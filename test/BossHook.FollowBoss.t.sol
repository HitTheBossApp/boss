// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BossFixture} from "./utils/BossFixture.sol";
import {ScriptRouter} from "./utils/ScriptRouter.sol";
import {BossHook} from "../src/BossHook.sol";
import {BossToken} from "../src/BossToken.sol";
import {FlashBait, SellBait} from "./BossHook.Forfeit.t.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @dev Damage credit follows the BOSS: a buy is credited to the wallet that receives the BOSS
/// from the pool, a forfeit is charged to the wallet whose BOSS leaves, and credit travels with
/// BOSS sent to another wallet. The signer (tx.origin) never decides who collects. Runs in both
/// currency orderings.
abstract contract BossFollowBossBase is BossFixture {
    address internal relayer = makeAddr("relayer");
    ScriptRouter internal script;

    function setUp() public virtual override {
        super.setUp();
        script = new ScriptRouter(IPoolManager(address(manager)), hook, key, bossIsCurrency0, boss, quoteToken);
        quoteToken.mint(address(script), 100 ether);
    }

    // ------------------------------------------------------------------ buys: credit goes with the BOSS

    function test_buyCreditsTheBossRecipient_notTheSigner() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](2);
        a[0] = script.buy(0.5 ether);
        a[1] = script.takeBoss(bob, type(uint256).max);
        vm.prank(alice, alice);
        script.run(a);
        assertEq(hook.damage(1, bob), 0.5 ether, "the wallet that received the BOSS is credited");
        assertGt(hook.bought(1, bob), 0, "and its BOSS is counted");
        assertEq(hook.damage(1, alice), 0, "the signer gets nothing");
        assertEq(hook.eligibleDamage(1), 0.5 ether);
        assertAccounting();
    }

    function test_relayedBuy_creditsTheWalletThatGetsTheBoss() public {
        bool z = !bossIsCurrency0;
        vm.prank(alice, relayer);
        swapRouter.swap(key, SwapParams(z, -0.5 ether, _limit(z)), PoolSwapTest.TestSettings(false, false), "");
        assertEq(hook.damage(1, alice), 0.5 ether, "alice got the BOSS, alice is credited");
        assertEq(hook.damage(1, relayer), 0, "the relayer only signed");
        assertEq(hook.bought(1, alice), boss.balanceOf(alice));
        assertAccounting();
    }

    function test_buyTakenAsClaims_getsNoCredit() public {
        bool z = !bossIsCurrency0;
        vm.prank(alice, alice);
        swapRouter.swap(key, SwapParams(z, -0.5 ether, _limit(z)), PoolSwapTest.TestSettings(true, false), "");
        assertEq(hook.damage(1, alice), 0, "no BOSS left the pool, no credit");
        assertEq(hook.eligibleDamage(1), 0, "and nobody is diluted");
        assertLt(hook.hp(), INITIAL_HP, "the boss was hit all the same");
        buyExactIn(bob, 0.25 ether); // a later buy in a new transaction is not polluted
        assertEq(hook.damage(1, bob), 0.25 ether);
        assertEq(hook.bought(1, bob), boss.balanceOf(bob));
        assertEq(hook.eligibleDamage(1), 0.25 ether);
        assertAccounting();
    }

    function test_partialTakes_splitTheCreditByBoss() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(0.5 ether);
        a[1] = script.takeBossShare(bob, 1, 4); // a quarter of the BOSS bought
        a[2] = script.takeBoss(carol, type(uint256).max); // the rest
        vm.prank(alice, alice);
        script.run(a);
        uint256 total = hook.bought(1, bob) + hook.bought(1, carol);
        assertEq(hook.bought(1, bob), total / 4, "bob got a quarter of the BOSS");
        assertApproxEqAbs(hook.damage(1, bob), 0.125 ether, 1, "and a quarter of the damage");
        assertApproxEqAbs(hook.damage(1, carol), 0.375 ether, 1);
        assertEq(hook.damage(1, bob) + hook.damage(1, carol), 0.5 ether, "nothing is lost to rounding");
        assertEq(hook.eligibleDamage(1), 0.5 ether);
        assertAccounting();
    }

    function test_hookDataNeverNamesTheBuyer() public {
        bool z = !bossIsCurrency0;
        address label = makeAddr("label");
        _swap(alice, SwapParams(z, -0.1 ether, _limit(z)), abi.encode(label), 0);
        assertEq(hook.damage(1, label), 0);
        assertEq(hook.damage(1, alice), 0.1 ether);
    }

    // ------------------------------------------------------------------ sells: the forfeit follows the BOSS

    function test_relayedSell_forfeitsTheWalletWhoseBossLeft() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        vm.expectEmit(true, true, false, true, address(hook));
        emit BossHook.Forfeited(1, alice, 0.5 ether);
        vm.prank(alice, relayer);
        swapRouter.swap(
            key,
            SwapParams(bossIsCurrency0, -int256(got), _limit(bossIsCurrency0)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(boss.balanceOf(alice), 0);
        assertEq(hook.damage(1, alice), 0, "alice's BOSS went into the pool: alice forfeits");
        assertEq(hook.bought(1, alice), 0);
        assertEq(hook.eligibleDamage(1), 0);
        assertAccounting();
    }

    function test_baitSellingItsOwnBoss_neverTouchesTheVictim() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        buyExactIn(bob, 0.25 ether);
        SellBait bait = new SellBait(swapRouter, key, bossIsCurrency0, boss);
        giveBoss(address(bait), got);
        vm.prank(alice, alice);
        bait.claimAirdrop(-int256(got), _limit(bossIsCurrency0)); // a sell as large as alice's whole buy
        assertEq(hook.damage(1, alice), 0.5 ether, "the bait sold its own BOSS, not alice's");
        assertEq(hook.bought(1, alice), got);
        assertEq(hook.eligibleDamage(1), 0.75 ether);
        assertGt(hook.hp(), 0.25 ether, "the boss was healed all the same");
        assertAccounting();
    }

    function test_flashRoundTripInsideVictimTx_changesNothing() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        buyExactIn(bob, 0.25 ether);
        FlashBait bait = new FlashBait(IPoolManager(address(manager)), key, bossIsCurrency0, quoteToken);
        quoteToken.mint(address(bait), 1 ether);
        vm.prank(alice, alice);
        bait.claimAirdrop(got); // sells alice's whole position, borrowed, and buys it back
        assertEq(hook.damage(1, alice), 0.5 ether, "no BOSS moved: nothing changes");
        assertEq(hook.bought(1, alice), got);
        assertEq(hook.damage(1, bob), 0.25 ether);
        assertEq(hook.eligibleDamage(1), 0.75 ether);
        assertEq(hook.damage(1, address(bait)), 0, "the bait took no BOSS out of the pool");
        assertAccounting();
    }

    function test_depositingBossAsClaims_forfeits() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        vm.prank(alice);
        boss.approve(address(script), type(uint256).max);
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](1);
        a[0] = script.depositAsClaims(alice, got / 2);
        vm.prank(alice, alice);
        script.run(a);
        assertApproxEqAbs(hook.damage(1, alice), 0.25 ether, 1, "BOSS handed to the pool is BOSS given up");
        assertEq(hook.bought(1, alice), got - got / 2);
        assertAccounting();
    }

    // ------------------------------------------------------------------ transfers: credit travels

    function test_transferMovesCreditWithTheBoss() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        vm.expectEmit(true, true, true, false, address(hook));
        emit BossHook.DamageMoved(1, alice, bob, 0, 0);
        vm.prank(alice);
        boss.transfer(bob, got / 2);
        assertApproxEqAbs(hook.damage(1, alice), 0.25 ether, 1, "half the BOSS left, half the damage went with it");
        assertApproxEqAbs(hook.damage(1, bob), 0.25 ether, 1);
        assertEq(hook.damage(1, alice) + hook.damage(1, bob), 0.5 ether);
        assertEq(hook.bought(1, alice), got - got / 2);
        assertEq(hook.bought(1, bob), got / 2);
        assertEq(hook.eligibleDamage(1), 0.5 ether, "moving credit dilutes nobody");
        assertAccounting();
    }

    function test_sellFromTheSecondWallet_forfeitsThatWallet() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        vm.prank(alice);
        boss.transfer(bob, got / 2);
        sellExactIn(bob, got / 2);
        assertEq(hook.damage(1, bob), 0, "the second wallet sold what it got: it loses that credit");
        assertApproxEqAbs(hook.damage(1, alice), 0.25 ether, 1, "the first keeps its half");
        assertEq(hook.eligibleDamage(1), hook.damage(1, alice));
        assertAccounting();
    }

    function test_transferAllThenSellAll_leavesNoCredit() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        buyExactIn(carol, 0.25 ether);
        vm.prank(alice);
        boss.transfer(bob, got);
        sellExactIn(bob, got);
        assertEq(hook.damage(1, alice), 0, "selling from another wallet no longer keeps the credit");
        assertEq(hook.damage(1, bob), 0);
        assertEq(hook.eligibleDamage(1), 0.25 ether, "only carol stays eligible");
        assertAccounting();
    }

    function testFuzz_transfer_movesExactlyTheProportion(uint256 buyAmount, uint256 moveBps) public {
        buyAmount = bound(buyAmount, 0.01 ether, 0.9 ether); // below the 1 IMD HP: no kill
        moveBps = bound(moveBps, 1, 10_000);
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, buyAmount)));
        uint256 moved = got * moveBps / 10_000;
        vm.assume(moved > 0);
        vm.prank(alice);
        boss.transfer(bob, moved);
        uint256 expectedMoved = moved == got ? buyAmount : buyAmount * moved / got;
        assertEq(hook.damage(1, bob), expectedMoved, "damage * moved / bought goes to the receiver");
        assertEq(hook.damage(1, alice), buyAmount - expectedMoved);
        assertEq(hook.bought(1, bob), moved);
        assertEq(hook.bought(1, alice), got - moved);
        assertEq(hook.eligibleDamage(1), buyAmount);
        assertAccounting();
    }

    function test_transferOfOldRoundBoss_countsAgainstThisRound() public {
        uint256 old = uint256(bossDeltaOf(buyExactIn(alice, 1 ether))); // kills boss 1, round 2 opens
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.2 ether)));
        vm.prank(alice);
        boss.transfer(bob, old); // moves round-1 BOSS, but the hook can't tell BOSS apart
        assertEq(hook.damage(2, alice), 0, "old BOSS leaving counts against this round's buy");
        assertEq(hook.damage(2, bob), 0.2 ether);
        assertEq(hook.bought(2, bob), got, "bob is only credited up to what alice bought this round");
        assertEq(hook.damage(1, alice), 1 ether, "the closed round is untouched");
        assertAccounting();
    }

    function test_transferWithNoCredit_isPlain() public {
        giveBoss(alice, 1_000 ether); // from the fixture's supply, never bought
        vm.prank(alice);
        boss.transfer(bob, 1_000 ether);
        assertEq(hook.damage(1, bob), 0);
        assertEq(hook.bought(1, bob), 0);
        assertEq(hook.eligibleDamage(1), 0);
    }

    // ------------------------------------------------------------------ the killing blow follows the BOSS too

    function test_relayedKill_creditsTheKillToTheBossRecipient() public {
        bool z = !bossIsCurrency0;
        vm.prank(alice, relayer);
        swapRouter.swap(key, SwapParams(z, -2 ether, _limit(z)), PoolSwapTest.TestSettings(false, false), "");
        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, alice, "the wallet that got the BOSS killed the boss");
        assertEq(hook.unclaimedKill(alice), prize);
        assertEq(hook.unclaimedKill(relayer), 0, "the relayer only signed");
        assertEq(hook.damage(1, alice), INITIAL_HP, "the killing blow's damage is hers");
        assertEq(hook.damage(1, relayer), 0);
        assertEq(hook.eligibleDamage(1), INITIAL_HP);
        assertAccounting();
    }

    function test_killTakenToAnotherWallet_movesTheKillAndItsDamage() public {
        buyExactIn(carol, 0.3 ether);
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](2);
        a[0] = script.buy(2 ether);
        a[1] = script.takeBoss(bob, type(uint256).max);
        vm.expectEmit(true, true, false, false, address(hook));
        emit BossHook.KillerCredited(1, bob);
        vm.prank(alice, alice);
        script.run(a);
        (address killer,, uint256 prize,, uint256 elig) = hook.results(1);
        assertEq(killer, bob);
        assertEq(hook.unclaimedKill(bob), prize);
        assertEq(hook.unclaimedKill(alice), 0);
        assertEq(hook.damage(1, bob), INITIAL_HP - 0.3 ether, "the rest of the HP was the killing blow");
        assertEq(hook.damage(1, alice), 0);
        assertEq(elig, INITIAL_HP, "the closed round counts carol and the killing blow");
        assertEq(hook.eligibleDamage(1), elig);
        assertAccounting();
    }

    function test_killTakenAsClaims_staysWithTheSigner() public {
        bool z = !bossIsCurrency0;
        vm.prank(alice, alice);
        swapRouter.swap(key, SwapParams(z, -2 ether, _limit(z)), PoolSwapTest.TestSettings(true, false), "");
        (address killer,, uint256 prize, uint256 damagePool, uint256 elig) = hook.results(1);
        assertEq(killer, alice, "no BOSS left the pool: the kill stays with the signer");
        assertEq(hook.unclaimedKill(alice), prize);
        assertEq(hook.damage(1, alice), INITIAL_HP, "and so does its damage, so the round can be paid");
        assertEq(elig, INITIAL_HP);
        assertGt(damagePool, 0, "the killing blow always counts as damage");
        assertEq(hook.claimableDamage(1, alice), damagePool);
        assertAccounting();
    }

    function test_killThenBuyAgainInOneTx_creditsEachRound() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether); // kills boss 1
        a[1] = script.buy(0.4 ether); // hits boss 2
        a[2] = script.takeBoss(bob, type(uint256).max);
        vm.prank(alice, alice);
        script.run(a);
        (address killer,,,,) = hook.results(1);
        assertEq(killer, bob);
        assertEq(hook.damage(1, bob), INITIAL_HP, "round 1: the killing blow");
        assertEq(hook.damage(2, bob), 0.4 ether, "round 2: the new hit");
        assertEq(hook.damage(1, alice) + hook.damage(2, alice), 0);
        assertEq(hook.eligibleDamage(1), INITIAL_HP);
        assertEq(hook.eligibleDamage(2), 0.4 ether);
        assertEq(hook.bought(1, bob) + hook.bought(2, bob), boss.balanceOf(bob), "all the BOSS is accounted for");
        assertAccounting();
    }

    /// @dev One transaction, three steps: alice kills and takes half the BOSS (the other half stays
    /// as claims in the router); she collects the whole round-1 damage pool; then the claims become
    /// BOSS for bob. The credit that was paid out must not follow that late BOSS.
    function test_killCreditAlreadyClaimed_doesNotMoveToALaterTaker() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether);
        a[1] = script.takeBossShare(alice, 1, 2);
        a[2] = script.takeBossAsClaims(type(uint256).max);
        ScriptRouter.Action[] memory b = new ScriptRouter.Action[](1);
        b[0] = script.claimsToBoss(bob, type(uint256).max);
        uint256 before = _quoteBalance(alice);
        vm.prank(alice, alice);
        script.runSequence(a, 1, alice, b);
        (,,, uint256 damagePool,) = hook.results(1);
        assertEq(_quoteBalance(alice) - before, damagePool, "alice was paid the whole damage pool");
        assertEq(hook.damage(1, alice), INITIAL_HP, "her credit stays recorded as claimed");
        assertEq(hook.damage(1, bob), 0, "the credit was already paid out: it does not move");
        assertEq(hook.claimableDamage(1, bob), 0);
        assertEq(hook.eligibleDamage(1), INITIAL_HP);
        assertGt(boss.balanceOf(bob), 0, "bob did get the BOSS");
        assertAccounting();
    }

    // ------------------------------------------------------------------ the kill through a router that custodies the BOSS

    address internal feeCollector = makeAddr("feeCollector");

    /// @dev The Universal Router with an interface fee, an aggregator or a solver: the BOSS reaches
    /// the player in two hops, pool -> router -> player, inside one transaction.
    function test_killDeliveredThroughARouter_reachesThePlayer() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether); // kills boss 1
        a[1] = script.takeBoss(address(script), type(uint256).max); // the router custodies it
        a[2] = script.forward(alice, type(uint256).max); // and delivers it
        vm.expectEmit(true, true, false, false, address(hook));
        emit BossHook.KillerCredited(1, alice);
        vm.prank(alice, alice);
        script.run(a);
        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, alice, "the kill reaches the player, not the router");
        assertEq(hook.unclaimedKill(alice), prize);
        assertEq(hook.unclaimedKill(address(script)), 0);
        assertEq(hook.damage(1, alice), INITIAL_HP, "so does the killing blow's damage");
        assertEq(hook.damage(1, address(script)), 0);
        assertEq(hook.bought(1, alice), boss.balanceOf(alice));
        assertEq(hook.eligibleDamage(1), INITIAL_HP);
        assertAccounting();
    }

    function test_killWithAnInterfaceFee_prizeFollowsTheLargestShare() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](4);
        a[0] = script.buy(2 ether);
        a[1] = script.takeBoss(address(script), type(uint256).max);
        a[2] = script.forwardShare(feeCollector, 25, 10_000); // 0.25% interface fee, paid first
        a[3] = script.forward(alice, type(uint256).max);
        vm.prank(alice, alice);
        script.run(a);
        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, alice, "the prize follows the largest share of the kill's BOSS");
        assertEq(hook.unclaimedKill(alice), prize);
        assertEq(hook.unclaimedKill(feeCollector), 0);
        assertApproxEqAbs(
            hook.damage(1, feeCollector), INITIAL_HP * 25 / 10_000, 1, "the fee carries its sliver of damage"
        );
        assertEq(hook.damage(1, feeCollector) + hook.damage(1, alice), INITIAL_HP);
        assertEq(hook.damage(1, address(script)), 0);
        assertAccounting();
    }

    function test_feeTakenFirstFromThePool_prizeStillFollowsTheLargestShare() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether);
        a[1] = script.takeBossShare(feeCollector, 25, 10_000); // TAKE_PORTION to the fee collector first
        a[2] = script.takeBoss(alice, type(uint256).max);
        vm.prank(alice, alice);
        script.run(a);
        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, alice, "a dust take first does not decide the kill");
        assertEq(hook.unclaimedKill(alice), prize);
        assertEq(hook.unclaimedKill(feeCollector), 0);
        assertAccounting();
    }

    function test_solverKeepingOneWei_prizeGoesToTheUser() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether);
        a[1] = script.takeBoss(address(script), type(uint256).max); // the solver
        a[2] = script.forwardAllBut(bob, 1); // delivers all but one wei
        vm.prank(alice, alice);
        script.run(a);
        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, bob);
        assertEq(hook.unclaimedKill(bob), prize);
        assertEq(hook.unclaimedKill(address(script)), 0);
        assertEq(hook.bought(1, address(script)), 1, "the solver keeps its wei");
        assertEq(hook.damage(1, address(script)) + hook.damage(1, bob), INITIAL_HP);
        assertAccounting();
    }

    function test_killBossSoldInTheSameTx_keepsTheClosedRoundCredit() public {
        buyExactIn(carol, 0.3 ether);
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether); // kills
        a[1] = script.takeBoss(address(script), type(uint256).max);
        a[2] = script.sellOwn(1_000 ether); // dumps part of it right away, in round 2
        vm.prank(alice, alice);
        script.run(a);
        (address killer,,,, uint256 elig) = hook.results(1);
        assertEq(killer, address(script));
        assertEq(hook.damage(1, address(script)), INITIAL_HP - 0.3 ether, "a closed round is never forfeited");
        assertEq(elig, INITIAL_HP);
        assertEq(hook.eligibleDamage(1), INITIAL_HP);
        assertEq(hook.damage(2, address(script)), 0, "and the dump heals boss 2 without touching round 2 credit");
        assertAccounting();
    }

    function test_killPrizeClaimedBetweenUnlocks_doesNotMoveWithTheBossLater() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](2);
        a[0] = script.buy(2 ether);
        a[1] = script.takeBossAsClaims(type(uint256).max);
        ScriptRouter.Action[] memory b = new ScriptRouter.Action[](1);
        b[0] = script.claimsToBoss(bob, type(uint256).max);
        uint256 before = _quoteBalance(alice);
        vm.prank(alice, alice);
        script.runSequence(a, 2, alice, b); // alice claims the kill prize between the two unlocks
        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(_quoteBalance(alice) - before, prize, "the signer was paid the prize");
        assertEq(killer, alice, "a paid prize does not move");
        assertEq(hook.unclaimedKill(bob), 0);
        assertEq(hook.damage(1, bob), INITIAL_HP, "the damage still follows the BOSS");
        assertEq(hook.damage(1, alice), 0);
        assertAccounting();
    }

    /// @dev The signer holds the killing credit from the kill until the BOSS leaves the pool. If she
    /// moves BOSS of her own in between, only what she really holds may travel: the credit of BOSS
    /// still inside the pool stays put, and its later arrival never underflows her balance.
    function test_signerMovesHerOwnBossBeforeTheKillBossArrives_onlyWhatSheHoldsTravels() public {
        uint256 early = uint256(bossDeltaOf(buyExactIn(alice, 0.1 ether))); // cheap early BOSS, small credit
        vm.prank(alice);
        boss.approve(address(script), type(uint256).max);
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether); // kills: 0.9 of damage, credited to alice until the BOSS leaves
        a[1] = script.pullFrom(alice, bob, early); // alice sends bob everything she actually holds
        a[2] = script.takeBoss(carol, type(uint256).max); // the kill's BOSS arrives, for carol
        vm.prank(alice, alice);
        script.run(a);
        assertEq(hook.damage(1, bob), 0.1 ether, "bob got alice's early BOSS and its credit, nothing more");
        assertEq(hook.bought(1, bob), early);
        assertEq(hook.damage(1, carol), INITIAL_HP - 0.1 ether, "the killing blow went with its BOSS to carol");
        assertEq(hook.damage(1, alice), 0);
        assertEq(hook.bought(1, alice), 0);
        (address killer,,,,) = hook.results(1);
        assertEq(killer, carol);
        assertEq(hook.eligibleDamage(1), INITIAL_HP);
        assertAccounting();
    }

    /// @dev A shared bundle (4337, 7702): after alice's killing blow, another player's transfer runs
    /// in the same transaction. Bob's BOSS carries bob's credit, as always, but it is not the kill's
    /// BOSS: the prize stays where the killing blow went.
    function test_sharedBundle_anotherPlayersTransferAfterTheKill_doesNotTakeThePrize() public {
        buyExactIn(bob, 0.8 ether); // bob's position is far larger than the killing blow's BOSS
        vm.prank(bob);
        boss.approve(address(script), type(uint256).max);
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(0.5 ether); // kills (0.2 of HP left)
        a[1] = script.takeBoss(alice, type(uint256).max);
        a[2] = script.pullFrom(bob, carol, type(uint256).max); // bob's op, bundled after alice's
        vm.prank(alice, relayer);
        script.run(a);
        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, alice, "the prize follows the killing blow's BOSS, not any BOSS of the round");
        assertEq(hook.unclaimedKill(alice), prize);
        assertEq(hook.unclaimedKill(carol), 0);
        assertEq(hook.damage(1, carol), 0.8 ether, "bob's credit still travelled with bob's BOSS");
        assertEq(hook.damage(1, alice), INITIAL_HP - 0.8 ether);
        assertEq(hook.eligibleDamage(1), INITIAL_HP);
        assertAccounting();
    }

    /// @dev The signer moves BOSS she bought before the kill after the kill's BOSS went to bob:
    /// her old credit travels with it, the prize does not.
    function test_signerMovesOldBossAfterTheKill_prizeStaysWithTheKillBoss() public {
        uint256 early = uint256(bossDeltaOf(buyExactIn(alice, 0.9 ether))); // a large early position
        vm.prank(alice);
        boss.approve(address(script), type(uint256).max);
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(0.15 ether); // kills the last 0.1 of HP, a small amount of BOSS
        a[1] = script.takeBoss(bob, type(uint256).max); // the killing blow's BOSS goes to bob
        a[2] = script.pullFrom(alice, carol, early); // alice then moves her old BOSS to carol
        vm.prank(alice, alice);
        script.run(a);
        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, bob, "bob holds all of the killing blow's BOSS");
        assertEq(hook.unclaimedKill(bob), prize);
        assertEq(hook.unclaimedKill(carol), 0);
        assertEq(hook.damage(1, carol), 0.9 ether, "alice's old credit went with her old BOSS");
        assertEq(hook.damage(1, bob), INITIAL_HP - 0.9 ether);
        assertEq(hook.damage(1, alice), 0);
        assertAccounting();
    }

    function test_killBossSentToTheHook_doesNotMoveThePrize() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether);
        a[1] = script.takeBoss(address(script), type(uint256).max);
        a[2] = script.forward(address(hook), type(uint256).max); // BOSS stuck in the hook
        vm.prank(alice, alice);
        script.run(a);
        (address killer,,,,) = hook.results(1);
        assertEq(killer, address(script), "the hook never becomes the killer");
        assertEq(hook.unclaimedKill(address(hook)), 0);
    }

    function test_hopAfterTheKill_carriesBothRoundsToThePlayer() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](4);
        a[0] = script.buy(2 ether); // kills boss 1
        a[1] = script.buy(0.4 ether); // hits boss 2
        a[2] = script.takeBoss(address(script), type(uint256).max);
        a[3] = script.forward(alice, type(uint256).max);
        vm.prank(alice, alice);
        script.run(a);
        (address killer,,,,) = hook.results(1);
        assertEq(killer, alice);
        assertEq(hook.damage(1, alice), INITIAL_HP);
        assertEq(hook.damage(2, alice), 0.4 ether);
        assertEq(hook.damage(1, address(script)) + hook.damage(2, address(script)), 0);
        assertEq(hook.bought(1, alice) + hook.bought(2, alice), boss.balanceOf(alice), "no BOSS is counted twice");
        assertAccounting();
    }

    // ------------------------------------------------------------------ guards

    function test_onBossTransfer_onlyTheToken() public {
        vm.expectRevert(BossHook.NotBossToken.selector);
        hook.onBossTransfer(alice, bob, 1);
    }

    function test_tokenIsBoundToTheHook() public view {
        assertEq(boss.hook(), address(hook));
    }
}

contract BossFollowBossBossFirstTest is BossFollowBossBase {}

contract BossFollowBossBossSecondTest is BossFollowBossBase {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
