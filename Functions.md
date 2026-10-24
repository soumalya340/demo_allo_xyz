# Functions

Every function in `src/`, grouped by how it's used.

- **PoolFactory** (`src/PoolFactory.sol`): launches coins and collects the platform's fees.
- **BondingCurvePool** (`src/Pool.sol`): one per coin. It is the coin's ERC20, its bonding curve and its PancakeSwap migration.
- **LinearCurveMath** (`src/LinearCurveMath.sol`): the maths for the `y = -mx + b` curve.

"Quote" means the token a coin trades against: native BNB, or an admin-approved ERC20 such as USDT.

---

## 1. Public callable (functions that change state)

### PoolFactory

| Function | Who can call | What it does |
|---|---|---|
| `constructor(admin, pancakeFactory, wbnb, nativeStartPrice, launchFee)` | Deployer, once | Deploys the pool template, stores the PancakeSwap/WBNB addresses, allows BNB as a quote token and sets the launch fee |
| `createPool(params, firstBuyAmount)` | Anyone | Launches a new coin as a minimal-proxy clone, charges the launch fee and optionally makes the creator's tax-free first buy |
| `setQuoteToken(token, startPrice)` | Admin (owner) | Allows an ERC20 as a quote token with its launch price, changes the price, or removes the token (price 0); existing pools are unaffected |
| `setLaunchFee(launchFee)` | Admin (owner) | Changes the flat BNB fee charged on each launch |
| `withdrawFees(token, to)` | Admin (owner) | Sends the platform's collected fees in one token (`address(0)` = BNB) to an address |
| `transferOwnership(newOwner)` | Admin (owner) | Hands the admin role to another address (inherited from OpenZeppelin `Ownable`) |
| `renounceOwnership()` | Admin (owner) | Gives up the admin role for good (inherited from `Ownable`) |
| `receive()` | Pools | Accepts the platform's 20% share of BNB tax sent by pools |

### BondingCurvePool

| Function | Who can call | What it does |
|---|---|---|
| `constructor()` | Factory, once | Locks the template contract so only clones can be initialized |
| `initialize(params, creator, startPrice)` | Factory, once per clone | Sets up the coin (name, metadata links and description, quote token, taxes, tax allocation, curve) and mints the full supply to the pool |
| `buy(amount, maxIn)` | Anyone | Buys an exact number of coins for at most `maxIn` quote including tax; partial fill at the end of the curve |
| `buyExactIn(amountIn, minTokensOut)` | Anyone | Spends up to `amountIn` quote on as many coins as it buys, receiving at least `minTokensOut`; partial fill at the end of the curve |
| `sell(amount, minQuoteOut)` | Any holder | Sells coins back to the curve for at least `minQuoteOut` after the sell tax |
| `firstBuy(amountIn)` | Factory only | The creator's tax-free first buy, made in the same transaction that creates the pool |
| `migrate()` | Anyone, after graduation | Creates the PancakeSwap pair, adds the 20% coin allocation plus the raised quote as permanently locked liquidity, then spends the leftover burn/buyback tax there |
| `claimRewards()` | Any holder | Pays the caller their share of the holder-rewards tax, in quote |
| `claimCreatorFees()` | Anyone (always pays the creator) | Sends the creator's accumulated share of the tax to the creator |
| `transfer(to, amount)` | Any holder | Standard ERC20 transfer (inherited); can't send to the PancakeSwap pair before migration |
| `transferFrom(from, to, amount)` | Approved spender | Standard ERC20 transfer on someone's behalf (inherited); same pair rule |
| `approve(spender, amount)` | Any holder | Standard ERC20 approval (inherited) |

---

## 2. Internal (helper functions)

### PoolFactory

| Function | What it does |
|---|---|
| `_setQuoteToken(token, startPrice)` | Stores a quote token's launch price and emits `QuoteTokenSet`; used by the constructor and `setQuoteToken` |

### BondingCurvePool

| Function | What it does |
|---|---|
| `_pairToken()` | Returns the token the coin pairs with on PancakeSwap: WBNB for BNB coins, otherwise the quote ERC20 |
| `_predictPair()` | Calculates the PancakeSwap pair address before the pair exists (the address is deterministic, via CREATE2) |
| `_buy(filled, cost, fee, wanted, maxIn)` | Shared logic for `buy` and `buyExactIn`: checks payment and per-token price, takes payment, sends coins, applies tax, spends buckets and refunds any unused BNB |
| `_buyFromCurve(budget)` | Buys as many coins as `budget` covers with no tax; used by the first buy, burns and buybacks |
| `_graduateIfSoldOut()` | Marks the pool graduated once every curve coin is sold |
| `_takeFee(fee)` | Splits a trade's tax: 20% to the platform, the rest across creator / burn / buyback / holders per the creator's allocation |
| `_spendBuckets()` | At the end of each trade, spends the burn bucket (buy and destroy) and the buyback bucket (buy and keep) on the curve |
| `_spendBucketsOnPancake(pairToken)` | During migration, swaps the leftover burn + buyback tax for coins on the PancakeSwap pair, burns the burn share and keeps the rest |
| `_payPair(pairToken, amount)` | Sends quote to the PancakeSwap pair, wrapping BNB into WBNB first |
| `_addRewards(amount)` | Shares a holder-rewards amount across all eligible holders by balance, or parks it if nobody holds yet |
| `_settle(holder)` | Records what a holder has earned since their last update, before their balance changes |
| `_noRewards(account)` | True for addresses that never earn rewards: the pool, the pair, the dead address and the zero address |
| `_update(from, to, value)` | Runs on every transfer, mint and burn: blocks sending to the pair before migration and settles both sides' rewards (overrides ERC20) |
| `_collect(maxIn, total)` | Takes payment for a buy: checks `msg.value` for BNB, or pulls exactly `total` of an ERC20 |
| `_send(to, amount)` | Pays out quote, as BNB or as the ERC20 |

### LinearCurveMath (library, all internal)

| Function | What it does |
|---|---|
| `endPrice(threshold, startPrice, curveSupply)` | Works out the end price `b` that makes selling the whole curve raise exactly the graduation threshold |
| `priceAt(b, startPrice, curveSupply, x)` | Spot price when `x` coins are left on the curve: `b - m·x` |
| `buyCost(b, startPrice, curveSupply, x0, x1)` | Quote needed to buy the coins between `x1` and `x0` left on the curve (area under the line), rounded up |
| `sellRefund(b, startPrice, curveSupply, x0, x1)` | Quote returned for selling those coins back, rounded down |
| `tokensForCost(b, startPrice, curveSupply, x, budget)` | Most coins a quote budget can buy (the curve maths solved in reverse), rounded down |
| `_area(b, startPrice, curveSupply, x0, x1, rounding)` | Shared area-under-the-curve calculation behind `buyCost` and `sellRefund` |

---

## 3. Getters (read-only)

### PoolFactory

| Getter | What it returns |
|---|---|
| `poolCount()` | How many coins have been launched |
| `allPools(i)` | The address of the i-th launched pool |
| `startPriceOf(token)` | A quote token's launch price per coin (0 = not allowed; `address(0)` = BNB) |
| `launchFee()` | The current flat BNB fee per launch |
| `implementation()` | The pool template every clone points to |
| `pancakeFactory()` | The PancakeSwap V2 factory pools migrate into |
| `wbnb()` | The WBNB token address |
| `pairInitCodeHash()` | PancakeSwap's pair init-code hash, used to predict pair addresses |
| `NATIVE()` | `address(0)`, meaning native BNB |
| `owner()` | The admin address (inherited from `Ownable`) |

### BondingCurvePool: quotes and calculated values

| Getter | What it returns |
|---|---|
| `currentPrice()` | The current price of one coin on the curve, in quote |
| `getBuyQuote(amount)` | For buying `amount` coins: how many would actually fill, the curve cost and the buy tax |
| `getBuyQuoteExactIn(amountIn)` | For spending `amountIn` quote: how many coins it buys, the curve cost and the buy tax |
| `getSellQuote(amount)` | For selling `amount` coins: the curve refund and the sell tax |
| `pendingRewards(holder)` | Holder rewards an address can claim right now |

### BondingCurvePool: coin settings (fixed at launch)

| Getter | What it returns |
|---|---|
| `factory()` | The factory that created this pool |
| `creator()` | The coin's creator |
| `quoteToken()` | What the coin trades against (`address(0)` = BNB); can never change |
| `imageUrl()` / `website()` / `twitter()` | The coin's metadata links |
| `description()` | The coin's description, written by the creator at launch |
| `buyFeeBps()` / `sellFeeBps()` | Buy and sell tax in basis points (100 = 1%) |
| `taxAllocation()` | The creator's split of the tax: creator / burn / buyback / holders, in basis points |
| `graduationThreshold()` | Quote the curve raises when it sells out |
| `startPrice()` / `endPrice()` | Curve price at launch, and at sell-out (`b`) |
| `curveSupply()` / `dexSupply()` | Coins sold on the curve (80%) and coins reserved for PancakeSwap (20%) |
| `pair()` | The PancakeSwap pair address (known before the pair is created) |

### BondingCurvePool: live state

| Getter | What it returns |
|---|---|
| `curveTokensLeft()` | Coins still for sale on the curve (`x` in `y = -mx + b`) |
| `quoteReserve()` | Quote backing the curve |
| `creatorFees()` | The creator's unclaimed share of the tax |
| `burnBucket()` / `buybackBucket()` | Tax waiting to be spent on burns / buybacks |
| `buybackHeld()` | Coins bought back so far, locked in the pool |
| `graduated()` | Whether the curve has sold out (trading on the curve is closed) |
| `migrated()` | Whether liquidity has been moved to PancakeSwap |
| `rewardPerToken()` | Running total of rewards per coin held (scaled by 1e36), used for reward accounting |
| `rewardsUnclaimed()` | Holder rewards handed out but not yet claimed |
| `rewardsPending()` | Holder rewards collected while nobody held the coin, waiting for the next payout |
| `paidPerToken(holder)` / `rewardsOwed(holder)` | A holder's reward bookkeeping (`pendingRewards` combines them) |

### BondingCurvePool: constants

| Getter | Value |
|---|---|
| `BPS()` | 10,000 (100%) |
| `MAX_FEE_BPS()` | 1,000: the maximum buy or sell tax (10%) |
| `CURVE_SHARE_BPS()` | 8,000: the share of supply sold on the curve (80%) |
| `ADMIN_FEE_SHARE_BPS()` | 2,000: the platform's share of every tax (20%) |
| `NATIVE()` | `address(0)`, meaning native BNB |
| `DEAD()` | `0x…dEaD`, which receives the burned LP tokens |

### BondingCurvePool: standard ERC20 (inherited)

| Getter | What it returns |
|---|---|
| `name()` / `symbol()` / `decimals()` | The coin's name, ticker and decimals (18) |
| `totalSupply()` | Current supply; goes down when coins are burned |
| `balanceOf(account)` | An address's coin balance |
| `allowance(owner, spender)` | How much a spender may move on an owner's behalf |
