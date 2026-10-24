// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @notice The parts of PancakeSwap V2 core (deps/pancake-swap-core) the pool uses to migrate liquidity.
interface IPancakeFactory {
    /// Not in Pancake's own IPancakeFactory, but a public constant on PancakeFactory.
    function INIT_CODE_PAIR_HASH() external view returns (bytes32);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPancakePair {
    function mint(address to) external returns (uint256 liquidity);
}

interface IWBNB {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}
