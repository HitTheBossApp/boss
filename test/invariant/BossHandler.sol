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

/// @notice Random buys and sells (all four swap shapes), time jumps and all three claims by five
/// actors on the BOSS/IMD pool. Ghosts track every fee charged and every IMD actually received.
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

    uint256 public swapsOk;
    uint256 public exactOutBuysOk;
    uint256 public exactOutSellsOk;
    uint256 public damageClaims;
    uint256 public killClaims;
    uint256 public treasuryClaims;

    constructor(
        BossHook h,
        BossToken b,
        MockERC20 imd_,
        PoolSwapTest r,
        IPoolManager m,
        PoolKey memory k,
        bool b0
    ) {
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

    function _swapTry(address a, SwapParams memory p) internal returns (bool ok) {
        uint256 before = hookClaims();
        vm.prank(a, a);
        try router.swap(key, p, PoolSwapTest.TestSettings(false, false), abi.encode(a)) {
            ok = true;
        } catch {}
        // A reverted swap leaves the claims untouched; a successful one only ever mints fees.
        totalFees += hookClaims() - before;
        if (ok) swapsOk++;
    }
}
