// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BossFixture} from "./utils/BossFixture.sol";
import {BossHook} from "../src/BossHook.sol";
import {OracleGate} from "../src/OracleGate.sol";
import {FixedAbility} from "./mocks/Abilities.sol";

contract BossRegistryTest is BossFixture {
    FixedAbility doubler;

    function setUp() public override {
        super.setUp();
        doubler = new FixedAbility(20_000, 10_000);
    }

    function _propose(address a) internal returns (uint256 id) {
        vm.prank(keeper);
        board.propose(a, "test");
        (id,) = board.pending();
        vm.warp(block.timestamp + 40 minutes); // the oracle answers after the proposal
    }

    function _accept(uint256 answer) internal {
        OracleGate.Attestation memory a = attestation(answer);
        hook.acceptAbility(a, signAttestation(a));
    }

    function test_acceptedAbility_activatesAfter12h() public {
        uint256 id = _propose(address(doubler));
        _accept(id * 2 + 1);
        (address active, address queued, uint64 at) = hook.currentAbility();
        assertEq(active, address(0));
        assertEq(queued, address(doubler));
        assertEq(at, block.timestamp + 12 hours);

        buyExactIn(alice, 0.1 ether);
        assertEq(hook.hp(), 0.9 ether, "still 1x before the delay");

        vm.warp(block.timestamp + 12 hours);
        buyExactIn(alice, 0.1 ether);
        assertEq(hook.activeAbility(), address(doubler));
        assertEq(hook.hp(), 0.7 ether, "2x after activation");
    }

    function test_rejectedAnswerReverts() public {
        uint256 id = _propose(address(doubler));
        OracleGate.Attestation memory a = attestation(id * 2);
        bytes memory sig = signAttestation(a);
        vm.expectRevert(abi.encodeWithSelector(BossHook.NotApproved.selector, id * 2));
        hook.acceptAbility(a, sig);
    }

    function test_answerForOldIdReverts() public {
        uint256 id = _propose(address(doubler));
        _propose(address(new FixedAbility(10_000, 10_000))); // id + 1 is now pending
        OracleGate.Attestation memory a = attestation(id * 2 + 1);
        bytes memory sig = signAttestation(a);
        vm.expectRevert(abi.encodeWithSelector(BossHook.NotApproved.selector, id * 2 + 1));
        hook.acceptAbility(a, sig);
    }

    // ---- Review Focus 5
    function test_sameAttestationTwiceReverts() public {
        uint256 id = _propose(address(doubler));
        OracleGate.Attestation memory a = attestation(id * 2 + 1);
        bytes memory sig = signAttestation(a);
        hook.acceptAbility(a, sig);
        vm.expectRevert(BossHook.NothingPending.selector);
        hook.acceptAbility(a, sig);
    }

    function test_attestationIssuedBeforeProposalReverts() public {
        OracleGate.Attestation memory early = attestation(3); // id 1 approved, signed now
        bytes memory sig = signAttestation(early);
        vm.warp(block.timestamp + 1);
        vm.prank(keeper);
        board.propose(address(doubler), "late");
        vm.expectRevert(BossHook.StaleAttestation.selector);
        hook.acceptAbility(early, sig);
    }

    function test_atMostOneActivationPerDay() public {
        uint256 id1 = _propose(address(doubler));
        _accept(id1 * 2 + 1);
        uint64 first = hook.queuedActivatesAt();
        vm.warp(first); // first one active
        buyExactIn(alice, 0.01 ether);
        uint256 id2 = _propose(address(new FixedAbility(5_000, 10_000)));
        _accept(id2 * 2 + 1);
        assertEq(hook.queuedActivatesAt(), first + 24 hours, "pushed to 24h after the previous activation");
    }

    function test_cannotQueueOverQueued() public {
        uint256 id1 = _propose(address(doubler));
        _accept(id1 * 2 + 1);
        uint256 id2 = _propose(address(new FixedAbility(5_000, 10_000)));
        OracleGate.Attestation memory a = attestation(id2 * 2 + 1);
        bytes memory sig = signAttestation(a);
        vm.expectRevert(BossHook.AbilityAlreadyQueued.selector);
        hook.acceptAbility(a, sig);
    }

    function test_nothingPendingReverts() public {
        OracleGate.Attestation memory a = attestation(1);
        bytes memory sig = signAttestation(a);
        vm.expectRevert(BossHook.NothingPending.selector);
        hook.acceptAbility(a, sig);
    }

    function test_expiredAttestationReverts() public {
        uint256 id = _propose(address(doubler));
        OracleGate.Attestation memory a = attestation(id * 2 + 1);
        bytes memory sig = signAttestation(a);
        vm.warp(a.expiresAt);
        vm.expectRevert(OracleGate.InvalidAttestation.selector);
        hook.acceptAbility(a, sig);
    }

    function test_wrongSignerReverts() public {
        uint256 id = _propose(address(doubler));
        OracleGate.Attestation memory a = attestation(id * 2 + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, hook.attestationDigest(a));
        vm.expectRevert(OracleGate.InvalidSigner.selector);
        hook.acceptAbility(a, abi.encodePacked(r, s, v));
    }

    function test_currentAbility_reportsMaturedButUnsynced() public {
        uint256 id = _propose(address(doubler));
        _accept(id * 2 + 1);
        vm.warp(hook.queuedActivatesAt());
        assertEq(hook.activeAbility(), address(0), "storage not synced yet (no swap since)");
        (address active, address queued, uint64 at) = hook.currentAbility();
        assertEq(active, address(doubler), "currentAbility counts the matured one");
        assertEq(queued, address(0));
        assertEq(at, 0);
    }

    function test_acceptAbility_syncsMaturedQueued() public {
        uint256 id1 = _propose(address(doubler));
        _accept(id1 * 2 + 1);
        vm.warp(hook.queuedActivatesAt());
        FixedAbility next = new FixedAbility(5_000, 10_000);
        uint256 id2 = _propose(address(next));
        OracleGate.Attestation memory a = attestation(id2 * 2 + 1);
        bytes memory sig = signAttestation(a);
        vm.expectEmit(true, false, false, false, address(hook));
        emit BossHook.AbilityActivated(address(doubler));
        hook.acceptAbility(a, sig);
        assertEq(hook.activeAbility(), address(doubler), "matured ability synced by the accept");
        assertEq(hook.queuedAbility(), address(next));
    }
}
