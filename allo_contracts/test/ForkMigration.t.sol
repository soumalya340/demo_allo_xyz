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
        uint256 threshold = 4.2 ether;
        if (!vm.envOr("FORK_TESTS", false)) vm.skip(true);
        vm.createSelectFork(rpc);
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_KEY)));

        PoolFactory factory = new DeployFactoryScript().run();
        address creator = makeAddr("creator");
        uint256 launchFee = factory.launchFee();
        vm.deal(creator, launchFee);
        vm.prank(creator);
        BondingCurvePool pool = BondingCurvePool(
            factory.createPool{value: launchFee}(
                PoolParams({
                    name: "Fork Coin",
                    symbol: "FORK",
                    imageUrl: "",
                    website: "",
                    twitter: "",
                    description: "",
                    buyFeeBps: 100,
                    sellFeeBps: 200,
                    totalSupply: 100_000 ether,
                    graduationThreshold: threshold
                })
            )
        );

        // buy out the whole curve with more than enough quote
        address buyer = makeAddr("buyer");
        uint256 budget = threshold * 2;
        vm.deal(buyer, budget);
        vm.prank(buyer);
        pool.buy{value: budget}(pool.curveSupply(), budget);
        assertTrue(pool.graduated());

        _migrateAndCheck(factory, pool, factory.wbnb(), threshold);
    }

    /// Migrates native BNB into the real Pancake pair and verifies reserves and locked LP.
    function _migrateAndCheck(PoolFactory factory, BondingCurvePool pool, address pairToken, uint256 threshold)
        internal
    {
        uint256 fees = pool.creatorFees();
        pool.migrate();
        ITestPair p = ITestPair(IPancakeFactory(factory.pancakeFactory()).getPair(address(pool), pairToken));
        assertEq(address(p), pool.pair());
        (uint112 r0, uint112 r1,) = p.getReserves();
        (uint256 tokenReserve, uint256 quoteReserve) = p.token0() == address(pool) ? (r0, r1) : (r1, r0);
        assertEq(tokenReserve, pool.dexSupply());
        assertEq(quoteReserve, threshold);
        assertEq(pool.quoteReserve(), 0);
        assertEq(address(pool).balance, fees);
        assertEq(p.balanceOf(pool.DEAD()), p.totalSupply() - 1000);
        pool.claimFees();
        assertEq(pool.creator().balance, fees);
        assertEq(address(pool).balance, 0);
    }
}
