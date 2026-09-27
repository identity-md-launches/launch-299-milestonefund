// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Tranche");
        assertEq(token.symbol(), "TRNC");
        assertEq(token.decimals(), 18);
    }

    function test_fixedSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.SUPPLY(), 10 ** 27);
        assertEq(token.balanceOf(deployer), 10 ** 27);
    }

    function test_transferMovesExactAmount() public {
        address to = makeAddr("to");
        vm.prank(deployer);
        assertTrue(token.transfer(to, 5e18));
        assertEq(token.balanceOf(to), 5e18);
        assertEq(token.balanceOf(deployer), 10 ** 27 - 5e18);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 10 ** 27);
        address to = makeAddr("to");
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), 10 ** 27);
    }

    function test_transferRevertsWhenInsufficient() public {
        address to = makeAddr("to");
        vm.prank(to);
        vm.expectRevert();
        token.transfer(deployer, 1);
    }

    function test_approveAndTransferFrom() public {
        address spender = makeAddr("spender");
        vm.prank(deployer);
        token.approve(spender, 7e18);
        vm.prank(spender);
        token.transferFrom(deployer, spender, 7e18);
        assertEq(token.balanceOf(spender), 7e18);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_noMintOrAdminEntrypoints() public {
        address attacker = makeAddr("attacker");
        string[6] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(address,uint256)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(attacker);
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], attacker, uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        vm.prank(deployer);
        (bool okDeployer,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", deployer, 1));
        assertFalse(okDeployer);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }
}
