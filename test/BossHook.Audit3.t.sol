// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReviewBase} from "./review/ReviewBase.sol";
import {ScriptRouter} from "./utils/ScriptRouter.sol";
import {Bundle} from "./utils/Bundle.sol";
import {BossHook} from "../src/BossHook.sol";
import {OracleGate} from "../src/OracleGate.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract SomeAbility {
    function modifiers(bytes calldata) external pure returns (uint256, uint256) {
        return (10_000, 10_000);
    }
}

/// @notice The third swarm audit of HitTheBossApp/boss@54e917c (job 853ff4df): one test per finding
/// fixed in code, written from the judge's reproductions. Each one failed on 54e917c before the fix.
contract BossAudit3Test is ReviewBase {
    address internal bundlerEOA = makeAddr("bundlerEOA");
    address internal dave = makeAddr("dave");
    ScriptRouter internal script2;
    Bundle internal bundle;

    function setUp() public override {
        super.setUp();
        script2 = new ScriptRouter(IPoolManager(address(manager)), hook, key, bossIsCurrency0, boss, quoteToken);
        quoteToken.mint(address(script2), 100 ether);
        vm.prank(bob);
        boss.approve(address(script2), type(uint256).max);
        bundle = new Bundle();
    }

    function _one(ScriptRouter.Action memory x) internal pure returns (ScriptRouter.Action[] memory a) {
        a = new ScriptRouter.Action[](1);
        a[0] = x;
    }

    function _two(ScriptRouter.Action memory x, ScriptRouter.Action memory y)
        internal
        pure
        returns (ScriptRouter.Action[] memory a)
    {
        a = new ScriptRouter.Action[](2);
        a[0] = x;
        a[1] = y;
    }

    /// @dev One bundle: someone's kill, then bob's operation. Bob bought in round 1 in an earlier transaction.
    function _killThen(ScriptRouter.Action[] memory bobOps) internal {
        address[] memory t = new address[](2);
        bytes[] memory c = new bytes[](2);
        t[0] = address(script);
        c[0] = abi.encodeCall(script.run, (_two(script.buy(2 ether), script.takeBoss(alice, type(uint256).max))));
        t[1] = address(script2);
        c[1] = abi.encodeCall(script2.run, (bobOps));
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(t, c);
        assertEq(hook.round(), 2, "round 1 closed in the bundle");
    }

    // ------------------------------------------------------------------ medium 1: bystanders' closed credit is frozen

    /// Judge's repro: after someone's kill in the same bundle, bob sells half of his BOSS through a
    /// router that custodies it (wallet -> router -> pool). His round-1 credit must not move.
    function test_M1_bystanderSellThroughCustodyAfterAKill_keepsClosedCredit() public {
        buyExactIn(bob, 0.3 ether);
        uint256 half = boss.balanceOf(bob) / 2;
        _killThen(_two(script2.pullFrom(bob, address(script2), half), script2.sellOwn(half)));

        assertEq(hook.damage(1, bob), 0.3 ether, "bob keeps his closed-round credit");
        assertEq(hook.damage(1, address(script2)), 0, "nothing stranded on the router");
        assertEq(hook.claimableDamage(1, address(script2)), 0);
        assertAccounting();
    }

    /// Variant: bob sends half of his BOSS to dave after the kill, in the same bundle.
    function test_M1_bystanderTransferAfterAKill_keepsClosedCredit() public {
        buyExactIn(bob, 0.3 ether);
        uint256 half = boss.balanceOf(bob) / 2;
        _killThen(_one(script2.pullFrom(bob, dave, half)));

        assertEq(hook.damage(1, bob), 0.3 ether, "bob keeps his closed-round credit");
        assertEq(hook.damage(1, dave), 0, "the payee gets none of it");
        assertAccounting();
    }

    // ------------------------------------------------------------------ low 2: the blow leaves last

    /// Judge's repro: the killer holds older BOSS, kills, takes the blow and then sends exactly the
    /// older BOSS away in the same transaction. She still holds every wei of the blow.
    function test_L2_killerSendsOlderBoss_keepsPrizeAndCredit() public {
        giveBoss(carol, 1_000_000 ether); // older BOSS, no credit
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether);
        a[1] = script.takeBoss(carol, type(uint256).max);
        a[2] = script.pullFrom(carol, dave, 1_000_000 ether);
        vm.prank(carol, carol);
        script.run(a);

        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, carol, "the killer keeps the kill");
        assertEq(hook.unclaimedKill(carol), prize);
        assertEq(hook.unclaimedKill(dave), 0, "older BOSS never carries the prize");
        assertEq(hook.damage(1, carol), 1 ether, "nor the killing credit");
        assertEq(hook.damage(1, dave), 0);
    }

    /// The blow still travels when it is what leaves: a router that holds only the blow delivers it.
    function test_L2_routerDeliveringTheBlow_stillMovesIt() public {
        ScriptRouter.Action[] memory a = new ScriptRouter.Action[](3);
        a[0] = script.buy(2 ether);
        a[1] = script.takeBoss(address(script), type(uint256).max);
        a[2] = script.forwardAllBut(dave, 0);
        vm.prank(carol, carol);
        script.run(a);

        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(killer, dave);
        assertEq(hook.unclaimedKill(dave), prize);
        assertEq(hook.damage(1, dave), 1 ether, "the blow's credit travelled with it");
        assertEq(hook.damage(1, address(script)), 0);
    }

    // ------------------------------------------------------------------ low 4: an ability is a contract

    /// Judge's proof: an EIP-7702 delegated EOA (23 bytes of code, 0xef0100 || target) can be
    /// re-pointed after approval. The hook refuses to queue it.
    function test_L4_delegatedEoaIsNotQueuedAsAnAbility() public {
        address target = address(new SomeAbility());
        address eoa = makeAddr("delegated-eoa");
        vm.etch(eoa, abi.encodePacked(hex"ef0100", target));
        assertEq(eoa.code.length, 23);

        vm.prank(keeper);
        board.propose(eoa, "swarm job 123");
        (uint256 id,) = board.pending();
        vm.warp(block.timestamp + 1);
        OracleGate.Attestation memory a = attestation(id * 2 + 1);
        bytes memory sig = signAttestation(a);
        vm.expectRevert(BossHook.AbilityNotAContract.selector);
        hook.acceptAbility(a, sig);
        assertEq(hook.queuedAbility(), address(0), "nothing queued");
    }
}
