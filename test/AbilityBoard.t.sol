// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AbilityBoard} from "../src/AbilityBoard.sol";
import {FixedAbility} from "./mocks/Abilities.sol";

contract AbilityBoardTest is Test {
    address keeper = makeAddr("keeper");
    AbilityBoard board;
    FixedAbility ability;

    function setUp() public {
        board = new AbilityBoard(keeper);
        ability = new FixedAbility(5_000, 10_000);
    }

    function test_keeperProposes() public {
        vm.warp(1_800_000_000);
        vm.prank(keeper);
        board.propose(address(ability), "whales hit half");
        (uint256 id, address a) = board.pending();
        assertEq(id, 1);
        assertEq(a, address(ability));
        assertEq(board.proposedAt(), 1_800_000_000);
    }

    function test_strangerCannotPropose() public {
        vm.expectRevert(AbilityBoard.NotKeeper.selector);
        board.propose(address(ability), "x");
    }

    function test_proposalNeedsCode() public {
        vm.prank(keeper);
        vm.expectRevert(AbilityBoard.NoCode.selector);
        board.propose(makeAddr("eoa"), "x");
    }

    function test_newProposalReplacesAndBumpsId() public {
        FixedAbility other = new FixedAbility(10_000, 20_000);
        vm.startPrank(keeper);
        board.propose(address(ability), "a");
        board.propose(address(other), "b");
        vm.stopPrank();
        (uint256 id, address a) = board.pending();
        assertEq(id, 2);
        assertEq(a, address(other));
    }

    function test_zeroKeeperRejected() public {
        vm.expectRevert(AbilityBoard.ZeroAddress.selector);
        new AbilityBoard(address(0));
    }
}
