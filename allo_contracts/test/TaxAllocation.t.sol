// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {BondingCurvePool, PoolParams, TaxAllocation} from "../src/Pool.sol";
import {IPancakeFactory} from "../src/interfaces/IPancake.sol";
import {MockWBNB} from "./mocks/MockWBNB.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ITestPair} from "./BondingCurvePool.t.sol";

/// Tax allocation (creator / burn / buyback / holder rewards) and the launch fee.
contract TaxAllocationTest is Test {
    address constant DEAD_ADDR = 0x000000000000000000000000000000000000dEaD;
    uint256 constant SUPPLY = 100_000 ether;
    uint256 constant START_PRICE = 0.00001 ether;
    uint256 constant THRESHOLD = 4.2 ether;

    PoolFactory factory;
    IPancakeFactory pancake;
    MockWBNB wbnb;
    BondingCurvePool pool;

    address admin = makeAddr("admin");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        pancake = IPancakeFactory(deployCode("PancakeFactory.sol:PancakeFactory", abi.encode(admin)));
        wbnb = new MockWBNB();
        factory = new PoolFactory(admin, address(pancake), address(wbnb), START_PRICE, 0);

        // the screenshot's settings: 2% buy / 1% sell tax, split 20% creator, 30% burn, 40% buyback, 10% holders
        vm.prank(creator);
        pool = BondingCurvePool(factory.createPool(_params(_alloc(2_000, 3_000, 4_000, 1_000)), 0));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function _alloc(uint256 creatorBps, uint256 burnBps, uint256 buybackBps, uint256 holdersBps)
        internal
        pure
        returns (TaxAllocation memory)
    {
        return TaxAllocation(creatorBps, burnBps, buybackBps, holdersBps);
    }

    function _params(TaxAllocation memory a) internal pure returns (PoolParams memory) {
        return PoolParams({
            name: "Allo Coin",
            symbol: "ALLO",
            imageUrl: "",
            website: "",
            twitter: "",
            quoteToken: address(0),
            buyFeeBps: 200,
            sellFeeBps: 100,
            taxAllocation: a,
            totalSupply: SUPPLY,
            graduationThreshold: THRESHOLD
        });
    }

    function _buy(BondingCurvePool p, address who, uint256 amount) internal {
        (, uint256 cost, uint256 fee) = p.getBuyQuote(amount);
        vm.prank(who);
        p.buy{value: cost + fee}(amount, cost + fee);
    }

    /// Every wei the pool holds is accounted for by exactly one bucket.
    function _assertBooksBalance(BondingCurvePool p) internal view {
        assertEq(
            address(p).balance,
            p.quoteReserve() + p.creatorFees() + p.burnBucket() + p.buybackBucket() + p.rewardsUnclaimed()
                + p.rewardsPending()
        );
    }

    // ------------------------------------------------------------- the split

    function test_TaxSplit_PlatformThenAllocation() public {
        (, uint256 cost, uint256 fee) = pool.getBuyQuote(10_000 ether);
        assertEq(cost, 0.153125 ether);
        assertEq(fee, 0.0030625 ether); // 2%

        _buy(pool, alice, 10_000 ether);

        // platform 20% = 0.0006125; the other 0.00245 is split 20/30/40/10
        assertEq(address(factory).balance, 0.0006125 ether);
        assertEq(pool.creatorFees(), 0.00049 ether);
        // nobody held the coin before alice, so the holder share waits for the next payout
        assertEq(pool.rewardsPending(), 0.000245 ether);
        // burn (0.000735) and buyback (0.00098) were spent on the curve straight away, down to dust
        assertLt(pool.burnBucket(), 1e9);
        assertLt(pool.buybackBucket(), 1e9);
        _assertBooksBalance(pool);
    }

    function test_Burn_BuysOnCurveAndDestroysCoins() public {
        _buy(pool, alice, 10_000 ether);

        uint256 burned = SUPPLY - pool.totalSupply();
        assertGt(burned, 0);
        // burned coins came off the curve and their cost went into the reserve
        uint256 sold = pool.curveSupply() - pool.curveTokensLeft();
        assertEq(sold, 10_000 ether + burned + pool.buybackHeld());
        assertEq(
            pool.quoteReserve(),
            0.153125 ether + (0.000735 ether - pool.burnBucket()) + (0.00098 ether - pool.buybackBucket())
        );
    }

    function test_Buyback_KeepsCoinsInsideThePool() public {
        _buy(pool, alice, 10_000 ether);

        assertGt(pool.buybackHeld(), 0);
        assertEq(pool.balanceOf(creator), 0);
        // the pool holds exactly: unsold curve coins + the DEX allocation + bought-back coins
        assertEq(pool.balanceOf(address(pool)), pool.curveTokensLeft() + pool.dexSupply() + pool.buybackHeld());
        // and they're out of circulation: selling everything else can't touch them
        uint256 all = pool.balanceOf(alice);
        vm.prank(alice);
        pool.sell(all, 0);
        assertGt(pool.buybackHeld(), 0);
    }

    function test_RevertWhen_AllocationNotHundredPercent() public {
        vm.expectRevert(BondingCurvePool.InvalidTaxAllocation.selector);
        factory.createPool(_params(_alloc(2_000, 3_000, 4_000, 999)), 0);

        vm.expectRevert(BondingCurvePool.InvalidTaxAllocation.selector);
        factory.createPool(_params(_alloc(5_000, 5_000, 1, 0)), 0);
    }

    // -------------------------------------------------------- holder rewards

    function test_Rewards_SharedProRataAmongHolders() public {
        _buy(pool, alice, 10_000 ether); // holder share pending: nobody held yet
        _buy(pool, carol, 20_000 ether); // pays out to alice, the only holder
        uint256 aliceBefore = pool.pendingRewards(alice);
        assertEq(pool.pendingRewards(carol), 0); // a buyer doesn't earn from their own tax

        _buy(pool, bob, 30_000 ether); // shared by alice (10k) and carol (20k)
        uint256 aliceGot = pool.pendingRewards(alice) - aliceBefore;
        uint256 carolGot = pool.pendingRewards(carol);
        assertGt(aliceGot, 0);
        assertApproxEqRel(carolGot, 2 * aliceGot, 1e12);
        assertEq(pool.pendingRewards(bob), 0);
        // bought-back coins sit in the pool, which doesn't earn rewards
        assertEq(pool.pendingRewards(address(pool)), 0);
        assertApproxEqAbs(pool.pendingRewards(alice) + carolGot, pool.rewardsUnclaimed(), 2);
    }

    function test_Rewards_ClaimPaysQuoteOnce() public {
        _buy(pool, alice, 10_000 ether);
        _buy(pool, bob, 10_000 ether);

        uint256 owed = pool.pendingRewards(alice);
        uint256 before = alice.balance;
        vm.prank(alice);
        assertEq(pool.claimRewards(), owed);
        assertEq(alice.balance, before + owed);

        vm.prank(alice);
        assertEq(pool.claimRewards(), 0);
        _assertBooksBalance(pool);
    }

    function test_Rewards_SellerKeepsEarnedButStopsEarning() public {
        _buy(pool, alice, 10_000 ether);
        _buy(pool, bob, 10_000 ether);
        uint256 earned = pool.pendingRewards(alice);

        uint256 all = pool.balanceOf(alice);
        vm.prank(alice);
        pool.sell(all, 0);
        assertEq(pool.pendingRewards(alice), earned); // her own sell tax goes to the others

        _buy(pool, carol, 10_000 ether);
        assertEq(pool.pendingRewards(alice), earned); // holds nothing, earns nothing more
    }

    function test_Rewards_TransferMovesFutureEarningsOnly() public {
        address dave = makeAddr("dave");
        _buy(pool, alice, 10_000 ether);
        _buy(pool, bob, 10_000 ether);
        uint256 earned = pool.pendingRewards(alice);

        vm.prank(alice);
        pool.transfer(dave, 10_000 ether);
        assertEq(pool.pendingRewards(alice), earned);
        assertEq(pool.pendingRewards(dave), 0);

        _buy(pool, carol, 10_000 ether);
        assertEq(pool.pendingRewards(alice), earned);
        assertGt(pool.pendingRewards(dave), 0);
    }

    function test_Rewards_ClaimableAfterMigration() public {
        _buy(pool, alice, 10_000 ether);
        _buy(pool, bob, 30_000 ether);
        // buy out the rest of the curve
        vm.prank(carol);
        pool.buyExactIn{value: 50 ether}(50 ether, 0);
        assertTrue(pool.graduated());

        uint256 aliceOwed = pool.pendingRewards(alice);
        pool.migrate();

        // unclaimed creator fees and rewards stay behind; everything else went to the DEX
        assertEq(address(pool).balance, pool.creatorFees() + pool.rewardsUnclaimed() + pool.rewardsPending());
        vm.prank(alice);
        assertEq(pool.claimRewards(), aliceOwed);
    }

    function test_Migration_SpendsLeftoverBurnAndBuybackOnPancake() public {
        _buy(pool, alice, 10_000 ether);
        // the graduating trade's burn/buyback can't buy from an empty curve, so it waits for migration
        vm.prank(bob);
        pool.buyExactIn{value: 50 ether}(50 ether, 0);
        assertTrue(pool.graduated());
        uint256 leftover = pool.burnBucket() + pool.buybackBucket();
        assertGt(leftover, 0);
        uint256 reserve = pool.quoteReserve();
        uint256 supplyBefore = pool.totalSupply();
        uint256 heldBefore = pool.buybackHeld();

        pool.migrate();

        // liquidity went in first, then the leftover was swapped for coins on the pair
        ITestPair p = ITestPair(pool.pair());
        (uint112 r0, uint112 r1,) = p.getReserves();
        (uint256 coinReserve, uint256 wbnbReserve) = p.token0() == address(pool) ? (r0, r1) : (r1, r0);
        assertEq(wbnbReserve, reserve + leftover);
        uint256 burned = supplyBefore - pool.totalSupply();
        uint256 kept = pool.buybackHeld() - heldBefore;
        assertGt(burned, 0);
        assertGt(kept, 0);
        assertEq(coinReserve, 20_000 ether - burned - kept);
        // split 30:40 like the allocation
        assertApproxEqRel(burned * 4, kept * 3, 1e12);

        assertEq(pool.burnBucket() + pool.buybackBucket(), 0);
        assertEq(pool.balanceOf(address(pool)), pool.buybackHeld()); // curve empty, DEX share sent
        assertEq(pool.balanceOf(address(factory)), 0); // swap output only passed through
        assertEq(pool.balanceOf(DEAD_ADDR), 0); // burned for real, not parked at the dead address
    }

    function test_Migration_SpendsLeftoverOnPancakeWithErc20Quote() public {
        MockERC20 usdt = new MockERC20("Tether USD", "USDT", 18);
        vm.prank(admin);
        factory.setQuoteToken(address(usdt), 0.01 ether);
        PoolParams memory params = _params(_alloc(2_000, 3_000, 4_000, 1_000));
        params.quoteToken = address(usdt);
        params.graduationThreshold = 4_200 ether;
        BondingCurvePool p = BondingCurvePool(factory.createPool(params, 0));

        usdt.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        usdt.approve(address(p), type(uint256).max);
        p.buyExactIn(10_000 ether, 0);
        vm.stopPrank();
        assertTrue(p.graduated());

        uint256 leftover = p.burnBucket() + p.buybackBucket();
        uint256 supplyBefore = p.totalSupply();
        p.migrate();

        assertEq(p.burnBucket() + p.buybackBucket(), 0);
        assertLt(p.totalSupply(), supplyBefore);
        assertGt(p.buybackHeld(), 0);
        assertGt(leftover, 0);
        assertEq(usdt.balanceOf(address(p)), p.creatorFees() + p.rewardsUnclaimed() + p.rewardsPending());
    }

    function test_AllToHolders() public {
        BondingCurvePool p = BondingCurvePool(factory.createPool(_params(_alloc(0, 0, 0, 10_000)), 0));
        _buy(p, alice, 10_000 ether);
        _buy(p, bob, 10_000 ether);

        assertEq(p.creatorFees(), 0);
        assertEq(p.balanceOf(creator), 0);
        assertEq(p.totalSupply(), SUPPLY); // nothing burned
        // alice was the only holder for both payouts: alice's own (pending) + bob's
        assertApproxEqAbs(p.pendingRewards(alice), p.rewardsUnclaimed(), 1);
    }

    // ------------------------------------------------------------ launch fee

    function test_LaunchFee_CollectedOnCreate() public {
        vm.prank(admin);
        factory.setLaunchFee(0.002 ether);

        vm.expectRevert(PoolFactory.InvalidMsgValue.selector);
        factory.createPool(_params(_alloc(10_000, 0, 0, 0)), 0);

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        factory.createPool{value: 0.002 ether}(_params(_alloc(10_000, 0, 0, 0)), 0);
        assertEq(address(factory).balance, 0.002 ether);

        // with a native first buy: launch fee + first buy in one msg.value, and the first buy stays tax-free
        vm.prank(creator);
        BondingCurvePool p =
            BondingCurvePool(factory.createPool{value: 0.502 ether}(_params(_alloc(10_000, 0, 0, 0)), 0.5 ether));
        assertEq(address(factory).balance, 0.004 ether);
        assertApproxEqAbs(p.quoteReserve(), 0.5 ether, 1e6);
        assertGt(p.balanceOf(creator), 0);

        vm.prank(admin);
        factory.withdrawFees(address(0), admin);
        assertEq(admin.balance, 0.004 ether);
    }

    function test_LaunchFee_InBnbForErc20Pools() public {
        MockERC20 usdt = new MockERC20("Tether USD", "USDT", 18);
        vm.startPrank(admin);
        factory.setQuoteToken(address(usdt), 0.01 ether);
        factory.setLaunchFee(0.002 ether);
        vm.stopPrank();

        PoolParams memory params = _params(_alloc(10_000, 0, 0, 0));
        params.quoteToken = address(usdt);
        params.graduationThreshold = 4_200 ether;

        usdt.mint(creator, 100 ether);
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        usdt.approve(address(factory), 100 ether);
        factory.createPool{value: 0.002 ether}(params, 100 ether);
        vm.stopPrank();

        assertEq(address(factory).balance, 0.002 ether);
    }

    function test_OnlyAdminSetsLaunchFee() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setLaunchFee(1 ether);
    }

    // ------------------------------------------------------------ invariants

    function testFuzz_BooksBalanceAndPoolStaysSolvent(uint256 a, uint256 b, uint256 s) public {
        a = bound(a, 1 ether, 30_000 ether);
        b = bound(b, 1 ether, 30_000 ether);
        _buy(pool, alice, a);
        _buy(pool, bob, b);

        s = bound(s, 1, pool.balanceOf(alice));
        vm.prank(alice);
        pool.sell(s, 0);

        _assertBooksBalance(pool);
        // the reserve covers buying back every coin still in circulation
        uint256 circulating = pool.totalSupply() - pool.balanceOf(address(pool));
        (uint256 refundAll,) = pool.getSellQuote(circulating);
        assertGe(pool.quoteReserve(), refundAll);
        // holders can never claim more than was handed out
        uint256 owed = pool.pendingRewards(alice) + pool.pendingRewards(bob) + pool.pendingRewards(creator);
        assertLe(owed, pool.rewardsUnclaimed());
    }
}
