// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BondingCurvePool, PoolParams} from "./Pool.sol";
import {IPancakeFactory} from "./interfaces/IPancake.sol";

/// @notice Launches native BNB pools and collects launch fees plus 20% of trading fees.
contract PoolFactory is Ownable {
    address public immutable implementation;
    address public immutable pancakeFactory;
    address public immutable wbnb;
    bytes32 public immutable pairInitCodeHash;
    uint256 public nativeStartPrice;
    uint256 public launchFee;
    address[] public allPools;

    event PoolCreated(
        address indexed pool, address indexed creator, address indexed quoteToken, string name, string symbol
    );
    event StartPriceSet(uint256 startPrice);
    event LaunchFeeSet(uint256 launchFee);
    event FeesWithdrawn(address indexed to, uint256 amount);

    error InvalidStartPrice();
    error InvalidMsgValue();
    error TransferFailed();

    constructor(address admin, address pancakeFactory_, address wbnb_, uint256 nativeStartPrice_, uint256 launchFee_)
        Ownable(admin)
    {
        implementation = address(new BondingCurvePool());
        pancakeFactory = pancakeFactory_;
        wbnb = wbnb_;
        pairInitCodeHash = IPancakeFactory(pancakeFactory_).INIT_CODE_PAIR_HASH();
        _setStartPrice(nativeStartPrice_);
        launchFee = launchFee_;
        emit LaunchFeeSet(launchFee_);
    }

    function setLaunchFee(uint256 launchFee_) external onlyOwner {
        launchFee = launchFee_;
        emit LaunchFeeSet(launchFee_);
    }

    /// @notice Set the launch price in wei per whole token for future pools.
    function setStartPrice(uint256 startPrice) external onlyOwner {
        _setStartPrice(startPrice);
    }

    function _setStartPrice(uint256 startPrice) private {
        if (startPrice == 0) revert InvalidStartPrice();
        nativeStartPrice = startPrice;
        emit StartPriceSet(startPrice);
    }

    /// @notice Launch a coin with native BNB as its quote token. Send exactly the launch fee.
    function createPool(PoolParams calldata params) external payable returns (address pool) {
        if (msg.value != launchFee) revert InvalidMsgValue();
        pool = Clones.clone(implementation);
        BondingCurvePool(pool).initialize(params, msg.sender, nativeStartPrice);
        allPools.push(pool);
        emit PoolCreated(pool, msg.sender, address(0), params.name, params.symbol);
    }

    function poolCount() external view returns (uint256) {
        return allPools.length;
    }

    function withdrawFees(address to) external onlyOwner {
        uint256 amount = address(this).balance;
        emit FeesWithdrawn(to, amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}
}
