import { Module } from '@nestjs/common';
import { APP_FILTER } from '@nestjs/core';
import { createObserveModule } from '@nestjs/observe';
import { AppController } from './app.controller.js';
import { AppService } from './app.service.js';
import { ChainErrorFilter } from './chain/chain-error.filter.js';
import { ChainService } from './chain/chain.service.js';
import { TransactionsController } from './transactions/transactions.controller.js';
import { IndexerService } from './indexer/indexer.service.js';
import { PoolReader } from './indexer/pool-reader.service.js';
import { PoolStore } from './store/pool-store.service.js';
import { FactoryService } from './transactions/factory.service.js';
import { PoolService } from './transactions/pool.service.js';

export const { ObserveModule, ObserveInstrument } = createObserveModule();

@Module({
  imports: [
    // Distributed tracing, auto-correlated logs, request/job metrics, error
    // telemetry, alarms, and more — out of the box. Sign up at https://observe.nestjs.com
    ObserveModule.forRoot({
      appKey: process.env.OBSERVE_APP_KEY ?? '',
      appSecret: process.env.OBSERVE_APP_SECRET ?? '',
      runtimeMetrics: !Boolean(process.versions?.['webcontainer']),
      serviceId: 'nest-typescript-starter',
    }),
  ],
  controllers: [AppController, TransactionsController],
  providers: [
    AppService,
    ChainService,
    FactoryService,
    PoolService,
    PoolReader,
    PoolStore,
    IndexerService,
    { provide: APP_FILTER, useClass: ChainErrorFilter },
  ],
})
export class AppModule {}
