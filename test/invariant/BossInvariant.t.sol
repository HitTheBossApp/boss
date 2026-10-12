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

    function invariant_closedRoundsNeverOverpay() public view {
        for (uint64 r = 1; r < hook.round(); r++) {
            uint256 sum;
            for (uint256 i = 0; i < handler.actorCount(); i++) {
                address a = handler.actors(i);
                if (!hook.sold(r, a)) sum += hook.damage(r, a);
            }
            (,,, uint256 damagePool, uint256 elig) = hook.results(r);
            assertEq(sum, elig, "eligible damage == sum of non-sellers damage");
            assertLe(handler.damagePaidInRound(r), damagePool, "damage claims of a round <= its damage pool");
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
        console2.log("damage claims", handler.damageClaims());
        console2.log("kill claims", handler.killClaims());
        console2.log("treasury claims", handler.treasuryClaims());
    }
}
