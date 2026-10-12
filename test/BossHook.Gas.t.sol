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
}
