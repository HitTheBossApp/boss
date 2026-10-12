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
        buyExactIn(alice, 0.5 ether);
        uint256 before = hook.hp();
        sellExactIn(alice, 100_000 ether); // alice holds ~194k BOSS from the buy
        assertGt(hook.hp(), before, "healed");
        assertTrue(hook.sold(1, alice));
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

    function test_noEligibleDamage_rollsIntoSeed() public {
        buyExactIn(alice, 0.5 ether);
        sellExactIn(alice, 1_000 ether); // alice forfeits
        uint256 hpNow = hook.hp();
        // alice (already sold) lands the killing blow: she still gets the killer half
        buyExactIn(alice, hpNow + 0.01 ether);
        (,, uint256 kp, uint256 dp, uint256 elig) = hook.results(1);
        assertEq(elig, 0);
        assertEq(dp, 0, "nobody eligible: damage half goes to the seed");
        assertEq(hook.unclaimedKill(alice), kp);
        assertAccounting();
    }

    // ---- Review Focus 2: sell then buy again in the same round
    function test_soldWallet_newDamageNotEligible() public {
        buyExactIn(alice, 0.2 ether);
        sellExactIn(alice, 1_000 ether);
        buyExactIn(alice, 0.2 ether);
        assertEq(hook.eligibleDamage(1), 0, "new damage from a seller is never eligible");
        buyExactIn(bob, 2 ether); // bob kills
        vm.expectRevert(BossHook.SoldThisRound.selector);
        hook.claimDamage(1, alice);
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
        assertFalse(hook.sold(2, alice));
    }

    // ---- Controller ruling: sells are attributed to tx.origin, never to hookData
    function test_sellNamingSomeoneElse_forfeitsSignerNotNamed() public {
        buyExactIn(alice, 0.2 ether);
        buyExactIn(bob, 0.2 ether);
        giveBoss(carol, 1_000_000 ether);
        _swap(carol, SwapParams(bossIsCurrency0, -int256(1_000 ether), _limit(bossIsCurrency0)), abi.encode(alice), 0);
        assertFalse(hook.sold(1, alice), "named wallet untouched");
        assertTrue(hook.sold(1, carol), "signer forfeits");
        assertEq(hook.eligibleDamage(1), 0.4 ether);
        assertAccounting();
    }

    // ---- Buyer identity
    function _buyWith(address actor, bytes memory hookData) internal {
        bool z = !bossIsCurrency0;
        _swap(actor, SwapParams(z, -int256(0.1 ether), _limit(z)), hookData, 0);
    }

    function test_identity_packed20BytesCreditsThatAddress() public {
        _buyWith(carol, abi.encodePacked(bob));
        assertEq(hook.damage(1, bob), 0.1 ether, "20 packed bytes name the buyer");
        assertEq(hook.damage(1, carol), 0);
    }

    function test_identity_dirtyUpperBitsFallBackToOrigin() public {
        bytes memory dirty = abi.encode(uint256(uint160(bob)) | (uint256(1) << 200));
        _buyWith(carol, dirty);
        assertEq(hook.damage(1, bob), 0, "a word with dirty upper bits is not an address");
        // PoolSwapTest has no msgSender(), so the next fallback is tx.origin.
        assertEq(hook.damage(1, carol), 0.1 ether, "credited to the signer");
    }

    function test_identity_emptyHookDataFallsBackToOrigin() public {
        _buyWith(carol, "");
        assertEq(hook.damage(1, carol), 0.1 ether, "PoolSwapTest has no msgSender(): tx.origin");
    }
}

contract BossGameBossFirstTest is BossGameBase {}

contract BossGameBossSecondTest is BossGameBase {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
