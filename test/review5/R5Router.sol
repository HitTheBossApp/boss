// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BossToken} from "../../src/BossToken.sol";
import {R4Router} from "../review4/R4Router.sol";
import {R3Router} from "../review3/R3Router.sol";

interface IERC20Lite {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice Fifth-review router: R4Router (all swap shapes, takes, claims, `multi`) plus a wallet's own
/// transfer in the middle of a transaction (`pull`, with the wallet's approval), the way Permit2 or a
/// smart account moves BOSS between two unlocks.
contract R5Router is R4Router {
    constructor(IPoolManager manager_, PoolKey memory key_, BossToken boss_) R4Router(manager_, key_, boss_) {}

    /// @dev transferFrom(`from`, `to`, min(amount, balance)). `from` must have approved this router.
    function pull(address from, address to, uint256 amount) external {
        uint256 bal = boss.balanceOf(from);
        uint256 amt = amount < bal ? amount : bal;
        if (amt > 0) boss.transferFrom(from, to, amt);
    }

    /// @dev Transfers BOSS it holds to the hook (a sink).
    function toHook(address hook_, uint256 amount) external {
        uint256 bal = boss.balanceOf(address(this));
        uint256 amt = amount < bal ? amount : bal;
        if (amt > 0) boss.transfer(hook_, amt);
    }
}

/// @notice An aggregator-style front contract that is NOT the locker: it has a router (the locker)
/// execute the swap with the output sent to itself, then forwards exactly the BOSS it received
/// (balance after minus balance before) to the user, the way an aggregator router checks a minimum
/// output and pays it out. `sweep` is public, like the Universal Router's SWEEP: anything this
/// contract holds between transactions can be taken by anyone.
contract ExactForwarder {
    BossToken public immutable boss;

    constructor(BossToken boss_) {
        boss = boss_;
    }

    receive() external payable {}

    function route(R3Router router, R3Router.Action[] calldata actions, address user) external {
        uint256 before = boss.balanceOf(address(this));
        router.run(actions);
        uint256 got = boss.balanceOf(address(this)) - before;
        boss.transfer(user, got);
    }

    function sweep(address token, address to) external {
        if (token == address(0)) {
            (bool ok,) = to.call{value: address(this).balance}("");
            require(ok, "eth");
        } else {
            IERC20Lite(token).transfer(to, IERC20Lite(token).balanceOf(address(this)));
        }
    }
}
