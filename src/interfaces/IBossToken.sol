// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice What BossHook needs from the BOSS token: to be bound as its hook at deploy time, and a
/// wallet's balance (read after a transfer, to tell the killing blow's BOSS from older BOSS).
interface IBossToken {
    function bindHook() external;
    function hook() external view returns (address);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice What the BOSS token tells its hook: every transfer, after the balances moved.
interface IBossTransferHook {
    function onBossTransfer(address from, address to, uint256 value) external;
}
