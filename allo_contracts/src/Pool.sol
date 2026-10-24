// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LinearCurveMath} from "./LinearCurveMath.sol";
import {IPancakeFactory, IPancakePair, IWBNB} from "./interfaces/IPancake.sol";

/// @notice How the creator splits the tax left after the platform's 20%. Must add up to 10_000 (100%).
struct TaxAllocation {
    uint256 creatorBps; // paid to the creator
    uint256 burnBps; // buys coins (curve, or PancakeSwap after graduation) and burns them
    uint256 buybackBps; // buys coins the same way and keeps them locked in the pool contract
    uint256 holdersBps; // shared among everyone holding the coin, claimable
}

/// @notice What a creator fills in to launch a coin.
struct PoolParams {
    string name;
    string symbol;
    string imageUrl;
    string website;
    string twitter;
    address quoteToken; // what the coin trades against: address(0) = native BNB, else an admin-approved ERC20
    uint256 buyFeeBps; // tax on buys, e.g. 100 = 1%
    uint256 sellFeeBps; // tax on sells
    TaxAllocation taxAllocation;
    uint256 totalSupply; // 18 decimals
    uint256 graduationThreshold; // quote the curve raises when it sells out, e.g. 4.2 ether
}

interface IPoolFactory {
    function pancakeFactory() external view returns (address);
    function wbnb() external view returns (address);
    function pairInitCodeHash() external view returns (bytes32);
}

/// @notice A coin plus its bonding curve. Deployed as an ERC-1167 clone by PoolFactory.
///
/// The coin trades against a quote asset: native BNB or an admin-approved ERC20. 80% of the supply
/// is sold on the curve y = -m*x + b; the other 20% is held back and, once the curve sells out,
/// paired with the raised quote in a PancakeSwap V2 pair (TOKEN/WBNB for native, else TOKEN/quote).
///
/// Buys pay `buyFeeBps` and sells pay `sellFeeBps`, in the quote asset, only while the coin trades on
/// the curve. 20% of every tax goes to the platform (via the factory); the rest is split by the
/// creator's `taxAllocation` into creator fees, burn, buyback and holder rewards. The creator's
/// optional first buy is tax-free.
contract BondingCurvePool is ERC20Upgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000; // 10%
    uint256 public constant CURVE_SHARE_BPS = 8_000; // 80% of supply on the curve
    uint256 public constant ADMIN_FEE_SHARE_BPS = 2_000; // platform's 20% of every tax
    uint256 private constant REWARD_SCALE = 1e36; // precision for rewardPerToken, so small taxes still count
    address public constant NATIVE = address(0);
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public factory;
    address public creator;
    address public quoteToken; // NATIVE or an ERC20
    string public imageUrl;
    string public website;
    string public twitter;
    uint256 public buyFeeBps;
    uint256 public sellFeeBps;
    TaxAllocation public taxAllocation;

    uint256 public graduationThreshold; // quote the curve raises when it sells out, set by the creator
    uint256 public startPrice; // price at launch, quote units per whole token
    uint256 public endPrice; // b: price once the curve is sold out
    uint256 public curveSupply; // tokens sold on the curve
    uint256 public dexSupply; // tokens reserved for DEX liquidity
    uint256 public curveTokensLeft; // x in y = -m*x + b

    uint256 public quoteReserve; // quote backing the curve
    uint256 public creatorFees; // unclaimed creator share of tax
    uint256 public burnBucket; // tax waiting to buy-and-burn (spent at the end of each trade)
    uint256 public buybackBucket; // tax waiting to buy back (same)
    uint256 public buybackHeld; // coins bought back so far, kept in this contract and never sold
    bool public graduated; // curve sold out, trading closed
    bool public migrated; // liquidity sent to the DEX
    address public pair; // PancakeSwap pair, known before it is created

    // Holder rewards: one running total of reward per coin held, so paying every holder costs one write.
    // A holder is owed balance * (rewardPerToken - paidPerToken[holder]) on top of rewardsOwed[holder].
    uint256 public rewardPerToken; // scaled by REWARD_SCALE
    uint256 public rewardsUnclaimed; // handed out to holders, not yet claimed
    uint256 public rewardsPending; // collected while nobody held the coin; added to the next payout
    mapping(address => uint256) public paidPerToken;
    mapping(address => uint256) public rewardsOwed;

    event Bought(address indexed buyer, uint256 amount, uint256 cost, uint256 fee);
    event Sold(address indexed seller, uint256 amount, uint256 refund, uint256 fee);
    event Burned(uint256 coins, uint256 quoteSpent);
    event BoughtBack(uint256 coins, uint256 quoteSpent);
    event Graduated(uint256 quoteRaised);
    event Migrated(address indexed pair, uint256 tokenAmount, uint256 quoteAmount, uint256 liquidity);
    event CreatorFeesClaimed(address indexed creator, uint256 amount);
    event RewardsClaimed(address indexed holder, uint256 amount);

    error ZeroAmount();
    error FeeTooHigh();
    error InvalidTaxAllocation();
    error InvalidCurve();
    error AlreadyGraduated();
    error NotGraduated();
    error AlreadyMigrated();
    error InsufficientPayment(uint256 required, uint256 maxIn);
    error SlippageExceeded(uint256 quoteOut, uint256 minQuoteOut);
    error AveragePriceTooHigh(uint256 filled, uint256 paid);
    error InvalidMsgValue();
    error OnlyFactory();
    error NotFirstBuy();
    error TransferFailed();
    error TransferToPairBeforeMigration();
    error PairMismatch(address expected, address actual);

    constructor() {
        _disableInitializers();
    }

    /// @param startPrice_ launch price in quote units per whole token, from the factory's list for p.quoteToken
    function initialize(PoolParams calldata p, address creator_, uint256 startPrice_) external initializer {
        if (p.buyFeeBps > MAX_FEE_BPS || p.sellFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        TaxAllocation calldata a = p.taxAllocation;
        if (a.creatorBps + a.burnBps + a.buybackBps + a.holdersBps != BPS) revert InvalidTaxAllocation();

        uint256 curve = p.totalSupply * CURVE_SHARE_BPS / BPS;
        if (curve == 0) revert InvalidCurve();
        // The price has to rise along the curve, so the threshold must beat selling the whole curve at
        // startPrice. Same as endPrice > startPrice, checked first so endPrice can't underflow.
        if (p.graduationThreshold * LinearCurveMath.WAD <= startPrice_ * curve) revert InvalidCurve();
        uint256 b = LinearCurveMath.endPrice(p.graduationThreshold, startPrice_, curve);

        __ERC20_init(p.name, p.symbol);
        factory = msg.sender;
        creator = creator_;
        quoteToken = p.quoteToken;
        imageUrl = p.imageUrl;
        website = p.website;
        twitter = p.twitter;
        buyFeeBps = p.buyFeeBps;
        sellFeeBps = p.sellFeeBps;
        taxAllocation = a;

        graduationThreshold = p.graduationThreshold;
        startPrice = startPrice_;
        endPrice = b;
        curveSupply = curve;
        dexSupply = p.totalSupply - curve;
        curveTokensLeft = curve;
        pair = _predictPair();

        _mint(address(this), p.totalSupply);
    }

    /// The token the coin is paired with on PancakeSwap: WBNB for native, otherwise the quote token.
    function _pairToken() private view returns (address) {
        return quoteToken == NATIVE ? IPoolFactory(factory).wbnb() : quoteToken;
    }

    /// PancakeFactory deploys pairs with CREATE2 (salt = sorted token addresses), so the address
    /// is fixed before anyone calls createPair.
    function _predictPair() private view returns (address) {
        IPoolFactory f = IPoolFactory(factory);
        address other = _pairToken();
        (address token0, address token1) = address(this) < other ? (address(this), other) : (other, address(this));
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(hex"ff", f.pancakeFactory(), salt, f.pairInitCodeHash()))))
            );
    }

    // ---------------------------------------------------------------- views

    function currentPrice() external view returns (uint256) {
        return LinearCurveMath.priceAt(endPrice, startPrice, curveSupply, curveTokensLeft);
    }

    /// @notice What `buy(amount, ...)` would do right now. `filled` is less than `amount` near the end of the curve.
    function getBuyQuote(uint256 amount) public view returns (uint256 filled, uint256 cost, uint256 fee) {
        filled = amount > curveTokensLeft ? curveTokensLeft : amount;
        cost = LinearCurveMath.buyCost(endPrice, startPrice, curveSupply, curveTokensLeft - filled, curveTokensLeft);
        fee = cost * buyFeeBps / BPS;
    }

    /// @notice What `buyExactIn(amountIn, ...)` would do right now (amountIn includes the buy tax).
    function getBuyQuoteExactIn(uint256 amountIn) public view returns (uint256 filled, uint256 cost, uint256 fee) {
        // Largest cost whose tax still fits: cost + cost * buyFeeBps / BPS <= amountIn
        uint256 budget = amountIn * BPS / (BPS + buyFeeBps);
        uint256 tokens = LinearCurveMath.tokensForCost(endPrice, startPrice, curveSupply, curveTokensLeft, budget);
        return getBuyQuote(tokens);
    }

    /// @notice Quote the curve pays for `amount` tokens before tax, and the sell tax taken from it.
    function getSellQuote(uint256 amount) public view returns (uint256 refund, uint256 fee) {
        refund =
            LinearCurveMath.sellRefund(endPrice, startPrice, curveSupply, curveTokensLeft, curveTokensLeft + amount);
        fee = refund * sellFeeBps / BPS;
    }

    /// @notice Holder rewards `holder` can claim right now, in quote.
    function pendingRewards(address holder) external view returns (uint256) {
        if (_noRewards(holder)) return 0;
        return rewardsOwed[holder] + balanceOf(holder) * (rewardPerToken - paidPerToken[holder]) / REWARD_SCALE;
    }

    // --------------------------------------------------------------- trading
    //
    // Paying in native BNB: send msg.value equal to `maxIn` / `amountIn`; whatever isn't used comes back.
    // Paying in an ERC20: approve the pool, send no value; it pulls exactly what the trade costs.

    /// @notice Buy `amount` tokens for at most `maxIn` quote (tax included).
    /// Near the end of the curve you get whatever is left (partial fill), as long as the price per
    /// token is no worse than maxIn / amount.
    function buy(uint256 amount, uint256 maxIn) external payable nonReentrant {
        if (graduated) revert AlreadyGraduated();
        (uint256 filled, uint256 cost, uint256 fee) = getBuyQuote(amount);
        _buy(filled, cost, fee, amount, maxIn);
    }

    /// @notice Spend up to `amountIn` quote (tax included) on as many tokens as it buys, receiving at least
    /// `minTokensOut`. If the curve runs out first you get the rest of it and pay only for those tokens,
    /// as long as the price per token is no worse than amountIn / minTokensOut.
    function buyExactIn(uint256 amountIn, uint256 minTokensOut) external payable nonReentrant {
        if (graduated) revert AlreadyGraduated();
        (uint256 filled, uint256 cost, uint256 fee) = getBuyQuoteExactIn(amountIn);
        _buy(filled, cost, fee, minTokensOut, amountIn);
    }

    /// @param wanted tokens the buyer asked for; with maxIn it sets the worst price per token they accept
    function _buy(uint256 filled, uint256 cost, uint256 fee, uint256 wanted, uint256 maxIn) private {
        if (filled == 0) revert ZeroAmount();
        uint256 total = cost + fee;
        if (maxIn < total) revert InsufficientPayment(total, maxIn);
        // total / filled <= maxIn / wanted. A full fill passes trivially; a partial fill only passes
        // if someone else buying first hasn't pushed the leftover tokens above the price the buyer agreed to.
        // (mulDiv so an ERC20 buyer can pass maxIn = type(uint256).max without overflowing.)
        if (Math.mulDiv(wanted, total, maxIn) > filled) revert AveragePriceTooHigh(filled, total);
        _collect(maxIn, total);

        // Tax first, so the holder share goes to existing holders and not to this buyer.
        _takeFee(fee);
        curveTokensLeft -= filled;
        quoteReserve += cost;
        _transfer(address(this), msg.sender, filled);
        emit Bought(msg.sender, filled, cost, fee);
        _graduateIfSoldOut();
        _spendBuckets();

        if (quoteToken == NATIVE) _send(msg.sender, maxIn - total);
    }

    /// @notice The creator's tax-free first buy, made by the factory in the same transaction that creates
    /// the pool so nobody can buy ahead of it. The factory has already sent `amountIn` (as msg.value for
    /// native, as tokens for an ERC20). Anything the curve doesn't use goes back to the creator.
    function firstBuy(uint256 amountIn) external payable nonReentrant {
        if (msg.sender != factory) revert OnlyFactory();
        if (curveTokensLeft != curveSupply) revert NotFirstBuy();
        if (msg.value != (quoteToken == NATIVE ? amountIn : 0)) revert InvalidMsgValue();

        (uint256 filled, uint256 cost) = _buyFromCurve(amountIn);
        if (filled == 0) revert ZeroAmount();
        _transfer(address(this), creator, filled);
        emit Bought(creator, filled, cost, 0);

        _send(creator, amountIn - cost);
    }

    /// @notice Sell `amount` tokens back to the curve for at least `minQuoteOut` after the sell tax.
    function sell(uint256 amount, uint256 minQuoteOut) external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        if (amount == 0) revert ZeroAmount();

        (uint256 refund, uint256 fee) = getSellQuote(amount);
        uint256 quoteOut = refund - fee;
        if (quoteOut < minQuoteOut) revert SlippageExceeded(quoteOut, minQuoteOut);

        // Coins leave the seller first, so the holder share of this tax goes to the remaining holders.
        _transfer(msg.sender, address(this), amount);
        curveTokensLeft += amount;
        quoteReserve -= refund;
        emit Sold(msg.sender, amount, refund, fee);

        _takeFee(fee);
        _spendBuckets();
        _send(msg.sender, quoteOut);
    }

    /// Buys from the curve with up to `budget` quote, no tax: moves the coins' cost into the reserve and
    /// leaves the coins in this contract for the caller to hand out or burn.
    function _buyFromCurve(uint256 budget) private returns (uint256 filled, uint256 cost) {
        uint256 tokens = LinearCurveMath.tokensForCost(endPrice, startPrice, curveSupply, curveTokensLeft, budget);
        filled = tokens > curveTokensLeft ? curveTokensLeft : tokens;
        if (filled == 0) return (0, 0);
        cost = LinearCurveMath.buyCost(endPrice, startPrice, curveSupply, curveTokensLeft - filled, curveTokensLeft);
        curveTokensLeft -= filled;
        quoteReserve += cost;
        _graduateIfSoldOut();
    }

    function _graduateIfSoldOut() private {
        if (curveTokensLeft == 0 && !graduated) {
            graduated = true;
            emit Graduated(quoteReserve);
        }
    }

    // ---------------------------------------------------------------- tax

    /// Splits a trade's tax: 20% to the platform, the rest by the creator's allocation. Rounding dust
    /// goes to the creator.
    function _takeFee(uint256 fee) private {
        if (fee == 0) return;
        uint256 adminFee = fee * ADMIN_FEE_SHARE_BPS / BPS;
        uint256 rest = fee - adminFee;
        TaxAllocation memory a = taxAllocation;
        uint256 toBurn = rest * a.burnBps / BPS;
        uint256 toBuyback = rest * a.buybackBps / BPS;
        uint256 toHolders = rest * a.holdersBps / BPS;

        creatorFees += rest - toBurn - toBuyback - toHolders;
        burnBucket += toBurn;
        buybackBucket += toBuyback;
        _addRewards(toHolders);
        _send(factory, adminFee);
    }

    /// Spends the burn and buyback buckets on the curve. Runs at the end of every trade; whatever is
    /// too small to buy a single unit waits for the next one. Whatever the curve can't take (the trade
    /// that sells it out) is spent on PancakeSwap during migration instead.
    function _spendBuckets() private {
        if (burnBucket != 0 && !graduated) {
            (uint256 coins, uint256 spent) = _buyFromCurve(burnBucket);
            if (coins != 0) {
                burnBucket -= spent;
                _burn(address(this), coins);
                emit Burned(coins, spent);
            }
        }
        if (buybackBucket != 0 && !graduated) {
            (uint256 coins, uint256 spent) = _buyFromCurve(buybackBucket);
            if (coins != 0) {
                buybackBucket -= spent;
                buybackHeld += coins; // the coins are already in this contract; they just stop being for sale
                emit BoughtBack(coins, spent);
            }
        }
    }

    // ------------------------------------------------------- holder rewards

    /// @notice Claim your share of the holder rewards, paid in quote. Works before and after migration.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender);
        amount = rewardsOwed[msg.sender];
        rewardsOwed[msg.sender] = 0;
        rewardsUnclaimed -= amount;
        emit RewardsClaimed(msg.sender, amount);
        _send(msg.sender, amount);
    }

    /// Shares `amount` among current holders pro rata. If nobody holds yet, it waits for the next payout.
    function _addRewards(uint256 amount) private {
        uint256 total = amount + rewardsPending;
        if (total == 0) return;
        uint256 supply = totalSupply() - balanceOf(address(this)) - balanceOf(pair) - balanceOf(DEAD);
        if (supply == 0) {
            rewardsPending = total;
            return;
        }
        rewardsPending = 0;
        rewardPerToken += total * REWARD_SCALE / supply;
        rewardsUnclaimed += total;
    }

    /// Books what `holder` earned since their last update, before their balance changes.
    function _settle(address holder) private {
        if (_noRewards(holder)) return;
        uint256 rpt = rewardPerToken;
        uint256 paid = paidPerToken[holder];
        if (rpt == paid) return;
        rewardsOwed[holder] += balanceOf(holder) * (rpt - paid) / REWARD_SCALE;
        paidPerToken[holder] = rpt;
    }

    /// Unsold curve coins, the DEX pair and burned coins don't earn rewards.
    function _noRewards(address account) private view returns (bool) {
        return account == address(this) || account == pair || account == DEAD || account == address(0);
    }

    /// Settles rewards for both sides of every transfer, and blocks sending this token to the Pancake
    /// pair until migration so the pair's price can't be seeded by anyone else.
    function _update(address from, address to, uint256 value) internal override {
        if (to == pair && !migrated) revert TransferToPairBeforeMigration();
        _settle(from);
        _settle(to);
        super._update(from, to, value);
    }

    // ------------------------------------------------------------- migration

    /// @notice After the curve sells out, anyone can push the 20% DEX allocation plus all raised quote
    /// into the PancakeSwap V2 pair. The LP tokens are burned, so the liquidity is locked forever.
    /// Burn/buyback tax the curve couldn't spend is then swapped for coins on the new pair: the burn share
    /// is burned, the buyback share kept. Creator fees and holder rewards stay claimable.
    ///
    /// This talks to Pancake core directly instead of the router. The router prices a deposit off the
    /// pair's existing reserves, so anyone who pre-created the pair and `sync`ed a dust donation into
    /// it could either brick migration or set the launch price. Here:
    ///   - nobody can send this token to the pair before migration (see `_update`), so it can't hold
    ///     any, and no LP can be minted ahead of us;
    ///   - `mint` credits everything above the old reserves as our deposit, so any WBNB/quote someone
    ///     donated just ends up as extra liquidity in the pool.
    function migrate() external nonReentrant {
        if (!graduated) revert NotGraduated();
        if (migrated) revert AlreadyMigrated();
        migrated = true;

        IPancakeFactory pancake = IPancakeFactory(IPoolFactory(factory).pancakeFactory());
        address pairToken = _pairToken();

        address actual = pancake.getPair(address(this), pairToken);
        if (actual == address(0)) actual = pancake.createPair(address(this), pairToken);
        if (actual != pair) revert PairMismatch(pair, actual);

        uint256 quoteAmount = quoteReserve;
        quoteReserve = 0;
        _payPair(pairToken, quoteAmount);
        _transfer(address(this), pair, dexSupply);
        uint256 liquidity = IPancakePair(pair).mint(DEAD);
        emit Migrated(pair, dexSupply, quoteAmount, liquidity);

        _spendBucketsOnPancake(pairToken);
    }

    /// Swaps the leftover burn + buyback tax for coins on the pair in one go, then splits the coins:
    /// burn share destroyed, buyback share kept. Priced with a 0.25% fee, PancakeSwap V2's, so the
    /// swap also clears on pairs with a lower fee.
    function _spendBucketsOnPancake(address pairToken) private {
        uint256 amountIn = burnBucket + buybackBucket;
        if (amountIn == 0) return;

        bool coinIsToken0 = address(this) < pairToken;
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = coinIsToken0 ? (uint256(r1), uint256(r0)) : (r0, r1);
        uint256 inWithFee = amountIn * 9_975;
        uint256 coinsOut = inWithFee * reserveOut / (reserveIn * 10_000 + inWithFee);
        if (coinsOut == 0) return; // dust: stays in the buckets

        uint256 burnIn = burnBucket;
        burnBucket = 0;
        buybackBucket = 0;
        _payPair(pairToken, amountIn);
        // A pair won't send output to one of its own tokens, and this contract is the coin, so the coins
        // land at the factory and are pulled straight back.
        IPancakePair(pair).swap(coinIsToken0 ? coinsOut : 0, coinIsToken0 ? 0 : coinsOut, factory, "");

        uint256 burnCoins = coinsOut * burnIn / amountIn;
        _burn(factory, burnCoins);
        _transfer(factory, address(this), coinsOut - burnCoins);
        buybackHeld += coinsOut - burnCoins;
        emit Burned(burnCoins, burnIn);
        emit BoughtBack(coinsOut - burnCoins, amountIn - burnIn);
    }

    /// Sends `amount` of quote to the pair, wrapping native BNB into WBNB first.
    function _payPair(address pairToken, uint256 amount) private {
        if (quoteToken == NATIVE) {
            IWBNB(pairToken).deposit{value: amount}();
            if (!IWBNB(pairToken).transfer(pair, amount)) revert TransferFailed();
        } else {
            IERC20(quoteToken).safeTransfer(pair, amount);
        }
    }

    // ------------------------------------------------------------------ fees

    function claimCreatorFees() external nonReentrant {
        uint256 amount = creatorFees;
        creatorFees = 0;
        emit CreatorFeesClaimed(creator, amount);
        _send(creator, amount);
    }

    // ----------------------------------------------------------- quote moves

    /// Takes payment for a buy: checks msg.value for native, pulls exactly `total` for an ERC20.
    function _collect(uint256 maxIn, uint256 total) private {
        if (quoteToken == NATIVE) {
            if (msg.value != maxIn) revert InvalidMsgValue();
        } else {
            if (msg.value != 0) revert InvalidMsgValue();
            IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), total);
        }
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        if (quoteToken == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(quoteToken).safeTransfer(to, amount);
        }
    }
}
