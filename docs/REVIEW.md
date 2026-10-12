# BossHook review notes

## Gas and invariants (Task 8)

Gas per swap with an active ability (WhaleNerfAbility), router included, warm pool
(`test_gas_buyAndSell_withAbility`, bound 450,000):

- Buy: 234,167 gas
- Sell: 253,525 gas

Invariant fuzzing (`test/invariant`, foundry.toml `[profile.default.invariant]`): runs = 64, depth = 64
(64 runs x 64 calls = 4096 calls, 0 reverts). Handler actors: 5 wallets doing buy, sell, warp, claimDamage, claimKill.
Invariants: money accounting (`assertAccounting`), HP within bounds, closed rounds never overpay
(eligible damage == sum of non-sellers' damage over the handler actors).

## Final run (Task 9)

- `forge build --sizes`: BossHook runtime 19,180 bytes (limit 24,576; margin 5,396), initcode 20,930 bytes (limit 49,152; margin 28,222).
- `forge test`: 13 suites, 99 tests passed, 0 failed, 0 skipped.
- Launch package: `launch.json` (placeholders documented in `notes`), `README.md`, `docs/ORACLE-QUESTION.md` (draft; nothing submitted, nothing paid; the free `/requests/check` needs the deployed board).

## Final-review fix wave

Corrections to the notes above: the invariant campaign is 64 runs × depth 64 = 4,096 calls in
total (not 64 runs × 4,096 calls).

- Pool pin (A): `beforeInitialize` refuses any other paired currency, LP fee or tick spacing
  (`WrongPairedCurrency`, `WrongLPFee`, `WrongTickSpacing`). Superseded: the constructor is now 9 flat static
  params (the swarm factory only accepts flat static args); panel 21 / quorum 15 and fee 3000 / spacing 60 are
  source constants, and `launchTickAbs` and `pairedCurrency` remain constructor args.
- Handler (D): 5 actors doing exact-input and exact-output buys and sells, warp, claimDamage, claimKill and
  claimTreasury, with `FixedAbility(15000, 7500)` active. Invariants: money accounting, fees charged ==
  paid out + treasury paid + held claims, HP within bounds, closed rounds never overpay (eligible damage ==
  non-sellers' damage, damage claims per round <= damage pool), kill claims <= killer prizes won
  (paid + unclaimed == won), plus a call summary (log only). 64 runs × depth 64 = 4,096 calls, 0 reverts.
- Gas with an active ability, router included: buy 234,233, sell 253,591.
- `forge build --sizes`: BossHook runtime 19,570 bytes (limit 24,576; margin 5,006), initcode 21,758 bytes
  (limit 49,152; margin 27,394).
- `forge test`: 13 suites, 150 tests passed, 0 failed, 0 skipped.

## Credit follows the BOSS (2026-10-12)

The swarm audit (job 2f96ed9f) found two mediums in the sell-forfeit rule: a zero-value sell inside a
victim's transaction forfeited her whole share, and buys could be credited to a `hookData` label while sells
marked `tx.origin`. The first fix made the forfeit proportional to the BOSS sold and credited everything to
the signer; it left three limits (a relayer, bundler, solver or second wallet dodged the forfeit; a contract
the player called traded as the player; buys through intermediaries were credited to the intermediary,
killing blow included). The second fix removes the signer from attribution altogether: `BossToken` reports
every transfer to the hook (`onBossTransfer`, bound once in the hook's constructor), a buy's credit waits in
transient storage and goes to the wallet that receives the BOSS from the pool, BOSS handed back to the pool
forfeits in proportion, BOSS sent to another wallet carries its credit, and the killing blow travels with its
BOSS for the rest of the transaction (router custody included), the prize going to the largest holder of the
BOSS that left the pool with the blow.

- Two independent reviews, each with its own probes (41 and 34, kept in `test/review/` and `test/review2/`),
  each found one critical: a kill delivered pool -> router -> player stranded prize and damage on the router;
  and the prize counter mixed any BOSS of the closed round, so a stranger's transfer bundled after the kill
  took it. Both fixed; the reviewers' probes pass unchanged. Remaining limits are in the README.
- `forge test`: 25 suites, 311 tests passed, 0 failed (isolate mode, so transient storage clears between calls).
- `forge build --sizes`: BossHook runtime 22,078 bytes (limit 24,576; margin 2,498), initcode 24,103.
- Gas with an active ability, router included: buy 261,276, sell 243,771. A BOSS transfer: 45,938, or
  51,581 when credit travels with it.
- Mainnet fork (`test/fork/UniversalRouter.t.sol`, `BOSS_FORK_RPC` set): 5 passed. Buy, sell, relayer-signed
  buy and sell, and the interface-fee shape of the Uniswap app (TAKE to the router, PAY_PORTION, SWEEP) with
  a kill: the prize and the damage reach the player, nothing stays on the Universal Router.

## Second swarm audit (job be67d693, 2026-10-12)

The swarm audit of `b154ad2` found 2 high, 5 low and 3 info. Fixed in code:

- High 1, flash sells never forfeited pending credit: a sell now takes back this transaction's pending
  credit for the BOSS it hands in (`_unpend`), and the net credit a transaction creates (credited minus
  forfeited) never exceeds the HP it has removed in the round when that credit is delivered
  (`_cappedPending`, anchored at the transaction's first trade of the round).
- High 2, pending and killing credit merged across the parties of one transaction: they are scoped to the
  locker (`afterSwap`'s `sender`); a swap here by another locker voids what is left and trims the cap.
- Low 3: the hook is a sink like the pool (BOSS sent or taken to it forfeits or voids its credit).
- Low 6: blow BOSS handed back to the pool lowers its holder's count, and the prize is re-decided over the
  transaction's holders whenever the largest one hands some away (this also fixes a split such as
  46% / 10% / 44% that was not in the report).
- Documented in the README: lows 4, 5 and 7 (7 kept as the agreed rule) and infos 8 to 10.

Two independent reviews followed, each with its own probes (`test/review3/`, `test/review4/`, run with BOSS
as currency0, as currency1 and with native ETH):

- Review 3 broke the first cap (it re-anchored when the pending batch emptied, so selling first and buying
  back inflated a kill: 0.96 credited against 0.1 removed). Fixed by anchoring once per transaction and
  round. Its finding B is a documented limit: BOSS a router leaves inside the PoolManager can be collected
  by the next party that takes BOSS out in that transaction, which the hook cannot tell apart from the
  router; standard routers take everything out.
- Review 4 found that a forfeited sell was charged twice by the cap (one player selling and buying again
  in one transaction lost the second buy's credit) and that, on heal-boost days, a later locker could be
  credited with an earlier locker's voided damage. Both fixed: forfeits give back their cap room, and a
  locker change trims the room to the HP left. It also corrected a README sentence.
- `forge test`: 33 suites, 400 tests passed, 0 failed, 5 skipped (fork tests, need an RPC). Both reviews'
  fuzzers pass 3,000 runs in each configuration; the invariant campaign passes at 256 runs × depth 64.
- `forge build --sizes`: BossHook runtime 23,151 bytes (limit 24,576; margin 1,425).
- Gas with an active ability, router included: buy 262,990, sell 245,444; transfer 45,975 / 51,618.
- Mainnet fork (`test/fork/UniversalRouter.t.sol`, `BOSS_FORK_RPC` set): 5 passed with these fixes, the
  interface-fee kill through the real Universal Router included.
