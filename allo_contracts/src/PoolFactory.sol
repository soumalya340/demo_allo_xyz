// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BondingCurvePool, PoolParams} from "./Pool.sol";
import {IPancakeFactory} from "./interfaces/IPancake.sol";

/// @notice Launches coins. Each pool is an ERC-1167 minimal proxy pointing at one BondingCurvePool implementation.
/// The owner is the admin: it decides which quote tokens coins may trade against, and the platform earns
/// a flat launch fee (in BNB) on every new coin plus 20% of every trading tax from every pool.
contract PoolFactory is Ownable {
    using SafeERC20 for IERC20;

    address public constant NATIVE = address(0);

    address public immutable implementation;
    address public immutable pancakeFactory; // PancakeSwap V2 factory pools migrate into
    address public immutable wbnb;
    bytes32 public immutable pairInitCodeHash; // read from pancakeFactory, used to predict pair addresses

    /// Launch price for each allowed quote token, in its units per whole coin; 0 = not allowed.
    /// NATIVE (address(0)) is native BNB.
    mapping(address => uint256) public startPriceOf;

    uint256 public launchFee; // flat BNB fee paid by the creator on createPool

    address[] public allPools;

    event PoolCreated(
        address indexed pool, address indexed creator, address indexed quoteToken, string name, string symbol
    );
    event QuoteTokenSet(address indexed token, uint256 startPrice);
    event LaunchFeeSet(uint256 launchFee);
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);

    error QuoteTokenNotAllowed(address token);
    error InvalidMsgValue();
    error TransferFailed();

    /// @param nativeStartPrice launch price for coins paired with native BNB, wei per coin (e.g. 0.00001 ether)
    /// @param launchFee_ flat BNB fee per launch (e.g. 0.002 ether)
    constructor(address admin, address pancakeFactory_, address wbnb_, uint256 nativeStartPrice, uint256 launchFee_)
        Ownable(admin)
    {
        implementation = address(new BondingCurvePool());
        pancakeFactory = pancakeFactory_;
        wbnb = wbnb_;
        pairInitCodeHash = IPancakeFactory(pancakeFactory_).INIT_CODE_PAIR_HASH();
        _setQuoteToken(NATIVE, nativeStartPrice);
        launchFee = launchFee_;
        emit LaunchFeeSet(launchFee_);
    }

    function setLaunchFee(uint256 launchFee_) external onlyOwner {
        launchFee = launchFee_;
        emit LaunchFeeSet(launchFee_);
    }

    /// @notice Allow `token` as a quote token with this launch price, change its price, or remove it (0).
    /// Only plain ERC20s belong here: fee-on-transfer or rebasing tokens break a pool's accounting.
    /// Existing pools keep the price they launched with.
    function setQuoteToken(address token, uint256 startPrice) external onlyOwner {
        _setQuoteToken(token, startPrice);
    }

    function _setQuoteToken(address token, uint256 startPrice) private {
        startPriceOf[token] = startPrice;
        emit QuoteTokenSet(token, startPrice);
    }

    /// @notice Launch a coin. The creator picks the quote token (from the allowed list), buy and sell tax,
    /// tax allocation, supply and graduation threshold in `params`.
    /// msg.value = launchFee, plus firstBuyAmount when the coin is paired with native BNB.
    /// @param firstBuyAmount optional tax-free first buy for the creator, in quote, made in this same
    /// transaction. ERC20 quote: approve this factory for it first.
    function createPool(PoolParams calldata params, uint256 firstBuyAmount) external payable returns (address pool) {
        uint256 startPrice = startPriceOf[params.quoteToken];
        if (startPrice == 0) revert QuoteTokenNotAllowed(params.quoteToken);
        bool native = params.quoteToken == NATIVE;
        uint256 firstBuyValue = native ? firstBuyAmount : 0;
        if (msg.value != launchFee + firstBuyValue) revert InvalidMsgValue();

        pool = Clones.clone(implementation);
        BondingCurvePool(pool).initialize(params, msg.sender, startPrice);
        allPools.push(pool);
        emit PoolCreated(pool, msg.sender, params.quoteToken, params.name, params.symbol);

        if (firstBuyAmount > 0) {
            if (!native) IERC20(params.quoteToken).safeTransferFrom(msg.sender, pool, firstBuyAmount);
            BondingCurvePool(pool).firstBuy{value: firstBuyValue}(firstBuyAmount);
        }
    }

    function poolCount() external view returns (uint256) {
        return allPools.length;
    }

    /// @notice Withdraw the admin's collected fees in `token` (NATIVE for BNB).
    function withdrawFees(address token, address to) external onlyOwner {
        uint256 amount = token == NATIVE ? address(this).balance : IERC20(token).balanceOf(address(this));
        emit FeesWithdrawn(token, to, amount);
        if (token == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// The platform's share of BNB tax arrives here from pools (launch fees are kept from createPool).
    receive() external payable {}
}
