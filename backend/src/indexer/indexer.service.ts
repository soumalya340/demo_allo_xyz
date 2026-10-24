import {
  Injectable,
  Logger,
  OnApplicationBootstrap,
  OnApplicationShutdown,
} from '@nestjs/common';
import {
  BaseError,
  decodeEventLog,
  getAddress,
  isAddressEqual,
  type Address,
  type Log,
} from 'viem';
import { poolFactoryAbi } from '../chain/abis.js';
import { ChainService } from '../chain/chain.service.js';
import { PoolStore } from '../store/pool-store.service.js';
import { PoolReader } from './pool-reader.service.js';

const MAX_LOG_RANGE = Number(process.env.INDEXER_LOG_RANGE ?? 5_000);
const INTERVAL_MS = Number(process.env.INDEXER_INTERVAL_MS ?? 3_000);
const ADDRESSES_PER_QUERY = 500;

/// Keeps SQLite in step with the chain.
///
/// Every pass:
///  1. New pools: compares the factory's poolCount() with the store and saves each new pool from
///     allPools(i). This works on any RPC, so no launch is ever missed.
///  2. Changes: reads the logs of the factory and every pool over the next block range. A
///     PoolCreated log fills in the pool's launch block / tx / time; any log from a pool means its
///     state changed, so its snapshot is re-read.
///
/// Some RPCs (BNB Chain's public dataseed nodes) refuse eth_getLogs. The range is halved on every
/// failure; if even a single block fails, the indexer stops using logs and re-reads every pool on
/// each pass instead (launch block / tx then stay empty). INDEXER_USE_LOGS=false forces that mode.
@Injectable()
export class IndexerService
  implements OnApplicationBootstrap, OnApplicationShutdown
{
  private readonly logger = new Logger(IndexerService.name);
  private useLogs = process.env.INDEXER_USE_LOGS !== 'false';
  private logRange = MAX_LOG_RANGE;
  private stopped = false;
  private wake?: () => void;

  constructor(
    private readonly chain: ChainService,
    private readonly store: PoolStore,
    private readonly reader: PoolReader,
  ) {}

  onApplicationBootstrap() {
    if (process.env.INDEXER === 'off') {
      this.logger.warn('INDEXER=off: SQLite will not be updated');
      return;
    }
    void this.run();
  }

  onApplicationShutdown() {
    this.stopped = true;
    this.wake?.();
  }

  private async run() {
    this.logger.log(
      `indexing factory ${this.chain.factoryAddress} on chain ${this.chain.chain.id}`,
    );
    while (!this.stopped) {
      let caughtUp = true;
      try {
        caughtUp = await this.pass();
      } catch (err) {
        this.logger.warn(`sync failed, retrying: ${message(err)}`);
      }
      if (caughtUp) await this.sleep(INTERVAL_MS);
    }
  }

  /// One pass. Returns false while there are still blocks to catch up on.
  private async pass(): Promise<boolean> {
    const head = Number(await this.chain.client.getBlockNumber());
    await this.addNewPools(head);

    // First run: start from the factory's deploy block if known (so every launch's block / tx is
    // recorded), otherwise from the current head.
    const synced =
      this.store.syncedBlock() ?? (this.chain.startBlock ?? head + 1) - 1;
    if (synced >= head) return true;

    if (!this.useLogs) {
      await this.refresh(this.store.addresses(), head);
      this.store.setSyncedBlock(head);
      return true;
    }

    const from = synced + 1;
    const to = Math.min(head, from + this.logRange - 1);
    const logs = await this.getLogs(from, to);
    if (!logs) return false; // range shrunk or switched to polling; go again now

    const changed = new Set<Address>();
    for (const log of logs) {
      if (isAddressEqual(log.address, this.chain.factoryAddress)) {
        await this.recordLaunch(log);
      } else {
        changed.add(getAddress(log.address));
      }
    }
    await this.refresh([...changed], head);
    this.store.setSyncedBlock(to);
    this.logRange = Math.min(MAX_LOG_RANGE, this.logRange * 2);
    return to === head;
  }

  private async addNewPools(head: number) {
    const factory = this.chain.factory();
    const count = Number(await factory.read.poolCount());
    for (let i = this.store.poolCount(); i < count; i++) {
      const address = await factory.read.allPools([BigInt(i)]);
      this.store.insertPool(i, await this.reader.snapshot(address), head);
      this.logger.log(`pool #${i} ${address}`);
    }
  }

  private async refresh(addresses: Address[], head: number) {
    for (const address of addresses) {
      this.store.updateSnapshot(
        address,
        await this.reader.snapshot(address),
        head,
      );
    }
  }

  /// Logs of the factory and every known pool, or undefined if the RPC refused the range.
  private async getLogs(from: number, to: number): Promise<Log[] | undefined> {
    const addresses = [this.chain.factoryAddress, ...this.store.addresses()];
    try {
      const batches = [];
      for (let i = 0; i < addresses.length; i += ADDRESSES_PER_QUERY) {
        batches.push(
          this.chain.client.getLogs({
            address: addresses.slice(i, i + ADDRESSES_PER_QUERY),
            fromBlock: BigInt(from),
            toBlock: BigInt(to),
          }),
        );
      }
      return (await Promise.all(batches)).flat();
    } catch (err) {
      if (!(err instanceof BaseError)) throw err;
      if (this.logRange > 1) {
        this.logRange = Math.max(1, Math.floor(this.logRange / 2));
        return undefined;
      }
      this.useLogs = false;
      this.logger.warn(
        `RPC refuses eth_getLogs (${err.shortMessage}); re-reading every pool each pass instead. ` +
          'Launch block/tx will not be recorded; use an RPC that serves logs to get them.',
      );
      return undefined;
    }
  }

  private async recordLaunch(log: Log) {
    let pool: Address;
    try {
      const event = decodeEventLog({
        abi: poolFactoryAbi,
        data: log.data,
        topics: log.topics,
      });
      if (event.eventName !== 'PoolCreated') return;
      pool = event.args.pool;
    } catch {
      return; // some other factory log
    }
    const block = await this.chain.client.getBlock({
      blockNumber: log.blockNumber!,
    });
    this.store.setLaunch(
      pool,
      Number(log.blockNumber),
      log.transactionHash!,
      Number(block.timestamp),
    );
  }

  private sleep(ms: number) {
    return new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, ms);
      this.wake = () => {
        clearTimeout(timer);
        resolve();
      };
    });
  }
}

function message(err: unknown) {
  return err instanceof BaseError
    ? err.shortMessage
    : err instanceof Error
      ? err.message
      : String(err);
}
