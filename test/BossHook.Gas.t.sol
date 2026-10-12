// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {BossFixture} from "./utils/BossFixture.sol";
import {WhaleNerfAbility} from "./mocks/Abilities.sol";

contract BossGasTest is BossFixture {
    using stdStorage for StdStorage;

    function test_gas_buyAndSell_withAbility() public {
        stdstore.target(address(hook)).sig("activeAbility()").checked_write(address(new WhaleNerfAbility()));
        buyExactIn(bob, 0.05 ether); // warm the pool

        uint256 g = gasleft();
        buyExactIn(alice, 0.1 ether);
        uint256 buyGas = g - gasleft();

        g = gasleft();
        sellExactIn(alice, boss.balanceOf(alice));
        uint256 sellGas = g - gasleft();

        console2.log("buy gas (router included)", buyGas);
        console2.log("sell gas (router included)", sellGas);
        assertLt(buyGas, 450_000, "CLAUS swaps cost ~724k; BOSS must stay below");
        assertLt(sellGas, 450_000);
    }

    /// @dev A plain BOSS transfer now reports to the hook: this is what that costs, with nothing to
    /// move (no credit this round) and with credit travelling to the receiver.
    function test_gas_transfer_withAndWithoutCredit() public {
        giveBoss(carol, 10 ether); // carol never bought: nothing to move
        vm.prank(carol);
        boss.transfer(bob, 1 ether); // warm bob

        uint256 g = gasleft();
        vm.prank(carol);
        boss.transfer(bob, 1 ether);
        uint256 plainGas = g - gasleft();

        buyExactIn(alice, 0.1 ether); // alice holds credit
        g = gasleft();
        vm.prank(alice);
        boss.transfer(bob, boss.balanceOf(alice) / 2);
        uint256 creditGas = g - gasleft();

        console2.log("transfer gas, nothing to move", plainGas);
        console2.log("transfer gas, credit travels", creditGas);
        assertLt(plainGas, 60_000);
        assertLt(creditGas, 120_000);
    }
}
