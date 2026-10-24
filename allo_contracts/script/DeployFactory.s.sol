// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PoolFactory} from "../src/PoolFactory.sol";

/// Usage: PANCAKE_FACTORY=<pancakeswap v2 factory> WBNB=<wbnb> \
///        forge script script/DeployFactory.s.sol --rpc-url <rpc> --broadcast
contract DeployFactoryScript is Script {
    uint256 constant GRADUATION_THRESHOLD = 4.2 ether;
    uint256 constant START_PRICE = 0.00001 ether;

    function run() public returns (PoolFactory factory) {
        address pancakeFactory = vm.envAddress("PANCAKE_FACTORY");
        address wbnb = vm.envAddress("WBNB");

        vm.startBroadcast();
        factory = new PoolFactory(msg.sender, pancakeFactory, wbnb, GRADUATION_THRESHOLD, START_PRICE);
        vm.stopBroadcast();
    }
}
