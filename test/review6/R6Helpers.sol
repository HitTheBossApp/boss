// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BossToken} from "../../src/BossToken.sol";
import {R3Router} from "../review3/R3Router.sol";

/// @notice A contract that does its work from its constructor (a one-shot "deploy and execute" contract,
/// the shape some aggregators and bots use): it has a router execute a buy with the output sent to
/// itself and forwards exactly what it received to `user`. While its constructor runs, its code is
/// empty (`address(this).code.length == 0`). No receive, no sweep, no claim function.
contract CtorForwarder {
    constructor(R3Router router, BossToken boss, uint256 quoteIn, address user) {
        R3Router.Action[] memory s = new R3Router.Action[](2);
        s[0] = R3Router.Action(R3Router.Kind.BuyIn, address(0), quoteIn, 0, 0);
        s[1] = R3Router.Action(R3Router.Kind.TakeBoss, address(this), type(uint256).max, 0, 0);
        uint256 before = boss.balanceOf(address(this));
        router.run(s);
        uint256 got = boss.balanceOf(address(this)) - before;
        if (got > 0) boss.transfer(user, got);
    }
}

/// @notice CREATE2 factory for CtorForwarder, so its address is known before it exists.
contract CtorFactory {
    function deploy(bytes32 salt, R3Router router, BossToken boss, uint256 quoteIn, address user)
        external
        returns (address)
    {
        return address(new CtorForwarder{salt: salt}(router, boss, quoteIn, user));
    }

    function predict(bytes32 salt, R3Router router, BossToken boss, uint256 quoteIn, address user)
        external
        view
        returns (address)
    {
        bytes32 h = keccak256(abi.encodePacked(type(CtorForwarder).creationCode, abi.encode(router, boss, quoteIn, user)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, h)))));
    }
}

/// @notice The body an EIP-7702 wallet delegates to (or a smart account): runs calls as itself.
/// No auth: in the tests only the wallet's own flows call it.
contract BatchWallet {
    struct Call {
        address target;
        bytes data;
    }

    receive() external payable {}

    function exec(Call[] calldata calls) external {
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    /// @dev transfer(min(amount, balance)) of `token` to `to`.
    function send(BossToken token, address to, uint256 amount) external {
        uint256 bal = token.balanceOf(address(this));
        uint256 amt = amount < bal ? amount : bal;
        if (amt > 0) token.transfer(to, amt);
    }
}
