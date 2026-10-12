# BOSS

BOSS is a game token on a Uniswap v4 pool, played by trading. The pool is BOSS/IMD and a single
hook contract (`BossHook`) runs the game inside every swap. Every buy of BOSS hits the boss, every
sell heals it, and a daily "ability" written by the IMD swarm changes how hard. When the boss dies,
the pot is paid out.

Status: contracts and tests are complete. Nothing is deployed yet. The launch goes through the IMD
swarm's `launch.open` with kind `univ4_hook`, on Ethereum mainnet, from this repository (see
`launch.json`).

## The game in 6 lines

1. Every swap pays a 2.5% hook fee in IMD, on top of the pool's 1.25% LP fee: 1.5% goes to the pot,
   1% to the treasury, which is paid to the keeper.
2. A buy deals damage to the boss, a sell heals it. The ability of the day scales both (1x by default).
3. Selling forfeits your damage for the current round.
4. The pot is split on a kill: 10% stays as the seed of the next boss, then 50% goes to the wallet that
   lands the killing blow and 50% is split by damage among wallets that did not sell that round. If
   nobody is eligible at the kill (every damage dealer sold), the damage half rolls into the next seed.
5. The next boss spawns with HP set by how fast the last one fell.
6. Payouts are pull-only: `claimKill`, `claimDamage`, `claimTreasury`.

Attribution: a **sell** is credited only to `tx.origin`, the signer. A **buy** is credited to the
address packed in `hookData`, else the router's `msgSender()`, else `tx.origin`. Naming someone in a
buy only gifts them damage or the kill credit. Nobody can make another wallet forfeit its share.

## Contracts

| File | What it is |
|---|---|
| `src/BossToken.sol` | Plain fixed-supply ERC-20: BOSS, 18 decimals, 1,000,000,000 minted once to the deployer. |
| `src/BossHook.sol` | The Uniswap v4 hook (flags `0x20CC`: beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta). Fees, game state, payouts and ability calls. |
| `src/AbilityBoard.sol` | Holds the one ability proposal the oracle panel is asked about. Only its keeper can propose. Deployed before the hook. |
| `src/OracleGate.sol` | Verifies IMD oracle EIP-712 attestations (domain "IdentityMD Oracle", version 2). |
| `src/libraries/BossMath.sol` | Pure math: clamps, damage scaling, next-boss HP, pot split. |
| `src/interfaces/IAbility.sol` | `IAbility`, `IAbilityBoard` and the `SwapInfo` struct an ability receives. |
| `src/HookFlags.sol` | Hook permission bits (from launch-784, unchanged). |

`BossHook` takes 9 flat static constructor arguments: pool manager, token, keeper, AbilityBoard,
oracle signer, question hash, initial HP, launch tick and paired currency. The constructor reverts
unless the AbilityBoard already has code and its `keeper()` equals the keeper argument.

## Pool binding

The hook is built for exactly one pool key. Its constructor pins the paired currency (IMD,
`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`) and the launch tick, while the LP fee (12500, that is 1.25%,
charged by the pool on top of the hook's 2.5%) and the tick spacing (60) are source constants (`LP_FEE`,
`TICK_SPACING`). `beforeInitialize` refuses any
other paired currency, fee or spacing, a second pool, and a start price more than 300 ticks from the
launch tick (|129000|, a 2,500 IMD opening cap) for the ordering it sees. The pin must match the
`pool` block of `launch.json`. The oracle panel size 21 and quorum 15 are also source constants
(`PANEL_SIZE`, `QUORUM`) and must match the IMD oracle request.

The pin narrows the race but does not remove it: the first valid `initialize` still binds the hook,
so the launch must deploy the hook and initialize the pool atomically.

## Trust model

- No owner, no setters, no proxy, no `DELEGATECALL`, no `SELFDESTRUCT`.
- **The keeper** is a fixed address set at deploy. It collects the 1% treasury and **selects which
  swarm-written ability is proposed** on the separate `AbilityBoard`. That is real influence over the
  game, bounded as follows.
- **The IMD oracle panel must approve** the proposal: an ability is queued only if the IMD oracle signs
  (EIP-712) the answer `id*2+1` to a fixed question about `AbilityBoard.pending()`
  (`docs/ORACLE-QUESTION.md`). The question checks five conditions: verified source, the right
  interface, the cited swarm job, nothing but returning two numbers, and no dependence on the trader
  or on any named wallet. IMD is therefore a trusted attester for abilities, and only for that.
- **The effect is bounded**: both multipliers are clamped to [0.25x, 4x], every change waits 12 hours
  in public before it applies, and at most one activation happens per 24 hours.
- The keeper cannot activate an ability without the oracle, move the pot, touch players' claims or
  pause trading.
- An ability only returns two numbers. It is called with `STATICCALL` and 50k gas, and any failure
  falls back to 1x. A swap reverts if too little gas remains to give the ability its full 50k, so an
  ability cannot be starved into failing.
- Gas with an active ability, router included: buy about 234k, sell about 254k (`docs/REVIEW.md`).

## Writing an ability

An ability implements `modifiers(SwapInfo) view returns (uint256 buyMultBps, uint256 sellMultBps)`.

- Stay under about 30k gas cold (the hard cap is 50k; past it the trade falls back to 1x).
- Never read `s.trader` and never name a specific address: condition (e) of the oracle question rejects it.
- Never call any external contract; use only the `SwapInfo` fields (amount, side, time, round, HP, pot).

## Build and test

Requires [Foundry](https://getfoundry.sh). Dependencies are vendored in `lib/` (no submodules).

```sh
forge build --sizes
forge test
```

The suite has unit, fuzz and invariant tests: money accounting, HP bounds, closed rounds never
overpay, the four swap shapes in both currency orderings, hostile abilities, the gas floor, and a
real IMD mainnet attestation checked against `OracleGate`. Results: `docs/REVIEW.md`.

`tools/oracle-check.mjs` holds the exact oracle request body (Node 18+). Running it only asks the
IMD API for free quotes; it never builds or sends a payment.

## Known limits

- Selling from a different wallet than the one that bought evades the forfeit. Accepted.
- Smart-contract wallets relaying through a bundler are credited to the relayer EOA on sells.
- Buys through aggregators or solvers may be credited to the aggregator contract unless they pass
  `hookData = buyer`.
- Bots race for the killing blow.
- After a high-volume round the next boss holds a large seed, and one wallet can take most of it by
  killing the fresh boss alone. The HP scaling (a boss that fell fast comes back 1.5x tougher) dampens this.
- Unclaimed prizes and rounding dust stay in the hook forever: there is no admin sweep.
- Abilities see the trader and the amount of every trade. Condition (e) of the oracle question forbids
  address-specific logic, but that is enforced by the panel, not by the hook.
- The treasury depends on volume, and so does the pot.
- Everything is denominated in IMD, so BOSS inherits IMD's risks (IMD must be a plain 18-decimals ERC-20).
- The IMD oracle signer and the keeper are immutable. If IMD rotates its signing key, abilities freeze
  at the last active one (or 1x). If the keeper key is lost, no new ability can be proposed and the
  treasury (which `claimTreasury` always pays to the keeper, whoever calls it) is stranded. In both
  cases trading, the pot and the players' claims keep working.

## License

MIT, see `LICENSE`. The fee, claim and pool-binding machinery is adapted from launch-784 (the WIN
hook, [identity-md-launches/launch-784-custom-token-last-buyer](https://github.com/identity-md-launches/launch-784-custom-token-last-buyer)),
MIT licensed. Code in `lib/` keeps its own licenses.
