// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Pure arithmetic of the BOSS game: multiplier clamps, damage scaling, next boss HP and
/// the pot split when a boss falls. Kept separate so every rule can be tested in isolation.
library BossMath {
    uint256 internal constant BPS = 10_000;
    /// @notice An ability can never make a trade count for less than 0.25x ...
    uint256 internal constant MIN_MULT_BPS = 2_500;
    /// @notice ... or more than 4x.
    uint256 internal constant MAX_MULT_BPS = 40_000;
    /// @notice Share of the pot kept as the next boss's seed.
    uint256 internal constant SEED_BPS = 1_000;
    /// @notice Share of the remainder (after the seed) paid to the killing blow.
    uint256 internal constant KILLER_BPS = 5_000;

    function clampMult(uint256 multBps) internal pure returns (uint256) {
        if (multBps < MIN_MULT_BPS) return MIN_MULT_BPS;
        if (multBps > MAX_MULT_BPS) return MAX_MULT_BPS;
        return multBps;
    }

    function scale(uint256 amount, uint256 multBps) internal pure returns (uint256) {
        return amount * multBps / BPS;
    }

    /// @notice A boss that fell in under a day comes back 1.5x tougher; one that lasted over three
    /// days comes back at 0.75x. Always within [initialHp / 4, initialHp * 16].
    function nextMaxHp(uint256 prevMax, uint256 duration, uint256 initialHp) internal pure returns (uint256 next) {
        if (duration < 1 days) next = prevMax * 3 / 2;
        else if (duration > 3 days) next = prevMax * 3 / 4;
        else next = prevMax;
        uint256 lo = initialHp / 4;
        uint256 hi = initialHp * 16;
        if (next < lo) next = lo;
        if (next > hi) next = hi;
    }

    /// @notice Seed first, then half of the rest to the killer and half to the damage pool. With no
    /// eligible damage the damage half rolls into the seed.
    function splitPot(uint256 pot, bool anyEligible)
        internal
        pure
        returns (uint256 seed, uint256 killerPrize, uint256 damagePool)
    {
        seed = pot * SEED_BPS / BPS;
        uint256 rest = pot - seed;
        killerPrize = rest * KILLER_BPS / BPS;
        damagePool = rest - killerPrize;
        if (!anyEligible) {
            seed += damagePool;
            damagePool = 0;
        }
    }

    /// @notice `part / total` of `pool`, rounded down. Zero when `total` is zero.
    function share(uint256 pool, uint256 part, uint256 total) internal pure returns (uint256) {
        if (total == 0) return 0;
        return pool * part / total;
    }
}
