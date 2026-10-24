// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {BondingCurvePool, PoolParams} from "../src/Pool.sol";
import {IPancakeFactory} from "../src/interfaces/IPancake.sol";
import {MockWBNB} from "./mocks/MockWBNB.sol";

/// Pair functions the tests read; the pair itself is the real PancakePair from deps/.
interface ITestPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function sync() external;
}

contract BondingCurvePoolTest is Test {
    uint256 constant THRESHOLD = 4.2 ether;
    uint256 constant START_PRICE = 0.00001 ether;
    uint256 constant SUPPLY = 100_000 ether; // 80k on the curve, 20k for the DEX
    uint256 constant FEE_BPS = 100; // 1%

    PoolFactory factory;
    IPancakeFactory pancake;
    MockWBNB wbnb;
    BondingCurvePool pool;

    address admin = makeAddr("admin");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        pancake = IPancakeFactory(deployCode("PancakeFactory.sol:PancakeFactory", abi.encode(admin)));
        wbnb = new MockWBNB();
        factory = new PoolFactory(admin, address(pancake), address(wbnb), START_PRICE);

        vm.prank(creator);
        pool = BondingCurvePool(factory.createPool(_params(SUPPLY, FEE_BPS)));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _params(uint256 supply, uint256 feeBps) internal pure returns (PoolParams memory) {
        return _params(supply, feeBps, THRESHOLD);
    }

    function _params(uint256 supply, uint256 feeBps, uint256 threshold) internal pure returns (PoolParams memory) {
        return PoolParams({
            name: "Allo Coin",
            symbol: "ALLO",
            imageUrl: "https://example.com/allo.png",
            website: "https://example.com",
            twitter: "https://x.com/allo",
            feeBps: feeBps,
            totalSupply: supply,
            graduationThreshold: threshold
        });
    }

    function _buy(address who, uint256 amount) internal returns (uint256 paid) {
        (, uint256 cost, uint256 fee) = pool.getBuyQuote(amount);
        paid = cost + fee;
        vm.prank(who);
        pool.buy{value: paid}(amount);
    }

    // -------------------------------------------------------------- creation

    function test_CreatePool_StoresMetadataAndSplitsSupply() public view {
        assertEq(pool.name(), "Allo Coin");
        assertEq(pool.symbol(), "ALLO");
        assertEq(pool.imageUrl(), "https://example.com/allo.png");
        assertEq(pool.website(), "https://example.com");
        assertEq(pool.twitter(), "https://x.com/allo");
        assertEq(pool.feeBps(), FEE_BPS);
        assertEq(pool.creator(), creator);
        assertEq(pool.factory(), address(factory));

        assertEq(pool.totalSupply(), SUPPLY);
        assertEq(pool.balanceOf(address(pool)), SUPPLY);
        assertEq(pool.curveSupply(), 80_000 ether);
        assertEq(pool.dexSupply(), 20_000 ether);
        assertEq(factory.poolCount(), 1);
    }

    function test_PoolIsMinimalProxy() public view {
        // ERC-1167 runtime code is exactly 45 bytes
        assertEq(address(pool).code.length, 45);
    }

    function test_CurveEndsAtPriceThatRaisesThreshold() public view {
        // b = 2 * 4.2 / 80,000 - 0.00001 = 0.000095 ETH
        assertEq(pool.startPrice(), START_PRICE);
        assertEq(pool.endPrice(), 0.000095 ether);
        assertEq(pool.currentPrice(), START_PRICE);
    }

    function test_RevertWhen_SupplyTooLargeForThreshold() public {
        // 80% of 525k = 420k tokens; at 0.00001 ETH that alone is 4.2 ETH, so the price couldn't rise
        vm.expectRevert(BondingCurvePool.InvalidCurve.selector);
        factory.createPool(_params(525_000 ether, FEE_BPS));
    }

    function test_CreatorPicksThreshold() public {
        // 8k tokens on the curve; b = 2 * 0.4 / 8,000 - 0.00001 = 0.00009 ETH
        BondingCurvePool small = BondingCurvePool(factory.createPool(_params(10_000 ether, FEE_BPS, 0.4 ether)));
        assertEq(small.graduationThreshold(), 0.4 ether);
        assertEq(small.endPrice(), 0.00009 ether);

        (, uint256 cost, uint256 fee) = small.getBuyQuote(8_000 ether);
        vm.prank(alice);
        small.buy{value: cost + fee}(8_000 ether);
        assertTrue(small.graduated());
        assertEq(small.ethReserve(), 0.4 ether);
    }

    function test_RevertWhen_ThresholdTooLowForSupply() public {
        // 80k tokens at 0.00001 ETH already raise 0.8 ETH, so 0.8 ETH or less can't make the price rise
        vm.expectRevert(BondingCurvePool.InvalidCurve.selector);
        factory.createPool(_params(SUPPLY, FEE_BPS, 0.8 ether));

        vm.expectRevert(BondingCurvePool.InvalidCurve.selector);
        factory.createPool(_params(SUPPLY, FEE_BPS, 0));
    }

    function test_RevertWhen_FeeTooHigh() public {
        vm.expectRevert(BondingCurvePool.FeeTooHigh.selector);
        factory.createPool(_params(SUPPLY, 1_001));
    }

    function test_RevertWhen_InitializingImplementationOrCloneAgain() public {
        BondingCurvePool impl = BondingCurvePool(factory.implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(_params(SUPPLY, FEE_BPS), alice, START_PRICE);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pool.initialize(_params(SUPPLY, FEE_BPS), alice, START_PRICE);
    }

    // ---------------------------------------------------------------- buying

    function test_Buy_ChargesAreaUnderCurvePlusFee() public {
        // x: 80k -> 70k left. Price goes 0.00001 -> 0.000020625, average 0.0000153125 * 10k tokens
        (uint256 filled, uint256 cost, uint256 fee) = pool.getBuyQuote(10_000 ether);
        assertEq(filled, 10_000 ether);
        assertEq(cost, 0.153125 ether);
        assertEq(fee, 0.00153125 ether);

        _buy(alice, 10_000 ether);

        assertEq(pool.balanceOf(alice), 10_000 ether);
        assertEq(pool.curveTokensLeft(), 70_000 ether);
        assertEq(pool.ethReserve(), cost);
        assertEq(pool.currentPrice(), 0.000020625 ether);
    }

    function test_Buy_SplitsFee20Admin80Creator() public {
        _buy(alice, 10_000 ether);
        // fee 0.00153125 ETH -> 20% admin, 80% creator
        assertEq(address(factory).balance, 0.00030625 ether);
        assertEq(pool.creatorFees(), 0.001225 ether);
        assertEq(address(pool).balance, pool.ethReserve() + pool.creatorFees());
    }

    function test_Buy_RefundsExcessEth() public {
        (, uint256 cost, uint256 fee) = pool.getBuyQuote(10_000 ether);
        vm.prank(alice);
        pool.buy{value: 10 ether}(10_000 ether);
        assertEq(alice.balance, 100 ether - cost - fee);
    }

    function test_RevertWhen_UnderPaying() public {
        (, uint256 cost, uint256 fee) = pool.getBuyQuote(10_000 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondingCurvePool.InsufficientPayment.selector, cost + fee, cost));
        pool.buy{value: cost}(10_000 ether);
    }

    function test_Buy_PartialFillAtEndOfCurve() public {
        _buy(alice, 50_000 ether);

        // bob asks for 50k but only 30k are left
        (, uint256 cost, uint256 fee) = pool.getBuyQuote(30_000 ether);
        vm.prank(bob);
        pool.buy{value: 10 ether}(50_000 ether);

        assertEq(pool.balanceOf(bob), 30_000 ether);
        assertEq(bob.balance, 100 ether - cost - fee);
        assertEq(pool.curveTokensLeft(), 0);
        assertTrue(pool.graduated());
    }

    function test_RevertWhen_PartialFillCostsMorePerToken() public {
        // bob prices 50k tokens from the bottom of the curve and allows exactly that spend
        (, uint256 cost, uint256 fee) = pool.getBuyQuote(50_000 ether);
        uint256 maxSpend = cost + fee;

        // alice gets in first and leaves only the 10k most expensive tokens
        _buy(alice, 70_000 ether);
        (uint256 filled,,) = pool.getBuyQuote(50_000 ether);
        (, uint256 leftCost, uint256 leftFee) = pool.getBuyQuote(filled);
        assertLt(leftCost + leftFee, maxSpend); // fits the budget, but per token it's far worse

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(BondingCurvePool.AveragePriceTooHigh.selector, 10_000 ether, leftCost + leftFee)
        );
        pool.buy{value: maxSpend}(50_000 ether);
    }

    // ------------------------------------------------------------ buy with ETH

    function test_BuyWithEth_SpendsTheWholeBudget() public {
        (uint256 filled, uint256 cost, uint256 fee) = pool.getBuyQuoteForEth(0.1 ether);

        vm.prank(alice);
        pool.buyWithEth{value: 0.1 ether}(filled);

        assertEq(pool.balanceOf(alice), filled);
        assertEq(alice.balance, 100 ether - cost - fee);
        assertLe(cost + fee, 0.1 ether);
        assertApproxEqAbs(cost + fee, 0.1 ether, 1e6); // only rounding dust is refunded
        // fee is 1% of cost
        assertEq(fee, cost * FEE_BPS / 10_000);
    }

    function test_BuyWithEth_MatchesExactTokenBuy() public view {
        // 0.153125 ETH + 1% fee buys exactly 10k tokens from the start (see test_Buy_ChargesAreaUnderCurvePlusFee)
        (uint256 filled,,) = pool.getBuyQuoteForEth(0.15465625 ether);
        assertApproxEqRel(filled, 10_000 ether, 1e9); // within 1e-9 %
        assertLe(filled, 10_000 ether); // never more than the budget covers
    }

    function test_BuyWithEth_PartialFillRefundsUnusedEth() public {
        _buy(alice, 70_000 ether);

        // bob throws 5 ETH at a curve that only has 10k tokens left
        (, uint256 cost, uint256 fee) = pool.getBuyQuote(10_000 ether);
        vm.prank(bob);
        pool.buyWithEth{value: 5 ether}(1_000 ether);

        assertEq(pool.balanceOf(bob), 10_000 ether);
        assertEq(bob.balance, 100 ether - cost - fee); // paid only for the 10k
        assertTrue(pool.graduated());
        assertEq(pool.ethReserve(), THRESHOLD);
    }

    function test_RevertWhen_BuyWithEthPartialFillCostsMorePerToken() public {
        // bob quotes 1 ETH from the bottom of the curve and insists on that rate
        (uint256 expected,,) = pool.getBuyQuoteForEth(1 ether);

        _buy(alice, 70_000 ether);

        vm.prank(bob);
        vm.expectPartialRevert(BondingCurvePool.AveragePriceTooHigh.selector);
        pool.buyWithEth{value: 1 ether}(expected);
    }

    function test_RevertWhen_BuyWithEthTooSmallForOneUnit() public {
        vm.prank(alice);
        vm.expectRevert(BondingCurvePool.ZeroAmount.selector);
        pool.buyWithEth{value: 0}(0);
    }

    function testFuzz_BuyWithEthNeverOverspends(uint256 pre, uint256 ethIn) public {
        pre = bound(pre, 0, 79_999 ether);
        ethIn = bound(ethIn, 1 gwei, 10 ether);
        if (pre > 0) _buy(alice, pre);

        uint256 before = bob.balance;
        (uint256 filled, uint256 cost, uint256 fee) = pool.getBuyQuoteForEth(ethIn);
        vm.assume(filled > 0);
        // a tiny bit more than `filled` would cost more than the budget, unless the curve runs out first
        bool curveRunsOut = filled == pool.curveTokensLeft();
        (, uint256 nextCost, uint256 nextFee) = pool.getBuyQuote(filled + 1e12);

        vm.prank(bob);
        pool.buyWithEth{value: ethIn}(0);

        assertLe(cost + fee, ethIn);
        assertEq(bob.balance, before - cost - fee);
        assertEq(pool.balanceOf(bob), filled);
        if (!curveRunsOut) assertGt(nextCost + nextFee, ethIn);
    }

    function test_SellingOutCurveRaisesExactlyThreshold() public {
        _buy(alice, 80_000 ether);
        assertEq(pool.ethReserve(), THRESHOLD);
        assertEq(pool.currentPrice(), 0.000095 ether);
        assertTrue(pool.graduated());
    }

    // --------------------------------------------------------------- selling

    function test_Sell_ReturnsAreaUnderCurveMinusFee() public {
        _buy(alice, 10_000 ether);
        _buy(bob, 10_000 ether);

        (uint256 refund, uint256 fee) = pool.getSellQuote(10_000 ether);
        uint256 balanceBefore = bob.balance;
        vm.prank(bob);
        pool.sell(10_000 ether, refund - fee);

        assertEq(bob.balance, balanceBefore + refund - fee);
        assertEq(pool.balanceOf(bob), 0);
        assertEq(pool.curveTokensLeft(), 70_000 ether);
        assertEq(pool.currentPrice(), 0.000020625 ether);
    }

    function test_RevertWhen_SellSlippage() public {
        _buy(alice, 10_000 ether);
        (uint256 refund, uint256 fee) = pool.getSellQuote(10_000 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondingCurvePool.SlippageExceeded.selector, refund - fee, refund));
        pool.sell(10_000 ether, refund);
    }

    function test_RevertWhen_SellingTokensYouDontHave() public {
        _buy(alice, 10_000 ether);
        vm.prank(bob);
        vm.expectRevert();
        pool.sell(1 ether, 0);
    }

    // ------------------------------------------------------------- migration

    function test_RevertWhen_TradingAfterGraduation() public {
        _buy(alice, 80_000 ether);

        vm.prank(bob);
        vm.expectRevert(BondingCurvePool.AlreadyGraduated.selector);
        pool.buy{value: 1 ether}(1 ether);

        vm.prank(alice);
        vm.expectRevert(BondingCurvePool.AlreadyGraduated.selector);
        pool.sell(1 ether, 0);
    }

    function test_RevertWhen_MigratingBeforeGraduation() public {
        vm.expectRevert(BondingCurvePool.NotGraduated.selector);
        pool.migrate();
    }

    /// Reserves of the pair as (pool token, WBNB).
    function _reserves() internal view returns (uint256 tokenReserve, uint256 wbnbReserve) {
        ITestPair p = ITestPair(pool.pair());
        (uint112 r0, uint112 r1,) = p.getReserves();
        (tokenReserve, wbnbReserve) = p.token0() == address(pool) ? (r0, r1) : (r1, r0);
    }

    function test_PairAddressIsPredictedBeforeCreation() public {
        assertEq(pancake.getPair(address(pool), address(wbnb)), address(0));
        address created = pancake.createPair(address(pool), address(wbnb));
        assertEq(created, pool.pair());
    }

    function test_Migrate_SeedsPancakePairAndBurnsLp() public {
        _buy(alice, 80_000 ether);
        pool.migrate();

        address pair = pancake.getPair(address(pool), address(wbnb));
        assertEq(pair, pool.pair());
        (uint256 tokenReserve, uint256 wbnbReserve) = _reserves();
        assertEq(tokenReserve, 20_000 ether);
        assertEq(wbnbReserve, THRESHOLD);

        // all LP except Pancake's MINIMUM_LIQUIDITY (locked at address(0)) is burned to DEAD
        ITestPair p = ITestPair(pair);
        assertEq(p.balanceOf(pool.DEAD()), p.totalSupply() - 1000);
        assertEq(p.balanceOf(address(0)), 1000);

        assertEq(pool.ethReserve(), 0);
        assertEq(pool.balanceOf(address(pool)), 0);
        // only the unclaimed creator fees remain
        assertEq(address(pool).balance, pool.creatorFees());

        vm.expectRevert(BondingCurvePool.AlreadyMigrated.selector);
        pool.migrate();
    }

    function test_RevertWhen_SendingTokenToPairBeforeMigration() public {
        _buy(alice, 1_000 ether);
        address pair = pool.pair();

        vm.startPrank(alice);
        vm.expectRevert(BondingCurvePool.TransferToPairBeforeMigration.selector);
        pool.transfer(pair, 1 ether);

        // transferFrom goes through the same check
        pool.approve(bob, 1 ether);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(BondingCurvePool.TransferToPairBeforeMigration.selector);
        pool.transferFrom(alice, pair, 1 ether);
    }

    function test_TransfersToPairAllowedAfterMigration() public {
        _buy(alice, 80_000 ether);
        pool.migrate();

        address pair = pool.pair();
        vm.prank(alice);
        pool.transfer(pair, 1 ether);
        assertEq(pool.balanceOf(pair), 20_000 ether + 1 ether);
    }

    /// The attack that bricked the router version: pre-create the pair, donate dust WBNB, sync.
    /// Reserves become (0, 1 wei), which made the router's quote() revert forever.
    function test_Migrate_SurvivesPreCreatedPairWithSyncedDonation() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        vm.startPrank(attacker);
        address pair = pancake.createPair(address(pool), address(wbnb));
        wbnb.deposit{value: 1 ether}();
        wbnb.transfer(pair, 1);
        ITestPair(pair).sync();
        vm.stopPrank();

        _buy(alice, 80_000 ether);
        pool.migrate();

        // the donation just becomes extra liquidity; the attacker holds no LP
        (uint256 tokenReserve, uint256 wbnbReserve) = _reserves();
        assertEq(tokenReserve, 20_000 ether);
        assertEq(wbnbReserve, THRESHOLD + 1);
        assertEq(ITestPair(pair).balanceOf(attacker), 0);
    }

    /// Same, but with a large unsynced donation: still credited to the pool, not to the attacker.
    function test_Migrate_SurvivesUnsyncedDonation() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 10 ether);
        vm.startPrank(attacker);
        wbnb.deposit{value: 10 ether}();
        wbnb.transfer(pool.pair(), 10 ether); // pair doesn't even exist yet
        vm.stopPrank();

        _buy(alice, 80_000 ether);
        pool.migrate();

        (uint256 tokenReserve, uint256 wbnbReserve) = _reserves();
        assertEq(tokenReserve, 20_000 ether);
        assertEq(wbnbReserve, THRESHOLD + 10 ether);
        assertEq(ITestPair(pool.pair()).balanceOf(attacker), 0);
    }

    // ------------------------------------------------------------------ fees

    function test_CreatorClaimsFees() public {
        _buy(alice, 10_000 ether);
        uint256 owed = pool.creatorFees();

        vm.prank(alice); // anyone can trigger it, ETH always goes to the creator
        pool.claimCreatorFees();

        assertEq(creator.balance, owed);
        assertEq(pool.creatorFees(), 0);
    }

    function test_AdminWithdrawsFees() public {
        _buy(alice, 10_000 ether);
        uint256 owed = address(factory).balance;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.withdrawFees(alice);

        vm.prank(admin);
        factory.withdrawFees(admin);
        assertEq(admin.balance, owed);
    }

    // ------------------------------------------------------------ invariants

    /// The pool can always buy back every circulating token, and its ETH covers reserve + creator fees.
    function testFuzz_PoolStaysSolvent(uint256 a, uint256 b, uint256 s) public {
        a = bound(a, 1, 40_000 ether);
        b = bound(b, 1, 39_999 ether); // a + b stays below 80k so the curve doesn't graduate before the sell
        _buy(alice, a);
        _buy(bob, b);

        s = bound(s, 1, a);
        vm.prank(alice);
        pool.sell(s, 0);

        uint256 circulating = pool.curveSupply() - pool.curveTokensLeft();
        (uint256 refundAll,) = pool.getSellQuote(circulating);
        assertGe(pool.ethReserve(), refundAll);
        assertEq(address(pool).balance, pool.ethReserve() + pool.creatorFees());
    }
}
