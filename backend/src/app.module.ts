import { Module } from '@nestjs/common';
import { APP_FILTER } from '@nestjs/core';
import { AppController } from './app.controller.js';
import { AppService } from './app.service.js';
import { ChainErrorFilter } from './chain/chain-error.filter.js';
import { ChainService } from './chain/chain.service.js';
import { HealthController } from './health/health.controller.js';
import { TransactionsController } from './transactions/transactions.controller.js';
import { IndexerService } from './indexer/indexer.service.js';
import { PoolReader } from './indexer/pool-reader.service.js';
import { PoolStore } from './store/pool-store.service.js';
import { FactoryService } from './transactions/factory.service.js';
import { PoolService } from './transactions/pool.service.js';

@Module({
  controllers: [AppController, HealthController, TransactionsController],
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
