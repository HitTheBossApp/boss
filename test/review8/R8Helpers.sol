// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BossHook} from "../../src/BossHook.sol";
import {BossToken} from "../../src/BossToken.sol";
import {IAbilityBoard} from "../../src/interfaces/IAbility.sol";

/// @notice BossHook plus read-only views of its transient kill state, so a step at the end of a transaction
/// can record who holds the killing blow. Behaviour is identical to BossHook (only views are added).
contract BossHookProbe is BossHook {
    constructor(
        IPoolManager manager,
        address token,
        address keeper_,
        IAbilityBoard board_,
        address oracleSigner_,
        bytes32 questionHash_,
        uint256 initialHp_,
        uint24 launchTickAbs_,
        address pairedCurrency_
    ) BossHook(manager, token, keeper_, board_, oracleSigner_, questionHash_, initialHp_, launchTickAbs_, pairedCurrency_) {}

    function probeKill()
        external
        view
        returns (uint256 kr, uint256 total, address locker, uint256 paid, uint256 kb, uint256 kd)
    {
        kr = _tload(T_KILL_ROUND);
        total = _tload(T_KILL_TOTAL);
        locker = address(uint160(_tload(T_KILL_LOCKER)));
        paid = _tload(T_KILL_PAID);
        kb = _tload(T_KILL_BOSS);
        kd = _tload(T_KILL_DAMAGE);
    }

    function probeWallet(uint64 kr, address w) external view returns (uint256 held, uint256 weight, uint256 bd) {
        held = _tload(_heldSlot(kr, w));
        weight = _weight(kr, w);
        bd = _tload(_blowDmgSlot(kr, w));
    }

    function probePending() external view returns (uint256 pd, uint256 pb, uint256 hp0) {
        pd = _tload(T_PEND_DAMAGE);
        pb = _tload(T_PEND_BOSS);
        hp0 = _tload(T_PEND_HP0);
    }
}

/// @notice Called as the last step of a transaction: stores the probe hook's transient kill state.
contract R8Recorder {
    uint64 public kr;
    uint256 public total;
    address public locker;
    uint256 public paid;
    uint256 public pd;
    uint256 public pb;
    mapping(address => uint256) public held;
    mapping(address => uint256) public weight;
    mapping(address => uint256) public blowDmg;

    function record(BossHookProbe h, address[] calldata ws) external {
        uint256 k;
        (k, total, locker, paid,,) = h.probeKill();
        kr = uint64(k);
        (pd, pb,) = h.probePending();
        for (uint256 i = 0; i < ws.length; i++) {
            (held[ws[i]], weight[ws[i]], blowDmg[ws[i]]) = h.probeWallet(kr, ws[i]);
        }
    }
}

/// @notice A contract under construction that binds itself as the token's hook, then (deployed) blocks
/// every transfer.
contract ChildBinder {
    constructor(BossToken t) {
        t.bindHook();
    }

    function onBossTransfer(address, address, uint256) external pure {
        revert("blocked");
    }
}

/// @notice A deployed contract the launcher is tricked into calling between the token and the hook deploys
/// (an airdrop claim, a dapp action). It cannot bind itself any more, so it deploys a child that does.
contract PhishFactory {
    address public child;

    function claimAirdrop(BossToken t) external {
        child = address(new ChildBinder(t));
    }
}

/// @notice The launch shape: one call deploys the token (CREATE2) and then the hook (CREATE2, mined salt), the
/// hook binding from its constructor.
contract LaunchFactory {
    function tokenAddress(bytes32 salt) external view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(type(BossToken).creationCode))
                    )
                )
            )
        );
    }

    function deployToken(bytes32 tokenSalt) public returns (BossToken t) {
        t = new BossToken{salt: tokenSalt}();
    }

    function deployHook(bytes memory hookInitCode, bytes32 hookSalt) public returns (address h) {
        assembly ("memory-safe") {
            h := create2(0, add(hookInitCode, 32), mload(hookInitCode), hookSalt)
        }
        require(h != address(0), "hook deploy failed");
    }

    function launch(bytes32 tokenSalt, bytes calldata hookInitCode, bytes32 hookSalt)
        external
        returns (BossToken t, address h)
    {
        t = deployToken(tokenSalt);
        h = deployHook(hookInitCode, hookSalt);
    }
}

/// @notice An EIP-7702 delegate: lets the EOA batch calls (approve + swap through a router + pay someone).
contract Exec7702 {
    function exec(address[] calldata targets, bytes[] calldata calls) external {
        require(msg.sender == address(this), "self only");
        for (uint256 i = 0; i < targets.length; i++) {
            (bool ok, bytes memory ret) = targets[i].call(calls[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}
