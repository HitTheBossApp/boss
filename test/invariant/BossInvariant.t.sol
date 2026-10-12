// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BossFixture} from "../utils/BossFixture.sol";
import {BossHandler} from "./BossHandler.sol";
import {FixedAbility} from "../mocks/Abilities.sol";

contract BossInvariantTest is BossFixture {
    using stdStorage for StdStorage;

    BossHandler handler;

    function setUp() public override {
        super.setUp();
        // Every trade runs through an active ability (1.5x hits, 0.75x heals) so its paths are covered.
        address ability = address(new FixedAbility(15_000, 7_500));
        stdstore.target(address(hook)).sig("activeAbility()").checked_write(ability);
        handler =
            new BossHandler(hook, boss, quoteToken, swapRouter, IPoolManager(address(manager)), key, bossIsCurrency0);
        targetContract(address(handler));
    }

    function invariant_moneyIsAccountedFor() public view {
        assertAccounting();
    }

    /// @dev Every fee ever charged is either still held as claims or was actually received by a
    /// player or the keeper: nothing leaks and nothing is paid twice.
    function invariant_feesEqualHeldPlusPaid() public view {
        assertEq(
            handler.totalPaidOut() + handler.treasuryPaid() + hookQuoteClaims(),
            handler.totalFees(),
            "fees charged == paid out + treasury paid + held"
        );
    }

    function invariant_hpWithinBounds() public view {
        assertLe(hook.hp(), hook.maxHp());
        assertGe(hook.maxHp(), INITIAL_HP / 4);
        assertLe(hook.maxHp(), INITIAL_HP * 16);
    }

    /// @dev Every wallet that can hold credit: the actors, the bait contract that trades inside
    /// their transactions (its buys are credited to it, since it receives the BOSS), and the
    /// relayer that only signs (it must never hold any).
    function _damageHeld(uint64 r) internal view returns (uint256 sum) {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += hook.damage(r, handler.actors(i));
        }
        sum += hook.damage(r, address(handler.bait())) + hook.damage(r, handler.relayer());
        sum += hook.damage(r, address(handler.custody())) + hook.damage(r, handler.feeCollector());
    }

    /// @dev A router that custodies BOSS and delivers it never keeps credit, the kill or the prize.
    function invariant_custodyRouterKeepsNothing() public view {
        address router = address(handler.custody());
        assertEq(hook.unclaimedKill(router), 0, "no prize sits on the router");
        for (uint64 r = 1; r <= hook.round(); r++) {
            assertEq(hook.damage(r, router), 0, "no damage sits on the router");
            assertEq(hook.bought(r, router), 0, "no BOSS is counted to the router");
            if (r < hook.round()) {
                (address killer,,,,) = hook.results(r);
                assertTrue(killer != router, "the router is never the killer");
            }
        }
    }

    function invariant_closedRoundsNeverOverpay() public view {
        for (uint64 r = 1; r < hook.round(); r++) {
            (,,, uint256 damagePool, uint256 elig) = hook.results(r);
            assertEq(_damageHeld(r), elig, "eligible damage == sum of the damage players still hold");
            assertLe(handler.damagePaidInRound(r), damagePool, "damage claims of a round <= its damage pool");
        }
    }

    function invariant_openRoundCreditIsHeldBySomeone() public view {
        uint64 r = hook.round();
        assertEq(_damageHeld(r), hook.eligibleDamage(r), "open round: eligible damage == damage held");
        assertEq(hook.damage(r, handler.relayer()), 0, "a signer that never receives BOSS holds no credit");
    }

    /// @dev Credit never outlives the BOSS it came with: a wallet's round-r BOSS count never exceeds
    /// its balance, and a wallet without round-r BOSS holds no round-r damage.
    function invariant_creditNeverExceedsTheBossHeld() public view {
        uint64 r = hook.round();
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            assertLe(hook.bought(r, a), boss.balanceOf(a), "bought this round <= BOSS held");
            if (hook.bought(r, a) == 0) assertEq(hook.damage(r, a), 0, "no BOSS from this round, no damage");
        }
    }

    /// @dev The hook is a sink: BOSS sent to it never makes it a creditor or a winner.
    function invariant_theHookHoldsNoCredit() public view {
        assertEq(hook.unclaimedKill(address(hook)), 0, "no prize on the hook");
        for (uint64 r = 1; r <= hook.round(); r++) {
            assertEq(hook.damage(r, address(hook)), 0, "no damage on the hook");
        }
    }

    /// @dev Kill prizes accrue per winner across rounds, so the bound is per winner: what a wallet
    /// received through claimKill never exceeds the prizes of the rounds it killed.
    function invariant_killClaimsWithinPrizes() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            uint256 won;
            for (uint64 r = 1; r < hook.round(); r++) {
                (address killer,, uint256 killerPrize,,) = hook.results(r);
                if (killer == a) won += killerPrize;
            }
            assertLe(handler.killPaidTo(a), won, "kill claims <= killer prizes won");
            assertEq(handler.killPaidTo(a) + hook.unclaimedKill(a), won, "paid + unclaimed == won");
        }
    }

    /// @dev Coverage visibility only, no assertion.
    function invariant_callSummary() public view {
        console2.log("kills", uint256(hook.round() - 1));
        console2.log("swaps ok", handler.swapsOk());
        console2.log("exact-out buys ok", handler.exactOutBuysOk());
        console2.log("exact-out sells ok", handler.exactOutSellsOk());
        console2.log("bait trades ok", handler.baitTradesOk());
        console2.log("relayed trades ok", handler.relayedOk());
        console2.log("transfers", handler.transfers());
        console2.log("flash round trips ok", handler.flashOk());
        console2.log("buys as claims", handler.claimsBuys());
        console2.log("routed buys ok", handler.routedOk());
        console2.log("damage claims", handler.damageClaims());
        console2.log("kill claims", handler.killClaims());
        console2.log("treasury claims", handler.treasuryClaims());
    }
}
