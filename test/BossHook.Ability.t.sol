// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {SwapParams as SwapParamsAlias} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest as PoolSwapTestAlias} from "v4-core/src/test/PoolSwapTest.sol";
import {BossFixture} from "./utils/BossFixture.sol";
import {BossHook} from "../src/BossHook.sol";
import {SwapInfo} from "../src/interfaces/IAbility.sol";
import {
    FixedAbility,
    WhaleNerfAbility,
    RevertingAbility,
    GasBombAbility,
    ShortReturnAbility,
    HugeAbility,
    StateWriterAbility,
    BurnerAbility
} from "./mocks/Abilities.sol";

contract BossAbilityTest is BossFixture {
    using stdStorage for StdStorage;

    function _activate(address ability) internal {
        stdstore.target(address(hook)).sig("activeAbility()").checked_write(ability);
        assertEq(hook.activeAbility(), ability);
    }

    function test_fixedAbility_doublesBuys_halvesHeals() public {
        _activate(address(new FixedAbility(20_000, 5_000)));
        buyExactIn(alice, 0.2 ether);
        assertEq(hook.hp(), 0.6 ether, "0.2 gross at 2x = 0.4 damage");
    }

    function test_whaleNerf() public {
        _activate(address(new WhaleNerfAbility()));
        buyExactIn(alice, 0.5 ether);
        assertEq(hook.hp(), 0.5 ether, "small buy: 1x");
        buyExactIn(bob, 4 ether);
        assertEq(hook.round(), 2, "4 ether at 0.5x = 2 ether >= 0.5 remaining");
    }

    function test_revertingAbility_fallsBackTo1x() public {
        _activate(address(new RevertingAbility()));
        buyExactIn(alice, 0.2 ether);
        assertEq(hook.hp(), 0.8 ether);
        assertAccounting();
    }

    function test_gasBomb_fallsBackTo1x_andSwapSucceeds() public {
        _activate(address(new GasBombAbility()));
        buyExactIn(alice, 0.2 ether);
        assertEq(hook.hp(), 0.8 ether);
    }

    function test_shortReturn_fallsBackTo1x() public {
        _activate(address(new ShortReturnAbility()));
        buyExactIn(alice, 0.2 ether);
        assertEq(hook.hp(), 0.8 ether);
    }

    function test_hugeValues_clamped() public {
        _activate(address(new HugeAbility()));
        buyExactIn(alice, 0.2 ether);
        assertEq(hook.hp(), 0.2 ether, "4x max: 0.8 damage");
        giveBoss(bob, 10_000_000 ether);
        uint256 before = hook.hp();
        sellExactIn(bob, 1_000_000 ether);
        assertGt(hook.hp(), before, "sell multiplier 0 clamps to 0.25x, still heals");
    }

    function test_stateWriter_fallsBackTo1x() public {
        StateWriterAbility a = new StateWriterAbility();
        _activate(address(a));
        buyExactIn(alice, 0.2 ether);
        assertEq(hook.hp(), 0.8 ether, "STATICCALL blocked the write, 1x applied");
        assertEq(a.calls(), 0);
    }

    // ---- Review Focus 1: starving gas must revert, never fall back to 1x
    function test_starvedGas_revertsInsteadOfFallback() public {
        _activate(address(new WhaleNerfAbility()));
        bool zeroForOne = !bossIsCurrency0;
        bytes memory call = abi.encodeCall(
            swapRouter.swap,
            (
                key,
                SwapParamsAlias(zeroForOne, -int256(1 ether), _limit(zeroForOne)),
                PoolSwapTestAlias.TestSettings(false, false),
                abi.encode(alice)
            )
        );
        // Find a gas limit that reaches the ability call with less than the floor left.
        bool sawFloorRevert;
        for (uint256 g = 120_000; g < 400_000; g += 2_000) {
            vm.prank(alice, alice);
            (bool ok, bytes memory ret) = address(swapRouter).call{gas: g, value: useNative() ? 1 ether : 0}(call);
            if (ok) {
                // A success must never have applied the 1x fallback to a whale buy.
                assertEq(hook.damage(1, alice), 0.5 ether, "whale nerf applied, not 1x");
                break;
            }
            if (_containsSelector(ret, BossHook.InsufficientGasForAbility.selector)) sawFloorRevert = true;
        }
        assertTrue(sawFloorRevert, "some gas limit hit the floor check");
    }

    /// @dev Fine scan (500 gas steps) across the floor boundary with an ability that needs ~45k
    /// of its 50k: every success must have applied 2x (the ability really got its gas, never the
    /// 1x fallback), and some limit must hit InsufficientGasForAbility.
    function test_burner_fineScanNearFloor_neverFallsBack() public {
        BurnerAbility burner = new BurnerAbility();
        _activate(address(burner));
        // The probe is sharp: it fails with 45k of gas and succeeds with the full 50k.
        bytes memory probe = abi.encodeWithSelector(BurnerAbility.modifiers.selector, _info());
        (bool okLow,) = address(burner).staticcall{gas: 45_000}(probe);
        (bool okFull,) = address(burner).staticcall{gas: 50_000}(probe);
        assertFalse(okLow, "burner fails below its need");
        assertTrue(okFull, "burner succeeds with ABILITY_GAS");

        bool zeroForOne = !bossIsCurrency0;
        bytes memory call = abi.encodeCall(
            swapRouter.swap,
            (
                key,
                SwapParamsAlias(zeroForOne, -int256(0.2 ether), _limit(zeroForOne)),
                PoolSwapTestAlias.TestSettings(false, false),
                abi.encode(alice)
            )
        );
        bool sawFloorRevert;
        uint256 successes;
        for (uint256 g = 150_000; g < 700_000 && successes < 20; g += 500) {
            uint256 snap = vm.snapshotState();
            vm.prank(alice, alice);
            (bool ok, bytes memory ret) = address(swapRouter).call{gas: g, value: useNative() ? 0.2 ether : 0}(call);
            if (ok) {
                successes++;
                assertEq(hook.damage(1, alice), 0.4 ether, "burner applied 2x, never the 1x fallback");
            } else if (_containsSelector(ret, BossHook.InsufficientGasForAbility.selector)) {
                sawFloorRevert = true;
            }
            vm.revertToState(snap);
        }
        assertEq(successes, 20, "the scan reached the success region");
        assertTrue(sawFloorRevert, "some gas limit hit the floor check");
    }

    function _info() internal view returns (SwapInfo memory s) {
        s = SwapInfo({
            trader: alice,
            isBuy: true,
            amount: 0.2 ether,
            timestamp: block.timestamp,
            round: 1,
            hp: 1 ether,
            maxHp: 1 ether,
            pot: 0
        });
    }

    function _containsSelector(bytes memory ret, bytes4 sel) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= ret.length; i++) {
            if (bytes4(ret[i]) == sel[0] && ret[i + 1] == sel[1] && ret[i + 2] == sel[2] && ret[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }
}
