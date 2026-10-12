// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BossFixture} from "../utils/BossFixture.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {BossHook} from "../../src/BossHook.sol";
import {BossToken} from "../../src/BossToken.sol";

/// @dev A factory that deploys the token: the token's supply lands on the factory, which forwards it.
/// `msg.sender` of the token's constructor is the factory; `tx.origin` is whoever called the factory.
contract TokenFactory {
    function deploy() external returns (BossToken t) {
        t = new BossToken();
        t.transfer(msg.sender, t.balanceOf(address(this)));
    }
}

/// @dev Deploys arbitrary init code with CREATE2 so the test can choose the signer with vm.prank.
contract HookDeployer {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address addr) {
        assembly ("memory-safe") {
            addr := create2(0, add(initCode, 32), mload(initCode), salt)
        }
    }
}

/// @dev A contract that binds itself to the token if the launcher can be made to call it: afterwards it
/// decides which transfers go through.
contract EvilHook {
    bool public blockAll;

    function bind(BossToken t) external {
        t.bindHook();
    }

    function setBlock(bool v) external {
        blockAll = v;
    }

    function onBossTransfer(address, address, uint256) external view {
        if (blockAll) revert("blocked");
    }
}

/// @notice Review probes for the token-hook binding and for the hook's transfer handler before the pool exists.
contract ReviewBindingTest is BossFixture {
    address internal launcher = makeAddr("launcher");
    address internal stranger = makeAddr("stranger");
    HookDeployer internal deployer;

    function setUp() public override {
        super.setUp();
        deployer = new HookDeployer();
    }

    function _hookInit(address token) internal view returns (bytes memory initCode, bytes32 salt) {
        initCode = abi.encodePacked(type(BossHook).creationCode, hookArgsFor(token, INITIAL_HP + 7, pairedAddr));
        (salt,) = HookFlags.mineSalt(address(deployer), initCode, HOOK_FLAGS, 300_000);
    }

    /// @dev Token deployed through a factory by the launcher's EOA, hook deployed by the same EOA in a later
    /// transaction: binds. The same hook deployed by anyone else: reverts (create2 returns zero).
    function test_probeE1_factoryToken_bindsOnlyFromTheLaunchersSigner() public {
        TokenFactory factory = new TokenFactory();
        vm.prank(launcher, launcher);
        BossToken token = factory.deploy();
        assertEq(token.balanceOf(launcher), token.TOTAL_SUPPLY());
        (bytes memory initCode, bytes32 salt) = _hookInit(address(token));

        vm.prank(stranger, stranger);
        address bad = deployer.deploy(initCode, salt);
        assertEq(bad, address(0), "a stranger's hook deploy reverts in the constructor (NotLaunchOrigin)");
        assertEq(token.hook(), address(0));

        vm.prank(launcher, launcher);
        address good = deployer.deploy(initCode, salt);
        assertTrue(good != address(0), "the launcher's signer binds");
        assertEq(token.hook(), good);
    }

    function test_probeE2_strangerCannotBindAContractOfTheirOwn() public {
        TokenFactory factory = new TokenFactory();
        vm.prank(launcher, launcher);
        BossToken token = factory.deploy(); // deployed, not yet bound: the window between the two deploys
        EvilHook evil = new EvilHook();
        vm.prank(stranger, stranger);
        vm.expectRevert(BossToken.NotLaunchOrigin.selector);
        evil.bind(token);
        assertEq(token.hook(), address(0));
    }

    /// @dev The launch window risk: if the launcher's EOA signs any transaction that reaches `bindHook`
    /// between the token deploy and the hook deploy (a phished call), the token is bound to that contract,
    /// the real hook deploy reverts (loudly) and the bound contract can block every transfer of the token.
    function test_probeE3_launcherPhishedBetweenDeploys_tokenBoundToEvilHook_realHookReverts() public {
        TokenFactory factory = new TokenFactory();
        vm.prank(launcher, launcher);
        BossToken token = factory.deploy();
        EvilHook evil = new EvilHook();
        vm.prank(launcher, launcher);
        evil.bind(token); // the launcher is tricked into one call
        assertEq(token.hook(), address(evil));

        (bytes memory initCode, bytes32 salt) = _hookInit(address(token));
        vm.prank(launcher, launcher);
        address real = deployer.deploy(initCode, salt);
        assertEq(real, address(0), "the real hook cannot bind any more: loud failure");

        evil.setBlock(true);
        vm.prank(launcher);
        vm.expectRevert("blocked");
        token.transfer(alice, 1 ether);
    }

    /// @dev Hook bound, pool not initialized (round 0): every transfer shape goes through and records nothing.
    function test_probeF_transfersBeforePoolInit_roundZero_neverRevert() public {
        BossToken fresh = _deployBossOrdered(pairedAddr, true);
        BossHook h = deployHookWith(hookArgsFor(address(fresh), INITIAL_HP + 3, pairedAddr));
        assertEq(fresh.hook(), address(h));
        assertEq(h.round(), 0);
        assertFalse(h.poolInitialized());

        fresh.transfer(alice, 10 ether); // the launch distribution
        fresh.transfer(address(manager), 1 ether); // BOSS parked in the PoolManager
        fresh.transfer(address(h), 1 ether); // BOSS sent to the hook
        fresh.transfer(address(this), 1 ether); // from == to
        fresh.transfer(alice, 0); // zero
        vm.prank(alice);
        fresh.transfer(bob, 5 ether);
        vm.prank(bob);
        fresh.approve(carol, type(uint256).max);
        vm.prank(carol);
        fresh.transferFrom(bob, alice, 5 ether);
        assertEq(h.damage(0, alice) + h.damage(0, bob) + h.eligibleDamage(0), 0);
        assertEq(h.bought(0, alice) + h.bought(0, bob), 0);
        assertEq(fresh.balanceOf(alice), 10 ether);
    }
}
