// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReviewBase} from "./ReviewBase.sol";
import {ScriptRouter} from "../utils/ScriptRouter.sol";
import {ReviewRouter} from "./ReviewRouter.sol";
import {BossHook} from "../../src/BossHook.sol";

/// @dev Independent review probes for "credit follows the BOSS" (commit 14d002a). Each probe
/// states what the design claims and what the code does; a PASS means the code does what the
/// probe's assertions say, which is not always what the design claims (see the names).
abstract contract ReviewFollowBossBase is ReviewBase {
    // =================================================================== A. the killer prize follows the FIRST take, whatever its size

    /// @dev Design claim: "the killing blow ... moves to the wallet that receives that BOSS".
    /// Code: `_moveKill` runs on the first take to a non-signer, however small. A router that takes an
    /// output fee first (Universal Router TAKE_PORTION, the shape interface fees use) hands the whole
    /// killer prize to the fee collector; the player who signed and received 99.75% of the BOSS gets none.
    function test_probeA_killPrize_goesToTheFirstDustTaker_notToTheBossRecipient() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether); // kills boss 1
        a[1] = script.takeBossShare(feeCollector, 25, 10_000); // a 0.25% output fee, taken first
        a[2] = script.takeBoss(alice, type(uint256).max); // the player gets the other 99.75%
        vm.prank(alice, alice);
        script.run(a);

        (address killer,, uint256 prize,,) = hook.results(1);
        assertGt(prize, 0);
        assertEq(killer, alice, "FIXED: the prize follows the largest share of the kill's BOSS");
        assertEq(hook.unclaimedKill(alice), prize);
        assertEq(hook.unclaimedKill(feeCollector), 0, "FIXED: a 0.25% fee take does not decide the kill");
        // The damage credit, by contrast, is split in proportion (as designed).
        assertApproxEqRel(hook.damage(1, alice), INITIAL_HP * 9_975 / 10_000, 1e14);
        assertApproxEqRel(hook.damage(1, feeCollector), INITIAL_HP * 25 / 10_000, 1e14);
        _assertOpenRoundSums();
        assertAccounting();
    }

    /// @dev Same shape, relayer-signed (a solver or bundler): a solver that keeps ONE WEI for itself before
    /// delivering the rest keeps the entire killer prize. The README only says "a solver that keeps the BOSS keeps the kill".
    function test_probeA2_solverKeepingOneWei_keepsTheWholeKillPrize() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether);
        a[1] = script.takeBoss(address(script), 1); // one wei to the solver itself
        a[2] = script.takeBoss(alice, type(uint256).max);
        vm.prank(alice, relayer);
        script.run(a);
        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, alice, "FIXED: one wei kept by the solver does not capture the prize");
        assertEq(hook.unclaimedKill(alice), prize);
        assertEq(hook.unclaimedKill(address(script)), 0);
        assertEq(hook.unclaimedKill(relayer), 0);
        assertApproxEqAbs(hook.damage(1, alice), INITIAL_HP, 1e6, "the damage did follow the BOSS");
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== A3. the killing blow does not survive a second hop

    /// @dev Two hops in two SEPARATE transactions. The closed round's credit only travels inside the
    /// transaction that closed it, so a router that custodies the killing blow's BOSS and delivers it in
    /// a LATER transaction keeps the kill (documented limit). The same two hops in ONE transaction, as
    /// the Universal Router does, reach the player: see A4.
    function test_probeA3_killDeliveredInTwoHops_prizeAndDamageStrandedOnTheRouter() public {
        // Contrast first: an ordinary two-hop buy is credited to the user.
        bytes[] memory ok = new bytes[](2);
        ReviewRouter.Action[] memory u0 = new ReviewRouter.Action[](2);
        u0[0] = rr.buy(0.4 ether);
        u0[1] = rr.takeBoss(address(rr), type(uint256).max); // custody
        ok[0] = abi.encodeCall(rr.unlockWith, (u0));
        ok[1] = abi.encodeCall(rr.transferBoss, (bob, type(uint256).max)); // placeholder, replaced below
        uint256 before = boss.balanceOf(address(rr));
        vm.prank(bob, bob);
        rr.unlockWith(u0);
        uint256 got = boss.balanceOf(address(rr)) - before;
        rr.transferBoss(bob, got); // second hop, same tx on chain (two txs here changes nothing: round 1 is open)
        assertEq(hook.damage(1, bob), 0.4 ether, "an ordinary buy: credit travels on the second hop");
        assertEq(hook.damage(1, address(rr)), 0);

        // The kill, two hops in ONE transaction.
        bytes[] memory calls = new bytes[](2);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(2 ether); // kills boss 1 (0.6 left)
        u1[1] = rr.takeBoss(address(rr), type(uint256).max); // TAKE to the router (custody)
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.transferBoss, (alice, 0)); // amount filled by the router's balance below
        uint256 rrBefore = boss.balanceOf(address(rr));
        vm.prank(alice, alice);
        rr.unlockWith(u1);
        uint256 killBoss = boss.balanceOf(address(rr)) - rrBefore;
        // (a separate transaction here, so the closed round's credit no longer travels; A4 does the
        // same two hops in one transaction and the kill reaches alice)
        vm.prank(alice, alice);
        rr.transferBoss(alice, killBoss);

        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(boss.balanceOf(alice) > 0, true, "alice holds the kill's BOSS");
        assertEq(killer, address(rr), "LIMIT: a router delivering in a later transaction keeps the kill");
        assertEq(hook.unclaimedKill(address(rr)), prize, "LIMIT: the prize stays on the router");
        assertEq(hook.unclaimedKill(alice), 0);
        assertEq(hook.damage(1, address(rr)), 0.6 ether, "LIMIT: the killing damage stays on the router");
        assertEq(hook.damage(1, alice), 0);
        assertGt(hook.claimableDamage(1, address(rr)), 0, "LIMIT: anyone can pay the router its share");
        _assertOpenRoundSums();
        assertAccounting();
    }

    /// @dev The same two hops inside ONE transaction (as the Universal Router does): the kill reaches
    /// the player through the router's custody.
    function test_probeA4_killDeliveredInTwoHops_oneTransaction_sameResult() public {
        bytes[] memory calls = new bytes[](2);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(2 ether);
        u1[1] = rr.takeBoss(address(rr), type(uint256).max);
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.transferBoss, (alice, 1_000_000 ether + 1)); // everything the router holds (fixture BOSS + kill)
        vm.prank(alice, alice);
        rr.multi(calls);
        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, alice, "FIXED: the kill follows the BOSS through the router's custody");
        assertEq(hook.unclaimedKill(alice), prize);
        assertEq(hook.unclaimedKill(address(rr)), 0);
        // Since audit 94b6c9a5 (finding 1) the router that executed the kill pays the blow out in proportion to
        // its balance: delivering part of inventory + blow carries that share of the blow.
        uint256 sent = 1_000_000 ether + 1;
        assertApproxEqAbs(hook.damage(1, alice), INITIAL_HP * sent / (sent + boss.balanceOf(address(rr))), 2);
        assertEq(hook.damage(1, alice) + hook.damage(1, address(rr)), INITIAL_HP);
        assertGt(hook.damage(1, alice), hook.damage(1, address(rr)), "most of the blow reached her");
        assertGt(boss.balanceOf(alice), 1_000_000 ether);
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== B. two kills in one transaction: the first stays with the signer

    /// @dev `_kill` overwrites T_KILL_* on the second kill. All the BOSS leaves the pool to alice, yet
    /// round 1's killer prize and killing damage stay with the signer (a relayer here, who can claim them).
    function test_probeB_twoKillsInOneTx_firstKillStaysWithTheRelayer() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether); // kills boss 1 (HP 1)
        a[1] = script.buy(3 ether); // kills boss 2 (HP 1.5)
        a[2] = script.takeBoss(alice, type(uint256).max); // every BOSS of both kills goes to alice
        vm.prank(alice, relayer);
        script.run(a);
        assertEq(hook.round(), 3, "two bosses fell");

        (address k1,, uint256 p1,,) = hook.results(1);
        (address k2,, uint256 p2,,) = hook.results(2);
        assertEq(k2, alice, "round 2 followed the BOSS");
        assertEq(hook.damage(2, alice), 1.5 ether);
        assertEq(k1, relayer, "PROBE: round 1 stayed with the signer although its BOSS went to alice");
        assertEq(hook.damage(1, relayer), INITIAL_HP, "PROBE: and so did its killing damage");
        assertEq(hook.unclaimedKill(relayer), p1, "PROBE: the relayer can claim round 1's prize");
        assertEq(hook.damage(1, alice), 0);
        assertGt(p1, 0);
        assertGt(p2, 0);
        _assertOpenRoundSums();
        assertAccounting();
        // No money is lost or doubled, only misattributed.
        uint256 paid = _claimEverything();
        (,,, uint256 dp1,) = hook.results(1);
        (,,, uint256 dp2,) = hook.results(2);
        assertLe(paid, p1 + p2 + dp1 + dp2);
        assertGe(paid + 4, p1 + p2 + dp1 + dp2, "at most rounding dust stays");
        assertAccounting();
    }

    // =================================================================== C. a bait kill inside the victim's tx cannot drain her

    /// @dev The victim signs; the bait kills with its own IMD and takes the BOSS. The victim's pre-existing
    /// round credit and her older unclaimed prize must be untouched; the bait gets only what it bought.
    function test_probeC_baitKillInsideVictimTx_leavesHerCreditAndOldPrizeAlone() public {
        buyExactIn(alice, 2 ether); // alice kills boss 1 herself: prize p1 waits unclaimed
        uint256 p1 = hook.unclaimedKill(alice);
        assertGt(p1, 0);
        buyExactIn(alice, 0.5 ether); // round 2 (HP 1.5): alice holds 0.5 of damage
        assertEq(hook.damage(2, alice), 0.5 ether);

        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](2);
        a[0] = script.buy(3 ether); // the bait kills boss 2 inside alice's transaction
        a[1] = script.takeBoss(bob, type(uint256).max); // and sends the BOSS to its owner
        vm.prank(alice, alice);
        script.run(a);

        (address killer,, uint256 p2,, uint256 elig) = hook.results(2);
        assertEq(killer, bob);
        assertEq(hook.damage(2, alice), 0.5 ether, "the victim's own credit is intact");
        assertEq(hook.damage(2, bob), 1 ether, "the bait's owner got exactly the killing blow");
        assertEq(hook.unclaimedKill(alice), p1, "the victim's older prize is intact");
        assertEq(hook.unclaimedKill(bob), p2);
        assertEq(elig, 1.5 ether);
        assertEq(hook.damage(1, alice), INITIAL_HP, "closed round 1 untouched");
        _assertOpenRoundSums();
        (,,, uint256 dp2,) = hook.results(2);
        assertLe(_sumClaimable(2), dp2);
        assertGe(_sumClaimable(2) + 2, dp2);
        assertAccounting();
    }

    // =================================================================== D. claims between unlocks: no double pay, no underflow

    function test_probeD1_claimKillBetweenUnlocks_prizeStaysAndIsPaidOnce() public {
        bytes[] memory calls = new bytes[](3);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(2 ether);
        u1[1] = rr.takeBossAsClaims(type(uint256).max);
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](1);
        u2[0] = rr.claimsToBoss(bob, type(uint256).max);
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.claimKill, (alice));
        calls[2] = abi.encodeCall(rr.unlockWith, (u2));
        uint256 before = _quoteBalance(alice);
        vm.prank(alice, alice);
        rr.multi(calls);

        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(_quoteBalance(alice) - before, prize, "alice was paid the prize once");
        assertEq(killer, alice, "a paid prize does not move");
        assertEq(hook.unclaimedKill(bob), 0);
        assertEq(hook.unclaimedKill(alice), 0);
        assertEq(hook.damage(1, bob), INITIAL_HP, "the unclaimed damage did move with the BOSS");
        assertEq(hook.damage(1, alice), 0);
        _assertOpenRoundSums();
        assertAccounting();
        vm.expectRevert(BossHook.NothingToClaim.selector);
        hook.claimKill(bob);
    }

    function test_probeD2_claimDamageBetweenUnlocks_damageStaysButPrizeMoves() public {
        bytes[] memory calls = new bytes[](3);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(2 ether);
        u1[1] = rr.takeBossAsClaims(type(uint256).max);
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](1);
        u2[0] = rr.claimsToBoss(bob, type(uint256).max);
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.claimDamage, (1, alice));
        calls[2] = abi.encodeCall(rr.unlockWith, (u2));
        vm.prank(alice, alice);
        rr.multi(calls);

        (address killer,, uint256 prize, uint256 dp,) = hook.results(1);
        assertEq(hook.damage(1, alice), INITIAL_HP, "claimed credit stays recorded");
        assertEq(hook.damage(1, bob), 0, "claimed credit does not move");
        assertEq(hook.claimableDamage(1, bob), 0);
        assertEq(killer, bob, "the unclaimed prize does move with the first BOSS out");
        assertEq(hook.unclaimedKill(bob), prize);
        assertEq(hook.unclaimedKill(alice), 0);
        assertEq(hook.totalReserved(), prize, "alice collected the whole damage pool: only the prize is still reserved");
        assertGt(dp, 0);
        _assertOpenRoundSums();
        assertAccounting();
    }

    /// @dev Partial take to a third party, a claim by the signer in between, then the rest to another wallet:
    /// the hunted `damage[kr][signer] -= dmg` never underflows and the sums close.
    function test_probeD3_partialTakes_claimInBetween_noUnderflowSumsClose() public {
        buyExactIn(alice, 0.3 ether); // alice already holds round-1 credit before she signs the kill
        bytes[] memory calls = new bytes[](3);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](3);
        u1[0] = rr.buy(2 ether); // kills: 0.7 of killing damage credited to alice (signer)
        u1[1] = rr.takeBossShare(bob, 1, 3); // a third of the kill's BOSS to bob
        u1[2] = rr.takeBossAsClaims(type(uint256).max); // the rest waits as claims
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](1);
        u2[0] = rr.claimsToBoss(carol, type(uint256).max); // after alice claimed: carol gets BOSS, no credit
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.claimDamage, (1, alice));
        calls[2] = abi.encodeCall(rr.unlockWith, (u2));
        vm.prank(alice, alice);
        rr.multi(calls);

        (address killer,, uint256 prize, uint256 dp, uint256 elig) = hook.results(1);
        assertEq(elig, INITIAL_HP);
        assertEq(killer, carol, "the prize follows the largest share of the kill's BOSS: carol's two thirds");
        assertEq(hook.unclaimedKill(carol), prize);
        assertEq(hook.unclaimedKill(bob), 0);
        assertApproxEqAbs(hook.damage(1, bob), uint256(0.7 ether) / 3, 1);
        assertApproxEqAbs(hook.damage(1, alice), 0.3 ether + 0.7 ether - uint256(0.7 ether) / 3, 1);
        assertEq(hook.damage(1, carol), 0, "credit already paid to alice did not follow carol's BOSS");
        assertEq(_sumDamage(1), elig);
        assertTrue(hook.damageClaimed(1, alice));
        assertEq(hook.claimableDamage(1, alice), 0);
        uint256 paidBob;
        {
            uint256 b = _quoteBalance(bob);
            hook.claimDamage(1, bob);
            paidBob = _quoteBalance(bob) - b;
        }
        assertLe(paidBob + dp * hook.damage(1, alice) / elig, dp, "never more than the pool");
        assertAccounting();
    }

    /// @dev The victim signs a bait that kills, then the victim's OWN wallet-to-wallet transfers run in the
    /// same transaction, then the kill's BOSS arrives late. Nothing reverts (no underflow) and sums close.
    function test_probeD4_lateArrivalAfterSignerTransfers_noRevert() public {
        buyExactIn(alice, 0.3 ether);
        uint256 got = boss.balanceOf(alice);
        bytes[] memory calls = new bytes[](4);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(2 ether); // kill, credited to alice (signer)
        u1[1] = rr.takeBossAsClaims(type(uint256).max);
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](1);
        u2[0] = rr.claimsToBoss(bob, type(uint256).max);
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.transferBossFrom, (alice, carol, got)); // alice's old BOSS leaves (round 2 now)
        calls[2] = abi.encodeCall(rr.transferBossFrom, (carol, alice, got / 2));
        calls[3] = abi.encodeCall(rr.unlockWith, (u2)); // the kill's BOSS finally leaves the pool, to bob
        vm.prank(alice, alice);
        rr.multi(calls);
        // Since audit 853ff4df (finding 1) a closed round is frozen except for the killing blow: alice's
        // own round-1 BOSS leaves without its 0.3, which stays with her; the killing blow waited for its BOSS.
        assertEq(hook.damage(1, carol), 0, "carol gets alice's old BOSS, not its closed-round credit");
        assertEq(hook.damage(1, alice), 0.3 ether, "alice keeps her 0.3, none of the killing blow");
        assertEq(hook.damage(1, bob), 0.7 ether, "bob got the killing blow");
        assertEq(hook.damage(2, carol) + hook.damage(2, alice), 0, "round-2 transfers moved nothing");
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== G. pending credit is NOT voided by claims: any later take in the tx collects it

    /// @dev Design doc: "si el BOSS nunca sale (claims ...), el crédito pendiente se evapora". Code: it waits
    /// in transient storage for the next BOSS that leaves the pool in the same transaction, from any source.
    /// Here LP BOSS taken by a second unlock collects a buy's credit. Self-inflicted, but the claim is wrong.
    function test_probeG_pendingCreditRidesOnLpBossTakenLaterInTheSameTx() public {
        bytes[] memory calls = new bytes[](2);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(0.5 ether);
        u1[1] = rr.takeBossAsClaims(type(uint256).max); // the buy's BOSS never leaves
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](2);
        u2[0] = rr.removeLiquidity(RR_LIQ); // BOSS that was never bought
        u2[1] = rr.takeBoss(bob, type(uint256).max);
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.unlockWith, (u2));
        vm.prank(alice, alice);
        rr.multi(calls);
        assertEq(hook.damage(1, bob), 0.5 ether, "PROBE: LP BOSS collected the buy's pending credit");
        assertGt(hook.bought(1, bob), 0);
        assertEq(hook.eligibleDamage(1), 0.5 ether);
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== H. selling anywhere but the PoolManager moves the credit instead of forfeiting it

    function test_probeH_sellOnAnotherVenue_creditMovesToTheVenueAndToItsBuyers() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        buyExactIn(carol, 0.25 ether);
        vm.prank(alice);
        boss.transfer(venue, got); // "selling" on a v3 pool / depositing on a CEX
        assertEq(hook.damage(1, alice), 0);
        assertEq(hook.damage(1, venue), 0.5 ether, "PROBE: the venue holds alice's credit");
        assertEq(hook.eligibleDamage(1), 0.75 ether, "PROBE: nothing was forfeited, carol is not favoured");
        vm.prank(venue);
        boss.transfer(bob, got / 2); // bob "buys" from the venue: inherits half the credit without hitting the boss
        assertApproxEqAbs(hook.damage(1, bob), 0.25 ether, 1, "PROBE: bob inherited credit he never dealt");
        buyExactIn(carol, 2 ether); // kill
        assertGt(hook.claimableDamage(1, venue), 0, "PROBE: anyone can pay the venue contract its share");
        assertGt(hook.claimableDamage(1, bob), 0);
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== I. the kill's BOSS kept as claims absorbs the next take of the same signer

    /// @dev One transaction: kill (BOSS kept as claims), then a fresh buy in round 2 taken by the signer.
    /// `_arrive` spends the whole take on the kill slice (to == signer, nothing moves) and returns before
    /// the round-2 pending credit: that credit is lost, nobody is diluted. A fungibility limit, undocumented.
    function test_probeI_killKeptAsClaims_swallowsTheSignersNextBuyCredit() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](4);
        a[0] = script.buy(2 ether); // kills boss 1
        a[1] = script.takeBossAsClaims(type(uint256).max); // its BOSS stays in the pool as claims
        a[2] = script.buy(0.4 ether); // hits boss 2 for 0.4
        a[3] = script.takeBoss(alice, type(uint256).max); // only the round-2 BOSS leaves, to the signer
        vm.prank(alice, alice);
        script.run(a);
        assertEq(hook.hp(), 1.5 ether - 0.4 ether, "boss 2 was hit for 0.4");
        assertEq(hook.damage(2, alice), 0, "PROBE: the 0.4 of round-2 damage was never credited to anyone");
        assertEq(hook.eligibleDamage(2), 0);
        assertEq(hook.damage(1, alice), INITIAL_HP, "the kill stayed with the signer");
        assertGt(boss.balanceOf(alice), 0);
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== L. onBossTransfer never reverts, in every shape we could think of

    function test_probeL_transfersNeverRevert_allShapes() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        buyExactIn(bob, 0.25 ether);
        address pm = address(manager);

        vm.prank(alice);
        boss.transfer(bob, 1); // dust with credit
        vm.prank(alice);
        boss.transfer(alice, got / 10); // from == to
        vm.prank(alice);
        boss.transfer(bob, 0); // zero value
        vm.prank(alice);
        boss.transfer(address(hook), 1); // to the hook itself
        vm.prank(alice);
        boss.transfer(pm, 1); // straight into the PoolManager: forfeits a dust share, BOSS is lost
        vm.prank(alice);
        boss.approve(carol, type(uint256).max);
        vm.prank(carol);
        boss.transferFrom(alice, carol, 1); // an operator moves it
        vm.prank(carol);
        boss.transferFrom(alice, pm, 1); // an operator hands it to the pool
        sellExactIn(alice, 1); // a one-wei sell
        sellExactOut(alice, 0.0001 ether); // an exact-out sell
        boss.transfer(pm, 1 ether); // the deployer (no credit) hands BOSS to the pool: nothing to release
        boss.transfer(address(hook), 1 ether);
        giveBoss(carol, 1_000 ether);
        sellExactIn(carol, 1_000 ether); // sells without any buy this round
        uint256 aliceLeft = boss.balanceOf(alice);
        vm.prank(alice);
        boss.transfer(bob, aliceLeft); // everything left, credit and all
        sellExactIn(bob, boss.balanceOf(bob)); // bob dumps it all: both credits gone
        assertEq(hook.damage(1, alice) + hook.damage(1, bob), 0);
        buyExactIn(carol, 2 ether); // carol kills; round 2
        sellExactIn(carol, boss.balanceOf(carol) / 2); // sells after the kill (round 2, no credit there)
        uint256 carolLeft = boss.balanceOf(carol);
        vm.prank(carol);
        boss.transfer(alice, carolLeft); // moves closed-round BOSS: nothing to move in round 2
        (,,,, uint256 elig1) = hook.results(1);
        assertEq(
            hook.damage(1, carol),
            elig1,
            "closed round keeps the kill (the boss had been healed: the blow is what was left)"
        );
        assertGt(elig1, 0);
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== M. after every move, the pools are paid at most once

    function test_probeM_payoutsNeverExceedThePools_afterMoves() public {
        test_probeA_killPrize_goesToTheFirstDustTaker_notToTheBossRecipient();
        buyExactIn(bob, 0.4 ether); // round 2 activity, some pot for round 2
        buyExactIn(carol, 3 ether); // kills boss 2 (HP 1.5)
        (,, uint256 p1, uint256 dp1,) = hook.results(1);
        (,, uint256 p2, uint256 dp2,) = hook.results(2);
        uint256 paid = _claimEverything();
        assertLe(paid, p1 + dp1 + p2 + dp2);
        assertGe(paid + 8, p1 + dp1 + p2 + dp2, "only rounding dust stays reserved");
        assertEq(hook.totalReserved(), p1 + dp1 + p2 + dp2 - paid);
        assertAccounting();
    }

    // =================================================================== N. credit moved to a wallet that already claimed is stranded (not doubled)

    function test_probeN_killCreditMovedToAnAlreadyPaidWallet_isStrandedNotDoubled() public {
        buyExactIn(bob, 0.3 ether); // bob holds round-1 credit
        bytes[] memory calls = new bytes[](3);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(2 ether); // relayer-signed kill: 0.7 credited to the relayer for now
        u1[1] = rr.takeBossAsClaims(type(uint256).max);
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](1);
        u2[0] = rr.claimsToBoss(bob, type(uint256).max);
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.claimDamage, (1, bob)); // bob is paid his 0.3 share first
        calls[2] = abi.encodeCall(rr.unlockWith, (u2)); // then the kill's 0.7 moves to bob, who already claimed
        vm.prank(alice, relayer);
        rr.multi(calls);
        (,,, uint256 dp, uint256 elig) = hook.results(1);
        assertEq(hook.damage(1, bob), 1 ether);
        assertEq(hook.claimableDamage(1, bob), 0, "already claimed: the moved 0.7 can never be paid");
        assertEq(hook.claimableDamage(1, relayer), 0);
        assertEq(_sumClaimable(1), 0);
        assertApproxEqAbs(
            hook.totalReserved() - hook.unclaimedKill(bob), dp * 0.7 ether / elig, 2, "0.7/1.0 of the pool is stuck"
        );
        assertAccounting();
    }

    // =================================================================== Q. a flash take to a stranger: gift, never harm

    function test_probeQ_flashTakeToStranger_onlyGiftsPendingCredit_attackerPays() public {
        buyExactIn(bob, 0.25 ether);
        uint256 bobBought = hook.bought(1, bob);
        ReviewRouter.Action[] memory u = new ReviewRouter.Action[](2);
        u[0] = rr.buy(0.1 ether); // attacker's small buy: pending (0.1, pb)
        u[1] = rr.flashTakeBoss(bob, 100_000 ether); // a take larger than the buy's BOSS, repaid by the router at the end
        uint256 rrBefore = boss.balanceOf(address(rr));
        vm.prank(carol, carol);
        rr.unlockWith(u);
        assertEq(hook.damage(1, bob), 0.35 ether, "bob was gifted the attacker's credit");
        assertLe(hook.bought(1, bob), boss.balanceOf(bob));
        assertGt(hook.bought(1, bob), bobBought);
        assertLt(boss.balanceOf(address(rr)), rrBefore, "the attacker paid the BOSS it gave away");
        assertEq(hook.damage(1, address(rr)), 0);
        _assertOpenRoundSums();
        assertAccounting();
    }
}

contract ReviewFollowBossBossFirstTest is ReviewFollowBossBase {}

contract ReviewFollowBossBossSecondTest is ReviewFollowBossBase {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
