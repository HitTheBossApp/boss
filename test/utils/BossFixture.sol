// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {HookFlags} from "../../src/HookFlags.sol";
import {BossToken} from "../../src/BossToken.sol";
import {BossHook} from "../../src/BossHook.sol";
import {AbilityBoard} from "../../src/AbilityBoard.sol";
import {IAbilityBoard} from "../../src/interfaces/IAbility.sol";
import {OracleGate} from "../../src/OracleGate.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice A fresh PoolManager, the BOSS token, an AbilityBoard, the hook at a mined address and
/// the pool seeded single-sided with 90% of the supply, as the launch does. Pairs with a mock IMD
/// (18-decimal ERC-20) by default, as launched; override `useNative` for the native-ETH variant.
abstract contract BossFixture is Test {
    uint160 internal constant HOOK_FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    uint24 internal constant LP_FEE = 12_500;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant POOL_SHARE = 900_000_000 ether;
    uint256 internal constant FUNDING = 10_000 ether;
    uint256 internal constant INITIAL_HP = 1 ether;
    uint16 internal constant PANEL = 21;
    uint16 internal constant QUORUM = 15;
    bytes32 internal constant QUESTION = keccak256("boss-ability-question-v1");

    PoolManager internal manager;
    BossToken internal boss;
    MockERC20 internal quoteToken; // unset when native
    BossHook internal hook;
    AbilityBoard internal board;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    PoolKey internal key;
    bool internal bossIsCurrency0;
    /// @dev The pool's paired currency (address(0) when native).
    address internal pairedAddr;
    uint256 internal launchTime;

    uint256 internal oracleKey = 0x0DAC1E;
    address internal oracleSigner;
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function useNative() internal pure virtual returns (bool) {
        return false;
    }

    function wantBossIsCurrency0() internal pure virtual returns (bool) {
        return true;
    }

    function launchTickAbs() internal pure virtual returns (uint24) {
        return useNative() ? 184_200 : 129_000;
    }

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        oracleSigner = vm.addr(oracleKey);
        manager = new PoolManager(address(this));

        Currency quote;
        if (useNative()) {
            boss = new BossToken();
            quote = Currency.wrap(address(0));
        } else {
            quoteToken = new MockERC20("IdentityMD", "IMD", 0);
            boss = _deployBossOrdered(address(quoteToken), wantBossIsCurrency0());
            quote = Currency.wrap(address(quoteToken));
        }
        bossIsCurrency0 = address(boss) < Currency.unwrap(quote);
        pairedAddr = Currency.unwrap(quote);

        board = new AbilityBoard(keeper);
        hook = deployHook();

        (Currency c0, Currency c1) =
            bossIsCurrency0 ? (Currency.wrap(address(boss)), quote) : (quote, Currency.wrap(address(boss)));
        key = PoolKey({currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))});

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        launchTime = block.timestamp;
        manager.initialize(key, TickMath.getSqrtPriceAtTick(launchTick()));
        _seedSingleSided();

        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    // ------------------------------------------------------------------ deployment

    function hookArgs() internal view returns (bytes memory) {
        return hookArgsWith(INITIAL_HP, pairedAddr);
    }

    /// @dev Constructor args (9 flat words) with hp and paired currency overridable (a different `hp` gives a different
    /// init code, so a second hook can be mined next to the fixture's).
    function hookArgsWith(uint256 hp, address paired) internal view returns (bytes memory) {
        return abi.encode(
            IPoolManager(address(manager)),
            address(boss),
            keeper,
            IAbilityBoard(address(board)),
            oracleSigner,
            QUESTION,
            hp,
            launchTickAbs(),
            paired
        );
    }

    function deployHook() internal returns (BossHook) {
        return deployHookWith(hookArgs());
    }

    function deployHookWith(bytes memory args) internal returns (BossHook deployed) {
        bytes memory initCode = abi.encodePacked(type(BossHook).creationCode, args);
        (bytes32 salt, address predicted) = HookFlags.mineSalt(address(this), initCode, HOOK_FLAGS, 300_000);
        address addr;
        assembly ("memory-safe") {
            addr := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(addr != address(0), "hook deploy failed");
        deployed = BossHook(addr);
        assertEq(address(deployed), predicted, "hook address");
    }

    function _deployBossOrdered(address other, bool before) internal returns (BossToken token) {
        bytes32 initHash = keccak256(type(BossToken).creationCode);
        for (uint256 i = 0; i < 1_000; i++) {
            address predicted = HookFlags.computeAddress(address(this), bytes32(i), initHash);
            if ((predicted < other) == before) {
                token = new BossToken{salt: bytes32(i)}();
                return token;
            }
        }
        revert("no ordering salt");
    }

    function launchTick() internal view returns (int24) {
        int24 abs_ = int24(launchTickAbs());
        return bossIsCurrency0 ? -abs_ : abs_;
    }

    function _seedSingleSided() internal {
        boss.approve(address(lpRouter), type(uint256).max);
        int24 tick = launchTick();
        int24 lower;
        int24 upper;
        uint128 liquidity;
        if (bossIsCurrency0) {
            lower = tick + TICK_SPACING;
            upper = TickMath.maxUsableTick(TICK_SPACING);
            liquidity = LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), POOL_SHARE
            );
        } else {
            lower = TickMath.minUsableTick(TICK_SPACING);
            upper = tick - TICK_SPACING;
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), POOL_SHARE
            );
        }
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), 0), "");
    }

    function _fund(address who) internal {
        if (useNative()) {
            vm.deal(who, FUNDING);
        } else {
            quoteToken.mint(who, FUNDING);
            vm.prank(who);
            quoteToken.approve(address(swapRouter), type(uint256).max);
        }
        vm.prank(who);
        boss.approve(address(swapRouter), type(uint256).max);
    }

    // ------------------------------------------------------------------ trading

    function _swap(address actor, SwapParams memory params, bytes memory hookData, uint256 value)
        internal
        returns (BalanceDelta)
    {
        vm.prank(actor, actor);
        return swapRouter.swap{value: value}(key, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function buyExactIn(address actor, uint256 quoteAmount) internal returns (BalanceDelta) {
        bool zeroForOne = !bossIsCurrency0;
        return _swap(
            actor,
            SwapParams(zeroForOne, -int256(quoteAmount), _limit(zeroForOne)),
            abi.encode(actor),
            useNative() ? quoteAmount : 0
        );
    }

    function buyExactOut(address actor, uint256 bossAmount, uint256 maxQuote) internal returns (BalanceDelta) {
        bool zeroForOne = !bossIsCurrency0;
        return _swap(
            actor, SwapParams(zeroForOne, int256(bossAmount), _limit(zeroForOne)), abi.encode(actor), useNative() ? maxQuote : 0
        );
    }

    function sellExactIn(address actor, uint256 bossAmount) internal returns (BalanceDelta) {
        bool zeroForOne = bossIsCurrency0;
        return _swap(actor, SwapParams(zeroForOne, -int256(bossAmount), _limit(zeroForOne)), abi.encode(actor), 0);
    }

    function sellExactOut(address actor, uint256 quoteAmount) internal returns (BalanceDelta) {
        bool zeroForOne = bossIsCurrency0;
        return _swap(actor, SwapParams(zeroForOne, int256(quoteAmount), _limit(zeroForOne)), abi.encode(actor), 0);
    }

    function quoteDeltaOf(BalanceDelta d) internal view returns (int256) {
        return bossIsCurrency0 ? int256(d.amount1()) : int256(d.amount0());
    }

    function bossDeltaOf(BalanceDelta d) internal view returns (int256) {
        return bossIsCurrency0 ? int256(d.amount0()) : int256(d.amount1());
    }

    /// @dev Buys some BOSS for `who` so they can sell. Uses `carol`'s quote by default.
    function giveBoss(address who, uint256 amount) internal {
        boss.transfer(who, amount);
    }

    // ------------------------------------------------------------------ state

    function _quoteBalance(address who) internal view returns (uint256) {
        return useNative() ? who.balance : quoteToken.balanceOf(who);
    }

    function hookQuoteClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), hook.quote().toId());
    }

    function hookBossClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), Currency.wrap(address(boss)).toId());
    }

    function assertAccounting() internal view {
        assertEq(hookQuoteClaims(), hook.pot() + hook.treasuryOwed() + hook.totalReserved(), "claims != pot+treasury+reserved");
        assertEq(hookBossClaims(), 0, "hook must never hold BOSS");
        assertEq(address(hook).balance, 0, "hook must hold no raw ETH");
        if (!useNative()) assertEq(quoteToken.balanceOf(address(hook)), 0, "hook must hold no raw quote token");
    }

    // ------------------------------------------------------------------ oracle

    function attestation(uint256 answer) internal view returns (OracleGate.Attestation memory a) {
        a.requestId = keccak256(abi.encode("req", answer, block.timestamp));
        a.chainId = block.chainid;
        a.questionHash = QUESTION;
        a.answerType = 3;
        a.answer = abi.encode(answer);
        a.panelJobId = keccak256("panel");
        a.panelSize = PANEL;
        a.quorum = QUORUM;
        a.agreed = 18;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
    }

    function signAttestation(OracleGate.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oracleKey, hook.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }
}
