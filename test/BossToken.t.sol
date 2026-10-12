// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BossToken} from "../src/BossToken.sol";

/// @dev Stands in for BossHook: records what the token tells it.
contract RecordingHook {
    address public lastFrom;
    address public lastTo;
    uint256 public lastValue;
    uint256 public calls;
    bool public shouldRevert;

    function bind(BossToken token) external {
        token.bindHook();
    }

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function onBossTransfer(address from, address to, uint256 value) external {
        if (shouldRevert) revert("hook says no");
        lastFrom = from;
        lastTo = to;
        lastValue = value;
        calls++;
    }
}

contract BossTokenTest is Test {
    BossToken token;
    RecordingHook hookStub;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new BossToken();
        hookStub = new RecordingHook();
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

    // ---- the hook binding

    function test_unboundTokenIsAPlainErc20() public {
        assertEq(token.hook(), address(0));
        token.transfer(alice, 1 ether);
        assertEq(hookStub.calls(), 0);
    }

    function test_bindHook_recordsTheCallerOnce() public {
        vm.expectEmit(true, false, false, false, address(token));
        emit BossToken.HookBound(address(hookStub));
        hookStub.bind(token);
        assertEq(token.hook(), address(hookStub));
        RecordingHook another = new RecordingHook();
        vm.expectRevert(BossToken.HookAlreadyBound.selector);
        another.bind(token);
        assertEq(token.hook(), address(hookStub), "the first binding stands");
    }

    function test_bindHook_fromAnotherOriginReverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger, stranger);
        vm.expectRevert(BossToken.NotLaunchOrigin.selector);
        hookStub.bind(token);
        assertEq(token.hook(), address(0));
    }

    function test_transferNotifiesTheHook() public {
        hookStub.bind(token);
        token.transfer(alice, 5 ether);
        assertEq(hookStub.calls(), 1);
        assertEq(hookStub.lastFrom(), address(this));
        assertEq(hookStub.lastTo(), alice);
        assertEq(hookStub.lastValue(), 5 ether);
        assertEq(token.balanceOf(alice), 5 ether, "balances move before the hook hears about it");
    }

    function test_transferFromNotifiesTheHook() public {
        hookStub.bind(token);
        token.approve(bob, 3 ether);
        vm.prank(bob);
        token.transferFrom(address(this), alice, 3 ether);
        assertEq(hookStub.calls(), 1);
        assertEq(hookStub.lastFrom(), address(this));
        assertEq(hookStub.lastTo(), alice);
        assertEq(hookStub.lastValue(), 3 ether);
    }

    function test_transferRevertsIfTheHookReverts() public {
        hookStub.bind(token);
        hookStub.setRevert(true);
        vm.expectRevert("hook says no");
        token.transfer(alice, 1 ether);
        assertEq(token.balanceOf(alice), 0, "a transfer the hook refuses does not happen");
    }
}
