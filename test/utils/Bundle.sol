// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Several parties' calls run back to back in ONE transaction, the way an ERC-4337 bundler
/// or a relayer multicall packs them: tx.origin is whoever sends the bundle, not the players.
contract Bundle {
    function run(address[] calldata targets, bytes[] calldata calls) external {
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

/// @notice A player's smart account: it buys through a stock router (PoolSwapTest) with its own
/// IMD and receives the BOSS itself. No code the bundler controls touches its swap.
contract SmartAccount {
    PoolSwapTest internal immutable router;

    constructor(PoolSwapTest router_, MockERC20 imd) {
        router = router_;
        imd.approve(address(router_), type(uint256).max);
    }

    function buy(PoolKey calldata key, bool bossIs0, uint256 quoteIn) external {
        bool z = !bossIs0;
        uint160 limit = z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        router.swap(key, SwapParams(z, -int256(quoteIn), limit), PoolSwapTest.TestSettings(false, false), "");
    }
}
