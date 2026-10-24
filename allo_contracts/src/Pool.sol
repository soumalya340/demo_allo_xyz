// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LinearCurveMath} from "./LinearCurveMath.sol";
import {IPancakeFactory, IPancakePair, IWBNB} from "./interfaces/IPancake.sol";

/// @notice What a creator fills in to launch a coin.
struct PoolParams {
    string name;
    string symbol;
    string imageUrl;
    string website;
    string twitter;
    uint256 feeBps; // trading fee, e.g. 100 = 1%
    uint256 totalSupply; // 18 decimals
    uint256 graduationThreshold; // ETH the curve raises when it sells out, e.g. 4.2 ether
}

interface IPoolFactory {
    function pancakeFactory() external view returns (address);
    function wbnb() external view returns (address);
    function pairInitCodeHash() external view returns (bytes32);
}

/// @notice A coin plus its bonding curve. Deployed as an ERC-1167 clone by PoolFactory.
///
/// 80% of the supply is sold on the curve y = -m*x + b; the other 20% is held back and,
/// once the curve sells out, paired with the raised ETH in a PancakeSwap V2 TOKEN/WBNB pair.
/// Every trade pays `feeBps` in ETH: 20% of it goes to the admin (via the factory), 80% to the creator.
contract BondingCurvePool is ERC20Upgradeable, ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000; // 10%
    uint256 public constant CURVE_SHARE_BPS = 8_000; // 80% of supply on the curve
    uint256 public constant ADMIN_FEE_SHARE_BPS = 2_000; // 20% of every fee
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public factory;
    address public creator;
    string public imageUrl;
    string public website;
    string public twitter;
    uint256 public feeBps;

    uint256 public graduationThreshold; // ETH the curve raises when it sells out, set by the creator
    uint256 public startPrice; // price at launch
    uint256 public endPrice; // b: price once the curve is sold out
    uint256 public curveSupply; // tokens sold on the curve
    uint256 public dexSupply; // tokens reserved for DEX liquidity
    uint256 public curveTokensLeft; // x in y = -m*x + b

    uint256 public ethReserve; // ETH backing the curve
    uint256 public creatorFees; // unclaimed creator share of fees
    bool public graduated; // curve sold out, trading closed
    bool public migrated; // liquidity sent to the DEX
    address public pair; // TOKEN/WBNB PancakeSwap pair, known before it is created

    event Bought(address indexed buyer, uint256 amount, uint256 cost, uint256 fee);
    event Sold(address indexed seller, uint256 amount, uint256 refund, uint256 fee);
    event Graduated(uint256 ethRaised);
    event Migrated(address indexed pair, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity);
    event CreatorFeesClaimed(address indexed creator, uint256 amount);

    error ZeroAmount();
    error FeeTooHigh();
    error InvalidCurve();
    error AlreadyGraduated();
    error NotGraduated();
    error AlreadyMigrated();
    error InsufficientPayment(uint256 required, uint256 sent);
    error SlippageExceeded(uint256 ethOut, uint256 minEthOut);
    error AveragePriceTooHigh(uint256 filled, uint256 paid);
    error TransferFailed();
    error TransferToPairBeforeMigration();
    error PairMismatch(address expected, address actual);

    constructor() {
        _disableInitializers();
    }

    /// @param startPrice_ launch price in wei per token (e.g. 0.00001 ether)
    function initialize(PoolParams calldata p, address creator_, uint256 startPrice_) external initializer {
        if (p.feeBps > MAX_FEE_BPS) revert FeeTooHigh();

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
        feeBps = p.feeBps;

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
        address wbnb = f.wbnb();
        (address token0, address token1) = address(this) < wbnb ? (address(this), wbnb) : (wbnb, address(this));
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

    /// @notice What `buy(amount)` would do right now. `filled` is less than `amount` near the end of the curve.
    function getBuyQuote(uint256 amount) public view returns (uint256 filled, uint256 cost, uint256 fee) {
        filled = amount > curveTokensLeft ? curveTokensLeft : amount;
        cost = LinearCurveMath.buyCost(endPrice, startPrice, curveSupply, curveTokensLeft - filled, curveTokensLeft);
        fee = cost * feeBps / BPS;
    }

    /// @notice What `buyWithEth` would do with `ethIn` wei (fee included) right now.
    function getBuyQuoteForEth(uint256 ethIn) public view returns (uint256 filled, uint256 cost, uint256 fee) {
        // Largest cost whose fee still fits: cost + cost * feeBps / BPS <= ethIn
        uint256 budget = ethIn * BPS / (BPS + feeBps);
        uint256 tokens = LinearCurveMath.tokensForCost(endPrice, startPrice, curveSupply, curveTokensLeft, budget);
        return getBuyQuote(tokens);
    }

    /// @notice ETH the curve pays for `amount` tokens before fees, and the fee taken from it.
    function getSellQuote(uint256 amount) public view returns (uint256 refund, uint256 fee) {
        refund =
            LinearCurveMath.sellRefund(endPrice, startPrice, curveSupply, curveTokensLeft, curveTokensLeft + amount);
        fee = refund * feeBps / BPS;
    }

    // --------------------------------------------------------------- trading

    /// @notice Buy `amount` tokens for at most msg.value (fee included); anything unused is refunded.
    /// Near the end of the curve you get whatever is left (partial fill), as long as the price per
    /// token is no worse than msg.value / amount.
    function buy(uint256 amount) external payable nonReentrant {
        if (graduated) revert AlreadyGraduated();
        (uint256 filled, uint256 cost, uint256 fee) = getBuyQuote(amount);
        _buy(filled, cost, fee, amount);
    }

    /// @notice Spend msg.value (fee included) on as many tokens as it buys, receiving at least `minTokensOut`.
    /// If the curve runs out first you get the rest of it, pay only for those tokens, and get the
    /// unused ETH back, as long as the price per token is no worse than msg.value / minTokensOut.
    function buyWithEth(uint256 minTokensOut) external payable nonReentrant {
        if (graduated) revert AlreadyGraduated();
        (uint256 filled, uint256 cost, uint256 fee) = getBuyQuoteForEth(msg.value);
        _buy(filled, cost, fee, minTokensOut);
    }

    /// @param wanted tokens the buyer asked for; with msg.value it sets the worst price per token they accept
    function _buy(uint256 filled, uint256 cost, uint256 fee, uint256 wanted) private {
        if (filled == 0) revert ZeroAmount();
        uint256 total = cost + fee;
        if (msg.value < total) revert InsufficientPayment(total, msg.value);
        // total / filled <= msg.value / wanted. A full fill passes trivially; a partial fill only passes
        // if someone else buying first hasn't pushed the leftover tokens above the price the buyer agreed to.
        if (filled * msg.value < wanted * total) revert AveragePriceTooHigh(filled, total);

        curveTokensLeft -= filled;
        ethReserve += cost;
        _transfer(address(this), msg.sender, filled);
        emit Bought(msg.sender, filled, cost, fee);

        if (curveTokensLeft == 0) {
            graduated = true;
            emit Graduated(ethReserve);
        }

        _takeFee(fee);
        _sendEth(msg.sender, msg.value - total);
    }

    /// @notice Sell `amount` tokens back to the curve for at least `minEthOut` wei after fees.
    function sell(uint256 amount, uint256 minEthOut) external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        if (amount == 0) revert ZeroAmount();

        (uint256 refund, uint256 fee) = getSellQuote(amount);
        uint256 ethOut = refund - fee;
        if (ethOut < minEthOut) revert SlippageExceeded(ethOut, minEthOut);

        _transfer(msg.sender, address(this), amount);
        curveTokensLeft += amount;
        ethReserve -= refund;
        emit Sold(msg.sender, amount, refund, fee);

        _takeFee(fee);
        _sendEth(msg.sender, ethOut);
    }

    // ------------------------------------------------------------- migration

    /// @notice After the curve sells out, anyone can push the 20% DEX allocation plus all raised ETH
    /// into the PancakeSwap V2 TOKEN/WBNB pair. The LP tokens are burned, so the liquidity is locked forever.
    ///
    /// This talks to Pancake core directly instead of the router. The router prices a deposit off the
    /// pair's existing reserves, so anyone who pre-created the pair and `sync`ed a dust donation into
    /// it could either brick migration or set the launch price. Here:
    ///   - nobody can send this token to the pair before migration (see `_update`), so it can't hold
    ///     any, and no LP can be minted ahead of us;
    ///   - `mint` credits everything above the old reserves as our deposit, so any WBNB someone donated
    ///     just ends up as extra liquidity in the pool.
    function migrate() external nonReentrant {
        if (!graduated) revert NotGraduated();
        if (migrated) revert AlreadyMigrated();
        migrated = true;

        IPoolFactory f = IPoolFactory(factory);
        IPancakeFactory pancake = IPancakeFactory(f.pancakeFactory());
        address wbnb = f.wbnb();

        address actual = pancake.getPair(address(this), wbnb);
        if (actual == address(0)) actual = pancake.createPair(address(this), wbnb);
        if (actual != pair) revert PairMismatch(pair, actual);

        uint256 ethAmount = ethReserve;
        ethReserve = 0;
        IWBNB(wbnb).deposit{value: ethAmount}();
        if (!IWBNB(wbnb).transfer(pair, ethAmount)) revert TransferFailed();
        _transfer(address(this), pair, dexSupply);
        uint256 liquidity = IPancakePair(pair).mint(DEAD);

        emit Migrated(pair, dexSupply, ethAmount, liquidity);
    }

    /// Blocks sending this token to the Pancake pair until migration, so the pair's price can't be
    /// seeded by anyone else.
    function _update(address from, address to, uint256 value) internal override {
        if (to == pair && !migrated) revert TransferToPairBeforeMigration();
        super._update(from, to, value);
    }

    // ------------------------------------------------------------------ fees

    function claimCreatorFees() external nonReentrant {
        uint256 amount = creatorFees;
        creatorFees = 0;
        emit CreatorFeesClaimed(creator, amount);
        _sendEth(creator, amount);
    }

    /// Admin's 20% goes straight to the factory; the creator's 80% waits here to be claimed,
    /// so a creator contract that rejects ETH can't block trading.
    function _takeFee(uint256 fee) private {
        uint256 adminFee = fee * ADMIN_FEE_SHARE_BPS / BPS;
        creatorFees += fee - adminFee;
        _sendEth(factory, adminFee);
    }

    function _sendEth(address to, uint256 value) private {
        if (value == 0) return;
        (bool ok,) = to.call{value: value}("");
        if (!ok) revert TransferFailed();
    }
}
