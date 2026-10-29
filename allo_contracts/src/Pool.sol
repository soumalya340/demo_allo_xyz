// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LinearCurveMath} from "./LinearCurveMath.sol";
import {IPancakeFactory, IPancakePair, IWBNB} from "./interfaces/IPancake.sol";

/// @notice What a creator fills in to launch a coin.
struct PoolParams {
    string name;
    string symbol;
    string imageUrl;
    string website;
    string twitter;
    string description;
    uint256 buyFeeBps; // tax on buys, e.g. 100 = 1%
    uint256 sellFeeBps; // tax on sells
    uint256 totalSupply; // 18 decimals
    uint256 graduationThreshold; // quote the curve raises when it sells out, e.g. 4.2 ether
}

interface IPoolFactory {
    function pancakeFactory() external view returns (address);
    function wbnb() external view returns (address);
    function pairInitCodeHash() external view returns (bytes32);
}

/// @notice ERC20 coin with a native BNB bonding curve, deployed as an ERC-1167 clone.
/// 80% of supply trades on the curve; 20% seeds a TOKEN/WBNB pair after graduation.
/// Trading fees are split 20% to the platform and 80% to the creator.
contract BondingCurvePool is ERC20Upgradeable, ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000; // 10%
    uint256 public constant CURVE_SHARE_BPS = 8_000; // 80% of supply on the curve
    uint256 public constant ADMIN_FEE_SHARE_BPS = 2_000; // platform's 20% of every tax
    address public constant NATIVE = address(0);
    address public constant quoteToken = address(0); // native BNB only
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public factory;
    address public creator;
    string public imageUrl;
    string public website;
    string public twitter;
    string public description;
    uint256 public buyFeeBps;
    uint256 public sellFeeBps;

    uint256 public graduationThreshold; // quote the curve raises when it sells out, set by the creator
    uint256 public startPrice; // price at launch, quote units per whole token
    uint256 public endPrice; // b: price once the curve is sold out
    uint256 public curveSupply; // tokens sold on the curve
    uint256 public dexSupply; // tokens reserved for DEX liquidity
    uint256 public curveTokensLeft; // x in y = -m*x + b

    uint256 public quoteReserve; // quote backing the curve
    uint256 public creatorFees; // unclaimed creator share of tax
    bool public graduated; // curve sold out, trading closed
    bool public migrated; // liquidity sent to the DEX
    address public pair; // PancakeSwap pair, known before it is created

    event Bought(address indexed buyer, uint256 amount, uint256 cost, uint256 fee);
    event Sold(address indexed seller, uint256 amount, uint256 refund, uint256 fee);
    event Graduated(uint256 quoteRaised);
    event Migrated(address indexed pair, uint256 tokenAmount, uint256 quoteAmount, uint256 liquidity);
    event CreatorFeesClaimed(address indexed creator, uint256 amount);

    error ZeroAmount();
    error FeeTooHigh();
    error InvalidCurve();
    error AlreadyGraduated();
    error NotGraduated();
    error AlreadyMigrated();
    error InsufficientPayment(uint256 required, uint256 maxIn);
    error SlippageExceeded(uint256 quoteOut, uint256 minQuoteOut);
    error AveragePriceTooHigh(uint256 filled, uint256 paid);
    error InvalidMsgValue();
    error TransferFailed();
    error TransferToPairBeforeMigration();
    error PairMismatch(address expected, address actual);

    constructor() {
        _disableInitializers();
    }

    /// @param startPrice_ launch price in wei per whole token
    function initialize(PoolParams calldata p, address creator_, uint256 startPrice_) external initializer {
        if (p.buyFeeBps > MAX_FEE_BPS || p.sellFeeBps > MAX_FEE_BPS) revert FeeTooHigh();

        uint256 curve = p.totalSupply * CURVE_SHARE_BPS / BPS;
        if (curve == 0) revert InvalidCurve();
        // The price has to rise along the curve, so the threshold must beat selling the whole curve at
        // startPrice. Same as endPrice > startPrice, checked first so endPrice can't underflow.
        if (p.graduationThreshold * LinearCurveMath.WAD <= startPrice_ * curve) revert InvalidCurve();
        uint256 b = LinearCurveMath.endPrice(p.graduationThreshold, startPrice_, curve);

        __ERC20_init(p.name, p.symbol);
        factory = msg.sender;
        creator = creator_;
        imageUrl = p.imageUrl;
        website = p.website;
        twitter = p.twitter;
        description = p.description;
        buyFeeBps = p.buyFeeBps;
        sellFeeBps = p.sellFeeBps;

        graduationThreshold = p.graduationThreshold;
        startPrice = startPrice_;
        endPrice = b;
        curveSupply = curve;
        dexSupply = p.totalSupply - curve;
        curveTokensLeft = curve;
        pair = _predictPair();

        _mint(address(this), p.totalSupply);
    }

    /// PancakeFactory deploys pairs with CREATE2 (salt = sorted token addresses), so the address
    /// is fixed before anyone calls createPair.
    function _predictPair() private view returns (address) {
        IPoolFactory f = IPoolFactory(factory);
        address other = f.wbnb();
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

    /// @notice Quote the curve pays for `amount` tokens before tax, and the sell tax taken from it.
    function getSellQuote(uint256 amount) public view returns (uint256 refund, uint256 fee) {
        refund =
            LinearCurveMath.sellRefund(endPrice, startPrice, curveSupply, curveTokensLeft, curveTokensLeft + amount);
        fee = refund * sellFeeBps / BPS;
    }

    // --------------------------------------------------------------- trading

    /// @notice Buy `amount` tokens for at most `maxIn` quote (tax included).
    /// Near the end of the curve you get whatever is left (partial fill), as long as the price per
    /// token is no worse than maxIn / amount.
    function buy(uint256 amount, uint256 maxIn) external payable nonReentrant {
        if (graduated) revert AlreadyGraduated();
        (uint256 filled, uint256 cost, uint256 fee) = getBuyQuote(amount);
        _buy(filled, cost, fee, amount, maxIn);
    }

    /// @param wanted tokens the buyer asked for; with maxIn it sets the worst price per token they accept
    function _buy(uint256 filled, uint256 cost, uint256 fee, uint256 wanted, uint256 maxIn) private {
        if (filled == 0) revert ZeroAmount();
        uint256 total = cost + fee;
        if (maxIn < total) revert InsufficientPayment(total, maxIn);
        // total / filled <= maxIn / wanted. A full fill passes trivially; a partial fill only passes
        // if someone else buying first hasn't pushed the leftover tokens above the price the buyer agreed to.
        // Use mulDiv to avoid overflow.
        if (Math.mulDiv(wanted, total, maxIn) > filled) revert AveragePriceTooHigh(filled, total);
        if (msg.value != maxIn) revert InvalidMsgValue();

        // Keep fees separate from the reserve backing circulating tokens.
        _takeFee(fee);
        curveTokensLeft -= filled;
        quoteReserve += cost;
        _transfer(address(this), msg.sender, filled);
        emit Bought(msg.sender, filled, cost, fee);
        _graduateIfSoldOut();

        _send(msg.sender, maxIn - total);
    }

    /// @notice Sell `amount` tokens back to the curve for at least `minQuoteOut` after the sell tax.
    function sell(uint256 amount, uint256 minQuoteOut) external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        if (amount == 0) revert ZeroAmount();

        (uint256 refund, uint256 fee) = getSellQuote(amount);
        uint256 quoteOut = refund - fee;
        if (quoteOut < minQuoteOut) revert SlippageExceeded(quoteOut, minQuoteOut);

        // Return sold tokens to the curve before paying BNB out.
        _transfer(msg.sender, address(this), amount);
        curveTokensLeft += amount;
        quoteReserve -= refund;
        emit Sold(msg.sender, amount, refund, fee);

        _takeFee(fee);
        _send(msg.sender, quoteOut);
    }

    function _graduateIfSoldOut() private {
        if (curveTokensLeft == 0 && !graduated) {
            graduated = true;
            emit Graduated(quoteReserve);
        }
    }

    // ---------------------------------------------------------------- tax

    /// Splits trading fees between the platform and creator, with rounding dust to the creator.
    function _takeFee(uint256 fee) private {
        uint256 adminFee = fee * ADMIN_FEE_SHARE_BPS / BPS;
        creatorFees += fee - adminFee;
        _send(factory, adminFee);
    }

    /// Block pair seeding before migration to protect the initial liquidity price.
    function _update(address from, address to, uint256 value) internal override {
        if (to == pair && !migrated) revert TransferToPairBeforeMigration();
        super._update(from, to, value);
    }

    // ------------------------------------------------------------- migration

    /// @notice After the curve sells out, anyone can push the 20% DEX allocation plus all raised quote
    /// into the PancakeSwap V2 pair. The LP tokens are burned, so the liquidity is locked forever.
    /// Creator fees stay claimable after migration.
    ///
    /// This talks to Pancake core directly instead of the router. The router prices a deposit off the
    /// pair's existing reserves, so anyone who pre-created the pair and `sync`ed a dust donation into
    /// it could either brick migration or set the launch price. Here:
    ///   - nobody can send this token to the pair before migration (see `_update`), so it can't hold
    ///     any, and no LP can be minted ahead of us;
    ///   - `mint` credits everything above the old reserves as our deposit, so any WBNB someone
    ///     donated just ends up as extra liquidity in the pool.
    function migrate() external nonReentrant {
        if (!graduated) revert NotGraduated();
        if (migrated) revert AlreadyMigrated();
        migrated = true;

        IPancakeFactory pancake = IPancakeFactory(IPoolFactory(factory).pancakeFactory());
        address pairToken = IPoolFactory(factory).wbnb();

        address actual = pancake.getPair(address(this), pairToken);
        if (actual == address(0)) actual = pancake.createPair(address(this), pairToken);
        if (actual != pair) revert PairMismatch(pair, actual);

        uint256 quoteAmount = quoteReserve;
        quoteReserve = 0;
        _payPair(pairToken, quoteAmount);
        _transfer(address(this), pair, dexSupply);
        uint256 liquidity = IPancakePair(pair).mint(DEAD);
        emit Migrated(pair, dexSupply, quoteAmount, liquidity);
    }

    /// Wrap BNB only when seeding the DEX pair.
    function _payPair(address pairToken, uint256 amount) private {
        IWBNB(pairToken).deposit{value: amount}();
        if (!IWBNB(pairToken).transfer(pair, amount)) revert TransferFailed();
    }

    // ------------------------------------------------------------------ fees

    function claimFees() external nonReentrant {
        uint256 amount = creatorFees;
        creatorFees = 0;
        emit CreatorFeesClaimed(creator, amount);
        _send(creator, amount);
    }

    // ----------------------------------------------------------- quote moves

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
