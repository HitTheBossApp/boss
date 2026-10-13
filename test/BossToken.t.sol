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

    /// @dev Binds in its constructor, as BossHook does: only a contract under construction may bind.
    constructor(BossToken token) {
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

/// @dev A deployed contract the launcher calls later: refused.
contract LateBinder {
    function bind(BossToken token) external {
        token.bindHook();
    }
}

contract BossTokenTest is Test {
    BossToken token;
    RecordingHook hookStub;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

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

    // ---- the hook binding

    function test_unboundTokenIsAPlainErc20() public {
        assertEq(token.hook(), address(0));
        token.transfer(alice, 1 ether);
        assertEq(token.balanceOf(alice), 1 ether, "no hook bound: a plain transfer");
    }

    function test_bindHook_recordsTheCallerOnce() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(true, false, false, false, address(token));
        emit BossToken.HookBound(predicted);
        hookStub = new RecordingHook(token);
        assertEq(token.hook(), address(hookStub));
        vm.expectRevert(BossToken.HookAlreadyBound.selector);
        new RecordingHook(token);
        assertEq(token.hook(), address(hookStub), "the first binding stands");
    }

    function test_bindHook_fromAnotherOriginReverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger, stranger);
        vm.expectRevert(BossToken.NotLaunchOrigin.selector);
        new RecordingHook(token);
        assertEq(token.hook(), address(0));
    }

    /// @dev Audit 965a5fce (finding 2): a deployed contract, or the launcher's own EOA, cannot bind.
    function test_bindHook_onlyAContractUnderConstruction() public {
        LateBinder late = new LateBinder();
        vm.expectRevert(BossToken.NotAHookUnderConstruction.selector);
        late.bind(token);
        address launcher = tx.origin; // the signer that deployed the token
        vm.prank(launcher, launcher);
        vm.expectRevert(BossToken.NotAHookUnderConstruction.selector);
        token.bindHook();
        assertEq(token.hook(), address(0));
    }

    function test_transferNotifiesTheHook() public {
        hookStub = new RecordingHook(token);
        token.transfer(alice, 5 ether);
        assertEq(hookStub.calls(), 1);
        assertEq(hookStub.lastFrom(), address(this));
        assertEq(hookStub.lastTo(), alice);
        assertEq(hookStub.lastValue(), 5 ether);
        assertEq(token.balanceOf(alice), 5 ether, "balances move before the hook hears about it");
    }

    function test_transferFromNotifiesTheHook() public {
        hookStub = new RecordingHook(token);
        token.approve(bob, 3 ether);
        vm.prank(bob);
        token.transferFrom(address(this), alice, 3 ether);
        assertEq(hookStub.calls(), 1);
        assertEq(hookStub.lastFrom(), address(this));
        assertEq(hookStub.lastTo(), alice);
        assertEq(hookStub.lastValue(), 3 ether);
    }

    function test_transferRevertsIfTheHookReverts() public {
        hookStub = new RecordingHook(token);
        hookStub.setRevert(true);
        vm.expectRevert("hook says no");
        token.transfer(alice, 1 ether);
        assertEq(token.balanceOf(alice), 0, "a transfer the hook refuses does not happen");
    }
}
