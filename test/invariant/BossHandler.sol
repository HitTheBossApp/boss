// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BossHook} from "../../src/BossHook.sol";
import {BossToken} from "../../src/BossToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FlashBait} from "../BossHook.Forfeit.t.sol";
import {ScriptRouter} from "../utils/ScriptRouter.sol";

/// @dev A contract that trades inside whoever calls it (tx.origin = that actor). It separates the
/// three identities the audit asked the suite to separate (finding 7): the signer, the contract
/// that calls the router, and the holder of the BOSS being sold.
contract TradeBait {
    PoolSwapTest internal immutable router;
    PoolKey internal key;
    bool internal immutable bossIs0;

    constructor(PoolSwapTest router_, PoolKey memory key_, bool bossIs0_, BossToken boss, MockERC20 imd) {
        router = router_;
        key = key_;
        bossIs0 = bossIs0_;
        boss.approve(address(router_), type(uint256).max);
        imd.approve(address(router_), type(uint256).max);
    }

    function buy(uint256 quoteAmount) external {
        bool z = !bossIs0;
        router.swap(key, SwapParams(z, -int256(quoteAmount), _limit(z)), PoolSwapTest.TestSettings(false, false), "");
    }

    function sell(uint256 bossAmount) external {
        bool z = bossIs0;
        router.swap(key, SwapParams(z, -int256(bossAmount), _limit(z)), PoolSwapTest.TestSettings(false, false), "");
    }

    function _limit(bool z) internal pure returns (uint160) {
        return z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
}

/// @notice Random buys and sells (all four swap shapes), trades a bait contract runs inside an
/// actor's transaction, time jumps and all three claims by five actors on the BOSS/IMD pool.
/// Ghosts track every fee charged and every IMD actually received.
contract BossHandler is Test {
    BossHook public hook;
    BossToken public boss;
    MockERC20 public imd;
    PoolSwapTest public router;
    IPoolManager public manager;
    PoolKey public key;
    bool public bossIsCurrency0;
    address[] public actors;

    /// @notice IMD actually received by winners and damage dealers through claimKill/claimDamage.
    uint256 public totalPaidOut;
    /// @notice IMD actually received by the keeper through claimTreasury.
    uint256 public treasuryPaid;
    /// @notice Every fee ever charged, measured as the hook's ERC-6909 claim growth during swaps.
    uint256 public totalFees;

    mapping(uint64 round => uint256) public damagePaidInRound;
    mapping(address winner => uint256) public killPaidTo;

    /// @notice Trades inside an actor's transaction; its own BOSS and IMD, the actor as tx.origin.
    TradeBait public bait;
    /// @notice Sells borrowed BOSS and buys it back inside an actor's transaction (flash accounting).
    FlashBait public flash;
    /// @notice Signs transactions for the actors without ever touching BOSS (a relayer, a bundler).
    address public relayer = address(0xBEEF);
    /// @notice A router that custodies the BOSS it buys and delivers it in a second hop, sometimes
    /// after paying an interface fee (the Universal Router's custody shape).
    ScriptRouter public custody;
    address public feeCollector = address(0xFEE);

    uint256 public swapsOk;
    uint256 public baitTradesOk;
    uint256 public relayedOk;
    uint256 public transfers;
    uint256 public flashOk;
    uint256 public claimsBuys;
    uint256 public routedOk;
    uint256 public exactOutBuysOk;
    uint256 public exactOutSellsOk;
    uint256 public damageClaims;
    uint256 public killClaims;
    uint256 public treasuryClaims;

    constructor(BossHook h, BossToken b, MockERC20 imd_, PoolSwapTest r, IPoolManager m, PoolKey memory k, bool b0) {
        hook = h;
        boss = b;
        imd = imd_;
        router = r;
        manager = m;
        key = k;
        bossIsCurrency0 = b0;
        for (uint256 i = 0; i < 5; i++) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            imd.mint(a, 1_000_000 ether);
            vm.startPrank(a);
            imd.approve(address(router), type(uint256).max);
            boss.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        bait = new TradeBait(r, k, b0, b, imd_);
        imd_.mint(address(bait), 1_000_000 ether);
        flash = new FlashBait(m, k, b0, imd_);
        imd_.mint(address(flash), 1_000_000 ether);
        custody = new ScriptRouter(m, h, k, b0, b, imd_);
        imd_.mint(address(custody), 1_000_000 ether);
    }

    // ------------------------------------------------------------------ buys through a router that custodies

    /// @dev Pool -> router -> actor, with a 0.25% interface fee first every other time. The router
    /// never ends up holding credit, the kill or the prize.
    function routedBuy(uint256 who, uint256 amount, bool withFee) external {
        amount = bound(amount, 0.001 ether, 2 ether);
        address a = _actor(who);
        ScriptRouter.Action[] memory s = new ScriptRouter.Action[](withFee ? 4 : 3);
        s[0] = custody.buy(amount);
        s[1] = custody.takeBoss(address(custody), type(uint256).max);
        if (withFee) {
            s[2] = custody.forwardShare(feeCollector, 25, 10_000);
            s[3] = custody.forward(a, type(uint256).max);
        } else {
            s[2] = custody.forward(a, type(uint256).max);
        }
        uint256 before = hookClaims();
        vm.prank(a, a);
        try custody.run(s) {
            routedOk++;
        } catch {}
        totalFees += hookClaims() - before;
    }

    // ------------------------------------------------------------------ trades inside someone else's tx

    /// @dev The bait buys with its own IMD inside `who`'s transaction and receives the BOSS: the
    /// hit is credited to the bait, not to `who`.
    function baitBuyIn(uint256 who, uint256 amount) external {
        amount = bound(amount, 0.001 ether, 1 ether);
        _baitTrade(_actor(who), abi.encodeCall(TradeBait.buy, (amount)));
    }

    /// @dev The bait sells its own BOSS inside `who`'s transaction: the bait forfeits, `who` is untouched.
    function baitSellIn(uint256 who, uint256 pct) external {
        uint256 bal = boss.balanceOf(address(bait));
        if (bal == 0) return;
        _baitTrade(_actor(who), abi.encodeCall(TradeBait.sell, (bal * bound(pct, 1, 100) / 100)));
    }

    /// @dev A flash round trip inside `who`'s transaction: no BOSS moves, nothing changes for anyone.
    function flashIn(uint256 who, uint256 bossAmount) external {
        bossAmount = bound(bossAmount, 1 ether, 1_000_000 ether);
        uint256 before = hookClaims();
        vm.prank(_actor(who), _actor(who));
        (bool ok,) = address(flash).call(abi.encodeCall(FlashBait.claimAirdrop, (bossAmount)));
        totalFees += hookClaims() - before;
        if (ok) flashOk++;
    }

    // ------------------------------------------------------------------ the signer is not the wallet

    /// @dev The relayer signs; the actor calls the router and receives the BOSS: the hit is the actor's.
    function relayedBuy(uint256 who, uint256 amount) external {
        amount = bound(amount, 0.001 ether, 2 ether);
        bool z = !bossIsCurrency0;
        if (_swapAs(_actor(who), relayer, SwapParams(z, -int256(amount), _limit(z)))) relayedOk++;
    }

    /// @dev The relayer signs the sell of the actor's own BOSS: the actor forfeits.
    function relayedSell(uint256 who, uint256 pct) external {
        address a = _actor(who);
        uint256 bal = boss.balanceOf(a);
        if (bal == 0) return;
        bool z = bossIsCurrency0;
        if (_swapAs(a, relayer, SwapParams(z, -int256(bal * bound(pct, 1, 100) / 100), _limit(z)))) relayedOk++;
    }

    /// @dev A buy kept as ERC-6909 claims: the BOSS never leaves the pool, so nobody is credited.
    function buyAsClaims(uint256 who, uint256 amount) external {
        amount = bound(amount, 0.001 ether, 1 ether);
        address a = _actor(who);
        bool z = !bossIsCurrency0;
        uint256 before = hookClaims();
        vm.prank(a, a);
        try router.swap(key, SwapParams(z, -int256(amount), _limit(z)), PoolSwapTest.TestSettings(true, false), "") {
            claimsBuys++;
        } catch {}
        totalFees += hookClaims() - before;
    }

    // ------------------------------------------------------------------ transfers between wallets

    /// @dev Credit travels with BOSS sent to another wallet, in proportion.
    function transferTo(uint256 who, uint256 toWho, uint256 pct) external {
        address a = _actor(who);
        address b = _actor(toWho);
        uint256 bal = boss.balanceOf(a);
        if (bal == 0 || a == b) return;
        vm.prank(a);
        boss.transfer(b, bal * bound(pct, 1, 100) / 100);
        transfers++;
    }

    /// @dev BOSS sent to the hook is lost and its credit is forfeited, like BOSS handed back to the pool.
    function sendToHook(uint256 who, uint256 pct) external {
        address a = _actor(who);
        uint256 bal = boss.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        boss.transfer(address(hook), bal * bound(pct, 1, 100) / 100);
        transfers++;
    }

    // ------------------------------------------------------------------ swaps

    function buy(uint256 who, uint256 amount) external {
        amount = bound(amount, 0.001 ether, 2 ether);
        bool z = !bossIsCurrency0;
        // Exact-input buys are what the site sends: they must never revert.
        _swapStrict(_actor(who), SwapParams(z, -int256(amount), _limit(z)));
    }

    function buyExactOut(uint256 who, uint256 bossAmount) external {
        bossAmount = bound(bossAmount, 1_000 ether, 2_000_000 ether);
        bool z = !bossIsCurrency0;
        if (_swapTry(_actor(who), SwapParams(z, int256(bossAmount), _limit(z)))) exactOutBuysOk++;
    }

    function sell(uint256 who, uint256 pct) external {
        address a = _actor(who);
        uint256 bal = boss.balanceOf(a);
        if (bal == 0) return;
        uint256 amount = bal * bound(pct, 1, 100) / 100;
        bool z = bossIsCurrency0;
        _swapTry(a, SwapParams(z, -int256(amount), _limit(z)));
    }

    /// @dev Reverts legitimately when the pool holds too little IMD (partial fill) or the actor
    /// has too little BOSS to pay for the exact output.
    function sellExactOut(uint256 who, uint256 quoteAmount) external {
        address a = _actor(who);
        if (boss.balanceOf(a) == 0) return;
        quoteAmount = bound(quoteAmount, 0.0001 ether, 1 ether);
        bool z = bossIsCurrency0;
        if (_swapTry(a, SwapParams(z, int256(quoteAmount), _limit(z)))) exactOutSellsOk++;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
    }

    // ------------------------------------------------------------------ claims

    function claimDamage(uint256 who, uint64 r) external {
        address a = _actor(who);
        uint64 maxRound = hook.round();
        if (maxRound < 2) return;
        r = uint64(bound(r, 1, maxRound - 1));
        uint256 owed = hook.claimableDamage(r, a);
        if (owed == 0) return;
        uint256 before = imd.balanceOf(a);
        hook.claimDamage(r, a);
        uint256 got = imd.balanceOf(a) - before;
        totalPaidOut += got;
        damagePaidInRound[r] += got;
        damageClaims++;
    }

    function claimKill(uint256 who) external {
        address a = _actor(who);
        uint256 owed = hook.unclaimedKill(a);
        if (owed == 0) return;
        uint256 before = imd.balanceOf(a);
        hook.claimKill(a);
        uint256 got = imd.balanceOf(a) - before;
        totalPaidOut += got;
        killPaidTo[a] += got;
        killClaims++;
    }

    function claimTreasury() external {
        if (hook.treasuryOwed() == 0) return;
        address k = hook.keeper();
        uint256 before = imd.balanceOf(k);
        hook.claimTreasury();
        treasuryPaid += imd.balanceOf(k) - before;
        treasuryClaims++;
    }

    // ------------------------------------------------------------------ views

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function hookClaims() public view returns (uint256) {
        return manager.balanceOf(address(hook), hook.quote().toId());
    }

    // ------------------------------------------------------------------ internals

    function _actor(uint256 who) internal view returns (address) {
        return actors[who % actors.length];
    }

    function _limit(bool z) internal pure returns (uint160) {
        return z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _swapStrict(address a, SwapParams memory p) internal {
        uint256 before = hookClaims();
        vm.prank(a, a);
        router.swap(key, p, PoolSwapTest.TestSettings(false, false), abi.encode(a));
        totalFees += hookClaims() - before;
        swapsOk++;
    }

    function _baitTrade(address a, bytes memory call) internal {
        uint256 before = hookClaims();
        vm.prank(a, a);
        (bool ok,) = address(bait).call(call);
        totalFees += hookClaims() - before;
        if (ok) baitTradesOk++;
    }

    function _swapTry(address a, SwapParams memory p) internal returns (bool ok) {
        return _swapAs(a, a, p);
    }

    /// @dev `a` calls the router (and receives or pays the BOSS); `origin` signs the transaction.
    function _swapAs(address a, address origin, SwapParams memory p) internal returns (bool ok) {
        uint256 before = hookClaims();
        vm.prank(a, origin);
        try router.swap(key, p, PoolSwapTest.TestSettings(false, false), abi.encode(a)) {
            ok = true;
        } catch {}
        // A reverted swap leaves the claims untouched; a successful one only ever mints fees.
        totalFees += hookClaims() - before;
        if (ok) swapsOk++;
    }
}
