# GET METHODS

All endpoints are `GET`, with arguments in the query string. Every endpoint except `/pool-info` returns
`{ chainId, approvals, transaction, simulated, quote }`: send each `approvals` entry first, then
`transaction`. `from` (optional everywhere) is the sender; with it the call is dry-run and `gas` is filled in.
Full details: `backend/API.md`.

## Health

| Endpoint | Returns |
|---|---|
| `/health` | `status` (`ok` / `down`), `uptimeSeconds`, `chainId`, `factory`, `rpc` (`headBlock` or `error`), `indexer` (`syncedBlock`, `lagBlocks`, `pools`). **200** when the RPC answers, **503** (same body) when it doesn't |

## PoolFactory

| # | Endpoint | Contract function | Who sends it | Args (* = required) |
|---|---|---|---|---|
| 1 | `/launch` | `createPool(params, firstBuyAmount)` | Anyone (becomes creator) | `name`*, `symbol`*, `buyFeeBps`*, `sellFeeBps`*, `totalSupply`*, `graduationThreshold`*, `imageUrl`, `website`, `twitter`, `description`, `quoteToken` (default BNB), `creatorBps`, `burnBps`, `buybackBps`, `holdersBps` (must add up to 10000), `firstBuyAmount`, `from` |
| 2 | `/set-quote-token` | `setQuoteToken(token, startPrice)` | Admin | `token`*, `startPrice`* (0 = remove), `from` |
| 3 | `/set-launch-fee` | `setLaunchFee(launchFee)` | Admin | `launchFee`* (BNB), `from` |
| 4 | `/claim-admin-fees` | `withdrawFees(token, to)` | Admin | `token` (default BNB), `to` (default owner), `from` |
| 5 | `/transfer-ownership` | `transferOwnership(newOwner)` | Admin | `newOwner`*, `from` |
| 6 | `/renounce-ownership` | `renounceOwnership()` | Admin | `confirm=true`*, `from` |

## BondingCurvePool

| # | Endpoint | Contract function | Who sends it | Args (* = required) |
|---|---|---|---|---|
| 7 | `/buy` | `buy(amount, maxIn)` | Anyone | `pool`*, `tokenAmount`*, `slippageBps` (default 100), `from` |
| 8 | `/buy-exact-in` | `buyExactIn(amountIn, minTokensOut)` | Anyone | `pool`*, `amountIn`*, `slippageBps`, `from` |
| 9 | `/sell` | `sell(amount, minQuoteOut)` | Any holder | `pool`*, `tokenAmount`*, `slippageBps`, `from` |
| 10 | `/migrate` | `migrate()` | Anyone, after graduation | `pool`*, `from` |
| 11 | `/claim-creator-fees` | `claimCreatorFees()` | Anyone (pays the creator) | `pool`*, `from` |
| 12 | `/claim-rewards` | `claimRewards()` | Any holder | `pool`*, `from` |
| 13 | `/transfer` | `transfer(to, amount)` | Any holder | `pool`*, `to`*, `amount`*, `from` |
| 14 | `/transfer-from` | `transferFrom(owner, to, amount)` | Approved spender | `pool`*, `owner`*, `to`*, `amount`*, `from` |
| 15 | `/approve` | `approve(spender, amount)` | Any holder | `pool`*, `spender`*, `amount`* (`max` or `0` allowed), `from` |

## Read-only (served from SQLite, kept current by the backend's indexer)

| # | Endpoint | Returns | Args |
|---|---|---|---|
| 16 | `/pool-info` | Indexed pool record (404 if unknown): `index`, `launch` (block / tx / time), `updatedBlock`, `syncedBlock`, and all pool state: metadata (links, description), quote token, taxes, tax allocation, supplies, progress, prices, reserve, fees, buckets, rewards, graduated/migrated, pair | `pool`*, `holder` (adds balance + pending rewards, read live) |
| 17 | `/get-all-pool-info` | The `/pool-info` record of every indexed pool, oldest first; plus `syncedBlock`, `total` (pools indexed), `offset`, `count` | `offset` (default 0), `limit` (default all), `holder` |
