// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BossFixture} from "../utils/BossFixture.sol";
import {BossHook} from "../../src/BossHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev A kill winner that is a contract. When the hook pays it (native ETH, inside the hook's own
/// unlock) it tries to re-enter the claims and, since the PoolManager is unlocked by the hook at that
/// moment, trades directly on the pool from inside the payout.
contract Reenterer {
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    BossHook internal immutable hook;
    PoolSwapTest internal immutable router;
    PoolKey internal key;
    bool internal immutable bossIs0;
    bool public reenteredClaim;
    bool public tradedInsidePayout;
    bool public armed;

    constructor(IPoolManager m, BossHook h, PoolSwapTest r, PoolKey memory k, bool b0) {
        manager = m;
        hook = h;
        router = r;
        key = k;
        bossIs0 = b0;
    }

    function kill(uint256 ethIn) external payable {
        bool z = !bossIs0;
        router.swap{value: ethIn}(
            key, SwapParams(z, -int256(ethIn), _limit(z)), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function arm() external {
        armed = true;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        try hook.claimKill(address(this)) {
            reenteredClaim = true;
        } catch {}
        try hook.claimDamage(1, address(this)) {
            reenteredClaim = true;
        } catch {}
        // The manager is unlocked by the hook's _payout: a direct swap goes through.
        uint256 spend = msg.value / 2;
        bool z = !bossIs0;
        manager.swap(key, SwapParams(z, -int256(spend), _limit(z)), "");
        manager.settle{value: spend}();
        Currency bossC = bossIs0 ? key.currency0 : key.currency1;
        int256 owed = manager.currencyDelta(address(this), bossC);
        if (owed > 0) manager.take(bossC, address(this), uint256(owed));
        tradedInsidePayout = true;
    }

    function _limit(bool z) internal pure returns (uint160) {
        return z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
}

/// @notice Native-ETH pairing (not the launch pairing, which is IMD): the one shape where `_payout`
/// hands control to the recipient while the hook holds the PoolManager lock. The claims stay closed
/// (nonReentrant); a trade inside the payout is possible and is accounted like any other.
contract ReviewNativeReentrancyTest is BossFixture {
    address internal hunter = makeAddr("hunter");
    Reenterer internal re;

    function useNative() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        re = new Reenterer(IPoolManager(address(manager)), hook, swapRouter, key, bossIsCurrency0);
        vm.deal(address(re), 10 ether);
        buyExactIn(alice, 0.5 ether); // volume: a pot worth claiming, boss 1 still alive
    }

    function test_probeJ_payoutRecipient_cannotReenterClaims_butCanTradeInsideTheHooksUnlock() public {
        vm.prank(hunter, hunter);
        re.kill(5 ether); // the router takes the BOSS to the Reenterer: kill, prize and damage follow it
        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, address(re));
        assertEq(hook.unclaimedKill(hunter), 0, "the signer kept nothing");
        assertGt(prize, 0);

        re.arm();
        uint256 before = address(re).balance;
        hook.claimKill(address(re));
        assertFalse(re.reenteredClaim(), "nonReentrant held for claimKill and claimDamage");
        assertTrue(re.tradedInsidePayout(), "a swap inside the hook's own unlock went through");
        assertEq(address(re).balance - before, prize - prize / 2, "paid once, half re-spent on the pool");
        assertGt(hook.damage(2, address(re)), 0, "the inside-payout buy was credited like any other");
        assertEq(hook.eligibleDamage(2), hook.damage(2, address(re)));
        assertAccounting();
        // And the damage pool is still paid exactly once.
        (,,, uint256 dp,) = hook.results(1);
        uint256 b = address(re).balance;
        hook.claimDamage(1, address(re));
        assertEq(address(re).balance - b, dp * hook.damage(1, address(re)) / hook.eligibleDamage(1));
        vm.expectRevert(BossHook.AlreadyClaimed.selector);
        hook.claimDamage(1, address(re));
        assertAccounting();
    }
}
