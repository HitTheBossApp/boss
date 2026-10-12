// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {BossHook} from "../../src/BossHook.sol";
import {BossToken} from "../../src/BossToken.sol";

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Third-review router. Works for both the IMD and the native-ETH pairing and for any pool
/// key (also a hookless BOSS pool). All four swap shapes, flash sells (sell BOSS it does not own,
/// bought back later in the same unlock), takes, claims, and a `multi` that runs several unlocks and
/// claims back to back in one transaction. Leftover deltas are settled from its own balances.
contract R3Router is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    enum Kind {
        BuyIn, // exact-in buy of `amount` quote
        BuyOut, // exact-out buy of `amount` BOSS
        SellIn, // exact-in sell of `amount` BOSS (flash: settled at the end)
        SellOut, // exact-out sell for `amount` quote (flash)
        BuyBackLast, // exact-out buy of the BOSS the last sell paid in
        TakeBoss, // take up to `amount` owed BOSS to `who`
        TakeBossShare, // take num/den of the owed BOSS to `who`
        KeepClaims, // keep up to `amount` owed BOSS as ERC-6909 claims
        ClaimsToBoss, // burn up to `amount` of own claims, take the BOSS to `who`
        DepositOwn, // move `amount` of its own BOSS into the PoolManager as ERC-6909 claims
        SellOwnShare // exact-in sell of num/den of the BOSS it holds (settled from its balance)
    }

    struct Action {
        Kind kind;
        address who;
        uint256 amount;
        uint256 num;
        uint256 den;
    }

    IPoolManager public immutable manager;
    BossToken public immutable boss;
    bool public immutable bossIs0;
    PoolKey internal key;
    uint256 internal lastBoss;

    constructor(IPoolManager manager_, PoolKey memory key_, BossToken boss_) {
        manager = manager_;
        key = key_;
        boss = boss_;
        bossIs0 = Currency.unwrap(key_.currency0) == address(boss_);
    }

    receive() external payable {}

    function a(Kind k, address who, uint256 amount) external pure returns (Action memory) {
        return Action(k, who, amount, 0, 0);
    }

    function share(address who, uint256 num, uint256 den) external pure returns (Action memory) {
        return Action(Kind.TakeBossShare, who, 0, num, den);
    }

    function run(Action[] calldata actions) external {
        manager.unlock(abi.encode(actions));
    }

    function claimKill(address w) external {
        BossHook(address(key.hooks)).claimKill(w);
    }

    function claimDamage(uint64 r, address w) external {
        BossHook(address(key.hooks)).claimDamage(r, w);
    }

    function forward(address to, uint256 amount) external {
        uint256 bal = boss.balanceOf(address(this));
        boss.transfer(to, amount < bal ? amount : bal);
    }

    function tryClaimKill(address w) external {
        try BossHook(address(key.hooks)).claimKill(w) {} catch {}
    }

    function tryClaimDamage(uint64 r, address w) external {
        try BossHook(address(key.hooks)).claimDamage(r, w) {} catch {}
    }

    uint256 public lastGas;

    /// @dev Transfers all its BOSS to `to` and records the gas that one transfer used.
    function forwardMeasured(address to) external {
        uint256 bal = boss.balanceOf(address(this));
        uint256 g = gasleft();
        boss.transfer(to, bal);
        lastGas = g - gasleft();
    }

    function multi(bytes[] calldata calls) external {
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = address(this).call(calls[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        Action[] memory actions = abi.decode(data, (Action[]));
        Currency bossC = _bossC();
        uint256 bossId = bossC.toId();
        for (uint256 i = 0; i < actions.length; i++) {
            Action memory x = actions[i];
            if (x.kind == Kind.BuyIn) {
                _swap(!bossIs0, -int256(x.amount));
            } else if (x.kind == Kind.BuyOut) {
                _swap(!bossIs0, int256(x.amount));
            } else if (x.kind == Kind.SellIn) {
                BalanceDelta d = _swap(bossIs0, -int256(x.amount));
                lastBoss = _abs(bossIs0 ? d.amount0() : d.amount1());
            } else if (x.kind == Kind.SellOut) {
                BalanceDelta d = _swap(bossIs0, int256(x.amount));
                lastBoss = _abs(bossIs0 ? d.amount0() : d.amount1());
            } else if (x.kind == Kind.BuyBackLast) {
                _swap(!bossIs0, int256(lastBoss));
            } else if (x.kind == Kind.TakeBoss) {
                uint256 amt = _cap(_owed(bossC), x.amount);
                if (amt > 0) manager.take(bossC, x.who, amt);
            } else if (x.kind == Kind.TakeBossShare) {
                uint256 amt = _owed(bossC) * x.num / x.den;
                if (amt > 0) manager.take(bossC, x.who, amt);
            } else if (x.kind == Kind.KeepClaims) {
                uint256 amt = _cap(_owed(bossC), x.amount);
                if (amt > 0) manager.mint(address(this), bossId, amt);
            } else if (x.kind == Kind.SellOwnShare) {
                uint256 amt = boss.balanceOf(address(this)) * x.num / x.den;
                if (amt > 0) _swap(bossIs0, -int256(amt));
            } else if (x.kind == Kind.DepositOwn) {
                manager.sync(bossC);
                boss.transfer(address(manager), x.amount);
                manager.settle();
                manager.mint(address(this), bossId, x.amount);
            } else if (x.kind == Kind.ClaimsToBoss) {
                uint256 amt = _cap(manager.balanceOf(address(this), bossId), x.amount);
                if (amt > 0) {
                    manager.burn(address(this), bossId, amt);
                    manager.take(bossC, x.who, amt);
                }
            }
        }
        _settleUp(bossC);
        _settleUp(bossIs0 ? key.currency1 : key.currency0);
        return "";
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        uint160 lim = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return manager.swap(key, SwapParams(zeroForOne, amountSpecified, lim), "");
    }

    function _settleUp(Currency c) internal {
        int256 d = manager.currencyDelta(address(this), c);
        if (d < 0) {
            if (c.isAddressZero()) {
                manager.settle{value: uint256(-d)}();
            } else {
                manager.sync(c);
                IERC20Min(Currency.unwrap(c)).transfer(address(manager), uint256(-d));
                manager.settle();
            }
        } else if (d > 0) {
            manager.take(c, address(this), uint256(d));
        }
    }

    function _owed(Currency c) internal view returns (uint256) {
        int256 d = manager.currencyDelta(address(this), c);
        return d > 0 ? uint256(d) : 0;
    }

    function _bossC() internal view returns (Currency) {
        return bossIs0 ? key.currency0 : key.currency1;
    }

    function _cap(uint256 x, uint256 y) internal pure returns (uint256) {
        return y < x ? y : x;
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }
}

/// @notice Two senders inside ONE unlock (any contract may call PoolManager.swap while it is unlocked;
/// deltas accrue to the caller). The healer flash-sells BOSS it does not own; inside its unlock the
/// hitter buys that BOSS back, kills, keeps the bought-back BOSS as ERC-6909 claims and hands the
/// claims to the healer, who burns them to pay its BOSS debt. Only the killing blow's BOSS ever
/// moves as a token. Used to test a fix that anchors the credit cap per locker.
contract SplitHealer is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    BossToken public immutable boss;
    bool public immutable bossIs0;
    PoolKey internal key;
    SplitHitter public immutable hitter;

    constructor(IPoolManager manager_, PoolKey memory key_, BossToken boss_) {
        manager = manager_;
        key = key_;
        boss = boss_;
        bossIs0 = Currency.unwrap(key_.currency0) == address(boss_);
        hitter = new SplitHitter(manager_, key_, boss_);
    }

    receive() external payable {}

    function run(uint256 sellBoss, uint256 killQuote, address wallet) external {
        manager.unlock(abi.encode(sellBoss, killQuote, wallet));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (uint256 sellBoss, uint256 killQuote, address wallet) = abi.decode(data, (uint256, uint256, address));
        Currency bossC = bossIs0 ? key.currency0 : key.currency1;
        Currency quoteC = bossIs0 ? key.currency1 : key.currency0;
        uint160 lim = bossIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = manager.swap(key, SwapParams(bossIs0, -int256(sellBoss), lim), ""); // heal (flash)
        int128 b = bossIs0 ? d.amount0() : d.amount1();
        uint256 owed = uint256(uint128(-b));
        hitter.hitAndKill(owed, killQuote, wallet, address(this)); // other sender, same unlock
        manager.burn(address(this), bossC.toId(), owed); // pays the BOSS debt with the hitter's claims
        int256 q = manager.currencyDelta(address(this), quoteC);
        if (q > 0) manager.take(quoteC, address(this), uint256(q));
        return "";
    }
}

contract SplitHitter {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    BossToken public immutable boss;
    bool public immutable bossIs0;
    PoolKey internal key;

    constructor(IPoolManager manager_, PoolKey memory key_, BossToken boss_) {
        manager = manager_;
        key = key_;
        boss = boss_;
        bossIs0 = Currency.unwrap(key_.currency0) == address(boss_);
    }

    receive() external payable {}

    function hitAndKill(uint256 bossBack, uint256 killQuote, address wallet, address healer) external {
        Currency bossC = bossIs0 ? key.currency0 : key.currency1;
        Currency quoteC = bossIs0 ? key.currency1 : key.currency0;
        bool z = !bossIs0;
        uint160 lim = z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        manager.swap(key, SwapParams(z, int256(bossBack), lim), ""); // buy the healed BOSS back
        manager.swap(key, SwapParams(z, -int256(killQuote), lim), ""); // the killing buy
        manager.mint(address(this), bossC.toId(), bossBack);
        manager.transfer(healer, bossC.toId(), bossBack); // ERC-6909 claims, no token moves
        int256 owed = manager.currencyDelta(address(this), bossC);
        if (owed > 0) manager.take(bossC, wallet, uint256(owed)); // only the blow's BOSS leaves
        int256 q = manager.currencyDelta(address(this), quoteC);
        if (q < 0) {
            if (quoteC.isAddressZero()) {
                manager.settle{value: uint256(-q)}();
            } else {
                manager.sync(quoteC);
                IERC20Min(Currency.unwrap(quoteC)).transfer(address(manager), uint256(-q));
                manager.settle();
            }
        }
    }
}
