import { BadRequestException, Injectable } from '@nestjs/common';
import {
  ContractFunctionExecutionError,
  encodeFunctionData,
  formatEther,
  getContract,
  isAddressEqual,
  type Address,
} from 'viem';
import { bondingCurvePoolAbi, poolFactoryAbi } from '../chain/abis.js';
import { ChainService, type UnsignedTx } from '../chain/chain.service.js';
import {
  amount,
  bps,
  optionalAddress,
  optionalAmount,
  optionalString,
  requireAddress,
  requireAmount,
  requireString,
} from './params.js';

type Query = Record<string, unknown>;

export interface TxResponse {
  chainId: number;
  transaction: UnsignedTx;
  quote: Record<string, unknown>;
}

// Mirrors the constants in BondingCurvePool / LinearCurveMath.
const BPS = 10_000n;
const MAX_FEE_BPS = 1_000;
const CURVE_SHARE_BPS = 8_000n;
const WAD = 10n ** 18n;
const MAX_SLIPPAGE_BPS = 5_000;
const DEFAULT_SLIPPAGE_BPS = 100; // 1%

/// Builds unsigned transactions for PoolFactory / BondingCurvePool. Nothing here signs or
/// sends: the caller's wallet does. Every endpoint takes an optional `from`; when given,
/// the call is dry-run as that account and `gas` is filled in.
@Injectable()
export class TransactionsService {
  constructor(private readonly chain: ChainService) {}

  async createPool(q: Query): Promise<TxResponse> {
    const params = {
      name: requireString('name', q.name),
      symbol: requireString('symbol', q.symbol),
      imageUrl: optionalString(q.imageUrl),
      website: optionalString(q.website),
      twitter: optionalString(q.twitter),
      feeBps: bps('feeBps', q.feeBps, MAX_FEE_BPS),
      totalSupply: requireAmount('totalSupply', q.totalSupply),
      graduationThreshold: requireAmount(
        'graduationThreshold',
        q.graduationThreshold,
      ),
    };
    const from = optionalAddress('from', q.from);

    // Same check BondingCurvePool.initialize makes, so a bad threshold fails here with a
    // readable message instead of an opaque InvalidCurve in the wallet.
    const startPrice = await this.factory().read.startPrice();
    const curveSupply = (params.totalSupply * CURVE_SHARE_BPS) / BPS;
    if (curveSupply === 0n) {
      throw new BadRequestException('totalSupply is too small');
    }
    const minThreshold = (startPrice * curveSupply) / WAD;
    if (params.graduationThreshold <= minThreshold) {
      throw new BadRequestException(
        `graduationThreshold must be more than ${formatEther(minThreshold)} BNB ` +
          '(what the curve raises if every token sold at the start price)',
      );
    }
    const endPrice =
      ceilDiv(2n * params.graduationThreshold * WAD, curveSupply) - startPrice;

    const data = encodeFunctionData({
      abi: poolFactoryAbi,
      functionName: 'createPool',
      args: [params],
    });
    return this.respond({ to: this.chain.factory, data }, from, {
      factory: this.chain.factory,
      feeBps: Number(params.feeBps),
      totalSupply: amount(params.totalSupply),
      curveSupply: amount(curveSupply),
      dexSupply: amount(params.totalSupply - curveSupply),
      graduationThreshold: amount(params.graduationThreshold),
      startPrice: amount(startPrice),
      endPrice: amount(endPrice),
      note: 'The new pool address is in the PoolCreated event of the receipt.',
    });
  }

  /// Exactly one of `bnbAmount` (spend this much, fee included) or `tokenAmount` (buy this many).
  async buy(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const bnbAmount = optionalAmount('bnbAmount', q.bnbAmount);
    const tokenAmount = optionalAmount('tokenAmount', q.tokenAmount);
    if ((bnbAmount === undefined) === (tokenAmount === undefined)) {
      throw new BadRequestException(
        'pass exactly one of bnbAmount or tokenAmount',
      );
    }
    const slippageBps = this.slippage(q);
    const from = optionalAddress('from', q.from);
    const pool = await this.tradablePool(address);
    const tokensLeft = await pool.read.curveTokensLeft();

    if (bnbAmount !== undefined) {
      const [filled, cost, fee] = await pool.read.getBuyQuoteForEth([
        bnbAmount,
      ]);
      if (filled === 0n) {
        throw new BadRequestException('bnbAmount is too small to buy a token');
      }
      const minTokensOut = (filled * (BPS - slippageBps)) / BPS;
      const data = encodeFunctionData({
        abi: bondingCurvePoolAbi,
        functionName: 'buyWithEth',
        args: [minTokensOut],
      });
      return this.respond({ to: address, data, value: bnbAmount }, from, {
        method: 'buyWithEth',
        slippageBps: Number(slippageBps),
        tokensOut: amount(filled),
        minTokensOut: amount(minTokensOut),
        cost: amount(cost),
        fee: amount(fee),
        totalPaid: amount(cost + fee),
        refund: amount(bnbAmount - cost - fee),
        completesCurve: filled === tokensLeft,
      });
    }

    // Near the end of the curve the quote may fill less than asked. Ask the contract for
    // just that many, so the average-price check in `buy` is against what can actually fill.
    const [filled, cost, fee] = await pool.read.getBuyQuote([tokenAmount!]);
    const maxPaid = ceilDiv((cost + fee) * (BPS + slippageBps), BPS);
    const data = encodeFunctionData({
      abi: bondingCurvePoolAbi,
      functionName: 'buy',
      args: [filled],
    });
    return this.respond({ to: address, data, value: maxPaid }, from, {
      method: 'buy',
      slippageBps: Number(slippageBps),
      tokensRequested: amount(tokenAmount!),
      tokensOut: amount(filled),
      partialFill: filled < tokenAmount!,
      cost: amount(cost),
      fee: amount(fee),
      totalPaid: amount(cost + fee),
      maxPaid: amount(maxPaid),
      note: 'value is totalPaid plus slippage; whatever is not used is refunded.',
      completesCurve: filled === tokensLeft,
    });
  }

  /// Sells straight from the caller's balance: the pool is the token, so no approve is needed.
  async sell(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const tokenAmount = requireAmount('tokenAmount', q.tokenAmount);
    const slippageBps = this.slippage(q);
    const from = optionalAddress('from', q.from);
    const pool = await this.tradablePool(address);

    const [curveSupply, tokensLeft] = await Promise.all([
      pool.read.curveSupply(),
      pool.read.curveTokensLeft(),
    ]);
    const sold = curveSupply - tokensLeft;
    if (tokenAmount > sold) {
      throw new BadRequestException(
        `only ${formatEther(sold)} tokens have been bought from the curve, so at most that many can be sold`,
      );
    }
    if (from) {
      const balance = await pool.read.balanceOf([from]);
      if (balance < tokenAmount) {
        throw new BadRequestException(
          `${from} holds only ${formatEther(balance)} tokens`,
        );
      }
    }

    const [refund, fee] = await pool.read.getSellQuote([tokenAmount]);
    const ethOut = refund - fee;
    const minEthOut = (ethOut * (BPS - slippageBps)) / BPS;
    const data = encodeFunctionData({
      abi: bondingCurvePoolAbi,
      functionName: 'sell',
      args: [tokenAmount, minEthOut],
    });
    return this.respond({ to: address, data }, from, {
      method: 'sell',
      slippageBps: Number(slippageBps),
      tokensIn: amount(tokenAmount),
      refund: amount(refund),
      fee: amount(fee),
      bnbOut: amount(ethOut),
      minBnbOut: amount(minEthOut),
    });
  }

  /// Read-only: everything about a pool, no transaction.
  async poolInfo(q: Query) {
    const address = requireAddress('pool', q.pool);
    const pool = await this.assertPool(address);
    const r = pool.read;
    const [
      name,
      symbol,
      totalSupply,
      creator,
      imageUrl,
      website,
      twitter,
      feeBps,
      graduationThreshold,
      startPrice,
      endPrice,
      currentPrice,
      curveSupply,
      dexSupply,
      curveTokensLeft,
      ethReserve,
      creatorFees,
      graduated,
      migrated,
      pair,
    ] = await Promise.all([
      r.name(),
      r.symbol(),
      r.totalSupply(),
      r.creator(),
      r.imageUrl(),
      r.website(),
      r.twitter(),
      r.feeBps(),
      r.graduationThreshold(),
      r.startPrice(),
      r.endPrice(),
      r.currentPrice(),
      r.curveSupply(),
      r.dexSupply(),
      r.curveTokensLeft(),
      r.ethReserve(),
      r.creatorFees(),
      r.graduated(),
      r.migrated(),
      r.pair(),
    ]);
    const sold = curveSupply - curveTokensLeft;
    return {
      chainId: this.chain.chain.id,
      pool: address,
      factory: this.chain.factory,
      name,
      symbol,
      decimals: 18,
      creator,
      imageUrl,
      website,
      twitter,
      feeBps: Number(feeBps),
      totalSupply: amount(totalSupply),
      curveSupply: amount(curveSupply),
      dexSupply: amount(dexSupply),
      curveTokensLeft: amount(curveTokensLeft),
      curveTokensSold: amount(sold),
      progressPercent: Number((sold * 10_000n) / curveSupply) / 100,
      graduationThreshold: amount(graduationThreshold),
      bnbReserve: amount(ethReserve),
      startPrice: amount(startPrice),
      currentPrice: amount(currentPrice),
      endPrice: amount(endPrice),
      creatorFees: amount(creatorFees),
      graduated,
      migrated,
      pair,
    };
  }

  /// Anyone may send this; the fees always go to the pool's creator.
  async claimCreatorFees(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const from = optionalAddress('from', q.from);
    const pool = await this.assertPool(address);
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
    return this.respond({ to: address, data }, from, {
      creator,
      amount: amount(creatorFees),
    });
  }

  /// PoolFactory.withdrawFees(to). Only the factory owner can send it; `to` defaults to the owner.
  async claimAdminFees(q: Query): Promise<TxResponse> {
    const from = optionalAddress('from', q.from);
    const [owner, balance] = await Promise.all([
      this.factory().read.owner(),
      this.chain.client.getBalance({ address: this.chain.factory }),
    ]);
    const to = optionalAddress('to', q.to) ?? owner;
    if (from && !isAddressEqual(from, owner)) {
      throw new BadRequestException(
        `only the factory owner ${owner} can withdraw admin fees`,
      );
    }
    if (balance === 0n) {
      throw new BadRequestException('no admin fees to withdraw');
    }
    const data = encodeFunctionData({
      abi: poolFactoryAbi,
      functionName: 'withdrawFees',
      args: [to],
    });
    return this.respond({ to: this.chain.factory, data }, from, {
      owner,
      to,
      amount: amount(balance),
      note: 'Must be signed by the factory owner.',
    });
  }

  /// Anyone may send this once the curve has sold out.
  async migrate(q: Query): Promise<TxResponse> {
    const address = requireAddress('pool', q.pool);
    const from = optionalAddress('from', q.from);
    const pool = await this.assertPool(address);
    const [graduated, migrated, pair, ethReserve, dexSupply] =
      await Promise.all([
        pool.read.graduated(),
        pool.read.migrated(),
        pool.read.pair(),
        pool.read.ethReserve(),
        pool.read.dexSupply(),
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
    return this.respond({ to: address, data }, from, {
      pair,
      bnbAmount: amount(ethReserve),
      tokenAmount: amount(dexSupply),
    });
  }

  // --------------------------------------------------------------- helpers

  private factory() {
    return getContract({
      address: this.chain.factory,
      abi: poolFactoryAbi,
      client: this.chain.client,
    });
  }

  /// Only build transactions against pools this factory created.
  private async assertPool(address: Address) {
    const pool = getContract({
      address,
      abi: bondingCurvePoolAbi,
      client: this.chain.client,
    });
    let factory: Address;
    try {
      factory = await pool.read.factory();
    } catch (err) {
      if (err instanceof ContractFunctionExecutionError) {
        throw new BadRequestException(`${address} is not a pool`);
      }
      throw err;
    }
    if (!isAddressEqual(factory, this.chain.factory)) {
      throw new BadRequestException(
        `${address} was not created by factory ${this.chain.factory}`,
      );
    }
    return pool;
  }

  private async tradablePool(address: Address) {
    const pool = await this.assertPool(address);
    if (await pool.read.graduated()) {
      throw new BadRequestException(
        `pool has graduated; trade on PancakeSwap (pair ${await pool.read.pair()})`,
      );
    }
    return pool;
  }

  private slippage(q: Query) {
    return bps(
      'slippageBps',
      q.slippageBps,
      MAX_SLIPPAGE_BPS,
      DEFAULT_SLIPPAGE_BPS,
    );
  }

  private async respond(
    tx: Parameters<ChainService['buildTx']>[0],
    from: Address | undefined,
    quote: Record<string, unknown>,
  ): Promise<TxResponse> {
    return {
      chainId: this.chain.chain.id,
      transaction: await this.chain.buildTx(tx, from),
      quote,
    };
  }
}

function ceilDiv(a: bigint, b: bigint) {
  return (a + b - 1n) / b;
}
