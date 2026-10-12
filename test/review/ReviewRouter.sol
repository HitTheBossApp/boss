// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {BossHook} from "../../src/BossHook.sol";
import {BossToken} from "../../src/BossToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Review-only router. One transaction can hold several PoolManager unlocks with hook
/// claims and plain token transfers in between (`multi`), and inside an unlock it can buy, sell,
/// take BOSS to anyone (also as a flash take it does not own yet), keep or deposit claims, settle
/// a BOSS debt from a wallet that approved it (the Permit2 / Universal Router shape) and add or
/// remove liquidity of its own position. Whatever is still owed at the end of an unlock is settled
/// from and to the router's own balances.
contract ReviewRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    enum Kind {
        Buy, // exact-in buy of `amount` IMD, paid by the router
        BuyExactOut, // exact-out buy of `amount` BOSS, paid by the router
        Sell, // exact-in sell of `amount` BOSS (the debt is settled by a later SettleBossFrom or at the end)
        TakeBoss, // take up to `amount` of the owed BOSS to `who`
        TakeBossShare, // take num/den of the owed BOSS to `who`
        TakeBossAsClaims, // keep up to `amount` of the owed BOSS as ERC-6909 claims
        DepositAsClaims, // transferFrom(who -> PoolManager) `amount`, minted as claims to the router
        ClaimsToBoss, // burn up to `amount` of the router's claims and take the BOSS to `who`
        SettleBossFrom, // pay `amount` of BOSS debt with `who`'s BOSS (who approved the router)
        FlashTakeBoss, // take `amount` BOSS to `who` without owning it (settled at the end from the router)
        RemoveLiquidity, // remove `amount` liquidity from the router's position
        AddLiquidity, // add `amount` liquidity to the router's position (BOSS settled at the end)
        TakeQuote, // take up to `amount` owed IMD to `who`
        SellPctFrom, // sell `amount`% of `who`'s BOSS balance, settled from `who` (who approved the router)
        DepositPctFrom // deposit `amount`% of `who`'s BOSS as claims held by the router
    }

    struct Action {
        Kind kind;
        address who;
        uint256 amount;
        uint256 num;
        uint256 den;
    }

    IPoolManager public immutable manager;
    BossHook public immutable hook;
    BossToken public immutable boss;
    MockERC20 public immutable imd;
    bool public immutable bossIs0;
    PoolKey internal key;
    int24 public immutable lower;
    int24 public immutable upper;

    constructor(
        IPoolManager manager_,
        BossHook hook_,
        PoolKey memory key_,
        bool bossIs0_,
        BossToken boss_,
        MockERC20 imd_,
        int24 lower_,
        int24 upper_
    ) {
        manager = manager_;
        hook = hook_;
        key = key_;
        bossIs0 = bossIs0_;
        boss = boss_;
        imd = imd_;
        lower = lower_;
        upper = upper_;
    }

    // ------------------------------------------------------------------ builders

    function buy(uint256 quoteIn) external pure returns (Action memory) {
        return Action(Kind.Buy, address(0), quoteIn, 0, 0);
    }

    function buyExactOut(uint256 bossOut) external pure returns (Action memory) {
        return Action(Kind.BuyExactOut, address(0), bossOut, 0, 0);
    }

    function sell(uint256 bossIn) external pure returns (Action memory) {
        return Action(Kind.Sell, address(0), bossIn, 0, 0);
    }

    function takeBoss(address to, uint256 amount) external pure returns (Action memory) {
        return Action(Kind.TakeBoss, to, amount, 0, 0);
    }

    function takeBossShare(address to, uint256 num, uint256 den) external pure returns (Action memory) {
        return Action(Kind.TakeBossShare, to, 0, num, den);
    }

    function takeBossAsClaims(uint256 amount) external pure returns (Action memory) {
        return Action(Kind.TakeBossAsClaims, address(0), amount, 0, 0);
    }

    function depositAsClaims(address payer, uint256 amount) external pure returns (Action memory) {
        return Action(Kind.DepositAsClaims, payer, amount, 0, 0);
    }

    function claimsToBoss(address to, uint256 amount) external pure returns (Action memory) {
        return Action(Kind.ClaimsToBoss, to, amount, 0, 0);
    }

    function settleBossFrom(address payer, uint256 amount) external pure returns (Action memory) {
        return Action(Kind.SettleBossFrom, payer, amount, 0, 0);
    }

    function flashTakeBoss(address to, uint256 amount) external pure returns (Action memory) {
        return Action(Kind.FlashTakeBoss, to, amount, 0, 0);
    }

    function removeLiquidity(uint256 liquidity) external pure returns (Action memory) {
        return Action(Kind.RemoveLiquidity, address(0), liquidity, 0, 0);
    }

    function addLiquidity(uint256 liquidity) external pure returns (Action memory) {
        return Action(Kind.AddLiquidity, address(0), liquidity, 0, 0);
    }

    function takeQuote(address to, uint256 amount) external pure returns (Action memory) {
        return Action(Kind.TakeQuote, to, amount, 0, 0);
    }

    function sellPctFrom(address who, uint256 pct) external pure returns (Action memory) {
        return Action(Kind.SellPctFrom, who, pct, 0, 0);
    }

    function depositPctFrom(address who, uint256 pct) external pure returns (Action memory) {
        return Action(Kind.DepositPctFrom, who, pct, 0, 0);
    }

    // ------------------------------------------------------------------ steps (each is a call; `multi` chains them in one tx)

    function unlockWith(Action[] calldata actions) external {
        manager.unlock(abi.encode(actions));
    }

    function claimKill(address winner) external {
        hook.claimKill(winner);
    }

    function claimDamage(uint64 r, address who) external {
        hook.claimDamage(r, who);
    }

    /// @dev Plain wallet-to-wallet transfer of the router's own BOSS.
    function transferBoss(address to, uint256 amount) external {
        boss.transfer(to, amount);
    }

    /// @dev Wallet-to-wallet transfer on behalf of `from` (who approved the router).
    function transferBossFrom(address from, address to, uint256 amount) external {
        boss.transferFrom(from, to, amount);
    }

    function transferBossFromPct(address from, address to, uint256 pct) external {
        uint256 amt = boss.balanceOf(from) * pct / 100;
        if (amt > 0) boss.transferFrom(from, to, amt);
    }

    function tryClaimKill(address winner) external {
        try hook.claimKill(winner) {} catch {}
    }

    function tryClaimDamage(uint64 r, address who) external {
        try hook.claimDamage(r, who) {} catch {}
    }

    /// @dev Runs every call on itself, in order, in this one transaction. Reverts with the first failure.
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

    // ------------------------------------------------------------------ unlock

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        Action[] memory actions = abi.decode(data, (Action[]));
        Currency bossC = _bossCurrency();
        uint256 bossId = bossC.toId();
        for (uint256 i = 0; i < actions.length; i++) {
            Action memory a = actions[i];
            if (a.kind == Kind.Buy) {
                bool z = !bossIs0;
                manager.swap(key, SwapParams(z, -int256(a.amount), _limit(z)), "");
            } else if (a.kind == Kind.BuyExactOut) {
                bool z = !bossIs0;
                manager.swap(key, SwapParams(z, int256(a.amount), _limit(z)), "");
            } else if (a.kind == Kind.Sell) {
                bool z = bossIs0;
                manager.swap(key, SwapParams(z, -int256(a.amount), _limit(z)), "");
            } else if (a.kind == Kind.TakeBoss) {
                uint256 amt = _cap(_owedBoss(), a.amount);
                if (amt > 0) manager.take(bossC, a.who, amt);
            } else if (a.kind == Kind.TakeBossShare) {
                uint256 amt = _owedBoss() * a.num / a.den;
                if (amt > 0) manager.take(bossC, a.who, amt);
            } else if (a.kind == Kind.TakeBossAsClaims) {
                uint256 amt = _cap(_owedBoss(), a.amount);
                if (amt > 0) manager.mint(address(this), bossId, amt);
            } else if (a.kind == Kind.DepositAsClaims) {
                manager.sync(bossC);
                boss.transferFrom(a.who, address(manager), a.amount);
                manager.settle();
                manager.mint(address(this), bossId, a.amount);
            } else if (a.kind == Kind.ClaimsToBoss) {
                uint256 amt = _cap(manager.balanceOf(address(this), bossId), a.amount);
                if (amt > 0) {
                    manager.burn(address(this), bossId, amt);
                    manager.take(bossC, a.who, amt);
                }
            } else if (a.kind == Kind.SettleBossFrom) {
                manager.sync(bossC);
                boss.transferFrom(a.who, address(manager), a.amount);
                manager.settle();
            } else if (a.kind == Kind.FlashTakeBoss) {
                manager.take(bossC, a.who, a.amount);
            } else if (a.kind == Kind.RemoveLiquidity) {
                manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, -int256(a.amount), 0), "");
            } else if (a.kind == Kind.AddLiquidity) {
                manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(a.amount), 0), "");
            } else if (a.kind == Kind.TakeQuote) {
                int256 d = manager.currencyDelta(address(this), _quoteCurrency());
                uint256 amt = d > 0 ? _cap(uint256(d), a.amount) : 0;
                if (amt > 0) manager.take(_quoteCurrency(), a.who, amt);
            } else if (a.kind == Kind.SellPctFrom) {
                uint256 amt = boss.balanceOf(a.who) * a.amount / 100;
                if (amt > 0) {
                    manager.swap(key, SwapParams(bossIs0, -int256(amt), _limit(bossIs0)), "");
                    manager.sync(bossC);
                    boss.transferFrom(a.who, address(manager), amt);
                    manager.settle();
                }
            } else if (a.kind == Kind.DepositPctFrom) {
                uint256 amt = boss.balanceOf(a.who) * a.amount / 100;
                if (amt > 0) {
                    manager.sync(bossC);
                    boss.transferFrom(a.who, address(manager), amt);
                    manager.settle();
                    manager.mint(address(this), bossId, amt);
                }
            }
        }
        _settleUp(bossC);
        _settleUp(_quoteCurrency());
        return "";
    }

    // ------------------------------------------------------------------ internals

    function _settleUp(Currency c) internal {
        int256 d = manager.currencyDelta(address(this), c);
        if (d < 0) {
            manager.sync(c);
            if (Currency.unwrap(c) == address(boss)) boss.transfer(address(manager), uint256(-d));
            else imd.transfer(address(manager), uint256(-d));
            manager.settle();
        } else if (d > 0) {
            manager.take(c, address(this), uint256(d));
        }
    }

    function _owedBoss() internal view returns (uint256) {
        int256 d = manager.currencyDelta(address(this), _bossCurrency());
        return d > 0 ? uint256(d) : 0;
    }

    function _cap(uint256 available, uint256 wanted) internal pure returns (uint256) {
        return wanted < available ? wanted : available;
    }

    function _bossCurrency() internal view returns (Currency) {
        return bossIs0 ? key.currency0 : key.currency1;
    }

    function _quoteCurrency() internal view returns (Currency) {
        return bossIs0 ? key.currency1 : key.currency0;
    }

    function _limit(bool z) internal pure returns (uint160) {
        return z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
}
