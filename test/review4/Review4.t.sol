// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FixedAbility} from "../mocks/Abilities.sol";
import {BossFixture} from "../utils/BossFixture.sol";
import {Bundle} from "../utils/Bundle.sol";
import {R3Router} from "../review3/R3Router.sol";
import {R4Router} from "./R4Router.sol";
import {LenientBundle} from "./LenientBundle.sol";

/// @dev Fourth independent review, on fix-audit2 @ c657e38. Same convention as reviews 1-3: each probe
/// asserts what the code or the README CLAIMS (or what the same trades give in separate transactions),
/// F1-F2 were fixed after this review (forfeits give back their cap room; a locker change trims the room
/// to the HP left), F3 asserts the corrected README sentence, and the fuzz checks net credit
/// (credited - forfeited) against the HP removed so far.
/// so a FAIL documents a gap and a PASS confirms the claim. Runs with BOSS as currency0, as currency1
/// (IMD pairing) and with native ETH.
abstract contract Review4Base is BossFixture {
    using stdStorage for StdStorage;

    address internal bundlerEOA = makeAddr("bundlerEOA");
    address internal bundlerWallet = makeAddr("bundlerWallet");
    R4Router internal ra; // a player's smart wallet that is also its own router (locker A)
    R4Router internal rb; // another party's router (locker B)
    Bundle internal bundle;
    LenientBundle internal lenient;
    uint256 internal constant MAX = type(uint256).max;

    bytes32 internal constant CREDITED = keccak256("Credited(uint64,address,uint256,uint256)");
    bytes32 internal constant KILLED = keccak256("BossKilled(uint64,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant FORFEITED = keccak256("Forfeited(uint64,address,uint256)");

    function setUp() public virtual override {
        super.setUp();
        ra = new R4Router(IPoolManager(address(manager)), key, boss);
        rb = new R4Router(IPoolManager(address(manager)), key, boss);
        _fundRouter(address(ra));
        _fundRouter(address(rb));
        bundle = new Bundle();
        lenient = new LenientBundle();
    }

    function _fundRouter(address r) internal {
        if (useNative()) vm.deal(r, 100 ether);
        else quoteToken.mint(r, 100 ether);
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

    function _run(R4Router, R3Router.Action[] memory s) internal pure returns (bytes memory) {
        return abi.encodeCall(R3Router.run, (s));
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
        w = new address[](10);
        w[0] = alice;
        w[1] = bob;
        w[2] = carol;
        w[3] = bundlerEOA;
        w[4] = bundlerWallet;
        w[5] = address(ra);
        w[6] = address(rb);
        w[7] = address(hook);
        w[8] = address(this);
        w[9] = address(manager);
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
        assertEq(hook.damage(r, address(hook)), 0, "the hook never holds credit");
        assertEq(hook.unclaimedKill(address(hook)), 0, "the hook never holds a prize");
    }

    function _bundle2(address t0, bytes memory c0, address t1, bytes memory c1) internal {
        address[] memory t = new address[](2);
        bytes[] memory c = new bytes[](2);
        t[0] = t0;
        c[0] = c0;
        t[1] = t1;
        c[1] = c1;
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(t, c);
    }

    function _setAbility(uint256 buyMult, uint256 sellMult) internal {
        stdstore.target(address(hook)).sig("activeAbility()").checked_write(
            address(new FixedAbility(buyMult, sellMult))
        );
    }

    // =================================================================== F1. the cap charges a forfeited sell twice

    /// @dev One player, one locker, one transaction: buy and take (credit d1), sell that BOSS from the
    /// wallet (a real transfer into the pool: d1 is forfeited, the boss heals h), buy again (d2).
    /// The same three trades as three transactions leave the wallet d2 of credit. In one transaction the
    /// heal is charged a second time through the cap: T_PEND_HP0 was lowered by the delivered d1 and is
    /// not raised back when d1 is forfeited, so the second buy only gets d2 - h.
    function test_r4_F1a_buyTakeSellBuy_inOneTx_sellChargedTwice() public {
        R3Router.Action[] memory buyTake = _buyTake(0.4 ether, address(ra));
        R3Router.Action[] memory sellAll = _1(_sellOwn(1, 1));

        uint256 snap = vm.snapshotState();
        vm.prank(bob, bob);
        ra.run(buyTake);
        vm.prank(bob, bob);
        ra.run(sellAll);
        vm.prank(bob, bob);
        ra.run(buyTake);
        uint256 sepDamage = hook.damage(1, address(ra));
        uint256 sepHp = hook.hp();
        vm.revertToState(snap);

        bytes[] memory calls = new bytes[](3);
        calls[0] = _run(ra, buyTake);
        calls[1] = _run(ra, sellAll);
        calls[2] = _run(ra, buyTake);
        vm.prank(bob, bob);
        ra.multi(calls);

        console2.log("F1a three txs: wallet damage", sepDamage);
        console2.log("F1a one tx:    wallet damage", hook.damage(1, address(ra)));
        console2.log("F1a hp (same in both)", hook.hp(), sepHp);
        assertEq(hook.hp(), sepHp, "same trades, same HP");
        _assertSums();
        assertAccounting();
        assertApproxEqAbs(
            hook.damage(1, address(ra)), sepDamage, 2, "same trades in one tx should keep the same credit (d2)"
        );
    }

    /// @dev The same double charge on a kill. The wallet holds credit from an earlier transaction, then in
    /// one transaction sells it (forfeited) and lands the killing blow: the blow is credited the HP the
    /// boss had BEFORE the sell, not the HP it removed. Two transactions credit the blow its full damage.
    function test_r4_F1b_sellOwnCreditThenKill_inOneTx_blowLosesTheHeal() public {
        vm.prank(bob, bob);
        ra.run(_buyTake(0.4 ether, address(ra))); // the wallet's credit: 0.4
        buyExactIn(alice, 0.3 ether); // hp 0.3
        R3Router.Action[] memory sellAll = _1(_sellOwn(1, 1));
        R3Router.Action[] memory kill = _buyTake(2 ether, address(ra));
        // One transaction's bound: the HP it can remove (all that is left) plus the credit it forfeits.
        uint256 txBound = hook.hp() + hook.damage(1, address(ra));

        uint256 snap = vm.snapshotState();
        vm.prank(bob, bob);
        ra.run(sellAll);
        uint256 hpBeforeKill = hook.hp();
        vm.prank(bob, bob);
        ra.run(kill);
        uint256 sepDamage = hook.damage(1, address(ra));
        uint256 sepAlice = hook.claimableDamage(1, alice);
        vm.revertToState(snap);

        bytes[] memory calls = new bytes[](2);
        calls[0] = _run(ra, sellAll);
        calls[1] = _run(ra, kill);
        vm.prank(bob, bob);
        ra.multi(calls);

        assertEq(_killer(1), address(ra));
        console2.log("F1b HP the killing buy removed", hpBeforeKill);
        console2.log("F1b two txs: blow credit / alice claimable", sepDamage, sepAlice);
        console2.log("F1b one tx:  blow credit / alice claimable", hook.damage(1, address(ra)), hook.claimableDamage(1, alice));
        _assertSums();
        assertAccounting();
        // Two transactions credit the blow the HP it removed; one transaction gets the same, capped at its own
        // bound (HP removed + credit forfeited). They differ only when the sold BOSS appreciated between rounds
        // of trading (native config: the heal exceeds the forfeit), the agreed proportional rule.
        uint256 expected = sepDamage < txBound ? sepDamage : txBound;
        assertApproxEqAbs(hook.damage(1, address(ra)), expected, 2, "the blow is credited the HP it removed, up to the bound");
    }

    // =================================================================== F2. heal day: voided leftovers become another locker's credit

    /// @dev On a day whose ability heals more per BOSS than a buy hits (here sells 4x), a buy followed by a
    /// flash sell of part of it leaves pending credit ABOVE the locker's own net damage; alone, the cap
    /// trims it to that net damage. In a bundle, the HP an earlier locker removed but never collected
    /// (its BOSS kept inside, its pending voided by `_scope`) is still counted in the cap's room, so the
    /// later locker is credited with it. README: "a swap by another router ... voids what is left of it, so
    /// one party's leftovers never merge into another party's swap or killing blow here".
    function test_r4_F2_healDay_laterLockerCreditedWithEarlierLockersVoidedDamage() public {
        _setAbility(10_000, 40_000);
        buyExactIn(alice, 0.1 ether);
        uint256 unit = boss.balanceOf(alice); // BOSS per 0.1 of quote at this price
        R3Router.Action[] memory bOps = _3(
            _A(R3Router.Kind.BuyOut, address(0), unit * 4),
            _A(R3Router.Kind.SellIn, address(0), unit * 4 / 5),
            _A(R3Router.Kind.TakeBoss, bundlerWallet, MAX)
        );
        uint256 hp0 = hook.hp();

        uint256 snap = vm.snapshotState();
        vm.prank(bundlerEOA, bundlerEOA);
        rb.run(bOps);
        uint256 soloCredit = hook.damage(1, bundlerWallet);
        uint256 soloNet = hp0 - hook.hp();
        vm.revertToState(snap);

        _bundle2(
            address(ra),
            _run(ra, _2(_A(R3Router.Kind.BuyIn, address(0), 0.3 ether), _A(R3Router.Kind.KeepClaims, address(0), MAX))),
            address(rb),
            _run(rb, bOps)
        );
        uint256 hpAfterA = hp0 - 0.3 ether;
        uint256 bNet = hpAfterA - hook.hp();
        console2.log("F2 B alone:   credit / own net HP removed", soloCredit, soloNet);
        console2.log("F2 A then B:  B credit / B net HP removed", hook.damage(1, bundlerWallet), bNet);
        console2.log("F2 A's voided damage (kept inside as claims)", uint256(0.3 ether));
        assertEq(hook.damage(1, address(ra)), 0, "A got nothing (its BOSS stayed inside)");
        _assertSums();
        assertAccounting();
        assertLe(hook.damage(1, bundlerWallet), bNet + 2, "README: A's voided leftovers never merge into B's swap");
    }

    // =================================================================== F3. README: "every heal in it included, in whatever order"

    /// @dev The cap bounds credit when it is delivered; a heal placed AFTER the delivery in the same
    /// transaction is not charged to it. Here the wallet buys and takes (credit d), then sells BOSS it
    /// holds from before (credit-free, so nothing is forfeited, the agreed low-7 rule): one transaction is
    /// credited d while it removed almost no HP. Same result as two transactions, so the impact is low 7;
    /// the README sentence is what is false.
    function test_r4_F3_healAfterDelivery_inSameTx_sameAsTwoTxs() public {
        uint256 snap = vm.snapshotState();
        vm.prank(bob, bob);
        ra.run(_buyTake(0.4 ether, carol));
        uint256 bought = boss.balanceOf(carol); // the BOSS a 0.4 buy yields here
        vm.revertToState(snap);

        giveBoss(address(ra), bought); // credit-free BOSS the wallet held from before
        uint256 h0 = hook.hp();
        bytes[] memory calls = new bytes[](2);
        calls[0] = _run(ra, _buyTake(0.4 ether, carol));
        calls[1] = _run(ra, _1(_A(R3Router.Kind.SellIn, address(0), bought)));
        vm.prank(bob, bob);
        ra.multi(calls);
        uint256 removed = h0 > hook.hp() ? h0 - hook.hp() : 0;
        console2.log("F3 credit created / HP the tx removed", hook.damage(1, carol), removed);
        _assertSums();
        assertAccounting();
        // README (corrected after this probe): the cap bounds credit by the HP removed up to the moment it
        // is delivered; a heal later in the transaction is not charged to it, exactly as in two transactions
        // (and selling credit-free BOSS forfeits nothing: the agreed low-7 rule).
        assertApproxEqAbs(hook.damage(1, carol), 0.4 ether, 2, "same credit as the buy alone");
    }

    // =================================================================== P. what holds (expected PASS)

    /// @dev A plain buy and take credits exactly the HP removed, exact-in and exact-out.
    function test_r4_P1_buyAndTake_creditEqualsHpRemoved_bothShapes() public {
        uint256 h0 = hook.hp();
        vm.prank(bob, bob);
        ra.run(_buyTake(0.3 ether, carol));
        assertEq(hook.damage(1, carol), h0 - hook.hp());
        uint256 h1 = hook.hp();
        vm.prank(bob, bob);
        ra.run(_2(_A(R3Router.Kind.BuyOut, address(0), boss.balanceOf(carol)), _A(R3Router.Kind.TakeBoss, alice, MAX)));
        assertEq(hook.damage(1, alice), h1 - hook.hp());
        _assertSums();
        assertAccounting();
    }

    /// @dev Flash buy, flash sell of that BOSS, then a real buy, in one unlock: the round trip leaves no
    /// credit and the real buy keeps all of its own (no over-penalty when nothing was delivered).
    function test_r4_P2_flashRoundTripThenBuy_oneUnlock_lastBuyKeepsFullCredit() public {
        buyExactIn(alice, 0.2 ether);
        uint256 unit = boss.balanceOf(alice);
        vm.prank(bob, bob);
        ra.run(
            _4(
                _A(R3Router.Kind.BuyOut, address(0), unit),
                _A(R3Router.Kind.SellIn, address(0), unit),
                _A(R3Router.Kind.BuyIn, address(0), 0.3 ether),
                _A(R3Router.Kind.TakeBoss, carol, MAX)
            )
        );
        assertEq(hook.damage(1, carol), 0.3 ether, "the real buy keeps its credit");
        _assertSums();
        assertAccounting();
    }

    /// @dev Kill, then a buy on the next boss in the same unlock, one take: the blow and the new buy both
    /// reach the wallet, each in its own round, with exactly the HP each removed.
    function test_r4_P3_killThenBuyNextBoss_sameUnlock_oneTake() public {
        buyExactIn(alice, 0.5 ether);
        uint256 hpLeft = hook.hp();
        vm.prank(bob, bob);
        ra.run(
            _3(
                _A(R3Router.Kind.BuyIn, address(0), 0.6 ether),
                _A(R3Router.Kind.BuyIn, address(0), 0.4 ether),
                _A(R3Router.Kind.TakeBoss, carol, MAX)
            )
        );
        assertEq(hook.round(), 2);
        assertEq(_killer(1), carol);
        assertEq(hook.unclaimedKill(carol), _prize(1));
        assertEq(hook.damage(1, carol), hpLeft, "blow credit == HP it removed");
        assertEq(hook.damage(2, carol), hook.maxHp() - hook.hp(), "next boss credit == HP removed");
        assertEq(hook.damage(1, bob), 0, "nothing left with the signer");
        _assertSums();
        assertAccounting();
    }

    /// @dev Two kills in one unlock and one take: each round's credit is bounded by its HP; only the last
    /// blow travels (documented), the first stays with the signer.
    function test_r4_P4_twoKillsOneUnlock_eachRoundBounded() public {
        vm.prank(bob, bob);
        ra.run(
            _3(
                _A(R3Router.Kind.BuyIn, address(0), 1.2 ether),
                _A(R3Router.Kind.BuyIn, address(0), 2 ether),
                _A(R3Router.Kind.TakeBoss, carol, MAX)
            )
        );
        assertEq(hook.round(), 3);
        assertEq(_elig(1), INITIAL_HP, "round 1 credit == its HP");
        assertEq(_elig(2), INITIAL_HP * 3 / 2, "round 2 credit == its HP");
        assertEq(hook.damage(1, bob), INITIAL_HP, "first blow stays with the signer (documented)");
        assertEq(hook.damage(2, carol), INITIAL_HP * 3 / 2, "last blow travels");
        assertEq(_killer(2), carol);
        _assertSums();
        assertAccounting();
    }

    /// @dev A claim between two unlocks (after a kill) does not disturb the next round's cap.
    function test_r4_P5_claimBetweenUnlocks_nextRoundCreditIntact() public {
        buyExactIn(alice, 0.5 ether);
        bytes[] memory calls = new bytes[](4);
        calls[0] = _run(ra, _buyTake(1 ether, carol));
        calls[1] = abi.encodeCall(R3Router.claimDamage, (uint64(1), carol));
        calls[2] = abi.encodeCall(R3Router.claimKill, (carol));
        calls[3] = _run(ra, _buyTake(0.4 ether, carol));
        vm.prank(bob, bob);
        ra.multi(calls);
        assertEq(hook.damage(2, carol), 0.4 ether);
        assertTrue(hook.damageClaimed(1, carol));
        assertEq(hook.unclaimedKill(carol), 0);
        _assertSums();
        assertAccounting();
    }

    /// @dev Custodian sells ALL of the blow back after taking it: nobody holds blow BOSS, the prize stays
    /// with the custodian (the killer of record), books close, no revert.
    function test_r4_P6_custodianSellsWholeBlowBack_noRevert_booksClose() public {
        buyExactIn(alice, 0.5 ether);
        bytes[] memory calls = new bytes[](2);
        calls[0] = _run(ra, _buyTake(1 ether, address(ra)));
        calls[1] = _run(ra, _1(_sellOwn(1, 1)));
        vm.prank(bob, bob);
        ra.multi(calls);
        assertEq(_killer(1), address(ra));
        _assertSums();
        assertAccounting();
    }

    // =================================================================== I. gas of `_recount`

    /// @dev A custodian (batch settlement, solver) that holds the whole blow and hands it out in N equal
    /// shares stays the largest holder until the last hop, so every hop runs `_recount` over the list of
    /// earlier recipients: O(N^2) in total. Logged against the same spray of credit-free BOSS.
    function test_r4_I1_sprayOfTheBlow_recountIsQuadratic() public {
        uint256[3] memory ns = [uint256(25), 50, 100];
        for (uint256 k = 0; k < ns.length; k++) {
            uint256 n = ns[k];
            address[] memory tos = new address[](n);
            for (uint256 i = 0; i < n; i++) {
                tos[i] = address(uint160(0x40000 + i));
            }
            uint256 snap = vm.snapshotState();
            vm.prank(bob, bob);
            ra.run(_buyTake(2 ether, address(ra)));
            uint256 blow = boss.balanceOf(address(ra));
            vm.revertToState(snap);

            uint256 each = blow / (n + 1);
            snap = vm.snapshotState();
            bytes[] memory calls = new bytes[](2);
            calls[0] = _run(ra, _buyTake(2 ether, address(ra)));
            calls[1] = abi.encodeCall(R4Router.sprayMeasured, (tos, each));
            vm.prank(bob, bob);
            ra.multi(calls);
            uint256 blowGas = ra.lastSprayGas();
            assertEq(_killer(1), address(ra), "custodian keeps the largest share");
            vm.revertToState(snap);

            snap = vm.snapshotState();
            uint256 have = boss.balanceOf(address(this));
            giveBoss(address(rb), blow < have ? blow : have); // transfer gas does not depend on the amount
            if (blow > have) each = have / (n + 1);
            vm.prank(bob, bob);
            rb.sprayMeasured(tos, each);
            uint256 plainGas = rb.lastSprayGas();
            vm.revertToState(snap);
            console2.log("I1 N / spray gas with blow / plain spray gas", n, blowGas, plainGas);
        }
    }

    // =================================================================== D. fuzz: claim 2 per round, books, liveness

    function _step(uint256 r, uint256 unit) internal view returns (address target, bytes memory data) {
        uint256 kind = r % 13;
        R4Router who = (r >> 8) % 2 == 0 ? ra : rb;
        address[5] memory ws = [alice, bob, carol, address(ra), address(rb)];
        address to = ws[(r >> 16) % 5];
        uint256 q = 0.01 ether + (r >> 24) % 1.5 ether;
        uint256 b = unit * (1 + (r >> 40) % 300) / 100;
        uint256 pct = 1 + (r >> 56) % 100;
        target = address(who);
        R3Router.Action[] memory s;
        if (kind == 0) s = _buyTake(q, to);
        else if (kind == 1) s = _2(_A(R3Router.Kind.BuyIn, address(0), q), _A(R3Router.Kind.KeepClaims, address(0), MAX));
        else if (kind == 2) {
            s = _4(
                _A(R3Router.Kind.SellIn, address(0), b / 4),
                _A(R3Router.Kind.BuyBackLast, address(0), 0),
                _A(R3Router.Kind.BuyIn, address(0), q),
                _A(R3Router.Kind.TakeBoss, to, MAX)
            );
        } else if (kind == 3) {
            s = _4(
                _A(R3Router.Kind.BuyOut, address(0), b),
                _A(R3Router.Kind.SellIn, address(0), b / 2),
                _share(to, 1, 3),
                _A(R3Router.Kind.KeepClaims, address(0), MAX)
            );
        } else if (kind == 4) {
            s = _1(_A(R3Router.Kind.ClaimsToBoss, to, b));
        } else if (kind == 5) {
            return (target, abi.encodeCall(R3Router.forward, (to, b / 3)));
        } else if (kind == 6) {
            s = _1(_sellOwn(pct, 400));
        } else if (kind == 7) {
            return (target, abi.encodeCall(R3Router.tryClaimKill, (to)));
        } else if (kind == 8) {
            return (target, abi.encodeCall(R3Router.tryClaimDamage, (uint64(1 + (r >> 48) % 3), to)));
        } else if (kind == 9) {
            s = _3(_A(R3Router.Kind.BuyIn, address(0), q), _share(to, 1, 2), _A(R3Router.Kind.TakeBoss, address(hook), MAX));
        } else if (kind == 10) {
            s = _2(_A(R3Router.Kind.BuyOut, address(0), b), _A(R3Router.Kind.TakeBoss, to, MAX));
        } else if (kind == 11) {
            s = _3(_A(R3Router.Kind.BuyIn, address(0), q), _A(R3Router.Kind.TakeBoss, address(who), MAX), _sellOwn(pct, 200));
        } else {
            s = _3(
                _A(R3Router.Kind.BuyOut, address(0), b),
                _A(R3Router.Kind.TakeBoss, to, MAX),
                _A(R3Router.Kind.SellIn, address(0), b / 8)
            );
        }
        data = abi.encodeCall(R3Router.run, (s));
    }

    struct Before {
        uint64 round;
        uint256 hp;
    }

    /// @dev Claim 2 of the fix, checked from the events: in one transaction, the credit created in each
    /// round (Credited events) never exceeds the HP the transaction removed in that round (from its HP at
    /// the start of the transaction, or at its spawn, to 0 if killed or to the HP left). Any order, two
    /// lockers, flash and real sells, deliveries to wallets, routers and the hook, claims in between, and
    /// abilities that scale buys or heals. Also: nothing reverts, all books close.
    function testFuzz_r4_D1_creditPerRound_neverExceedsHpRemoved(uint256 seed, uint8 steps, uint8 mode, bool relayed)
        public
    {
        mode = uint8(bound(mode, 0, 3));
        if (mode == 1) _setAbility(10_000, 40_000);
        else if (mode == 2) _setAbility(40_000, 10_000);
        else if (mode == 3) _setAbility(2_500, 10_000);
        buyExactIn(alice, 0.5 ether);
        uint256 unit = boss.balanceOf(alice) / 2;
        uint256 stock = unit * 3;
        uint256 have = boss.balanceOf(address(this)) / 3;
        if (stock > have) stock = have;
        giveBoss(address(ra), stock);
        giveBoss(address(rb), stock);
        steps = uint8(bound(steps, 1, 10));
        address[] memory t = new address[](steps);
        bytes[] memory c = new bytes[](steps);
        uint256 r = seed;
        for (uint256 i = 0; i < steps; i++) {
            r = uint256(keccak256(abi.encode(r, i)));
            (t[i], c[i]) = _step(r, unit);
        }
        Before memory b0 = Before(hook.round(), hook.hp());
        address signer = relayed ? bundlerEOA : alice;
        vm.recordLogs();
        vm.prank(signer, signer);
        lenient.run(t, c);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _checkNoPanic(lenient.failures());
        _checkCap(logs, b0, false);
        _assertSums();
        assertAccounting();
    }

    /// @dev A step may fail for market reasons (a price limit reached, a router out of BOSS), never with an
    /// arithmetic panic (an underflow in the hook's books would surface as Panic(0x11) somewhere inside).
    function _checkNoPanic(bytes[] memory fails) internal pure {
        for (uint256 i = 0; i < fails.length; i++) {
            bytes memory f = fails[i];
            for (uint256 j = 0; j + 4 <= f.length; j++) {
                bool hit = f[j] == 0x4e && f[j + 1] == 0x48 && f[j + 2] == 0x7b && f[j + 3] == 0x71;
                assertFalse(hit, "a step failed with a Panic");
            }
        }
    }

    function _apply(
        Vm.Log memory l,
        uint64 r0,
        uint256[] memory created,
        uint256[] memory start,
        uint256[] memory hpNow,
        uint256[] memory forfeited
    ) internal pure {
        if (l.topics.length < 2) return;
        bytes32 sig = l.topics[0];
        if (sig != CREDITED && sig != KILLED && sig != HIT && sig != HEALED && sig != FORFEITED) return;
        uint256 k = uint64(uint256(l.topics[1])) - r0;
        if (sig == FORFEITED) {
            // Credit that left the game in this transaction no longer counts against its cap (F1 fix).
            forfeited[k] += abi.decode(l.data, (uint256));
        } else if (sig == CREDITED) {
            (uint256 d,) = abi.decode(l.data, (uint256, uint256));
            created[k] += d;
            uint256 removedSoFar = start[k] > hpNow[k] ? start[k] - hpNow[k] : 0;
            // Heals AFTER a delivery are not charged to it (F3), so check only where credit is created.
            if (d > 0) {
                assertLe(created[k], removedSoFar + forfeited[k], "net credit so far <= HP removed so far (timeline)");
            }
        } else if (sig == KILLED) {
            (,,, uint256 nextHp) = abi.decode(l.data, (uint256, uint256, uint256, uint256));
            start[k + 1] = nextHp;
            hpNow[k + 1] = nextHp;
        } else {
            (,, uint256 hpAfter) = abi.decode(l.data, (uint256, uint256, uint256));
            hpNow[k] = hpAfter;
        }
    }

    bytes32 internal constant HIT = keccak256("Hit(uint64,address,uint256,uint256,uint256)");
    bytes32 internal constant HEALED = keccak256("Healed(uint64,address,uint256,uint256,uint256)");

    /// @dev Replays the transaction's events in order. At every Credited event, the credit created so far
    /// in that round must not exceed (HP at the round's first trade in the tx) - (HP at that moment).
    /// `endState` additionally checks the README wording: against the HP left at the END of the tx.
    function _checkCap(Vm.Log[] memory logs, Before memory b0, bool endState) internal view {
        uint64 endRound = hook.round();
        uint256 nRounds = endRound - b0.round + 1;
        uint256[] memory created = new uint256[](nRounds);
        uint256[] memory start = new uint256[](nRounds);
        uint256[] memory hpNow = new uint256[](nRounds);
        uint256[] memory forfeited = new uint256[](nRounds);
        start[0] = b0.hp;
        hpNow[0] = b0.hp;
        bytes32 stepSig = keccak256("Step(uint256,bool)");
        uint256 segStart = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(lenient) || logs[i].topics[0] != stepSig) continue;
            bool ok = abi.decode(logs[i].data, (bool));
            if (ok) {
                for (uint256 j = segStart; j < i; j++) {
                    _apply(logs[j], b0.round, created, start, hpNow, forfeited);
                }
            }
            segStart = i + 1;
        }
        if (!endState) return;
        for (uint256 k = 0; k < nRounds; k++) {
            uint256 endHp = (b0.round + k < endRound) ? 0 : hook.hp();
            uint256 removed = start[k] > endHp ? start[k] - endHp : 0;
            assertLe(created[k], removed + forfeited[k], "net credit created in the tx <= HP the tx removed");
        }
    }
}

contract Review4BossFirstTest is Review4Base {}

contract Review4BossSecondTest is Review4Base {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

contract Review4NativeTest is Review4Base {
    function useNative() internal pure override returns (bool) {
        return true;
    }
}
