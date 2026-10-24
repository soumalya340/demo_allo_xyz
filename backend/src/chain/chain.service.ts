import { Injectable } from '@nestjs/common';
import {
  createPublicClient,
  defineChain,
  http,
  toHex,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
} from 'viem';
import { bsc, bscTestnet } from 'viem/chains';

/// Factory deployed on BSC testnet (see Address.md).
const DEFAULT_FACTORY = '0x9F47e969D6012f37916F8Abc21E6E7c9b8d026BF';
const DEFAULT_RPC = 'https://data-seed-prebsc-1-s1.bnbchain.org:8545';

/// What the caller hands to web3.js / the wallet. Quantities are hex so it can also go
/// straight into an EIP-1193 `eth_sendTransaction` (MetaMask etc.) without conversion.
export interface UnsignedTx {
  from?: Address;
  to: Address;
  data: Hex;
  value: Hex;
  gas?: Hex;
}

@Injectable()
export class ChainService {
  readonly chain: Chain;
  readonly client: PublicClient<Transport, Chain>;
  readonly factory: Address;

  constructor() {
    const chainId = Number(process.env.CHAIN_ID ?? bscTestnet.id);
    const rpcUrl = process.env.RPC_URL ?? DEFAULT_RPC;
    this.chain =
      [bsc, bscTestnet].find((c) => c.id === chainId) ??
      defineChain({
        id: chainId,
        name: `chain-${chainId}`,
        nativeCurrency: { name: 'BNB', symbol: 'BNB', decimals: 18 },
        rpcUrls: { default: { http: [rpcUrl] } },
      });
    this.client = createPublicClient({
      chain: this.chain,
      transport: http(rpcUrl, { batch: true }),
    });
    this.factory = (process.env.FACTORY_ADDRESS ?? DEFAULT_FACTORY) as Address;
  }

  /// Packs a call into an unsigned transaction. With `from`, it is dry-run as that account
  /// first, so a call that would revert fails here (ChainErrorFilter turns it into a 400)
  /// instead of in the user's wallet, and the gas limit is filled in.
  async buildTx(
    tx: { to: Address; data: Hex; value?: bigint },
    from?: Address,
  ): Promise<UnsignedTx> {
    const value = tx.value ?? 0n;
    let gas: bigint | undefined;
    if (from) {
      await this.client.call({ account: from, ...tx, value });
      gas = await this.client.estimateGas({ account: from, ...tx, value });
    }
    return {
      ...(from && { from }),
      to: tx.to,
      data: tx.data,
      value: toHex(value),
      ...(gas !== undefined && { gas: toHex(gas) }),
    };
  }
}
