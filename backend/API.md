# Transaction API

The backend never signs anything. Each endpoint reads the chain, works out the contract arguments
(price, slippage, fees), and returns an **unsigned transaction**. The caller signs and sends it
with web3.js, a browser wallet, or a private key.

All endpoints are `GET`. Arguments go in the query string.

## Running

```bash
npm install
npm run build
RPC_URL=... CHAIN_ID=97 FACTORY_ADDRESS=0x... npm run start:prod
```

| Env               | Default                                            |
| ----------------- | -------------------------------------------------- |
| `RPC_URL`         | `https://data-seed-prebsc-1-s1.bnbchain.org:8545` |
| `CHAIN_ID`        | `97` (BSC testnet)                                 |
| `FACTORY_ADDRESS` | `0x9F47e969D6012f37916F8Abc21E6E7c9b8d026BF`       |
| `PORT`            | `3000`                                             |

CORS is open, so browser frontends can call the API directly.

## Conventions

- **Amounts are human decimals**: `bnbAmount=0.5`, `tokenAmount=1000`. BNB and every pool token
  have 18 decimals.
- **`slippageBps`** (buy/sell): basis points, default `100` (1%), max `5000`.
- **`from`** (optional on every transaction endpoint): the address that will send the transaction.
  When it is given, the API dry-runs the call as that address and fills in `gas`, so anything that
  would revert fails here with a readable error instead of in the wallet. Pass it whenever you
  know the sender.
- Only pools created by the configured factory are accepted.

### Response

```jsonc
{
  "chainId": 97,
  "transaction": {
    "from": "0x…",   // only if you passed `from`
    "to": "0x…",
    "data": "0x…",
    "value": "0x…",  // hex wei
    "gas": "0x…"     // only if you passed `from`
  },
  "quote": { … }     // what the transaction will do; differs per endpoint
}
```

Every amount in `quote` looks like `{ "raw": "1500000000000000000", "formatted": "1.5" }`.

`transaction` uses hex quantities, so it works as-is with both web3.js and a raw EIP-1193 wallet
(`window.ethereum.request({ method: 'eth_sendTransaction', params: [tx] })`).

### Errors

| Status | When                                                                                                                                           |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `400`  | Bad or missing arguments; the pool's state doesn't allow it; the dry run reverted (`error` is the Solidity error name, e.g. `SlippageExceeded`); `from` lacks BNB |
| `502`  | The RPC node failed                                                                                                                            |

## Sending a transaction

### web3.js with a private key (scripts)

```js
import { Web3 } from 'web3';

const web3 = new Web3(RPC_URL);
const account = web3.eth.accounts.wallet.add(PRIVATE_KEY)[0];

const q = new URLSearchParams({ pool, bnbAmount: '0.1', from: account.address });
const { transaction, quote } = await fetch(`${API}/buy?${q}`).then((r) => r.json());

const receipt = await web3.eth.sendTransaction(transaction); // signed locally with the wallet key
```

### web3.js with a browser wallet (frontends)

```js
const web3 = new Web3(window.ethereum);
const [from] = await web3.eth.requestAccounts();

const q = new URLSearchParams({ pool, tokenAmount: '500', from });
const { transaction, quote } = await fetch(`${API}/sell?${q}`).then((r) => r.json());
// show `quote` to the user, then:
const receipt = await web3.eth.sendTransaction(transaction); // wallet pops up to sign
```

If you call without `from`, add it yourself before sending: `{ ...transaction, from }`.

## Endpoints

### `GET /create-pool-transaction`

Launches a coin through `PoolFactory.createPool`.

| Param                 | Required | Notes                                                    |
| --------------------- | -------- | -------------------------------------------------------- |
| `name`, `symbol`      | yes      |                                                          |
| `imageUrl`, `website`, `twitter` | no | default empty                                     |
| `feeBps`              | yes      | trading fee, `0`–`1000` (100 = 1%)                       |
| `totalSupply`         | yes      | whole tokens, e.g. `1000000`                             |
| `graduationThreshold` | yes      | BNB the curve raises when it sells out, e.g. `4.2`       |
| `from`                | no       | becomes the pool's creator                               |

`graduationThreshold` must exceed `startPrice × 80% of totalSupply`. Otherwise you get a 400 that
names the minimum.

`quote`: `curveSupply`, `dexSupply`, `startPrice`, `endPrice`, … The new pool's address is in the
`PoolCreated` event of the receipt (`topics[1]`).

### `GET /buy`

| Param                        | Required | Notes                                                    |
| ---------------------------- | -------- | -------------------------------------------------------- |
| `pool`                       | yes      |                                                          |
| `bnbAmount` **or** `tokenAmount` | one of | see below                                              |
| `slippageBps`, `from`        | no       |                                                          |

- **`bnbAmount`**: spend exactly this much BNB (fee included) via `buyWithEth`. `quote.tokensOut`
  is the expected output and `quote.minTokensOut` is what slippage still accepts.
- **`tokenAmount`**: buy this many tokens via `buy`. `value` is the quoted cost plus slippage, and
  the contract refunds whatever isn't used. Near the end of the curve fewer tokens may be left than
  asked for; then `quote.partialFill` is `true` and the transaction buys what is left.

`quote.completesCurve` is `true` when this buy sells out the curve: the pool graduates and anyone
can then call `/migrate`. Buying from a graduated pool returns a 400 that gives the PancakeSwap
pair address.

### `GET /sell`

| Param                 | Required | Notes          |
| --------------------- | -------- | -------------- |
| `pool`, `tokenAmount` | yes      |                |
| `slippageBps`, `from` | no       |                |

No `approve` is needed, because the pool contract is the token. `quote.bnbOut` is the expected BNB
after the fee and `quote.minBnbOut` is the slippage floor.

### `GET /pool-info?pool=0x…`

Read-only, so there is no `transaction`. It returns the name, symbol, creator, links, `feeBps`,
supplies, `curveTokensLeft`/`curveTokensSold`, `progressPercent`, `bnbReserve`, `startPrice` /
`currentPrice` / `endPrice` (wei per whole token), unclaimed `creatorFees`, `graduated`,
`migrated` and the PancakeSwap `pair`.

### `GET /claim-creator-fees?pool=0x…`

Builds `claimCreatorFees()`. Anyone may send it, but the BNB always goes to the pool's creator.
Returns a 400 if there is nothing to claim.

### `GET /claim-admin-fees`

Builds `PoolFactory.withdrawFees(to)`, which sends the factory's accumulated 20% fee share. Only the
factory owner can send it: passing any other address as `from` gets a 400. `to` defaults to the
owner. Returns a 400 if the factory holds nothing.

### `GET /migrate?pool=0x…`

Builds `migrate()` once the curve has sold out: it moves the raised BNB and the 20% DEX allocation
into PancakeSwap, and the LP tokens are burned. Anyone may send it. Returns a 400 before graduation
or after migration.

## ABIs

`src/chain/abis.ts` is generated from `allo_contracts/out`. Regenerate it after changing the contracts.
