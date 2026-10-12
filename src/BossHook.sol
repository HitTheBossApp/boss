// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Lock} from "v4-core/src/libraries/Lock.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {OracleGate} from "./OracleGate.sol";
import {BossMath} from "./libraries/BossMath.sol";
import {IAbility, IAbilityBoard, SwapInfo} from "./interfaces/IAbility.sol";

interface IMsgSender {
    function msgSender() external view returns (address);
}

/// @title BossHook — the boss that learns
/// @notice Every buy of BOSS hits the boss, every sell heals it. A 2.5% fee in the paired currency
/// fills the pot (1.5%) and the treasury that pays the IMD swarm (1%). When the boss falls, the
/// killing blow takes half of the pot (after a 10% seed for the next boss) and the rest is split
/// by damage among wallets that did not sell during the fight. Each day the swarm writes an
/// ability that changes how much a trade hits or heals; it only returns numbers, is called with
/// STATICCALL under a gas cap, and is clamped to [0.25x, 4x].
///
/// Trust model: no owner, no setters. The keeper (a) receives the treasury share and (b) selects
/// which swarm-written ability is posted on the AbilityBoard. A proposal applies only with an IMD
/// oracle signature approving it against the fixed question's conditions, after a 12-hour public
/// delay and at most once per 24 hours; its effect is clamped to [0.25x, 4x]. No ability can move money.
///
/// Fee custody: fees are minted to this contract as ERC-6909 claims on the PoolManager and only
/// leave through pull-based claims, each paid inside this contract's own unlock. Forked from the
/// fee machinery of WinGameHook (identity-md-launches/launch-784, MIT).
contract BossHook is IHooks, IUnlockCallback, OracleGate {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------- constants

    uint256 public constant PIPS = 1_000_000;
    uint256 public constant BPS = 10_000;
    /// @notice Public wait between an accepted ability and the moment it applies.
    uint256 public constant ABILITY_DELAY = 12 hours;
    /// @notice Minimum time between two activations.
    uint256 public constant MIN_ABILITY_INTERVAL = 24 hours;
    /// @notice Gas forwarded to the ability on every trade.
    uint256 public constant ABILITY_GAS = 50_000;
    /// @notice Gas that must be left when the ability is called, so it really gets ABILITY_GAS
    /// (EIP-150 keeps 1/64 back) and the hook can finish. Below it the whole swap reverts: a
    /// trader can never starve the ability on purpose to get the 1x fallback.
    uint256 public constant ABILITY_GAS_FLOOR = ABILITY_GAS * 64 / 63 + 30_000;
    /// @notice Hook fee on every trade: 2.5%, always in the paired currency.
    uint256 public constant FEE_PIPS = 25_000;
    /// @notice Share of the fee that goes to the treasury (1% of the trade); the rest (1.5%) fills the pot.
    uint256 public constant TREASURY_SHARE_BPS = 4_000;
    int24 public constant LAUNCH_TICK_TOLERANCE = 300;
    uint8 public constant PAIRED_DECIMALS = 18;
    uint256 public constant MSG_SENDER_PROBE_GAS = 50_000;

    // ---------------------------------------------------------------- immutables

    IPoolManager public immutable poolManager;
    address public immutable bossToken;
    /// @notice Receives the treasury share; pays the swarm's daily jobs.
    address public immutable keeper;
    IAbilityBoard public immutable board;
    uint256 public immutable initialHp;
    uint24 public immutable launchTickAbs;
    /// @notice The only currency BOSS may be paired with (address(0) = native ETH).
    address public immutable pairedCurrency;
    /// @notice Oracle panel size. Fixed before deploy; must match the IMD oracle request.
    uint16 public constant PANEL_SIZE = 21;
    /// @notice Oracle quorum. Fixed before deploy; must match the IMD oracle request.
    uint16 public constant QUORUM = 15;
    /// @notice The only LP fee the pool may use. Fixed before deploy; must match the manifest pool block.
    uint24 public constant LP_FEE = 12_500;
    /// @notice The only tick spacing the pool may use. Fixed before deploy; must match the manifest pool block.
    int24 public constant TICK_SPACING = 60;

    // ---------------------------------------------------------------- pool

    PoolKey internal _poolKey;
    PoolId internal _poolId;
    Currency public quote;
    bool public poolInitialized;
    bool public bossIsCurrency0;
    uint64 public launchTime;

    // ---------------------------------------------------------------- money (paired currency, as ERC-6909 claims)

    uint256 public pot;
    uint256 public treasuryOwed;
    /// @notice Decided but unpaid: killer prizes plus damage pools (and their rounding dust).
    uint256 public totalReserved;

    // ---------------------------------------------------------------- game

    uint64 public round;
    uint256 public hp;
    uint256 public maxHp;
    uint64 public roundStart;

    struct RoundResult {
        address killer;
        uint64 endedAt;
        uint256 killerPrize;
        uint256 damagePool;
        uint256 eligibleDamage;
    }

    mapping(uint64 round => mapping(address trader => uint256)) public damage;
    mapping(uint64 round => mapping(address trader => bool)) public sold;
    mapping(uint64 round => uint256) public eligibleDamage;
    mapping(uint64 round => RoundResult) public results;
    mapping(address winner => uint256) public unclaimedKill;
    mapping(uint64 round => mapping(address trader => bool)) public damageClaimed;

    /// @notice The ability in force as of the last swap or accept. Zero means 1x on both sides.
    /// It updates lazily (on the next swap or acceptAbility), so read `currentAbility()` for the
    /// authoritative view: it also counts a queued ability whose time has come.
    address public activeAbility;
    /// @notice Accepted ability waiting for its activation time. Zero when nothing is queued.
    address public queuedAbility;
    /// @notice When `queuedAbility` applies. Zero when nothing is queued.
    uint64 public queuedActivatesAt;
    /// @notice Scheduled activation time of the last accepted ability, set when it is queued (not
    /// when it applies). The next one cannot activate sooner than this plus MIN_ABILITY_INTERVAL.
    uint64 public lastActivationAt;
    /// @notice Highest board id ever accepted; an id is never accepted twice.
    uint256 public acceptedId;

    // ---------------------------------------------------------------- payout scratch

    address internal _payoutTo;
    uint256 internal _payoutAmount;
    uint256 internal _entered = 1;

    // ---------------------------------------------------------------- events

    event Launched(PoolId indexed poolId, address bossToken, Currency quote, uint64 launchTime, uint256 hp);
    event FeeCharged(address indexed trader, bool indexed isBuy, uint256 gross, uint256 fee);
    event TreasuryPaid(address indexed to, uint256 amount);
    event Hit(uint64 indexed round, address indexed trader, uint256 gross, uint256 damage, uint256 hpAfter);
    event Healed(uint64 indexed round, address indexed trader, uint256 gross, uint256 heal, uint256 hpAfter);
    event Forfeited(uint64 indexed round, address indexed trader, uint256 damageLost);
    event BossKilled(
        uint64 indexed round, address indexed killer, uint256 killerPrize, uint256 damagePool, uint256 seed, uint256 nextHp
    );
    event KillPaid(address indexed winner, uint256 amount);
    event AbilityFailed(address indexed ability);
    event AbilityQueued(uint256 indexed id, address indexed ability, uint64 activatesAt, bytes32 requestId);
    event AbilityActivated(address indexed ability);
    event DamagePaid(uint64 indexed round, address indexed trader, uint256 amount);

    // ---------------------------------------------------------------- errors

    error InsufficientGasForAbility();
    error NotPoolManager();
    error HookNotImplemented();
    error ZeroAddress();
    error TokenHasNoCode();
    error InvalidConfig();
    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error PoolMustPairBossToken();
    error WrongPairedCurrency();
    error WrongLPFee(uint24 fee);
    error WrongTickSpacing(int24 tickSpacing);
    error WrongStartingPrice(uint160 sqrtPriceX96, int24 tick, int24 expectedTick);
    error PairedCurrencyDecimals();
    error WrongPool();
    error PartialFillNotSupported();
    error NothingToClaim();
    error UnexpectedUnlock();
    error ManagerUnlocked();
    error Reentrancy();
    error RoundNotOver();
    error SoldThisRound();
    error AlreadyClaimed();
    error NothingPending();
    error StaleAttestation();
    error NotApproved(uint256 answer);
    error AbilityAlreadyQueued();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    /// @param manager The chain's PoolManager ("$poolManager").
    /// @param token The BOSS token ("$token").
    /// @param keeper_ Treasury recipient and AbilityBoard keeper ("$owner").
    /// @param board_ The AbilityBoard the oracle question reads.
    /// @param oracleSigner_ IMD oracle attester address.
    /// @param questionHash_ Hash of the fixed ability question (from /requests/check).
    /// @param initialHp_ First boss HP, in the paired currency's smallest unit.
    /// @param launchTickAbs_ |tick| of the launch price (184200 = 10 ETH cap; 129000 = 2,500 IMD cap).
    /// @param pairedCurrency_ The only currency BOSS may be paired with (IMD as launched; address(0) for native ETH).
    /// Panel size, quorum, LP fee and tick spacing are source constants, not arguments.
    constructor(
        IPoolManager manager,
        address token,
        address keeper_,
        IAbilityBoard board_,
        address oracleSigner_,
        bytes32 questionHash_,
        uint256 initialHp_,
        uint24 launchTickAbs_,
        address pairedCurrency_
    ) OracleGate(oracleSigner_, questionHash_, PANEL_SIZE, QUORUM) {
        if (address(manager) == address(0) || token == address(0) || keeper_ == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert TokenHasNoCode();
        if (address(board_).code.length == 0 || board_.keeper() != keeper_) revert InvalidConfig();
        if (initialHp_ < 4 || initialHp_ > type(uint128).max || launchTickAbs_ == 0 || launchTickAbs_ > 887_000) {
            revert InvalidConfig();
        }
        if (pairedCurrency_ == token) revert InvalidConfig();
        pairedCurrency = pairedCurrency_;
        poolManager = manager;
        bossToken = token;
        keeper = keeper_;
        board = board_;
        initialHp = initialHp_;
        launchTickAbs = launchTickAbs_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- initialization

    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (poolInitialized) revert PoolAlreadyInitialized();
        // The hook binds only to the exact pool key it was built for (hooks == this is implicit).
        if (key.fee != LP_FEE) revert WrongLPFee(key.fee);
        if (key.tickSpacing != TICK_SPACING) revert WrongTickSpacing(key.tickSpacing);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 == bossToken) {
            bossIsCurrency0 = true;
            quote = key.currency1;
        } else if (c1 == bossToken) {
            bossIsCurrency0 = false;
            quote = key.currency0;
        } else {
            revert PoolMustPairBossToken();
        }
        if (Currency.unwrap(quote) != pairedCurrency) revert WrongPairedCurrency();
        if (!_hasPairedDecimals(quote)) revert PairedCurrencyDecimals();

        int24 expectedTick = launchTick(bossIsCurrency0);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        if (tick < expectedTick - LAUNCH_TICK_TOLERANCE || tick > expectedTick + LAUNCH_TICK_TOLERANCE) {
            revert WrongStartingPrice(sqrtPriceX96, tick, expectedTick);
        }

        _poolKey = key;
        _poolId = key.toId();
        poolInitialized = true;
        launchTime = uint64(block.timestamp);
        round = 1;
        maxHp = initialHp;
        hp = initialHp;
        roundStart = uint64(block.timestamp);

        emit Launched(_poolId, bossToken, quote, launchTime, initialHp);
        return IHooks.beforeInitialize.selector;
    }

    function launchTick(bool bossIsCurrency0_) public view returns (int24) {
        int24 abs_ = int24(launchTickAbs);
        return bossIsCurrency0_ ? -abs_ : abs_;
    }

    function launchSqrtPriceX96(bool bossIsCurrency0_) external view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(launchTick(bossIsCurrency0_));
    }

    // ---------------------------------------------------------------- swaps

    /// @dev When the paired currency is the specified side (exact-input buy, exact-output sell)
    /// the fee is diverted here; otherwise it is taken in afterSwap from the unspecified side.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        (bool isBuy, bool exactInput) = _classify(params);
        if (isBuy != exactInput) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        uint256 fee = _specifiedSideFee(params, isBuy);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkPool(key);
        (bool isBuy, bool exactInput) = _classify(params);
        // Sells are always attributed to the signer: naming someone else must never forfeit their share.
        address trader = isBuy ? _resolveTrader(sender, hookData) : tx.origin;
        (uint256 fee, uint256 gross, int128 unspecifiedReturn) = _feeAndGross(params, delta, isBuy, exactInput);
        if (fee > 0) poolManager.mint(address(this), quote.toId(), fee);
        emit FeeCharged(trader, isBuy, gross, fee);
        _accrue(fee);
        _play(trader, isBuy, gross);
        return (IHooks.afterSwap.selector, unspecifiedReturn);
    }

    function _feeAndGross(SwapParams calldata params, BalanceDelta delta, bool isBuy, bool exactInput)
        internal
        view
        returns (uint256 fee, uint256 gross, int128 unspecifiedReturn)
    {
        int128 quoteDelta = bossIsCurrency0 ? delta.amount1() : delta.amount0();
        if (isBuy == exactInput) {
            fee = _specifiedSideFee(params, isBuy);
            uint256 specified = _abs(params.amountSpecified);
            if (isBuy) {
                gross = specified;
                if (uint256(uint128(-quoteDelta)) != gross - fee) revert PartialFillNotSupported();
            } else {
                gross = specified + fee;
                if (uint256(uint128(quoteDelta)) != gross) revert PartialFillNotSupported();
            }
        } else if (isBuy) {
            uint256 poolIn = uint256(uint128(-quoteDelta));
            fee = poolIn * FEE_PIPS / (PIPS - FEE_PIPS);
            gross = poolIn + fee;
            unspecifiedReturn = fee.toInt128();
        } else {
            uint256 poolOut = uint256(uint128(quoteDelta));
            fee = poolOut * FEE_PIPS / PIPS;
            gross = poolOut;
            unspecifiedReturn = fee.toInt128();
        }
    }

    function _specifiedSideFee(SwapParams calldata params, bool isBuy) internal pure returns (uint256) {
        uint256 specified = _abs(params.amountSpecified);
        return isBuy ? specified * FEE_PIPS / PIPS : specified * FEE_PIPS / (PIPS - FEE_PIPS);
    }

    function _classify(SwapParams calldata params) internal view returns (bool isBuy, bool exactInput) {
        isBuy = params.zeroForOne != bossIsCurrency0;
        exactInput = params.amountSpecified < 0;
    }

    function _accrue(uint256 fee) internal {
        if (fee == 0) return;
        uint256 toTreasury = fee * TREASURY_SHARE_BPS / BPS;
        treasuryOwed += toTreasury;
        pot += fee - toTreasury;
    }

    /// @notice Queues the board's pending ability once the IMD oracle panel approved it
    /// (answer = id * 2 + 1). It applies 12 hours later, and never sooner than 24 hours after the
    /// previous activation. Anyone may relay the signed answer.
    function acceptAbility(Attestation calldata a, bytes calldata sig) external {
        _syncAbility();
        (uint256 id, address ability) = board.pending();
        if (ability == address(0) || id <= acceptedId) revert NothingPending();
        if (queuedAbility != address(0)) revert AbilityAlreadyQueued();
        if (a.issuedAt <= board.proposedAt()) revert StaleAttestation();
        uint256 answer = _verifyAttestation(a, sig);
        if (answer != id * 2 + 1) revert NotApproved(answer);

        uint64 at = uint64(block.timestamp + ABILITY_DELAY);
        if (lastActivationAt != 0) {
            uint64 earliest = lastActivationAt + uint64(MIN_ABILITY_INTERVAL);
            if (at < earliest) at = earliest;
        }
        acceptedId = id;
        queuedAbility = ability;
        queuedActivatesAt = at;
        lastActivationAt = at;
        emit AbilityQueued(id, ability, at, a.requestId);
    }

    /// @notice The ability in force right now (counting a queued one whose time has come). This is
    /// the authoritative view; the public `activeAbility` only catches up on the next swap or accept.
    function currentAbility() external view returns (address active, address queued, uint64 activatesAt) {
        if (queuedAbility != address(0) && block.timestamp >= queuedActivatesAt) {
            return (queuedAbility, address(0), 0);
        }
        return (activeAbility, queuedAbility, queuedActivatesAt);
    }

    function _syncAbility() internal {
        address q = queuedAbility;
        if (q != address(0) && block.timestamp >= queuedActivatesAt) {
            activeAbility = q;
            queuedAbility = address(0);
            queuedActivatesAt = 0;
            emit AbilityActivated(q);
        }
    }

    /// @dev The boss game step, run after this trade's fee is already in the pot.
    function _play(address trader, bool isBuy, uint256 gross) internal {
        _syncAbility();
        (uint256 buyMult, uint256 sellMult) = _abilityMults(trader, isBuy, gross);
        uint64 r = round;
        if (isBuy) {
            uint256 dmg = BossMath.scale(gross, buyMult);
            if (dmg == 0) return;
            uint256 current = hp;
            if (dmg > current) dmg = current;
            hp = current - dmg;
            damage[r][trader] += dmg;
            if (!sold[r][trader]) eligibleDamage[r] += dmg;
            emit Hit(r, trader, gross, dmg, current - dmg);
            if (current == dmg) _kill(trader);
        } else {
            if (!sold[r][trader]) {
                sold[r][trader] = true;
                uint256 lost = damage[r][trader];
                if (lost > 0) {
                    eligibleDamage[r] -= lost;
                    emit Forfeited(r, trader, lost);
                }
            }
            uint256 heal = BossMath.scale(gross, sellMult);
            uint256 room = maxHp - hp;
            if (heal > room) heal = room;
            hp += heal;
            emit Healed(r, trader, gross, heal, hp);
        }
    }

    /// @dev Closes the round: seed stays in the pot, killer prize and damage pool are reserved
    /// for pull claims, and the next boss spawns with HP set by how fast this one fell.
    function _kill(address killer) internal {
        uint64 r = round;
        uint256 elig = eligibleDamage[r];
        (uint256 seed, uint256 killerPrize, uint256 damagePool) = BossMath.splitPot(pot, elig > 0);
        results[r] = RoundResult({
            killer: killer,
            endedAt: uint64(block.timestamp),
            killerPrize: killerPrize,
            damagePool: damagePool,
            eligibleDamage: elig
        });
        unclaimedKill[killer] += killerPrize;
        totalReserved += killerPrize + damagePool;
        pot = seed;

        uint256 next = BossMath.nextMaxHp(maxHp, block.timestamp - roundStart, initialHp);
        round = r + 1;
        maxHp = next;
        hp = next;
        roundStart = uint64(block.timestamp);
        emit BossKilled(r, killer, killerPrize, damagePool, seed, next);
    }

    /// @dev Calls the active ability with STATICCALL under ABILITY_GAS, copies at most 64 bytes
    /// back (no return-data bomb), clamps both multipliers and falls back to 1x on any failure.
    function _abilityMults(address trader, bool isBuy, uint256 gross)
        internal
        returns (uint256 buyMult, uint256 sellMult)
    {
        address ability = activeAbility;
        if (ability == address(0)) return (BPS, BPS);
        if (gasleft() < ABILITY_GAS_FLOOR) revert InsufficientGasForAbility();

        bytes memory data = abi.encodeCall(
            IAbility.modifiers,
            (
                SwapInfo({
                    trader: trader,
                    isBuy: isBuy,
                    amount: gross,
                    timestamp: block.timestamp,
                    round: round,
                    hp: hp,
                    maxHp: maxHp,
                    pot: pot
                })
            )
        );
        uint256 gasForAbility = ABILITY_GAS;
        bool ok;
        uint256 b;
        uint256 s;
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := staticcall(gasForAbility, ability, add(data, 32), mload(data), out, 64)
            if lt(returndatasize(), 64) { ok := 0 }
            b := mload(out)
            s := mload(add(out, 32))
        }
        if (!ok) {
            emit AbilityFailed(ability);
            return (BPS, BPS);
        }
        return (BossMath.clampMult(b), BossMath.clampMult(s));
    }

    // ---------------------------------------------------------------- claims

    /// @notice Pays a killing-blow prize. Anyone may trigger it; the money only goes to `winner`.
    function claimKill(address winner) external nonReentrant {
        uint256 amount = unclaimedKill[winner];
        if (amount == 0) revert NothingToClaim();
        unclaimedKill[winner] = 0;
        totalReserved -= amount;
        _payout(winner, amount);
        emit KillPaid(winner, amount);
    }

    /// @notice Pays `who` their share of round `r`'s damage pool. Anyone may trigger it.
    function claimDamage(uint64 r, address who) external nonReentrant {
        if (results[r].endedAt == 0) revert RoundNotOver();
        if (sold[r][who]) revert SoldThisRound();
        if (damageClaimed[r][who]) revert AlreadyClaimed();
        uint256 amount = claimableDamage(r, who);
        if (amount == 0) revert NothingToClaim();
        damageClaimed[r][who] = true;
        totalReserved -= amount;
        _payout(who, amount);
        emit DamagePaid(r, who, amount);
    }

    function claimableDamage(uint64 r, address who) public view returns (uint256) {
        RoundResult storage res = results[r];
        if (res.endedAt == 0 || sold[r][who] || damageClaimed[r][who]) return 0;
        return BossMath.share(res.damagePool, damage[r][who], res.eligibleDamage);
    }

    /// @notice Sends the treasury share to the keeper. Anyone may trigger it; the destination is fixed.
    function claimTreasury() external nonReentrant {
        uint256 amount = treasuryOwed;
        if (amount == 0) revert NothingToClaim();
        treasuryOwed = 0;
        _payout(keeper, amount);
        emit TreasuryPaid(keeper, amount);
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        address to = _payoutTo;
        uint256 amount = _payoutAmount;
        if (to == address(0) || amount == 0) revert UnexpectedUnlock();
        poolManager.burn(address(this), quote.toId(), amount);
        poolManager.take(quote, to, amount);
        return "";
    }

    function _payout(address to, uint256 amount) internal {
        if (poolManager.exttload(Lock.IS_UNLOCKED_SLOT) != bytes32(0)) revert ManagerUnlocked();
        _payoutTo = to;
        _payoutAmount = amount;
        poolManager.unlock("");
        _payoutTo = address(0);
        _payoutAmount = 0;
    }

    // ---------------------------------------------------------------- views

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function poolId() external view returns (PoolId) {
        return _poolId;
    }

    // ---------------------------------------------------------------- identity and misc

    /// @dev Who traded. The PoolManager hands the hook the router, never the user, so identity
    /// comes from `hookData` (abi.encode(addr) or 20 packed bytes), then the router's
    /// `msgSender()`, then `tx.origin`. Used only for buys, where naming someone can only gift them
    /// damage or the kill credit. Sells are always attributed to `tx.origin` (the signer) in
    /// afterSwap, so nobody can forfeit someone else's share. Identity is never used for authorization.
    function _resolveTrader(address router, bytes calldata hookData) internal view returns (address trader) {
        if (hookData.length == 32) {
            uint256 word = uint256(bytes32(hookData[:32]));
            if (word >> 160 == 0) trader = address(uint160(word));
        } else if (hookData.length == 20) {
            trader = address(bytes20(hookData[:20]));
        }
        if (trader == address(0)) trader = _routerMsgSender(router);
        if (trader == address(0)) trader = tx.origin;
    }

    function _routerMsgSender(address router) internal view returns (address) {
        if (router.code.length == 0) return address(0);
        (bool ok, bytes memory data) =
            router.staticcall{gas: MSG_SENDER_PROBE_GAS}(abi.encodeCall(IMsgSender.msgSender, ()));
        if (!ok || data.length != 32) return address(0);
        uint256 word = abi.decode(data, (uint256));
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }

    function _hasPairedDecimals(Currency currency) internal view returns (bool) {
        if (currency.isAddressZero()) return true;
        (bool ok, bytes memory data) = Currency.unwrap(currency).staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (uint256)) == PAIRED_DECIMALS;
    }

    function _checkPool(PoolKey calldata key) internal view {
        if (!poolInitialized) revert PoolNotInitialized();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(_poolId)) revert WrongPool();
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    // ---------------------------------------------------------------- callbacks not enabled

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
