// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {MockWBNB} from "../test/mocks/MockWBNB.sol";

/// Deploys PoolFactory wired to PancakeSwap V2 on whichever chain the RPC points at.
///
///   BNB Chain:          forge script script/DeployFactory.s.sol --rpc-url bsc --broadcast
///   BNB Chain testnet:  forge script script/DeployFactory.s.sol --rpc-url bsc_testnet --broadcast
///   Local anvil:        forge script script/DeployFactory.s.sol --rpc-url local --broadcast
///                       (deploys its own PancakeSwap core + WBNB first)
///
/// Env (read from .env): PRIVATE_KEY (deployer). Optional: ADMIN (factory owner, defaults to the
/// deployer), PANCAKE_FACTORY / WBNB to override the addresses below or deploy to another chain.
///
/// Pools use native BNB exclusively, wrapping it into WBNB on migration.
contract DeployFactoryScript is Script {
    uint256 constant START_PRICE = 0.00001 ether; // launch price for coins paired with native BNB
    uint256 constant LAUNCH_FEE = 0.002 ether; // flat BNB fee per coin launch (admin can change it later)

    // PancakeSwap V2 factory + WBNB, checked on-chain (both factories expose INIT_CODE_PAIR_HASH)
    address constant BSC_PANCAKE_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BSC_TESTNET_PANCAKE_FACTORY = 0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    address constant BSC_TESTNET_WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    function run() public returns (PoolFactory factory) {
        uint256 deployerKey = _deployerKey();
        address deployer = vm.addr(deployerKey);
        address admin = vm.envOr("ADMIN", deployer);

        uint256 balanceBefore = deployer.balance;

        uint256 gasStart = gasleft();
        vm.startBroadcast(deployerKey);
        (address pancakeFactory, address wbnb) = _dex(admin);
        factory = new PoolFactory(admin, pancakeFactory, wbnb, START_PRICE, LAUNCH_FEE);
        vm.stopBroadcast();
        uint256 gasUsed = gasStart - gasleft();

        // forge runs this whole function locally before it broadcasts anything, so deployer.balance
        // can't change here. The "after" is estimated from gas used; script/deploy.sh prints the real one.
        uint256 estimatedCost = gasUsed * tx.gasprice;
        console.log("deployer:                    ", deployer);
        console.log("balance before (BNB):        ", _bnb(balanceBefore));
        console.log("estimated gas:               ", gasUsed);
        console.log("estimated cost (BNB):        ", _bnb(estimatedCost));
        console.log("estimated balance after (BNB):", _bnb(balanceBefore - estimatedCost));

        console.log("chain id:           ", block.chainid);
        console.log("PoolFactory:        ", address(factory));
        console.log("pool implementation:", factory.implementation());
        console.log("admin:              ", admin);
        console.log("PancakeSwap factory:", pancakeFactory);
        console.log("WBNB:               ", wbnb);
        console.log("pair init code hash:");
        console.logBytes32(factory.pairInitCodeHash());
    }

    /// wei -> "0.100000000000000000"
    function _bnb(uint256 wei_) internal pure returns (string memory frac) {
        frac = vm.toString(wei_ % 1 ether);
        while (bytes(frac).length < 18) frac = string.concat("0", frac);
        return string.concat(vm.toString(wei_ / 1 ether), ".", frac);
    }

    /// PRIVATE_KEY with or without the 0x prefix.
    function _deployerKey() internal view returns (uint256) {
        string memory key = vm.envString("PRIVATE_KEY");
        if (bytes(key).length == 64) key = string.concat("0x", key);
        return vm.parseUint(key);
    }

    function _dex(address admin) internal returns (address pancakeFactory, address wbnb) {
        if (block.chainid == 56) {
            (pancakeFactory, wbnb) = (BSC_PANCAKE_FACTORY, BSC_WBNB);
        } else if (block.chainid == 97) {
            (pancakeFactory, wbnb) = (BSC_TESTNET_PANCAKE_FACTORY, BSC_TESTNET_WBNB);
        } else if (block.chainid == 31337) {
            // Local anvil has no PancakeSwap: deploy the real core from deps/ and a stand-in WBNB.
            pancakeFactory = vm.deployCode("PancakeFactory.sol:PancakeFactory", abi.encode(admin));
            wbnb = address(new MockWBNB());
        }

        pancakeFactory = vm.envOr("PANCAKE_FACTORY", pancakeFactory);
        wbnb = vm.envOr("WBNB", wbnb);
        require(pancakeFactory != address(0) && wbnb != address(0), "set PANCAKE_FACTORY and WBNB for this chain");
    }
}
