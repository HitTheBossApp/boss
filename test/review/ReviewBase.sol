// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BossFixture} from "../utils/BossFixture.sol";
import {ScriptRouter} from "../utils/ScriptRouter.sol";
import {ReviewRouter} from "./ReviewRouter.sol";
import {BossHook} from "../../src/BossHook.sol";
import {BossToken} from "../../src/BossToken.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Shared setup and helpers of the independent review probes (commit 14d002a).
abstract contract ReviewBase is BossFixture {
    address internal relayer = makeAddr("relayer");
    address internal feeCollector = makeAddr("feeCollector");
    address internal venue = makeAddr("venue"); // a v3 pool, a CEX hot wallet: any non-PoolManager contract
    ScriptRouter internal script;
    ReviewRouter internal rr;
    uint256 internal constant RR_LIQ = 1e21; // about 630k BOSS in the position: more than a 0.5 IMD buy yields

    function setUp() public virtual override {
        super.setUp();
        script = new ScriptRouter(IPoolManager(address(manager)), hook, key, bossIsCurrency0, boss, quoteToken);
        quoteToken.mint(address(script), 100 ether);

        (int24 lower, int24 upper) = _seedRange();
        rr = new ReviewRouter(
            IPoolManager(address(manager)), hook, key, bossIsCurrency0, boss, quoteToken, lower, upper
        );
        quoteToken.mint(address(rr), 100 ether);
        giveBoss(address(rr), 1_000_000 ether); // BOSS from the fixture's supply: never bought, no credit
        // The router holds an LP position next to the launch one (BOSS only, price below the range).
        ReviewRouter.Action[] memory a = new ReviewRouter.Action[](1);
        a[0] = rr.addLiquidity(RR_LIQ);
        rr.unlockWith(a);
        // Players approve the review router, as they would approve Permit2 / a router.
        _approveRouter(alice);
        _approveRouter(bob);
        _approveRouter(carol);
    }

    function _approveRouter(address who) internal {
        vm.prank(who);
        boss.approve(address(rr), type(uint256).max);
        vm.prank(who);
        boss.approve(address(script), type(uint256).max);
    }

    function _seedRange() internal view returns (int24 lower, int24 upper) {
        int24 tick = launchTick();
        if (bossIsCurrency0) {
            lower = tick + TICK_SPACING;
            upper = TickMath.maxUsableTick(TICK_SPACING);
        } else {
            lower = TickMath.minUsableTick(TICK_SPACING);
            upper = tick - TICK_SPACING;
        }
    }

    function _enc(bytes memory call) internal pure returns (bytes memory) {
        return call;
    }

    function _knownWallets() internal view returns (address[] memory w) {
        w = new address[](9);
        w[0] = alice;
        w[1] = bob;
        w[2] = carol;
        w[3] = relayer;
        w[4] = feeCollector;
        w[5] = venue;
        w[6] = address(script);
        w[7] = address(rr);
        w[8] = address(hook);
    }

    function _sumDamage(uint64 r) internal view returns (uint256 sum) {
        address[] memory w = _knownWallets();
        for (uint256 i = 0; i < w.length; i++) {
            sum += hook.damage(r, w[i]);
        }
    }

    function _sumClaimable(uint64 r) internal view returns (uint256 sum) {
        address[] memory w = _knownWallets();
        for (uint256 i = 0; i < w.length; i++) {
            sum += hook.claimableDamage(r, w[i]);
        }
    }

    /// @dev Claims everything claimable for every known wallet, in separate transactions, and
    /// returns what was actually paid out (kill prizes + damage pools of closed rounds).
    function _claimEverything() internal returns (uint256 paid) {
        address[] memory w = _knownWallets();
        for (uint256 i = 0; i < w.length; i++) {
            if (hook.unclaimedKill(w[i]) > 0) {
                uint256 before = _quoteBalance(w[i]);
                hook.claimKill(w[i]);
                paid += _quoteBalance(w[i]) - before;
            }
            for (uint64 r = 1; r < hook.round(); r++) {
                if (hook.claimableDamage(r, w[i]) > 0) {
                    uint256 before = _quoteBalance(w[i]);
                    hook.claimDamage(r, w[i]);
                    paid += _quoteBalance(w[i]) - before;
                }
            }
        }
    }

    function _assertOpenRoundSums() internal view {
        uint64 r = hook.round();
        assertEq(_sumDamage(r), hook.eligibleDamage(r), "open round: eligible == sum of damage held");
        for (uint64 c = 1; c < r; c++) {
            (,,,, uint256 elig) = hook.results(c);
            assertEq(_sumDamage(c), elig, "closed round: snapshot == sum of damage held");
        }
    }
}
