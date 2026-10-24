# Allo

A coin launchpad on BNB Chain. Anyone launches a coin with one transaction; it trades on a linear
bonding curve (`y = -mx + b`) against BNB or an admin-approved ERC20, and once the curve sells out its
liquidity moves to PancakeSwap V2 and is locked forever.

- **[Functions.md](Functions.md)**: every contract function, grouped into public calls, internal helpers and getters.
- **[Endpoints.md](Endpoints.md)**: every backend endpoint, the contract function it calls, who sends it and its arguments.
- **[allo_contracts/Architecture.md](allo_contracts/Architecture.md)**: how a coin works end to end, without the code.

## Deployed contracts (BSC testnet, chain 97)

| Contract | Address |
|---|---|
| **PoolFactory**: the contract the backend calls | [`0xc44f16547b4c5fb6818281F9312bf63C959B6D18`](https://testnet.bscscan.com/address/0xc44f16547b4c5fb6818281F9312bf63C959B6D18) |
| BondingCurvePool implementation (every coin is a clone of it) | [`0x1F6713c6b2b429AAa89DD235ab29c5Cb2f6BD73A`](https://testnet.bscscan.com/address/0x1F6713c6b2b429AAa89DD235ab29c5Cb2f6BD73A) |
| PancakeSwap V2 factory (coins migrate here) | [`0x6725F303b657a9451d8BA641348b6761A6CC7a17`](https://testnet.bscscan.com/address/0x6725F303b657a9451d8BA641348b6761A6CC7a17) |
| WBNB | [`0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd`](https://testnet.bscscan.com/address/0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd) |

The factory was deployed in block `138672089`. It charges a 0.002 BNB launch fee, and coins paired
with BNB start at 0.00001 BNB. Each launched coin gets its own pool address, which the API returns.
`Address.md` holds the factory address; change it there, and in the backend's `FACTORY_ADDRESS`,
after a redeploy.

## Architecture

```
  Wallet / frontend / script                backend (NestJS, Docker)                 BNB Chain
  ┌──────────────────────────┐  GET /buy?…  ┌──────────────────────────────┐  reads  ┌──────────────────────┐
  │ scripts/menu.js (web3.js)│ ───────────► │ transaction endpoints        │ ──────► │ PoolFactory          │
  │ or any frontend          │ ◄─────────── │  quote + unsigned tx         │         │  └─ BondingCurvePool │
  │                          │ {approvals,  │                              │         │     (one per coin)   │
  │ signs + sends the tx     │ transaction} │ indexer ──► SQLite           │ ◄────── │  └─ PancakeSwap pair │
  │                          │              │  └► /pool-info endpoints     │   logs  │                      │
  └────────────┬─────────────┘              └──────────────────────────────┘         └──────────▲───────────┘
               │                                                                                │
               └────────────────────────────── signed transaction ──────────────────────────────┘
```

| Folder | What it is |
|---|---|
| [`allo_contracts/`](allo_contracts) | Solidity, built and tested with Foundry. **PoolFactory** launches coins as ERC-1167 clones and collects the platform's fees. **BondingCurvePool** is the coin itself: ERC20, bonding curve, buy/sell tax, the creator's tax split (creator / burn / buyback / holder rewards), and migration to PancakeSwap. **LinearCurveMath** holds the curve math. |
| [`backend/`](backend) | NestJS API. It **never signs**: each endpoint reads the chain, works out the arguments (price, slippage, tax, launch fee, ERC20 approvals) and returns unsigned transactions. A background indexer stores every launch and each pool's latest state in SQLite, which `/pool-info` and `/get-all-pool-info` serve. Full reference: [`backend/API.md`](backend/API.md). |
| [`scripts/`](scripts) | `menu.js`: an interactive client for every endpoint, and the reference for calling the backend (below). |
| `dockerfile` | Builds the backend image (API + indexer, SQLite in a volume). |

How a coin moves: **launch** → **trade** on the curve (price rises as coins are bought) →
**graduation** when the curve sells out → **migrate** to PancakeSwap. 80% of the supply is sold on
the curve; the other 20% is paired with the raised BNB/ERC20 on PancakeSwap.

## Running the backend

Settings come from the repo-root `.env` (copy [`.env.example`](.env.example)). With no `.env`, the
backend uses the testnet defaults above.

```bash
cd backend && npm install && cd ..
npm start          # or: yarn dev / npm run dev (restarts on code changes)
curl localhost:3000/health
```

In Docker:

```bash
docker build -t allo-backend .
docker run -d --name allo --env-file .env -e PORT=3018 -p 3018:3018 -v allo-data:/app/data allo-backend
curl localhost:3018/health
```

## Calling the backend: `scripts/menu.js`

[`scripts/menu.js`](scripts/menu.js) is the reference client. It calls each endpoint, shows the
quote, and on confirmation signs and sends with web3.js (approvals first, then the transaction),
printing the BscScan link. It has one menu entry per endpoint, including the admin ones.

```bash
cd scripts
cp .env.example .env    # RPC_URL, API_URL (the backend), ADMIN_PRIVATE_KEY, USER_PRIVATE_KEY
npm install
npm start               # or from the repo root: npm run menu
```

Every client follows the same three steps, so the same pattern works in any frontend:

```js
const q = new URLSearchParams({ pool, amountIn: '0.01', from: account });
const { approvals, transaction, quote } = await fetch(`${API_URL}/buy-exact-in?${q}`).then((r) => r.json());
// show `quote` to the user, then:
for (const tx of approvals) await web3.eth.sendTransaction(tx);
const receipt = await web3.eth.sendTransaction(transaction);
```

Passing `from` makes the backend dry-run the transaction as that address and fill in `gas`, so a call
that would fail comes back as a readable 400 instead of failing in the wallet.

## Endpoints at a glance

All `GET`, with arguments in the query string. Details and arguments are in [Endpoints.md](Endpoints.md).

| Group | Endpoints |
|---|---|
| Health | `/health` |
| PoolFactory | `/launch`, `/set-quote-token`, `/set-launch-fee`, `/claim-admin-fees`, `/transfer-ownership`, `/renounce-ownership` |
| BondingCurvePool | `/buy`, `/buy-exact-in`, `/sell`, `/migrate`, `/claim-creator-fees`, `/claim-rewards`, `/transfer`, `/transfer-from`, `/approve` |
| Read (from SQLite) | `/pool-info`, `/get-all-pool-info` |

## Contracts: build and test

```bash
cd allo_contracts
forge build
forge test
./script/deploy.sh bsc_testnet     # deploys PoolFactory; needs PRIVATE_KEY in allo_contracts/.env
```
