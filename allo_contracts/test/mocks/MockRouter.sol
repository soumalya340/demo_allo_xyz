// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPancakeRouter02} from "../../src/interfaces/IPancakeRouter02.sol";

/// Records what a migration sent instead of creating a real pair.
contract MockRouter is IPancakeRouter02 {
    address public lastToken;
    address public lastTo;
    uint256 public lastTokenAmount;
    uint256 public lastEthAmount;

    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256, uint256, address to, uint256)
        external
        payable
        returns (uint256, uint256, uint256)
    {
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        lastToken = token;
        lastTo = to;
        lastTokenAmount = amountTokenDesired;
        lastEthAmount = msg.value;
        return (amountTokenDesired, msg.value, 1);
    }
}
