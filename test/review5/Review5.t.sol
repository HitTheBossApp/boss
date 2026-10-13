// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BossFixture} from "../utils/BossFixture.sol";
import {Bundle} from "../utils/Bundle.sol";
import {FixedAbility} from "../mocks/Abilities.sol";
import {R3Router} from "../review3/R3Router.sol";
import {LenientBundle} from "../review4/LenientBundle.sol";
import {R5Router, ExactForwarder} from "./R5Router.sol";
import {BossHook} from "../../src/BossHook.sol";
import {OracleGate} from "../../src/OracleGate.sol";

/// @dev Fifth independent review, on fix-audit3 @ ed8a9c6 (fixes of the swarm's third audit, job 853ff4df).
/// Convention of the earlier reviews: each probe asserts what the code or the README CLAIMS (or what the
/// same trades give without the disturbing step), so a FAIL documents a gap and a PASS confirms the claim.
/// Runs with BOSS as currency0, as currency1 (IMD pairing) and with native ETH.
abstract contract Review5Base is BossFixture {
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve"); // the attacker
    address internal bundlerEOA = makeAddr("bundlerEOA");
    R5Router internal ra; // locker A (a player's router / smart wallet that is its own router)
    R5Router internal rb; // locker B (another party's router)
    ExactForwarder internal fwd; // a non-locker custodian that forwards exactly what it received
    Bundle internal bundle;
    LenientBundle internal lenient;
    uint256 internal constant MAX = type(uint256).max;

    function setUp() public virtual override {
        super.setUp();
        ra = new R5Router(IPoolManager(address(manager)), key, boss);
        rb = new R5Router(IPoolManager(address(manager)), key, boss);
        fwd = new ExactForwarder(boss);
        _fundRouter(address(ra));
        _fundRouter(address(rb));
        bundle = new Bundle();
        lenient = new LenientBundle();
        address[6] memory eoas = [alice, bob, carol, dave, eve, bundlerEOA];
        for (uint256 i = 0; i < eoas.length; i++) {
            vm.startPrank(eoas[i]);
            boss.approve(address(ra), MAX);
            boss.approve(address(rb), MAX);
            vm.stopPrank();
        }
    }

    function _fundRouter(address r) internal {
        if (useNative()) vm.deal(r, 1_000 ether);
        else quoteToken.mint(r, 1_000 ether);
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

    function _claimD(uint64 r, address w) internal pure returns (bytes memory) {
        return abi.encodeCall(R3Router.claimDamage, (r, w));
    }

    function _fwdTo(address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(R3Router.forward, (to, amount));
    }

    function _multi(R5Router r, address signer, bytes[] memory calls) internal {
        vm.prank(signer, signer);
        r.multi(calls);
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
        w = new address[](13);
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

    /// @dev The killing blow of a fresh pool: 2 units of quote kill the 1-unit boss. Returns the blow's
    /// BOSS and credit, measured in a throw-away run.
    function _measureBlow() internal returns (uint256 blowBoss, uint256 blowDmg) {
        uint256 snap = vm.snapshotState();
        vm.prank(bob, bob);
        ra.run(_buyTake(2 ether, dave));
        blowBoss = boss.balanceOf(dave);
        blowDmg = hook.damage(1, dave);
        vm.revertToState(snap);
    }

    /// @dev The plant: the blow's size, or (native config, where 2 ETH buy more BOSS than the fixture holds)
    /// all the BOSS the fixture can spare, which still exceeds half of the blow.
    function _plantOf(uint256 blowBoss) internal view returns (uint256) {
        uint256 have = boss.balanceOf(address(this));
        return blowBoss < have ? blowBoss : have;
    }

    function _bossId() internal view returns (uint256) {
        return uint256(uint160(address(boss)));
    }

    function _hasPanic(bytes memory f) internal pure returns (bool) {
        for (uint256 j = 0; j + 4 <= f.length; j++) {
            if (f[j] == 0x4e && f[j + 1] == 0x48 && f[j + 2] == 0x7b && f[j + 3] == 0x71) return true;
        }
        return false;
    }

    // =================================================================== F1. `_arrive` can underflow `bought`

    /// @dev Shared flow of F1 and its control. Bob signs (tx.origin) and kills through his router `ra`; 60%
    /// of the blow goes to carol, 40% stays inside the PoolManager as ERC-6909 claims (README: "What never
    /// leaves the pool in that transaction ... stays with the signer" until it leaves). Between the two
    /// unlocks (optionally) anyone triggers claimDamage(1, carol); carol hands her blow BOSS to bob, bob pays
    /// it on to dave (both wallets' own transfers), and the router finally redeems its claims to alice.
    function _f1Flow(bool claimCarol) internal returns (bool ok, bytes memory ret) {
        bytes[] memory calls = new bytes[](claimCarol ? 5 : 4);
        uint256 i;
        calls[i++] = _run(_3(_A(R3Router.Kind.BuyIn, address(0), 2 ether), _share(carol, 6, 10), _A(R3Router.Kind.KeepClaims, address(0), MAX)));
        if (claimCarol) calls[i++] = _claimD(1, carol);
        calls[i++] = _pull(carol, bob, MAX);
        calls[i++] = _pull(bob, dave, MAX);
        calls[i++] = _run(_1(_A(R3Router.Kind.ClaimsToBoss, alice, MAX)));
        vm.prank(bob, bob);
        (ok, ret) = address(ra).call(abi.encodeCall(R3Router.multi, (calls)));
    }

    /// Control: the same flow without the claim succeeds and closes the books.
    function test_r5_F1_control_withoutClaim_succeeds() public {
        (bool ok,) = _f1Flow(false);
        assertTrue(ok, "control flow succeeds");
        assertEq(hook.round(), 2);
        _assertSums();
        assertAccounting();
    }

    /// @dev Expected (NatSpec of onBossTransfer and README: "no revert path beyond the caller check, so it
    /// can never block a transfer"; fix 4: "a hop of blow BOSS whose credit was already collected never
    /// underflows bought"): the redemption of the claims succeeds. Actual: carol's hop to bob skips the
    /// credit block (carol collected), so bob receives 0.6 of the blow as held BOSS without `bought`; bob's
    /// hop to dave then takes min(out, bought[1][bob]) = all of the 0.4 `bought` that still backs the blow
    /// left inside the PoolManager, and `_arrive` panics on `bought[kr][signer] -= bossAmount`.
    function test_r5_F1_claimedBlowHopsToSigner_thenRestArrives_noRevert() public {
        // State right before the redemption (same calls, last unlock left out, as its own transaction).
        uint256 snap = vm.snapshotState();
        bytes[] memory pre = new bytes[](4);
        pre[0] = _run(_3(_A(R3Router.Kind.BuyIn, address(0), 2 ether), _share(carol, 6, 10), _A(R3Router.Kind.KeepClaims, address(0), MAX)));
        pre[1] = _claimD(1, carol);
        pre[2] = _pull(carol, bob, MAX);
        pre[3] = _pull(bob, dave, MAX);
        _multi(ra, bob, pre);
        console2.log("F1 before redemption: bought[1][bob] (signer)", hook.bought(1, bob));
        console2.log("F1 before redemption: damage[1][bob]", hook.damage(1, bob));
        console2.log("F1 blow BOSS still inside as claims (to arrive)", manager.balanceOf(address(ra), _bossId()));
        vm.revertToState(snap);

        (bool ok, bytes memory ret) = _f1Flow(true);
        console2.log("F1 flow ok:", ok);
        console2.logBytes(ret);
        assertFalse(_hasPanic(ret), "onBossTransfer must never panic (Panic(0x11) on bought[kr][signer])");
        assertTrue(ok, "the claims redemption must not be blocked");
    }

    // =================================================================== F2. 7702 check bypassed by clearing the delegation

    function _propose7702(address eoa, address target) internal returns (uint256 id) {
        vm.etch(eoa, abi.encodePacked(hex"ef0100", target)); // the code an EOA carries after a 7702 authorization
        vm.prank(keeper);
        board.propose(eoa, "swarm job: delegated wallet");
        (id,) = board.pending();
        vm.warp(block.timestamp + 1);
    }

    /// Control: the fix refuses a delegated EOA at accept (all three configs).
    function test_r5_F2_control_delegatedAtAccept_refused() public {
        address eoa = makeAddr("delegated");
        uint256 id = _propose7702(eoa, address(new FixedAbility(10_000, 10_000)));
        OracleGate.Attestation memory a = attestation(id * 2 + 1);
        bytes memory sig = signAttestation(a);
        vm.expectRevert(BossHook.AbilityNotAContract.selector);
        hook.acceptAbility(a, sig);
    }

    /// @dev Expected (README: "It must be a contract: an EIP-7702 delegated wallet, whose code its owner
    /// could re-point after the approval, is refused when it is accepted"). Actual: the owner clears the
    /// delegation (a 7702 authorization to address(0) empties the code) right before relaying the approved
    /// attestation; acceptAbility only refuses the exact 23-byte 0xef0100 shape, never an address without
    /// code, so the EOA is queued and, once active, its owner re-delegates it to any code (emulated with an
    /// etch of the new delegation target's code, which is what a STATICCALL to a delegated EOA executes).
    function test_r5_F2_delegationClearedBeforeAccept_isRefused() public {
        uint256 pk = 0xA11CE7702;
        address eoa = vm.addr(pk);
        uint256 id = _propose7702(eoa, address(new FixedAbility(10_000, 10_000)));
        OracleGate.Attestation memory a = attestation(id * 2 + 1);
        bytes memory sig = signAttestation(a);

        vm.etch(eoa, ""); // the owner signs a 7702 authorization to address(0): the code is gone
        (bool accepted,) = address(hook).call(abi.encodeCall(BossHook.acceptAbility, (a, sig)));
        console2.log("F2 accepted an address without code:", accepted);
        if (accepted) {
            vm.warp(block.timestamp + 12 hours + 1);
            // After activation the owner points the delegation at a 4x-hit body that nobody reviewed.
            FixedAbility rogue = new FixedAbility(40_000, 2_500);
            vm.etch(eoa, address(rogue).code);
            uint256 h0 = hook.hp();
            buyExactIn(alice, 0.1 ether);
            console2.log("F2 damage of a 0.1 buy after re-pointing:", h0 - hook.hp());
            (address active,,) = hook.currentAbility();
            assertEq(active, eoa, "the EOA is the active ability");
        }
        assertFalse(accepted, "an address that can be re-pointed (EOA, 7702) must never be queued");
    }

    /// @dev F2 with real EIP-7702 delegations (Prague): delegate, propose, approve, revoke (delegate to zero),
    /// accept, then re-delegate to a rogue body after activation. Same expectation as above.
    function test_r5_F2_real7702_revokeThenAccept_isRefused() public {
        vm.setEvmVersion("prague");
        uint256 pk = 0xB0B7702;
        address eoa = vm.addr(pk);
        FixedAbility body = new FixedAbility(10_000, 10_000);
        FixedAbility rogue = new FixedAbility(40_000, 2_500);
        vm.signAndAttachDelegation(address(body), pk);
        (bool ok0,) = eoa.call("");
        ok0;
        console2.log("F2 real: code length after delegating", eoa.code.length);
        vm.prank(keeper);
        board.propose(eoa, "swarm job: delegated wallet");
        (uint256 id,) = board.pending();
        vm.warp(block.timestamp + 1);
        OracleGate.Attestation memory a = attestation(id * 2 + 1);
        bytes memory sig = signAttestation(a);

        vm.signAndAttachDelegation(address(0), pk); // revoke: the EOA has no code again
        (bool ok1,) = eoa.call("");
        ok1;
        console2.log("F2 real: code length after revoking", eoa.code.length);
        (bool accepted,) = address(hook).call(abi.encodeCall(BossHook.acceptAbility, (a, sig)));
        console2.log("F2 real: accepted", accepted);
        if (accepted) {
            vm.warp(block.timestamp + 12 hours + 1);
            vm.signAndAttachDelegation(address(rogue), pk);
            (bool ok2,) = eoa.call("");
            ok2;
            uint256 h0 = hook.hp();
            buyExactIn(alice, 0.1 ether);
            console2.log("F2 real: damage of a 0.1 buy after re-delegating", h0 - hook.hp());
        }
        assertFalse(accepted, "an EOA that can be re-delegated must never be queued");
    }

    // =================================================================== F3. older-first rule: a planted custodian keeps the blow

    function _routeKillVia(address user) internal {
        R3Router.Action[] memory s = _2(_A(R3Router.Kind.BuyIn, address(0), 2 ether), _A(R3Router.Kind.TakeBoss, address(fwd), MAX));
        vm.prank(user, user);
        fwd.route(ra, s, user);
    }

    /// Control: through a clean forwarder (non-locker custodian) the user gets the whole blow and the prize.
    function test_r5_F3_control_cleanForwarder_userGetsBlow() public {
        (, uint256 blowDmg) = _measureBlow();
        _routeKillVia(carol);
        assertEq(_killer(1), carol);
        assertEq(hook.damage(1, carol), blowDmg);
        assertEq(hook.damage(1, address(fwd)), 0);
    }

    /// @dev Expected (README: the killing blow and its damage "travel with that BOSS for the rest of the
    /// transaction, through any router, aggregator or solver that custodies it on the way"; before ed8a9c6
    /// every hop was blow-first and this held): carol, who receives every wei of the blow, gets its credit
    /// and the prize. Actual: in an EARLIER transaction eve sends BOSS to the forwarder. The forwarder is not
    /// the locker, so `_hopBlow` spends its "older" BOSS first: out = held - balanceOf(fwd) = 0. The blow's
    /// credit and the prize stay on the forwarder, although its own BOSS never moved in this transaction.
    function test_r5_F3_plantedForwarder_userStillGetsBlow() public {
        (uint256 blowBoss, uint256 blowDmg) = _measureBlow();
        uint256 plant = _plantOf(blowBoss);
        giveBoss(eve, plant);
        vm.prank(eve);
        boss.transfer(address(fwd), plant); // tx 1: the plant (an amount >= the blow keeps all of it)

        _routeKillVia(carol); // tx 2: carol's kill
        console2.log("F3 blow BOSS carol received:", boss.balanceOf(carol));
        console2.log("F3 credit carol / forwarder:", hook.damage(1, carol), hook.damage(1, address(fwd)));
        console2.log("F3 killer is the forwarder:", _killer(1) == address(fwd));
        assertEq(boss.balanceOf(carol), blowBoss, "carol received every wei of the blow");
        assertEq(_killer(1), carol, "the prize follows the blow's BOSS to carol");
        assertEq(hook.damage(1, carol), blowDmg, "the blow's credit follows it to carol");
    }

    /// @dev Worst case of F3: the custodian has a public sweep (as the Universal Router does). Eve plants,
    /// carol kills, then eve claims the prize and the blow's damage share to the forwarder and sweeps the
    /// quote out, and sweeps her planted BOSS back. Expected: eve gains nothing.
    function test_r5_F3_plantedSweepableForwarder_attackerGainsNothing() public {
        (uint256 blowBoss,) = _measureBlow();
        uint256 plant = _plantOf(blowBoss);
        giveBoss(eve, plant);
        vm.prank(eve);
        boss.transfer(address(fwd), plant);
        _routeKillVia(carol);

        uint256 q0 = _quoteBalance(eve);
        if (hook.unclaimedKill(address(fwd)) > 0) hook.claimKill(address(fwd));
        if (hook.claimableDamage(1, address(fwd)) > 0) hook.claimDamage(1, address(fwd));
        vm.prank(eve, eve);
        fwd.sweep(pairedAddr, eve);
        vm.prank(eve, eve);
        fwd.sweep(address(boss), eve);
        uint256 gain = _quoteBalance(eve) - q0;
        console2.log("F3 eve's quote gain (prize + blow damage share):", gain);
        console2.log("F3 eve's BOSS back / planted:", boss.balanceOf(eve), plant);
        assertEq(gain, 0, "a stranger must not collect the kill");
    }

    // =================================================================== P. what holds (expected PASS)

    /// @dev Bob bought in round 1 (earlier tx). One bundle: rb's kill (blow to alice), then bob's operations:
    /// a sell through a custodying router, a transfer to dave, a deposit of BOSS as claims via the router and
    /// their redemption to carol, a transfer to the hook. Bob's closed-round credit never moves.
    function test_r5_P1_bystanderClosedCredit_frozenThroughEveryShape() public {
        vm.prank(bob, bob);
        ra.run(_buyTake(0.3 ether, bob));
        uint256 d0 = hook.damage(1, bob);
        uint256 q = boss.balanceOf(bob) / 5;
        address[] memory t = new address[](6);
        bytes[] memory c = new bytes[](6);
        t[0] = address(rb);
        c[0] = _run(_buyTake(2 ether, alice));
        t[1] = address(ra);
        c[1] = abi.encodeCall(R3Router.multi, (_c(_pull(bob, address(ra), q), _run(_1(_sellOwn(1, 1))))));
        t[2] = address(ra);
        c[2] = _pull(bob, dave, q);
        t[3] = address(ra);
        c[3] = abi.encodeCall(
            R3Router.multi,
            (_c(_pull(bob, address(ra), q), _run(_2(_A(R3Router.Kind.DepositOwn, address(0), q), _A(R3Router.Kind.ClaimsToBoss, carol, q)))))
        );
        t[4] = address(ra);
        c[4] = _pull(bob, address(hook), q);
        t[5] = address(rb);
        c[5] = _run(_buyTake(0.05 ether, bob)); // another locker's buy in round 2, delivered to bob
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(t, c);
        assertEq(hook.round(), 2);
        assertEq(hook.damage(1, bob), d0, "bob's closed credit is frozen");
        assertEq(hook.damage(1, address(ra)), 0);
        assertEq(hook.damage(1, dave), 0);
        assertEq(hook.damage(1, carol), 0);
        assertEq(_killer(1), alice);
        _assertSums();
        assertAccounting();
    }

    /// @dev The killer (an EOA, not the locker) holds older BOSS, receives more older BOSS from dave after
    /// the kill, and sends older BOSS away several times (to a wallet, to the pool through a router, to the
    /// hook, to herself). She keeps the prize and every wei of the blow's credit; then the blow itself leaves.
    function test_r5_P2_killerNonLocker_olderBossInAndOut_keepsBlow() public {
        (uint256 blowBoss, uint256 blowDmg) = _measureBlow();
        giveBoss(carol, 300_000 ether);
        giveBoss(dave, 200_000 ether);
        bytes[] memory calls = new bytes[](8);
        calls[0] = _run(_buyTake(2 ether, carol));
        calls[1] = _pull(dave, carol, 200_000 ether);
        calls[2] = _pull(carol, alice, 150_000 ether);
        calls[3] = _pull(carol, carol, MAX); // self-transfer: nothing moves
        calls[4] = _pull(carol, address(ra), 100_000 ether);
        calls[5] = _run(_1(_sellOwn(1, 1))); // the router sells it into the pool
        calls[6] = _pull(carol, address(hook), 200_000 ether); // the rest of her older BOSS into the sink
        calls[7] = _pull(carol, dave, 49_999 ether);
        _multi(ra, bob, calls);
        assertEq(_killer(1), carol, "older BOSS never carries the prize");
        assertEq(hook.damage(1, carol), blowDmg, "nor the blow's credit");
        assertEq(hook.damage(1, alice) + hook.damage(1, dave) + hook.damage(1, address(ra)), 0);
        assertEq(boss.balanceOf(carol), blowBoss + 1 ether, "she still holds the blow (+1 older BOSS)");
        _assertSums();
        assertAccounting();
    }

    /// @dev Same start, then the blow itself leaves: a half goes to alice (tie stays with carol), the rest to
    /// dave in one transfer (dave becomes the largest holder).
    function test_r5_P2b_killerNonLocker_blowLeavesLast_inProportion() public {
        (uint256 blowBoss, uint256 blowDmg) = _measureBlow();
        giveBoss(carol, 100_000 ether);
        bytes[] memory calls = new bytes[](3);
        calls[0] = _run(_buyTake(2 ether, carol));
        calls[1] = _pull(carol, alice, 100_000 ether + blowBoss / 4);
        calls[2] = _pull(carol, dave, blowBoss / 2);
        _multi(ra, bob, calls);
        assertApproxEqAbs(hook.damage(1, alice), blowDmg / 4, 2);
        assertApproxEqAbs(hook.damage(1, dave), blowDmg / 2, 2);
        assertApproxEqAbs(hook.damage(1, carol), blowDmg - blowDmg / 4 - blowDmg / 2, 3);
        // Since audit 965a5fce (finding 1) the prize goes to a wallet holding more than half of the blow, else to the signer: dave holds exactly half, not more.
        assertEq(_killer(1), bob, "no majority: the signer keeps the prize");
        _assertSums();
        assertAccounting();
    }

    /// @dev Since audit 94b6c9a5 (finding 1) the locker that executed the kill pays the blow out in
    /// proportion to its balance. A smart wallet that is its own router holds older BOSS, kills, keeps the
    /// blow and pays older BOSS to dave: dave carries that payment's share of the blow.
    function test_r5_P3_ownRouterWallet_paysOlderBoss_blowLeavesInProportion() public {
        (uint256 blowBoss, uint256 blowDmg) = _measureBlow();
        uint256 older = _plantOf(blowBoss); // the wallet's older BOSS (all of the blow's size, or > half of it)
        giveBoss(address(ra), older);
        _multi(ra, bob, _c(_run(_buyTake(2 ether, address(ra))), _fwdTo(dave, older)));
        assertApproxEqAbs(hook.damage(1, dave), blowDmg * older / (older + blowBoss), 2, "the payment's share");
        // Documented limit (README): a smart wallet that is its own router (not the signer) stops counting for
        // the prize once it pays blow BOSS out, so its payee takes the prize (review 7's fix of planted BOSS).
        // Since audit 965a5fce (finding 1) the prize goes to a wallet holding more than half of the blow, else to the signer; the paying router-wallet no longer counts.
        uint256 daveHeld = blowBoss * older / (older + blowBoss);
        assertEq(_killer(1), 2 * daveHeld > blowBoss ? dave : bob, "majority, else the signer");
        _assertSums();
        assertAccounting();
    }

    /// @dev Two kills in one transaction by two lockers, both blows to carol (who holds older BOSS too).
    /// Round 1 is frozen once round 2 closes; round 2's blow leaves last from carol; sums hold.
    function test_r5_P4_twoKillsTwoLockers_blowOfBoth_onlyLastTravels() public {
        giveBoss(carol, 50_000 ether);
        address[] memory t = new address[](4);
        bytes[] memory c = new bytes[](4);
        t[0] = address(ra);
        c[0] = _run(_buyTake(2 ether, carol));
        t[1] = address(rb);
        c[1] = _run(_buyTake(3 ether, carol)); // next boss: 1.5 units of HP
        t[2] = address(ra);
        c[2] = _pull(carol, dave, 50_000 ether); // older first: nothing moves
        t[3] = address(ra);
        c[3] = _pull(carol, alice, MAX); // everything, both blows
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(t, c);
        assertEq(hook.round(), 3);
        assertGt(hook.damage(1, carol), 0, "round 1 credit stayed with carol (frozen after the 2nd kill)");
        assertEq(hook.damage(1, alice), 0, "round 1 does not travel any more");
        assertEq(hook.damage(2, dave), 0, "older BOSS never carries round 2");
        assertGt(hook.damage(2, alice), 0, "round 2's blow travelled with its BOSS");
        assertEq(hook.damage(2, carol), 0);
        assertEq(_killer(1), carol);
        assertEq(_killer(2), alice);
        _assertSums();
        assertAccounting();
    }

    /// @dev The killing locker keeps the blow in custody; another locker swaps (scope change); the first
    /// locker then delivers: still blow-first, carol gets the credit and the prize.
    function test_r5_P5_lockerChangeAfterKill_custodianStillDelivers() public {
        (, uint256 blowDmg) = _measureBlow();
        address[] memory t = new address[](3);
        bytes[] memory c = new bytes[](3);
        t[0] = address(ra);
        c[0] = _run(_buyTake(2 ether, address(ra)));
        t[1] = address(rb);
        c[1] = _run(_buyTake(0.1 ether, bob));
        t[2] = address(ra);
        c[2] = _fwdTo(carol, MAX);
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(t, c);
        assertEq(_killer(1), carol);
        assertEq(hook.damage(1, carol), blowDmg);
        _assertSums();
        assertAccounting();
    }

    /// @dev The signer collects its credit and the prize between unlocks; the rest of the blow then leaves
    /// as claims are redeemed and hops further: no revert, nothing paid twice, books close.
    function test_r5_P6_signerClaimsBetweenUnlocks_thenBlowMoves_noRevert() public {
        bytes[] memory calls = new bytes[](5);
        calls[0] = _run(_2(_A(R3Router.Kind.BuyIn, address(0), 2 ether), _A(R3Router.Kind.KeepClaims, address(0), MAX)));
        calls[1] = _claimD(1, bob);
        calls[2] = abi.encodeCall(R3Router.claimKill, (bob));
        calls[3] = _run(_1(_A(R3Router.Kind.ClaimsToBoss, carol, MAX)));
        calls[4] = _pull(carol, dave, MAX);
        _multi(ra, bob, calls);
        assertEq(hook.claimableDamage(1, dave), 0, "already collected: not paid twice");
        assertEq(hook.unclaimedKill(dave), 0);
        _assertSums();
        assertAccounting();
    }

    /// @dev The blow goes to the hook (sink) from its custodian: held by nobody, credit stays, no revert.
    function test_r5_P7_blowIntoHookAndPool_heldByNobody_noRevert() public {
        bytes[] memory calls = new bytes[](3);
        calls[0] = _run(_buyTake(2 ether, address(ra)));
        calls[1] = abi.encodeCall(R5Router.toHook, (address(hook), 1000 ether));
        calls[2] = _run(_1(_sellOwn(1, 2)));
        _multi(ra, bob, calls);
        // Since audit 965a5fce (finding 1) the prize goes to a wallet holding more than half of the blow, else to the signer: half of the blow went back to the pool.
        assertEq(_killer(1), bob);
        _assertSums();
        assertAccounting();
    }

    // =================================================================== D. fuzz: kills, hops, custody, sells, claims, several lockers

    struct P {
        uint256 kind;
        R5Router who;
        address to;
        address src;
        uint256 q;
        uint256 b;
        uint256 r;
    }

    function _wsAt(uint256 i) internal view returns (address) {
        address[8] memory ws = [alice, bob, carol, dave, address(ra), address(rb), address(fwd), eve];
        return ws[i % 8];
    }

    function _eoaAt(uint256 i) internal view returns (address) {
        address[5] memory eoas = [alice, bob, carol, dave, eve];
        return eoas[i % 5];
    }

    function _step(uint256 r, uint256 unit, bool withClaims) internal view returns (address, bytes memory) {
        P memory p;
        p.kind = r % 15;
        if (!withClaims && (p.kind == 8 || p.kind == 9)) p.kind = 0;
        p.who = (r >> 8) % 2 == 0 ? ra : rb;
        p.to = _wsAt(r >> 16);
        p.src = _eoaAt(r >> 20);
        p.q = 0.01 ether + (r >> 24) % 1.6 ether;
        p.b = unit * (1 + (r >> 40) % 300) / 100;
        p.r = r;
        if (p.kind < 8) return (address(p.who), _stepA(p));
        return _stepB(p);
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
        if (p.kind == 4) return _fwdTo(p.to, p.b);
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
        // a non-locker custodian: the forwarder has `who` execute and forwards what it got
        R3Router.Action[] memory s2 =
            _2(_A(R3Router.Kind.BuyIn, address(0), p.q), _A(R3Router.Kind.TakeBoss, address(fwd), MAX));
        return (address(fwd), abi.encodeCall(ExactForwarder.route, (R3Router(payable(address(p.who))), s2, p.to)));
    }

    function _fuzz(uint256 seed, uint8 steps, uint8 signerSel, bool withClaims) internal {
        buyExactIn(alice, 0.2 ether);
        uint256 unit = boss.balanceOf(alice);
        uint256 per = unit;
        uint256 have = boss.balanceOf(address(this));
        if (per * 17 > have) per = have / 17; // native: BOSS is far cheaper than the fixture's stock allows
        giveBoss(address(ra), per * 4);
        giveBoss(address(rb), per * 4);
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

    /// @dev Coverage of the fuzz generator: 60 fixed seeds, 14 steps each; logs how many transactions closed
    /// at least one round, how many closed two, and how many steps failed (for market reasons). Same checks.
    function test_r5_D0_generatorCoverage() public {
        uint256 kills;
        uint256 doubleKills;
        uint256 failed;
        for (uint256 k = 0; k < 60; k++) {
            uint256 snap = vm.snapshotState();
            _fuzz(uint256(keccak256(abi.encode("cov", k))), 14, uint8(k), true);
            if (hook.round() > 1) kills++;
            if (hook.round() > 2) doubleKills++;
            failed += lenient.failures().length;
            vm.revertToState(snap);
        }
        console2.log("D0 txs with a kill / with two kills / failed steps of 840", kills, doubleKills, failed);
        assertGt(kills, 20, "the generator closes rounds");
    }

    /// @dev All step kinds, claims between unlocks included.
    function testFuzz_r5_D1_mixed_withClaims_noPanic_booksClose(uint256 seed, uint8 steps, uint8 signerSel) public {
        _fuzz(seed, steps, signerSel, true);
    }

    /// @dev The same without claims inside the transaction.
    function testFuzz_r5_D2_mixed_noClaims_noPanic_booksClose(uint256 seed, uint8 steps, uint8 signerSel) public {
        _fuzz(seed, steps, signerSel, false);
    }
}

contract Review5BossFirstTest is Review5Base {}

contract Review5BossSecondTest is Review5Base {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

contract Review5NativeTest is Review5Base {
    function useNative() internal pure override returns (bool) {
        return true;
    }
}
