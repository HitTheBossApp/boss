// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey as PoolKeyAlias} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BossFixture} from "./utils/BossFixture.sol";
import {BossHook} from "../src/BossHook.sol";
import {BossToken} from "../src/BossToken.sol";

/// @notice The 2.5% fee is always charged in the paired currency, on all four swap shapes, and
/// split 60/40 between the pot and the treasury.
abstract contract BossFeesBase is BossFixture {
    uint256 constant PIPS = 1_000_000;

    function test_buyExactIn_feeFromQuoteInput() public {
        BalanceDelta d = buyExactIn(alice, 1 ether);
        assertEq(quoteDeltaOf(d), -1 ether, "spends exactly the quote asked");
        assertGt(bossDeltaOf(d), 0);
        assertEq(hookQuoteClaims(), 0.025 ether, "2.5% of the input");
        // The 1 ether buy now also kills the 1 ether boss, so the pot is split into seed + reserved prizes.
        assertEq(hook.pot() + hook.totalReserved(), 0.015 ether, "1.5% to the pot");
        assertEq(hook.treasuryOwed(), 0.01 ether, "1% to the treasury");
        assertAccounting();
    }

    function test_buyExactOut_feeOnTop() public {
        BalanceDelta d = buyExactOut(alice, 1_000_000 ether, 5 ether);
        assertEq(bossDeltaOf(d), 1_000_000 ether);
        uint256 paid = uint256(-quoteDeltaOf(d));
        uint256 fee = hookQuoteClaims();
        assertEq(
            fee, (paid - fee) * hook.FEE_PIPS() / (PIPS - hook.FEE_PIPS()), "2.5% of gross, on top of the pool input"
        );
        assertAccounting();
    }

    function test_sellExactIn_feeFromQuoteOutput() public {
        buyExactIn(bob, 2 ether);
        giveBoss(alice, 1_000_000 ether);
        uint256 before = hookQuoteClaims();
        BalanceDelta d = sellExactIn(alice, 1_000_000 ether);
        uint256 received = uint256(quoteDeltaOf(d));
        uint256 fee = hookQuoteClaims() - before;
        assertEq(fee, (received + fee) * hook.FEE_PIPS() / PIPS, "2.5% of the pool output");
        assertAccounting();
    }

    function test_sellExactOut_feeOnTop() public {
        buyExactIn(bob, 2 ether);
        giveBoss(alice, 50_000_000 ether);
        uint256 before = hookQuoteClaims();
        BalanceDelta d = sellExactOut(alice, 0.1 ether);
        assertEq(quoteDeltaOf(d), 0.1 ether, "receives exactly the quote asked");
        assertEq(hookQuoteClaims() - before, uint256(0.1 ether) * hook.FEE_PIPS() / (PIPS - hook.FEE_PIPS()));
        assertAccounting();
    }

    function test_claimTreasury_paysKeeperOnly() public {
        buyExactIn(alice, 1 ether);
        uint256 owed = hook.treasuryOwed();
        uint256 before = _quoteBalance(keeper);
        vm.prank(bob);
        hook.claimTreasury();
        assertEq(_quoteBalance(keeper) - before, owed);
        assertEq(hook.treasuryOwed(), 0);
        assertAccounting();
    }

    function test_claimTreasury_nothingReverts() public {
        vm.expectRevert(BossHook.NothingToClaim.selector);
        hook.claimTreasury();
    }

    function test_secondPoolRefused() public {
        uint160 price = TickMath.getSqrtPriceAtTick(launchTick());
        _expectInitRevert(address(hook), abi.encodeWithSelector(BossHook.PoolAlreadyInitialized.selector));
        manager.initialize(_otherKey(), price);
    }

    function test_sameKeyTwiceRefused() public {
        uint160 price = TickMath.getSqrtPriceAtTick(launchTick());
        _expectInitRevert(address(hook), abi.encodeWithSelector(BossHook.PoolAlreadyInitialized.selector));
        manager.initialize(key, price);
    }

    // ------------------------------------------------------------- pinned pool key

    function test_initialize_wrongPairedCurrencyReverts() public {
        BossHook fresh = _freshHook();
        MockERC20 other = new MockERC20("Other", "OTH", 0);
        bool bossFirst = address(freshBoss) < address(other);
        PoolKeyAlias memory k = PoolKeyAlias({
            currency0: Currency.wrap(bossFirst ? address(freshBoss) : address(other)),
            currency1: Currency.wrap(bossFirst ? address(other) : address(freshBoss)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(fresh))
        });
        int24 t = bossFirst ? -int24(launchTickAbs()) : int24(launchTickAbs());
        _expectInitRevert(address(fresh), abi.encodeWithSelector(BossHook.WrongPairedCurrency.selector));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(t));
    }

    function test_initialize_wrongFeeReverts() public {
        BossHook fresh = _freshHook();
        PoolKeyAlias memory k = _keyOn(fresh, 10_000, TICK_SPACING);
        _expectInitRevert(address(fresh), abi.encodeWithSelector(BossHook.WrongLPFee.selector, uint24(10_000)));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(launchTick()));
    }

    function test_initialize_wrongTickSpacingReverts() public {
        BossHook fresh = _freshHook();
        PoolKeyAlias memory k = _keyOn(fresh, LP_FEE, 10);
        _expectInitRevert(address(fresh), abi.encodeWithSelector(BossHook.WrongTickSpacing.selector, int24(10)));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(launchTick()));
    }

    function test_initialize_wrongStartingTickReverts() public {
        BossHook fresh = _freshHook();
        PoolKeyAlias memory k = _keyOn(fresh, LP_FEE, TICK_SPACING);
        int24 bad = launchTick() + 301;
        uint160 price = TickMath.getSqrtPriceAtTick(bad);
        _expectInitRevert(
            address(fresh), abi.encodeWithSelector(BossHook.WrongStartingPrice.selector, price, bad, launchTick())
        );
        manager.initialize(k, price);
    }

    function test_initialize_freshHookAcceptsExactKey() public {
        BossHook fresh = _freshHook();
        manager.initialize(_keyOn(fresh, LP_FEE, TICK_SPACING), TickMath.getSqrtPriceAtTick(launchTick() + 300));
        assertTrue(fresh.poolInitialized());
    }

    function test_constructor_pairedEqualsTokenReverts() public {
        bytes memory code = abi.encodePacked(type(BossHook).creationCode, hookArgsWith(INITIAL_HP, address(boss)));
        vm.expectRevert(BossHook.InvalidConfig.selector);
        this.rawCreate(code);
    }

    /// @dev The swarm factory takes flat static args only: exactly 9 words, in launch.json order.
    function test_constructorArgs_nineFlatStaticWords() public view {
        bytes memory a = hookArgs();
        assertEq(a.length, 9 * 32, "9 words");
        assertEq(_word(a, 6), INITIAL_HP);
        assertEq(_word(a, 7), uint256(launchTickAbs()));
        assertEq(_word(a, 8), uint256(uint160(pairedAddr)));
        assertEq(hook.pairedCurrency(), pairedAddr);
        assertEq(uint256(hook.PANEL_SIZE()), uint256(PANEL));
        assertEq(uint256(hook.QUORUM()), uint256(QUORUM));
        assertEq(hook.LP_FEE(), LP_FEE);
        assertEq(hook.TICK_SPACING(), TICK_SPACING);
        assertEq(hook.panelSize(), PANEL);
        assertEq(hook.quorum(), QUORUM);
    }

    function _word(bytes memory a, uint256 i) internal pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := mload(add(add(a, 32), mul(i, 32)))
        }
    }

    /// @dev Plain CREATE that bubbles the constructor's revert data (the pin checks run before
    /// the hook-address check, so the address does not matter).
    function rawCreate(bytes memory code) external returns (address addr) {
        assembly ("memory-safe") {
            addr := create(0, add(code, 32), mload(code))
            if iszero(addr) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    /// @dev A token binds to one hook for good, so a fresh hook comes with a fresh BOSS token,
    /// ordered against the paired currency like the fixture's.
    BossToken internal freshBoss;

    function _freshHook() internal returns (BossHook) {
        freshBoss = _deployBossOrdered(pairedAddr, bossIsCurrency0);
        return deployHookWith(hookArgsFor(address(freshBoss), INITIAL_HP + 1, pairedAddr));
    }

    function _keyOn(BossHook h, uint24 fee, int24 spacing) internal view returns (PoolKeyAlias memory) {
        Currency fresh = Currency.wrap(address(freshBoss));
        return PoolKeyAlias({
            currency0: bossIsCurrency0 ? fresh : key.currency0,
            currency1: bossIsCurrency0 ? key.currency1 : fresh,
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(h))
        });
    }

    /// @dev The PoolManager wraps hook reverts; assert on the hook's own error.
    function _expectInitRevert(address target, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                target,
                IHooks.beforeInitialize.selector,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _otherKey() internal view returns (PoolKeyAlias memory k) {
        k = PoolKeyAlias({
            currency0: key.currency0, currency1: key.currency1, fee: 10_000, tickSpacing: 200, hooks: key.hooks
        });
    }
}

/// @dev BOSS/IMD as launched, BOSS sorting first.
contract BossFeesImdBossFirstTest is BossFeesBase {}

/// @dev BOSS/IMD as launched, BOSS sorting second.
contract BossFeesImdBossSecondTest is BossFeesBase {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

/// @dev Native-ETH variant: the hook stays pair-agnostic.
contract BossFeesNativeTest is BossFeesBase {
    function useNative() internal pure override returns (bool) {
        return true;
    }
}
