// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Tranche (TRNC) launch token
/// @notice Fixed-supply ERC-20. The whole supply of 1,000,000,000 TRNC (10^27 minor units, 18 decimals)
///         is minted once to the deployer in the constructor. The project factory deploys it, so the
///         factory receives the supply and splits it between the launch pool and the reward distributor.
/// @dev No constructor arguments, no owner, no mint, burn-by-admin, pause, blocklist, fee or upgrade path.
///      Transfers move exactly the requested amount, which MilestoneFund relies on when it credits shares.
contract LaunchToken is ERC20 {
    /// @notice Total supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant SUPPLY = 1_000_000_000e18;

    constructor() ERC20("Tranche", "TRNC") {
        _mint(msg.sender, SUPPLY);
    }
}
