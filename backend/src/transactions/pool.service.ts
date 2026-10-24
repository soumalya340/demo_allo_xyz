import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import {
  ContractFunctionExecutionError,
  encodeFunctionData,
  formatEther,
  formatUnits,
  isAddressEqual,
  maxUint256,
  type Address,
} from 'viem';
import { bondingCurvePoolAbi } from '../chain/abis.js';
import {
  ChainService,
  type PoolContract,
  type QuoteToken,
  type TxResponse,
} from '../chain/chain.service.js';
import { PoolReader } from '../indexer/pool-reader.service.js';
import { PoolStore } from '../store/pool-store.service.js';
import {
  allowanceAmount,
  amount,
  bps,
  optionalAddress,
  optionalInt,
  requireAddress,
  requireAmount,
} from './params.js';

type Query = Record<string, unknown>;

const BPS = 10_000n;
const MAX_SLIPPAGE_BPS = 5_000;
const DEFAULT_SLIPPAGE_BPS = 100; // 1%

/// BondingCurvePool transactions: trading, migration, fees and rewards, and the coin's ERC20 calls.
/// Quote amounts (what the coin trades against) use the quote token's decimals; coins have 18.
@Injectable()
export class PoolService {
  constructor(
    private readonly chain: ChainService,
    private readonly store: PoolStore,
    private readonly reader: PoolReader,
  ) {}

  // ---------------------------------------------------------------- trading

  /// buy(amount, maxIn): an exact number of coins, paying at most the quote + slippage.
  async buy(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const tokenAmount = requireAmount('tokenAmount', q.tokenAmount);
    const slippageBps = this.slippage(q);
    const from = optionalAddress('from', q.from);
    const { pool, quote } = await this.tradablePool(address);

    // Near the end of the curve the quote may fill less than asked. Ask the contract for just
    // that many, so its average-price check is against what can actually fill.
    const [[filled, cost, fee], tokensLeft] = await Promise.all([
      pool.read.getBuyQuote([tokenAmount]),
      pool.read.curveTokensLeft(),
    ]);
    const total = cost + fee;
    const maxIn = ceilDiv(total * (BPS + slippageBps), BPS);
    await this.assertCanPay(quote, from, maxIn);

    const data = encodeFunctionData({
      abi: bondingCurvePoolAbi,
      functionName: 'buy',
      args: [filled, maxIn],
    });
    const d = quote.decimals;
    return this.chain.respond(
      { to: address, data, value: quote.native ? maxIn : 0n },
      from,
      {
        method: 'buy',
        quoteToken: quote,
        slippageBps: Number(slippageBps),
        tokensRequested: amount(tokenAmount),
        tokensOut: amount(filled),
        partialFill: filled < tokenAmount,
        cost: amount(cost, d),
        tax: amount(fee, d),
        totalPaid: amount(total, d),
        maxIn: amount(maxIn, d),
        completesCurve: filled === tokensLeft,
        note: quote.native
          ? 'value is maxIn; whatever is not used is refunded.'
          : 'The pool pulls exactly totalPaid at execution (at most maxIn).',
      },
      await this.chain.approvals(quote, from, address, maxIn),
    );
  }

  /// buyExactIn(amountIn, minTokensOut): spend this much quote (tax included) on as many coins as it buys.
  async buyExactIn(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const slippageBps = this.slippage(q);
    const from = optionalAddress('from', q.from);
    const { pool, quote } = await this.tradablePool(address);
    const amountIn = requireAmount('amountIn', q.amountIn, quote.decimals);

    const [[filled, cost, fee], tokensLeft] = await Promise.all([
      pool.read.getBuyQuoteExactIn([amountIn]),
      pool.read.curveTokensLeft(),
    ]);
    if (filled === 0n) {
      throw new BadRequestException('amountIn is too small to buy a coin');
    }
    const minTokensOut = (filled * (BPS - slippageBps)) / BPS;
    await this.assertCanPay(quote, from, amountIn);

    const data = encodeFunctionData({
      abi: bondingCurvePoolAbi,
      functionName: 'buyExactIn',
      args: [amountIn, minTokensOut],
    });
    const d = quote.decimals;
    return this.chain.respond(
      { to: address, data, value: quote.native ? amountIn : 0n },
      from,
      {
        method: 'buyExactIn',
        quoteToken: quote,
        slippageBps: Number(slippageBps),
        amountIn: amount(amountIn, d),
        tokensOut: amount(filled),
        minTokensOut: amount(minTokensOut),
        cost: amount(cost, d),
        tax: amount(fee, d),
        totalPaid: amount(cost + fee, d),
        unused: amount(amountIn - cost - fee, d),
        completesCurve: filled === tokensLeft,
        note: quote.native
          ? 'unused BNB is refunded.'
          : 'The pool pulls exactly totalPaid at execution.',
      },
      await this.chain.approvals(quote, from, address, amountIn),
    );
  }

  /// sell(amount, minQuoteOut). The pool is the coin, so no approve is needed.
  async sell(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const tokenAmount = requireAmount('tokenAmount', q.tokenAmount);
    const slippageBps = this.slippage(q);
    const from = optionalAddress('from', q.from);
    const { pool, quote } = await this.tradablePool(address);

    const [curveSupply, tokensLeft] = await Promise.all([
      pool.read.curveSupply(),
      pool.read.curveTokensLeft(),
    ]);
    const sold = curveSupply - tokensLeft;
    if (tokenAmount > sold) {
      throw new BadRequestException(
        `only ${formatEther(sold)} coins have been bought from the curve, so at most that many can be sold`,
      );
    }
    if (from) await this.assertHolds(pool, from, tokenAmount);

    const [refund, fee] = await pool.read.getSellQuote([tokenAmount]);
    const quoteOut = refund - fee;
    const minQuoteOut = (quoteOut * (BPS - slippageBps)) / BPS;
    const data = encodeFunctionData({
      abi: bondingCurvePoolAbi,
      functionName: 'sell',
      args: [tokenAmount, minQuoteOut],
    });
    const d = quote.decimals;
    return this.chain.respond({ to: address, data }, from, {
      method: 'sell',
      quoteToken: quote,
      slippageBps: Number(slippageBps),
      tokensIn: amount(tokenAmount),
      refund: amount(refund, d),
      tax: amount(fee, d),
      quoteOut: amount(quoteOut, d),
      minQuoteOut: amount(minQuoteOut, d),
    });
  }

  /// migrate(): anyone, once the curve has sold out.
  async migrate(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const from = optionalAddress('from', q.from);
    const { pool, quote } = await this.assertPool(address);
    const [graduated, migrated, pair, quoteReserve, dexSupply, burn, buyback] =
      await Promise.all([
        pool.read.graduated(),
        pool.read.migrated(),
        pool.read.pair(),
        pool.read.quoteReserve(),
        pool.read.dexSupply(),
        pool.read.burnBucket(),
        pool.read.buybackBucket(),
      ]);
    if (!graduated) {
      throw new BadRequestException(
        'pool has not graduated yet (curve not sold out)',
      );
    }
    if (migrated) throw new BadRequestException('pool is already migrated');
    const data = encodeFunctionData({
      abi: bondingCurvePoolAbi,
      functionName: 'migrate',
    });
    const d = quote.decimals;
    return this.chain.respond({ to: address, data }, from, {
      quoteToken: quote,
      pair,
      quoteLiquidity: amount(quoteReserve, d),
      coinLiquidity: amount(dexSupply),
      burnBucket: amount(burn, d),
      buybackBucket: amount(buyback, d),
      note: 'LP tokens are burned. Leftover burn/buyback tax is swapped for coins on the new pair.',
    });
  }

  // ------------------------------------------------------- fees & rewards

  /// claimCreatorFees(): anyone may send it; the quote always goes to the creator.
  async claimCreatorFees(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const from = optionalAddress('from', q.from);
    const { pool, quote } = await this.assertPool(address);
    const [creator, creatorFees] = await Promise.all([
      pool.read.creator(),
      pool.read.creatorFees(),
    ]);
    if (creatorFees === 0n) {
      throw new BadRequestException('no creator fees to claim');
    }
    const data = encodeFunctionData({
      abi: bondingCurvePoolAbi,
      functionName: 'claimCreatorFees',
    });
    return this.chain.respond({ to: address, data }, from, {
      quoteToken: quote,
      creator,
      amount: amount(creatorFees, quote.decimals),
    });
  }

  /// claimRewards(): pays the sender their holder rewards, so pass `from` to see what they get.
  async claimRewards(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const from = optionalAddress('from', q.from);
    const { pool, quote } = await this.assertPool(address);
    let pending: bigint | undefined;
    if (from) {
      pending = await pool.read.pendingRewards([from]);
      if (pending === 0n) {
        throw new BadRequestException(`${from} has no rewards to claim`);
      }
    }
    const data = encodeFunctionData({
      abi: bondingCurvePoolAbi,
      functionName: 'claimRewards',
    });
    return this.chain.respond({ to: address, data }, from, {
      quoteToken: quote,
      ...(pending !== undefined
        ? { amount: amount(pending, quote.decimals) }
        : { note: 'Pass `from` to see the claimable amount.' }),
    });
  }

  // ------------------------------------------------------- the coin's ERC20

  /// transfer(to, amount).
  async transfer(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const to = requireAddress('to', q.to);
    const tokenAmount = requireAmount('amount', q.amount);
    const from = optionalAddress('from', q.from);
    const { pool } = await this.assertPool(address);
    await this.assertNotPair(pool, to);
    if (from) await this.assertHolds(pool, from, tokenAmount);
    const data = encodeFunctionData({
      abi: bondingCurvePoolAbi,
      functionName: 'transfer',
      args: [to, tokenAmount],
    });
    return this.chain.respond({ to: address, data }, from, {
      to,
      amount: amount(tokenAmount),
    });
  }

  /// transferFrom(owner, to, amount), sent by a spender `owner` approved. `from` is that spender.
  async transferFrom(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const owner = requireAddress('owner', q.owner);
    const to = requireAddress('to', q.to);
    const tokenAmount = requireAmount('amount', q.amount);
    const from = optionalAddress('from', q.from);
    const { pool } = await this.assertPool(address);
    await this.assertNotPair(pool, to);
    await this.assertHolds(pool, owner, tokenAmount);
    if (from) {
      const allowance = await pool.read.allowance([owner, from]);
      if (allowance < tokenAmount) {
        throw new BadRequestException(
          `${owner} has approved ${from} for only ${formatEther(allowance)} coins`,
        );
      }
    }
    const data = encodeFunctionData({
      abi: bondingCurvePoolAbi,
      functionName: 'transferFrom',
      args: [owner, to, tokenAmount],
    });
    return this.chain.respond({ to: address, data }, from, {
      owner,
      to,
      amount: amount(tokenAmount),
    });
  }

  /// approve(spender, amount). amount may be "max" or 0 (revoke).
  async approve(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const spender = requireAddress('spender', q.spender);
    const allowance = allowanceAmount('amount', q.amount);
    const from = optionalAddress('from', q.from);
    await this.assertPool(address);
    const data = encodeFunctionData({
      abi: bondingCurvePoolAbi,
      functionName: 'approve',
      args: [spender, allowance],
    });
    return this.chain.respond({ to: address, data }, from, {
      spender,
      amount:
        allowance === maxUint256
          ? { raw: allowance.toString(), formatted: 'max' }
          : amount(allowance),
    });
  }

  // ----------------------------------------------------------------- reads
  //
  // Served from SQLite, kept current by the indexer (a few seconds behind the chain). `syncedBlock`
  // says how far it has got. Per-holder numbers aren't indexed, so `holder` is read live.

  /// Everything about a pool, no transaction. With `holder`, also their balance and rewards.
  async poolInfo(q: Query) {
    const address = requireAddress('pool', q.pool);
    const holder = optionalAddress('holder', q.holder);
    const pool = this.store.get(address);
    if (!pool) {
      throw new NotFoundException(
        `${address} is not an indexed pool of factory ${this.chain.factoryAddress} ` +
          '(not a pool, or launched in the last few seconds)',
      );
    }
    return {
      syncedBlock: this.store.syncedBlock() ?? null,
      ...(await this.withHolder(pool, holder)),
    };
  }

  /// Every pool the factory launched, oldest first. `offset` / `limit` page through them; by
  /// default all are returned.
  async allPoolInfo(q: Query) {
    const holder = optionalAddress('holder', q.holder);
    const total = this.store.poolCount();
    const offset = optionalInt('offset', q.offset, 0);
    const limit = optionalInt('limit', q.limit, total);
    const pools = await Promise.all(
      this.store.list(offset, limit).map((p) => this.withHolder(p, holder)),
    );
    return {
      chainId: this.chain.chain.id,
      factory: this.chain.factoryAddress,
      syncedBlock: this.store.syncedBlock() ?? null,
      total,
      offset,
      count: pools.length,
      pools,
    };
  }

  private async withHolder(
    pool: NonNullable<ReturnType<PoolStore['get']>>,
    holder: Address | undefined,
  ) {
    if (!holder) return pool;
    return {
      ...pool,
      holder: await this.reader.holder(
        pool.pool,
        holder,
        pool.quoteToken.decimals,
      ),
    };
  }

  // --------------------------------------------------------------- helpers

  /// Only build transactions against pools this factory created.
  private async assertPool(address: Address) {
    const pool = this.chain.pool(address);
    let factory: Address;
    try {
      factory = await pool.read.factory();
    } catch (err) {
      if (err instanceof ContractFunctionExecutionError) {
        throw new BadRequestException(`${address} is not a pool`);
      }
      throw err;
    }
    if (!isAddressEqual(factory, this.chain.factoryAddress)) {
      throw new BadRequestException(
        `${address} was not created by factory ${this.chain.factoryAddress}`,
      );
    }
    const quote = await this.chain.quoteToken(await pool.read.quoteToken());
    return { pool, quote };
  }

  private async tradablePool(address: Address) {
    const found = await this.assertPool(address);
    if (await found.pool.read.graduated()) {
      throw new BadRequestException(
        `pool has graduated; trade on PancakeSwap (pair ${await found.pool.read.pair()})`,
      );
    }
    return found;
  }

  private async assertCanPay(
    quote: QuoteToken,
    from: Address | undefined,
    needed: bigint,
  ) {
    if (!from) return;
    const balance = await this.chain.balanceOf(quote, from);
    if (balance < needed) {
      throw new BadRequestException(
        `${from} holds only ${formatUnits(balance, quote.decimals)} ${quote.symbol}; needs ${formatUnits(needed, quote.decimals)}`,
      );
    }
  }

  private async assertHolds(
    pool: PoolContract,
    holder: Address,
    needed: bigint,
  ) {
    const balance = await pool.read.balanceOf([holder]);
    if (balance < needed) {
      throw new BadRequestException(
        `${holder} holds only ${formatEther(balance)} coins`,
      );
    }
  }

  /// The coin can't be sent to its PancakeSwap pair before migration.
  private async assertNotPair(pool: PoolContract, to: Address) {
    const [pair, migrated] = await Promise.all([
      pool.read.pair(),
      pool.read.migrated(),
    ]);
    if (isAddressEqual(to, pair) && !migrated) {
      throw new BadRequestException(
        'coins cannot be sent to the PancakeSwap pair before migration',
      );
    }
  }

  private slippage(q: Query) {
    return bps(
      'slippageBps',
      q.slippageBps,
      MAX_SLIPPAGE_BPS,
      DEFAULT_SLIPPAGE_BPS,
    );
  }
}

function ceilDiv(a: bigint, b: bigint) {
  return (a + b - 1n) / b;
}
