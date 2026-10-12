// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BossToken} from "../src/BossToken.sol";

contract BossTokenTest is Test {
    BossToken token;
    address alice = makeAddr("alice");

    function setUp() public {
        token = new BossToken();
    }

    function test_supplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), 1_000_000_000 ether);
        assertEq(token.decimals(), 18);
        assertEq(token.symbol(), "BOSS");
    }

    function test_transferMovesBalance() public {
        token.transfer(alice, 5 ether);
        assertEq(token.balanceOf(alice), 5 ether);
    }

    function test_transferFromRespectsAllowance() public {
        token.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BossToken.InsufficientAllowance.selector, 1 ether, 2 ether));
        token.transferFrom(address(this), alice, 2 ether);
    }
}
