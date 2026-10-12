// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice What BossHook needs from the BOSS token at deploy time: to be bound as its hook.
interface IBossToken {
    function bindHook() external;
    function hook() external view returns (address);
}

/// @notice What the BOSS token tells its hook: every transfer, after the balances moved.
interface IBossTransferHook {
    function onBossTransfer(address from, address to, uint256 value) external;
}
