// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BondingCurvePool, PoolParams} from "./Pool.sol";

/// @notice Launches coins. Each pool is an ERC-1167 minimal proxy pointing at one BondingCurvePool implementation.
/// The owner is the admin: it collects 20% of every trading fee from every pool.
contract PoolFactory is Ownable {
    address public immutable implementation;
    address public immutable dexRouter;
    uint256 public immutable graduationThreshold; // ETH a curve raises when it sells out
    uint256 public immutable startPrice; // launch price, wei per token

    address[] public allPools;

    event PoolCreated(address indexed pool, address indexed creator, string name, string symbol, uint256 totalSupply);
    event FeesWithdrawn(address indexed to, uint256 amount);

    error TransferFailed();

    constructor(address admin, address dexRouter_, uint256 graduationThreshold_, uint256 startPrice_) Ownable(admin) {
        implementation = address(new BondingCurvePool());
        dexRouter = dexRouter_;
        graduationThreshold = graduationThreshold_;
        startPrice = startPrice_;
    }

    function createPool(PoolParams calldata params) external returns (address pool) {
        pool = Clones.clone(implementation);
        BondingCurvePool(payable(pool)).initialize(params, msg.sender, graduationThreshold, startPrice);
        allPools.push(pool);
        emit PoolCreated(pool, msg.sender, params.name, params.symbol, params.totalSupply);
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

    /// Admin fees arrive here from pools.
    receive() external payable {}
}
