// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BossToken} from "../../src/BossToken.sol";
import {R3Router} from "../review3/R3Router.sol";
import {R5Router, IERC20Lite} from "../review5/R5Router.sol";

/// @notice Seventh-review router: R5Router (every swap shape, takes, claims, `multi`, `pull`, `forward`) plus
/// the payout shapes of a custodian that executed the swap (the locker):
/// - `payPortion` / `sweepBoss`: the Universal Router's PAY_PORTION (bips of its BOSS balance) and SWEEP;
/// - `buyDeliverExact`: takes the output to itself and transfers exactly the swap's output (balance diff);
/// - `buyDeliverQuoted`: delivers `bps` of the output to the user (the quoted amount) and sweeps everything
///   else it holds to `surplusTo` (positive slippage kept by the protocol);
/// - `sweep`: a public sweep of any token or ETH, like the Universal Router's SWEEP command.
contract R7Router is R5Router {
    constructor(IPoolManager manager_, PoolKey memory key_, BossToken boss_) R5Router(manager_, key_, boss_) {}

    function payPortion(address to, uint256 bips) external {
        uint256 amt = boss.balanceOf(address(this)) * bips / 10_000;
        if (amt > 0) boss.transfer(to, amt);
    }

    function sweepBoss(address to) external {
        uint256 bal = boss.balanceOf(address(this));
        if (bal > 0) boss.transfer(to, bal);
    }

    function sweepBossBut(address to, uint256 keep) external {
        uint256 bal = boss.balanceOf(address(this));
        if (bal > keep) boss.transfer(to, bal - keep);
    }

    function sweep(address token, address to) external {
        if (token == address(0)) {
            (bool ok,) = to.call{value: address(this).balance}("");
            require(ok, "eth");
        } else {
            IERC20Lite(token).transfer(to, IERC20Lite(token).balanceOf(address(this)));
        }
    }

    function _buySelf(uint256 quoteIn) internal returns (uint256 got) {
        R3Router.Action[] memory s = new R3Router.Action[](2);
        s[0] = R3Router.Action(R3Router.Kind.BuyIn, address(0), quoteIn, 0, 0);
        s[1] = R3Router.Action(R3Router.Kind.TakeBoss, address(this), type(uint256).max, 0, 0);
        uint256 before = boss.balanceOf(address(this));
        manager.unlock(abi.encode(s));
        got = boss.balanceOf(address(this)) - before;
    }

    function buyDeliverExact(uint256 quoteIn, address user) external {
        uint256 got = _buySelf(quoteIn);
        if (got > 0) boss.transfer(user, got);
    }

    function buyDeliverQuoted(uint256 quoteIn, address user, uint256 bps, address surplusTo) external {
        uint256 got = _buySelf(quoteIn);
        uint256 quoted = got * bps / 10_000;
        if (quoted > 0) boss.transfer(user, quoted);
        uint256 rest = boss.balanceOf(address(this));
        if (rest > 0) boss.transfer(surplusTo, rest);
    }
}

/// @notice A non-locker fee wrapper: has a router (the locker) buy with the output sent to itself, pays
/// `bips` of its BOSS balance to `feeTo` (PAY_PORTION) and sweeps the rest to `user`.
contract FeeWrapper {
    BossToken public immutable boss;

    constructor(BossToken boss_) {
        boss = boss_;
    }

    function route(R3Router router, R3Router.Action[] calldata actions, address feeTo, uint256 bips, address user)
        external
    {
        router.run(actions);
        uint256 fee = boss.balanceOf(address(this)) * bips / 10_000;
        if (fee > 0) boss.transfer(feeTo, fee);
        uint256 rest = boss.balanceOf(address(this));
        if (rest > 0) boss.transfer(user, rest);
    }
}
