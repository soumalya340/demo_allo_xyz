import { Controller, Get, Query } from '@nestjs/common';
import { FactoryService } from './factory.service.js';
import { PoolService } from './pool.service.js';

type Q = Record<string, unknown>;

/// One GET endpoint per public, user-callable contract function (Functions.md, section 1), plus
/// /pool-info and /get-all-pool-info. All arguments go in the query string. Each transaction endpoint returns
/// { chainId, approvals, transaction, simulated, quote }: the caller sends every `approvals`
/// entry first, then `transaction`, with web3.js or their wallet.
@Controller()
export class TransactionsController {
  constructor(
    private readonly factory: FactoryService,
    private readonly pools: PoolService,
  ) {}

  // ------------------------------------------------------------ PoolFactory

  @Get('launch')
  createPool(@Query() q: Q) {
    return this.factory.createPool(q);
  }

  @Get('set-quote-token')
  setQuoteToken(@Query() q: Q) {
    return this.factory.setQuoteToken(q);
  }

  @Get('set-launch-fee')
  setLaunchFee(@Query() q: Q) {
    return this.factory.setLaunchFee(q);
  }

  /// PoolFactory.withdrawFees(token, to)
  @Get('claim-admin-fees')
  claimAdminFees(@Query() q: Q) {
    return this.factory.withdrawFees(q);
  }

  @Get('transfer-ownership')
  transferOwnership(@Query() q: Q) {
    return this.factory.transferOwnership(q);
  }

  @Get('renounce-ownership')
  renounceOwnership(@Query() q: Q) {
    return this.factory.renounceOwnership(q);
  }

  // ------------------------------------------------------- BondingCurvePool

  @Get('buy')
  buy(@Query() q: Q) {
    return this.pools.buy(q);
  }

  @Get('buy-exact-in')
  buyExactIn(@Query() q: Q) {
    return this.pools.buyExactIn(q);
  }

  @Get('sell')
  sell(@Query() q: Q) {
    return this.pools.sell(q);
  }

  @Get('migrate')
  migrate(@Query() q: Q) {
    return this.pools.migrate(q);
  }

  @Get('claim-creator-fees')
  claimCreatorFees(@Query() q: Q) {
    return this.pools.claimCreatorFees(q);
  }

  @Get('claim-rewards')
  claimRewards(@Query() q: Q) {
    return this.pools.claimRewards(q);
  }

  @Get('transfer')
  transfer(@Query() q: Q) {
    return this.pools.transfer(q);
  }

  @Get('transfer-from')
  transferFrom(@Query() q: Q) {
    return this.pools.transferFrom(q);
  }

  @Get('approve')
  approve(@Query() q: Q) {
    return this.pools.approve(q);
  }

  @Get('pool-info')
  poolInfo(@Query() q: Q) {
    return this.pools.poolInfo(q);
  }

  @Get('get-all-pool-info')
  allPoolInfo(@Query() q: Q) {
    return this.pools.allPoolInfo(q);
  }
}
