// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAbility, SwapInfo} from "../../src/interfaces/IAbility.sol";

contract FixedAbility is IAbility {
    uint256 public immutable buyMult;
    uint256 public immutable sellMult;

    constructor(uint256 b, uint256 s) {
        buyMult = b;
        sellMult = s;
    }

    function modifiers(SwapInfo calldata) external view returns (uint256, uint256) {
        return (buyMult, sellMult);
    }

    function name() external pure returns (string memory) {
        return "Fixed";
    }
}

/// @notice "Yesterday the whales won": buys of 1 ether or more hit half.
contract WhaleNerfAbility is IAbility {
    function modifiers(SwapInfo calldata s) external pure returns (uint256, uint256) {
        return (s.isBuy && s.amount >= 1 ether ? 5_000 : 10_000, 10_000);
    }

    function name() external pure returns (string memory) {
        return "Whale Nerf";
    }
}

contract RevertingAbility is IAbility {
    function modifiers(SwapInfo calldata) external pure returns (uint256, uint256) {
        revert("nope");
    }

    function name() external pure returns (string memory) {
        return "Revert";
    }
}

contract GasBombAbility is IAbility {
    function modifiers(SwapInfo calldata) external pure returns (uint256, uint256) {
        uint256 x;
        while (true) {
            x++;
        }
        return (x, x);
    }

    function name() external pure returns (string memory) {
        return "Gas Bomb";
    }
}

/// @notice Returns 32 bytes instead of 64.
contract ShortReturnAbility {
    fallback() external {
        assembly {
            mstore(0, 40000)
            return(0, 32)
        }
    }
}

contract HugeAbility is IAbility {
    function modifiers(SwapInfo calldata) external pure returns (uint256, uint256) {
        return (type(uint256).max, 0);
    }

    function name() external pure returns (string memory) {
        return "Huge";
    }
}

/// @notice Tries to write storage. Under STATICCALL the write reverts, so the hook must fall back.
contract StateWriterAbility {
    uint256 public calls;

    function modifiers(SwapInfo calldata) external returns (uint256, uint256) {
        calls++;
        return (40_000, 2_500);
    }
}

/// @notice Probe: burns about 45k of its 50k gas, then returns 2x hits / 1x heals. It only
/// succeeds when the hook really forwards (nearly) the full ABILITY_GAS.
contract BurnerAbility is IAbility {
    uint256 internal constant BURN = 45_000;

    function modifiers(SwapInfo calldata) external view returns (uint256, uint256) {
        uint256 start = gasleft();
        bytes32 x;
        while (start - gasleft() < BURN) {
            x = keccak256(abi.encode(x));
        }
        return (20_000, 10_000);
    }

    function name() external pure returns (string memory) {
        return "Burner";
    }
}
