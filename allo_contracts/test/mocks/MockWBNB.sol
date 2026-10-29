// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Wraps native coin 1:1, like WBNB/WBNB9.
contract MockWBNB is ERC20("Wrapped BNB", "WBNB") {
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}
