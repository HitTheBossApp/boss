// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {BossHook} from "../../src/BossHook.sol";
import {BossToken} from "../../src/BossToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice A test router that runs a small script inside one PoolManager unlock: buys paid with
/// its own IMD, and BOSS taken to any wallet, split, kept as ERC-6909 claims, deposited as claims
/// or turned back into BOSS. Whatever is left owed or owed to it at the end is settled from and to
/// its own balances. It separates the signer (tx.origin), the locker (this contract) and the
/// wallet that actually receives or gives BOSS, which is what the follow-the-BOSS rule is about.
contract ScriptRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    enum Kind {
        Buy,
        TakeBoss,
        TakeBossShare,
        TakeBossAsClaims,
        DepositAsClaims,
        ClaimsToBoss,
        Forward,
        ForwardShare,
        ForwardAllBut,
        SellOwn,
        PullFrom
    }

    struct Action {
        Kind kind;
        address who;
        uint256 amount;
        uint256 num;
        uint256 den;
    }

    IPoolManager internal immutable manager;
    BossHook internal immutable hook;
    BossToken internal immutable boss;
    MockERC20 internal immutable imd;
    bool internal immutable bossIs0;
    PoolKey internal key;

    constructor(
        IPoolManager manager_,
        BossHook hook_,
        PoolKey memory key_,
        bool bossIs0_,
        BossToken boss_,
        MockERC20 imd_
    ) {
        manager = manager_;
        hook = hook_;
        key = key_;
        bossIs0 = bossIs0_;
        boss = boss_;
        imd = imd_;
    }

    // ------------------------------------------------------------------ script builders

    /// @dev Exact-input buy of `quoteIn` IMD, paid by this contract.
    function buy(uint256 quoteIn) external pure returns (Action memory) {
        return Action(Kind.Buy, address(0), quoteIn, 0, 0);
    }

    /// @dev Takes up to `amount` of the BOSS this contract is owed to `to` (max = all of it).
    function takeBoss(address to, uint256 amount) external pure returns (Action memory) {
        return Action(Kind.TakeBoss, to, amount, 0, 0);
    }

    /// @dev Takes `num / den` of the BOSS this contract is owed to `to`.
    function takeBossShare(address to, uint256 num, uint256 den) external pure returns (Action memory) {
        return Action(Kind.TakeBossShare, to, 0, num, den);
    }

    /// @dev Keeps up to `amount` of the BOSS owed as ERC-6909 claims held by this contract.
    function takeBossAsClaims(uint256 amount) external pure returns (Action memory) {
        return Action(Kind.TakeBossAsClaims, address(0), amount, 0, 0);
    }

    /// @dev Moves `amount` BOSS from `payer` (who approved this contract) into the PoolManager as claims.
    function depositAsClaims(address payer, uint256 amount) external pure returns (Action memory) {
        return Action(Kind.DepositAsClaims, payer, amount, 0, 0);
    }

    /// @dev Burns up to `amount` of this contract's BOSS claims and takes the BOSS to `to`.
    function claimsToBoss(address to, uint256 amount) external pure returns (Action memory) {
        return Action(Kind.ClaimsToBoss, to, amount, 0, 0);
    }

    /// @dev A second hop: this contract transfers up to `amount` of the BOSS it holds to `to` (the
    /// Universal Router's custody-then-SWEEP shape, an aggregator, a solver delivering a fill).
    function forward(address to, uint256 amount) external pure returns (Action memory) {
        return Action(Kind.Forward, to, amount, 0, 0);
    }

    /// @dev Transfers `num / den` of the BOSS this contract holds to `to` (an interface fee, say).
    function forwardShare(address to, uint256 num, uint256 den) external pure returns (Action memory) {
        return Action(Kind.ForwardShare, to, 0, num, den);
    }

    /// @dev Transfers all the BOSS this contract holds but `keep` wei to `to`.
    function forwardAllBut(address to, uint256 keep) external pure returns (Action memory) {
        return Action(Kind.ForwardAllBut, to, keep, 0, 0);
    }

    /// @dev Exact-input sell of `bossAmount` paid from the BOSS this contract holds.
    function sellOwn(uint256 bossAmount) external pure returns (Action memory) {
        return Action(Kind.SellOwn, address(0), bossAmount, 0, 0);
    }

    /// @dev Moves up to `amount` BOSS from `payer` (who approved this contract) to `to`: a wallet's
    /// own transfer in the middle of the script.
    function pullFrom(address payer, address to, uint256 amount) external pure returns (Action memory) {
        return Action(Kind.PullFrom, payer, amount, uint256(uint160(to)), 0);
    }

    // ------------------------------------------------------------------ running

    function run(Action[] calldata actions) external {
        manager.unlock(abi.encode(actions));
    }

    /// @dev Two unlocks in one transaction with a claim in between (claims can't run inside an
    /// unlock): `claimKind` 1 = claimDamage(1, who), 2 = claimKill(who), 0 = none. Tests what the
    /// same transaction may and may not move afterwards.
    function runSequence(Action[] calldata first, uint8 claimKind, address who, Action[] calldata second) external {
        manager.unlock(abi.encode(first));
        if (claimKind == 1) hook.claimDamage(1, who);
        else if (claimKind == 2) hook.claimKill(who);
        manager.unlock(abi.encode(second));
    }

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
            } else if (a.kind == Kind.TakeBoss) {
                manager.take(bossC, a.who, _cap(_owedBoss(), a.amount));
            } else if (a.kind == Kind.TakeBossShare) {
                manager.take(bossC, a.who, _owedBoss() * a.num / a.den);
            } else if (a.kind == Kind.TakeBossAsClaims) {
                manager.mint(address(this), bossId, _cap(_owedBoss(), a.amount));
            } else if (a.kind == Kind.DepositAsClaims) {
                manager.sync(bossC);
                boss.transferFrom(a.who, address(manager), a.amount);
                manager.settle();
                manager.mint(address(this), bossId, a.amount);
            } else if (a.kind == Kind.ClaimsToBoss) {
                uint256 amt = _cap(manager.balanceOf(address(this), bossId), a.amount);
                manager.burn(address(this), bossId, amt);
                manager.take(bossC, a.who, amt);
            } else if (a.kind == Kind.Forward) {
                boss.transfer(a.who, _cap(boss.balanceOf(address(this)), a.amount));
            } else if (a.kind == Kind.ForwardShare) {
                boss.transfer(a.who, boss.balanceOf(address(this)) * a.num / a.den);
            } else if (a.kind == Kind.ForwardAllBut) {
                boss.transfer(a.who, boss.balanceOf(address(this)) - a.amount);
            } else if (a.kind == Kind.SellOwn) {
                manager.swap(key, SwapParams(bossIs0, -int256(a.amount), _limit(bossIs0)), "");
            } else if (a.kind == Kind.PullFrom) {
                boss.transferFrom(a.who, address(uint160(a.num)), _cap(boss.balanceOf(a.who), a.amount));
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
        require(d > 0, "no BOSS owed");
        return uint256(d);
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
