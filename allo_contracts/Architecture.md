# How Allo Works

Allo is a launchpad for new coins. Anyone can create a coin in one step. People trade it straight away at a fair, predictable price, and once enough money has come in, the coin moves to PancakeSwap, where it trades like any other token.

This page explains the whole system without the technical details.

---

## The life of a coin

```
   1. LAUNCH             2. TRADING                3. GRADUATION          4. ON PANCAKESWAP
 ┌────────────┐      ┌──────────────────┐       ┌────────────────┐      ┌────────────────┐
 │ Creator    │      │ People buy and   │       │ All coins on   │      │ Coin trades    │
 │ fills in   │ ───► │ sell. The price  │ ───►  │ the curve sold │ ───► │ freely, like   │
 │ the form   │      │ rises as coins   │       │ = target hit   │      │ any token      │
 │            │      │ get bought       │       │                │      │                │
 └────────────┘      └──────────────────┘       └────────────────┘      └────────────────┘
```

---

## 1. Launch

The creator fills in a short form:

| What | Example |
|---|---|
| Name and ticker | Allo Coin · ALLO |
| Image, website, X (Twitter), description | Shown on the coin's page |
| **Pay with** | **BNB by default**, or a token the platform has approved (e.g. USDT) |
| Buy tax and sell tax | Anything from 0% to 10%, e.g. 2% buy / 1% sell |
| Tax split | Where the tax goes (see section 3) |
| Total supply | e.g. 100,000 coins |
| Graduation target | How much money the coin must raise, e.g. 4.2 BNB |

- **Launch fee.** The creator pays a small flat fee (0.002 BNB) to the platform.
- **Optional first buy.** The creator can buy some of their own coin in the same instant it's created, so no bot can get in first. This first buy is **tax-free**.
- **Cheap to launch.** Every coin is a lightweight copy of one master design, so creating a coin costs little.

### Where the coins go

```
             Total supply
   ┌──────────────────────────────┐
   │ 80% for sale on the curve    │  ← people buy these
   ├──────────────────────────────┤
   │ 20% saved for PancakeSwap    │  ← locked away until graduation
   └──────────────────────────────┘
```

---

## 2. Trading: the price curve

The price isn't set by an order book. It follows a **straight line** that climbs as coins are sold:

```
 price
   ▲
   │                         ●  end price
   │                    ●
   │               ●             Every coin bought pushes the price up a little.
   │          ●                  Every coin sold brings it back down.
   │     ●
   │●  start price (0.00001 BNB)
   └─────────────────────────────► coins sold
```

- **Early buyers pay less** and later buyers pay more, which rewards people who spot a coin early.
- **The line is tuned per coin**, so that selling every coin on the curve raises exactly the creator's graduation target.
- **You can always sell back** before graduation, at the current price on the line.

### Two ways to buy

| | You say... | You get... |
|---|---|---|
| **Exact amount** | "I want 10,000 coins, and won't pay more than X" | Exactly 10,000 coins, plus anything unused back |
| **Exact spend** | "Spend 1 BNB" | As many coins as 1 BNB buys |

### Built-in protections for traders

- **Partial fills near the end.** If you ask for more coins than are left, you get all the remaining coins, pay only for those, and get the rest of your money back.
- **No overpaying.** If someone buys just before you and the price jumps, your trade is cancelled instead of going through at a worse price than you agreed to.
- **Sell protection.** You set the minimum you'll accept, and if the price drops below it, the sale is cancelled.

---

## 3. Taxes: where the money goes

Every buy and sell on the curve pays the coin's tax. The tax is split twice:

```
                     Tax from a trade
                           │
          ┌────────────────┴────────────────┐
          ▼                                 ▼
   20% → Platform                   80% → split the way the creator chose
                                            │
              ┌─────────────┬───────────────┼───────────────┐
              ▼             ▼               ▼               ▼
        Creator wallet     Burn          Buyback      Holder rewards
```

| Bucket | What happens |
|---|---|
| **Creator wallet** | Saved for the creator, who claims it whenever they like |
| **Burn** | Used to buy coins, which are then **destroyed forever**, so the total supply shrinks |
| **Buyback** | Used to buy coins, which are **locked inside the coin's contract forever**, never sold |
| **Holder rewards** | Shared among **everyone holding the coin**, in proportion to how much they hold, and claimed whenever they like |

The creator's split must add up to 100%.

### Example

A coin has a 2% buy tax, and its creator chose **20% creator · 30% burn · 40% buyback · 10% holders**. Someone buys 1 BNB worth:

| | Amount |
|---|---|
| Tax (2% of 1 BNB) | 0.02 BNB |
| → Platform (20%) | 0.004 BNB |
| → Creator (20% of the rest) | 0.0032 BNB |
| → Burn (30% of the rest) | 0.0048 BNB |
| → Buyback (40% of the rest) | 0.0064 BNB |
| → Holders (10% of the rest) | 0.0016 BNB |

### Good to know

- **It all happens automatically.** Burns and buybacks run at the end of every trade. Nobody has to press a button, and nobody can time them for profit.
- **Holder rewards stay earned.** If you sell, you keep what you've earned but stop earning more. Rewards can still be claimed after the coin moves to PancakeSwap.
- **No rewards from your own trade.** A buyer doesn't earn rewards from the tax on their own buy, and a seller doesn't earn from their own sell.
- **Taxes only apply on the curve.** After the coin moves to PancakeSwap it's a normal token with no tax.

---

## 4. Graduation and the move to PancakeSwap

When the last coin on the curve is bought:

1. **Curve trading closes.** The target has been raised.
2. **Anyone can trigger the move.** It takes one click, and it doesn't have to be the creator.
3. **A PancakeSwap pool is created.** It gets the **20% of coins saved at launch** plus **all the money raised**.
4. **The pool is locked forever.** The ownership tickets for that pool are destroyed, so nobody, not the creator and not the platform, can ever pull the money out.
5. **Leftover burn and buyback money** from the final trade is spent buying the coin on PancakeSwap.

From then on, the coin trades on PancakeSwap like any other token.

---

## 5. Who's who

| Role | What they do | What they earn |
|---|---|---|
| **Creator** | Launches the coin and picks its settings | Their share of the tax, plus a tax-free first buy |
| **Traders and holders** | Buy and sell on the curve | Holder rewards, and price gains if the coin grows |
| **Platform (admin)** | Runs Allo and approves which tokens coins can be paired with | The launch fee plus 20% of all taxes |
| **Anyone** | Can trigger a graduated coin's move to PancakeSwap | Nothing; it's a public service |

---

## 6. Safety: what keeps it fair

- 💰 **Every coin can be sold back.** The coin always holds enough money to buy back every coin in circulation at the curve price.
- 🔒 **Settings are locked at launch.** The payment token, taxes, tax split and price curve can never be changed afterwards, not even by the platform.
- 🛑 **Taxes are capped** at 10% on buys and 10% on sells.
- 🚫 **No early tampering with PancakeSwap.** Nobody can set up the PancakeSwap pool ahead of time to rig the starting price or block the move.
- 🔐 **Liquidity is locked forever** once the coin graduates.
- ✅ **Only approved payment tokens.** The platform vets tokens like USDT before coins can use them, because unusual tokens could break the maths.
- 🧪 **Thoroughly tested.** 77 automated tests and randomised stress tests, plus rehearsals against real copies of BNB Chain and PancakeSwap.

---

## Glossary

| Term | Meaning |
|---|---|
| **Bonding curve** | The straight-line price rule a coin trades on before graduation |
| **Graduation** | The moment the curve sells out and the coin is ready for PancakeSwap |
| **Migration** | Moving the coin and its money into a PancakeSwap pool |
| **Liquidity** | The money and coins in a trading pool that let people trade |
| **Native coin** | The blockchain's own currency, BNB on BNB Chain; the default way to pay |
| **Burn** | Destroying coins for good, so the supply gets smaller |
| **Buyback** | Using tax to buy coins and keep them off the market for good |
| **Holder rewards** | A share of the tax paid to everyone holding the coin |
| **Partial fill** | Getting fewer coins than you asked for, because the curve ran out, and paying only for those |
