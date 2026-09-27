// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployLocal} from "../script/DeployLocal.s.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MilestoneFund} from "../src/MilestoneFund.sol";

contract DeployLocalTest is Test {
    function test_deployWiresFundToToken() public {
        DeployLocal s = new DeployLocal();
        (LaunchToken token, MilestoneFund fund) = s.deploy();
        assertEq(address(fund.token()), address(token));
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(s)), 10 ** 27);
        assertEq(token.balanceOf(address(fund)), 0);
    }
}
