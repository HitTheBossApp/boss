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
import {IBossToken} from "./interfaces/IBossToken.sol";

/// @title BossHook — the boss that learns
/// @notice Every buy of BOSS hits the boss, every sell heals it. A 2.5% fee in the paired currency
/// fills the pot (1.5%) and the treasury that pays the IMD swarm (1%). When the boss falls, the
/// killing blow takes half of the pot (after a 10% seed for the next boss) and the rest is split
/// by the damage each wallet still holds. Credit follows the BOSS, not the signer: a buy is credited
/// to the wallet that receives the BOSS from the pool, BOSS handed back to the pool forfeits damage
/// in proportion to the BOSS bought that round, and BOSS sent to another wallet takes that share of
/// the credit with it (the token reports every transfer to this hook). Each day the swarm writes an
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

    /// @notice Damage a wallet still holds in a round: credited with the BOSS it received from the
    /// pool, minus what left with the BOSS it handed back to the pool or sent to another wallet.
    mapping(uint64 round => mapping(address wallet => uint256)) public damage;
    /// @notice BOSS a wallet received from the pool this round (or, with its credit, from another
    /// wallet) and still holds. `x` BOSS leaving the wallet takes damage * x / bought with it (all
    /// of it once x >= bought) and lowers this by x.
    mapping(uint64 round => mapping(address wallet => uint256)) public bought;
    /// @notice Sum of `damage` over all wallets in a round: the denominator of the damage pool.
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

    // ---------------------------------------------------------------- transient scratch (cleared after every transaction)

    /// @dev Damage and BOSS of this transaction's buys that no wallet has received yet, and their round.
    bytes32 internal constant T_PEND_ROUND = bytes32(uint256(1));
    bytes32 internal constant T_PEND_DAMAGE = bytes32(uint256(2));
    bytes32 internal constant T_PEND_BOSS = bytes32(uint256(3));
    /// @dev The round this transaction closed, and how much of its killing credit (held by the signer
    /// since the kill) still has BOSS to leave the pool and carry it. HELD: base of a per-wallet
    /// map of how much of that BOSS each wallet holds so far; the prize goes to a majority holder.
    bytes32 internal constant T_KILL_ROUND = bytes32(uint256(4));
    bytes32 internal constant T_KILL_DAMAGE = bytes32(uint256(5));
    bytes32 internal constant T_KILL_BOSS = bytes32(uint256(6));
    bytes32 internal constant T_KILL_HELD = bytes32(uint256(7));
    /// @dev The locker (afterSwap's `sender`) that owns the pending and killing credit above: a swap
    /// from another locker voids what is left of it, so one party's leftovers never merge with another's.
    bytes32 internal constant T_SENDER = bytes32(uint256(8));
    /// @dev HP the boss had before this transaction's first trade (or forfeit) of the round, plus the
    /// credit forfeited since, minus the credit delivered since: the net credit a transaction creates
    /// never exceeds the HP it has removed when that credit is delivered, heals by anyone in it before
    /// then included. A locker change trims it to the HP left. HP0_ROUND is the round it belongs to.
    bytes32 internal constant T_PEND_HP0 = bytes32(uint256(9));
    bytes32 internal constant T_HP0_ROUND = bytes32(uint256(13));
    /// @dev The killing blow's BOSS at the kill: the prize goes to a wallet that holds more than half of it.
    bytes32 internal constant T_KILL_TOTAL = bytes32(uint256(10));
    /// @dev Base of a per-wallet map: the killing blow's credit each wallet holds with its blow BOSS
    /// (the part of the closed round's credit that travels on hops; every other closed credit is frozen).
    bytes32 internal constant T_KILL_DMG = bytes32(uint256(14));
    /// @dev The locker that executed the killing swap: the custodian of the blow, which pays it out in
    /// proportion to its balance (a fee taken as a share, then a sweep).
    bytes32 internal constant T_KILL_LOCKER = bytes32(uint256(15));
    /// @dev Set once that locker starts paying the blow out to wallets: from then on it can no longer
    /// hold the prize (unless it is the signer), so BOSS planted on it never keeps the prize there.
    bytes32 internal constant T_KILL_PAID = bytes32(uint256(16));

    // ---------------------------------------------------------------- events

    event Launched(PoolId indexed poolId, address bossToken, Currency quote, uint64 launchTime, uint256 hp);
    event FeeCharged(address indexed trader, bool indexed isBuy, uint256 gross, uint256 fee);
    event TreasuryPaid(address indexed to, uint256 amount);
    event Hit(uint64 indexed round, address indexed trader, uint256 gross, uint256 damage, uint256 hpAfter);
    event Healed(uint64 indexed round, address indexed trader, uint256 gross, uint256 heal, uint256 hpAfter);
    event Forfeited(uint64 indexed round, address indexed trader, uint256 damageLost);
    event BossKilled(
        uint64 indexed round,
        address indexed killer,
        uint256 killerPrize,
        uint256 damagePool,
        uint256 seed,
        uint256 nextHp
    );
    event KillPaid(address indexed winner, uint256 amount);
    event AbilityFailed(address indexed ability);
    event AbilityQueued(uint256 indexed id, address indexed ability, uint64 activatesAt, bytes32 requestId);
    event AbilityActivated(address indexed ability);
    event DamagePaid(uint64 indexed round, address indexed trader, uint256 amount);
    event Credited(uint64 indexed round, address indexed to, uint256 damage, uint256 boss);
    event DamageMoved(uint64 indexed round, address indexed from, address indexed to, uint256 damage, uint256 boss);
    event KillerCredited(uint64 indexed round, address indexed winner);

    // ---------------------------------------------------------------- errors

    error NotBossToken();
    error TokenNotBound();
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
    error AlreadyClaimed();
    error NothingPending();
    error StaleAttestation();
    error NotApproved(uint256 answer);
    error AbilityAlreadyQueued();
    error AbilityNotAContract();

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
        if (address(manager) == address(0) || token == address(0) || keeper_ == address(0)) {
            revert ZeroAddress();
        }
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
        // From here on the token reports every transfer to this hook. The token refuses a second
        // binding and any signer but its deployer's, so a bad launch fails here, loudly.
        IBossToken(token).bindHook();
        if (IBossToken(token).hook() != address(this)) revert TokenNotBound();
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

    /// @dev The signer (tx.origin) only labels the events and the ability's read-only SwapInfo. Who
    /// is credited is decided when the BOSS actually moves, in `onBossTransfer`: neither hookData,
    /// nor the router, nor the signer can name the wallet that collects. Identity is never used
    /// for authorization. The locker (`sender`) only scopes this transaction's pending credit.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkPool(key);
        _scope(sender);
        (bool isBuy, bool exactInput) = _classify(params);
        address signer = tx.origin;
        (uint256 fee, uint256 gross, int128 unspecifiedReturn) = _feeAndGross(params, delta, isBuy, exactInput);
        if (fee > 0) poolManager.mint(address(this), quote.toId(), fee);
        emit FeeCharged(signer, isBuy, gross, fee);
        _accrue(fee);
        // BOSS that changed hands: received on a buy, paid in on a sell. The hook never charges BOSS.
        int128 bossDelta = bossIsCurrency0 ? delta.amount0() : delta.amount1();
        _play(signer, isBuy, gross, _abs(bossDelta));
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
        // An ability is an immutable contract. An EOA can be (re-)delegated with EIP-7702 at any time:
        // with no code now, or with 23 bytes of code (0xef0100 || target), it is refused. No contract's
        // code can start with 0xef (EIP-3541), and a contract can never become an EOA, so what passes
        // here keeps its code.
        uint256 len = ability.code.length;
        if (len == 0 || (len == 23 && bytes3(ability.code) == 0xef0100)) revert AbilityNotAContract();
        if (queuedAbility != address(0)) revert AbilityAlreadyQueued();
        if (a.issuedAt < board.proposedAt()) revert StaleAttestation();
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

    /// @dev The boss game step, run after this trade's fee is already in the pot. `bossAmount` is the
    /// BOSS the trade moved (received on a buy, paid in on a sell). A buy's damage waits as pending
    /// credit until the BOSS leaves the pool (`onBossTransfer`). A sell heals; the BOSS it hands
    /// back first takes back this transaction's pending credit of that much BOSS (a buy and a sell
    /// settled against each other inside the PoolManager move no token, so `onBossTransfer` never
    /// sees them), and BOSS a wallet hands back to the pool is forfeited in `onBossTransfer`.
    function _play(address signer, bool isBuy, uint256 gross, uint256 bossAmount) internal {
        _syncAbility();
        (uint256 buyMult, uint256 sellMult) = _abilityMults(signer, isBuy, gross);
        uint64 r = round;
        _anchor(r);
        if (isBuy) {
            uint256 dmg = BossMath.scale(gross, buyMult);
            if (dmg == 0) return;
            uint256 current = hp;
            if (dmg > current) dmg = current;
            hp = current - dmg;
            _pend(r, dmg, bossAmount);
            emit Hit(r, signer, gross, dmg, current - dmg);
            if (current == dmg) _kill(signer);
        } else {
            _unpend(r, bossAmount);
            uint256 heal = BossMath.scale(gross, sellMult);
            uint256 room = maxHp - hp;
            if (heal > room) heal = room;
            hp += heal;
            emit Healed(r, signer, gross, heal, hp);
        }
    }

    /// @dev Marks the HP the credit of this transaction is measured from, at its first trade (or
    /// forfeit) of round `r`: a sell that heals before a buy, in any order and through any number of
    /// contracts, counts against the credit that buy can earn.
    function _anchor(uint64 r) internal {
        if (uint64(_tload(T_HP0_ROUND)) != r) {
            _tstore(T_HP0_ROUND, r);
            _tstore(T_PEND_HP0, hp);
        }
    }

    /// @dev Parks a buy's damage and BOSS for the wallet that receives the BOSS in this transaction.
    function _pend(uint64 r, uint256 dmg, uint256 bossAmount) internal {
        if (uint64(_tload(T_PEND_ROUND)) == r) {
            _tstore(T_PEND_DAMAGE, _tload(T_PEND_DAMAGE) + dmg);
            _tstore(T_PEND_BOSS, _tload(T_PEND_BOSS) + bossAmount);
        } else {
            // Older pending credit belongs to a round this transaction closed (it was credited at
            // the kill): void.
            _tstore(T_PEND_ROUND, r);
            _tstore(T_PEND_DAMAGE, dmg);
            _tstore(T_PEND_BOSS, bossAmount);
        }
    }

    /// @dev A sell of `bossAmount` BOSS takes back that much BOSS's share of the pending credit.
    function _unpend(uint64 r, uint256 bossAmount) internal {
        uint256 pb = _tload(T_PEND_BOSS);
        if (pb == 0 || uint64(_tload(T_PEND_ROUND)) != r) return;
        uint256 pd = _tload(T_PEND_DAMAGE);
        (uint256 dmg, uint256 handedBack) = _slice(pd, pb, bossAmount);
        _tstore(T_PEND_DAMAGE, pd - dmg);
        _tstore(T_PEND_BOSS, pb - handedBack);
    }

    /// @dev The pending damage, cut to the HP this transaction removed in the round so far, plus the
    /// credit it forfeited, minus the credit it delivered (a flash sell before or after a buy, a heal
    /// day, or a price move between a buy and the sell settled against it can otherwise leave more
    /// credit than damage; a sell whose credit was already forfeited is not charged twice).
    function _cappedPending() internal returns (uint256 pd) {
        pd = _tload(T_PEND_DAMAGE);
        uint256 h0 = _tload(T_PEND_HP0);
        uint256 h = hp;
        uint256 room = h0 > h ? h0 - h : 0;
        if (pd > room) {
            // The BOSS that carried the credit cut is cut with it: it must not weigh in later forfeits.
            _tstore(T_PEND_BOSS, _tload(T_PEND_BOSS) * room / pd);
            pd = room;
            _tstore(T_PEND_DAMAGE, pd);
        }
    }

    /// @dev Scopes this transaction's pending and killing credit to one locker. A swap from another
    /// locker voids what is left of it: credit of BOSS the previous locker kept inside the
    /// PoolManager never merges with another party's swap, and the part of a killing blow it did not
    /// deliver stays with the signer instead of going to whoever takes BOSS out next.
    function _scope(address sender) internal {
        address owner = address(uint160(_tload(T_SENDER)));
        if (owner == sender) return;
        if (owner != address(0)) {
            _tstore(T_PEND_DAMAGE, 0);
            _tstore(T_PEND_BOSS, 0);
            _tstore(T_KILL_DAMAGE, 0);
            _tstore(T_KILL_BOSS, 0);
            // The HP the previous locker removed and never delivered is not this one's to collect;
            // the heals before it still count.
            if (_tload(T_PEND_HP0) > hp) _tstore(T_PEND_HP0, hp);
        }
        _tstore(T_SENDER, uint160(sender));
    }

    /// @dev Closes the round: seed stays in the pot, killer prize and damage pool are reserved
    /// for pull claims, and the next boss spawns with HP set by how fast this one fell. The
    /// transaction's pending credit (the killing blow included, never more than the HP it removed)
    /// is credited to the signer right now, so the round closes with it counted; it moves, killer
    /// prize included, to whoever receives that BOSS from the pool later in this transaction
    /// (`_arrive`).
    function _kill(address killer) internal {
        uint64 r = round;
        // A previous kill in this transaction stops travelling here: a prize still on the router that
        // executed it, or on no majority holder of its blow, goes to the signer.
        uint64 pk = uint64(_tload(T_KILL_ROUND));
        if (pk != 0) {
            address h = results[pk].killer;
            if (
                h != tx.origin
                    && (h == address(uint160(_tload(T_KILL_LOCKER))) || 2 * _weight(pk, h) <= _tload(T_KILL_TOTAL))
            ) _moveKill(pk, h, tx.origin);
        }
        // The blow's BOSS is all the BOSS its buys took out; the cap only cuts what the open round counts.
        uint256 blow = _tload(T_PEND_BOSS);
        uint256 pd = _cappedPending();
        uint256 pb = _tload(T_PEND_BOSS);
        _tstore(T_PEND_DAMAGE, 0);
        _tstore(T_PEND_BOSS, 0);
        _credit(r, killer, pd, pb);
        _tstore(T_KILL_ROUND, r);
        _tstore(T_KILL_DAMAGE, pd);
        _tstore(T_KILL_BOSS, blow);
        _tstore(T_KILL_TOTAL, blow);
        _tstore(T_KILL_LOCKER, _tload(T_SENDER));
        _tstore(T_KILL_PAID, 0);
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
            (SwapInfo({
                    trader: trader,
                    isBuy: isBuy,
                    amount: gross,
                    timestamp: block.timestamp,
                    round: round,
                    hp: hp,
                    maxHp: maxHp,
                    pot: pot
                }))
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

    // ---------------------------------------------------------------- transfers reported by the token

    /// @notice Called by BossToken after every transfer. BOSS leaving the pool carries this
    /// transaction's pending credit (and the killing blow, if the round just closed) to the wallet
    /// that receives it. BOSS leaving a wallet takes that wallet's credit with it, in proportion to
    /// the BOSS it bought this round: forfeited when the BOSS goes into the pool (or into this hook,
    /// where BOSS can never move again), moved when it goes to another wallet. Bookkeeping only: its
    /// one external call is a read of the BOSS token's balance (in the transaction of a kill), and it
    /// has no revert path beyond the caller check, so it can never block a transfer.
    function onBossTransfer(address from, address to, uint256 value) external {
        if (msg.sender != bossToken) revert NotBossToken();
        if (value == 0 || from == to) return;
        address pm = address(poolManager);
        if (from == pm) {
            _arrive(to, value);
            return;
        }
        bool sink = to == pm || to == address(this);
        // The open round first: its BOSS count is exact (it follows every transfer), so what is
        // left of the transfer after it is BOSS from earlier rounds.
        uint64 r = round;
        (uint256 dmg, uint256 bossAmount) = _release(r, from, value, sink);
        if (bossAmount != 0) {
            if (sink) {
                if (dmg != 0) {
                    eligibleDamage[r] -= dmg;
                    emit Forfeited(r, from, dmg);
                    // Credit that leaves the game no longer counts against this transaction's cap.
                    _anchor(r);
                    _tstore(T_PEND_HP0, _tload(T_PEND_HP0) + dmg);
                }
            } else {
                damage[r][to] += dmg;
                bought[r][to] += bossAmount;
                emit DamageMoved(r, from, to, dmg, bossAmount);
            }
            value -= bossAmount;
        }
        if (value == 0) return;
        uint64 kr = uint64(_tload(T_KILL_ROUND));
        if (kr == 0) return;
        _hopBlow(kr, from, sink ? address(0) : to, value);
    }

    /// @dev A hop in the transaction that closed round `kr`. Only the killing blow's BOSS carries that
    /// round's credit and its prize (a router that custodies the blow and then delivers it); every
    /// other credit of the closed round stays where it is, as in any later transaction. Which BOSS
    /// leaves a wallet cannot be seen, so: the locker that executed the killing swap (the custodian)
    /// pays the blow out in proportion to its balance, so a fee taken as a share of it carries only
    /// that share even with BOSS planted on it; any other contract (a forwarder) hands the blow on
    /// first, so BOSS planted on it never holds the blow back; a wallet without code spends its older
    /// BOSS first: what it still holds after the transfer counts as blow BOSS, so older BOSS sent away
    /// never takes the blow with it. A closed round is never forfeited, so blow BOSS going into a sink
    /// (`to` zero) leaves its credit with `from`, held by nobody from then on.
    function _hopBlow(uint64 kr, address from, address to, uint256 value) internal {
        uint256 hf = _tload(_heldSlot(kr, from));
        if (hf == 0) return;
        uint256 out;
        if (from == address(uint160(_tload(T_KILL_LOCKER)))) {
            out = hf * value / (IBossToken(bossToken).balanceOf(from) + value);
            if (to != address(0) && from != tx.origin) _tstore(T_KILL_PAID, 1);
        } else if (from.code.length != 0) {
            out = value < hf ? value : hf;
        } else {
            uint256 left = IBossToken(bossToken).balanceOf(from);
            out = hf > left ? hf - left : 0;
            if (out > value) out = value;
        }
        if (out == 0) return;
        bytes32 fd = _blowDmgSlot(kr, from);
        uint256 dh = _tload(fd);
        uint256 dOut = out == hf ? dh : dh * out / hf;
        _tstore(fd, dh - dOut);
        // Credit `from` already collected stays collected: it is not paid twice. A wallet that got
        // blow BOSS whose credit was already collected holds the BOSS without its credit.
        if (to != address(0) && !damageClaimed[kr][from]) {
            uint256 bf = bought[kr][from];
            uint256 bOut = out < bf ? out : bf;
            if (dOut != 0 || bOut != 0) {
                damage[kr][from] -= dOut;
                bought[kr][from] = bf - bOut;
                damage[kr][to] += dOut;
                bought[kr][to] += bOut;
                emit DamageMoved(kr, from, to, dOut, bOut);
                bytes32 td = _blowDmgSlot(kr, to);
                _tstore(td, _tload(td) + dOut);
            }
        }
        _trackKill(kr, from, to, out);
    }

    function _blowDmgSlot(uint64 kr, address who) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(T_KILL_DMG, kr, who));
    }

    /// @dev BOSS left the pool for `to`: first the killing credit of a round this transaction closed
    /// (held by the signer since the kill), then the pending credit of the open round. BOSS taken
    /// straight into this hook carries no credit: the killing part stays with the signer and the
    /// pending part is void.
    function _arrive(address to, uint256 value) internal {
        bool sink = to == address(this);
        uint256 kb = _tload(T_KILL_BOSS);
        if (kb != 0) {
            uint64 kr = uint64(_tload(T_KILL_ROUND));
            uint256 kd = _tload(T_KILL_DAMAGE);
            (uint256 dmg, uint256 bossAmount) = _slice(kd, kb, value);
            _tstore(T_KILL_DAMAGE, kd - dmg);
            _tstore(T_KILL_BOSS, kb - bossAmount);
            address signer = tx.origin;
            if (!sink) {
                // Credit the signer already collected stays collected: it is not paid twice.
                bool moved = to != signer && !damageClaimed[kr][signer];
                if (moved) {
                    // The signer's count can be short when blow BOSS whose credit was already
                    // collected passed through her: never below zero.
                    uint256 bs = bought[kr][signer];
                    uint256 bm = bossAmount < bs ? bossAmount : bs;
                    damage[kr][signer] -= dmg;
                    bought[kr][signer] = bs - bm;
                    damage[kr][to] += dmg;
                    bought[kr][to] += bm;
                    emit DamageMoved(kr, signer, to, dmg, bm);
                }
                // The blow's credit `to` now holds travels with that BOSS on later hops.
                if (moved || to == signer) {
                    bytes32 td = _blowDmgSlot(kr, to);
                    _tstore(td, _tload(td) + dmg);
                }
                _trackKill(kr, address(0), to, bossAmount);
            }
            value -= bossAmount;
            if (value == 0) return;
        }
        if (_tload(T_PEND_BOSS) == 0) return;
        uint256 pd = _cappedPending();
        uint256 pb = _tload(T_PEND_BOSS);
        if (pb == 0) return;
        (uint256 dmg2, uint256 boss2) = _slice(pd, pb, value);
        _tstore(T_PEND_DAMAGE, pd - dmg2);
        _tstore(T_PEND_BOSS, pb - boss2);
        if (sink) return;
        _tstore(T_PEND_HP0, _tload(T_PEND_HP0) - dmg2);
        _credit(uint64(_tload(T_PEND_ROUND)), to, dmg2, boss2);
    }

    /// @dev Tracks how much of the killing blow's BOSS each wallet holds so far in this transaction
    /// (`from` is zero when the BOSS comes out of the pool, `to` is zero when it goes into a sink;
    /// on a hop only what `from` holds of it counts). The killer prize goes to the wallet that holds
    /// more than half of the blow's BOSS (the killing swap's router stops counting once it pays the
    /// blow out); while no wallet does, it stays with the signer. A fee of any share, a solver keeping
    /// a wei, BOSS planted on a router, a custodian that sells part of the blow back or another player's
    /// transfer bundled after the kill never take it from the wallet that receives most of the blow.
    function _trackKill(uint64 kr, address from, address to, uint256 amount) internal {
        if (from != address(0)) {
            bytes32 fs = _heldSlot(kr, from);
            uint256 hf = _tload(fs);
            if (amount > hf) amount = hf;
            if (amount == 0) return;
            _tstore(fs, hf - amount);
        }
        if (to != address(0)) {
            bytes32 ts = _heldSlot(kr, to);
            _tstore(ts, _tload(ts) + amount);
        }
        address k = results[kr].killer;
        uint256 total = _tload(T_KILL_TOTAL);
        address w = tx.origin;
        if (to != address(0) && 2 * _weight(kr, to) > total) w = to;
        else if (2 * _weight(kr, k) > total) w = k;
        if (w != k) _moveKill(kr, k, w);
    }

    /// @dev What `w` holds of the blow, for the prize: the killing swap's locker stops counting once it
    /// pays the blow out to wallets (see T_KILL_PAID).
    function _weight(uint64 kr, address w) internal view returns (uint256) {
        if (_tload(T_KILL_PAID) != 0 && w == address(uint160(_tload(T_KILL_LOCKER)))) return 0;
        return _tload(_heldSlot(kr, w));
    }

    function _heldSlot(uint64 kr, address who) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(T_KILL_HELD, kr, who));
    }

    /// @dev The killer prize moves with the killing blow's BOSS, unless it was already claimed.
    function _moveKill(uint64 r, address from, address to) internal {
        RoundResult storage res = results[r];
        uint256 prize = res.killerPrize;
        if (res.killer != from || unclaimedKill[from] < prize) return;
        unclaimedKill[from] -= prize;
        unclaimedKill[to] += prize;
        res.killer = to;
        emit KillerCredited(r, to);
    }

    /// @dev `value` BOSS out of `bossTotal` carries the same share of `dmgTotal`; all of it once
    /// `value` covers the total.
    function _slice(uint256 dmgTotal, uint256 bossTotal, uint256 value)
        internal
        pure
        returns (uint256 dmg, uint256 bossAmount)
    {
        if (value >= bossTotal) return (dmgTotal, bossTotal);
        return (dmgTotal * value / bossTotal, value);
    }

    /// @dev Takes `value` BOSS worth of round `r` credit away from `from`, in proportion to the BOSS
    /// it bought. A wallet with no buy this round has nothing to give up. A forfeit (`up`) is a charge
    /// on the wallet handing BOSS back, so it is rounded up; a move to another wallet rounds down.
    function _release(uint64 r, address from, uint256 value, bool up)
        internal
        returns (uint256 dmg, uint256 bossAmount)
    {
        uint256 owned = bought[r][from];
        if (owned == 0) return (0, 0);
        uint256 had = damage[r][from];
        (dmg, bossAmount) = _slice(had, owned, value);
        if (up && dmg * owned < had * bossAmount) dmg += 1;
        bought[r][from] = owned - bossAmount;
        damage[r][from] = had - dmg;
    }

    function _credit(uint64 r, address to, uint256 dmg, uint256 bossAmount) internal {
        if (dmg == 0 && bossAmount == 0) return;
        damage[r][to] += dmg;
        bought[r][to] += bossAmount;
        eligibleDamage[r] += dmg;
        emit Credited(r, to, dmg, bossAmount);
    }

    function _tload(bytes32 slot) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 v) internal {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
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
        if (res.endedAt == 0 || damageClaimed[r][who]) return 0;
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

    // ---------------------------------------------------------------- misc

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
