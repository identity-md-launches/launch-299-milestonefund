# Tranche (TRNC) and MilestoneFund

Sepolia `evm_project` launch: a fixed-supply launch token plus one application contract, deployed through the
project factory. Site label `lab-milestone-fund`.

| Contract | File | Role |
| --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | Tranche (TRNC), fixed-supply ERC-20, 18 decimals, 1,000,000,000 minted to `msg.sender` |
| `MilestoneFund` | `src/MilestoneFund.sol` | Milestone-gated raises in TRNC with backer-approved tranche releases and rage-quit |

ABI exports live in `docs/abi/LaunchToken.json` and `docs/abi/MilestoneFund.json`; `docs/MilestoneFund.md`
walks through the interface for the website.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`, `ffi = false` and an
empty `fs_permissions`. Dependencies are vendored as plain files (no submodules):

- `lib/forge-std` — forge-std v1.9.6 (`src/` only)
- `lib/openzeppelin-contracts` — OpenZeppelin Contracts v5.1.0, only the files `ERC20`, `SafeERC20` and
  `ReentrancyGuard` need

Tests read no environment variables and make no `vm.setEnv` calls, so they pass in any order and in parallel.
`test/scratch/` is ignored and never submitted.

## Deployment parameters (for the manifest node)

- Chain: Sepolia (11155111) only.
- Launch token: `LaunchToken` (`src/LaunchToken.sol`), no constructor arguments. Name `Tranche`, symbol `TRNC`,
  decimals `18`, supply `1000000000000000000000000000` minor units minted to the deployer (the factory).
- Application contract: `MilestoneFund`, identifier `MilestoneFund`, constructor `(address token)` with
  `constructorArgs: ["$token"]`. The constructor is nonpayable and reverts on the zero address.
- No `$owner`: MilestoneFund has no owner, admin, pause or upgrade path, so the manifest grants no
  privileged role to anyone.
- MilestoneFund holds no TRNC at deploy and never needs a balance. The factory keeps the entire supply for the
  ETH/TRNC pool and the reward distributor.
- Pool: TRNC against native ETH, fee 3000, tick spacing 60, initial sqrtPriceX96
  `79228162514264337593543950336` (the pinned policy's `initialMarketCapWei` overrides this when present).
- Runtime: MilestoneFund's deployed bytecode is under 10 KB, uses no `DELEGATECALL`, `CALLCODE` or
  `SELFDESTRUCT`, and its constructor moves no launch supply. The protected floor tests were run locally
  against the built creation code with a simulated factory and pass.

`script/DeployLocal.s.sol` deploys both contracts on a local Anvil chain for website development. It is not the
Sepolia path and broadcasts nothing unless invoked with `forge script --broadcast` by an operator.

## MilestoneFund behaviour

- **open(bps1, bps2, bps3, fundingDuration)** — caller becomes the creator. Each share is at least 1 basis point,
  the three sum to exactly 10,000, and the funding window is 1 to 90 days inclusive. Raise ids start at 0.
  Tranche 1's vote opens at the funding deadline.
- **deposit(raiseId, amount)** — `amount > 0`, strictly before the deadline, never by the creator. Requires a
  prior ERC-20 `approve` on TRNC; the contract pulls with `safeTransferFrom`. The backer gets `amount` shares.
- **approveTranche(raiseId)** — after the deadline, a backer approves the next unreleased tranche with weight
  equal to their shares, once per backer per tranche. Approvals never carry to the next tranche. Named this
  way so it is never confused with ERC-20 `approve`.
- **release(raiseId)** — anyone, once `approvalWeight * 2 > totalShares` (exactly half is not enough) and at
  least 3 days after the tranche's vote opened (the deadline for tranche 1, the previous release otherwise).
  Tranche 1 pays `unreleased * bps1 / 10000`, tranche 2 pays `unreleased * bps2 / (bps2 + bps3)`, both floored;
  tranche 3 takes everything left so no dust stays. The amount is credited to `creatorBalance[creator]`.
- **rageQuit(raiseId)** — before the deadline returns the full deposit; after it pays
  `shares * unreleased / totalShares` (floor) and the last backer out takes the whole remainder. The backer's
  shares and any approval on the current tranche are removed. A zero payout still clears the position.
- **withdraw()** — pull of the caller's entire released balance across all raises.
- Views: `raiseCount()`, `raise(id)`, `sharesOf(id, backer)`, `approvalWeight(id)`, `unreleased(id)`,
  `creatorBalance(creator)`, plus `hasApproved(id, backer)` and `nextTrancheAmount(id)` for the page.
- Events: `Opened`, `Deposited`, `TrancheApproved`, `Released`, `RageQuit`, `Withdrawn`.

## Assumptions

- TRNC is the plain fixed-supply ERC-20 in this repository: no transfer fee, no rebasing, no hooks. The amount
  pulled is therefore the amount credited. If MilestoneFund were ever pointed at a different token, the share
  accounting would need balance-before/after measurement, which it does not do.
- Every payment in is `approve` + `safeTransferFrom`; every payment out is a `safeTransfer` to the caller after
  state is settled, under OpenZeppelin's `ReentrancyGuard`. The guard is also exercised in tests with a
  callback token that TRNC does not have.
- MilestoneFund has no payable function and no `receive`/`fallback`, so it never holds ETH.
- Backers obtain TRNC by swapping Sepolia ETH in the launch pool the factory seeds. The contract does not swap.
- Timestamps are compared at day scale (1 to 90 day funding, 3 day grace). Validator drift of seconds does not
  matter to the design.
- A raise with no deposits, or one every backer has left, simply ends. Nothing is stranded and nothing can be
  released from it, because `0 * 2 > 0` is false.

## Known limits (documented, not fixed)

- **Sybil majority.** An actor holding more than 50% of a raise's shares through other wallets, including the
  creator backing their own raise from a second address, can approve and release every tranche. They can never
  do so faster than one tranche per 3 days, and each tranche's vote is visible on chain the moment it opens, so
  every other backer can rage-quit with their pro-rata share of the unreleased balance before any TRNC leaves.
  Backers should treat the grace period as their exit window.
- **Rounding.** Tranche 1 and 2 amounts and non-final rage-quit payouts round down. The dust always stays in the
  raise and is swept by the last tranche or the last quitter, never lost, never paid twice.
- **No deadline for approval.** A tranche whose vote never reaches a majority stays open indefinitely; backers
  can leave at any time with their pro-rata share, and the creator receives nothing further.
- **Creator identity.** The creator is whoever called `open`; there is no transfer of the creator role.

## Operational responsibilities

- The manifest node writes `launch.json` naming `LaunchToken` as the launch token and `MilestoneFund` with
  `constructorArgs ["$token"]`. Nothing else in this repository is a deployment input.
- No wallet key, RPC secret or broadcast lives in this repository or its tests. Deployment is performed by the
  services after the independent review.
- The website (a later assignment) reads the TRNC address from `MilestoneFund.token()`, shows balance and
  allowance, puts an Approve step before every paying action, and builds its lists from views and events only,
  chunking log queries from the deployment block.
- Tests passing is not a security audit. The independent adversarial review should attack approval-weight
  double counting across rage-quit, release ordering and rounding, the last-tranche and last-quitter remainders,
  creator self-dealing with a sybil majority, and any path paying out more TRNC than was deposited. The test
  suite already targets each of these; the reviewer should try to break them.

## Test coverage map

- `test/LaunchToken.t.sol` — metadata, supply, exact transfers, absence of mint/admin entrypoints, opcode scan.
- `test/MilestoneFund.t.sol` — constructor, `open` validation bounds, `deposit` rules and allowance failures,
  approval once per tranche with no carry-over, release amounts and dust sweep, the exact-half boundary
  (`approvalWeight * 2 == totalShares` fails, one minor unit more passes), the 3-day grace boundary
  (`voteOpenedAt + 3 days - 1` reverts, `+ 3 days` releases, counted from the previous release), rage-quit
  before and after the deadline, last-quitter remainder, approval removal on quit and stale-approval safety,
  withdraw as pull, sybil majority pacing, reentrancy on `rageQuit` and `withdraw`, and fuzz over bps splits,
  deposit sizes and quit order with the conservation assertions.
- `test/MilestoneFundInvariant.t.sol` — handler-driven invariants over random sequences: TRNC balance equals
  the sum of `unreleased` plus creator balances; released plus rage-quit payouts never exceed deposits;
  finished raises hold nothing; shares and approvals add up.
- `test/DeployLocal.t.sol` — the local script's `deploy()` wires the fund to the token.
