// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MilestoneFund} from "../src/MilestoneFund.sol";

/// @notice Local-only deployment for an Anvil fork or dev chain. The Sepolia launch goes through the project
///         factory driven by launch.json; this script is never used for it and broadcasts nothing by itself.
/// @dev `deploy()` takes no configuration and reads no environment, so tests call it directly.
contract DeployLocal is Script {
    function deploy() public returns (LaunchToken token, MilestoneFund fund) {
        token = new LaunchToken();
        fund = new MilestoneFund(address(token));
    }

    function run() external returns (LaunchToken token, MilestoneFund fund) {
        vm.startBroadcast();
        (token, fund) = deploy();
        vm.stopBroadcast();
    }
}
