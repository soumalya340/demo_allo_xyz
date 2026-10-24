import { BadRequestException, Injectable } from '@nestjs/common';
import {
  encodeFunctionData,
  formatUnits,
  isAddressEqual,
  zeroAddress,
} from 'viem';
import { poolFactoryAbi } from '../chain/abis.js';
import { ChainService, type TxResponse } from '../chain/chain.service.js';
import {
  amount,
  bps,
  optionalAddress,
  optionalAmount,
  optionalString,
  quoteTokenAddress,
  requireAddress,
  requireAmount,
  requireString,
} from './params.js';

type Query = Record<string, unknown>;

// Mirrors the constants in BondingCurvePool / LinearCurveMath.
const BPS = 10_000n;
const MAX_FEE_BPS = 1_000;
const CURVE_SHARE_BPS = 8_000n;
const WAD = 10n ** 18n;

/// PoolFactory transactions: launching coins, plus the admin's (owner's) settings and fees.
@Injectable()
export class FactoryService {
  constructor(private readonly chain: ChainService) {}

  /// createPool(params, firstBuyAmount). msg.value = launchFee (+ firstBuyAmount for a BNB coin).
  async createPool(q: Query): Promise<TxResponse> {
    const from = optionalAddress('from', q.from);
    const quote = await this.chain.quoteToken(
      quoteTokenAddress('quoteToken', q.quoteToken),
    );
    const taxAllocation = {
      creatorBps: bps('creatorBps', q.creatorBps, 10_000, 0),
      burnBps: bps('burnBps', q.burnBps, 10_000, 0),
      buybackBps: bps('buybackBps', q.buybackBps, 10_000, 0),
      holdersBps: bps('holdersBps', q.holdersBps, 10_000, 0),
    };
    const params = {
      name: requireString('name', q.name),
      symbol: requireString('symbol', q.symbol),
      imageUrl: optionalString(q.imageUrl),
      website: optionalString(q.website),
      twitter: optionalString(q.twitter),
      quoteToken: quote.address,
      buyFeeBps: bps('buyFeeBps', q.buyFeeBps, MAX_FEE_BPS),
      sellFeeBps: bps('sellFeeBps', q.sellFeeBps, MAX_FEE_BPS),
      taxAllocation,
      totalSupply: requireAmount('totalSupply', q.totalSupply),
      graduationThreshold: requireAmount(
        'graduationThreshold',
        q.graduationThreshold,
        quote.decimals,
      ),
    };
    const firstBuyAmount =
      optionalAmount('firstBuyAmount', q.firstBuyAmount, quote.decimals) ?? 0n;

    const allocated = Object.values(taxAllocation).reduce((a, b) => a + b);
    if (allocated !== BPS) {
      throw new BadRequestException(
        `creatorBps + burnBps + buybackBps + holdersBps must add up to 10000 (got ${allocated})`,
      );
    }

    const factory = this.chain.factory();
    const [startPrice, launchFee] = await Promise.all([
      factory.read.startPriceOf([quote.address]),
      factory.read.launchFee(),
    ]);
    if (startPrice === 0n) {
      throw new BadRequestException(
        `quote token ${quote.address} is not allowed by the factory`,
      );
    }

    // Same checks BondingCurvePool.initialize makes, so a bad threshold fails here with a
    // readable message instead of an opaque InvalidCurve in the wallet.
    const curveSupply = (params.totalSupply * CURVE_SHARE_BPS) / BPS;
    if (curveSupply === 0n) {
      throw new BadRequestException('totalSupply is too small');
    }
    const minThreshold = (startPrice * curveSupply) / WAD;
    if (params.graduationThreshold <= minThreshold) {
      throw new BadRequestException(
        `graduationThreshold must be more than ${formatUnits(minThreshold, quote.decimals)} ${quote.symbol} ` +
          '(what the curve raises if every coin sold at the start price)',
      );
    }
    const endPrice =
      ceilDiv(2n * params.graduationThreshold * WAD, curveSupply) - startPrice;

    const value = launchFee + (quote.native ? firstBuyAmount : 0n);
    const approvals = await this.chain.approvals(
      quote,
      from,
      this.chain.factoryAddress,
      firstBuyAmount,
    );
    const data = encodeFunctionData({
      abi: poolFactoryAbi,
      functionName: 'createPool',
      args: [params, firstBuyAmount],
    });
    const d = quote.decimals;
    return this.chain.respond(
      { to: this.chain.factoryAddress, data, value },
      from,
      {
        factory: this.chain.factoryAddress,
        quoteToken: quote,
        buyFeeBps: Number(params.buyFeeBps),
        sellFeeBps: Number(params.sellFeeBps),
        taxAllocation: mapValues(taxAllocation, Number),
        totalSupply: amount(params.totalSupply),
        curveSupply: amount(curveSupply),
        dexSupply: amount(params.totalSupply - curveSupply),
        graduationThreshold: amount(params.graduationThreshold, d),
        startPrice: amount(startPrice, d),
        endPrice: amount(endPrice, d),
        launchFee: amount(launchFee),
        firstBuyAmount: amount(firstBuyAmount, d),
        note: 'The new pool address is in the PoolCreated event of the receipt (topics[1]).',
      },
      approvals,
    );
  }

  /// setQuoteToken(token, startPrice): allow an ERC20 (or reprice BNB); startPrice 0 removes it.
  async setQuoteToken(q: Query): Promise<TxResponse> {
    const from = optionalAddress('from', q.from);
    const token = await this.chain.quoteToken(
      quoteTokenAddress('token', q.token),
    );
    const startPrice = requireAmount(
      'startPrice',
      q.startPrice,
      token.decimals,
      {
        allowZero: true,
      },
    );
    const [owner, current] = await Promise.all([
      this.chain.assertFactoryOwner(from),
      this.chain.factory().read.startPriceOf([token.address]),
    ]);
    const data = encodeFunctionData({
      abi: poolFactoryAbi,
      functionName: 'setQuoteToken',
      args: [token.address, startPrice],
    });
    return this.chain.respond({ to: this.chain.factoryAddress, data }, from, {
      owner,
      token,
      currentStartPrice: amount(current, token.decimals),
      newStartPrice: amount(startPrice, token.decimals),
      action:
        startPrice === 0n ? 'remove' : current === 0n ? 'allow' : 'reprice',
      note: 'Existing pools keep the price they launched with.',
    });
  }

  /// setLaunchFee(launchFee), in BNB.
  async setLaunchFee(q: Query): Promise<TxResponse> {
    const from = optionalAddress('from', q.from);
    const launchFee = requireAmount('launchFee', q.launchFee, 18, {
      allowZero: true,
    });
    const [owner, current] = await Promise.all([
      this.chain.assertFactoryOwner(from),
      this.chain.factory().read.launchFee(),
    ]);
    const data = encodeFunctionData({
      abi: poolFactoryAbi,
      functionName: 'setLaunchFee',
      args: [launchFee],
    });
    return this.chain.respond({ to: this.chain.factoryAddress, data }, from, {
      owner,
      currentLaunchFee: amount(current),
      newLaunchFee: amount(launchFee),
    });
  }

  /// withdrawFees(token, to): the platform's collected fees in one token. `to` defaults to the owner.
  async withdrawFees(q: Query): Promise<TxResponse> {
    const from = optionalAddress('from', q.from);
    const token = await this.chain.quoteToken(
      quoteTokenAddress('token', q.token),
    );
    const owner = await this.chain.assertFactoryOwner(from);
    const to = optionalAddress('to', q.to) ?? owner;
    const balance = await this.chain.balanceOf(
      token,
      this.chain.factoryAddress,
    );
    if (balance === 0n) {
      throw new BadRequestException(`no ${token.symbol} fees to withdraw`);
    }
    const data = encodeFunctionData({
      abi: poolFactoryAbi,
      functionName: 'withdrawFees',
      args: [token.address, to],
    });
    return this.chain.respond({ to: this.chain.factoryAddress, data }, from, {
      owner,
      token,
      to,
      amount: amount(balance, token.decimals),
    });
  }

  /// transferOwnership(newOwner): hands the admin role over.
  async transferOwnership(q: Query): Promise<TxResponse> {
    const from = optionalAddress('from', q.from);
    const newOwner = requireAddress('newOwner', q.newOwner);
    if (isAddressEqual(newOwner, zeroAddress)) {
      throw new BadRequestException(
        'newOwner cannot be the zero address; use /renounce-ownership to give up the role',
      );
    }
    const owner = await this.chain.assertFactoryOwner(from);
    const data = encodeFunctionData({
      abi: poolFactoryAbi,
      functionName: 'transferOwnership',
      args: [newOwner],
    });
    return this.chain.respond({ to: this.chain.factoryAddress, data }, from, {
      currentOwner: owner,
      newOwner,
    });
  }

  /// renounceOwnership(): irreversible, so it needs confirm=true.
  async renounceOwnership(q: Query): Promise<TxResponse> {
    const from = optionalAddress('from', q.from);
    if (q.confirm !== 'true') {
      throw new BadRequestException(
        'renouncing ownership is permanent: nobody can change settings or withdraw fees afterwards. Pass confirm=true',
      );
    }
    const owner = await this.chain.assertFactoryOwner(from);
    const data = encodeFunctionData({
      abi: poolFactoryAbi,
      functionName: 'renounceOwnership',
    });
    return this.chain.respond({ to: this.chain.factoryAddress, data }, from, {
      currentOwner: owner,
      warning:
        'After this the factory has no admin: fees can never be withdrawn and settings never changed.',
    });
  }
}

function ceilDiv(a: bigint, b: bigint) {
  return (a + b - 1n) / b;
}

function mapValues<T, U>(o: Record<string, T>, f: (v: T) => U) {
  return Object.fromEntries(Object.entries(o).map(([k, v]) => [k, f(v)]));
}
