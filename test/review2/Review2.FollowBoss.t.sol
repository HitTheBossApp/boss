// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {ReviewBase} from "../review/ReviewBase.sol";
import {ReviewRouter} from "../review/ReviewRouter.sol";
import {ScriptRouter} from "../utils/ScriptRouter.sol";
import {BossHook} from "../../src/BossHook.sol";

/// @dev Second independent review, on commit 1049a09 (the fix of C1 / I1). Every probe states what the
/// design claims (docs/fix-follow-boss.md 3.2 / 3.3, README "Known limits") in its final assertions;
/// a FAIL therefore documents a gap between the claim and the code, a PASS confirms the claim.
/// Runs in both currency orderings.
abstract contract Review2Base is ReviewBase {
    uint256 internal constant FLASH = 50_000_000 ether; // well above any killing blow's BOSS, well below the pool's

    function _killer(uint64 r) internal view returns (address k) {
        (k,,,,) = hook.results(r);
    }

    function _prize(uint64 r) internal view returns (uint256 p) {
        (,, p,,) = hook.results(r);
    }

    function _pool(uint64 r) internal view returns (uint256 dp) {
        (,,, dp,) = hook.results(r);
    }

    // =================================================================== P1. `_trackKill` counts ANY closed-round BOSS hop as kill BOSS

    /// @dev A shared 4337 bundle, or a relayer's own op appended after the user's: alice's op kills and
    /// takes the whole killing blow's BOSS; afterwards, in the same transaction, an UNRELATED transfer
    /// of BOSS bought earlier in the same round (bob -> carol, more BOSS than the blow) runs.
    /// `onBossTransfer` releases bob's closed-round credit and feeds its size to `_trackKill`, so carol
    /// "holds more of the kill's BOSS" than alice and takes the prize, although carol never touched it.
    function test_r2_P1_olderRoundBossHoppedInsideTheKillTx_takesThePrizeFromTheKiller() public {
        buyExactIn(bob, 0.8 ether); // bob bought early and cheap: lots of round-1 BOSS; 0.2 HP left
        uint256 bobBoss = boss.balanceOf(bob);
        bytes[] memory calls = new bytes[](2);
        ReviewRouter.Action[] memory u = new ReviewRouter.Action[](2);
        u[0] = rr.buy(0.5 ether); // alice's killing blow (0.2 of damage)
        u[1] = rr.takeBoss(alice, type(uint256).max); // all of the blow's BOSS to alice
        calls[0] = abi.encodeCall(rr.unlockWith, (u));
        calls[1] = abi.encodeCall(rr.transferBossFromPct, (bob, carol, 100)); // bob's own op, same bundle
        vm.prank(alice, relayer);
        rr.multi(calls);

        uint256 pb = hook.bought(1, alice);
        assertGt(bobBoss, pb, "bob's round-1 BOSS exceeds the killing blow's");
        assertEq(hook.damage(1, alice), 0.2 ether, "alice holds the whole killing blow");
        // Since audit 853ff4df finding 1: a closed round is frozen except for the killing blow.
        assertEq(hook.damage(1, carol), 0, "bob's closed-round credit stays with bob");
        assertEq(hook.damage(1, bob), 0.8 ether);
        _assertOpenRoundSums();
        assertAccounting();
        console2.log("P1 killer:", _killer(1));
        console2.log("P1 alice / carol:", alice, carol);
        assertEq(_killer(1), alice, "DESIGN: the prize follows the largest share of the KILL's BOSS (alice: 100%)");
        assertEq(hook.unclaimedKill(alice), _prize(1));
        assertEq(hook.unclaimedKill(carol), 0);
    }

    /// @dev The same conflation inside the signer's own transaction, in probe D4's shape: alice moves her
    /// OLD round-1 BOSS to carol while the blow's BOSS waits as claims, then the blow's BOSS (all of it)
    /// goes to bob. carol, who holds none of the kill's BOSS, ends up with the prize.
    function test_r2_P1b_signersOwnOldBossHop_outvotesTheWalletHoldingTheWholeBlow() public {
        buyExactIn(alice, 0.9 ether); // 0.1 HP left; alice's early BOSS is the big position
        uint256 got = boss.balanceOf(alice);
        bytes[] memory calls = new bytes[](3);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(0.3 ether); // the kill: 0.1 of damage
        u1[1] = rr.takeBossAsClaims(type(uint256).max);
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](1);
        u2[0] = rr.claimsToBoss(bob, type(uint256).max);
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.transferBossFrom, (alice, carol, got)); // her old BOSS, in the middle
        calls[2] = abi.encodeCall(rr.unlockWith, (u2)); // the blow's BOSS arrives, all of it, for bob
        vm.prank(alice, alice);
        rr.multi(calls);

        assertEq(hook.damage(1, bob), 0.1 ether, "bob holds the whole killing blow");
        // Since audit 853ff4df finding 1: a closed round is frozen except for the killing blow.
        assertEq(hook.damage(1, carol), 0, "carol gets alice's old BOSS, not its credit");
        assertEq(hook.damage(1, alice), 0.9 ether, "alice keeps her old credit");
        assertGt(got, hook.bought(1, bob), "the old position is larger than the blow");
        _assertOpenRoundSums();
        assertAccounting();
        console2.log("P1b killer:", _killer(1));
        console2.log("P1b bob / carol:", bob, carol);
        assertEq(_killer(1), bob, "DESIGN: the prize follows the kill's BOSS, all of it in bob's hands");
    }

    // =================================================================== P2. a flash take inside the kill tx takes prize and damage for free

    /// @dev Design: "la ida y vuelta con flash no mueve tokens y no toca a nadie"; README: "what never
    /// leaves the pool in that transaction (claims, a flash round trip) stays with the signer". A
    /// solver, aggregator or bait that executes alice's kill borrows BOSS from the pool into its own
    /// wallet (carol), returns it at once and only then hands alice her BOSS: `_arrive` moved the whole
    /// killing credit and the prize to carol, and the return to the pool releases nothing (a closed
    /// round is never forfeited). alice gets her BOSS with no credit; carol holds no BOSS.
    function test_r2_P2_flashTakeByAThirdWalletInsideTheKillTx_takesPrizeAndDamageForFree() public {
        ReviewRouter.Action[] memory u = new ReviewRouter.Action[](4);
        u[0] = rr.buy(2 ether); // alice's kill, paid by the executor on her behalf
        u[1] = rr.flashTakeBoss(carol, FLASH); // the executor's wallet borrows BOSS from the pool
        u[2] = rr.settleBossFrom(carol, FLASH); // and returns it at once
        u[3] = rr.takeBoss(alice, type(uint256).max); // alice gets the blow's BOSS
        vm.prank(alice, alice);
        rr.unlockWith(u);

        assertEq(boss.balanceOf(carol), 0, "carol holds no BOSS");
        assertGt(boss.balanceOf(alice), 0, "alice got the blow's BOSS");
        _assertOpenRoundSums();
        assertAccounting();
        console2.log("P2 killer:", _killer(1));
        console2.log("P2 damage alice / carol:", hook.damage(1, alice), hook.damage(1, carol));
        // Documented limit (README "Known limits"): whoever EXECUTES the killing swap can keep the
        // kill, here with a flash take returned before the signer's BOSS leaves the pool. Routers
        // you trust (the Uniswap app, the explorer) do not; a solver or a contract you hand the
        // trade to could.
        assertEq(hook.damage(1, carol), INITIAL_HP, "LIMIT: the executor's wallet took the blow's damage");
        assertEq(hook.damage(1, alice), 0, "LIMIT: the signer got her BOSS without the blow's credit");
        assertEq(_killer(1), carol, "LIMIT: and the prize");
    }

    // =================================================================== P3. the executor collects the prize between unlocks

    /// @dev The signer is a relayer / solver. It kills for alice, keeps the BOSS as claims, calls
    /// `claimKill(relayer)` (anyone may) and only then turns the claims into BOSS for alice. The
    /// damage follows the BOSS; the prize was paid to the relayer and never moves. The README words
    /// this as "what the signer already collected is not paid twice", assuming the signer is the player.
    function test_r2_P3_relayerClaimsThePrizeBetweenUnlocks_keepsIt() public {
        bytes[] memory calls = new bytes[](3);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(2 ether);
        u1[1] = rr.takeBossAsClaims(type(uint256).max);
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](1);
        u2[0] = rr.claimsToBoss(alice, type(uint256).max);
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.claimKill, (relayer));
        calls[2] = abi.encodeCall(rr.unlockWith, (u2));
        uint256 before = _quoteBalance(relayer);
        vm.prank(alice, relayer);
        rr.multi(calls);

        assertEq(hook.damage(1, alice), INITIAL_HP, "the damage reached alice");
        assertEq(_quoteBalance(relayer) - before, _prize(1), "LIMIT: the relayer was paid alice's prize");
        assertEq(hook.unclaimedKill(alice), 0);
        assertEq(_killer(1), relayer);
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== P4. the signer's exclusion: exact numbers

    /// @dev Pre-kill credit, a partial arrival to her, a partial arrival to bob, her own hop of everything
    /// she holds, the rest through a router and back to her. Checks `_releaseClosed` moves exactly what
    /// she holds (pre-kill BOSS + what arrived), never the part still in the pool, and that nothing reverts.
    function test_r2_P4_signerExclusion_exactWithPreKillCreditPartialArrivalsAndHerHop() public {
        buyExactIn(alice, 0.3 ether);
        uint256 b0 = boss.balanceOf(alice);
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](6);
        a[0] = script.buy(2 ether); // kill: 0.7 of damage, credited to alice (signer) for now
        a[1] = script.takeBossShare(alice, 1, 4); // a quarter of the blow's BOSS to her
        a[2] = script.takeBossShare(bob, 1, 3); // a third of what is left (another quarter) to bob
        a[3] = script.pullFrom(alice, carol, type(uint256).max); // she hands carol everything she holds
        a[4] = script.takeBoss(address(script), type(uint256).max); // the remaining half to the router
        a[5] = script.forward(alice, type(uint256).max); // and on to her
        vm.prank(alice, alice);
        script.run(a);

        // Since audit 853ff4df finding 1: a closed round is frozen except for the killing blow: her pre-kill 0.3 stays with her when she hands carol everything she holds; only
        // the quarter of the blow she held travels (her wallet spends older BOSS first, so all of the blow
        // she held is what left: nothing else remained). The router that executed the kill delivers its half.
        uint256 pb = (hook.bought(1, alice) - b0) + hook.bought(1, bob) + hook.bought(1, carol);
        assertApproxEqAbs(boss.balanceOf(alice), pb / 2, 2, "alice: the half that came through the router");
        assertApproxEqAbs(hook.bought(1, bob), pb / 4, 2);
        assertApproxEqAbs(hook.bought(1, carol), pb / 4, 2, "carol: the quarter of the blow alice held");
        assertApproxEqAbs(hook.damage(1, alice), 0.3 ether + 0.35 ether, 1e6, "her pre-kill credit plus the router's half");
        assertApproxEqAbs(hook.damage(1, bob), 0.175 ether, 1e6);
        assertApproxEqAbs(hook.damage(1, carol), 0.175 ether, 1e6);
        assertEq(hook.damage(1, address(script)) + hook.bought(1, address(script)), 0);
        assertEq(hook.damage(1, alice) + hook.damage(1, bob) + hook.damage(1, carol), INITIAL_HP);
        assertEq(hook.eligibleDamage(1), INITIAL_HP);
        console2.log("P4 killer:", _killer(1));
        console2.log("P4 alice / carol:", alice, carol);
        assertAccounting();
    }

    // =================================================================== P5. two kills in one transaction: held counts are keyed per round

    function test_r2_P5_twoKillsInOneTx_eachPrizeFollowsItsOwnBoss() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](5);
        a[0] = script.buy(2 ether); // kills boss 1
        a[1] = script.takeBoss(alice, type(uint256).max); // its BOSS to alice
        a[2] = script.buy(3 ether); // kills boss 2 (HP 1.5)
        a[3] = script.takeBoss(address(script), type(uint256).max); // its BOSS custodied by the router
        a[4] = script.forward(bob, type(uint256).max); // and delivered to bob
        vm.prank(alice, relayer);
        script.run(a);

        assertEq(hook.round(), 3);
        assertEq(_killer(1), alice, "round 1 followed its BOSS");
        assertEq(_killer(2), bob, "round 2 followed its BOSS through the router");
        assertEq(hook.damage(1, alice), INITIAL_HP);
        assertEq(hook.damage(2, bob), 1.5 ether);
        assertEq(hook.damage(1, address(script)) + hook.damage(2, address(script)), 0);
        assertEq(hook.damage(1, relayer) + hook.damage(2, relayer), 0);
        assertEq(hook.unclaimedKill(alice), _prize(1));
        assertEq(hook.unclaimedKill(bob), _prize(2));
        assertEq(hook.unclaimedKill(relayer), 0);
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== P6. a prize claimed mid-transaction never moves nor doubles

    function test_r2_P6_prizeClaimedByTheRouterMidTx_laterHopMovesDamageOnly_paidOnce() public {
        bytes[] memory calls = new bytes[](3);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(2 ether);
        u1[1] = rr.takeBoss(address(rr), type(uint256).max); // prize -> router
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.claimKill, (address(rr))); // the router cashes it
        calls[2] = abi.encodeCall(rr.transferBoss, (alice, 1_000_000 ether + 1)); // then delivers (inventory + blow)
        uint256 before = _quoteBalance(address(rr));
        vm.prank(alice, alice);
        rr.multi(calls);

        // The router spent exactly 2 IMD on the buy and received the prize.
        assertEq(_quoteBalance(address(rr)) + 2 ether - before, _prize(1), "the router was paid once");
        assertEq(_killer(1), address(rr), "a paid prize does not move");
        assertEq(hook.unclaimedKill(alice), 0);
        assertEq(hook.unclaimedKill(address(rr)), 0);
        // Since audit 94b6c9a5 (finding 1) the router that executed the kill pays the blow out in proportion to
        // its balance: delivering part of inventory + blow carries that share of the blow.
        uint256 sent = 1_000_000 ether + 1;
        assertApproxEqAbs(
            hook.damage(1, alice), INITIAL_HP * sent / (sent + boss.balanceOf(address(rr))), 2, "the damage did move"
        );
        _assertOpenRoundSums();
        assertAccounting();
        uint256 paid = _claimEverything();
        // The damage pool is now split between alice and the router (proportional custody, audit 94b6c9a5):
        // each share rounds down, so a wei of dust can stay (README: rounding dust stays in the hook).
        assertApproxEqAbs(paid, _pool(1), 2, "only the damage pool was left to pay");
        assertLe(hook.totalReserved(), 2);
        assertAccounting();
    }

    // =================================================================== P7. stale closed-round counts after the signer sells post-kill

    /// @dev `bought[kr]` is frozen at the kill. The signer sells her pre-kill BOSS right after the kill,
    /// before the blow's BOSS leaves the pool; then it leaves, to bob. The late arrival must not
    /// underflow her counts, bob gets exactly the blow, and the stale count only affects her own wallet.
    function test_r2_P7_signerSellsAfterTheKillBeforeArrival_noUnderflow_staleCountHarmsOnlyHer() public {
        buyExactIn(alice, 0.3 ether);
        uint256 b0 = boss.balanceOf(alice);
        bytes[] memory calls = new bytes[](5);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(2 ether); // kill: 0.7
        u1[1] = rr.takeBossAsClaims(type(uint256).max);
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](1);
        u2[0] = rr.sellPctFrom(alice, 100); // she dumps her old BOSS in round 2: no forfeit anywhere
        ReviewRouter.Action[] memory u3 = new ReviewRouter.Action[](1);
        u3[0] = rr.claimsToBoss(bob, type(uint256).max); // the blow arrives late, for bob
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.unlockWith, (u2));
        calls[2] = abi.encodeCall(rr.unlockWith, (u3));
        calls[3] = abi.encodeCall(rr.transferBoss, (alice, b0)); // uncredited inventory lands on her
        calls[4] = abi.encodeCall(rr.transferBossFrom, (alice, carol, b0)); // and she hops it: stale credit travels
        vm.prank(alice, alice);
        rr.multi(calls);

        assertEq(boss.balanceOf(alice), 0);
        assertEq(hook.damage(1, bob), 0.7 ether, "bob got exactly the killing blow");
        // Since audit 853ff4df finding 1: a closed round is frozen except for the killing blow: uncredited BOSS hopped later carries nothing.
        assertEq(hook.damage(1, carol), 0, "her stale pre-kill credit no longer travels with uncredited BOSS");
        assertEq(hook.damage(1, alice), 0.3 ether);
        assertEq(hook.bought(1, carol), 0);
        assertEq(hook.damage(2, alice) + hook.damage(2, carol) + hook.damage(2, bob), 0);
        _assertOpenRoundSums();
        assertAccounting();
        console2.log("P7 killer:", _killer(1));
        console2.log("P7 bob / carol:", bob, carol);
    }

    // =================================================================== P8. an equal split: the tie goes to the last receiver

    function test_r2_P8_routerSplitsTheBlowInHalves_tieGoesToTheLastReceiver() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](4);
        a[0] = script.buy(2 ether);
        a[1] = script.takeBoss(address(script), type(uint256).max);
        a[2] = script.forwardShare(bob, 1, 2); // half to bob: not strictly more than the router's half
        a[3] = script.forward(carol, type(uint256).max); // the other half to carol: more than the router's zero
        vm.prank(alice, alice);
        script.run(a);
        assertEq(hook.bought(1, bob) + 1 >= hook.bought(1, carol), true);
        // Since audit 94b6c9a5 (review 7) the router stops counting for the prize once it pays out, so the
        // first half's receiver takes it, and an equal second half does not take it away (ties stay put).
        assertEq(_killer(1), bob, "the first of two equal halves keeps the prize");
        assertEq(hook.unclaimedKill(address(script)), 0, "the router keeps nothing");
        assertApproxEqAbs(hook.damage(1, bob), 0.5 ether, 2);
        assertApproxEqAbs(hook.damage(1, carol), 0.5 ether, 2);
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== P9. an older prize on the relayer stays with the relayer

    function test_r2_P9_relayerWithAnOlderPrize_arrivalMovesOnlyThisRoundsPrize() public {
        _fund(relayer);
        buyExactIn(relayer, 2 ether); // the relayer kills boss 1 in its own transaction
        uint256 p1 = hook.unclaimedKill(relayer);
        assertGt(p1, 0);
        ReviewRouter.Action[] memory u = new ReviewRouter.Action[](2);
        u[0] = rr.buy(3 ether); // alice's kill of boss 2 (HP 1.5), relayer-signed
        u[1] = rr.takeBoss(alice, type(uint256).max);
        vm.prank(alice, relayer);
        rr.unlockWith(u);
        assertEq(_killer(2), alice);
        assertEq(hook.unclaimedKill(alice), _prize(2), "exactly round 2's prize moved");
        assertEq(hook.unclaimedKill(relayer), p1, "the relayer keeps its own older prize");
        assertEq(hook.damage(2, alice), 1.5 ether);
        assertEq(hook.damage(2, relayer), 0);
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== P10. kill BOSS forwarded to the hook: the prize strands raw IMD in the hook

    function test_r2_P10_blowForwardedToTheHook_prizeClaimStrandsRawImdInTheHook() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether);
        a[1] = script.takeBoss(address(script), type(uint256).max);
        a[2] = script.forward(address(hook), type(uint256).max);
        vm.prank(alice, alice);
        script.run(a);
        assertEq(
            _killer(1),
            address(script),
            "FIXED: the hook never becomes the killer; the prize stays with the last holder"
        );
        vm.expectRevert(abi.encodeWithSignature("NothingToClaim()"));
        hook.claimKill(address(hook));
        assertEq(quoteToken.balanceOf(address(hook)), 0, "no raw IMD can be stranded in the hook this way");
        assertEq(hook.totalReserved(), _pool(1) + _prize(1));
    }

    // =================================================================== P11. a battery of hops inside the kill transaction: no revert, sums close, no overpay

    function test_r2_P11_killTxHopBattery_neverReverts_sumsClose_paysAtMostOnce() public {
        buyExactIn(alice, 0.3 ether);
        address pm = address(manager);
        bytes[] memory calls = new bytes[](9);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](4);
        u1[0] = rr.buy(2 ether); // kill: 0.7
        u1[1] = rr.takeBossShare(alice, 1, 2); // half to her
        u1[2] = rr.takeBossShare(bob, 1, 2); // a quarter to bob
        u1[3] = rr.takeBossAsClaims(type(uint256).max); // a quarter waits
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](1);
        u2[0] = rr.claimsToBoss(carol, type(uint256).max);
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.transferBossFrom, (alice, carol, 1)); // a dust hop by the signer
        calls[2] = abi.encodeCall(rr.transferBossFrom, (alice, pm, 1)); // a wei straight into the PoolManager, outside any unlock
        calls[3] = abi.encodeCall(rr.transferBossFrom, (bob, alice, 1)); // a hop INTO the signer
        calls[4] = abi.encodeCall(rr.claimDamage, (1, alice)); // she claims her damage mid-transaction
        calls[5] = abi.encodeCall(rr.transferBossFrom, (alice, bob, 5)); // her hops now move nothing (claimed)
        calls[6] = abi.encodeCall(rr.unlockWith, (u2)); // the late arrival after her claim
        calls[7] = abi.encodeCall(rr.transferBossFrom, (carol, alice, 1)); // carol's dust back to her
        calls[8] = abi.encodeCall(rr.transferBossFromPct, (bob, carol, 100)); // bob hands everything to carol
        uint256 aliceBefore = _quoteBalance(alice);
        vm.prank(alice, alice);
        rr.multi(calls);
        uint256 paidInTx = _quoteBalance(alice) - aliceBefore;
        assertGt(paidInTx, 0);

        _assertOpenRoundSums();
        assertAccounting();
        assertTrue(hook.damageClaimed(1, alice));
        // alice: 0.3 + 0.7 at the kill, minus bob's quarter (0.175). She was paid on 0.825 although a quarter
        // of the blow's BOSS was still in the pool; that BOSS later went to carol with no credit (claimed).
        assertApproxEqAbs(hook.damage(1, alice), 0.825 ether, 1e6, "her claimed credit stays recorded");
        assertApproxEqAbs(hook.damage(1, carol), 0.175 ether, 1e6, "carol: bob's quarter, hopped at the end");
        assertEq(hook.damage(1, bob), 0);
        assertEq(hook.claimableDamage(1, carol) > 0, true);
        uint256 paid = _claimEverything();
        assertLe(paid + paidInTx, _prize(1) + _pool(1), "never more than the pools");
        assertEq(hook.totalReserved(), _prize(1) + _pool(1) - paid - paidInTx);
        assertAccounting();
    }

    // =================================================================== P12. after the signer's mid-tx damage claim, the prize stops following hops

    /// @dev The signer claims her damage between the kill and the blow's arrival; the BOSS then comes
    /// out to a router and the router delivers it to her. `_arrive` did not move `bought[kr]` to the
    /// router (her credit is claimed), so the hop releases nothing and `_trackKill` never runs: the
    /// prize, which did move to the router at the arrival, stays there.
    function test_r2_P12_signerClaimsDamageMidTx_prizeStopsFollowingTheHops() public {
        bytes[] memory calls = new bytes[](4);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(2 ether);
        u1[1] = rr.takeBossAsClaims(type(uint256).max);
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](1);
        u2[0] = rr.claimsToBoss(address(rr), type(uint256).max);
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.claimDamage, (1, alice));
        calls[2] = abi.encodeCall(rr.unlockWith, (u2)); // prize -> router
        calls[3] = abi.encodeCall(rr.transferBoss, (alice, 1_000_000 ether + 1)); // router -> her
        vm.prank(alice, alice);
        rr.multi(calls);
        assertGt(boss.balanceOf(alice), 1_000_000 ether, "she holds the whole blow");
        console2.log("P12 killer:", _killer(1));
        console2.log("P12 alice / router:", alice, address(rr));
        assertEq(_killer(1), alice, "DESIGN: the prize follows the largest share of the blow's BOSS (hers)");
    }

    // =================================================================== P13. the Universal Router shape with a fee and a large pre-kill position (sanity)

    function test_r2_P13_universalRouterShape_feeTakenFirst_thenCustodyAndSweep_withPreKillPosition() public {
        buyExactIn(alice, 0.5 ether);
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](4);
        a[0] = script.buy(2 ether); // kill: 0.5
        a[1] = script.takeBossShare(feeCollector, 25, 10_000); // TAKE_PORTION
        a[2] = script.takeBoss(address(script), type(uint256).max); // custody
        a[3] = script.forward(alice, type(uint256).max); // SWEEP
        vm.prank(alice, alice);
        script.run(a);
        assertEq(_killer(1), alice);
        assertEq(hook.unclaimedKill(alice), _prize(1));
        assertEq(hook.unclaimedKill(feeCollector) + hook.unclaimedKill(address(script)), 0);
        assertApproxEqAbs(hook.damage(1, alice), 0.5 ether + uint256(0.5 ether) * 9_975 / 10_000, 1e6);
        assertEq(hook.damage(1, alice) + hook.damage(1, feeCollector), INITIAL_HP);
        assertEq(hook.bought(1, alice), boss.balanceOf(alice));
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== P14. the relayer's own EOA hops its pre-kill BOSS: the signer exclusion does not stop it

    /// @dev Same as P1 but the hopping wallet is the signer itself (a relayer that also played round 1):
    /// after alice's arrival consumed T_KILL_BOSS, `_releaseClosed` excludes nothing and the relayer's
    /// hop of its own pre-kill BOSS out-holds alice.
    function test_r2_P14_relayerEoaHopsItsOwnPreKillBoss_takesThePrize() public {
        _fund(relayer);
        buyExactIn(relayer, 0.8 ether); // the relayer played round 1 early
        vm.prank(relayer);
        boss.approve(address(rr), type(uint256).max);
        bytes[] memory calls = new bytes[](2);
        ReviewRouter.Action[] memory u = new ReviewRouter.Action[](2);
        u[0] = rr.buy(0.5 ether); // alice's killing blow (0.2)
        u[1] = rr.takeBoss(alice, type(uint256).max);
        calls[0] = abi.encodeCall(rr.unlockWith, (u));
        calls[1] = abi.encodeCall(rr.transferBossFromPct, (relayer, venue, 100)); // relayer -> its other wallet
        vm.prank(alice, relayer);
        rr.multi(calls);
        assertEq(hook.damage(1, alice), 0.2 ether);
        _assertOpenRoundSums();
        assertAccounting();
        console2.log("P14 killer:", _killer(1));
        console2.log("P14 alice / venue:", alice, venue);
        assertEq(_killer(1), alice, "DESIGN: the prize follows the kill's BOSS (alice: 100%)");
    }

    // =================================================================== P3b. the executor collects prize AND damage pool between unlocks

    /// @dev P3 completed: between the kill and the arrival the relayer calls `claimKill(relayer)` and
    /// `claimDamage(1, relayer)` (both open to anyone). The signer holds the whole killing credit at
    /// that moment, so the damage pool share of the blow is paid to the relayer; the later arrival
    /// then moves nothing (`damageClaimed[kr][signer]`). alice receives her BOSS with no credit at all.
    function test_r2_P3b_relayerCollectsPrizeAndDamagePoolBetweenUnlocks_aliceGetsBareBoss() public {
        buyExactIn(bob, 0.3 ether); // another player, so the damage pool is split
        bytes[] memory calls = new bytes[](4);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(2 ether); // alice's kill: 0.7
        u1[1] = rr.takeBossAsClaims(type(uint256).max);
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](1);
        u2[0] = rr.claimsToBoss(alice, type(uint256).max);
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.claimKill, (relayer));
        calls[2] = abi.encodeCall(rr.claimDamage, (1, relayer));
        calls[3] = abi.encodeCall(rr.unlockWith, (u2));
        uint256 before = _quoteBalance(relayer);
        vm.prank(alice, relayer);
        rr.multi(calls);

        assertGt(boss.balanceOf(alice), 0, "alice got the BOSS");
        assertEq(hook.damage(1, alice), 0, "LIMIT: no damage credit reached her");
        assertEq(hook.unclaimedKill(alice), 0, "LIMIT: no prize either");
        assertEq(hook.damage(1, relayer), 0.7 ether, "the relayer keeps the blow's credit, claimed");
        assertEq(_quoteBalance(relayer) - before, _prize(1) + _pool(1) * 0.7 ether / INITIAL_HP, "LIMIT: paid both");
        assertEq(hook.claimableDamage(1, bob), _pool(1) * 0.3 ether / INITIAL_HP, "bob is not harmed");
        _assertOpenRoundSums();
        assertAccounting();
    }

    // =================================================================== P15. the frozen closed-round count makes P1 cheap

    /// @dev bob's `bought[1]` is frozen at the kill, so he can sell his round-1 BOSS right after the kill
    /// (nothing is forfeited), receive any uncredited BOSS and hop it: the hop carries his full round-1
    /// credit and out-holds alice for the prize. The attacker recovers its capital minus fees.
    function test_r2_P15_hopperSellsAfterTheKill_thenHopsUncreditedBoss_stillTakesThePrize() public {
        buyExactIn(bob, 0.8 ether);
        uint256 b = boss.balanceOf(bob);
        uint256 pmBoss = boss.balanceOf(address(manager));
        bytes[] memory calls = new bytes[](4);
        ReviewRouter.Action[] memory u1 = new ReviewRouter.Action[](2);
        u1[0] = rr.buy(0.5 ether); // alice's killing blow (0.2)
        u1[1] = rr.takeBoss(alice, type(uint256).max);
        ReviewRouter.Action[] memory u2 = new ReviewRouter.Action[](1);
        u2[0] = rr.sellPctFrom(bob, 100); // bob dumps his round-1 BOSS in round 2: no forfeit
        calls[0] = abi.encodeCall(rr.unlockWith, (u1));
        calls[1] = abi.encodeCall(rr.unlockWith, (u2));
        calls[2] = abi.encodeCall(rr.transferBoss, (bob, b)); // uncredited inventory lands on bob
        calls[3] = abi.encodeCall(rr.transferBossFromPct, (bob, carol, 100)); // and he hops it
        vm.prank(alice, relayer);
        rr.multi(calls);

        // The pool took bob's whole position back (the router pocketed the IMD) and gave alice the blow.
        assertEq(
            boss.balanceOf(address(manager)), pmBoss + b - hook.bought(1, alice), "bob's BOSS went back into the pool"
        );
        assertEq(boss.balanceOf(bob), 0);
        // Since audit 853ff4df finding 1: a closed round is frozen except for the killing blow.
        assertEq(hook.damage(1, carol), 0, "his frozen round-1 credit no longer travels with uncredited BOSS");
        assertEq(hook.damage(1, bob), 0.8 ether);
        assertEq(hook.damage(1, alice), 0.2 ether);
        _assertOpenRoundSums();
        assertAccounting();
        console2.log("P15 killer:", _killer(1));
        console2.log("P15 alice / carol:", alice, carol);
        assertEq(_killer(1), alice, "DESIGN: the prize follows the kill's BOSS (alice: 100%)");
    }
}

contract Review2BossFirstTest is Review2Base {}

contract Review2BossSecondTest is Review2Base {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
