// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReviewBase} from "./review/ReviewBase.sol";
import {ScriptRouter} from "./utils/ScriptRouter.sol";
import {R7Router} from "./review7/R7Router.sol";
import {BossToken} from "../src/BossToken.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @dev The judge's fee-then-exact router: buys to itself, pays `bips` of its balance to `feeTo`, then
/// sends the user exactly the output minus the fee (no sweep).
contract FeeExactRouter is R7Router {
    constructor(IPoolManager manager_, PoolKey memory key_, BossToken boss_) R7Router(manager_, key_, boss_) {}

    function buyFeeThenExact(uint256 quoteIn, address user, address feeTo, uint256 bips) external {
        uint256 got = _buySelf(quoteIn);
        uint256 fee = boss.balanceOf(address(this)) * bips / 10_000;
        if (fee > 0) boss.transfer(feeTo, fee);
        uint256 out = got * (10_000 - bips) / 10_000;
        if (out > 0) boss.transfer(user, out);
    }
}

/// @dev A contract the launcher can be tricked into calling between the token and the hook deploys.
contract Phish {
    function claimAirdrop(BossToken t) external {
        t.bindHook();
    }

    function onBossTransfer(address, address, uint256) external pure {
        revert("blocked");
    }
}

contract TokenMaker {
    function make() external returns (BossToken) {
        return new BossToken();
    }
}

/// @notice The fifth swarm audit of HitTheBossApp/boss@5acf4b4 (job 965a5fce): one test per finding fixed
/// in code, written from the judge's reproductions. Each one failed on 5acf4b4 before the fix.
contract BossAudit5Test is ReviewBase {
    address internal eve = makeAddr("eve");
    FeeExactRouter internal fx;

    function setUp() public override {
        super.setUp();
        fx = new FeeExactRouter(IPoolManager(address(manager)), key, boss);
        quoteToken.mint(address(fx), 1 ether);
    }

    // ------------------------------------------------------------------ medium 1: fee, then exact delivery, with a plant

    /// Judge's repro: alice leaves 0.01 of HP; eve plants 300 times the blow on the router; carol kills
    /// through it, which pays 1% of its balance as a fee and then exactly 99% of the output to carol.
    function test_M1_feeThenExactDelivery_withAPlant_prizeNeverGoesToTheFeeWallet() public {
        buyExactIn(alice, 0.99 ether);
        uint256 snap = vm.snapshotState();
        vm.prank(carol, carol);
        fx.buyFeeThenExact(0.02 ether, carol, feeCollector, 100);
        uint256 blow = boss.balanceOf(carol) * 10_000 / 9_900;
        vm.revertToState(snap);

        giveBoss(eve, blow * 300);
        vm.prank(eve);
        boss.transfer(address(fx), blow * 300);
        vm.prank(carol, carol);
        fx.buyFeeThenExact(0.02 ether, carol, feeCollector, 100);

        (address killer,, uint256 prize,,) = hook.results(1);
        assertEq(hook.unclaimedKill(feeCollector), 0, "the fee wallet never takes the prize");
        assertEq(killer, carol, "nobody holds most of the blow: the prize stays with the signer, carol");
        assertEq(hook.unclaimedKill(carol), prize);
        assertAccounting();
    }

    // ------------------------------------------------------------------ low 2: only a hook under construction binds

    function test_L2_launcherPhishedBetweenDeploys_cannotBindAnotherContract() public {
        address launcher = makeAddr("launcher");
        TokenMaker maker = new TokenMaker();
        vm.prank(launcher, launcher);
        BossToken t = maker.make();
        Phish phish = new Phish();
        vm.prank(launcher, launcher);
        vm.expectRevert(BossToken.NotAHookUnderConstruction.selector);
        phish.claimAirdrop(t);
        assertEq(t.hook(), address(0), "nothing bound: the real hook can still bind");
    }

    function test_L2_theLauncherItselfCannotBind() public {
        address launcher = makeAddr("launcher");
        TokenMaker maker = new TokenMaker();
        vm.prank(launcher, launcher);
        BossToken t = maker.make();
        vm.prank(launcher, launcher);
        vm.expectRevert(BossToken.NotAHookUnderConstruction.selector);
        t.bindHook();
    }

    // ------------------------------------------------------------------ low 3: a capped buy does not pad `bought`

    /// Judge's repro: in one transaction a heal of credit-free BOSS, then a buy whose credit the cap cuts to
    /// zero. Its BOSS must not count in `bought`, so a later sell of a full later buy forfeits all of it.
    function test_L3_cappedBuy_doesNotPadTheForfeitDenominator() public {
        buyExactIn(carol, 0.6 ether);
        giveBoss(bob, 400_000 ether);
        ScriptRouter.Action[][] memory s = new ScriptRouter.Action[][](2);
        s[0] = new ScriptRouter.Action[](2);
        s[0][0] = script.pullFrom(bob, address(script), 400_000 ether);
        s[0][1] = script.sellOwn(400_000 ether);
        s[1] = new ScriptRouter.Action[](2);
        s[1][0] = script.buy(0.3 ether);
        s[1][1] = script.takeBoss(alice, type(uint256).max);
        vm.prank(alice, alice);
        script.runMany(s);
        assertEq(hook.damage(1, alice), 0, "the cap cut that buy's credit to zero");
        assertEq(hook.bought(1, alice), 0, "and its BOSS carries no forfeit weight");

        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.2 ether)));
        assertGt(hook.damage(1, alice), 0);
        sellExactIn(alice, got);
        assertEq(hook.damage(1, alice), 0, "selling all of a buy loses all of its credit");
        assertAccounting();
    }
}
