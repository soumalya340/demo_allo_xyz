// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {BondingCurvePool, PoolParams} from "../src/Pool.sol";
import {IPancakeFactory} from "../src/interfaces/IPancake.sol";
import {DeployFactoryScript} from "../script/DeployFactory.s.sol";
import {ITestPair} from "./BondingCurvePool.t.sol";

/// Runs the deploy script on a fork of each live chain and migrates a coin into the real PancakeSwap.
/// Hits public RPCs, so it is opt-in:  FORK_TESTS=true forge test --match-contract ForkMigration
contract ForkMigrationTest is Test {
    // anvil's well-known first key; only ever used on a local fork
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function test_Fork_BscMainnet() public {
        _deployLaunchAndMigrate("bsc");
    }

    function test_Fork_BscTestnet() public {
        _deployLaunchAndMigrate("bsc_testnet");
    }

    function _deployLaunchAndMigrate(string memory rpc) internal {
        if (!vm.envOr("FORK_TESTS", false)) vm.skip(true);
        vm.createSelectFork(rpc);
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_KEY)));

        PoolFactory factory = new DeployFactoryScript().run();

        address creator = makeAddr("creator");
        vm.prank(creator);
        BondingCurvePool pool = BondingCurvePool(
            factory.createPool(
                PoolParams({
                    name: "Fork Coin",
                    symbol: "FORK",
                    imageUrl: "",
                    website: "",
                    twitter: "",
                    feeBps: 100,
                    totalSupply: 100_000 ether
                })
            )
        );

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        pool.buyWithEth{value: 10 ether}(0);
        assertTrue(pool.graduated());

        pool.migrate();

        // the pair the real Pancake factory created is the one the pool predicted
        address pair = IPancakeFactory(factory.pancakeFactory()).getPair(address(pool), factory.wbnb());
        assertEq(pair, pool.pair());

        ITestPair p = ITestPair(pair);
        (uint112 r0, uint112 r1,) = p.getReserves();
        (uint256 tokenReserve, uint256 wbnbReserve) = p.token0() == address(pool) ? (r0, r1) : (r1, r0);
        assertEq(tokenReserve, 20_000 ether);
        assertEq(wbnbReserve, 4.2 ether);
        assertEq(p.balanceOf(pool.DEAD()), p.totalSupply() - 1000);
    }
}
