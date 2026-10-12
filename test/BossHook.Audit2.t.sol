// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {ReviewBase} from "./review/ReviewBase.sol";
import {ScriptRouter} from "./utils/ScriptRouter.sol";
import {Bundle, SmartAccount} from "./utils/Bundle.sol";
import {FixedAbility} from "./mocks/Abilities.sol";
import {BossHook} from "../src/BossHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice The second swarm audit of HitTheBossApp/boss@b154ad2 (job be67d693): one test per
/// finding that was fixed in code, written from the judge's reproductions. Each one failed on
/// b154ad2 before the fix.
contract BossAudit2Test is ReviewBase {
    using stdStorage for StdStorage;

    address internal bundlerEOA = makeAddr("bundlerEOA");
    address internal bundlerWallet = makeAddr("bundlerWallet");
    ScriptRouter internal script2;
    SmartAccount internal account;
    Bundle internal bundle;

    function setUp() public override {
        super.setUp();
        script2 = new ScriptRouter(IPoolManager(address(manager)), hook, key, bossIsCurrency0, boss, quoteToken);
        quoteToken.mint(address(script2), 100 ether);
        account = new SmartAccount(swapRouter, quoteToken);
        quoteToken.mint(address(account), 100 ether);
        bundle = new Bundle();
    }

    // ------------------------------------------------------------------ helpers

    function _activate(address ability) internal {
        stdstore.target(address(hook)).sig("activeAbility()").checked_write(ability);
        assertEq(hook.activeAbility(), ability);
    }

    /// @dev `n` flash round trips: exact-output buy of `bossAmount`, exact-input sell of the same
    /// BOSS in the same unlock. No BossToken moves.
    function _roundTrips(uint256 n, uint256 bossAmount, uint256 extra)
        internal
        view
        returns (ScriptRouter.Action[] memory a)
    {
        a = new ScriptRouter.Action[](2 * n + extra);
        for (uint256 i = 0; i < n; i++) {
            a[2 * i] = script.buyBossOut(bossAmount);
            a[2 * i + 1] = script.sellOwn(bossAmount);
        }
    }

    function _one(ScriptRouter.Action memory x) internal pure returns (ScriptRouter.Action[] memory a) {
        a = new ScriptRouter.Action[](1);
        a[0] = x;
    }

    function _two(ScriptRouter.Action memory x, ScriptRouter.Action memory y)
        internal
        pure
        returns (ScriptRouter.Action[] memory a)
    {
        a = new ScriptRouter.Action[](2);
        a[0] = x;
        a[1] = y;
    }

    function _three(ScriptRouter.Action memory x, ScriptRouter.Action memory y, ScriptRouter.Action memory z)
        internal
        pure
        returns (ScriptRouter.Action[] memory a)
    {
        a = new ScriptRouter.Action[](3);
        a[0] = x;
        a[1] = y;
        a[2] = z;
    }

    function _runBundle(address[] memory targets, bytes[] memory calls) internal {
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(targets, calls);
    }

    function _killer(uint64 r) internal view returns (address killer, uint256 prize) {
        (killer,, prize,,) = hook.results(r);
    }

    // ------------------------------------------------------------------ high 1: flash sells

    /// Judge's ProofFlashSell: 8 buy-then-flash-sell round trips before the killing buy, all in one
    /// unlock. No BOSS token moves for the round trips, so they must not leave any credit behind.
    function test_H1_flashRoundTrips_doNotInflateKillCredit() public {
        buyExactIn(alice, 0.5 ether);
        assertEq(hook.hp(), 0.5 ether);

        ScriptRouter.Action[] memory a = _roundTrips(8, 100_000 ether, 2);
        a[16] = script.buy(1 ether);
        a[17] = script.takeBoss(bob, type(uint256).max);
        vm.prank(bob, bob);
        script.run(a);

        (address killer,,, uint256 pool, uint256 elig) = hook.results(1);
        assertEq(killer, bob, "bob killed");
        assertLe(hook.damage(1, bob), 0.5 ether, "bob is credited at most the HP that was left");
        assertLe(elig, 1 ether, "eligible damage never exceeds the boss's HP");
        assertGe(hook.claimableDamage(1, alice) + 1, pool / 2, "alice keeps half of the damage pool");
        _assertOpenRoundSums();
        assertAccounting();
    }

    /// Backstop: on a day when heals count 4x, a buy, a partial flash sell that heals the boss back
    /// to full, then the killing buy. The kill credits no more than the HP the transaction removed.
    function test_H1_killCredit_neverExceedsHpTheTxRemoved_onAHealDay() public {
        _activate(address(new FixedAbility(10_000, 40_000)));

        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](4);
        a[0] = script.buyBossOut(160_000 ether);
        a[1] = script.sellOwn(80_000 ether);
        a[2] = script.buy(2 ether);
        a[3] = script.takeBoss(bob, type(uint256).max);
        vm.prank(bob, bob);
        script.run(a);

        (address killer,,,, uint256 elig) = hook.results(1);
        assertEq(killer, bob, "bob killed");
        assertLe(hook.damage(1, bob), 1 ether, "no more credit than the boss's whole HP");
        assertLe(elig, 1 ether, "eligible damage never exceeds the HP removed");
        assertAccounting();
    }

    /// Same heal day, no kill: a buy and a flash sell that heals the boss back to full leave the
    /// buyer's BOSS with no credit, because the transaction removed no HP.
    function test_H1_arrivalCredit_neverExceedsNetDamage_onAHealDay() public {
        _activate(address(new FixedAbility(10_000, 40_000)));

        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buyBossOut(160_000 ether);
        a[1] = script.sellOwn(80_000 ether);
        a[2] = script.takeBoss(bob, type(uint256).max);
        vm.prank(bob, bob);
        script.run(a);

        assertEq(hook.hp(), hook.maxHp(), "the heal put the boss back to full");
        assertEq(hook.damage(1, bob), 0, "no net damage, no credit");
        assertEq(hook.eligibleDamage(1), 0, "nothing eligible");
        assertGt(hook.bought(1, bob), 0, "bob still holds the BOSS he kept");
        assertAccounting();
    }

    // ------------------------------------------------------------------ high 2: credit scoped to the locker

    /// Judge's ProofBundler: the bundler's executor runs flash round trips, the victim's smart
    /// account kills through a stock router, then the bundler buys and takes BOSS to its wallet,
    /// all in one bundle. The victim keeps the killing blow.
    function test_H2_bundlerFlashAroundVictimKill_victimKeepsPrize() public {
        buyExactIn(alice, 0.5 ether);

        address[] memory t = new address[](3);
        bytes[] memory c = new bytes[](3);
        t[0] = address(script);
        c[0] = abi.encodeCall(script.run, (_roundTrips(8, 100_000 ether, 0)));
        t[1] = address(account);
        c[1] = abi.encodeCall(account.buy, (key, bossIsCurrency0, 0.6 ether));
        t[2] = address(script);
        c[2] = abi.encodeCall(
            script.run, (_two(script.buy(0.7 ether), script.takeBoss(bundlerWallet, type(uint256).max)))
        );
        _runBundle(t, c);

        (address killer, uint256 prize) = _killer(1);
        assertEq(killer, address(account), "the victim's account killed");
        assertEq(hook.unclaimedKill(address(account)), prize, "the prize is the victim's");
        assertEq(hook.unclaimedKill(bundlerWallet), 0, "the bundler's wallet gets no prize");
        assertAccounting();
    }

    /// Without flash sells: the bundler's executor buys and keeps the BOSS as ERC-6909 claims, the
    /// victim kills, then the executor turns its claims into BOSS for its wallet. Another party's
    /// leftover credit must not merge into the victim's blow.
    function test_H2_claimsHeldPreBuy_doesNotMergeIntoVictimKill() public {
        buyExactIn(alice, 0.2 ether);

        address[] memory t = new address[](3);
        bytes[] memory c = new bytes[](3);
        t[0] = address(script);
        c[0] = abi.encodeCall(
            script.run, (_two(script.buy(0.5 ether), script.takeBossAsClaims(type(uint256).max)))
        );
        t[1] = address(account);
        c[1] = abi.encodeCall(account.buy, (key, bossIsCurrency0, 0.6 ether));
        t[2] = address(script);
        c[2] = abi.encodeCall(script.run, (_one(script.claimsToBoss(bundlerWallet, type(uint256).max))));
        _runBundle(t, c);

        (address killer, uint256 prize) = _killer(1);
        assertEq(killer, address(account), "the victim's account killed");
        assertEq(hook.unclaimedKill(address(account)), prize, "the prize is the victim's");
        assertEq(hook.unclaimedKill(bundlerWallet), 0, "the bundler's wallet gets no prize");
        assertEq(hook.damage(1, bundlerWallet), 0, "no killing credit for the bundler's wallet");
        assertEq(hook.damage(1, address(account)), 0.3 ether, "the victim holds exactly her blow");
        assertAccounting();
    }

    /// The victim's router delivers 40% of the blow and keeps 60% as claims; then another party's
    /// swap (another router) takes BOSS out of the pool. That BOSS is not the blow's.
    function test_H2_laterSenderCannotTakeTheVictimsUndeliveredBlow() public {
        buyExactIn(alice, 0.2 ether);

        address[] memory t = new address[](2);
        bytes[] memory c = new bytes[](2);
        t[0] = address(script);
        c[0] = abi.encodeCall(
            script.run,
            (_three(
                    script.buy(1.6 ether),
                    script.takeBossShare(carol, 2, 5),
                    script.takeBossAsClaims(type(uint256).max)
                ))
        );
        t[1] = address(script2);
        c[1] = abi.encodeCall(
            script2.run, (_two(script2.buy(0.7 ether), script2.takeBoss(bundlerWallet, type(uint256).max)))
        );
        _runBundle(t, c);

        (address killer, uint256 prize) = _killer(1);
        assertEq(killer, carol, "the wallet that received the blow keeps it");
        assertEq(hook.unclaimedKill(carol), prize);
        assertEq(hook.unclaimedKill(bundlerWallet), 0, "another party's BOSS is not the blow's");
        assertEq(hook.damage(1, bundlerWallet), 0, "no killing credit for another party");
        assertAccounting();
    }

    // ------------------------------------------------------------------ low 3: the hook is a sink

    function test_L3_bossSentToTheHook_forfeits_andTheHookIsNeverPaid() public {
        buyExactIn(alice, 0.5 ether);
        uint256 bal = boss.balanceOf(alice);
        vm.prank(alice);
        boss.transfer(address(hook), bal);

        assertEq(hook.damage(1, address(hook)), 0, "the hook holds no credit");
        assertEq(hook.eligibleDamage(1), 0, "alice's credit was forfeited");

        buyExactIn(bob, 2 ether);
        assertEq(hook.round(), 2);
        assertEq(hook.claimableDamage(1, address(hook)), 0);
        vm.expectRevert(BossHook.NothingToClaim.selector);
        hook.claimDamage(1, address(hook));
        assertAccounting();
    }

    function test_L3_bossTakenFromThePoolToTheHook_creditsNobody() public {
        vm.prank(bob, bob);
        script.run(_two(script.buy(0.3 ether), script.takeBoss(address(hook), type(uint256).max)));

        assertEq(hook.damage(1, address(hook)), 0, "the hook holds no credit");
        assertEq(hook.eligibleDamage(1), 0, "credit of BOSS sent to the hook is void");
        assertAccounting();
    }

    // ------------------------------------------------------------------ low 6: largest holder, always

    /// Judge's P6 shape: the custodian sells 60% of the blow back into the pool, then delivers 40%.
    function test_L6_custodianSellsPartThenDelivers_prizeFollowsTheDelivery() public {
        ScriptRouter.Action[][] memory s = new ScriptRouter.Action[][](3);
        s[0] = _two(script.buy(1.6 ether), script.takeBoss(address(script), type(uint256).max));
        s[1] = _one(script.sellOwnShare(3, 5));
        s[2] = _one(script.forwardAllBut(alice, 0));
        vm.prank(carol, carol);
        script.runMany(s);

        (address killer, uint256 prize) = _killer(1);
        assertEq(boss.balanceOf(address(script)), 0, "the custodian kept nothing");
        assertEq(killer, alice, "alice holds all that is left of the blow");
        assertEq(hook.unclaimedKill(alice), prize);
        assertEq(hook.unclaimedKill(address(script)), 0);
    }

    /// Reverse order: the custodian delivers 40% first, then sells the other 60% into the pool.
    function test_L6_custodianDeliversThenSellsTheRest_prizeFollowsTheDelivery() public {
        ScriptRouter.Action[][] memory s = new ScriptRouter.Action[][](2);
        s[0] = _two(script.buy(1.6 ether), script.takeBoss(address(script), type(uint256).max));
        s[1] = _two(script.forwardShare(alice, 2, 5), script.sellOwnShare(1, 1));
        vm.prank(carol, carol);
        script.runMany(s);

        (address killer, uint256 prize) = _killer(1);
        assertEq(killer, alice, "alice holds all that is left of the blow");
        assertEq(hook.unclaimedKill(alice), prize);
        assertEq(hook.unclaimedKill(address(script)), 0);
    }

    /// The killer's holding drops below a third wallet's on a hop to someone else: 46% / 10% / 44%.
    function test_L6_killerHopToAnotherWallet_reevaluatesTheLargestHolder() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](5);
        a[0] = script.buy(1.6 ether);
        a[1] = script.takeBoss(address(script), type(uint256).max);
        a[2] = script.forwardShare(alice, 46, 100);
        a[3] = script.forwardShare(feeCollector, 10, 54);
        a[4] = script.forwardAllBut(bob, 0);
        vm.prank(carol, carol);
        script.run(a);

        (address killer, uint256 prize) = _killer(1);
        assertGt(boss.balanceOf(alice), boss.balanceOf(bob), "46% > 44%");
        assertEq(killer, alice, "the largest holder of the blow wins");
        assertEq(hook.unclaimedKill(alice), prize);
        assertEq(hook.unclaimedKill(bob), 0);
    }
}
