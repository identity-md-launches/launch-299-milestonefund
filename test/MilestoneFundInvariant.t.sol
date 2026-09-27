// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MilestoneFund} from "../src/MilestoneFund.sol";

/// @dev Random sequences of open / deposit / approve / release / rageQuit / withdraw / time travel across
///      several raises, creators and backers. Ghost counters track every TRNC that entered and left.
contract MilestoneFundHandler is Test {
    LaunchToken public token;
    MilestoneFund public fund;

    address[] public creators;
    address[] public backers;

    uint256 public ghostDeposited;
    uint256 public ghostQuitPaid;
    uint256 public ghostReleased;
    uint256 public ghostWithdrawn;

    constructor(LaunchToken token_, MilestoneFund fund_) {
        token = token_;
        fund = fund_;
        for (uint256 i; i < 3; ++i) {
            creators.push(makeAddr(string.concat("creator", vm.toString(i))));
        }
        for (uint256 i; i < 5; ++i) {
            address b = makeAddr(string.concat("backer", vm.toString(i)));
            backers.push(b);
            vm.prank(b);
            token.approve(address(fund), type(uint256).max);
        }
    }

    function creatorCount() external view returns (uint256) {
        return creators.length;
    }

    function backerCount() external view returns (uint256) {
        return backers.length;
    }

    function open(uint256 who, uint16 a, uint16 b, uint64 duration) external {
        a = uint16(bound(a, 1, 9998));
        b = uint16(bound(b, 1, 9999 - a));
        uint16 c = 10_000 - a - b;
        duration = uint64(bound(duration, 1 days, 90 days));
        vm.prank(creators[who % creators.length]);
        fund.open(a, b, c, duration);
    }

    function deposit(uint256 who, uint256 raiseId, uint96 amount) external {
        if (fund.raiseCount() == 0) return;
        raiseId = raiseId % fund.raiseCount();
        address backer = backers[who % backers.length];
        amount = uint96(bound(amount, 1, 100_000e18));
        if (token.balanceOf(backer) < amount) return;
        if (vm.getBlockTimestamp() >= fund.raise(raiseId).deadline) return;
        vm.prank(backer);
        fund.deposit(raiseId, amount);
        ghostDeposited += amount;
    }

    function approve(uint256 who, uint256 raiseId) external {
        if (fund.raiseCount() == 0) return;
        raiseId = raiseId % fund.raiseCount();
        address backer = backers[who % backers.length];
        MilestoneFund.Raise memory r = fund.raise(raiseId);
        if (vm.getBlockTimestamp() < r.deadline || r.released >= 3) return;
        if (fund.sharesOf(raiseId, backer) == 0 || fund.hasApproved(raiseId, backer)) return;
        vm.prank(backer);
        fund.approveTranche(raiseId);
    }

    function release(uint256 raiseId) external {
        if (fund.raiseCount() == 0) return;
        raiseId = raiseId % fund.raiseCount();
        MilestoneFund.Raise memory r = fund.raise(raiseId);
        if (r.released >= 3 || r.approvalWeight * 2 <= r.totalShares) return;
        if (vm.getBlockTimestamp() < uint256(r.voteOpenedAt) + 3 days) return;
        uint256 expected = fund.nextTrancheAmount(raiseId);
        fund.release(raiseId);
        ghostReleased += expected;
    }

    function rageQuit(uint256 who, uint256 raiseId) external {
        if (fund.raiseCount() == 0) return;
        raiseId = raiseId % fund.raiseCount();
        address backer = backers[who % backers.length];
        if (fund.sharesOf(raiseId, backer) == 0) return;
        uint256 before = token.balanceOf(backer);
        vm.prank(backer);
        fund.rageQuit(raiseId);
        ghostQuitPaid += token.balanceOf(backer) - before;
    }

    function withdraw(uint256 who) external {
        address creator = creators[who % creators.length];
        uint256 amount = fund.creatorBalance(creator);
        if (amount == 0) return;
        vm.prank(creator);
        fund.withdraw();
        ghostWithdrawn += amount;
    }

    function warp(uint32 delta) external {
        delta = uint32(bound(delta, 1, 4 days));
        vm.warp(vm.getBlockTimestamp() + delta);
    }
}

contract MilestoneFundInvariantTest is Test {
    LaunchToken internal token;
    MilestoneFund internal fund;
    MilestoneFundHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new LaunchToken();
        fund = new MilestoneFund(address(token));
        handler = new MilestoneFundHandler(token, fund);
        for (uint256 i; i < handler.backerCount(); ++i) {
            token.transfer(handler.backers(i), 10_000_000e18);
        }
        targetContract(address(handler));
    }

    /// @dev TRNC held == sum of unreleased over all raises + sum of creator balances.
    function invariant_balanceMatchesObligations() public view {
        uint256 owed;
        for (uint256 i; i < fund.raiseCount(); ++i) {
            owed += fund.unreleased(i);
        }
        for (uint256 i; i < handler.creatorCount(); ++i) {
            owed += fund.creatorBalance(handler.creators(i));
        }
        assertEq(token.balanceOf(address(fund)), owed);
    }

    /// @dev Released + rage-quit payouts never exceed deposits; withdrawn never exceeds released.
    function invariant_payoutsNeverExceedDeposits() public view {
        assertLe(handler.ghostReleased() + handler.ghostQuitPaid(), handler.ghostDeposited());
        assertLe(handler.ghostWithdrawn(), handler.ghostReleased());
        assertEq(
            token.balanceOf(address(fund)),
            handler.ghostDeposited() - handler.ghostQuitPaid() - handler.ghostWithdrawn()
        );
    }

    /// @dev A fully released raise, or one every backer has left, holds nothing.
    function invariant_finishedRaisesHoldNothing() public view {
        for (uint256 i; i < fund.raiseCount(); ++i) {
            MilestoneFund.Raise memory r = fund.raise(i);
            if (r.released == 3 || r.totalShares == 0) {
                assertEq(r.unreleased, 0);
            }
            assertLe(r.approvalWeight, r.totalShares);
            assertLe(r.unreleased, r.totalShares);
            assertLe(r.released, 3);
        }
    }

    /// @dev Per-raise: the sum of backer shares equals totalShares, and the approval weight is at most the
    ///      shares of backers who approved the current tranche.
    function invariant_sharesAndApprovalsAddUp() public view {
        for (uint256 i; i < fund.raiseCount(); ++i) {
            uint256 shares;
            uint256 approved;
            for (uint256 b; b < handler.backerCount(); ++b) {
                address backer = handler.backers(b);
                uint256 s = fund.sharesOf(i, backer);
                shares += s;
                if (fund.hasApproved(i, backer)) approved += s;
            }
            assertEq(shares, fund.raise(i).totalShares);
            assertEq(approved, fund.approvalWeight(i));
        }
    }
}
