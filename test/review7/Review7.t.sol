// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BossFixture} from "../utils/BossFixture.sol";
import {Bundle} from "../utils/Bundle.sol";
import {FixedAbility} from "../mocks/Abilities.sol";
import {R3Router} from "../review3/R3Router.sol";
import {LenientBundle} from "../review4/LenientBundle.sol";
import {R5Router, ExactForwarder} from "../review5/R5Router.sol";
import {R7Router, FeeWrapper} from "./R7Router.sol";
import {BossHook} from "../../src/BossHook.sol";
import {OracleGate} from "../../src/OracleGate.sol";

/// @dev Seventh independent review, on fix-audit4 @ a067634 (fixes of the swarm's fourth audit, job 94b6c9a5):
/// the killing swap's locker pays the blow out in proportion to its balance, same-second attestations, the
/// forfeit rounded up. Convention of the earlier reviews: each probe asserts what the code or the README
/// CLAIMS, so a FAIL documents a gap and a PASS confirms the claim. Runs with BOSS as currency0, as currency1
/// (IMD pairing) and with native ETH.
abstract contract Review7Base is BossFixture {
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve"); // the attacker / planter
    address internal relayer = makeAddr("relayer");
    address internal bundlerEOA = makeAddr("bundlerEOA");
    address internal feeCollector = makeAddr("feeCollector");
    R7Router internal ra; // a locker (the Universal Router's role)
    R7Router internal rb; // another locker
    ExactForwarder internal fwd;
    FeeWrapper internal wrap;
    Bundle internal bundle;
    LenientBundle internal lenient;
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant W7_PK = 0x7702BEEF;
    address internal w7;
    address[] internal extra;

    function setUp() public virtual override {
        super.setUp();
        ra = new R7Router(IPoolManager(address(manager)), key, boss);
        rb = new R7Router(IPoolManager(address(manager)), key, boss);
        fwd = new ExactForwarder(boss);
        wrap = new FeeWrapper(boss);
        _fundRouter(address(ra), 1_000 ether);
        _fundRouter(address(rb), 1_000 ether);
        bundle = new Bundle();
        lenient = new LenientBundle();
        w7 = vm.addr(W7_PK);
        address[7] memory eoas = [alice, bob, carol, dave, eve, bundlerEOA, relayer];
        for (uint256 i = 0; i < eoas.length; i++) {
            vm.startPrank(eoas[i]);
            boss.approve(address(ra), MAX);
            boss.approve(address(rb), MAX);
            vm.stopPrank();
        }
    }

    function _fundRouter(address r, uint256 amount) internal {
        if (useNative()) vm.deal(r, amount);
        else quoteToken.mint(r, amount);
    }

    // ------------------------------------------------------------------ builders

    function _A(R3Router.Kind k, address who, uint256 amount) internal pure returns (R3Router.Action memory) {
        return R3Router.Action(k, who, amount, 0, 0);
    }

    function _share(address who, uint256 num, uint256 den) internal pure returns (R3Router.Action memory) {
        return R3Router.Action(R3Router.Kind.TakeBossShare, who, 0, num, den);
    }

    function _sellOwn(uint256 num, uint256 den) internal pure returns (R3Router.Action memory) {
        return R3Router.Action(R3Router.Kind.SellOwnShare, address(0), 0, num, den);
    }

    function _1(R3Router.Action memory x) internal pure returns (R3Router.Action[] memory s) {
        s = new R3Router.Action[](1);
        s[0] = x;
    }

    function _2(R3Router.Action memory x, R3Router.Action memory y) internal pure returns (R3Router.Action[] memory s) {
        s = new R3Router.Action[](2);
        s[0] = x;
        s[1] = y;
    }

    function _3(R3Router.Action memory x, R3Router.Action memory y, R3Router.Action memory z)
        internal
        pure
        returns (R3Router.Action[] memory s)
    {
        s = new R3Router.Action[](3);
        s[0] = x;
        s[1] = y;
        s[2] = z;
    }

    function _4(R3Router.Action memory w, R3Router.Action memory x, R3Router.Action memory y, R3Router.Action memory z)
        internal
        pure
        returns (R3Router.Action[] memory s)
    {
        s = new R3Router.Action[](4);
        s[0] = w;
        s[1] = x;
        s[2] = y;
        s[3] = z;
    }

    function _buyTake(uint256 q, address to) internal pure returns (R3Router.Action[] memory) {
        return _2(_A(R3Router.Kind.BuyIn, address(0), q), _A(R3Router.Kind.TakeBoss, to, MAX));
    }

    function _run(R3Router.Action[] memory s) internal pure returns (bytes memory) {
        return abi.encodeCall(R3Router.run, (s));
    }

    function _pull(address from, address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(R5Router.pull, (from, to, amount));
    }

    function _portion(address to, uint256 bips) internal pure returns (bytes memory) {
        return abi.encodeCall(R7Router.payPortion, (to, bips));
    }

    function _sweepB(address to) internal pure returns (bytes memory) {
        return abi.encodeCall(R7Router.sweepBoss, (to));
    }

    function _sweepBut(address to, uint256 keep) internal pure returns (bytes memory) {
        return abi.encodeCall(R7Router.sweepBossBut, (to, keep));
    }

    function _c(bytes memory a) internal pure returns (bytes[] memory c) {
        c = new bytes[](1);
        c[0] = a;
    }

    function _c(bytes memory a, bytes memory b) internal pure returns (bytes[] memory c) {
        c = new bytes[](2);
        c[0] = a;
        c[1] = b;
    }

    function _c(bytes memory a, bytes memory b, bytes memory d) internal pure returns (bytes[] memory c) {
        c = new bytes[](3);
        c[0] = a;
        c[1] = b;
        c[2] = d;
    }

    function _c(bytes memory a, bytes memory b, bytes memory d, bytes memory e) internal pure returns (bytes[] memory c) {
        c = new bytes[](4);
        c[0] = a;
        c[1] = b;
        c[2] = d;
        c[3] = e;
    }

    function _c(bytes memory a, bytes memory b, bytes memory d, bytes memory e, bytes memory f)
        internal
        pure
        returns (bytes[] memory c)
    {
        c = new bytes[](5);
        c[0] = a;
        c[1] = b;
        c[2] = d;
        c[3] = e;
        c[4] = f;
    }

    function _multi(R7Router r, address signer, bytes[] memory calls) internal {
        vm.prank(signer, signer);
        r.multi(calls);
    }

    // ------------------------------------------------------------------ views

    function _killer(uint64 r) internal view returns (address k) {
        (k,,,,) = hook.results(r);
    }

    function _prize(uint64 r) internal view returns (uint256 p) {
        (,, p,,) = hook.results(r);
    }

    function _elig(uint64 r) internal view returns (uint256 e) {
        (,,,, e) = hook.results(r);
    }

    function _wallets() internal view returns (address[] memory w) {
        w = new address[](17 + extra.length);
        w[0] = alice;
        w[1] = bob;
        w[2] = carol;
        w[3] = dave;
        w[4] = eve;
        w[5] = bundlerEOA;
        w[6] = address(ra);
        w[7] = address(rb);
        w[8] = address(fwd);
        w[9] = address(hook);
        w[10] = address(this);
        w[11] = address(manager);
        w[12] = keeper;
        w[13] = feeCollector;
        w[14] = address(wrap);
        w[15] = relayer;
        w[16] = w7;
        for (uint256 i = 0; i < extra.length; i++) {
            w[17 + i] = extra[i];
        }
    }

    function _sumDamage(uint64 r) internal view returns (uint256 s) {
        address[] memory w = _wallets();
        for (uint256 i = 0; i < w.length; i++) {
            s += hook.damage(r, w[i]);
        }
    }

    function _assertSums() internal view {
        uint64 r = hook.round();
        assertEq(_sumDamage(r), hook.eligibleDamage(r), "open round: eligible == sum of damage held");
        for (uint64 c = 1; c < r; c++) {
            assertEq(_sumDamage(c), _elig(c), "closed round: snapshot == sum of damage held");
        }
        assertEq(hook.unclaimedKill(address(hook)), 0, "the hook never holds a prize");
    }

    function _hasPanic(bytes memory f) internal pure returns (bool) {
        for (uint256 j = 0; j + 4 <= f.length; j++) {
            if (f[j] == 0x4e && f[j + 1] == 0x48 && f[j + 2] == 0x7b && f[j + 3] == 0x71) return true;
        }
        return false;
    }

    /// @dev The audit's state: alice leaves the boss at 0.01; a 0.02 buy is the last hit. Measures the
    /// blow's BOSS and credit in a throw-away run.
    function _lastHit() internal returns (uint256 blowBoss, uint256 blowDmg) {
        buyExactIn(alice, 0.99 ether);
        assertEq(hook.hp(), 0.01 ether);
        uint256 snap = vm.snapshotState();
        vm.prank(bob, bob);
        ra.run(_buyTake(0.02 ether, dave));
        blowBoss = boss.balanceOf(dave);
        blowDmg = hook.damage(1, dave);
        vm.revertToState(snap);
        assertEq(blowDmg, 0.01 ether);
    }

    function _cap(uint256 want) internal view returns (uint256) {
        uint256 have = boss.balanceOf(address(this)) / 4;
        return want < have ? want : have;
    }

    /// @dev eve plants `amount` BOSS on `target` in an earlier transaction.
    function _plant(address target, uint256 amount) internal {
        giveBoss(eve, amount);
        vm.prank(eve);
        boss.transfer(target, amount);
    }

    // =================================================================== A. rule (a), the fix (expected PASS)

    /// The judge's shape on the locker: take to the router, PAY_PORTION 0.25% of its balance, SWEEP the rest;
    /// a plant of 1,000x the blow on the router.
    function test_r7_A1_payPortionSweep_plantOnLocker_playerKeepsBlow() public {
        (uint256 blowBoss, uint256 blowDmg) = _lastHit();
        _plant(address(ra), _cap(blowBoss * 1000));
        _multi(ra, carol, _c(_run(_buyTake(0.02 ether, address(ra))), _portion(feeCollector, 25), _sweepB(carol)));
        assertEq(_killer(1), carol);
        assertApproxEqAbs(hook.damage(1, feeCollector), blowDmg * 25 / 10_000, 1, "the fee carries its share");
        assertEq(hook.damage(1, carol) + hook.damage(1, feeCollector), blowDmg, "no credit stranded on the router");
        _assertSums();
        assertAccounting();
    }

    /// Several payouts (two fees and a third party) then the sweep; plants on the router, the fee collector
    /// and the final recipient.
    function test_r7_A2_severalPayouts_plantsEverywhere_proportional() public {
        (uint256 blowBoss, uint256 blowDmg) = _lastHit();
        _plant(address(ra), _cap(blowBoss * 50));
        _plant(feeCollector, _cap(blowBoss * 5));
        _plant(carol, _cap(blowBoss * 5));
        _multi(
            ra,
            carol,
            _c(
                _run(_buyTake(0.02 ether, address(ra))),
                _portion(feeCollector, 25),
                _portion(dave, 15),
                _portion(bob, 100),
                _sweepB(carol)
            )
        );
        assertEq(_killer(1), carol);
        // each payout carries bips of what the router held at that moment
        uint256 f = blowDmg * 25 / 10_000;
        uint256 d = (blowDmg - f) * 15 / 10_000;
        uint256 b = (blowDmg - f - d) * 100 / 10_000;
        assertApproxEqAbs(hook.damage(1, feeCollector), f, 2);
        assertApproxEqAbs(hook.damage(1, dave), d, 2);
        assertApproxEqAbs(hook.damage(1, bob), b, 2);
        assertEq(hook.damage(1, carol) + hook.damage(1, feeCollector) + hook.damage(1, dave) + hook.damage(1, bob), blowDmg);
        _assertSums();
        assertAccounting();
    }

    /// SWEEP only, with a plant: the player gets every wei of the blow (and the plant).
    function test_r7_A3_sweepOnly_plant_playerGetsAll() public {
        (uint256 blowBoss, uint256 blowDmg) = _lastHit();
        _plant(address(ra), _cap(blowBoss * 3));
        _multi(ra, carol, _c(_run(_buyTake(0.02 ether, address(ra))), _sweepB(carol)));
        assertEq(_killer(1), carol);
        assertEq(hook.damage(1, carol), blowDmg);
        _assertSums();
        assertAccounting();
    }

    /// The router keeps 1 wei of BOSS after its sweep (a solver keeping dust): the player keeps the prize,
    /// the router keeps at most a rounding share of the credit.
    function test_r7_A4_lockerKeepsOneWei_rounding() public {
        (uint256 blowBoss, uint256 blowDmg) = _lastHit();
        _plant(address(ra), _cap(blowBoss));
        _multi(ra, carol, _c(_run(_buyTake(0.02 ether, address(ra))), _portion(feeCollector, 25), _sweepBut(carol, 1)));
        assertEq(_killer(1), carol);
        assertLe(hook.damage(1, address(ra)), 2, "at most rounding dust stays on the router");
        assertEq(hook.damage(1, carol) + hook.damage(1, feeCollector) + hook.damage(1, address(ra)), blowDmg);
        _assertSums();
        assertAccounting();
    }

    /// The locker changes after the kill (another router swaps), then the killing locker pays the fee and
    /// sweeps: still proportional, T_KILL_LOCKER is the killing locker.
    function test_r7_A5_lockerChangeAfterKill_plantOnLocker_stillProportional() public {
        (uint256 blowBoss, uint256 blowDmg) = _lastHit();
        _plant(address(ra), _cap(blowBoss * 1000));
        address[] memory t = new address[](4);
        bytes[] memory c = new bytes[](4);
        t[0] = address(ra);
        c[0] = _run(_buyTake(0.02 ether, address(ra)));
        t[1] = address(rb);
        c[1] = _run(_buyTake(0.01 ether, bob));
        t[2] = address(ra);
        c[2] = _portion(feeCollector, 25);
        t[3] = address(ra);
        c[3] = _sweepB(carol);
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(t, c);
        assertEq(_killer(1), carol);
        assertApproxEqAbs(hook.damage(1, feeCollector), blowDmg * 25 / 10_000, 1);
        _assertSums();
        assertAccounting();
    }

    /// Two kills in one transaction by two lockers, both planted, both with the fee shape.
    function test_r7_A6_twoKillsTwoLockers_planted_feeShape() public {
        (uint256 blowBoss,) = _lastHit();
        _plant(address(ra), _cap(blowBoss * 500));
        _plant(address(rb), _cap(blowBoss * 500));
        address[] memory t = new address[](2);
        bytes[] memory c = new bytes[](2);
        t[0] = address(ra);
        c[0] = abi.encodeCall(
            R3Router.multi, (_c(_run(_buyTake(0.02 ether, address(ra))), _portion(feeCollector, 25), _sweepB(carol)))
        );
        t[1] = address(rb);
        c[1] = abi.encodeCall(
            R3Router.multi, (_c(_run(_buyTake(3 ether, address(rb))), _portion(feeCollector, 25), _sweepB(dave)))
        );
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(t, c);
        assertEq(hook.round(), 3);
        assertEq(_killer(1), carol);
        assertEq(_killer(2), dave);
        _assertSums();
        assertAccounting();
    }

    /// An EIP-7702 wallet delegated to router code is its own locker: it kills, keeps the blow and pays half
    /// as much older BOSS as the blow to a relayer. The payment carries its proportional share; the wallet
    /// keeps the prize. A plant on it only dilutes what leaves.
    function test_r7_A7_7702OwnLocker_olderFee_proportional() public {
        (uint256 blowBoss, uint256 blowDmg) = _lastHit();
        R7Router tmpl = new R7Router(IPoolManager(address(manager)), key, boss);
        vm.setEvmVersion("prague");
        vm.signAndAttachDelegation(address(tmpl), W7_PK);
        (bool ok,) = w7.call("");
        ok;
        for (uint256 s = 0; s < 3; s++) {
            vm.store(w7, bytes32(s), vm.load(address(tmpl), bytes32(s))); // the pool key lives in storage
        }
        _fundRouter(w7, 1 ether);
        uint256 older = blowBoss / 2;
        _plant(w7, older);
        vm.prank(w7, w7);
        R7Router(payable(w7)).multi(_c(_run(_buyTake(0.02 ether, w7)), abi.encodeCall(R3Router.forward, (relayer, older))));
        assertEq(_killer(1), w7);
        assertApproxEqAbs(hook.damage(1, relayer), blowDmg * older / (older + blowBoss), 2);
        _assertSums();
        assertAccounting();
    }

    // =================================================================== F. rule (a) vs exact-amount delivery (findings)

    R7Router internal rx; // a locker funded with exactly the buy, public sweep

    function _rx() internal {
        rx = new R7Router(IPoolManager(address(manager)), key, boss);
        _fundRouter(address(rx), 0.02 ether);
        extra.push(address(rx));
    }

    /// Control: the locker delivers exactly the swap's output; no plant: the player gets the blow and prize.
    function test_r7_F1_control_exactDelivery_noPlant_playerKeepsPrize() public {
        (, uint256 blowDmg) = _lastHit();
        _rx();
        vm.prank(carol, carol);
        rx.buyDeliverExact(0.02 ether, carol);
        assertEq(_killer(1), carol);
        assertEq(hook.damage(1, carol), blowDmg);
    }

    /// @dev Expected (`_trackKill` NatSpec: "a router that custodies and delivers ... never end[s] up with it";
    /// README: the blow travels "through any router ... that custodies it on the way"; before a067634 a
    /// contract handed the blow on first, so this held): carol receives every wei of the swap's output and
    /// keeps the prize. Actual: eve planted 1.01x the blow on the locker in an earlier transaction; the exact
    /// delivery carries only B*B/(B+P) of the blow, the router keeps the larger share and the prize.
    function test_r7_F1_exactDelivery_plantOnLocker_playerKeepsPrize() public {
        (uint256 blowBoss, uint256 blowDmg) = _lastHit();
        _rx();
        uint256 plant = blowBoss * 101 / 100;
        _plant(address(rx), plant);
        vm.prank(carol, carol);
        rx.buyDeliverExact(0.02 ether, carol);
        console2.log("F1 blow BOSS / plant:", blowBoss, plant);
        console2.log("F1 carol received the whole output:", boss.balanceOf(carol) == blowBoss);
        console2.log("F1 credit carol / router:", hook.damage(1, carol), hook.damage(1, address(rx)));
        console2.log("F1 prize holder is the router:", _killer(1) == address(rx));
        _assertSums();
        assertAccounting();
        assertEq(boss.balanceOf(carol), blowBoss, "carol received every wei of the swap's output");
        assertEq(_killer(1), carol, "the prize follows the delivered blow to carol");
        // Fixed after this review: once the killing swap's router pays the blow out it can no longer hold
        // the prize. Documented limit (README, Known limits): the blow's credit still splits in proportion to the router's balance.
        assertApproxEqAbs(hook.damage(1, carol), blowDmg * blowBoss / (blowBoss + plant), 2, "credit in proportion");
    }

    /// @dev Worst case: the locker's balance is public (a SWEEP command, like the Universal Router's). eve
    /// plants, carol kills, then eve claims the prize and the router's damage share TO the router (anyone may
    /// trigger a claim) and sweeps the quote and her plant back. Expected: eve gains nothing.
    function test_r7_F2_exactDelivery_sweepableLocker_planterTakesPrize() public {
        (uint256 blowBoss,) = _lastHit();
        _rx();
        uint256 plant = blowBoss * 101 / 100;
        _plant(address(rx), plant);
        vm.prank(carol, carol);
        rx.buyDeliverExact(0.02 ether, carol);
        assertEq(_quoteBalance(address(rx)), 0, "the router spent exactly the buy");

        uint256 q0 = _quoteBalance(eve);
        vm.startPrank(eve, eve);
        if (hook.unclaimedKill(address(rx)) > 0) hook.claimKill(address(rx));
        if (hook.claimableDamage(1, address(rx)) > 0) hook.claimDamage(1, address(rx));
        rx.sweep(pairedAddr, eve);
        rx.sweep(address(boss), eve);
        vm.stopPrank();
        uint256 gain = _quoteBalance(eve) - q0;
        console2.log("F2 prize of round 1:", _prize(1));
        console2.log("F2 eve's quote gain (prize + damage share):", gain);
        console2.log("F2 eve's BOSS back / planted:", boss.balanceOf(eve), plant);
        console2.log("F2 carol's prize:", hook.unclaimedKill(carol));
        // Fixed after this review: the prize stays with carol. Documented limit (README, Known limits): the planter can still
        // collect the router's proportional share of the blow's credit, a small part of the damage pool.
        assertEq(hook.unclaimedKill(carol), _prize(1), "the prize stays with carol");
        assertLt(gain, _prize(1) / 10, "only the router's share of the blow's credit, never the prize");
    }

    /// @dev Positive-slippage shape (an aggregator delivers the quoted amount, 99% of the output here, and
    /// sweeps the surplus to its fee wallet). Expected: carol, who gets 99% of the output, keeps the prize.
    /// Actual: with a plant about the size of the blow the fee wallet holds more of it and takes the prize.
    function test_r7_F3_quotedDelivery_plant_prizeToSurplusWallet() public {
        (uint256 blowBoss,) = _lastHit();
        _rx();
        _plant(address(rx), blowBoss);
        vm.prank(carol, carol);
        rx.buyDeliverQuoted(0.02 ether, carol, 9_900, feeCollector);
        console2.log("F3 credit carol / fee wallet:", hook.damage(1, carol), hook.damage(1, feeCollector));
        _assertSums();
        assertAccounting();
        // Documented limit (README, Known limits): a router that delivers a quoted amount and sweeps the surplus, planted BOSS included,
        // to its own wallet can hand that wallet the larger share of the blow and the prize.
        assertEq(_killer(1), feeCollector, "documented: the surplus wallet holds the larger share");
    }

    /// Control of F3 without a plant: carol keeps the prize.
    function test_r7_F3_control_quotedDelivery_noPlant() public {
        _lastHit();
        _rx();
        vm.prank(carol, carol);
        rx.buyDeliverQuoted(0.02 ether, carol, 9_900, feeCollector);
        assertEq(_killer(1), carol);
    }

    // =================================================================== N. finding 1's shape on a NON-locker custodian (documented rule (b))

    /// @dev A fee wrapper that is not the locker (it has `ra` execute with the output sent to itself), pays
    /// 0.25% of its balance and sweeps the rest. Rule (b) hands the blow on first, so with a plant of 400x
    /// the blow the fee carries all of it and the prize: finding 1 is unchanged for this custody. Asserted as
    /// the README's rule (b) says (PASS = documented).
    function test_r7_N1_nonLockerFeeWrapper_plant_feeTakesBlow_documented() public {
        (uint256 blowBoss, uint256 blowDmg) = _lastHit();
        uint256 plant = _cap(blowBoss * 400);
        _plant(address(wrap), plant);
        R3Router.Action[] memory s = _buyTake(0.02 ether, address(wrap));
        vm.prank(carol, carol);
        wrap.route(ra, s, feeCollector, 25, carol);
        uint256 fee = (blowBoss + plant) * 25 / 10_000;
        console2.log("N1 fee BOSS / blow BOSS:", fee, blowBoss);
        console2.log("N1 credit fee collector / carol:", hook.damage(1, feeCollector), hook.damage(1, carol));
        if (fee >= blowBoss) {
            assertEq(_killer(1), feeCollector, "documented: blow-first hands it to the fee");
            assertEq(hook.damage(1, feeCollector), blowDmg);
        }
        _assertSums();
        assertAccounting();
    }

    // =================================================================== R. rounding and revert probes

    /// @dev Rule (a) against a simulation: random plant, up to 5 payouts of random bips of the locker's balance
    /// to 4 recipients, then optionally a sweep keeping a few wei. Credit is conserved exactly, never exceeds
    /// the blow, and the prize sits with the largest holder of the blow (per the simulated counts).
    struct Sim {
        uint256 hf; // blow BOSS the router still holds
        uint256 bal; // the router's BOSS balance
        uint256[4] held; // blow BOSS each recipient holds
        bool paid; // the router paid blow BOSS out to a wallet: it no longer counts for the prize
    }

    /// @dev Mirrors rule (a): a transfer of `v` out of the locker carries hf * v / (balance before).
    function _simPay(Sim memory s, uint256 i, uint256 v) internal pure {
        if (v == 0) return;
        if (s.hf > 0) s.paid = true;
        uint256 out = s.hf * v / s.bal;
        s.hf -= out;
        s.held[i] += out;
        s.bal -= v;
    }

    function _r1Calls(Sim memory s, uint256[5] memory bips, uint8 n, bool sweepLast, uint16 keep)
        internal
        view
        returns (bytes[] memory calls)
    {
        address[4] memory rec = [feeCollector, carol, dave, bob];
        calls = new bytes[](1 + n + (sweepLast ? 1 : 0));
        calls[0] = _run(_buyTake(0.02 ether, address(ra)));
        for (uint256 i = 0; i < n; i++) {
            uint256 bp = bound(bips[i], 1, 10_000);
            calls[1 + i] = _portion(rec[i % 4], bp);
            _simPay(s, i % 4, s.bal * bp / 10_000);
        }
        if (sweepLast) {
            uint256 k = keep % 1000;
            calls[1 + n] = _sweepBut(rec[n % 4], k);
            if (s.bal > k) _simPay(s, n % 4, s.bal - k);
        }
    }

    function testFuzz_r7_R1_lockerPayouts_conserveCredit_prizeWithLargest(
        uint256 plantSeed,
        uint256[5] memory bips,
        uint8 n,
        bool sweepLast,
        uint16 keep
    ) public {
        (uint256 blowBoss, uint256 blowDmg) = _lastHit();
        uint256 plant = _cap(plantSeed % (blowBoss * 2000 + 1));
        if (plant > 0) _plant(address(ra), plant);
        n = uint8(bound(n, 0, 5));
        Sim memory s;
        s.hf = blowBoss;
        s.bal = blowBoss + plant;
        bytes[] memory calls = _r1Calls(s, bips, n, sweepLast, keep);
        _multi(ra, carol, calls);
        address[4] memory rec = [feeCollector, carol, dave, bob];
        uint256 sum = hook.damage(1, address(ra));
        // Once the router (the killing swap's locker, not the signer) pays the blow out to a wallet it no
        // longer counts for the prize (fixed after this review).
        bool paid = s.paid;
        uint256 most = paid ? 0 : s.hf;
        address k1 = _killer(1);
        uint256 hk = k1 == address(ra) ? (paid ? 0 : s.hf) : 0;
        for (uint256 i = 0; i < 4; i++) {
            sum += hook.damage(1, rec[i]);
            assertLe(hook.damage(1, rec[i]), blowDmg);
            if (s.held[i] > most) most = s.held[i];
            if (k1 == rec[i]) hk = s.held[i];
        }
        assertEq(sum, blowDmg, "the blow's credit is conserved");
        assertEq(hk, most, "the prize is with the largest holder of the blow");
        _assertSums();
        assertAccounting();
    }

    /// @dev The forfeit rounds up: a wallet handing BOSS back loses at least its proportional credit, never
    /// more than it holds; a move to a wallet rounds down; in one transaction the net credit created never
    /// exceeds the HP removed; sums hold. Random sizes from 1 wei to more than the position.
    function testFuzz_r7_R2_forfeitRoundsUp_noUnderflow(uint256 q, uint256[6] memory vals, uint8 sel) public {
        q = bound(q, 1e6, 0.5 ether);
        vm.prank(alice, alice);
        ra.run(_buyTake(q, alice));
        for (uint256 i = 0; i < 6; i++) {
            uint256 owned = hook.bought(1, alice);
            uint256 had = hook.damage(1, alice);
            uint256 bal = boss.balanceOf(alice);
            if (bal == 0) break;
            uint256 v = 1 + vals[i] % (i % 2 == 0 ? 1e6 : bal);
            if (v > bal) v = bal;
            uint256 kind = (uint256(sel) >> i) % 3;
            address to = kind == 0 ? address(manager) : kind == 1 ? address(hook) : bob;
            uint256 bobBefore = hook.damage(1, bob);
            uint256 eligBefore = hook.eligibleDamage(1);
            vm.prank(alice);
            boss.transfer(to, v);
            uint256 left = hook.damage(1, alice);
            uint256 taken = v < owned ? v : owned;
            if (owned > 0) {
                if (kind < 2) {
                    assertLe(left * owned, had * (owned - taken), "a forfeit is at least proportional");
                    assertEq(hook.eligibleDamage(1), eligBefore - (had - left));
                } else {
                    assertGe(left * owned, had * (owned - taken), "a move is at most proportional");
                    assertEq(hook.damage(1, bob) - bobBefore, had - left);
                }
            }
            _assertSums();
        }
        // one transaction: forfeit via the router's settle, then a buy; net credit <= HP removed
        uint256 e0 = hook.eligibleDamage(1);
        uint256 h0 = hook.hp();
        uint256 sellAmt = boss.balanceOf(alice) / 3;
        vm.prank(alice, alice);
        ra.multi(_c(_pull(alice, address(ra), sellAmt), _run(_1(_sellOwn(1, 1))), _run(_buyTake(q / 2, alice))));
        if (hook.round() == 1) {
            uint256 e1 = hook.eligibleDamage(1);
            uint256 h1 = hook.hp();
            if (e1 > e0) assertLe(e1 - e0, h0 > h1 ? h0 - h1 : 0, "net credit <= HP removed");
        }
        _assertSums();
        assertAccounting();
    }

    // =================================================================== S. same-second attestation

    function _propose(address ability) internal returns (uint256 id) {
        vm.prank(keeper);
        board.propose(ability, "swarm job");
        (id,) = board.pending();
    }

    /// Two proposals in the same second: the approval of the first never approves the second; the second's
    /// own approval in that second is accepted once; neither replays.
    function test_r7_S1_sameSecond_noWrongAbility_noReplay() public {
        address x = address(new FixedAbility(10_000, 10_000));
        address y = address(new FixedAbility(40_000, 2_500));
        uint256 idX = _propose(x);
        OracleGate.Attestation memory ax = attestation(idX * 2 + 1);
        bytes memory sx = signAttestation(ax);
        uint256 idY = _propose(y); // same block, same second
        vm.expectRevert(abi.encodeWithSelector(BossHook.NotApproved.selector, idX * 2 + 1));
        hook.acceptAbility(ax, sx);
        OracleGate.Attestation memory ay = attestation(idY * 2 + 1);
        ay.requestId = keccak256("y");
        bytes memory sy = signAttestation(ay);
        hook.acceptAbility(ay, sy);
        assertEq(hook.queuedAbility(), y);
        vm.expectRevert(BossHook.NothingPending.selector);
        hook.acceptAbility(ay, sy);
        vm.expectRevert(BossHook.NothingPending.selector);
        hook.acceptAbility(ax, sx);
    }

    /// An attestation issued one second before the proposal is still stale.
    function test_r7_S2_issuedBeforeProposal_stale() public {
        vm.warp(block.timestamp + 10);
        address x = address(new FixedAbility(10_000, 10_000));
        uint256 id = _propose(x);
        OracleGate.Attestation memory a = attestation(id * 2 + 1);
        a.issuedAt = uint64(block.timestamp - 1);
        bytes memory sig = signAttestation(a);
        vm.expectRevert(BossHook.StaleAttestation.selector);
        hook.acceptAbility(a, sig);
    }

    // =================================================================== D. fuzz: kills, fee custodian lockers, plants, forwarders, sells, claims

    struct P {
        uint256 kind;
        R7Router who;
        address to;
        address src;
        uint256 q;
        uint256 b;
        uint256 r;
    }

    function _wsAt(uint256 i) internal view returns (address) {
        address[9] memory ws = [alice, bob, carol, dave, address(ra), address(rb), address(fwd), eve, feeCollector];
        return ws[i % 9];
    }

    function _eoaAt(uint256 i) internal view returns (address) {
        address[5] memory eoas = [alice, bob, carol, dave, eve];
        return eoas[i % 5];
    }

    function _step(uint256 r, uint256 unit, bool withClaims) internal view returns (address, bytes memory) {
        P memory p;
        p.kind = r % 21;
        if (!withClaims && (p.kind == 8 || p.kind == 9)) p.kind = 15;
        p.who = (r >> 8) % 2 == 0 ? ra : rb;
        p.to = _wsAt(r >> 16);
        p.src = _eoaAt(r >> 20);
        p.q = 0.005 ether + (r >> 24) % 1.6 ether;
        p.b = unit * (1 + (r >> 40) % 300) / 100;
        p.r = r;
        if (p.kind < 8) return (address(p.who), _stepA(p));
        if (p.kind < 15) return _stepB(p);
        return (address(p.who), _stepC(p));
    }

    function _stepA(P memory p) internal view returns (bytes memory) {
        if (p.kind == 0) return _run(_buyTake(p.q, p.to));
        if (p.kind == 1) {
            return _run(
                _3(_A(R3Router.Kind.BuyIn, address(0), p.q), _share(p.to, 1, 3), _A(R3Router.Kind.TakeBoss, address(p.who), MAX))
            );
        }
        if (p.kind == 2) {
            return _run(_2(_A(R3Router.Kind.BuyIn, address(0), p.q), _A(R3Router.Kind.KeepClaims, address(0), MAX)));
        }
        if (p.kind == 3) return _run(_1(_A(R3Router.Kind.ClaimsToBoss, p.to, p.b)));
        if (p.kind == 4) return abi.encodeCall(R3Router.forward, (p.to, p.b));
        if (p.kind == 5) return _pull(p.src, p.to, p.b);
        if (p.kind == 6) {
            return abi.encodeCall(R3Router.multi, (_c(_pull(p.src, address(p.who), p.b), _run(_1(_sellOwn(1, 1))))));
        }
        return _run(_1(_sellOwn(1 + (p.r >> 56) % 100, 200)));
    }

    function _stepB(P memory p) internal view returns (address, bytes memory) {
        address target = address(p.who);
        if (p.kind == 8) {
            return (target, abi.encodeCall(R3Router.tryClaimDamage, (uint64(1 + (p.r >> 48) % 3), _wsAt(p.r >> 52))));
        }
        if (p.kind == 9) return (target, abi.encodeCall(R3Router.tryClaimKill, (_wsAt(p.r >> 52))));
        if (p.kind == 10) return (target, abi.encodeCall(R5Router.toHook, (address(hook), p.b / 4)));
        if (p.kind == 11) {
            return (
                target,
                _run(_3(_A(R3Router.Kind.BuyIn, address(0), p.q), _share(p.to, 1, 2), _A(R3Router.Kind.TakeBoss, address(hook), MAX)))
            );
        }
        if (p.kind == 12) {
            return (
                target,
                _run(
                    _4(
                        _A(R3Router.Kind.SellIn, address(0), p.b / 4),
                        _A(R3Router.Kind.BuyBackLast, address(0), 0),
                        _A(R3Router.Kind.BuyIn, address(0), p.q),
                        _A(R3Router.Kind.TakeBoss, p.to, MAX)
                    )
                )
            );
        }
        if (p.kind == 13) {
            return (target, _run(_2(_A(R3Router.Kind.BuyOut, address(0), p.b), _A(R3Router.Kind.TakeBoss, p.to, MAX))));
        }
        R3Router.Action[] memory s2 =
            _2(_A(R3Router.Kind.BuyIn, address(0), p.q), _A(R3Router.Kind.TakeBoss, address(fwd), MAX));
        return (address(fwd), abi.encodeCall(ExactForwarder.route, (R3Router(payable(address(p.who))), s2, p.to)));
    }

    /// @dev The custodian-locker shapes of this review.
    function _stepC(P memory p) internal view returns (bytes memory) {
        address self = address(p.who);
        if (p.kind == 15) {
            return abi.encodeCall(
                R3Router.multi, (_c(_run(_buyTake(p.q, self)), _portion(feeCollector, 25), _sweepB(p.to)))
            );
        }
        if (p.kind == 16) return abi.encodeCall(R7Router.buyDeliverExact, (p.q, p.to));
        if (p.kind == 17) return abi.encodeCall(R7Router.buyDeliverQuoted, (p.q, p.to, 9_900, feeCollector));
        if (p.kind == 18) return _pull(p.src, p.who == ra ? address(rb) : address(ra), p.b); // a plant mid-bundle
        if (p.kind == 19) {
            return abi.encodeCall(
                R3Router.multi,
                (_c(_run(_buyTake(p.q, self)), _portion(feeCollector, 25), _portion(dave, 15), _sweepBut(p.to, p.b / 10)))
            );
        }
        // the locker sells part of what it holds (blow, plant) back into the pool, then sweeps
        return abi.encodeCall(R3Router.multi, (_c(_run(_buyTake(p.q, self)), _run(_1(_sellOwn(1, 3))), _sweepB(p.to))));
    }

    function _fuzz(uint256 seed, uint8 steps, uint8 signerSel, bool withClaims) internal {
        buyExactIn(alice, 0.2 ether);
        uint256 unit = boss.balanceOf(alice);
        uint256 per = unit;
        uint256 have = boss.balanceOf(address(this));
        if (per * 20 > have) per = have / 20;
        giveBoss(address(ra), per * 4); // plants on the lockers
        giveBoss(address(rb), per * 4);
        giveBoss(address(fwd), per);
        giveBoss(carol, per * 3);
        giveBoss(dave, per * 3);
        giveBoss(eve, per * 3);
        steps = uint8(bound(steps, 1, 14));
        address[] memory t = new address[](steps);
        bytes[] memory c = new bytes[](steps);
        uint256 r = seed;
        for (uint256 i = 0; i < steps; i++) {
            r = uint256(keccak256(abi.encode(r, i)));
            (t[i], c[i]) = _step(r, unit, withClaims);
        }
        address[4] memory signers = [bob, carol, bundlerEOA, eve];
        address signer = signers[signerSel % 4];
        vm.prank(signer, signer);
        lenient.run(t, c);
        bytes[] memory fails = lenient.failures();
        for (uint256 i = 0; i < fails.length; i++) {
            assertFalse(_hasPanic(fails[i]), "a step failed with a Panic");
        }
        _assertSums();
        assertAccounting();
    }

    function test_r7_D0_generatorCoverage() public {
        uint256 kills;
        uint256 doubleKills;
        uint256 failed;
        for (uint256 k = 0; k < 60; k++) {
            uint256 snap = vm.snapshotState();
            _fuzz(uint256(keccak256(abi.encode("cov7", k))), 14, uint8(k), true);
            if (hook.round() > 1) kills++;
            if (hook.round() > 2) doubleKills++;
            failed += lenient.failures().length;
            vm.revertToState(snap);
        }
        console2.log("D0 txs with a kill / with two kills / failed steps of 840", kills, doubleKills, failed);
        assertGt(kills, 20, "the generator closes rounds");
    }

    function testFuzz_r7_D1_mixed_withClaims_noPanic_booksClose(uint256 seed, uint8 steps, uint8 signerSel) public {
        _fuzz(seed, steps, signerSel, true);
    }

    function testFuzz_r7_D2_mixed_noClaims_noPanic_booksClose(uint256 seed, uint8 steps, uint8 signerSel) public {
        _fuzz(seed, steps, signerSel, false);
    }
}

contract Review7BossFirstTest is Review7Base {}

contract Review7BossSecondTest is Review7Base {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

contract Review7NativeTest is Review7Base {
    function useNative() internal pure override returns (bool) {
        return true;
    }
}
