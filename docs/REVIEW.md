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
