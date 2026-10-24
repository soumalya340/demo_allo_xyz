import { Controller, Get, Query } from '@nestjs/common';
import { TransactionsService } from './transactions.service.js';

/// Endpoints from Endpoints.md. All GET, all arguments in the query string.
/// Each one (except /pool-info) returns { chainId, transaction, quote }; the caller signs and
/// sends `transaction` with web3.js or their wallet.
@Controller()
export class TransactionsController {
  constructor(private readonly transactions: TransactionsService) {}

  @Get('create-pool-transaction')
  createPool(@Query() q: Record<string, unknown>) {
    return this.transactions.createPool(q);
  }

  @Get('buy')
  buy(@Query() q: Record<string, unknown>) {
    return this.transactions.buy(q);
  }

  @Get('sell')
  sell(@Query() q: Record<string, unknown>) {
    return this.transactions.sell(q);
  }

  @Get('pool-info')
  poolInfo(@Query() q: Record<string, unknown>) {
    return this.transactions.poolInfo(q);
  }

  @Get('claim-creator-fees')
  claimCreatorFees(@Query() q: Record<string, unknown>) {
    return this.transactions.claimCreatorFees(q);
  }

  @Get('claim-admin-fees')
  claimAdminFees(@Query() q: Record<string, unknown>) {
    return this.transactions.claimAdminFees(q);
  }

  @Get('migrate')
  migrate(@Query() q: Record<string, unknown>) {
    return this.transactions.migrate(q);
  }
}
