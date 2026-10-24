import { Injectable } from '@nestjs/common';
import type { Address } from 'viem';
import { ChainService } from '../chain/chain.service.js';
import { amount } from '../transactions/params.js';

/// What /pool-info returns for a pool, minus anything per-holder. JSON-safe, so it is stored as is.
export type PoolSnapshot = Awaited<ReturnType<PoolReader['snapshot']>>;

/// Reads a pool's full state from the chain. The indexer stores the result in SQLite.
@Injectable()
export class PoolReader {
  constructor(private readonly chain: ChainService) {}

  async snapshot(address: Address) {
    const r = this.chain.pool(address).read;
    const [
      [
        name,
        symbol,
        totalSupply,
        creator,
        imageUrl,
        website,
        twitter,
        description,
        quoteAddress,
      ],
      [buyFeeBps, sellFeeBps, [creatorBps, burnBps, buybackBps, holdersBps]],
      [graduationThreshold, startPrice, endPrice, currentPrice],
      [curveSupply, dexSupply, curveTokensLeft, quoteReserve],
      [creatorFees, burnBucket, buybackBucket, buybackHeld],
      [rewardsUnclaimed, rewardsPending, graduated, migrated, pair],
    ] = await Promise.all([
      Promise.all([
        r.name(),
        r.symbol(),
        r.totalSupply(),
        r.creator(),
        r.imageUrl(),
        r.website(),
        r.twitter(),
        r.description(),
        r.quoteToken(),
      ]),
      Promise.all([r.buyFeeBps(), r.sellFeeBps(), r.taxAllocation()]),
      Promise.all([
        r.graduationThreshold(),
        r.startPrice(),
        r.endPrice(),
        r.currentPrice(),
      ]),
      Promise.all([
        r.curveSupply(),
        r.dexSupply(),
        r.curveTokensLeft(),
        r.quoteReserve(),
      ]),
      Promise.all([
        r.creatorFees(),
        r.burnBucket(),
        r.buybackBucket(),
        r.buybackHeld(),
      ]),
      Promise.all([
        r.rewardsUnclaimed(),
        r.rewardsPending(),
        r.graduated(),
        r.migrated(),
        r.pair(),
      ]),
    ]);
    const quote = await this.chain.quoteToken(quoteAddress);
    const d = quote.decimals;
    const sold = curveSupply - curveTokensLeft;
    return {
      chainId: this.chain.chain.id,
      pool: address,
      factory: this.chain.factoryAddress,
      name,
      symbol,
      decimals: 18,
      creator,
      imageUrl,
      website,
      twitter,
      description,
      quoteToken: quote,
      buyFeeBps: Number(buyFeeBps),
      sellFeeBps: Number(sellFeeBps),
      taxAllocation: {
        creatorBps: Number(creatorBps),
        burnBps: Number(burnBps),
        buybackBps: Number(buybackBps),
        holdersBps: Number(holdersBps),
      },
      totalSupply: amount(totalSupply),
      curveSupply: amount(curveSupply),
      dexSupply: amount(dexSupply),
      curveTokensLeft: amount(curveTokensLeft),
      curveTokensSold: amount(sold),
      progressPercent: Number((sold * 10_000n) / curveSupply) / 100,
      graduationThreshold: amount(graduationThreshold, d),
      quoteReserve: amount(quoteReserve, d),
      startPrice: amount(startPrice, d),
      currentPrice: amount(currentPrice, d),
      endPrice: amount(endPrice, d),
      creatorFees: amount(creatorFees, d),
      burnBucket: amount(burnBucket, d),
      buybackBucket: amount(buybackBucket, d),
      buybackHeld: amount(buybackHeld),
      rewardsUnclaimed: amount(rewardsUnclaimed, d),
      rewardsPending: amount(rewardsPending, d),
      graduated,
      migrated,
      pair,
    };
  }

  /// Per-holder numbers aren't indexed (they change with every transfer), so they're read live.
  async holder(address: Address, holder: Address, quoteDecimals: number) {
    const r = this.chain.pool(address).read;
    const [balance, pendingRewards] = await Promise.all([
      r.balanceOf([holder]),
      r.pendingRewards([holder]),
    ]);
    return {
      address: holder,
      balance: amount(balance),
      pendingRewards: amount(pendingRewards, quoteDecimals),
    };
  }
}
