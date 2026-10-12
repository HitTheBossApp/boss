// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BossFixture} from "./utils/BossFixture.sol";
import {BossHook} from "../src/BossHook.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Runs in both currency orderings (subclasses at the bottom). Amounts are IMD (18 decimals).
abstract contract BossGameBase is BossFixture {
    // INITIAL_HP = 1 ether (1 IMD). A buy of `x` gross hits for `x` at 1x.

    function test_buyHitsBoss() public {
        buyExactIn(alice, 0.3 ether);
        assertEq(hook.hp(), 0.7 ether);
        assertEq(hook.damage(1, alice), 0.3 ether);
        assertEq(hook.eligibleDamage(1), 0.3 ether);
        assertAccounting();
    }

    function test_sellHealsBossAndForfeits() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        uint256 before = hook.hp();
        sellExactIn(alice, got); // everything alice bought this round
        assertGt(hook.hp(), before, "healed");
        assertEq(hook.damage(1, alice), 0, "selling all she bought forfeits all her damage");
        assertEq(hook.eligibleDamage(1), 0, "alice's damage no longer eligible");
        assertAccounting();
    }

    function test_healNeverExceedsMaxHp() public {
        // A sell can only pull out ETH that buys put in, so to overflow the heal the pool needs
        // more ETH than the boss is missing: kill boss 1 (pool keeps that ETH), then chip boss 2.
        buyExactIn(bob, 1 ether);
        buyExactIn(carol, 0.2 ether);
        assertEq(hook.round(), 2);
        giveBoss(alice, 100_000_000 ether);
        sellExactIn(alice, 50_000_000 ether);
        assertEq(hook.hp(), hook.maxHp(), "heal clamped at max hp");
    }

    function test_killingBlow_capsDamageAndOpensNextRound() public {
        buyExactIn(alice, 0.6 ether);
        buyExactIn(bob, 2 ether); // overkill: only 0.4 counts
        assertEq(hook.damage(1, bob), 0.4 ether, "overkill clamped to remaining hp");
        assertEq(hook.round(), 2);
        assertEq(hook.maxHp(), 1.5 ether, "fell in under a day: 1.5x");
        assertEq(hook.hp(), 1.5 ether);
        (address killer, uint64 endedAt,,,) = hook.results(1);
        assertEq(killer, bob);
        assertEq(endedAt, block.timestamp);
        assertAccounting();
    }

    function test_potSplit_onKill() public {
        buyExactIn(alice, 0.6 ether);
        uint256 potBeforeKill = hook.pot();
        buyExactIn(bob, 0.4 ether);
        uint256 potAtKill = potBeforeKill + 0.4 ether * 15_000 / 1_000_000;
        uint256 seed = potAtKill / 10;
        uint256 killerPrize = (potAtKill - seed) / 2;
        uint256 damagePool = potAtKill - seed - killerPrize;
        (,, uint256 kp, uint256 dp, uint256 elig) = hook.results(1);
        assertEq(kp, killerPrize);
        assertEq(dp, damagePool);
        assertEq(elig, 1 ether);
        assertEq(hook.pot(), seed, "seed stays for the next boss");
        assertEq(hook.unclaimedKill(bob), killerPrize);
        assertAccounting();
    }

    function test_claimDamage_proRata() public {
        buyExactIn(alice, 0.75 ether);
        buyExactIn(bob, 0.25 ether);
        (,,, uint256 dp,) = hook.results(1);
        uint256 before = _quoteBalance(alice);
        hook.claimDamage(1, alice);
        assertEq(_quoteBalance(alice) - before, dp * 3 / 4);
        assertAccounting();
    }

    function test_claimKill_paysKiller() public {
        buyExactIn(alice, 1 ether);
        uint256 prize = hook.unclaimedKill(alice);
        uint256 before = _quoteBalance(alice);
        vm.prank(carol);
        hook.claimKill(alice);
        assertEq(_quoteBalance(alice) - before, prize);
        assertEq(hook.unclaimedKill(alice), 0);
        assertAccounting();
    }

    /// @dev The killing blow is itself fresh damage, so a kill always leaves eligible damage and the
    /// "nobody eligible" branch of BossMath.splitPot (tested in BossMath.t.sol) is not reachable.
    function test_sellerWhoKills_takesKillerHalfAndTheKillHitCounts() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        sellExactIn(alice, got); // alice sells all she bought: she forfeits all her damage
        uint256 hpNow = hook.hp();
        buyExactIn(alice, hpNow + 0.01 ether); // her killing blow is fresh damage
        (,, uint256 kp, uint256 dp, uint256 elig) = hook.results(1);
        assertEq(elig, hook.damage(1, alice), "only the killing hit is eligible");
        assertEq(hook.unclaimedKill(alice), kp, "she still gets the killer half");
        assertEq(hook.claimableDamage(1, alice), dp, "and the whole damage pool");
        assertAccounting();
    }

    // ---- Review Focus 2: sell then buy again in the same round (forfeits are proportional now)
    function test_sellerWhoBuysAgain_claimsOnlyTheNewDamage() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.2 ether)));
        sellExactIn(alice, got);
        buyExactIn(alice, 0.2 ether);
        assertEq(hook.eligibleDamage(1), 0.2 ether, "the new hit counts, the sold one does not");
        buyExactIn(bob, 2 ether); // bob kills
        (,,, uint256 dp, uint256 elig) = hook.results(1);
        uint256 before = _quoteBalance(alice);
        hook.claimDamage(1, alice);
        assertEq(_quoteBalance(alice) - before, dp * 0.2 ether / elig, "paid for the new damage only");
        assertAccounting();
    }

    // ---- Review Focus 4: bad claims
    function test_claimDamage_twiceReverts() public {
        buyExactIn(alice, 1 ether);
        hook.claimDamage(1, alice);
        vm.expectRevert(BossHook.AlreadyClaimed.selector);
        hook.claimDamage(1, alice);
        assertAccounting();
    }

    function test_claimDamage_openRoundReverts() public {
        buyExactIn(alice, 0.5 ether);
        vm.expectRevert(BossHook.RoundNotOver.selector);
        hook.claimDamage(1, alice);
    }

    function test_claimDamage_noDamageReverts() public {
        buyExactIn(alice, 1 ether);
        vm.expectRevert(BossHook.NothingToClaim.selector);
        hook.claimDamage(1, carol);
    }

    function test_claimKill_nothingReverts() public {
        vm.expectRevert(BossHook.NothingToClaim.selector);
        hook.claimKill(carol);
    }

    function test_slowKill_nextBossWeaker() public {
        buyExactIn(alice, 0.5 ether);
        vm.warp(block.timestamp + 4 days);
        buyExactIn(bob, 0.5 ether);
        assertEq(hook.maxHp(), 0.75 ether);
    }

    function test_damageInNewRoundIsSeparate() public {
        buyExactIn(alice, 1 ether);
        buyExactIn(alice, 0.3 ether);
        assertEq(hook.damage(2, alice), 0.3 ether);
        assertEq(hook.eligibleDamage(2), 0.3 ether);
    }

    // ---- Every trade is credited to its signer (tx.origin); hookData never names anyone
    function test_sellNamingSomeoneElse_onlyTouchesTheSigner() public {
        buyExactIn(alice, 0.2 ether);
        uint256 got = uint256(bossDeltaOf(buyExactIn(carol, 0.2 ether)));
        _swap(carol, SwapParams(bossIsCurrency0, -int256(got), _limit(bossIsCurrency0)), abi.encode(alice), 0);
        assertEq(hook.damage(1, alice), 0.2 ether, "named wallet untouched");
        assertEq(hook.damage(1, carol), 0, "the signer sold all she bought and forfeits all");
        assertEq(hook.eligibleDamage(1), 0.2 ether);
        assertAccounting();
    }

    // ---- Buyer identity
    function _buyWith(address actor, bytes memory hookData) internal {
        bool z = !bossIsCurrency0;
        _swap(actor, SwapParams(z, -int256(0.1 ether), _limit(z)), hookData, 0);
    }

    function test_identity_packed20BytesAreIgnored() public {
        _buyWith(carol, abi.encodePacked(bob));
        assertEq(hook.damage(1, bob), 0, "hookData never names the buyer");
        assertEq(hook.damage(1, carol), 0.1 ether, "credited to the signer");
    }

    function test_identity_encodedAddressIsIgnored() public {
        _buyWith(carol, abi.encode(bob));
        assertEq(hook.damage(1, bob), 0, "hookData never names the buyer");
        assertEq(hook.damage(1, carol), 0.1 ether, "credited to the signer");
    }

    function test_identity_emptyHookDataCreditsTheSigner() public {
        _buyWith(carol, "");
        assertEq(hook.damage(1, carol), 0.1 ether, "credited to the signer");
    }
}

contract BossGameBossFirstTest is BossGameBase {}

contract BossGameBossSecondTest is BossGameBase {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
