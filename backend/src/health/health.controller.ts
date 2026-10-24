import { Controller, Get, ServiceUnavailableException } from '@nestjs/common';
import { ChainService } from '../chain/chain.service.js';
import { PoolStore } from '../store/pool-store.service.js';

const RPC_TIMEOUT_MS = 3_000;
const startedAt = Date.now();

/// Liveness + readiness. 200 while the RPC answers; 503 (same body) when it doesn't, since
/// every transaction endpoint and the indexer depend on it.
@Controller()
export class HealthController {
  constructor(
    private readonly chain: ChainService,
    private readonly store: PoolStore,
  ) {}

  @Get('health')
  async health() {
    let headBlock: number | null = null;
    let rpcError: string | undefined;
    try {
      headBlock = Number(
        await Promise.race([
          this.chain.client.getBlockNumber(),
          new Promise<never>((_, reject) =>
            setTimeout(
              () => reject(new Error(`no answer in ${RPC_TIMEOUT_MS} ms`)),
              RPC_TIMEOUT_MS,
            ),
          ),
        ]),
      );
    } catch (err) {
      rpcError =
        err instanceof Error ? err.message.split('\n')[0] : String(err);
    }

    const syncedBlock = this.store.syncedBlock() ?? null;
    const body = {
      status: rpcError ? 'down' : 'ok',
      uptimeSeconds: Math.round((Date.now() - startedAt) / 1000),
      chainId: this.chain.chain.id,
      factory: this.chain.factoryAddress,
      rpc: rpcError ? { ok: false, error: rpcError } : { ok: true, headBlock },
      indexer: {
        enabled: process.env.INDEXER !== 'off',
        syncedBlock,
        // Blocks the SQLite data is behind the chain; null until both are known.
        lagBlocks:
          headBlock !== null && syncedBlock !== null
            ? Math.max(0, headBlock - syncedBlock)
            : null,
        pools: this.store.poolCount(),
      },
    };
    if (rpcError) throw new ServiceUnavailableException(body);
    return body;
  }
}
