// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MilestoneFund
/// @notice Milestone-gated raises denominated in TRNC. A creator opens a raise split into three tranches.
///         Backers deposit TRNC before the funding deadline and receive one share per minor unit. After the
///         deadline the tranches release strictly in order: a tranche releases once backers holding more than
///         half of the outstanding shares approve it and at least 3 days have passed since its vote opened.
///         Any backer can rage-quit at any time for their pro-rata part of the unreleased balance. Released
///         TRNC is credited to the creator, who withdraws it with a pull.
/// @dev No owner, admin, pause or upgrade path. The contract has no payable function and no receive or
///      fallback, so it never holds ETH. Every payment in is `approve` + `safeTransferFrom`; every payment
///      out is a `safeTransfer` to the caller after state is settled, under a reentrancy guard. TRNC is a
///      plain fixed-supply ERC-20 without transfer fees, so the amount pulled equals the amount credited.
contract MilestoneFund is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @notice Number of tranches in every raise.
    uint8 public constant TRANCHES = 3;
    /// @notice Basis-point denominator; the three tranche shares must sum to this.
    uint16 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Shortest funding window.
    uint64 public constant MIN_FUNDING_DURATION = 1 days;
    /// @notice Longest funding window.
    uint64 public constant MAX_FUNDING_DURATION = 90 days;
    /// @notice Grace period between a tranche's vote opening and the earliest release. Dissenting backers
    ///         can rage-quit during this window before any TRNC leaves the raise.
    uint64 public constant GRACE_PERIOD = 3 days;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    struct Raise {
        /// @dev Address that opened the raise and receives released tranches.
        address creator;
        /// @dev Funding deadline; deposits are accepted strictly before it.
        uint64 deadline;
        /// @dev When the vote on the current (next unreleased) tranche opened.
        uint64 voteOpenedAt;
        /// @dev Number of tranches already released (0..3).
        uint8 released;
        /// @dev Tranche shares in basis points.
        uint16 bps1;
        uint16 bps2;
        uint16 bps3;
        /// @dev Sum of all outstanding backer shares (one share per minor unit deposited).
        uint256 totalShares;
        /// @dev TRNC held for this raise that has not been released or paid out.
        uint256 unreleased;
        /// @dev Shares that approved the current tranche.
        uint256 approvalWeight;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @notice The TRNC token every raise is denominated in.
    IERC20 public immutable token;

    /// @notice Number of raises opened so far. Raise ids run from 0 to raiseCount() - 1.
    uint256 public raiseCount;

    mapping(uint256 raiseId => Raise) private _raises;
    mapping(uint256 raiseId => mapping(address backer => uint256)) private _shares;
    /// @dev Tranche number (1-based) the backer last approved, or 0. An approval only counts while it equals
    ///      `released + 1`, so approvals never carry over to the next tranche.
    mapping(uint256 raiseId => mapping(address backer => uint8)) private _approvedTranche;
    /// @notice Released TRNC a creator can withdraw.
    mapping(address creator => uint256) public creatorBalance;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event Opened(
        uint256 indexed raiseId, address indexed creator, uint16 bps1, uint16 bps2, uint16 bps3, uint64 deadline
    );
    event Deposited(uint256 indexed raiseId, address indexed backer, uint256 amount);
    event TrancheApproved(uint256 indexed raiseId, address indexed backer, uint8 tranche, uint256 weight);
    event Released(uint256 indexed raiseId, uint8 tranche, uint256 amount, uint64 nextVoteOpenedAt);
    event RageQuit(uint256 indexed raiseId, address indexed backer, uint256 shares, uint256 payout);
    event Withdrawn(address indexed creator, uint256 amount);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error ZeroToken();
    error InvalidBps();
    error InvalidFundingDuration();
    error UnknownRaise();
    error ZeroAmount();
    error FundingClosed();
    error FundingOpen();
    error CreatorCannotBack();
    error NoShares();
    error AllReleased();
    error AlreadyApproved();
    error InsufficientApproval();
    error GracePeriodActive();
    error NothingToWithdraw();

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @param token_ The TRNC token address. The contract holds no TRNC at deploy and never needs any.
    constructor(address token_) {
        if (token_ == address(0)) revert ZeroToken();
        token = IERC20(token_);
    }

    // ------------------------------------------------------------------
    // Creator actions
    // ------------------------------------------------------------------

    /// @notice Open a raise. The caller is the creator.
    /// @param bps1 Share of tranche 1 in basis points (>= 1).
    /// @param bps2 Share of tranche 2 in basis points (>= 1).
    /// @param bps3 Share of tranche 3 in basis points (>= 1). The three must sum to exactly 10,000.
    /// @param fundingDuration Seconds the raise accepts deposits, 1 to 90 days inclusive.
    /// @return raiseId The id of the new raise.
    function open(uint16 bps1, uint16 bps2, uint16 bps3, uint64 fundingDuration) external returns (uint256 raiseId) {
        if (bps1 == 0 || bps2 == 0 || bps3 == 0) revert InvalidBps();
        if (uint256(bps1) + bps2 + bps3 != BPS_DENOMINATOR) revert InvalidBps();
        if (fundingDuration < MIN_FUNDING_DURATION || fundingDuration > MAX_FUNDING_DURATION) {
            revert InvalidFundingDuration();
        }

        raiseId = raiseCount++;
        uint64 deadline = uint64(block.timestamp) + fundingDuration;

        Raise storage r = _raises[raiseId];
        r.creator = msg.sender;
        r.deadline = deadline;
        r.voteOpenedAt = deadline; // tranche 1's vote opens at the funding deadline
        r.bps1 = bps1;
        r.bps2 = bps2;
        r.bps3 = bps3;

        emit Opened(raiseId, msg.sender, bps1, bps2, bps3, deadline);
    }

    /// @notice Withdraw every TRNC released to the caller across all raises.
    function withdraw() external nonReentrant {
        uint256 amount = creatorBalance[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        creatorBalance[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Backer actions
    // ------------------------------------------------------------------

    /// @notice Deposit TRNC into a raise before its funding deadline. Requires a prior ERC-20 approval.
    ///         The backer receives shares equal to the amount.
    function deposit(uint256 raiseId, uint256 amount) external nonReentrant {
        Raise storage r = _raise(raiseId);
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp >= r.deadline) revert FundingClosed();
        if (msg.sender == r.creator) revert CreatorCannotBack();

        _shares[raiseId][msg.sender] += amount;
        r.totalShares += amount;
        r.unreleased += amount;

        emit Deposited(raiseId, msg.sender, amount);
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Approve the next unreleased tranche with weight equal to the caller's shares.
    ///         Once per backer per tranche; approvals never carry over to the next tranche.
    function approveTranche(uint256 raiseId) external {
        Raise storage r = _raise(raiseId);
        if (block.timestamp < r.deadline) revert FundingOpen();
        if (r.released >= TRANCHES) revert AllReleased();
        uint256 shares = _shares[raiseId][msg.sender];
        if (shares == 0) revert NoShares();

        uint8 tranche = r.released + 1;
        if (_approvedTranche[raiseId][msg.sender] == tranche) revert AlreadyApproved();
        _approvedTranche[raiseId][msg.sender] = tranche;
        r.approvalWeight += shares;

        emit TrancheApproved(raiseId, msg.sender, tranche, shares);
    }

    /// @notice Release the next tranche to the creator's withdrawable balance. Anyone may call once
    ///         approval weight x 2 > total shares and the 3-day grace period since the vote opened has passed.
    ///         Tranche i pays unreleased x bps_i / remainingBps (floor); the last tranche takes all that is left.
    function release(uint256 raiseId) external {
        Raise storage r = _raise(raiseId);
        if (r.released >= TRANCHES) revert AllReleased();
        if (r.approvalWeight * 2 <= r.totalShares) revert InsufficientApproval();
        if (block.timestamp < uint256(r.voteOpenedAt) + GRACE_PERIOD) revert GracePeriodActive();

        uint8 tranche = r.released + 1;
        uint256 amount = _trancheAmount(r, tranche);

        r.unreleased -= amount;
        r.released = tranche;
        r.approvalWeight = 0;
        r.voteOpenedAt = uint64(block.timestamp);
        creatorBalance[r.creator] += amount;

        emit Released(raiseId, tranche, amount, uint64(block.timestamp));
    }

    /// @notice Leave a raise. Before the deadline the full deposit is returned; after it the backer receives
    ///         shares x unreleased / totalShares (floor), and the last backer out takes the whole remainder.
    ///         The backer's shares and any approval on the current tranche are removed.
    function rageQuit(uint256 raiseId) external nonReentrant {
        Raise storage r = _raise(raiseId);
        uint256 shares = _shares[raiseId][msg.sender];
        if (shares == 0) revert NoShares();

        uint256 payout;
        if (block.timestamp < r.deadline) {
            // Nothing can have been released before the deadline, so unreleased == totalShares.
            payout = shares;
        } else if (shares == r.totalShares) {
            payout = r.unreleased;
        } else {
            payout = shares * r.unreleased / r.totalShares;
        }

        if (_approvedTranche[raiseId][msg.sender] == r.released + 1) {
            r.approvalWeight -= shares;
        }
        delete _approvedTranche[raiseId][msg.sender];
        delete _shares[raiseId][msg.sender];
        r.totalShares -= shares;
        r.unreleased -= payout;

        emit RageQuit(raiseId, msg.sender, shares, payout);
        if (payout != 0) token.safeTransfer(msg.sender, payout);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Full state of a raise.
    function raise(uint256 raiseId) external view returns (Raise memory) {
        return _raise(raiseId);
    }

    /// @notice Shares held by `backer` in `raiseId` (one per minor unit deposited).
    function sharesOf(uint256 raiseId, address backer) external view returns (uint256) {
        return _shares[raiseId][backer];
    }

    /// @notice Shares that have approved the current tranche of `raiseId`.
    function approvalWeight(uint256 raiseId) external view returns (uint256) {
        return _raise(raiseId).approvalWeight;
    }

    /// @notice TRNC still held for `raiseId` that has not been released or paid out.
    function unreleased(uint256 raiseId) external view returns (uint256) {
        return _raise(raiseId).unreleased;
    }

    /// @notice Whether `backer` has approved the current tranche of `raiseId`.
    function hasApproved(uint256 raiseId, address backer) external view returns (bool) {
        Raise storage r = _raise(raiseId);
        return r.released < TRANCHES && _approvedTranche[raiseId][backer] == r.released + 1;
    }

    /// @notice Amount the next release of `raiseId` would credit to the creator right now, or 0 if all
    ///         tranches are released.
    function nextTrancheAmount(uint256 raiseId) external view returns (uint256) {
        Raise storage r = _raise(raiseId);
        if (r.released >= TRANCHES) return 0;
        return _trancheAmount(r, r.released + 1);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _raise(uint256 raiseId) private view returns (Raise storage r) {
        if (raiseId >= raiseCount) revert UnknownRaise();
        r = _raises[raiseId];
    }

    /// @dev Amount tranche `tranche` (1-based) pays out of the current unreleased balance.
    function _trancheAmount(Raise storage r, uint8 tranche) private view returns (uint256) {
        uint256 pool = r.unreleased;
        if (tranche == 1) {
            return pool * r.bps1 / BPS_DENOMINATOR;
        }
        if (tranche == 2) {
            return pool * r.bps2 / (uint256(r.bps2) + r.bps3);
        }
        return pool; // last tranche takes everything that is left, so no dust stays
    }
}
