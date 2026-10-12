// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Hook permission bits as encoded in a Uniswap v4 hook address, plus the helpers a
/// deployer needs to find a CREATE2 salt that lands a hook on a matching address.
/// @dev Mirrors `Hooks.sol` in v4-core. Kept dependency-free so scripts and external tooling can
/// import it without pulling the whole core library.
library HookFlags {
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = 1 << 8;
    uint160 internal constant BEFORE_SWAP = 1 << 7;
    uint160 internal constant AFTER_SWAP = 1 << 6;
    uint160 internal constant BEFORE_DONATE = 1 << 5;
    uint160 internal constant AFTER_DONATE = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = 1 << 0;

    /// @notice Mask covering all fourteen permission bits.
    uint160 internal constant ALL = (1 << 14) - 1;

    /// @notice The permission bits carried by `hook`.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice True when `hook` carries exactly the permission bits in `flags` (other bits ignored).
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }

    /// @notice Address CREATE2 would give `deployer` for `initCodeHash` and `salt`.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice Finds a salt such that `deployer` deploying `initCode` with CREATE2 lands on an
    /// address carrying exactly `flags`. Reverts if none is found within `maxIterations`.
    /// @dev Expected work is 2^14 hashes. Deterministic: the same inputs give the same salt.
    function mineSalt(address deployer, bytes memory initCode, uint160 flags, uint256 maxIterations)
        internal
        pure
        returns (bytes32 salt, address hook)
    {
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(i);
            hook = computeAddress(deployer, salt, initCodeHash);
            if (matches(hook, flags)) return (salt, hook);
        }
        revert("HookFlags: no salt found");
    }
}
