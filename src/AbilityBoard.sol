// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAbilityBoard} from "./interfaces/IAbility.sol";

/// @title AbilityBoard
/// @notice Holds the one ability proposal the IMD oracle panel is asked about. The keeper posts
/// the contract the swarm wrote; nothing here activates it. BossHook only queues a proposal that
/// carries a valid oracle signature, then waits 12 hours.
/// @dev Separate from the hook on purpose: the oracle question reads `pending()` at this address,
/// and the hook pins that question's hash. If the hook held the proposal, its own address would
/// depend on a hash that depends on its address.
contract AbilityBoard is IAbilityBoard {
    address public immutable keeper;

    uint256 public id;
    address public ability;
    uint64 public proposedAt;

    event Proposed(uint256 indexed id, address indexed ability, string note);

    error NotKeeper();
    error NoCode();
    error ZeroAddress();

    constructor(address keeper_) {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
    }

    function propose(address ability_, string calldata note) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (ability_.code.length == 0) revert NoCode();
        unchecked {
            ++id;
        }
        ability = ability_;
        proposedAt = uint64(block.timestamp);
        emit Proposed(id, ability_, note);
    }

    function pending() external view returns (uint256, address) {
        return (id, ability);
    }
}
