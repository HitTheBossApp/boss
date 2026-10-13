// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BossFixture} from "../utils/BossFixture.sol";
import {Bundle} from "../utils/Bundle.sol";
import {R3Router} from "../review3/R3Router.sol";
import {LenientBundle} from "../review4/LenientBundle.sol";
import {R5Router, ExactForwarder} from "../review5/R5Router.sol";
import {CtorForwarder, CtorFactory, BatchWallet} from "./R6Helpers.sol";
import {BossHook} from "../../src/BossHook.sol";

/// @dev Sixth independent review, on fix-audit3 @ 7bfa2a8 (review-5 fixes: capped signer `bought` in
/// `_arrive`, codeless abilities refused, contract/EOA split in `_hopBlow`). Convention of the earlier
/// reviews: each probe asserts what the code or the README CLAIMS, so a FAIL documents a gap and a PASS
/// confirms the claim. Runs with BOSS as currency0, as currency1 (IMD pairing) and with native ETH.
abstract contract Review6Base is BossFixture {
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve"); // the attacker
    address internal relayer = makeAddr("relayer");
    address internal bundlerEOA = makeAddr("bundlerEOA");
    R5Router internal ra;
    R5Router internal rb;
    ExactForwarder internal fwd;
    Bundle internal bundle;
    LenientBundle internal lenient;
    CtorFactory internal cf;
    BatchWallet internal body; // what the 7702 wallet delegates to
    uint256 internal constant W7_PK = 0x7702F00D;
    address internal w7; // an EIP-7702 delegated wallet (delegated in the tests that need it)
    uint256 internal constant MAX = type(uint256).max;
    address[] internal extra; // addresses created during a test that may hold damage

    function setUp() public virtual override {
        super.setUp();
        ra = new R5Router(IPoolManager(address(manager)), key, boss);
        rb = new R5Router(IPoolManager(address(manager)), key, boss);
        fwd = new ExactForwarder(boss);
        _fundRouter(address(ra));
        _fundRouter(address(rb));
        bundle = new Bundle();
        lenient = new LenientBundle();
        cf = new CtorFactory();
        body = new BatchWallet();
        w7 = vm.addr(W7_PK);
        address[7] memory eoas = [alice, bob, carol, dave, eve, bundlerEOA, relayer];
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

    function _delegate7702() internal {
        vm.setEvmVersion("prague");
        vm.signAndAttachDelegation(address(body), W7_PK);
        (bool ok,) = w7.call("");
        ok;
        assertEq(w7.code.length, 23, "w7 carries the 7702 designator");
    }

    // ------------------------------------------------------------------ builders

    function _A(R3Router.Kind k, address who, uint256 amount) internal pure returns (R3Router.Action memory) {
        return R3Router.Action(k, who, amount, 0, 0);
    }

    function _buyTake(uint256 q, address to) internal pure returns (R3Router.Action[] memory s) {
        s = new R3Router.Action[](2);
        s[0] = _A(R3Router.Kind.BuyIn, address(0), q);
        s[1] = _A(R3Router.Kind.TakeBoss, to, MAX);
    }

    function _run(R3Router.Action[] memory s) internal pure returns (bytes memory) {
        return abi.encodeCall(R3Router.run, (s));
    }

    function _pull(address from, address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(R5Router.pull, (from, to, amount));
    }

    function _c2(bytes memory a, bytes memory b) internal pure returns (bytes[] memory c) {
        c = new bytes[](2);
        c[0] = a;
        c[1] = b;
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
        w = new address[](15 + extra.length);
        w[0] = alice;
        w[1] = bob;
        w[2] = carol;
        w[3] = dave;
        w[4] = eve;
        w[5] = bundlerEOA;
        w[6] = relayer;
        w[7] = address(ra);
        w[8] = address(rb);
        w[9] = address(fwd);
        w[10] = address(hook);
        w[11] = address(this);
        w[12] = address(manager);
        w[13] = keeper;
        w[14] = w7;
        for (uint256 i = 0; i < extra.length; i++) {
            w[15 + i] = extra[i];
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

    /// @dev The killing blow of a fresh pool through `ra` (2 units of quote kill the 1-unit boss), measured in
    /// a throw-away run.
    function _measureBlow() internal returns (uint256 blowBoss, uint256 blowDmg) {
        uint256 snap = vm.snapshotState();
        vm.prank(bob, bob);
        ra.run(_buyTake(2 ether, dave));
        blowBoss = boss.balanceOf(dave);
        blowDmg = hook.damage(1, dave);
        vm.revertToState(snap);
    }

    function _plantOf(uint256 want) internal view returns (uint256) {
        uint256 have = boss.balanceOf(address(this));
        return want < have ? want : have;
    }

    // =================================================================== F1. a contract under construction is "a wallet without code"

    /// Control: carol's one-shot contract (constructor executes and forwards) delivers the blow, its credit
    /// and the prize to carol when nobody planted anything on it.
    function test_r6_F1_control_ctorForwarder_noPlant_userGetsBlow() public {
        (uint256 blowBoss, uint256 blowDmg) = _measureBlow();
        vm.prank(carol, carol);
        address c = cf.deploy(bytes32(uint256(1)), ra, boss, 2 ether, carol);
        extra.push(c);
        assertEq(boss.balanceOf(carol), blowBoss);
        assertEq(_killer(1), carol);
        assertEq(hook.damage(1, carol), blowDmg);
        _assertSums();
        assertAccounting();
    }

    /// @dev Expected (README Known limits / `_hopBlow` NatSpec: "A contract (a router, an aggregator, a smart
    /// account) hands the blow on first, so BOSS anyone planted on it never holds the blow back"). Actual:
    /// while its constructor runs a contract has no code, so `_hopBlow` applies the wallet rule (older BOSS
    /// first: out = held - balanceOf). Eve sends BOSS to the contract's CREATE2 address before it exists; the
    /// contract forwards every wei of the blow to carol, but the blow's credit and the killer prize stay on
    /// the contract, which has no way to claim or move them (review-5 F3 again, for one-shot contracts).
    function test_r6_F1_limit_plantedCtorForwarder_keepsTheBlow() public {
        (uint256 blowBoss, uint256 blowDmg) = _measureBlow();
        bytes32 salt = bytes32(uint256(1));
        address c = cf.predict(salt, ra, boss, 2 ether, carol);
        extra.push(c);
        uint256 plant = _plantOf(blowBoss);
        giveBoss(eve, plant);
        vm.prank(eve);
        boss.transfer(c, plant); // tx 1: the plant at a counterfactual address

        vm.prank(carol, carol);
        assertEq(cf.deploy(salt, ra, boss, 2 ether, carol), c); // tx 2: carol's kill
        console2.log("F1 blow BOSS carol received / blow:", boss.balanceOf(carol), blowBoss);
        console2.log("F1 credit carol / contract:", hook.damage(1, carol), hook.damage(1, c));
        console2.log("F1 prize stuck on the contract:", hook.unclaimedKill(c));
        if (useNative()) {
            (bool ok,) = address(hook).call(abi.encodeCall(BossHook.claimKill, (c)));
            console2.log("F1 native: claimKill(contract) succeeds:", ok);
        }
        _assertSums();
        assertAccounting();
        assertEq(boss.balanceOf(carol), blowBoss, "carol received every wei of the blow");
        // Documented limit (README, Known limits): a contract that trades from its constructor has no code
        // yet and is treated as a wallet, so BOSS planted on its address beforehand holds the blow back.
        // Griefing only: the planter gains nothing. Deployed contracts, 4337 accounts and 7702 wallets
        // are not affected (review 5's F3 probes).
        assertEq(_killer(1), c, "documented limit: the constructor-time forwarder keeps the prize");
        assertLt(hook.damage(1, carol), blowDmg, "documented limit: and some or all of the blow's credit");
    }

    // =================================================================== I1. documented limit, measured: a 7702 killer's BOSS fee takes the whole prize

    /// @dev Last hit: alice leaves the boss at 0.01; the killer buys 0.02 through `ra` with the output to
    /// itself and then pays `fee` BOSS it held from before (a relayer / paymaster / app fee) to `relayer`.
    function _lastHitThenFee(bool as7702) internal returns (uint256 blowBoss, uint256 blowDmg, address killer) {
        buyExactIn(alice, 0.99 ether);
        assertEq(hook.hp(), 0.01 ether);
        killer = as7702 ? w7 : dave;
        uint256 snap = vm.snapshotState();
        vm.prank(bob, bob);
        ra.run(_buyTake(0.02 ether, bob));
        uint256 lastHit = boss.balanceOf(bob);
        vm.revertToState(snap);
        uint256 fee = _plantOf(lastHit); // a fee about the size of the last hit
        giveBoss(killer, fee); // older BOSS (no credit this round)
        if (as7702) {
            _delegate7702();
            BatchWallet.Call[] memory calls = new BatchWallet.Call[](2);
            calls[0] = BatchWallet.Call(address(ra), _run(_buyTake(0.02 ether, w7)));
            calls[1] = BatchWallet.Call(address(boss), abi.encodeWithSignature("transfer(address,uint256)", relayer, fee));
            vm.prank(w7, w7);
            BatchWallet(payable(w7)).exec(calls);
        } else {
            vm.prank(dave, dave);
            ra.multi(_c2(_run(_buyTake(0.02 ether, dave)), _pull(dave, relayer, fee)));
        }
        assertEq(hook.round(), 2, "the 0.02 buy killed");
        blowBoss = boss.balanceOf(killer);
        blowDmg = hook.damage(1, killer) + hook.damage(1, relayer);
        console2.log("I1 fee in older BOSS / blow BOSS:", fee, boss.balanceOf(killer) + boss.balanceOf(relayer) - fee);
        console2.log("I1 killer credit / relayer credit:", hook.damage(1, killer), hook.damage(1, relayer));
        console2.log("I1 prize holder is the relayer:", _killer(1) == relayer);
        _assertSums();
        assertAccounting();
    }

    /// The same intent from a wallet without code: the older-BOSS fee never takes the blow (README claim).
    function test_r6_I1_eoaKiller_olderFee_keepsPrize() public {
        (,, address k) = _lastHitThenFee(false);
        assertEq(_killer(1), k);
        assertEq(hook.damage(1, relayer), 0);
    }

    /// @dev README: "A smart account or an EIP-7702 wallet that kills and then pays with older BOSS in the
    /// same transaction therefore hands the blow on with that payment." Measured: with a last hit, any fee
    /// of older BOSS at least the size of the (small) blow carries ALL of the blow's credit and the whole
    /// killer prize to the fee recipient. Asserted as documented (PASS = the limit is as wide as this).
    function test_r6_I1_7702Killer_olderFee_prizeGoesToFeeRecipient_documented() public {
        (, uint256 blowDmg,) = _lastHitThenFee(true);
        assertEq(_killer(1), relayer, "documented: the fee recipient takes the prize");
        assertEq(hook.damage(1, relayer), blowDmg, "and every wei of the blow's credit");
        assertGt(_prize(1), 0);
    }

    // =================================================================== P. what holds (expected PASS)

    /// @dev The killer is an EOA; eve plants BOSS on her in an earlier tx and again in the middle of the
    /// bundle; the killer sends older BOSS to dave, to the pool (router sale) and to the hook, and a
    /// self-transfer. She keeps every wei of the blow's credit and the prize; nobody else gets closed credit.
    function test_r6_P1_eoaKiller_plantsBeforeAndDuring_keepsBlow() public {
        (uint256 blowBoss, uint256 blowDmg) = _measureBlow();
        uint256 p = _plantOf(blowBoss) / 4;
        giveBoss(carol, p);
        giveBoss(eve, p);
        address[] memory t = new address[](7);
        bytes[] memory c = new bytes[](7);
        t[0] = address(rb);
        c[0] = _run(_buyTake(2 ether, carol)); // the kill, delivered to carol
        t[1] = address(rb);
        c[1] = _pull(eve, carol, p); // mid-bundle plant
        t[2] = address(rb);
        c[2] = _pull(carol, carol, MAX); // self-transfer
        t[3] = address(rb);
        c[3] = _pull(carol, dave, p / 2);
        t[4] = address(ra);
        c[4] = abi.encodeCall(R3Router.multi, (_c2(_pull(carol, address(ra), p / 2), _run(_sellOwnAll()))));
        t[5] = address(rb);
        c[5] = _pull(carol, address(hook), p / 2);
        t[6] = address(rb);
        c[6] = _pull(carol, alice, p / 2);
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(t, c);
        assertEq(_killer(1), carol);
        assertEq(hook.damage(1, carol), blowDmg);
        assertEq(boss.balanceOf(carol), blowBoss);
        _assertSums();
        assertAccounting();
    }

    function _sellOwnAll() internal pure returns (R3Router.Action[] memory s) {
        s = new R3Router.Action[](1);
        s[0] = R3Router.Action(R3Router.Kind.SellOwnShare, address(0), 0, 1, 1);
    }

    /// @dev A 7702 killer that holds older BOSS: a self-transfer moves nothing, the blow then goes on in
    /// proportion, blow first; sends to the hook leave the credit with it (held by nobody). No revert.
    function test_r6_P2_7702Killer_selfTransferAndSink_noRevert() public {
        (uint256 blowBoss,) = _measureBlow();
        uint256 older = _plantOf(blowBoss);
        giveBoss(w7, older);
        _delegate7702();
        BatchWallet.Call[] memory calls = new BatchWallet.Call[](4);
        calls[0] = BatchWallet.Call(address(ra), _run(_buyTake(2 ether, w7)));
        calls[1] = BatchWallet.Call(address(boss), abi.encodeWithSignature("transfer(address,uint256)", w7, older));
        calls[2] = BatchWallet.Call(address(boss), abi.encodeWithSignature("transfer(address,uint256)", address(hook), older / 4));
        calls[3] = BatchWallet.Call(address(boss), abi.encodeWithSignature("transfer(address,uint256)", carol, older / 2));
        vm.prank(w7, w7);
        BatchWallet(payable(w7)).exec(calls);
        assertEq(hook.round(), 2);
        assertGt(hook.damage(1, carol), 0, "blow first from a wallet with code");
        _assertSums();
        assertAccounting();
    }

    // =================================================================== D. fuzz: EOAs, a 7702 wallet, contracts, constructors

    function _who(uint256 i) internal view returns (address) {
        address[8] memory ws = [alice, carol, dave, eve, w7, address(ra), address(fwd), relayer];
        return ws[i % 8];
    }

    function _eoa(uint256 i) internal view returns (address) {
        address[4] memory e = [alice, carol, dave, eve];
        return e[i % 4];
    }

    function _stepD(uint256 r, uint256 unit, uint256 i) internal returns (address, bytes memory) {
        uint256 kind = r % 9;
        R5Router who = (r >> 8) % 2 == 0 ? ra : rb;
        address to = _who(r >> 16);
        uint256 q = 0.01 ether + (r >> 24) % 1.6 ether;
        uint256 b = unit * (1 + (r >> 40) % 300) / 100;
        if (kind == 0) return (address(who), _run(_buyTake(q, to)));
        if (kind == 1) return (address(who), _pull(_eoa(r >> 20), to, b));
        if (kind == 2) return (w7, abi.encodeCall(BatchWallet.send, (boss, to, b)));
        if (kind == 3) return (address(who), abi.encodeCall(R3Router.forward, (to, b)));
        if (kind == 4) return (w7, abi.encodeCall(BatchWallet.send, (boss, address(hook), b / 4)));
        if (kind == 5) return (address(who), _pull(_eoa(r >> 20), address(hook), b / 4));
        if (kind == 6) {
            return (address(who), abi.encodeCall(R3Router.multi, (_c2(_pull(_eoa(r >> 20), address(who), b), _run(_sellOwnAll())))));
        }
        if (kind == 7) {
            bytes32 salt = keccak256(abi.encode(r, i));
            extra.push(cf.predict(salt, who, boss, q, to));
            return (address(cf), abi.encodeCall(CtorFactory.deploy, (salt, who, boss, q, to)));
        }
        return (address(who), abi.encodeCall(R3Router.tryClaimDamage, (uint64(1 + (r >> 48) % 2), _who(r >> 52))));
    }

    function _fuzzD(uint256 seed, uint8 steps, uint8 signerSel) internal {
        _delegate7702();
        buyExactIn(alice, 0.2 ether);
        uint256 unit = boss.balanceOf(alice);
        uint256 per = unit;
        uint256 have = boss.balanceOf(address(this));
        if (per * 17 > have) per = have / 17;
        giveBoss(address(ra), per * 3);
        giveBoss(address(rb), per * 3);
        giveBoss(address(fwd), per * 2);
        giveBoss(carol, per * 2);
        giveBoss(dave, per * 2);
        giveBoss(eve, per * 2);
        giveBoss(w7, per * 3);
        steps = uint8(bound(steps, 1, 14));
        address[] memory t = new address[](steps);
        bytes[] memory c = new bytes[](steps);
        uint256 r = seed;
        for (uint256 i = 0; i < steps; i++) {
            r = uint256(keccak256(abi.encode(r, i)));
            (t[i], c[i]) = _stepD(r, unit, i);
        }
        address[4] memory signers = [bundlerEOA, carol, w7, eve];
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

    function test_r6_D0_generatorCoverage() public {
        uint256 kills;
        uint256 failed;
        for (uint256 k = 0; k < 40; k++) {
            uint256 snap = vm.snapshotState();
            _fuzzD(uint256(keccak256(abi.encode("r6", k))), 14, uint8(k));
            if (hook.round() > 1) kills++;
            failed += lenient.failures().length;
            delete extra;
            vm.revertToState(snap);
        }
        console2.log("D0 txs with a kill / failed steps of 560", kills, failed);
        assertGt(kills, 10, "the generator closes rounds");
    }

    function testFuzz_r6_D1_mixedSenders_noPanic_booksClose(uint256 seed, uint8 steps, uint8 signerSel) public {
        _fuzzD(seed, steps, signerSel);
    }
}

contract Review6BossFirstTest is Review6Base {}

contract Review6BossSecondTest is Review6Base {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

contract Review6NativeTest is Review6Base {
    function useNative() internal pure override returns (bool) {
        return true;
    }
}
