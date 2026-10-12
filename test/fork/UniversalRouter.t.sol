// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {HookFlags} from "../../src/HookFlags.sol";
import {BossToken} from "../../src/BossToken.sol";
import {BossHook} from "../../src/BossHook.sol";
import {AbilityBoard} from "../../src/AbilityBoard.sol";
import {IAbilityBoard} from "../../src/interfaces/IAbility.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// Mainnet Universal Router v4 param struct (deployed version).
struct ExactInSingle {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// @notice The real thing: a mainnet fork with the real PoolManager, PositionManager, Permit2,
/// Universal Router and IMD. The launch is reproduced as the factory does it (token, hook at a
/// mined address, pool, single-sided BOSS liquidity), then players trade through the Universal
/// Router exactly as the Uniswap app sends it, including the custody shape used with an interface
/// fee (TAKE to the router, PAY_PORTION, SWEEP). Credit must follow the BOSS in every shape.
///
/// Needs an RPC: `BOSS_FORK_RPC=https://rpc.mevblocker.io forge test --match-path "test/fork/*" -vv`.
/// Skipped otherwise, so the normal suite never touches the network.
contract UniversalRouterForkTest is Test {
    IPoolManager internal constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address internal constant POSM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant UR = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant IMD_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    // Universal Router commands and v4 router actions (mainnet deployment).
    uint8 internal constant CMD_SWEEP = 0x04;
    uint8 internal constant CMD_PAY_PORTION = 0x06;
    uint8 internal constant CMD_V4_SWAP = 0x10;
    uint8 internal constant ACT_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant ACT_SETTLE_ALL = 0x0c;
    uint8 internal constant ACT_TAKE = 0x0e;
    uint8 internal constant ACT_TAKE_ALL = 0x0f;
    address internal constant MSG_SENDER = address(1);
    address internal constant ADDRESS_THIS = address(2);

    uint160 internal constant HOOK_FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    uint256 internal constant INITIAL_HP = 1 ether; // one IMD of HP, so a single buy can kill
    uint24 internal constant LAUNCH_TICK_ABS = 129_000;
    uint256 internal constant POOL_SHARE = 900_000_000 ether;

    bool internal forked;
    BossToken internal t;
    BossHook internal h;
    AbilityBoard internal board;
    PoolKey internal key;
    bool internal bossIs0;
    int24 internal tick;

    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal relayer = makeAddr("relayer");
    address internal feeCollector = makeAddr("feeCollector");

    function setUp() public {
        string memory rpc = vm.envOr("BOSS_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        // The launch, as the factory does it: this contract deploys the token and the hook (same
        // tx.origin, so the hook binds the token), opens the pool and seeds it single-sided.
        t = new BossToken();
        board = new AbilityBoard(keeper);
        bytes memory args = abi.encode(
            PM, address(t), keeper, IAbilityBoard(address(board)), IMD_SIGNER, keccak256("fork"), INITIAL_HP, LAUNCH_TICK_ABS, IMD
        );
        bytes memory initCode = abi.encodePacked(type(BossHook).creationCode, args);
        (bytes32 salt, address predicted) = HookFlags.mineSalt(address(this), initCode, HOOK_FLAGS, 2_000_000);
        address addr;
        assembly ("memory-safe") {
            addr := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(addr == predicted && addr != address(0), "hook deploy");
        h = BossHook(addr);
        assertEq(t.hook(), address(h), "the token is bound to the hook");

        bossIs0 = address(t) < IMD;
        key = PoolKey({
            currency0: Currency.wrap(bossIs0 ? address(t) : IMD),
            currency1: Currency.wrap(bossIs0 ? IMD : address(t)),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(h))
        });
        tick = bossIs0 ? -int24(LAUNCH_TICK_ABS) : int24(LAUNCH_TICK_ABS);
        PM.initialize(key, TickMath.getSqrtPriceAtTick(tick));
        _addLiquidity();

        _fund(alice);
        _fund(bob);
    }

    function _requireFork() internal {
        if (!forked) vm.skip(true);
    }

    // ------------------------------------------------------------------ launch helpers

    /// @dev Single-sided BOSS liquidity through the real PositionManager: MINT_POSITION + CLOSE_CURRENCY.
    function _addLiquidity() internal {
        t.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(t), POSM, type(uint160).max, uint48(block.timestamp + 1 days));
        int24 lo;
        int24 hi;
        uint128 liq;
        if (bossIs0) {
            lo = tick + 60;
            hi = TickMath.maxUsableTick(60);
            liq = LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), POOL_SHARE
            );
        } else {
            lo = TickMath.minUsableTick(60);
            hi = tick - 60;
            liq = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), POOL_SHARE
            );
        }
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            lo,
            hi,
            uint256(liq),
            bossIs0 ? uint128(1_000_000_000 ether) : uint128(0),
            bossIs0 ? uint128(0) : uint128(1_000_000_000 ether),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(Currency.wrap(address(t)));
        IPositionManager(POSM).modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(0x02), uint8(0x12)), params), block.timestamp + 3600
        );
        assertEq(h.round(), 1);
        assertEq(h.hp(), INITIAL_HP);
    }

    /// @dev IMD from a storage write (forge-std `deal`), and the Permit2 allowances the Uniswap app sets.
    function _fund(address who) internal {
        deal(IMD, who, 1_000 ether);
        vm.startPrank(who);
        IERC20Min(IMD).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(IMD, UR, type(uint160).max, uint48(block.timestamp + 30 days));
        t.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(t), UR, type(uint160).max, uint48(block.timestamp + 30 days));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ Universal Router shapes

    /// @dev Exact-input buy, app shape: V4_SWAP [SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL]; the BOSS goes straight to msgSender.
    function _buy(address who, address signer, uint256 imdIn) internal {
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(ExactInSingle(key, !bossIs0, uint128(imdIn), 0, ""));
        p[1] = abi.encode(Currency.wrap(IMD), imdIn);
        p[2] = abi.encode(Currency.wrap(address(t)), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL), p);
        vm.prank(who, signer);
        IUniversalRouter(UR).execute(abi.encodePacked(CMD_V4_SWAP), inputs, block.timestamp + 3600);
    }

    /// @dev Exact-input sell: the BOSS leaves the seller through Permit2 into the PoolManager.
    function _sell(address who, address signer, uint256 bossIn) internal {
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(ExactInSingle(key, bossIs0, uint128(bossIn), 0, ""));
        p[1] = abi.encode(Currency.wrap(address(t)), bossIn);
        p[2] = abi.encode(Currency.wrap(IMD), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL), p);
        vm.prank(who, signer);
        IUniversalRouter(UR).execute(abi.encodePacked(CMD_V4_SWAP), inputs, block.timestamp + 3600);
    }

    /// @dev The Uniswap app with an interface fee: the router custodies the BOSS (TAKE to itself),
    /// pays the fee (PAY_PORTION) and sweeps the rest to the user. Two hops in one transaction.
    function _buyWithInterfaceFee(address who, uint256 imdIn, uint256 feeBips) internal {
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(ExactInSingle(key, !bossIs0, uint128(imdIn), 0, ""));
        p[1] = abi.encode(Currency.wrap(IMD), imdIn);
        p[2] = abi.encode(Currency.wrap(address(t)), ADDRESS_THIS, uint256(0)); // TAKE(BOSS, router, open delta)
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE), p);
        inputs[1] = abi.encode(address(t), feeCollector, feeBips);
        inputs[2] = abi.encode(address(t), MSG_SENDER, uint256(0));
        vm.prank(who, who);
        IUniversalRouter(UR).execute(
            abi.encodePacked(CMD_V4_SWAP, CMD_PAY_PORTION, CMD_SWEEP), inputs, block.timestamp + 3600
        );
    }

    function _assertAccounting() internal view {
        assertEq(
            PM.balanceOf(address(h), uint256(uint160(IMD))),
            h.pot() + h.treasuryOwed() + h.totalReserved(),
            "6909 claims == pot + treasury + reserved"
        );
        assertEq(PM.balanceOf(address(h), uint256(uint160(address(t)))), 0, "the hook never holds BOSS claims");
    }

    // ------------------------------------------------------------------ tests

    function test_fork_buy_creditsTheBuyer() public {
        _requireFork();
        _buy(alice, alice, 0.4 ether);
        assertEq(h.damage(1, alice), 0.4 ether, "1x damage credited to the wallet that got the BOSS");
        assertEq(h.bought(1, alice), t.balanceOf(alice), "the BOSS counted is the BOSS held");
        assertEq(h.eligibleDamage(1), 0.4 ether);
        assertEq(h.damage(1, UR), 0, "the router holds no credit");
        assertEq(h.hp(), INITIAL_HP - 0.4 ether);
        _assertAccounting();
    }

    function test_fork_sell_forfeitsInProportion() public {
        _requireFork();
        _buy(alice, alice, 0.4 ether);
        uint256 got = t.balanceOf(alice);
        _sell(alice, alice, got / 2);
        assertApproxEqAbs(h.damage(1, alice), 0.2 ether, 1, "half the BOSS back into the pool, half the damage lost");
        assertEq(h.bought(1, alice), t.balanceOf(alice));
        assertApproxEqAbs(h.eligibleDamage(1), 0.2 ether, 1);
        _assertAccounting();
    }

    function test_fork_relayedBuy_creditsTheWalletNotTheSigner() public {
        _requireFork();
        _buy(alice, relayer, 0.4 ether); // a relayer or bundler signs; alice calls the router
        assertEq(h.damage(1, alice), 0.4 ether, "the wallet that received the BOSS is credited");
        assertEq(h.damage(1, relayer), 0, "the signer gets nothing");
        assertEq(h.bought(1, alice), t.balanceOf(alice));
        _assertAccounting();
    }

    function test_fork_relayedSell_forfeitsTheWalletWhoseBossLeft() public {
        _requireFork();
        _buy(alice, alice, 0.4 ether);
        _sell(alice, relayer, t.balanceOf(alice));
        assertEq(h.damage(1, alice), 0, "alice's BOSS went into the pool: alice forfeits, whoever signed");
        assertEq(h.eligibleDamage(1), 0);
        _assertAccounting();
    }

    function test_fork_killWithInterfaceFee_prizeAndDamageReachThePlayer() public {
        _requireFork();
        _buy(bob, bob, 0.3 ether); // bob dealt 0.3; 0.7 of HP left
        vm.expectEmit(true, true, false, false, address(h));
        emit BossHook.KillerCredited(1, alice);
        _buyWithInterfaceFee(alice, 1 ether, 25); // kills; 0.25% of the BOSS goes to the fee collector first
        (address killer,, uint256 prize, uint256 damagePool,) = h.results(1);
        assertEq(killer, alice, "the kill reached the player through the router's custody");
        assertEq(h.unclaimedKill(alice), prize);
        assertEq(h.unclaimedKill(UR), 0, "nothing stays on the router");
        assertEq(h.damage(1, UR), 0);
        assertEq(h.bought(1, UR), 0);
        assertEq(h.damage(1, alice) + h.damage(1, feeCollector), 0.7 ether, "the killing blow's damage, split by BOSS");
        assertApproxEqAbs(h.damage(1, feeCollector), uint256(0.7 ether) * 25 / 10_000, 1, "the fee's sliver");
        assertEq(h.bought(1, alice), t.balanceOf(alice));
        assertEq(h.bought(1, feeCollector), t.balanceOf(feeCollector));
        assertEq(h.eligibleDamage(1), INITIAL_HP);
        assertGt(damagePool, 0);
        assertEq(h.round(), 2);
        _assertAccounting();
    }
}
