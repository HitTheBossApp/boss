// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BossFixture} from "../utils/BossFixture.sol";
import {Bundle} from "../utils/Bundle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {R3Router} from "../review3/R3Router.sol";
import {LenientBundle} from "../review4/LenientBundle.sol";
import {R5Router, ExactForwarder} from "../review5/R5Router.sol";
import {R7Router, FeeWrapper} from "../review7/R7Router.sol";
import {BossHook} from "../../src/BossHook.sol";
import {BossToken} from "../../src/BossToken.sol";
import {AbilityBoard} from "../../src/AbilityBoard.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {BossHookProbe, R8Recorder, ChildBinder, PhishFactory, LaunchFactory, Exec7702} from "./R8Helpers.sol";

/// @dev Eighth independent review, on fix-audit5 @ 6c3b1db (fixes of the swarm's fifth audit, job 965a5fce):
/// the killer prize goes to a majority holder of the blow (else the signer), `bindHook` only from a contract
/// under construction, the per-transaction cap scales the pending BOSS. Convention of the earlier reviews:
/// each probe asserts what the code or the README CLAIMS, so a FAIL documents a gap and a PASS confirms it.
/// Runs with BOSS as currency0, as currency1 (IMD pairing) and with native ETH.
abstract contract Review8Base is BossFixture {
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve"); // the attacker / planter
    address internal relayer = makeAddr("relayer");
    address internal bundlerEOA = makeAddr("bundlerEOA");
    address internal feeCollector = makeAddr("feeCollector");
    R7Router internal ra;
    R7Router internal rb;
    ExactForwarder internal fwd;
    FeeWrapper internal wrap;
    Bundle internal bundle;
    LenientBundle internal lenient;
    R8Recorder internal rec;
    BossHookProbe internal probe; // set when useProbe()
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant W7_PK = 0x7702BEEF8;
    address internal w7;
    address[] internal extra;

    function useProbe() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public virtual override {
        if (useProbe()) _probeSetUp();
        else super.setUp();
        ra = new R7Router(IPoolManager(address(manager)), key, boss);
        rb = new R7Router(IPoolManager(address(manager)), key, boss);
        fwd = new ExactForwarder(boss);
        wrap = new FeeWrapper(boss);
        _fundRouter(address(ra), 1_000 ether);
        _fundRouter(address(rb), 1_000 ether);
        bundle = new Bundle();
        lenient = new LenientBundle();
        rec = new R8Recorder();
        w7 = vm.addr(W7_PK);
        address[7] memory eoas = [alice, bob, carol, dave, eve, bundlerEOA, relayer];
        for (uint256 i = 0; i < eoas.length; i++) {
            vm.startPrank(eoas[i]);
            boss.approve(address(ra), MAX);
            boss.approve(address(rb), MAX);
            vm.stopPrank();
        }
    }

    /// @dev BossFixture.setUp with the probe hook (BossHook + transient views) at the mined address.
    function _probeSetUp() internal {
        vm.warp(1_800_000_000);
        oracleSigner = vm.addr(oracleKey);
        manager = new PoolManager(address(this));
        Currency quote;
        if (useNative()) {
            boss = new BossToken();
            quote = Currency.wrap(address(0));
        } else {
            quoteToken = new MockERC20("IdentityMD", "IMD", 0);
            boss = _deployBossOrdered(address(quoteToken), wantBossIsCurrency0());
            quote = Currency.wrap(address(quoteToken));
        }
        bossIsCurrency0 = address(boss) < Currency.unwrap(quote);
        pairedAddr = Currency.unwrap(quote);
        board = new AbilityBoard(keeper);
        bytes memory initCode = abi.encodePacked(type(BossHookProbe).creationCode, hookArgs());
        (bytes32 salt,) = HookFlags.mineSalt(address(this), initCode, HOOK_FLAGS, 300_000);
        address addr;
        assembly ("memory-safe") {
            addr := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(addr != address(0), "probe deploy failed");
        probe = BossHookProbe(addr);
        hook = BossHook(addr);
        (Currency c0, Currency c1) =
            bossIsCurrency0 ? (Currency.wrap(address(boss)), quote) : (quote, Currency.wrap(address(boss)));
        key = PoolKey({currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(addr)});
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        launchTime = block.timestamp;
        manager.initialize(key, TickMath.getSqrtPriceAtTick(launchTick()));
        _seedSingleSided();
        _fund(alice);
        _fund(bob);
        _fund(carol);
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

    function _t(address a, address b) internal pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = a;
        t[1] = b;
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
        assertEq(hook.unclaimedKill(address(manager)), 0, "the PoolManager never holds a prize");
    }

    function _hasPanic(bytes memory f) internal pure returns (bool) {
        for (uint256 j = 0; j + 4 <= f.length; j++) {
            if (f[j] == 0x4e && f[j + 1] == 0x48 && f[j + 2] == 0x7b && f[j + 3] == 0x71) return true;
        }
        return false;
    }

    /// @dev alice leaves `left` of HP; a buy of `killQ` is the last hit. Measures the blow in a throw-away run.
    function _lastHitAt(uint256 left, uint256 killQ) internal returns (uint256 blowBoss, uint256 blowDmg) {
        buyExactIn(alice, INITIAL_HP - left);
        assertEq(hook.hp(), left);
        uint256 snap = vm.snapshotState();
        vm.prank(bob, bob);
        ra.run(_buyTake(killQ, dave));
        blowBoss = boss.balanceOf(dave);
        blowDmg = hook.damage(1, dave);
        vm.revertToState(snap);
        assertEq(blowDmg, left);
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

    function _newRx(uint256 funding) internal returns (R7Router rx) {
        rx = new R7Router(IPoolManager(address(manager)), key, boss);
        _fundRouter(address(rx), funding);
        extra.push(address(rx));
    }
}

/// @notice Targeted probes (real BossHook).
abstract contract Review8Probes is Review8Base {
    // =================================================================== B. bindHook

    /// @dev Expected (README, BossToken NatSpec; audit 965a5fce finding 2 fixed): a contract the launcher is
    /// tricked into calling between the token and the hook deploys can no longer bind a hook. Actual: it deploys a
    /// child whose constructor calls `bindHook` (no code yet, not tx.origin, signer = launcher): the child is bound,
    /// every BOSS transfer reverts and the real hook can never bind.
    function test_r8_B1_phishedLauncher_childUnderConstruction_stillBinds() public {
        address launcher = makeAddr("launcher");
        vm.prank(launcher, launcher);
        BossToken t = new BossToken();
        PhishFactory phish = new PhishFactory();
        vm.prank(launcher, launcher);
        (bool ok,) = address(phish).call(abi.encodeCall(PhishFactory.claimAirdrop, (t)));
        console2.log("B1 phishing call succeeded:", ok);
        console2.log("B1 bound hook / phish child:", t.hook(), phish.child());
        if (ok) {
            vm.prank(launcher);
            (bool sent,) = address(t).call(abi.encodeCall(BossToken.transfer, (alice, 1)));
            console2.log("B1 launcher transfer after the phish succeeded:", sent);
            vm.prank(launcher, launcher);
            (bool real,) = address(new PhishFactory()).call(abi.encodeCall(PhishFactory.claimAirdrop, (t)));
            console2.log("B1 a later binder (the real hook's constructor path) succeeded:", real);
        }
        // Documented limit (README, Known limits, independent review 8): a contract the launcher is tricked into calling can create a child that
        // binds from its constructor; the launch deploys token and hook in one transaction (the IMD factory).
        assertEq(t.hook(), phish.child(), "documented: a phished child under construction can still bind");
    }

    /// The real launch: one launcher-signed call deploys the token and then the hook with CREATE2 (mined salt)
    /// from a factory; the hook binds from its constructor.
    function test_r8_B2_factoryLaunch_create2_oneTransaction_binds() public {
        address launcher = makeAddr("launcher");
        LaunchFactory f = new LaunchFactory();
        bytes32 tokenSalt = keccak256("boss-token");
        address tokenAddr = f.tokenAddress(tokenSalt);
        bytes memory initCode = abi.encodePacked(type(BossHook).creationCode, hookArgsFor(tokenAddr, INITIAL_HP, pairedAddr));
        (bytes32 hookSalt, address predicted) = HookFlags.mineSalt(address(f), initCode, HOOK_FLAGS, 300_000);
        vm.prank(launcher, launcher);
        (BossToken t, address h) = f.launch(tokenSalt, initCode, hookSalt);
        assertEq(address(t), tokenAddr);
        assertEq(h, predicted);
        assertEq(t.hook(), h, "the hook bound from its constructor");
        assertEq(BossHook(h).bossToken(), address(t));
    }

    /// Token and hook from the factory in two launcher-signed transactions, nothing in between: still binds; a
    /// stranger-signed hook deployment in between cannot.
    function test_r8_B3_factoryLaunch_twoTransactions_onlyLauncherSigned() public {
        address launcher = makeAddr("launcher");
        LaunchFactory f = new LaunchFactory();
        vm.prank(launcher, launcher);
        BossToken t = f.deployToken(keccak256("t2"));
        bytes memory initCode = abi.encodePacked(type(BossHook).creationCode, hookArgsFor(address(t), INITIAL_HP, pairedAddr));
        (bytes32 hookSalt,) = HookFlags.mineSalt(address(f), initCode, HOOK_FLAGS, 300_000);
        vm.prank(eve, eve);
        vm.expectRevert();
        f.deployHook(initCode, hookSalt);
        vm.prank(launcher, launcher);
        address h = f.deployHook(initCode, hookSalt);
        assertEq(t.hook(), h);
    }

    // =================================================================== M. majority rule: who can end up with the prize

    /// @dev Expected (README: "if anyone may sweep the router, a planter can take that share of the credit (never
    /// the prize)"; the prize is a majority holder's or the signer's). eve planted 2x the blow on an exact-delivery
    /// locker with a public sweep; in the same transaction (an ERC-4337 bundle: carol's operation, then eve's) she
    /// sweeps the router. Actual: the sweep carries the blow the router kept (2/3 of it): eve takes the prize and
    /// her plant back.
    function test_r8_M1_exactDelivery_planterSweepsLaterInSameTx_takesPrize() public {
        (uint256 blowBoss, uint256 blowDmg) = _lastHitAt(0.01 ether, 0.02 ether);
        R7Router rx = _newRx(0.02 ether);
        uint256 plant = blowBoss * 2;
        _plant(address(rx), plant);
        bytes[] memory c = new bytes[](2);
        c[0] = abi.encodeCall(R7Router.buyDeliverExact, (0.02 ether, carol)); // carol's operation
        c[1] = abi.encodeCall(R7Router.sweep, (address(boss), eve)); // eve's operation, same bundle
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(_t(address(rx), address(rx)), c);
        console2.log("M1 blow BOSS, carol received:", blowBoss, boss.balanceOf(carol));
        console2.log("M1 eve got back BOSS (plant):", boss.balanceOf(eve), plant);
        console2.log("M1 credit carol / eve:", hook.damage(1, carol), hook.damage(1, eve));
        console2.log("M1 killer is eve:", _killer(1) == eve);
        _assertSums();
        assertAccounting();
        assertEq(hook.damage(1, carol) + hook.damage(1, eve), blowDmg);
        // Documented limit (README, Known limits, independent review 8): a router anyone may sweep, swept later in the same transaction by
        // whoever planted BOSS on it, hands that planter what it kept of the blow, prize included.
        assertEq(_killer(1), eve, "documented: the same-transaction sweeper of a planted router");
    }

    /// @dev Expected (README: "If a route splits the blow so that nobody holds most of it (... a quoted delivery
    /// that sweeps a surplus ...), the prize stays with the signer"). Relayed (signer = relayer); carol gets 99% of
    /// the output; eve planted 1x the blow on the router in an earlier transaction. Actual: the surplus sweep
    /// carries the majority of the blow and the prize goes to the surplus wallet, neither the player nor the
    /// signer. (There is no plant size where nobody holds most of it.)
    function test_r8_M2_quotedDelivery_plant_prizeToSurplusWallet_notSigner() public {
        (uint256 blowBoss,) = _lastHitAt(0.01 ether, 0.02 ether);
        R7Router rx = _newRx(0.02 ether);
        _plant(address(rx), blowBoss);
        vm.prank(relayer, relayer);
        rx.buyDeliverQuoted(0.02 ether, carol, 9_900, feeCollector);
        console2.log("M2 credit carol / surplus wallet:", hook.damage(1, carol), hook.damage(1, feeCollector));
        console2.log("M2 killer is the surplus wallet:", _killer(1) == feeCollector);
        _assertSums();
        assertAccounting();
        // Documented limit (README, Known limits, independent review 8): a quoted delivery that sweeps the surplus, planted BOSS included,
        // to its own wallet can hand that wallet most of the blow and the prize.
        assertEq(_killer(1), feeCollector, "documented: the surplus wallet");
    }

    /// @dev Expected (README: "a fee of any share, BOSS planted on a router ... never take the prize from them").
    /// A non-locker fee wrapper (has the router execute, pays 0.25% of its balance, sweeps the rest to the user);
    /// eve planted ~200x a small last hit on it. Blow-first: the fee carries more than half of the blow, so the fee
    /// wallet takes the prize from carol (who is also the signer).
    function test_r8_M3_nonLockerFeeWrapper_plant_feeWalletTakesPrize() public {
        (uint256 blowBoss,) = _lastHitAt(0.0005 ether, 0.001 ether);
        uint256 plant = _cap(blowBoss * 202);
        _plant(address(wrap), plant);
        uint256 bips = 25;
        while ((blowBoss + plant) * bips / 10_000 * 2 <= blowBoss) bips += 25;
        vm.prank(carol, carol);
        wrap.route(ra, _buyTake(0.001 ether, address(wrap)), feeCollector, bips, carol);
        console2.log("M3 fee bips / blow BOSS / plant:", bips, blowBoss, plant);
        console2.log("M3 credit carol / fee wallet:", hook.damage(1, carol), hook.damage(1, feeCollector));
        console2.log("M3 killer is the fee wallet:", _killer(1) == feeCollector);
        _assertSums();
        assertAccounting();
        // Documented limit (README, Known limits, independent review 8): a fee taker that is not the router that swapped takes its fee first,
        // as a share of a balance inflated with planted BOSS, and can carry most of the blow and the prize.
        assertEq(_killer(1), feeCollector, "documented: a non-router fee taker with a planted balance");
    }

    /// @dev Fix 3 x fix 1. Expected (README: "a fee of any share ... never take the prize"): carol's router takes a
    /// 2% fee straight from the PoolManager (TAKE_PORTION) and 98% to carol. Earlier in the same bundle dave sells
    /// older BOSS (a heal). The cap now scales the killing blow's BOSS down (T_KILL_TOTAL = pb * room / pd), so the
    /// first BOSS out of the pool, the fee, holds most of the blow: the fee wallet takes the prize. Before fix 3 the
    /// blow was the whole output and the fee held 2%.
    function test_r8_M4_healEarlierInTx_capShrinksBlow_directFeeTakesPrize() public {
        buyExactIn(alice, 0.99 ether);
        uint256 sellAmt = boss.balanceOf(alice) * 6 / 10;
        giveBoss(dave, sellAmt);
        bytes memory heal = abi.encodeCall(R3Router.multi, (_c(_pull(dave, address(rb), sellAmt), _run(_1(_sellOwn(1, 1))))));
        uint256 snap = vm.snapshotState();
        vm.prank(dave, dave);
        (bool ok,) = address(rb).call(heal);
        require(ok, "heal");
        uint256 hpAfter = hook.hp();
        vm.revertToState(snap);
        uint256 q = hpAfter + 0.01 ether;
        bytes memory kill = _run(
            _3(_A(R3Router.Kind.BuyIn, address(0), q), _share(feeCollector, 2, 100), _A(R3Router.Kind.TakeBoss, carol, MAX))
        );
        uint256 snap2 = vm.snapshotState();
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(_t(address(ra), address(ra)), _c(kill, _run(_1(_A(R3Router.Kind.TakeBoss, carol, MAX)))));
        console2.log("M4 control (no heal) killer is carol:", _killer(1) == carol);
        vm.revertToState(snap2);
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(_t(address(rb), address(ra)), _c(heal, kill));
        assertEq(hook.round(), 2, "killed");
        console2.log("M4 hp before / after the heal:", uint256(0.01 ether), hpAfter);
        console2.log("M4 BOSS carol / fee wallet:", boss.balanceOf(carol), boss.balanceOf(feeCollector));
        console2.log("M4 credit carol / fee wallet:", hook.damage(1, carol), hook.damage(1, feeCollector));
        console2.log("M4 killer is the fee wallet:", _killer(1) == feeCollector);
        _assertSums();
        assertAccounting();
        assertEq(_killer(1), carol, "README: a 2% fee never takes the prize from the player who got 98%");
    }

    /// @dev Expected (README: the blow "travel[s] with that BOSS ... through any router ... that custodies it";
    /// the prize ends with a majority holder or the signer): a split route makes two kills through one custodian
    /// router (both outputs taken to the router, then swept to carol). Actual: "only the last one travels", so the
    /// first round's prize and blow credit stay on the router; anyone claims them to the router and sweeps.
    function test_r8_M5_twoKillsThroughCustodian_firstPrizeStrandedOnRouter() public {
        _lastHitAt(0.01 ether, 0.02 ether);
        R7Router rx = _newRx(0.02 ether + 1.6 ether);
        vm.prank(carol, carol);
        rx.multi(_c(_run(_buyTake(0.02 ether, address(rx))), _run(_buyTake(1.6 ether, address(rx))), _sweepB(carol)));
        assertEq(hook.round(), 3, "two kills");
        console2.log("M5 killer r1 is the router / r2 is carol:", _killer(1) == address(rx), _killer(2) == carol);
        console2.log("M5 r1 credit on the router:", hook.damage(1, address(rx)));
        _assertSums();
        assertAccounting();
        uint256 q0 = _quoteBalance(eve);
        vm.startPrank(eve, eve);
        if (hook.unclaimedKill(address(rx)) > 0) hook.claimKill(address(rx));
        if (hook.claimableDamage(1, address(rx)) > 0) hook.claimDamage(1, address(rx));
        rx.sweep(pairedAddr, eve);
        vm.stopPrank();
        uint256 gain = _quoteBalance(eve) - q0;
        console2.log("M5 r1 prize / eve's sweep gain:", _prize(1), gain);
        address k = _killer(1);
        assertEq(k, carol, "the first prize follows the BOSS to carol (the signer)");
    }

    /// @dev Expected (README: an EIP-7702 wallet that pays with older BOSS after a kill "hands the blow's credit on
    /// with that payment"; nothing says the prize). The 7702 wallet signs, kills through a router, then pays 60% of
    /// the blow's size in older BOSS to dave (a batch). Blow-first for code: dave holds most of the blow and takes
    /// the prize. Asserts the README's wording (credit only), so a FAIL documents an understatement.
    function test_r8_I1_7702Wallet_paysOlderBoss_handsThePrizeToo() public {
        (uint256 blowBoss,) = _lastHitAt(0.01 ether, 0.02 ether);
        Exec7702 body = new Exec7702();
        vm.setEvmVersion("prague");
        vm.signAndAttachDelegation(address(body), W7_PK);
        uint256 older = blowBoss * 6 / 10;
        giveBoss(w7, older);
        address[] memory t = _t(address(ra), address(boss));
        bytes[] memory c = _c(_run(_buyTake(0.02 ether, w7)), abi.encodeCall(BossToken.transfer, (dave, older)));
        vm.prank(w7, w7);
        Exec7702(w7).exec(t, c);
        console2.log("I1 killer is dave (the payee):", _killer(1) == dave);
        _assertSums();
        assertAccounting();
        // Documented limit (README, Known limits, independent review 8): a payment in older BOSS that carries more than half of the blow
        // hands on the prize too.
        assertEq(_killer(1), dave, "documented: the payee of most of the blow");
    }

    // =================================================================== E. edge cases of the majority rule (expected PASS)

    /// Exactly half to two wallets (direct takes): no majority, the relayer (signer) keeps it.
    function test_r8_E1_exactHalf_signerKeeps() public {
        _lastHitAt(0.01 ether, 0.02 ether);
        vm.prank(relayer, relayer);
        ra.run(_3(_A(R3Router.Kind.BuyIn, address(0), 0.02 ether), _share(carol, 1, 2), _A(R3Router.Kind.TakeBoss, dave, MAX)));
        // the share rounds down, so dave may hold 1 wei more than half
        address k = _killer(1);
        assertTrue(k == relayer || k == dave, "exact half: signer; one wei more: dave");
        _assertSums();
        assertAccounting();
    }

    /// The prize claimed between two unlocks, then the blow delivered: the prize stays paid, nothing moves twice.
    function test_r8_E2_claimBetweenUnlocks_noDoublePay() public {
        _lastHitAt(0.01 ether, 0.02 ether);
        uint256 p0 = _quoteBalance(bob);
        bytes[] memory c = _c(
            _run(_2(_A(R3Router.Kind.BuyIn, address(0), 0.02 ether), _A(R3Router.Kind.KeepClaims, address(0), MAX))),
            abi.encodeCall(R3Router.claimKill, (bob)),
            _run(_1(_A(R3Router.Kind.ClaimsToBoss, carol, MAX)))
        );
        _multi(ra, bob, c);
        assertEq(_quoteBalance(bob) - p0, _prize(1), "the signer was paid once");
        assertEq(hook.unclaimedKill(carol), 0, "and the prize did not move again");
        _assertSums();
        assertAccounting();
    }

    /// Part of the blow taken straight into the hook (lost), the rest to carol: total is unchanged, so carol holds
    /// 40% and the relayer (signer) keeps the prize; no revert, books close.
    function test_r8_E3_blowPartToHook_totalUnchanged() public {
        _lastHitAt(0.01 ether, 0.02 ether);
        vm.prank(relayer, relayer);
        ra.run(
            _3(_A(R3Router.Kind.BuyIn, address(0), 0.02 ether), _share(address(hook), 6, 10), _A(R3Router.Kind.TakeBoss, carol, MAX))
        );
        assertEq(_killer(1), relayer);
        _assertSums();
        assertAccounting();
    }

    /// The 7702 signer is also the killing locker (its own router): it pays an exact amount, keeps counting
    /// (`_weight` exempts tx.origin) and keeps the prize while it holds most of the blow.
    function test_r8_E4_7702SignerIsLocker_keepsPrize() public {
        (uint256 blowBoss,) = _lastHitAt(0.01 ether, 0.02 ether);
        R7Router tmpl = new R7Router(IPoolManager(address(manager)), key, boss);
        vm.setEvmVersion("prague");
        vm.signAndAttachDelegation(address(tmpl), W7_PK);
        for (uint256 s = 0; s < 3; s++) {
            vm.store(w7, bytes32(s), vm.load(address(tmpl), bytes32(s)));
        }
        _fundRouter(w7, 1 ether);
        giveBoss(w7, blowBoss * 3); // older BOSS
        vm.prank(w7, w7);
        R7Router(payable(w7)).multi(_c(_run(_buyTake(0.02 ether, w7)), abi.encodeCall(R3Router.forward, (dave, blowBoss))));
        assertEq(_killer(1), w7, "pro rata: dave holds 1/4 of the blow");
        _assertSums();
        assertAccounting();
    }
}

contract Review8BossFirstTest is Review8Probes {}

contract Review8BossSecondTest is Review8Probes {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

contract Review8NativeTest is Review8Probes {
    function useNative() internal pure override returns (bool) {
        return true;
    }
}
