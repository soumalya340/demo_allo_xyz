// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @notice The one PancakeSwap V2 router function the pool needs to migrate liquidity.
interface IPancakeRouter02 {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}
