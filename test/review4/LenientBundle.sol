// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A bundle whose individual operations may fail (as in an ERC-4337 bundle, where one user
/// operation reverting does not undo the others). Records each failure's revert data.
contract LenientBundle {
    bytes[] internal _failures;

    /// @dev Emitted after each operation. Foundry's recordLogs also keeps the events of a call that
    /// reverted, so a reader must drop the events between two markers when `ok` is false.
    event Step(uint256 indexed i, bool ok);

    function run(address[] calldata targets, bytes[] calldata calls) external returns (uint256 failed) {
        delete _failures;
        for (uint256 i = 0; i < targets.length; i++) {
            (bool ok, bytes memory ret) = targets[i].call(calls[i]);
            if (!ok) {
                _failures.push(ret);
                failed++;
            }
            emit Step(i, ok);
        }
    }

    function failures() external view returns (bytes[] memory) {
        return _failures;
    }
}
