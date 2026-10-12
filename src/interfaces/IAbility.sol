// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice What the hook tells an ability about the trade being scored. Read-only data: an
/// ability receives no address with authority and is called with STATICCALL.
struct SwapInfo {
    address trader;
    bool isBuy;
    /// @dev Gross amount of the paired currency moved by the trade, fee included.
    uint256 amount;
    uint256 timestamp;
    uint64 round;
    uint256 hp;
    uint256 maxHp;
    uint256 pot;
}

/// @notice The boss's ability of the day, written by the IMD swarm. It only returns numbers:
/// how much a buy hits and how much a sell heals, in bps (10_000 = 1x). The hook clamps both
/// to [0.25x, 4x] and falls back to 1x if the call fails.
interface IAbility {
    function modifiers(SwapInfo calldata s) external view returns (uint256 buyMultBps, uint256 sellMultBps);
    function name() external view returns (string memory);
}

/// @notice Where the keeper posts the swarm's ability for the oracle panel to read.
interface IAbilityBoard {
    function keeper() external view returns (address);
    function pending() external view returns (uint256 id, address ability);
    function proposedAt() external view returns (uint64);
}
