// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReviewBase} from "./ReviewBase.sol";
import {ReviewRouter} from "./ReviewRouter.sol";
import {BossHook} from "../../src/BossHook.sol";

/// @notice One transaction, up to twelve random steps (buys with full, split or dust takes, buys kept
/// as claims, claims turned into BOSS, sells and deposits settled from players' wallets, wallet-to-wallet
/// transfers, LP removals, flash takes, claims between unlocks), signed by the player or by a relayer.
/// After the transaction: every round's eligible damage equals the damage its wallets hold, no wallet's
/// round BOSS exceeds its balance, the money accounting closes, and claiming everything afterwards never
/// pays more than the prizes and pools decided at each kill. The transaction itself must never revert:
/// every amount is bounded so that the only possible revert would come from the hook.
abstract contract ReviewSingleTxFuzzBase is ReviewBase {
    address[] internal players;

    function setUp() public virtual override {
        super.setUp();
        players.push(alice);
        players.push(bob);
        players.push(carol);
        buyExactIn(alice, 0.2 ether); // some credit and BOSS exist before the transaction
        buyExactIn(bob, 0.1 ether);
    }

    function _p(uint256 x) internal view returns (address) {
        return players[x % players.length];
    }

    function _buildStep(uint256 r) internal view returns (bytes memory) {
        uint256 kind = r % 13;
        uint256 amount = 0.01 ether + (r >> 8) % 2.5 ether; // buys of 0.01 to 2.51 IMD: kills happen often
        address a = _p(r >> 16);
        address b = _p(r >> 24);
        uint256 pct = 1 + (r >> 32) % 100;
        if (kind == 0) {
            ReviewRouter.Action[] memory u = new ReviewRouter.Action[](2);
            u[0] = rr.buy(amount);
            u[1] = rr.takeBoss(a, type(uint256).max);
            return abi.encodeCall(rr.unlockWith, (u));
        } else if (kind == 1) {
            ReviewRouter.Action[] memory u = new ReviewRouter.Action[](3);
            u[0] = rr.buy(amount);
            u[1] = rr.takeBossShare(a, 1, 3);
            u[2] = rr.takeBoss(b, type(uint256).max);
            return abi.encodeCall(rr.unlockWith, (u));
        } else if (kind == 2) {
            ReviewRouter.Action[] memory u = new ReviewRouter.Action[](2);
            u[0] = rr.buy(amount);
            u[1] = rr.takeBossAsClaims(type(uint256).max);
            return abi.encodeCall(rr.unlockWith, (u));
        } else if (kind == 3) {
            ReviewRouter.Action[] memory u = new ReviewRouter.Action[](1);
            u[0] = rr.claimsToBoss(a, type(uint256).max);
            return abi.encodeCall(rr.unlockWith, (u));
        } else if (kind == 4) {
            ReviewRouter.Action[] memory u = new ReviewRouter.Action[](1);
            u[0] = rr.sellPctFrom(a, pct);
            return abi.encodeCall(rr.unlockWith, (u));
        } else if (kind == 5) {
            ReviewRouter.Action[] memory u = new ReviewRouter.Action[](1);
            u[0] = rr.depositPctFrom(a, pct);
            return abi.encodeCall(rr.unlockWith, (u));
        } else if (kind == 6) {
            return abi.encodeCall(rr.transferBossFromPct, (a, b, pct));
        } else if (kind == 7) {
            return abi.encodeCall(rr.tryClaimKill, (a));
        } else if (kind == 8) {
            return abi.encodeCall(rr.tryClaimDamage, (uint64(1 + (r >> 40) % 4), a));
        } else if (kind == 9) {
            ReviewRouter.Action[] memory u = new ReviewRouter.Action[](2);
            u[0] = rr.removeLiquidity(RR_LIQ / 16);
            u[1] = rr.takeBoss(a, type(uint256).max);
            return abi.encodeCall(rr.unlockWith, (u));
        } else if (kind == 10) {
            ReviewRouter.Action[] memory u = new ReviewRouter.Action[](2);
            u[0] = rr.buy(amount);
            u[1] = rr.flashTakeBoss(a, 1 + (r >> 48) % 10_000 ether);
            return abi.encodeCall(rr.unlockWith, (u));
        } else if (kind == 11) {
            ReviewRouter.Action[] memory u = new ReviewRouter.Action[](3);
            u[0] = rr.buy(amount);
            u[1] = rr.takeBoss(address(rr), 1); // the router keeps one wei first
            u[2] = rr.takeBoss(a, type(uint256).max);
            return abi.encodeCall(rr.unlockWith, (u));
        } else {
            ReviewRouter.Action[] memory u = new ReviewRouter.Action[](3);
            u[0] = rr.sellPctFrom(a, pct);
            u[1] = rr.buy(amount);
            u[2] = rr.takeBoss(a, type(uint256).max);
            return abi.encodeCall(rr.unlockWith, (u));
        }
    }

    function testFuzz_oneTx_manySteps_sumsMoneyAndPayoutsAlwaysClose(uint256 seed, uint8 steps, bool relayed)
        public
    {
        steps = uint8(bound(steps, 1, 12));
        bytes[] memory calls = new bytes[](steps);
        uint256 r = seed;
        for (uint256 i = 0; i < steps; i++) {
            r = uint256(keccak256(abi.encode(r, i)));
            calls[i] = _buildStep(r);
        }
        address signer = relayed ? relayer : alice;
        uint256 playersQuoteBefore = _playersQuote();
        vm.prank(alice, signer);
        rr.multi(calls);
        // Prizes and pools paid INSIDE the transaction (tryClaim* steps) reach players' IMD balances only.
        uint256 paidInTx = _playersQuote() - playersQuoteBefore;

        // Books close after the transaction, for every round.
        _assertOpenRoundSums();
        address[] memory w = _knownWallets();
        uint64 open = hook.round();
        for (uint256 i = 0; i < w.length; i++) {
            assertLe(hook.bought(open, w[i]), boss.balanceOf(w[i]), "round BOSS counted never exceeds the balance");
        }
        for (uint64 c = 1; c < open; c++) {
            (,,, uint256 dp,) = hook.results(c);
            assertLe(_sumClaimable(c), dp, "claimable never exceeds the pool");
        }
        assertAccounting();

        // And nothing is ever paid twice: claim everything, in separate transactions.
        uint256 decided;
        for (uint64 c = 1; c < open; c++) {
            (,, uint256 prize, uint256 dp,) = hook.results(c);
            decided += prize + dp;
        }
        uint256 paid = _claimEverything();
        assertLe(paid + paidInTx, decided, "paid out <= decided at the kills");
        assertEq(hook.totalReserved(), decided - paid - paidInTx, "what is not paid stays reserved");
        assertAccounting();
    }

    function _playersQuote() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < players.length; i++) {
            sum += _quoteBalance(players[i]);
        }
        sum += _quoteBalance(relayer);
    }
}

contract ReviewSingleTxFuzzBossFirstTest is ReviewSingleTxFuzzBase {}

contract ReviewSingleTxFuzzBossSecondTest is ReviewSingleTxFuzzBase {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
