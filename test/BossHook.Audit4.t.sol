// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReviewBase} from "./review/ReviewBase.sol";
import {ScriptRouter} from "./utils/ScriptRouter.sol";
import {OracleGate} from "../src/OracleGate.sol";
import {FixedAbility} from "./mocks/Abilities.sol";

/// @notice The fourth swarm audit of HitTheBossApp/boss@7dc01c2 (job 94b6c9a5): one test per finding
/// fixed in code, written from the judge's reproductions. Each one failed on 7dc01c2 before the fix.
contract BossAudit4Test is ReviewBase {
    address internal eve = makeAddr("eve");

    /// @dev The Uniswap app's interface-fee shape, run by the router that executes the kill: take all
    /// the BOSS to the router, pay 0.25% of its balance to the fee collector, sweep the rest to carol.
    function _killWithInterfaceFee() internal {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](4);
        a[0] = script.buy(0.02 ether);
        a[1] = script.takeBoss(address(script), type(uint256).max);
        a[2] = script.forwardShare(feeCollector, 25, 10_000);
        a[3] = script.forwardAllBut(carol, 0);
        vm.prank(carol, carol);
        script.run(a);
    }

    // ------------------------------------------------------------------ medium 1: planted BOSS on the fee custodian

    /// Judge's repro: alice leaves 0.01 of HP; eve plants 10,000,000 BOSS on the router; carol kills
    /// through it with the interface fee. The fee is a quarter of a percent of the blow, not all of it.
    function test_M1_plantedBossOnTheFeeCustodian_blowStaysWithThePlayer() public {
        buyExactIn(alice, 0.99 ether);
        giveBoss(eve, 10_000_000 ether);
        vm.prank(eve);
        boss.transfer(address(script), 10_000_000 ether);

        _killWithInterfaceFee();

        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, carol, "the player keeps the kill");
        assertEq(hook.unclaimedKill(carol), prize);
        assertEq(hook.unclaimedKill(feeCollector), 0, "the fee collector gets no prize");
        uint256 blow = hook.damage(1, carol) + hook.damage(1, feeCollector) + hook.damage(1, address(script));
        assertEq(blow, 0.01 ether, "the blow's credit is all accounted for");
        assertApproxEqAbs(hook.damage(1, feeCollector), blow * 25 / 10_000, 1, "the fee carries its share only");
        assertApproxEqAbs(hook.damage(1, carol), blow - blow * 25 / 10_000, 1, "the player carries the rest");
        assertAccounting();
    }

    /// Control: the same shape without a plant keeps the prize and 99.75% of the blow with carol.
    function test_M1_interfaceFeeWithoutPlant_sameSplit() public {
        buyExactIn(alice, 0.99 ether);
        _killWithInterfaceFee();
        (address killer,,,,) = hook.results(1);
        assertEq(killer, carol);
        assertApproxEqAbs(hook.damage(1, feeCollector), uint256(0.01 ether) * 25 / 10_000, 1);
    }

    // ------------------------------------------------------------------ info 3: same-second attestation

    function test_I3_attestationIssuedInTheProposalSecond_isAccepted() public {
        address ability = address(new FixedAbility(10_000, 10_000));
        vm.prank(keeper);
        board.propose(ability, "swarm job");
        (uint256 id,) = board.pending();
        OracleGate.Attestation memory a = attestation(id * 2 + 1); // issuedAt == proposedAt
        hook.acceptAbility(a, signAttestation(a));
        assertEq(hook.queuedAbility(), ability, "queued in the same second");
    }

    // ------------------------------------------------------------------ info 4: the forfeit rounds up

    /// Judge's repro: handing back fewer than bought/damage wei of BOSS used to forfeit nothing.
    function test_I4_tinySellIntoThePool_forfeitsAtLeastOneWei() public {
        buyExactIn(alice, 0.1 ether);
        uint256 d0 = hook.damage(1, alice);
        uint256 b0 = hook.bought(1, alice);
        uint256 tiny = b0 / d0; // less than one wei of credit's worth of BOSS
        assertGt(tiny, 0);
        vm.prank(alice);
        boss.transfer(address(manager), tiny);
        assertEq(hook.damage(1, alice), d0 - 1, "the forfeit is rounded up, never down to zero");
        assertEq(hook.eligibleDamage(1), d0 - 1);
    }
}
