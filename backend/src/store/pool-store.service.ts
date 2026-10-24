import { Injectable, Logger, OnModuleDestroy } from '@nestjs/common';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import type { Address, Hash } from 'viem';
import { ChainService } from '../chain/chain.service.js';
import type { PoolSnapshot } from '../indexer/pool-reader.service.js';

const DEFAULT_DB_PATH = 'data/allo.sqlite';

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS pools (
    address       TEXT PRIMARY KEY,
    idx           INTEGER NOT NULL UNIQUE, -- position in the factory's allPools
    creator       TEXT NOT NULL,
    quote_token   TEXT NOT NULL,
    name          TEXT NOT NULL,
    symbol        TEXT NOT NULL,
    launch_block  INTEGER,                 -- from the PoolCreated log; NULL until/unless it is seen
    launch_tx     TEXT,
    launched_at   INTEGER,                 -- unix seconds
    snapshot      TEXT NOT NULL,           -- JSON: the /pool-info body
    updated_block INTEGER NOT NULL         -- chain head when the snapshot was read
  );
  CREATE INDEX IF NOT EXISTS pools_creator ON pools (creator);
`;

interface PoolRow {
  address: string;
  idx: number;
  launch_block: number | null;
  launch_tx: string | null;
  launched_at: number | null;
  snapshot: string;
  updated_block: number;
}

/// SQLite (node:sqlite, built into Node) holding every launch and each pool's latest state, as
/// written by the indexer. One database belongs to one chain + factory: if either changes, the
/// old rows are dropped and the indexer starts over.
@Injectable()
export class PoolStore implements OnModuleDestroy {
  private readonly logger = new Logger(PoolStore.name);
  private readonly db: DatabaseSync;

  constructor(chain: ChainService) {
    const path = process.env.DB_PATH ?? DEFAULT_DB_PATH;
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec('PRAGMA journal_mode = WAL;');
    this.db.exec(SCHEMA);

    const scope = `${chain.chain.id}:${chain.factoryAddress.toLowerCase()}`;
    const stored = this.meta('scope');
    if (stored !== scope) {
      if (stored) {
        this.logger.warn(
          `chain/factory changed (${stored} -> ${scope}); clearing indexed pools`,
        );
      }
      this.db.exec('DELETE FROM pools; DELETE FROM meta;');
      this.setMeta('scope', scope);
    }
  }

  onModuleDestroy() {
    this.db.close();
  }

  // ------------------------------------------------------------- indexer

  /// Last block whose logs have been applied, or undefined before the first pass.
  syncedBlock(): number | undefined {
    const v = this.meta('synced_block');
    return v === undefined ? undefined : Number(v);
  }

  setSyncedBlock(block: number) {
    this.setMeta('synced_block', String(block));
  }

  poolCount(): number {
    const row = this.db.prepare('SELECT COUNT(*) AS n FROM pools').get() as {
      n: number;
    };
    return row.n;
  }

  addresses(): Address[] {
    return (
      this.db.prepare('SELECT address FROM pools ORDER BY idx').all() as {
        address: Address;
      }[]
    ).map((r) => r.address);
  }

  insertPool(idx: number, snapshot: PoolSnapshot, block: number) {
    this.db
      .prepare(
        `INSERT INTO pools (address, idx, creator, quote_token, name, symbol, snapshot, updated_block)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (address) DO NOTHING`,
      )
      .run(
        snapshot.pool,
        idx,
        snapshot.creator,
        snapshot.quoteToken.address,
        snapshot.name,
        snapshot.symbol,
        JSON.stringify(snapshot),
        block,
      );
  }

  updateSnapshot(address: Address, snapshot: PoolSnapshot, block: number) {
    this.db
      .prepare(
        'UPDATE pools SET snapshot = ?, updated_block = ? WHERE address = ?',
      )
      .run(JSON.stringify(snapshot), block, address);
  }

  setLaunch(address: Address, block: number, tx: Hash, timestamp: number) {
    this.db
      .prepare(
        'UPDATE pools SET launch_block = ?, launch_tx = ?, launched_at = ? WHERE address = ?',
      )
      .run(block, tx, timestamp, address);
  }

  // ---------------------------------------------------------------- reads

  get(address: Address) {
    const row = this.db
      .prepare('SELECT * FROM pools WHERE address = ?')
      .get(address) as PoolRow | undefined;
    return row && toRecord(row);
  }

  /// Oldest launch first.
  list(offset: number, limit: number) {
    return (
      this.db
        .prepare('SELECT * FROM pools ORDER BY idx LIMIT ? OFFSET ?')
        .all(limit, offset) as unknown as PoolRow[]
    ).map(toRecord);
  }

  // ----------------------------------------------------------------- meta

  private meta(key: string): string | undefined {
    const row = this.db
      .prepare('SELECT value FROM meta WHERE key = ?')
      .get(key) as { value: string } | undefined;
    return row?.value;
  }

  private setMeta(key: string, value: string) {
    this.db
      .prepare(
        'INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      )
      .run(key, value);
  }
}

/// A stored pool as the API returns it: the snapshot plus where it came from.
function toRecord(row: PoolRow) {
  const snapshot = JSON.parse(row.snapshot) as PoolSnapshot;
  return {
    index: row.idx,
    ...snapshot,
    launch:
      row.launch_block === null
        ? null
        : {
            block: row.launch_block,
            txHash: row.launch_tx,
            timestamp: row.launched_at,
          },
    updatedBlock: row.updated_block,
  };
}
