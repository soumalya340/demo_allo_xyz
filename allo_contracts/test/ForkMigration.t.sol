// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {BondingCurvePool, PoolParams, TaxAllocation} from "../src/Pool.sol";
import {IPancakeFactory} from "../src/interfaces/IPancake.sol";
import {DeployFactoryScript} from "../script/DeployFactory.s.sol";
import {ITestPair} from "./BondingCurvePool.t.sol";

/// Runs the deploy script on a fork of each live chain and migrates a coin into the real PancakeSwap.
/// Hits public RPCs, so it is opt-in:  FORK_TESTS=true forge test --match-contract ForkMigration
contract ForkMigrationTest is Test {
    // anvil's well-known first key; only ever used on a local fork
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955; // 18 decimals

    function test_Fork_BscMainnet() public {
        _deployLaunchAndMigrate("bsc", address(0), 0, 4.2 ether);
    }

    function test_Fork_BscTestnet() public {
        _deployLaunchAndMigrate("bsc_testnet", address(0), 0, 4.2 ether);
    }

    /// Real USDT as the quote token: 0.01 USDT start price, 4,200 USDT to graduate.
    function test_Fork_BscMainnetUsdtQuote() public {
        _deployLaunchAndMigrate("bsc", BSC_USDT, 0.01 ether, 4_200 ether);
    }

    function _deployLaunchAndMigrate(string memory rpc, address quote, uint256 quoteStartPrice, uint256 threshold)
        internal
    {
        if (!vm.envOr("FORK_TESTS", false)) vm.skip(true);
        vm.createSelectFork(rpc);
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_KEY)));

        PoolFactory factory = new DeployFactoryScript().run();
        if (quote != address(0)) {
            vm.prank(factory.owner());
            factory.setQuoteToken(quote, quoteStartPrice);
        }

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
                    quoteToken: quote,
                    buyFeeBps: 100,
                    sellFeeBps: 200,
                    taxAllocation: TaxAllocation({
                        creatorBps: 2_000, burnBps: 3_000, buybackBps: 4_000, holdersBps: 1_000
                    }),
                    totalSupply: 100_000 ether,
                    graduationThreshold: threshold
                }),
                0
            )
        );

        // buy out the whole curve with more than enough quote
        address buyer = makeAddr("buyer");
        uint256 budget = threshold * 2;
        if (quote == address(0)) {
            vm.deal(buyer, budget);
            vm.prank(buyer);
            pool.buyExactIn{value: budget}(budget, 0);
        } else {
            deal(quote, buyer, budget);
            vm.startPrank(buyer);
            IERC20(quote).approve(address(pool), budget);
            pool.buyExactIn(budget, 0);
            vm.stopPrank();
        }
        assertTrue(pool.graduated());

        _migrateAndCheck(factory, pool, quote == address(0) ? factory.wbnb() : quote, threshold);
    }

    /// Migrates into the real Pancake pair and checks liquidity, the leftover burn/buyback swap and the LP burn.
    function _migrateAndCheck(PoolFactory factory, BondingCurvePool pool, address pairToken, uint256 threshold)
        internal
    {
        // the graduating trade's burn/buyback tax gets swapped on the real pair during migration
        uint256 raised = pool.quoteReserve();
        uint256 leftover = pool.burnBucket() + pool.buybackBucket();
        uint256 coinsBefore = pool.totalSupply() - pool.buybackHeld();
        assertGe(raised, threshold);
        assertGt(leftover, 0);

        pool.migrate();

        // the pair the real Pancake factory created is the one the pool predicted
        ITestPair p = ITestPair(IPancakeFactory(factory.pancakeFactory()).getPair(address(pool), pairToken));
        assertEq(address(p), pool.pair());

        (uint112 r0, uint112 r1,) = p.getReserves();
        (uint256 tokenReserve, uint256 quoteReserve) = p.token0() == address(pool) ? (r0, r1) : (r1, r0);
        // coins bought on the pair were either burned (supply down) or kept (buybackHeld up)
        uint256 coinsBought = coinsBefore - (pool.totalSupply() - pool.buybackHeld());
        assertGt(coinsBought, 0);
        assertEq(tokenReserve, 20_000 ether - coinsBought);
        assertEq(quoteReserve, raised + leftover);
        assertEq(pool.burnBucket() + pool.buybackBucket(), 0);
        assertEq(p.balanceOf(pool.DEAD()), p.totalSupply() - 1000);
    }
}
