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

## Third swarm audit (job 853ff4df, 2026-10-13)

The swarm audit of `54e917c` found 0 high, 1 medium, 3 low and 1 info. Fixed in code:

- Medium 1, a bystander's closed-round credit moved with their BOSS inside the transaction that closed the
  round: only the killing blow's BOSS now carries that round's credit (per-wallet transient blow credit,
  `_hopBlow`); every other closed-round credit is frozen, as in any later transaction.
- Low 2, a killer paying with older BOSS in the kill transaction gave the blow away: a wallet without code
  spends its older BOSS first (blow leaving = blow held - balance after the transfer); a contract hands the
  blow on first, so BOSS planted on a deployed custodian never holds it back.
- Low 4: `acceptAbility` refuses an address with no code or with an EIP-7702 delegation designator.
- Documented in the README: low 3 (a gross-settled buy and sell in one unlock charges the sold BOSS twice)
  and info 5 (the start price depends on the ordering; the factory initializes at the ordering's price).

Independent reviews 5 and 6 (`test/review5/`, `test/review6/`, BOSS as currency0, currency1 and native
ETH): review 5 found an underflow when blow BOSS whose credit was already collected passed through the
signer, a bypass of the 7702 check by revoking before the accept, and planted BOSS holding the blow back
on a custodian; all three fixed. Review 6 found that a contract trading from its constructor counts as a
wallet (griefing only, documented) and asked for clearer README wording on smart-account fees (done).

- `forge test`: 40 suites, 486 tests passed, 0 failed, 5 skipped (fork tests, need an RPC). Fuzzers at
  3,000 runs; invariants at 256 runs × depth 64; mainnet fork 5 passed.
- `forge build --sizes`: BossHook runtime 23,817 bytes (limit 24,576; margin 759).
- Gas with an active ability, router included: buy 262,990, sell 245,444; transfer 45,975 / 51,618.

## Fourth swarm audit (job 94b6c9a5, 2026-10-13)

The swarm audit of `7dc01c2` found 0 high, 1 medium, 1 low and 2 info.

- Medium 1, BOSS planted on the Universal Router before a kill made its interface fee (a share of the
  router's balance) carry the whole blow and the prize to the fee collector: the router that executed the
  killing swap now pays the blow out in proportion to its balance, and once it pays blow BOSS out to a
  wallet it no longer counts for the prize (unless it is the signer). Other contracts hand the blow on
  first; wallets without code spend older BOSS first.
- Low 2 (an ability that is a forwarder or has settable numbers): documented; condition (d) of the oracle
  question covers it, enforced by the panel.
- Info 3: an attestation issued in the proposal's second is accepted. Info 4: a forfeit rounds up.

Independent review 7 (`test/review7/`, BOSS as currency0, currency1 and native ETH) found that the
proportional rule let a router delivering an exact amount, with BOSS planted on it, keep the prize; fixed
as above. Documented residuals: that router keeps its proportional share of the blow's credit; a router
that sweeps a surplus (planted BOSS included) to its own wallet can hand that wallet the prize; a smart
wallet that is its own router hands the prize to the first wallet it pays blow BOSS to.

- `forge test`: 44 suites, 550 tests passed, 0 failed, 5 skipped (fork tests, need an RPC). 35 fuzz tests at
  3,000 runs; invariants at 256 runs × depth 64; mainnet fork 5 passed.
- `forge build --sizes`: BossHook runtime 24,219 bytes (limit 24,576; margin 357).
- Gas with an active ability, router included: buy 262,990, sell 245,585; transfer 45,980 / 51,623.

## Fifth swarm audit (job 965a5fce, 2026-10-13)

The swarm audit of `5acf4b4` found 0 high, 1 medium, 2 low and 2 info.

- Medium 1, a fee-then-exact-delivery router holding planted BOSS handed the prize to the fee wallet. It was
  the third finding about who gets the prize when a contract splits the blow, so the rule was replaced, as
  the judge suggested: the prize goes to the wallet holding more than half of the blow's BOSS, else it stays
  with the signer. The holder list and `_recount` were removed; the killing swap's router still stops
  counting once it pays blow BOSS out to a wallet.
- Low 2: `bindHook` only accepts a contract under construction (not an EOA, not a deployed contract).
  Independent review 8 showed a phished call can still create a child that binds from its constructor, so
  the one-transaction launch (the IMD factory) remains a launch assumption.
- Low 3: when the per-transaction cap cuts pending credit, it cuts the BOSS that carries it too, so it does
  not pad `bought`.
- Infos 4 (a trade scaled to zero by a sub-1x ability) and 5 (last-hit front-running; use a private relay)
  are documented.

Independent review 8 (`test/review8/`, BOSS as currency0, currency1 and native ETH) found that the cap made
the killing blow smaller so a first direct fee took all of it (fixed: the blow keeps all its BOSS), that a
second kill in one transaction left the first prize on its router (fixed: it goes to the signer), and that
the README overstated who can never take the prize (corrected: routes that split the blow can hand it to a
third party).

- `forge test`: 51 suites, 609 tests passed, 0 failed, 5 skipped (fork tests, need an RPC). 44 fuzz tests at
  3,000 runs; invariants at 256 runs × depth 64; mainnet fork 5 passed.
- `forge build --sizes`: BossHook runtime 24,008 bytes (limit 24,576; margin 568); BossToken 1,882.
- Gas with an active ability, router included: buy 263,112, sell 245,581; transfer 45,980 / 51,623.
