// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BossMath} from "../src/libraries/BossMath.sol";

contract BossMathTest is Test {
    function test_clampMult_bounds() public pure {
        assertEq(BossMath.clampMult(0), 2_500);
        assertEq(BossMath.clampMult(2_499), 2_500);
        assertEq(BossMath.clampMult(10_000), 10_000);
        assertEq(BossMath.clampMult(40_001), 40_000);
        assertEq(BossMath.clampMult(type(uint256).max), 40_000);
    }

    function test_scale() public pure {
        assertEq(BossMath.scale(1 ether, 10_000), 1 ether);
        assertEq(BossMath.scale(1 ether, 5_000), 0.5 ether);
        assertEq(BossMath.scale(1 ether, 40_000), 4 ether);
    }

    function test_nextMaxHp_fastKillGrows() public pure {
        assertEq(BossMath.nextMaxHp(10 ether, 12 hours, 10 ether), 15 ether);
    }

    function test_nextMaxHp_slowKillShrinks() public pure {
        assertEq(BossMath.nextMaxHp(10 ether, 4 days, 10 ether), 7.5 ether);
    }

    function test_nextMaxHp_normalKillKeeps() public pure {
        assertEq(BossMath.nextMaxHp(10 ether, 2 days, 10 ether), 10 ether);
        assertEq(BossMath.nextMaxHp(10 ether, 1 days, 10 ether), 10 ether, "exactly one day is not fast");
        assertEq(BossMath.nextMaxHp(10 ether, 3 days, 10 ether), 10 ether, "exactly three days is not slow");
    }

    function test_nextMaxHp_clamped() public pure {
        assertEq(BossMath.nextMaxHp(160 ether, 1 hours, 10 ether), 160 ether, "ceiling 16x");
        assertEq(BossMath.nextMaxHp(2.5 ether, 9 days, 10 ether), 2.5 ether, "floor 1/4");
    }

    function test_splitPot_withEligible() public pure {
        (uint256 seed, uint256 killer, uint256 dmg) = BossMath.splitPot(100 ether, true);
        assertEq(seed, 10 ether);
        assertEq(killer, 45 ether);
        assertEq(dmg, 45 ether);
    }

    function test_splitPot_noEligibleRollsIntoSeed() public pure {
        (uint256 seed, uint256 killer, uint256 dmg) = BossMath.splitPot(100 ether, false);
        assertEq(seed, 55 ether);
        assertEq(killer, 45 ether);
        assertEq(dmg, 0);
    }

    function testFuzz_splitPot_conserves(uint256 pot, bool any) public pure {
        pot = bound(pot, 0, 1e30);
        (uint256 seed, uint256 killer, uint256 dmg) = BossMath.splitPot(pot, any);
        assertEq(seed + killer + dmg, pot);
    }

    function test_share() public pure {
        assertEq(BossMath.share(90 ether, 1, 3), 30 ether);
        assertEq(BossMath.share(90 ether, 0, 3), 0);
        assertEq(BossMath.share(90 ether, 5, 0), 0, "no total, no share");
    }

    function testFuzz_share_neverExceedsPool(uint256 pool, uint256 a, uint256 b) public pure {
        pool = bound(pool, 0, 1e30);
        a = bound(a, 0, 1e30);
        b = bound(b, 0, 1e30);
        uint256 total = a + b;
        assertLe(BossMath.share(pool, a, total) + BossMath.share(pool, b, total), pool);
    }
}
