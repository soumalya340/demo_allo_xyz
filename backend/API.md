# Transaction API

The backend never signs anything. Each endpoint reads the chain, works out the contract arguments
(price, slippage, tax, launch fee, approvals), and returns **unsigned transactions**. The caller signs
and sends them with web3.js, a browser wallet, or a private key.

There is one endpoint for every public function a user or the admin can call (`Functions.md`,
section 1), plus `/pool-info`. All endpoints are `GET`, with arguments in the query string.

Functions with no endpoint, because no user calls them directly:
- `initialize` and `firstBuy`: only the factory calls these. For the first buy, use
  `firstBuyAmount` on `/launch`.
- the constructors and `receive`: these run on their own.

## Running

```bash
npm install
npm run build
RPC_URL=... CHAIN_ID=97 FACTORY_ADDRESS=0x... npm run start:prod
```

| Env               | Default                                            |
| ----------------- | -------------------------------------------------- |
| `RPC_URL`         | `https://bsc-testnet-rpc.publicnode.com`           |
| `CHAIN_ID`        | `97` (BSC testnet)                                 |
| `FACTORY_ADDRESS` | `0xc44f16547b4c5fb6818281F9312bf63C959B6D18` (see `Address.md`) |
| `PORT`            | `3000`                                             |
| `DB_PATH`         | `data/allo.sqlite` (relative to the working directory) |
| `INDEXER_START_BLOCK` | the default factory's deploy block (`138672089`); for any other factory, the current head on first run. Set it to your factory's deploy block to record every launch's block / tx |
| `INDEXER_INTERVAL_MS` | `3000`: pause between passes once caught up      |
| `INDEXER_LOG_RANGE`   | `5000`: most blocks per `eth_getLogs`            |
| `INDEXER_USE_LOGS`    | `true`; `false` forces polling mode (see below)  |
| `INDEXER`             | set to `off` to stop updating SQLite             |

CORS is open, so browser frontends can call the API directly.

## Indexer and SQLite

`/pool-info` and `/get-all-pool-info` are served from SQLite (Node's built-in `node:sqlite`; no extra
dependency). A background indexer, started with the server, keeps it in step with the chain. The
transaction endpoints always read the chain live.

Each pass of the indexer:

1. **Finds new launches**: compares the factory's `poolCount()` with the database and saves each new
   pool from `allPools(i)`. This needs nothing special from the RPC, so no launch is missed.
2. **Follows changes**: reads `eth_getLogs` for the factory and every pool over the next block range.
   A `PoolCreated` log records the launch block, tx hash and time. Any log from a pool (a trade,
   claim, transfer or migration) means its state changed, so its snapshot is re-read from the chain.

Reads are a few seconds behind the chain. Every read response has `syncedBlock`, the last block
applied, and every pool has `updatedBlock`, the head when its snapshot was taken.

**RPCs without logs.** BNB Chain's own `data-seed-*.bnbchain.org` nodes refuse `eth_getLogs`
entirely. The indexer halves its range on each refusal. If even one block is refused, it switches to
**polling mode**: it re-reads every pool on every pass, and `launch` stays `null`. It logs a warning
when that happens. Use an RPC that serves logs (the default publicnode one does) to avoid it.

The database belongs to one chain + factory. If `CHAIN_ID` or `FACTORY_ADDRESS` changes, the old rows
are cleared and indexing starts again.

Tables: `pools` (one row per launch: `address`, `idx`, `creator`, `quote_token`, `name`, `symbol`,
`launch_block`, `launch_tx`, `launched_at`, the JSON `snapshot` and `updated_block`) and `meta`
(sync progress).

## Health

`GET /health` reports whether the server can do its job:

```jsonc
{
  "status": "ok",                 // "down" when the RPC doesn't answer
  "uptimeSeconds": 3600,
  "chainId": 97,
  "factory": "0x…",
  "rpc": { "ok": true, "headBlock": 138680000 },   // or { "ok": false, "error": "…" }
  "indexer": { "enabled": true, "syncedBlock": 138679998, "lagBlocks": 2, "pools": 1 }
}
```

It returns **200** while the RPC answers (within 3 s), and **503** with the same body when it doesn't,
since every transaction endpoint and the indexer need it. `lagBlocks` is how far the SQLite data is
behind the chain.

## Conventions

- **Amounts are human decimals.** Coins (pool tokens) have 18 decimals. Quote amounts (prices,
  `amountIn`, `graduationThreshold`, `firstBuyAmount`, fees) use the quote token's own decimals, so
  `amountIn=100` on a USDC-quoted pool means 100 USDC.
- **Quote token**: an omitted value, `native`, `bnb` or the zero address all mean native BNB.
  Anything else is an ERC20 address the admin has allowed.
- **`slippageBps`** (buy/sell): basis points, default `100` (1%), max `5000`.
- **`from`** (optional on every transaction endpoint): the address that will send the transaction.
  When it is given, the API checks balances and allowances, dry-runs the call as that address and
  fills in `gas`. Anything that would revert fails here with a readable error instead of in the
  wallet. Pass it whenever you know the sender.
- Only pools created by the configured factory are accepted.

### Response

```jsonc
{
  "chainId": 97,
  "approvals": [ /* UnsignedTx, send these first, in order */ ],
  "transaction": {
    "from": "0x…",   // only if you passed `from`
    "to": "0x…",
    "data": "0x…",
    "value": "0x…",  // hex wei
    "gas": "0x…"     // only when simulated
  },
  "simulated": true, // the transaction was dry-run as `from`
  "quote": { … }     // what the transaction will do; differs per endpoint
}
```

Every amount in `quote` looks like `{ "raw": "1500000", "formatted": "1.5" }`. A `quoteToken` object
(`address`, `native`, `symbol`, `decimals`) says which units the quote amounts are in.

**`approvals`** is only non-empty when an **ERC20 quote** has to be pulled from the sender: buying on
an ERC20 pool (approve the pool), or a first buy on a new ERC20 coin (approve the factory). It
approves the exact amount needed. With `from`, it is left out when the current allowance already
covers it; without `from`, it is always included. While an approval is still unsent the main
transaction can't be dry-run, so then `simulated` is `false` and there is no `gas`, and the wallet
estimates gas when it sends.

`transaction` uses hex quantities, so it works as-is with both web3.js and a raw EIP-1193 wallet
(`window.ethereum.request({ method: 'eth_sendTransaction', params: [tx] })`).

### Errors

| Status | When                                                                                                                                                            |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `400`  | Bad or missing arguments; the pool's state doesn't allow it; `from` lacks the balance, allowance or role; the dry run reverted (`error` is the Solidity error name, e.g. `SlippageExceeded`) |
| `502`  | The RPC node failed                                                                                                                                             |

## Sending

```js
import { Web3 } from 'web3';

// Script: sign with a key.        Frontend: const web3 = new Web3(window.ethereum);
const web3 = new Web3(RPC_URL);
const from = web3.eth.accounts.wallet.add(PRIVATE_KEY)[0].address;

const q = new URLSearchParams({ pool, amountIn: '0.1', from });
const { approvals, transaction, quote } = await fetch(`${API}/buy-exact-in?${q}`).then((r) => r.json());

// show `quote` to the user, then:
for (const tx of approvals) await web3.eth.sendTransaction(tx);
const receipt = await web3.eth.sendTransaction(transaction);
```

If you call without `from`, add it yourself before sending: `{ ...transaction, from }`.

## PoolFactory endpoints

### `GET /launch`: `createPool(params, firstBuyAmount)`

| Param                              | Required | Notes                                                                 |
| ---------------------------------- | -------- | --------------------------------------------------------------------- |
| `name`, `symbol`                   | yes      |                                                                       |
| `imageUrl`, `website`, `twitter`, `description` | no | default empty                                          |
| `quoteToken`                       | no       | default BNB; must be allowed by the admin                             |
| `buyFeeBps`, `sellFeeBps`          | yes      | `0`–`1000` (100 = 1%)                                                 |
| `creatorBps`, `burnBps`, `buybackBps`, `holdersBps` | no | how the tax left after the platform's 20% is split; each defaults to 0, and together they must add up to `10000` |
| `totalSupply`                      | yes      | whole coins, e.g. `1000000`                                           |
| `graduationThreshold`              | yes      | quote the curve raises when it sells out                              |
| `firstBuyAmount`                   | no       | quote to spend on the creator's tax-free first buy, in the same transaction |
| `from`                             | no       | becomes the creator                                                   |

`value` is the launch fee (BNB) plus `firstBuyAmount` on a BNB coin. On an ERC20 coin with a first
buy, `approvals` approves the factory for `firstBuyAmount`. The new pool's address is in the
`PoolCreated` event of the receipt (`topics[1]`).

### `GET /set-quote-token?token=&startPrice=`: `setQuoteToken`, admin only

Allows an ERC20 as a quote token at `startPrice` (in that token, per coin), changes its price, or
removes it with `startPrice=0`. `token=native` reprices BNB. Existing pools are unaffected.

### `GET /set-launch-fee?launchFee=`: `setLaunchFee`, admin only

The flat BNB fee per launch (`0` allowed).

### `GET /claim-admin-fees?token=&to=`: `withdrawFees(token, to)`, admin only

Withdraws the platform's collected fees in one token: BNB by default (launch fees plus the 20% share of
BNB tax), or an ERC20 quote. `to` defaults to the owner. Returns a 400 if there is nothing to withdraw.

### `GET /transfer-ownership?newOwner=`: admin only

### `GET /renounce-ownership?confirm=true`: admin only

This is permanent: afterwards nobody can withdraw fees or change settings. It requires `confirm=true`.

## BondingCurvePool endpoints

All take `pool`. Trading endpoints return a 400 once the pool has graduated, with the PancakeSwap
pair address in the message.

### `GET /buy?pool=&tokenAmount=`: `buy(amount, maxIn)`

Buys an exact number of coins. `maxIn` is the quoted cost plus tax plus slippage. On a BNB pool that
is the `value`, and the unused part is refunded. On an ERC20 pool the pool pulls exactly the cost
(after the approval). If fewer coins are left than asked for, `quote.partialFill` is `true` and the
transaction buys what's left.

### `GET /buy-exact-in?pool=&amountIn=`: `buyExactIn(amountIn, minTokensOut)`

Spends `amountIn` of quote (tax included) on as many coins as it buys. `quote.tokensOut` is the
expected output and `minTokensOut` is the slippage floor. `quote.completesCurve` is `true` when the
buy sells out the curve; anyone can then `/migrate`.

### `GET /sell?pool=&tokenAmount=`: `sell(amount, minQuoteOut)`

No approval is needed, because the pool is the coin. `quote.quoteOut` is the expected amount after
the sell tax and `minQuoteOut` is the slippage floor.

### `GET /migrate?pool=`: `migrate()`

Anyone may send it, once graduated. It moves the raised quote and the 20% coin allocation into
PancakeSwap, burns the LP tokens, and spends leftover burn/buyback tax on the new pair.

### `GET /claim-creator-fees?pool=`: `claimCreatorFees()`

Anyone may send it; the quote always goes to the creator.

### `GET /claim-rewards?pool=&from=`: `claimRewards()`

Pays the **sender** their share of the holder-rewards tax. Pass `from` to see the amount: you get a
400 if they have nothing to claim.

### `GET /transfer?pool=&to=&amount=`: ERC20 `transfer`

### `GET /transfer-from?pool=&owner=&to=&amount=`: ERC20 `transferFrom`

`from` is the approved spender who sends it, and `owner` is whose coins move.

### `GET /approve?pool=&spender=&amount=`: ERC20 `approve`

`amount` can be `max`, or `0` to revoke.

Before migration, coins can't be sent to the PancakeSwap pair. `/transfer` and `/transfer-from`
reject that.

### `GET /pool-info?pool=&holder=`

Read-only, from SQLite, so there is no `transaction`. It returns the metadata (links and
`description`), quote token, buy/sell tax, tax allocation, supplies, curve progress, prices,
`quoteReserve`, creator fees, burn/buyback buckets, `buybackHeld`, reward totals, `graduated` /
`migrated` and `pair`. It also returns `index` (position in the factory), `launch` (`{ block, txHash,
timestamp }`, or `null` if not seen), `updatedBlock` and `syncedBlock`.

With `holder`, it adds their coin balance and `pendingRewards`. These are read live from the chain,
since per-holder numbers aren't indexed.

It returns a **404** if the pool isn't in the database: either it's not a pool of this factory, or it
launched in the last few seconds.

### `GET /get-all-pool-info?offset=&limit=&holder=`

Read-only, from SQLite. It returns the `/pool-info` record of every indexed pool, oldest first. All
pools come back by default; `offset` and `limit` page through them, and `total` is the number
indexed. `holder` works as it does on `/pool-info` (live).

```jsonc
{ "chainId": 97, "factory": "0x…", "syncedBlock": 1234567, "total": 42, "offset": 0, "count": 42,
  "pools": [ { "index": 0, "pool": "0x…", …, "launch": { "block": 1230001, "txHash": "0x…", "timestamp": 1792841816 }, "updatedBlock": 1234560 } ] }
```

## ABIs

`src/chain/abis.ts` is generated from `allo_contracts/out` (`forge build`). Regenerate it after
changing the contracts.
