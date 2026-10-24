import { BadRequestException, Injectable } from '@nestjs/common';
import {
  createPublicClient,
  defineChain,
  encodeFunctionData,
  erc20Abi,
  getContract,
  http,
  isAddressEqual,
  toHex,
  zeroAddress,
  type Address,
  type Chain,
  type GetContractReturnType,
  type Hex,
  type PublicClient,
  type Transport,
} from 'viem';
import { bsc, bscTestnet } from 'viem/chains';
import { bondingCurvePoolAbi, poolFactoryAbi } from './abis.js';

/// Factory deployed on BSC testnet (see Address.md), and the block it was deployed in.
const DEFAULT_FACTORY = '0xc44f16547b4c5fb6818281F9312bf63C959B6D18';
const DEFAULT_FACTORY_BLOCK = 138_672_089;
// publicnode serves eth_getLogs, which the indexer uses; BNB Chain's own dataseed nodes refuse it.
const DEFAULT_RPC = 'https://bsc-testnet-rpc.publicnode.com';

/// What the caller hands to web3.js / the wallet. Quantities are hex so it can also go
/// straight into an EIP-1193 `eth_sendTransaction` (MetaMask etc.) without conversion.
export interface UnsignedTx {
  from?: Address;
  to: Address;
  data: Hex;
  value: Hex;
  gas?: Hex;
}

/// Send every `approvals` entry first (in order), then `transaction`.
export interface TxResponse {
  chainId: number;
  approvals: UnsignedTx[];
  transaction: UnsignedTx;
  /// true when `transaction` was dry-run as `from`. It can't be while an approval is still unsent.
  simulated: boolean;
  quote: Record<string, unknown>;
}

type Client = PublicClient<Transport, Chain>;
export type FactoryContract = GetContractReturnType<
  typeof poolFactoryAbi,
  Client
>;
export type PoolContract = GetContractReturnType<
  typeof bondingCurvePoolAbi,
  Client
>;

/// What a coin trades against. Native BNB is the zero address.
export interface QuoteToken {
  address: Address;
  native: boolean;
  symbol: string;
  decimals: number;
}

@Injectable()
export class ChainService {
  readonly chain: Chain;
  readonly client: Client;
  readonly factoryAddress: Address;
  /// Where the indexer starts on its first run, if known: INDEXER_START_BLOCK, else the default
  /// factory's deploy block.
  readonly startBlock?: number;

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
    this.factoryAddress = (process.env.FACTORY_ADDRESS ??
      DEFAULT_FACTORY) as Address;
    this.startBlock = process.env.INDEXER_START_BLOCK
      ? Number(process.env.INDEXER_START_BLOCK)
      : isAddressEqual(this.factoryAddress, DEFAULT_FACTORY) &&
          chainId === bscTestnet.id
        ? DEFAULT_FACTORY_BLOCK
        : undefined;
  }

  factory(): FactoryContract {
    return getContract({
      address: this.factoryAddress,
      abi: poolFactoryAbi,
      client: this.client,
    });
  }

  pool(address: Address): PoolContract {
    return getContract({
      address,
      abi: bondingCurvePoolAbi,
      client: this.client,
    });
  }

  async quoteToken(address: Address): Promise<QuoteToken> {
    if (isAddressEqual(address, zeroAddress)) {
      return { address, native: true, symbol: 'BNB', decimals: 18 };
    }
    const token = getContract({ address, abi: erc20Abi, client: this.client });
    const [symbol, decimals] = await Promise.all([
      token.read.symbol(),
      token.read.decimals(),
    ]);
    return { address, native: false, symbol, decimals };
  }

  /// The quote's balance held by `holder`, native or ERC20.
  async balanceOf(token: QuoteToken, holder: Address): Promise<bigint> {
    return token.native
      ? this.client.getBalance({ address: holder })
      : this.client.readContract({
          address: token.address,
          abi: erc20Abi,
          functionName: 'balanceOf',
          args: [holder],
        });
  }

  /// `spender` pulls `needed` of an ERC20 quote from the sender, so an approve has to go first.
  /// With `owner` known, it is only returned when the current allowance falls short.
  async approvals(
    token: QuoteToken,
    owner: Address | undefined,
    spender: Address,
    needed: bigint,
  ): Promise<UnsignedTx[]> {
    if (token.native || needed === 0n) return [];
    if (owner) {
      const allowance = await this.client.readContract({
        address: token.address,
        abi: erc20Abi,
        functionName: 'allowance',
        args: [owner, spender],
      });
      if (allowance >= needed) return [];
    }
    const data = encodeFunctionData({
      abi: erc20Abi,
      functionName: 'approve',
      args: [spender, needed],
    });
    return [await this.buildTx({ to: token.address, data }, owner)];
  }

  /// Owner-only factory calls: reject a `from` that isn't the owner before the wallet does.
  async assertFactoryOwner(from: Address | undefined): Promise<Address> {
    const owner = await this.factory().read.owner();
    if (isAddressEqual(owner, zeroAddress)) {
      throw new BadRequestException(
        'the factory has no owner (ownership was renounced)',
      );
    }
    if (from && !isAddressEqual(from, owner)) {
      throw new BadRequestException(
        `only the factory owner ${owner} can send this`,
      );
    }
    return owner;
  }

  /// Packs a call into an unsigned transaction. With `from` (and `simulate`), it is dry-run as
  /// that account first, so a call that would revert fails here (ChainErrorFilter turns it into
  /// a 400) instead of in the user's wallet, and the gas limit is filled in.
  async buildTx(
    tx: { to: Address; data: Hex; value?: bigint },
    from?: Address,
    simulate = true,
  ): Promise<UnsignedTx> {
    const value = tx.value ?? 0n;
    let gas: bigint | undefined;
    if (from && simulate) {
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

  /// The main transaction can only be dry-run once its approvals are on-chain.
  async respond(
    tx: { to: Address; data: Hex; value?: bigint },
    from: Address | undefined,
    quote: Record<string, unknown>,
    approvals: UnsignedTx[] = [],
  ): Promise<TxResponse> {
    const simulate = approvals.length === 0;
    return {
      chainId: this.chain.id,
      approvals,
      transaction: await this.buildTx(tx, from, simulate),
      simulated: Boolean(from) && simulate,
      quote,
    };
  }
}
