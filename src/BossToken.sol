// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBossTransferHook} from "./interfaces/IBossToken.sol";

/// @title BOSS
/// @notice The launch token of BOSS. All game and fee logic lives in BossHook; the token only
/// tells the hook about every transfer, so damage credit can follow the BOSS instead of the
/// transaction signer.
/// @dev Exactly 1,000,000,000 BOSS (10^27 minor units, 18 decimals) are minted once, to the
/// deployer, in the constructor. There is no owner, no mint, no burn-by-admin, no pause, no
/// blocklist, no transfer fee and no upgrade path. The one piece of post-deploy state is the
/// hook, bound once by BossHook's constructor during the launch.
contract BossToken {
    string public constant name = "BOSS";
    string public constant symbol = "BOSS";
    uint8 public constant decimals = 18;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    uint256 public immutable totalSupply;
    /// @dev Signer of the deploy transaction. Only a transaction it signs may bind the hook, so a
    /// stranger cannot bind a contract of their own between the token and the hook deployments.
    /// A deploy-time guard, never an authorization for users.
    address private immutable _launchOrigin;

    /// @notice The BossHook that scores every transfer. Zero until the launch binds it.
    address public hook;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event HookBound(address indexed hook);

    error InsufficientBalance(uint256 available, uint256 required);
    error InsufficientAllowance(uint256 available, uint256 required);
    error TransferToZeroAddress();
    error HookAlreadyBound();
    error NotLaunchOrigin();

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        _launchOrigin = tx.origin;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Binds the caller as the hook, once. Called by BossHook's constructor in the launch
    /// transaction; refused from any other signer and after the first binding.
    function bindHook() external {
        if (hook != address(0)) revert HookAlreadyBound();
        if (tx.origin != _launchOrigin) revert NotLaunchOrigin();
        hook = msg.sender;
        emit HookBound(msg.sender);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance(allowed, value);
            unchecked {
                allowance[from][msg.sender] = allowed - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    /// @dev Balances move first; then the hook hears about it. The hook's handler is bookkeeping
    /// only (no external calls, no revert path), so it cannot block a transfer; if it ever did,
    /// the transfer fails rather than running without the game's accounting.
    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert TransferToZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert InsufficientBalance(fromBalance, value);
        unchecked {
            balanceOf[from] = fromBalance - value;
            // Total supply is fixed, so the sum of balances can never overflow.
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
        address h = hook;
        if (h != address(0)) IBossTransferHook(h).onBossTransfer(from, to, value);
    }
}
