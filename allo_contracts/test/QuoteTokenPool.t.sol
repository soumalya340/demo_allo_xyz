// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {BondingCurvePool, PoolParams, TaxAllocation} from "../src/Pool.sol";
import {IPancakeFactory} from "../src/interfaces/IPancake.sol";
import {MockWBNB} from "./mocks/MockWBNB.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ITestPair} from "./BondingCurvePool.t.sol";

/// Coins that trade against an ERC20 instead of native BNB.
contract QuoteTokenPoolTest is Test {
    // Same curve shape as the native tests, priced in a USDT-like token at 1,000x:
    // 0.01 USDT -> 0.095 USDT per coin, 4,200 USDT raised when the 80k-coin curve sells out.
    uint256 constant SUPPLY = 100_000 ether;
    uint256 constant START_PRICE = 0.01 ether;
    uint256 constant THRESHOLD = 4_200 ether;
    uint256 constant BUY_FEE_BPS = 100; // 1%
    uint256 constant SELL_FEE_BPS = 200; // 2%

    PoolFactory factory;
    IPancakeFactory pancake;
    MockERC20 usdt;
    BondingCurvePool pool;

    address admin = makeAddr("admin");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        pancake = IPancakeFactory(deployCode("PancakeFactory.sol:PancakeFactory", abi.encode(admin)));
        factory = new PoolFactory(admin, address(pancake), address(new MockWBNB()), 0.00001 ether, 0);
        usdt = new MockERC20("Tether USD", "USDT", 18);

        vm.prank(admin);
        factory.setQuoteToken(address(usdt), START_PRICE);

        vm.prank(creator);
        pool = BondingCurvePool(factory.createPool(_params(address(usdt), THRESHOLD), 0));

        for (uint256 i; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            usdt.mint(who, 100_000 ether);
            vm.prank(who);
            usdt.approve(address(pool), type(uint256).max);
        }
    }

    function _params(address quote, uint256 threshold) internal pure returns (PoolParams memory) {
        return PoolParams({
            name: "Allo Coin",
            symbol: "ALLO",
            imageUrl: "",
            website: "",
            twitter: "",
            quoteToken: quote,
            buyFeeBps: BUY_FEE_BPS,
            sellFeeBps: SELL_FEE_BPS,
            taxAllocation: TaxAllocation({creatorBps: 10_000, burnBps: 0, buybackBps: 0, holdersBps: 0}),
            totalSupply: SUPPLY,
            graduationThreshold: threshold
        });
    }

    function _buy(address who, uint256 amount) internal returns (uint256 paid) {
        (, uint256 cost, uint256 fee) = pool.getBuyQuote(amount);
        paid = cost + fee;
        vm.prank(who);
        pool.buy(amount, paid);
    }

    function _reserves(BondingCurvePool p) internal view returns (uint256 tokenReserve, uint256 quoteReserve) {
        ITestPair pair = ITestPair(p.pair());
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (tokenReserve, quoteReserve) = pair.token0() == address(p) ? (r0, r1) : (r1, r0);
    }

    // ---------------------------------------------------------------- curve

    function test_CurveIsPricedInQuoteToken() public view {
        assertEq(pool.quoteToken(), address(usdt));
        assertEq(pool.startPrice(), START_PRICE);
        assertEq(pool.endPrice(), 0.095 ether); // 2 * 4,200 / 80,000 - 0.01
        assertEq(pool.currentPrice(), START_PRICE);
    }

    /// A pool's quote token is fixed at launch. The admin delisting or repricing it on the factory only
    /// affects new pools; this one keeps its token, price and pair, and keeps trading.
    function test_QuoteTokenIsFixedForever() public {
        address pairBefore = pool.pair();

        vm.startPrank(admin);
        factory.setQuoteToken(address(usdt), 1 ether); // reprice
        factory.setQuoteToken(address(usdt), 0); // then delist
        vm.stopPrank();

        assertEq(pool.quoteToken(), address(usdt));
        assertEq(pool.startPrice(), START_PRICE);
        assertEq(pool.pair(), pairBefore);
        _buy(alice, 10_000 ether);
        vm.prank(alice);
        pool.sell(10_000 ether, 0);

        // new pools can't use the delisted token
        vm.expectRevert(abi.encodeWithSelector(PoolFactory.QuoteTokenNotAllowed.selector, address(usdt)));
        factory.createPool(_params(address(usdt), THRESHOLD), 0);
    }

    // --------------------------------------------------------------- trading

    function test_Buy_PullsExactCostPlusTax() public {
        (, uint256 cost, uint256 fee) = pool.getBuyQuote(10_000 ether);
        assertEq(cost, 153.125 ether);
        assertEq(fee, 1.53125 ether);

        // an ERC20 buyer can pass "no limit"; the pool pulls exactly cost + tax
        vm.prank(alice);
        pool.buy(10_000 ether, type(uint256).max);

        assertEq(pool.balanceOf(alice), 10_000 ether);
        assertEq(usdt.balanceOf(alice), 100_000 ether - cost - fee);
        assertEq(pool.quoteReserve(), cost);
        assertEq(usdt.balanceOf(address(factory)), fee * 2_000 / 10_000);
        assertEq(usdt.balanceOf(address(pool)), pool.quoteReserve() + pool.creatorFees());
    }

    function test_RevertWhen_SendingBnbToErc20Pool() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(BondingCurvePool.InvalidMsgValue.selector);
        pool.buy{value: 1}(10 ether, type(uint256).max);
    }

    function test_RevertWhen_MaxInBelowCost() public {
        (, uint256 cost, uint256 fee) = pool.getBuyQuote(10_000 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondingCurvePool.InsufficientPayment.selector, cost + fee, cost));
        pool.buy(10_000 ether, cost);
    }

    function test_BuyExactIn_SpendsAtMostAmountIn() public {
        (uint256 filled, uint256 cost, uint256 fee) = pool.getBuyQuoteExactIn(100 ether);
        vm.prank(alice);
        pool.buyExactIn(100 ether, filled);

        assertEq(pool.balanceOf(alice), filled);
        assertEq(usdt.balanceOf(alice), 100_000 ether - cost - fee);
        assertLe(cost + fee, 100 ether);
        assertApproxEqAbs(cost + fee, 100 ether, 1e6);
    }

    function test_BuyExactIn_PartialFillOnlyChargesWhatIsUsed() public {
        _buy(alice, 70_000 ether);
        (, uint256 cost, uint256 fee) = pool.getBuyQuote(10_000 ether);

        vm.prank(bob);
        pool.buyExactIn(50_000 ether, 0); // far more than the last 10k coins cost

        assertEq(pool.balanceOf(bob), 10_000 ether);
        assertEq(usdt.balanceOf(bob), 100_000 ether - cost - fee);
        assertTrue(pool.graduated());
        assertEq(pool.quoteReserve(), THRESHOLD);
    }

    function test_Sell_PaysQuoteMinusSellTax() public {
        _buy(alice, 10_000 ether);
        _buy(bob, 10_000 ether);

        (uint256 refund, uint256 fee) = pool.getSellQuote(10_000 ether);
        assertEq(fee, refund * SELL_FEE_BPS / 10_000);
        uint256 before = usdt.balanceOf(bob);
        vm.prank(bob);
        pool.sell(10_000 ether, refund - fee);

        assertEq(usdt.balanceOf(bob), before + refund - fee);
        assertEq(pool.balanceOf(bob), 0);
    }

    // ------------------------------------------------------------------ fees

    function test_FeesAreCollectedAndPaidInQuoteToken() public {
        _buy(alice, 10_000 ether);
        vm.prank(alice);
        pool.sell(5_000 ether, 0);

        uint256 adminOwed = usdt.balanceOf(address(factory));
        assertGt(adminOwed, 0);
        vm.prank(admin);
        factory.withdrawFees(address(usdt), admin);
        assertEq(usdt.balanceOf(admin), adminOwed);

        uint256 creatorOwed = pool.creatorFees();
        pool.claimCreatorFees();
        assertEq(usdt.balanceOf(creator), creatorOwed);
        // what's left backs the curve exactly
        assertEq(usdt.balanceOf(address(pool)), pool.quoteReserve());
    }

    // ------------------------------------------------------------- first buy

    function test_FirstBuy_WithErc20IsTaxFree() public {
        usdt.mint(creator, 1_000 ether);
        vm.startPrank(creator);
        usdt.approve(address(factory), 100 ether);
        BondingCurvePool launched = BondingCurvePool(factory.createPool(_params(address(usdt), THRESHOLD), 100 ether));
        vm.stopPrank();

        assertGt(launched.balanceOf(creator), 0);
        assertEq(launched.creatorFees(), 0);
        assertEq(usdt.balanceOf(address(factory)), 0);
        // paid only the curve cost; the rounding dust came back
        assertEq(usdt.balanceOf(creator), 1_000 ether - launched.quoteReserve());
        assertApproxEqAbs(launched.quoteReserve(), 100 ether, 1e6);
        assertEq(usdt.balanceOf(address(launched)), launched.quoteReserve());
    }

    function test_RevertWhen_FirstBuyWithoutApproval() public {
        usdt.mint(creator, 1_000 ether);
        vm.prank(creator);
        vm.expectRevert();
        factory.createPool(_params(address(usdt), THRESHOLD), 100 ether);
    }

    function test_RevertWhen_Erc20FirstBuySendsBnb() public {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(PoolFactory.InvalidMsgValue.selector);
        factory.createPool{value: 1 ether}(_params(address(usdt), THRESHOLD), 1 ether);
    }

    // ------------------------------------------------------------- migration

    function test_Migrate_PairsWithQuoteToken() public {
        _buy(alice, 80_000 ether);
        pool.migrate();

        address pair = pancake.getPair(address(pool), address(usdt));
        assertEq(pair, pool.pair());
        (uint256 tokenReserve, uint256 quoteReserve) = _reserves(pool);
        assertEq(tokenReserve, 20_000 ether);
        assertEq(quoteReserve, THRESHOLD);
        assertEq(ITestPair(pair).balanceOf(pool.DEAD()), ITestPair(pair).totalSupply() - 1000);
        assertEq(usdt.balanceOf(address(pool)), pool.creatorFees());
    }

    function test_Migrate_SurvivesSyncedQuoteDonation() public {
        address attacker = makeAddr("attacker");
        usdt.mint(attacker, 1);
        vm.startPrank(attacker);
        address pair = pancake.createPair(address(pool), address(usdt));
        usdt.transfer(pair, 1);
        ITestPair(pair).sync();
        vm.stopPrank();

        _buy(alice, 80_000 ether);
        pool.migrate();

        (uint256 tokenReserve, uint256 quoteReserve) = _reserves(pool);
        assertEq(tokenReserve, 20_000 ether);
        assertEq(quoteReserve, THRESHOLD + 1);
        assertEq(ITestPair(pair).balanceOf(attacker), 0);
    }

    /// Prices are in the quote's own smallest units, so a 6-decimal token works the same way.
    function test_SixDecimalQuoteToken() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(admin);
        factory.setQuoteToken(address(usdc), 10_000); // 0.01 USDC per coin

        BondingCurvePool p = BondingCurvePool(factory.createPool(_params(address(usdc), 4_200e6), 0));
        assertEq(p.endPrice(), 95_000); // 0.095 USDC

        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(p), type(uint256).max);
        p.buy(80_000 ether, type(uint256).max);
        vm.stopPrank();

        assertTrue(p.graduated());
        assertEq(p.quoteReserve(), 4_200e6);
        p.migrate();
        (uint256 tokenReserve, uint256 quoteReserve) = _reserves(p);
        assertEq(tokenReserve, 20_000 ether);
        assertEq(quoteReserve, 4_200e6);
    }

    // ------------------------------------------------------------ invariants

    function testFuzz_Erc20PoolStaysSolvent(uint256 a, uint256 b, uint256 s) public {
        a = bound(a, 1, 40_000 ether);
        b = bound(b, 1, 39_999 ether);
        _buy(alice, a);
        _buy(bob, b);

        s = bound(s, 1, a);
        vm.prank(alice);
        pool.sell(s, 0);

        uint256 circulating = pool.curveSupply() - pool.curveTokensLeft();
        (uint256 refundAll,) = pool.getSellQuote(circulating);
        assertGe(pool.quoteReserve(), refundAll);
        assertEq(usdt.balanceOf(address(pool)), pool.quoteReserve() + pool.creatorFees());
    }
}
