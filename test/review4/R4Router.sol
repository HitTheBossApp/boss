// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BossToken} from "../../src/BossToken.sol";
import {R3Router} from "../review3/R3Router.sol";

/// @notice R3Router plus a measured "spray": the custodian of a killing blow hands equal shares of it to
/// N wallets, one transfer each, the way a batch settlement or a solver delivers a shared fill. Used to
/// measure the cost of `_recount` when every hop leaves the custodian the largest holder.
contract R4Router is R3Router {
    uint256 public lastSprayGas;

    constructor(IPoolManager manager_, PoolKey memory key_, BossToken boss_) R3Router(manager_, key_, boss_) {}

    function sprayMeasured(address[] calldata tos, uint256 each) external {
        uint256 g = gasleft();
        for (uint256 i = 0; i < tos.length; i++) {
            boss.transfer(tos[i], each);
        }
        lastSprayGas = g - gasleft();
    }
}
