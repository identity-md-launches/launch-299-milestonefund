// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MilestoneFund} from "../src/MilestoneFund.sol";
import {CallbackToken} from "./mocks/CallbackToken.sol";
import {ReentrantBacker, ReentrantCreator} from "./mocks/Reentrant.sol";

contract MilestoneFundTest is Test {
    LaunchToken internal token;
    MilestoneFund internal fund;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal anyone = makeAddr("anyone");

    uint64 internal constant DURATION = 7 days;
    uint64 internal constant GRACE = 3 days;
    uint256 internal constant START = 1_700_000_000;

    event Opened(
        uint256 indexed raiseId, address indexed creator, uint16 bps1, uint16 bps2, uint16 bps3, uint64 deadline
    );
    event Deposited(uint256 indexed raiseId, address indexed backer, uint256 amount);
    event TrancheApproved(uint256 indexed raiseId, address indexed backer, uint8 tranche, uint256 weight);
    event Released(uint256 indexed raiseId, uint8 tranche, uint256 amount, uint64 nextVoteOpenedAt);
    event RageQuit(uint256 indexed raiseId, address indexed backer, uint256 shares, uint256 payout);
    event Withdrawn(address indexed creator, uint256 amount);

    function setUp() public {
        vm.warp(START);
        token = new LaunchToken();
        fund = new MilestoneFund(address(token));
        _fund(alice, 1_000_000e18);
        _fund(bob, 1_000_000e18);
        _fund(carol, 1_000_000e18);
        _fund(creator, 1_000_000e18);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _fund(address who, uint256 amount) internal {
        token.transfer(who, amount);
        vm.prank(who);
        token.approve(address(fund), type(uint256).max);
    }

    function _open(uint16 a, uint16 b, uint16 c) internal returns (uint256 id) {
        vm.prank(creator);
        id = fund.open(a, b, c, DURATION);
    }

    function _openDefault() internal returns (uint256 id) {
        return _open(2000, 3000, 5000);
    }

    function _deposit(address who, uint256 id, uint256 amount) internal {
        vm.prank(who);
        fund.deposit(id, amount);
    }

    function _approve(address who, uint256 id) internal {
        vm.prank(who);
        fund.approveTranche(id);
    }

    function _quit(address who, uint256 id) internal {
        vm.prank(who);
        fund.rageQuit(id);
    }

    function _deadline(uint256 id) internal view returns (uint256) {
        return fund.raise(id).deadline;
    }

    function _assertConserved() internal view {
        uint256 owed;
        for (uint256 i; i < fund.raiseCount(); ++i) {
            owed += fund.unreleased(i);
        }
        owed += fund.creatorBalance(creator) + fund.creatorBalance(alice) + fund.creatorBalance(bob)
        + fund.creatorBalance(carol);
        assertEq(token.balanceOf(address(fund)), owed, "TRNC balance != unreleased + creator balances");
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    function test_constructorStoresToken() public view {
        assertEq(address(fund.token()), address(token));
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.raiseCount(), 0);
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(MilestoneFund.ZeroToken.selector);
        new MilestoneFund(address(0));
    }

    function test_noEthAccepted() public {
        vm.deal(anyone, 1 ether);
        vm.prank(anyone);
        (bool ok,) = address(fund).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(anyone);
        (ok,) = address(fund).call{value: 1 ether}(abi.encodeWithSignature("withdraw()"));
        assertFalse(ok);
        assertEq(address(fund).balance, 0);
    }

    // ------------------------------------------------------------------
    // open
    // ------------------------------------------------------------------

    function test_openStoresRaise() public {
        vm.expectEmit(true, true, false, true);
        emit Opened(0, creator, 2000, 3000, 5000, uint64(START + DURATION));
        uint256 id = _openDefault();
        assertEq(id, 0);
        assertEq(fund.raiseCount(), 1);
        MilestoneFund.Raise memory r = fund.raise(id);
        assertEq(r.creator, creator);
        assertEq(r.deadline, START + DURATION);
        assertEq(r.voteOpenedAt, START + DURATION);
        assertEq(r.released, 0);
        assertEq(r.bps1, 2000);
        assertEq(r.bps2, 3000);
        assertEq(r.bps3, 5000);
        assertEq(r.totalShares, 0);
        assertEq(r.unreleased, 0);
        assertEq(r.approvalWeight, 0);

        uint256 second = _open(1, 1, 9998);
        assertEq(second, 1);
        assertEq(fund.raiseCount(), 2);
    }

    function test_openRejectsZeroBps() public {
        vm.startPrank(creator);
        vm.expectRevert(MilestoneFund.InvalidBps.selector);
        fund.open(0, 5000, 5000, DURATION);
        vm.expectRevert(MilestoneFund.InvalidBps.selector);
        fund.open(5000, 0, 5000, DURATION);
        vm.expectRevert(MilestoneFund.InvalidBps.selector);
        fund.open(5000, 5000, 0, DURATION);
        vm.stopPrank();
    }

    function test_openRejectsBpsNotSummingTo10000() public {
        vm.startPrank(creator);
        vm.expectRevert(MilestoneFund.InvalidBps.selector);
        fund.open(3333, 3333, 3333, DURATION);
        vm.expectRevert(MilestoneFund.InvalidBps.selector);
        fund.open(5000, 5000, 1, DURATION);
        vm.expectRevert(MilestoneFund.InvalidBps.selector);
        fund.open(65535, 65535, 65535, DURATION);
        vm.stopPrank();
    }

    function test_openFundingDurationBounds() public {
        vm.startPrank(creator);
        vm.expectRevert(MilestoneFund.InvalidFundingDuration.selector);
        fund.open(2000, 3000, 5000, 1 days - 1);
        vm.expectRevert(MilestoneFund.InvalidFundingDuration.selector);
        fund.open(2000, 3000, 5000, 90 days + 1);
        vm.expectRevert(MilestoneFund.InvalidFundingDuration.selector);
        fund.open(2000, 3000, 5000, 0);
        uint256 a = fund.open(2000, 3000, 5000, 1 days);
        uint256 b = fund.open(2000, 3000, 5000, 90 days);
        vm.stopPrank();
        assertEq(fund.raise(a).deadline, START + 1 days);
        assertEq(fund.raise(b).deadline, START + 90 days);
    }

    function testFuzz_openAcceptsAnyValidSplit(uint16 a, uint16 b, uint64 duration) public {
        a = uint16(bound(a, 1, 9998));
        b = uint16(bound(b, 1, 9999 - a));
        uint16 c = 10_000 - a - b;
        duration = uint64(bound(duration, 1 days, 90 days));
        vm.prank(creator);
        uint256 id = fund.open(a, b, c, duration);
        MilestoneFund.Raise memory r = fund.raise(id);
        assertEq(uint256(r.bps1) + r.bps2 + r.bps3, 10_000);
        assertEq(r.deadline, START + duration);
    }

    // ------------------------------------------------------------------
    // deposit
    // ------------------------------------------------------------------

    function test_depositCreditsSharesAndPullsTokens() public {
        uint256 id = _openDefault();
        uint256 before = token.balanceOf(alice);
        vm.expectEmit(true, true, false, true);
        emit Deposited(id, alice, 100e18);
        _deposit(alice, id, 100e18);
        _deposit(alice, id, 50e18);
        _deposit(bob, id, 25e18);

        assertEq(fund.sharesOf(id, alice), 150e18);
        assertEq(fund.sharesOf(id, bob), 25e18);
        assertEq(fund.raise(id).totalShares, 175e18);
        assertEq(fund.unreleased(id), 175e18);
        assertEq(token.balanceOf(alice), before - 150e18);
        assertEq(token.balanceOf(address(fund)), 175e18);
        _assertConserved();
    }

    function test_depositRejectsZeroAmount() public {
        uint256 id = _openDefault();
        vm.prank(alice);
        vm.expectRevert(MilestoneFund.ZeroAmount.selector);
        fund.deposit(id, 0);
    }

    function test_depositRejectsUnknownRaise() public {
        vm.prank(alice);
        vm.expectRevert(MilestoneFund.UnknownRaise.selector);
        fund.deposit(0, 1e18);
        _openDefault();
        vm.prank(alice);
        vm.expectRevert(MilestoneFund.UnknownRaise.selector);
        fund.deposit(1, 1e18);
    }

    function test_depositRejectsCreator() public {
        uint256 id = _openDefault();
        vm.prank(creator);
        vm.expectRevert(MilestoneFund.CreatorCannotBack.selector);
        fund.deposit(id, 1e18);
    }

    function test_depositRejectsAtAndAfterDeadline() public {
        uint256 id = _openDefault();
        vm.warp(_deadline(id) - 1);
        _deposit(alice, id, 1e18);
        vm.warp(_deadline(id));
        vm.prank(alice);
        vm.expectRevert(MilestoneFund.FundingClosed.selector);
        fund.deposit(id, 1e18);
        vm.warp(_deadline(id) + 30 days);
        vm.prank(alice);
        vm.expectRevert(MilestoneFund.FundingClosed.selector);
        fund.deposit(id, 1e18);
    }

    function test_depositRequiresAllowanceAndBalance() public {
        uint256 id = _openDefault();
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert();
        fund.deposit(id, 1e18);

        token.transfer(poor, 1e18);
        vm.prank(poor);
        vm.expectRevert(); // no allowance
        fund.deposit(id, 1e18);

        vm.startPrank(poor);
        token.approve(address(fund), 1e18);
        vm.expectRevert(); // allowance ok, balance short
        fund.deposit(id, 2e18);
        fund.deposit(id, 1e18);
        vm.stopPrank();
        assertEq(fund.sharesOf(id, poor), 1e18);
    }

    // ------------------------------------------------------------------
    // approveTranche
    // ------------------------------------------------------------------

    function test_approveTrancheAddsWeightOncePerBacker() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 60e18);
        _deposit(bob, id, 40e18);
        vm.warp(_deadline(id));

        vm.expectEmit(true, true, false, true);
        emit TrancheApproved(id, alice, 1, 60e18);
        _approve(alice, id);
        assertEq(fund.approvalWeight(id), 60e18);
        assertTrue(fund.hasApproved(id, alice));
        assertFalse(fund.hasApproved(id, bob));

        vm.prank(alice);
        vm.expectRevert(MilestoneFund.AlreadyApproved.selector);
        fund.approveTranche(id);

        _approve(bob, id);
        assertEq(fund.approvalWeight(id), 100e18);
    }

    function test_approveTrancheRejectsBeforeDeadline() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 1e18);
        vm.warp(_deadline(id) - 1);
        vm.prank(alice);
        vm.expectRevert(MilestoneFund.FundingOpen.selector);
        fund.approveTranche(id);
    }

    function test_approveTrancheRejectsNonBackers() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 1e18);
        vm.warp(_deadline(id));
        vm.prank(bob);
        vm.expectRevert(MilestoneFund.NoShares.selector);
        fund.approveTranche(id);
        vm.prank(creator);
        vm.expectRevert(MilestoneFund.NoShares.selector);
        fund.approveTranche(id);
    }

    function test_approveTrancheRejectsUnknownRaise() public {
        vm.prank(alice);
        vm.expectRevert(MilestoneFund.UnknownRaise.selector);
        fund.approveTranche(7);
    }

    function test_approvalsDoNotCarryToNextTranche() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 100e18);
        vm.warp(_deadline(id));
        _approve(alice, id);
        vm.warp(_deadline(id) + GRACE);
        fund.release(id);

        assertEq(fund.approvalWeight(id), 0);
        assertFalse(fund.hasApproved(id, alice));
        vm.warp(vm.getBlockTimestamp() + GRACE);
        vm.expectRevert(MilestoneFund.InsufficientApproval.selector);
        fund.release(id);

        _approve(alice, id); // tranche 2 needs a fresh approval
        assertEq(fund.approvalWeight(id), 100e18);
        fund.release(id);
        assertEq(fund.raise(id).released, 2);
    }

    function test_approveTrancheRejectsAfterAllReleased() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 100e18);
        _releaseAll(id, alice);
        vm.prank(alice);
        vm.expectRevert(MilestoneFund.AllReleased.selector);
        fund.approveTranche(id);
    }

    // ------------------------------------------------------------------
    // release
    // ------------------------------------------------------------------

    function test_releaseAmountsFollowBpsAndLastTakesRemainder() public {
        uint256 id = _openDefault(); // 20 / 30 / 50
        _deposit(alice, id, 1000e18);
        vm.warp(_deadline(id));
        _approve(alice, id);
        vm.warp(_deadline(id) + GRACE);

        assertEq(fund.nextTrancheAmount(id), 200e18);
        vm.expectEmit(true, false, false, true);
        emit Released(id, 1, 200e18, uint64(vm.getBlockTimestamp()));
        vm.prank(anyone);
        fund.release(id);
        assertEq(fund.unreleased(id), 800e18);
        assertEq(fund.creatorBalance(creator), 200e18);
        assertEq(fund.raise(id).released, 1);
        assertEq(fund.raise(id).voteOpenedAt, vm.getBlockTimestamp());

        // tranche 2 = 800 * 3000 / 8000 = 300
        _approve(alice, id);
        vm.warp(vm.getBlockTimestamp() + GRACE);
        assertEq(fund.nextTrancheAmount(id), 300e18);
        fund.release(id);
        assertEq(fund.unreleased(id), 500e18);
        assertEq(fund.creatorBalance(creator), 500e18);

        // tranche 3 takes all that is left
        _approve(alice, id);
        vm.warp(vm.getBlockTimestamp() + GRACE);
        assertEq(fund.nextTrancheAmount(id), 500e18);
        fund.release(id);
        assertEq(fund.unreleased(id), 0);
        assertEq(fund.creatorBalance(creator), 1000e18);
        assertEq(fund.raise(id).released, 3);
        assertEq(fund.nextTrancheAmount(id), 0);
        _assertConserved();

        vm.expectRevert(MilestoneFund.AllReleased.selector);
        fund.release(id);
    }

    function test_releaseRoundsDownAndLastTrancheSweepsDust() public {
        uint256 id = _open(1, 1, 9998);
        _deposit(alice, id, 1); // one minor unit
        vm.warp(_deadline(id));
        _approve(alice, id);
        vm.warp(_deadline(id) + GRACE);
        fund.release(id);
        assertEq(fund.creatorBalance(creator), 0); // floor(1 * 1 / 10000)
        assertEq(fund.unreleased(id), 1);
        _approve(alice, id);
        vm.warp(vm.getBlockTimestamp() + GRACE);
        fund.release(id);
        assertEq(fund.creatorBalance(creator), 0); // floor(1 * 1 / 9999)
        _approve(alice, id);
        vm.warp(vm.getBlockTimestamp() + GRACE);
        fund.release(id);
        assertEq(fund.creatorBalance(creator), 1);
        assertEq(fund.unreleased(id), 0);
        _assertConserved();
    }

    function test_releaseRequiresStrictMajority_exactHalfDoesNotRelease() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 100e18);
        _deposit(bob, id, 100e18);
        vm.warp(_deadline(id) + GRACE);
        _approve(alice, id);
        assertEq(fund.approvalWeight(id) * 2, fund.raise(id).totalShares);
        vm.expectRevert(MilestoneFund.InsufficientApproval.selector);
        fund.release(id);

        // once the dissenter leaves, alice's approval is a strict majority of what remains
        _quit(bob, id);
        assertEq(fund.approvalWeight(id), 100e18);
        assertEq(fund.raise(id).totalShares, 100e18);
        fund.release(id);
        assertEq(fund.raise(id).released, 1);
        assertEq(fund.creatorBalance(creator), 20e18);
    }

    function test_releaseWithOneUnitOverHalf() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 100e18 + 1);
        _deposit(bob, id, 100e18);
        vm.warp(_deadline(id) + GRACE);
        _approve(alice, id);
        fund.release(id);
        assertEq(fund.raise(id).released, 1);
    }

    function test_releaseWithOneUnitUnderHalfFails() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 100e18 - 1);
        _deposit(bob, id, 100e18);
        vm.warp(_deadline(id) + GRACE);
        _approve(alice, id);
        vm.expectRevert(MilestoneFund.InsufficientApproval.selector);
        fund.release(id);
    }

    function test_releaseGraceBoundary() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 100e18);
        vm.warp(_deadline(id));
        _approve(alice, id);

        vm.warp(_deadline(id) + GRACE - 1);
        vm.expectRevert(MilestoneFund.GracePeriodActive.selector);
        fund.release(id);

        vm.warp(_deadline(id) + GRACE);
        fund.release(id);
        uint256 opened = vm.getBlockTimestamp();
        _approve(alice, id);

        vm.warp(opened + GRACE - 1);
        vm.expectRevert(MilestoneFund.GracePeriodActive.selector);
        fund.release(id);
        vm.warp(opened + GRACE);
        fund.release(id);
        assertEq(fund.raise(id).released, 2);
    }

    function test_releaseGraceCountsFromPreviousReleaseNotApproval() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 100e18);
        vm.warp(_deadline(id) + 10 days); // approve late; the grace still counts from the deadline
        _approve(alice, id);
        fund.release(id);
        uint256 opened = vm.getBlockTimestamp();
        vm.warp(opened + 1 days);
        _approve(alice, id);
        vm.warp(opened + GRACE - 1);
        vm.expectRevert(MilestoneFund.GracePeriodActive.selector);
        fund.release(id);
        vm.warp(opened + GRACE);
        fund.release(id);
    }

    function test_releaseImpossibleBeforeDeadline() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 100e18);
        vm.expectRevert(MilestoneFund.InsufficientApproval.selector);
        fund.release(id);
    }

    function test_releaseWithNoBackersNeverReleases() public {
        uint256 id = _openDefault();
        vm.warp(_deadline(id) + 365 days);
        vm.expectRevert(MilestoneFund.InsufficientApproval.selector);
        fund.release(id);
        assertEq(fund.unreleased(id), 0);
    }

    function test_releaseAfterEveryoneQuitsNeverReleases() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 100e18);
        vm.warp(_deadline(id));
        _approve(alice, id);
        vm.warp(_deadline(id) + GRACE);
        _quit(alice, id);
        assertEq(fund.unreleased(id), 0);
        assertEq(fund.raise(id).totalShares, 0);
        assertEq(fund.approvalWeight(id), 0);
        vm.expectRevert(MilestoneFund.InsufficientApproval.selector);
        fund.release(id);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function test_releaseRejectsUnknownRaise() public {
        vm.expectRevert(MilestoneFund.UnknownRaise.selector);
        fund.release(3);
    }

    // ------------------------------------------------------------------
    // rageQuit
    // ------------------------------------------------------------------

    function test_rageQuitBeforeDeadlineReturnsFullDeposit() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 100e18);
        _deposit(bob, id, 50e18);
        uint256 before = token.balanceOf(alice);
        vm.expectEmit(true, true, false, true);
        emit RageQuit(id, alice, 100e18, 100e18);
        _quit(alice, id);
        assertEq(token.balanceOf(alice), before + 100e18);
        assertEq(fund.sharesOf(id, alice), 0);
        assertEq(fund.raise(id).totalShares, 50e18);
        assertEq(fund.unreleased(id), 50e18);
        _assertConserved();

        // can re-enter the raise while funding is open
        _deposit(alice, id, 10e18);
        assertEq(fund.sharesOf(id, alice), 10e18);
    }

    function test_rageQuitAfterDeadlineIsProRataOfUnreleased() public {
        uint256 id = _openDefault(); // 20/30/50
        _deposit(alice, id, 600e18);
        _deposit(bob, id, 400e18);
        vm.warp(_deadline(id));
        _approve(alice, id);
        vm.warp(_deadline(id) + GRACE);
        fund.release(id); // 200 released, 800 unreleased

        uint256 before = token.balanceOf(bob);
        _quit(bob, id); // 400 * 800 / 1000 = 320
        assertEq(token.balanceOf(bob), before + 320e18);
        assertEq(fund.unreleased(id), 480e18);
        assertEq(fund.raise(id).totalShares, 600e18);
        _assertConserved();

        // alice is now the last backer and takes the remainder exactly
        before = token.balanceOf(alice);
        _quit(alice, id);
        assertEq(token.balanceOf(alice), before + 480e18);
        assertEq(fund.unreleased(id), 0);
        assertEq(fund.raise(id).totalShares, 0);
        assertEq(token.balanceOf(address(fund)), fund.creatorBalance(creator));
        assertEq(fund.creatorBalance(creator), 200e18);
    }

    function test_rageQuitLastBackerTakesRoundingRemainder() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 3);
        _deposit(bob, id, 3);
        _deposit(carol, id, 4);
        vm.warp(_deadline(id));
        _approve(alice, id);
        _approve(bob, id);
        vm.warp(_deadline(id) + GRACE);
        fund.release(id); // 10 * 2000 / 10000 = 2 -> unreleased 8
        assertEq(fund.unreleased(id), 8);

        _quit(alice, id); // 3 * 8 / 10 = 2 -> unreleased 6, shares 7
        assertEq(fund.unreleased(id), 6);
        _quit(bob, id); // 3 * 6 / 7 = 2 -> unreleased 4, shares 4
        assertEq(fund.unreleased(id), 4);
        uint256 before = token.balanceOf(carol);
        _quit(carol, id); // last out: 4, not floor(4*4/4)=4 anyway; but dust cases are covered by fuzz
        assertEq(token.balanceOf(carol), before + 4);
        assertEq(fund.unreleased(id), 0);
        _assertConserved();
    }

    function test_rageQuitRemovesApprovalWeight() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 60e18);
        _deposit(bob, id, 40e18);
        vm.warp(_deadline(id));
        _approve(alice, id);
        assertEq(fund.approvalWeight(id), 60e18);
        _quit(alice, id);
        assertEq(fund.approvalWeight(id), 0);
        assertEq(fund.raise(id).totalShares, 40e18);
        vm.warp(_deadline(id) + GRACE);
        vm.expectRevert(MilestoneFund.InsufficientApproval.selector);
        fund.release(id);
        // bob alone is a strict majority of what remains
        _approve(bob, id);
        fund.release(id);
    }

    function test_rageQuitDoesNotTouchWeightOfStaleApproval() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 60e18);
        _deposit(bob, id, 40e18);
        vm.warp(_deadline(id));
        _approve(alice, id);
        vm.warp(_deadline(id) + GRACE);
        fund.release(id); // resets approval weight, alice's approval is now stale
        _approve(bob, id);
        assertEq(fund.approvalWeight(id), 40e18);
        _quit(alice, id); // stale approval: weight must not underflow or change
        assertEq(fund.approvalWeight(id), 40e18);
    }

    function test_rageQuitRejectsNonBackerAndDoubleQuit() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 1e18);
        vm.prank(bob);
        vm.expectRevert(MilestoneFund.NoShares.selector);
        fund.rageQuit(id);
        _quit(alice, id);
        vm.prank(alice);
        vm.expectRevert(MilestoneFund.NoShares.selector);
        fund.rageQuit(id);
        vm.prank(alice);
        vm.expectRevert(MilestoneFund.UnknownRaise.selector);
        fund.rageQuit(id + 1);
    }

    function test_rageQuitAfterFullReleasePaysNothing() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 100e18);
        _releaseAll(id, alice);
        uint256 before = token.balanceOf(alice);
        _quit(alice, id);
        assertEq(token.balanceOf(alice), before);
        assertEq(fund.sharesOf(id, alice), 0);
        assertEq(fund.raise(id).totalShares, 0);
        _assertConserved();
    }

    function test_rageQuitFromDifferentRaisesIsIndependent() public {
        uint256 a = _openDefault();
        uint256 b = _open(5000, 2500, 2500);
        _deposit(alice, a, 100e18);
        _deposit(alice, b, 30e18);
        _quit(alice, a);
        assertEq(fund.sharesOf(a, alice), 0);
        assertEq(fund.sharesOf(b, alice), 30e18);
        assertEq(fund.unreleased(b), 30e18);
        _assertConserved();
    }

    // ------------------------------------------------------------------
    // withdraw
    // ------------------------------------------------------------------

    function test_withdrawIsPullAndAccumulatesAcrossRaises() public {
        uint256 a = _openDefault();
        uint256 b = _openDefault();
        _deposit(alice, a, 100e18);
        _deposit(bob, b, 50e18);
        vm.warp(_deadline(a) + GRACE);
        _approve(alice, a);
        _approve(bob, b);
        fund.release(a);
        fund.release(b);
        assertEq(fund.creatorBalance(creator), 30e18);

        uint256 before = token.balanceOf(creator);
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(creator, 30e18);
        vm.prank(creator);
        fund.withdraw();
        assertEq(token.balanceOf(creator), before + 30e18);
        assertEq(fund.creatorBalance(creator), 0);
        _assertConserved();

        vm.prank(creator);
        vm.expectRevert(MilestoneFund.NothingToWithdraw.selector);
        fund.withdraw();
    }

    function test_withdrawRejectsAddressesWithNoBalance() public {
        vm.prank(anyone);
        vm.expectRevert(MilestoneFund.NothingToWithdraw.selector);
        fund.withdraw();
    }

    function test_creatorCannotTakeMoreThanReleased() public {
        uint256 id = _openDefault();
        _deposit(alice, id, 100e18);
        vm.warp(_deadline(id) + GRACE);
        _approve(alice, id);
        fund.release(id);
        vm.prank(creator);
        fund.withdraw();
        assertEq(token.balanceOf(address(fund)), 80e18);
        vm.prank(creator);
        vm.expectRevert(MilestoneFund.NothingToWithdraw.selector);
        fund.withdraw();
    }

    // ------------------------------------------------------------------
    // Sybil / self-dealing (documented limit)
    // ------------------------------------------------------------------

    function test_sybilMajorityReleasesAtMostOneTranchePerGracePeriod() public {
        uint256 id = _openDefault();
        address sybil = makeAddr("creator-sybil");
        _fund(sybil, 1_000e18);
        _deposit(sybil, id, 51e18);
        _deposit(alice, id, 49e18);

        vm.warp(_deadline(id));
        _approve(sybil, id);
        vm.warp(_deadline(id) + GRACE - 1);
        vm.expectRevert(MilestoneFund.GracePeriodActive.selector);
        fund.release(id);

        // alice sees the approval during the grace period and leaves with her full pro-rata share
        uint256 before = token.balanceOf(alice);
        _quit(alice, id);
        assertEq(token.balanceOf(alice), before + 49e18);

        vm.warp(_deadline(id) + GRACE);
        fund.release(id); // 51 * 20% = 10.2
        assertEq(fund.creatorBalance(creator), 10.2e18);
        _approve(sybil, id);
        vm.expectRevert(MilestoneFund.GracePeriodActive.selector);
        fund.release(id); // cannot chain releases in the same block
        vm.warp(vm.getBlockTimestamp() + GRACE);
        fund.release(id);
        assertEq(fund.raise(id).released, 2);
        _assertConserved();
    }

    // ------------------------------------------------------------------
    // Reentrancy
    // ------------------------------------------------------------------

    function test_rageQuitReentrancyIsBlocked() public {
        CallbackToken cb = new CallbackToken();
        MilestoneFund cbFund = new MilestoneFund(address(cb));
        vm.prank(creator);
        uint256 id = cbFund.open(2000, 3000, 5000, DURATION);
        ReentrantBacker attacker = new ReentrantBacker(cbFund);
        cb.transfer(address(attacker), 100e18);
        cb.transfer(alice, 100e18);
        vm.startPrank(alice);
        cb.approve(address(cbFund), 100e18);
        cbFund.deposit(id, 100e18);
        vm.stopPrank();
        attacker.join(id, 100e18);

        attacker.quit();
        assertEq(attacker.attempts(), 1);
        assertFalse(attacker.reenterSucceeded());
        assertEq(cb.balanceOf(address(attacker)), 100e18);
        assertEq(cb.balanceOf(address(cbFund)), 100e18);
        assertEq(cbFund.unreleased(id), 100e18);
    }

    function test_withdrawReentrancyIsBlocked() public {
        CallbackToken cb = new CallbackToken();
        MilestoneFund cbFund = new MilestoneFund(address(cb));
        ReentrantCreator rc = new ReentrantCreator(cbFund);
        uint256 id = rc.open(2000, 3000, 5000, DURATION);
        cb.transfer(alice, 100e18);
        vm.startPrank(alice);
        cb.approve(address(cbFund), 100e18);
        cbFund.deposit(id, 100e18);
        vm.warp(cbFund.raise(id).deadline);
        cbFund.approveTranche(id);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + GRACE);
        cbFund.release(id);

        rc.withdraw();
        assertEq(rc.attempts(), 1);
        assertFalse(rc.reenterSucceeded());
        assertEq(cb.balanceOf(address(rc)), 20e18);
        assertEq(cbFund.creatorBalance(address(rc)), 0);
        assertEq(cb.balanceOf(address(cbFund)), 80e18);
    }

    // ------------------------------------------------------------------
    // Fuzz: conservation over bps splits, deposit sizes and quit order
    // ------------------------------------------------------------------

    function testFuzz_fullReleaseConservesAndLeavesNoDust(uint16 a, uint16 b, uint96 d1, uint96 d2, uint96 d3) public {
        a = uint16(bound(a, 1, 9998));
        b = uint16(bound(b, 1, 9999 - a));
        uint16 c = 10_000 - a - b;
        d1 = uint96(bound(d1, 1, 1_000_000e18));
        d2 = uint96(bound(d2, 0, 1_000_000e18));
        d3 = uint96(bound(d3, 0, 1_000_000e18));

        uint256 id = _open(a, b, c);
        _deposit(alice, id, d1);
        if (d2 > 0) _deposit(bob, id, d2);
        if (d3 > 0) _deposit(carol, id, d3);
        uint256 total = uint256(d1) + d2 + d3;
        assertEq(fund.unreleased(id), total);

        vm.warp(_deadline(id));
        uint256 credited;
        for (uint8 t = 1; t <= 3; ++t) {
            _approve(alice, id);
            if (d2 > 0) _approve(bob, id);
            if (d3 > 0) _approve(carol, id);
            vm.warp(vm.getBlockTimestamp() + GRACE);
            uint256 expected = fund.nextTrancheAmount(id);
            uint256 pool = fund.unreleased(id);
            if (t == 1) assertEq(expected, pool * a / 10_000);
            if (t == 2) assertEq(expected, pool * b / (uint256(b) + c));
            if (t == 3) assertEq(expected, pool);
            fund.release(id);
            credited += expected;
            assertEq(fund.creatorBalance(creator), credited);
            _assertConserved();
        }
        assertEq(fund.unreleased(id), 0);
        assertEq(fund.creatorBalance(creator), total);
        assertLe(fund.creatorBalance(creator), total);
    }

    function testFuzz_quitOrderConservesAndDrainsRaise(
        uint16 a,
        uint16 b,
        uint96 d1,
        uint96 d2,
        uint96 d3,
        uint8 releases,
        uint8 order
    ) public {
        a = uint16(bound(a, 1, 9998));
        b = uint16(bound(b, 1, 9999 - a));
        uint16 c = 10_000 - a - b;
        d1 = uint96(bound(d1, 1, 1_000_000e18));
        d2 = uint96(bound(d2, 1, 1_000_000e18));
        d3 = uint96(bound(d3, 1, 1_000_000e18));
        releases = uint8(bound(releases, 0, 2));

        uint256 id = _open(a, b, c);
        _deposit(alice, id, d1);
        _deposit(bob, id, d2);
        _deposit(carol, id, d3);
        uint256 total = uint256(d1) + d2 + d3;

        vm.warp(_deadline(id));
        for (uint8 t; t < releases; ++t) {
            _approve(alice, id);
            _approve(bob, id);
            _approve(carol, id);
            vm.warp(vm.getBlockTimestamp() + GRACE);
            fund.release(id);
        }
        uint256 released = fund.creatorBalance(creator);
        assertEq(fund.unreleased(id), total - released);

        // pending approval on the current tranche by one backer, to exercise weight removal on quit
        _approve(alice, id);

        address[3] memory who = _permutation(order);
        uint256 paid;
        uint256 startBalances = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol);
        for (uint256 i; i < 3; ++i) {
            uint256 shares = fund.sharesOf(id, who[i]);
            uint256 pool = fund.unreleased(id);
            uint256 totalShares = fund.raise(id).totalShares;
            uint256 expected = shares == totalShares ? pool : shares * pool / totalShares;
            uint256 before = token.balanceOf(who[i]);
            _quit(who[i], id);
            assertEq(token.balanceOf(who[i]) - before, expected);
            paid += expected;
            _assertConserved();
        }
        assertEq(fund.unreleased(id), 0);
        assertEq(fund.raise(id).totalShares, 0);
        assertEq(fund.approvalWeight(id), 0);
        assertLe(paid + released, total);
        assertEq(paid + released, total); // nothing stranded: the last quitter took the remainder
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol), startBalances + paid);
        assertEq(token.balanceOf(address(fund)), released);
    }

    function testFuzz_partialQuitThenReleaseNeverOverpays(uint96 d1, uint96 d2, uint96 d3, uint8 order) public {
        d1 = uint96(bound(d1, 1, 1_000_000e18));
        d2 = uint96(bound(d2, 1, 1_000_000e18));
        d3 = uint96(bound(d3, 1, 1_000_000e18));
        uint256 id = _open(1234, 4321, 4445);
        _deposit(alice, id, d1);
        _deposit(bob, id, d2);
        _deposit(carol, id, d3);
        uint256 total = uint256(d1) + d2 + d3;

        address[3] memory who = _permutation(order);
        vm.warp(_deadline(id));
        _approve(who[0], id);
        _approve(who[1], id);
        uint256 paid;
        uint256 before = token.balanceOf(who[2]);
        _quit(who[2], id); // dissenter leaves during the grace period
        paid += token.balanceOf(who[2]) - before;
        vm.warp(vm.getBlockTimestamp() + GRACE);
        fund.release(id);
        _assertConserved();

        before = token.balanceOf(who[0]);
        _quit(who[0], id);
        paid += token.balanceOf(who[0]) - before;
        before = token.balanceOf(who[1]);
        _quit(who[1], id);
        paid += token.balanceOf(who[1]) - before;
        _assertConserved();
        assertEq(fund.unreleased(id), 0);
        assertEq(paid + fund.creatorBalance(creator), total);
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    function _releaseAll(uint256 id, address soleBacker) internal {
        vm.warp(_deadline(id));
        for (uint8 t; t < 3; ++t) {
            _approve(soleBacker, id);
            vm.warp(vm.getBlockTimestamp() + GRACE);
            fund.release(id);
        }
    }

    function _permutation(uint8 order) internal view returns (address[3] memory who) {
        address[3] memory base = [alice, bob, carol];
        uint8 first = order % 3;
        uint8 second = (order / 3) % 2;
        who[0] = base[first];
        address[2] memory rest;
        uint8 k;
        for (uint8 i; i < 3; ++i) {
            if (i != first) rest[k++] = base[i];
        }
        who[1] = rest[second];
        who[2] = rest[1 - second];
    }
}
