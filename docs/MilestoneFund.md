# MilestoneFund ABI guide

Machine-readable ABIs: `docs/abi/MilestoneFund.json`, `docs/abi/LaunchToken.json`. Both are `forge inspect`
exports of the compiled contracts and are regenerated with:

```
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/MilestoneFund.sol:MilestoneFund abi --json > docs/abi/MilestoneFund.json
```

## Constructor

`constructor(address token_)` — the TRNC address. The manifest passes `$token`. Reverts with `ZeroToken()` on
the zero address.

## Write functions

| Function | Who | Effect |
| --- | --- | --- |
| `open(uint16 bps1, uint16 bps2, uint16 bps3, uint64 fundingDuration) returns (uint256 raiseId)` | anyone (becomes creator) | Creates a raise; deadline = now + duration; tranche 1 vote opens at the deadline |
| `deposit(uint256 raiseId, uint256 amount)` | any non-creator, before deadline | Pulls `amount` TRNC (needs `approve` first), credits `amount` shares |
| `approveTranche(uint256 raiseId)` | backer, after deadline | Adds the caller's shares to the current tranche's approval weight, once per tranche |
| `release(uint256 raiseId)` | anyone | Credits the next tranche to the creator once weight x 2 > total shares and 3 days passed since the vote opened |
| `rageQuit(uint256 raiseId)` | backer | Pays the caller's pro-rata share of `unreleased` (full deposit before the deadline; the last backer takes the remainder), removes shares and any current approval |
| `withdraw()` | creator | Transfers the caller's whole `creatorBalance` |

## Views

| Function | Returns |
| --- | --- |
| `token()` | TRNC address |
| `raiseCount()` | Number of raises; ids are `0 .. raiseCount() - 1` |
| `raise(uint256 id)` | `Raise` struct: `creator, deadline, voteOpenedAt, released, bps1, bps2, bps3, totalShares, unreleased, approvalWeight` |
| `sharesOf(uint256 id, address backer)` | Backer shares (one per minor unit deposited) |
| `approvalWeight(uint256 id)` | Shares approving the current tranche |
| `unreleased(uint256 id)` | TRNC still held for the raise |
| `creatorBalance(address creator)` | Withdrawable released TRNC |
| `hasApproved(uint256 id, address backer)` | Whether the backer approved the current tranche |
| `nextTrancheAmount(uint256 id)` | What the next `release` would credit right now (0 when fully released) |
| `TRANCHES`, `BPS_DENOMINATOR`, `MIN_FUNDING_DURATION`, `MAX_FUNDING_DURATION`, `GRACE_PERIOD` | Constants: 3, 10000, 1 day, 90 days, 3 days |

Progress for a listing: funded = `raise(id).totalShares` while funding is open; released so far =
tranche count `raise(id).released` of 3; remaining = `unreleased(id)`; vote status =
`approvalWeight(id) * 2 > totalShares` and `now >= voteOpenedAt + 3 days`.

## Events

```
Opened(uint256 indexed raiseId, address indexed creator, uint16 bps1, uint16 bps2, uint16 bps3, uint64 deadline)
Deposited(uint256 indexed raiseId, address indexed backer, uint256 amount)
TrancheApproved(uint256 indexed raiseId, address indexed backer, uint8 tranche, uint256 weight)
Released(uint256 indexed raiseId, uint8 tranche, uint256 amount, uint64 nextVoteOpenedAt)
RageQuit(uint256 indexed raiseId, address indexed backer, uint256 shares, uint256 payout)
Withdrawn(address indexed creator, uint256 amount)
```

`tranche` in `TrancheApproved` and `Released` is 1-based.

## Errors

`ZeroToken`, `InvalidBps`, `InvalidFundingDuration`, `UnknownRaise`, `ZeroAmount`, `FundingClosed`,
`FundingOpen`, `CreatorCannotBack`, `NoShares`, `AllReleased`, `AlreadyApproved`, `InsufficientApproval`,
`GracePeriodActive`, `NothingToWithdraw`, plus OpenZeppelin's `ReentrancyGuardReentrantCall` and the ERC-20
allowance/balance errors surfaced through `SafeERC20`.
