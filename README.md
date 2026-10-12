# BOSS

BOSS is a game token on a Uniswap v4 pool, played by trading. The pool is BOSS/IMD and a single
hook contract (`BossHook`) runs the game inside every swap. Every buy of BOSS hits the boss, every
sell heals it, and a daily "ability" written by the IMD swarm changes how hard. When the boss dies, the
pot is paid out.

Status: contracts and tests are done. Nothing is deployed or published yet. The launch goes through
the IMD swarm's `launch.open` with kind `univ4_hook` (see `launch.json`).

## The game in 6 lines

1. Every swap pays a 2.5% hook fee in IMD: 1.5% goes to the pot, 1% to the treasury (the keeper wallet).
   The pool also charges its own 1.25% LP fee on top (fee tier 12500, the only one the mainnet hook policy admits).
2. A buy deals damage to the boss, a sell heals it. The ability of the day scales both (1x by default).
3. Credit follows the BOSS. A buy's damage goes to the wallet that receives the BOSS from the pool. BOSS you
   hand back to the pool (a sell, a deposit) forfeits damage in proportion to the BOSS you bought that round:
   selling half of it loses half your damage, selling all of it loses all of it. BOSS you send to another
   wallet carries that proportion of your credit with it.
4. The wallet that lands the killing blow gets the killer share. The pot is split on a kill: 10% stays as the seed of the
   next boss, then 50% to the killer and 50% by the damage each wallet still holds. The killing blow is itself
   damage, so a kill always leaves someone eligible.
5. The next boss spawns with HP set by how fast the last one fell.
6. Payouts are pull-only: `claimKill`, `claimDamage`, `claimTreasury`.

Attribution: `BossToken` reports every transfer to the hook, so who collects is decided by where the BOSS
goes, never by who signed (`tx.origin` only labels the events). Neither `hookData`, nor the router, nor
the signer can name another wallet. A relayer, bundler or solver signing for you changes nothing; a
contract you call for anything else can only sell its own BOSS or hand you BOSS; a flash round trip
that moves no BOSS changes nothing (audit `2f96ed9f`, findings 1 and 2, and the identity limits that
followed them). The one trust left is in the code that executes your killing swap (see Known limits).

## Pool binding

The hook is built for exactly one pool key. Its constructor pins the paired currency (IMD,
`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`) and the launch tick, while the LP fee (12500, that is 1.25%) and the tick spacing (60)
are source constants (`LP_FEE`, `TICK_SPACING`), and`beforeInitialize` refuses any other paired currency, fee or spacing, a second pool, and a start
price more than 300 ticks from the briefed launch tick (|129000| for the ordering it sees). The pin
must match the manifest's `pool` block. The constructor takes 9 flat static arguments (manager, token,
keeper, board, oracle signer, question hash, initial HP, launch tick, paired currency), which is what the
swarm launch factory accepts; the oracle panel 21 and quorum 15 are source constants (`PANEL_SIZE`,
`QUORUM`) and must match the IMD oracle request. The pin narrows the race but does not remove it: the first
valid `initialize` still binds the hook, so the launch must deploy the hook and initialize the pool
atomically.

## Trust model

- No owner, no setters, no proxy, no `DELEGATECALL`, no `SELFDESTRUCT`. Hook flags are `0x20CC`.
- `BossToken` is a fixed-supply ERC-20 (1,000,000,000, minted once to the deployer) with one addition: after
  every transfer it calls `BossHook.onBossTransfer`. The hook is bound once, by the hook's constructor in the
  launch (`bindHook`, refused after the first binding and from any signer but the token's deployer; a launch
  that cannot bind reverts instead of running unscored). The handler is bookkeeping only, with no revert
  path, so it cannot block a transfer. No owner, mint, pause, blocklist, fee or upgrade path.
- **The keeper** collects the 1% treasury and **selects which swarm-written ability is proposed** on the
  separate `AbilityBoard`. That is real influence over the game, bounded as follows.
- **The IMD oracle panel must approve** the proposal: an ability becomes active only if the IMD oracle signs
  (EIP-712) the answer `id*2+1` to a fixed question about `AbilityBoard.pending()` (draft in
  `docs/ORACLE-QUESTION.md`), which checks conditions (a)-(e): verified source, the right interface, the
  cited swarm artifact, nothing but returning two numbers, and no dependence on the trader's address or
  any named wallet. IMD is therefore a trusted attester for abilities, and only for that.
- **The effect is bounded**: both multipliers are clamped to [0.25x, 4x], every change waits 12 hours in
  public before it applies, and at most one activation happens per 24 hours.
- The keeper cannot activate an ability without the oracle, move the pot, touch players' claims or pause trading.
- An ability only returns two numbers. It is called with `STATICCALL` and 50k gas and any failure falls back
  to 1x. A swap reverts if too little gas remains to give the ability its full 50k, so an ability cannot be
  starved into failing.
- Gas, router included, with an active ability: buy about 261k, sell about 244k. A BOSS transfer costs about
  46k, 52k when credit travels with it (`test/BossHook.Gas.t.sol`).
- A mainnet-fork test reproduces the launch and trades through the real PoolManager, PositionManager, Permit2
  and Universal Router against the real IMD, including the app's interface-fee shape (the router custodies
  the BOSS, pays the fee and sweeps): `BOSS_FORK_RPC=<rpc> forge test --match-path "test/fork/*"`. It is
  skipped without the variable, so the normal suite never touches the network.

## Writing an ability

An ability implements `modifiers(SwapInfo) view returns (uint256 buyMultBps, uint256 sellMultBps)`.

- Stay under about 30k gas cold (the hard cap is 50k; past it the trade falls back to 1x).
- Never read `s.trader` and never name a specific address: condition (e) of the oracle question rejects it.
- Never call any external contract; use only the `SwapInfo` fields (amount, side, time, round, HP, pot).

## Tests

```sh
export PATH="$HOME/.foundry/bin:$PATH"
forge build --sizes
forge test
```

The suite includes fuzz and invariant tests (money accounting, HP bounds, closed rounds never overpay).
`BossHook` stays below the 24,576 byte runtime limit. Results are recorded in `docs/REVIEW.md`.

## Known limits

- Credit follows the BOSS, so moving BOSS between your own wallets moves the credit with it, in proportion.
  Claim from the wallet that holds it. The same holds for BOSS sold anywhere but this pool (another DEX,
  a CEX deposit): the credit goes to that venue, and from there to whoever buys the BOSS; it is not
  redistributed to the other players.
- A buy's credit waits for BOSS to leave the pool in the same transaction, whatever that BOSS is: a buy
  kept as ERC-6909 claims earns no credit by itself, but BOSS taken later in that transaction (claims
  burned, an LP withdrawal) collects it. If no BOSS leaves, the credit vanishes and dilutes nobody.
  Depositing BOSS into the pool as claims counts as handing it back.
- The killing blow and its damage are credited to the signer at the kill and travel with that BOSS for
  the rest of the transaction, through any router, aggregator or solver that custodies it on the way;
  the killer prize goes to whoever ends up holding the largest share of the BOSS that left the pool with
  the killing blow (other BOSS of that round moving in the same transaction carries its credit but never
  the prize). BOSS the signer takes out of the pool later in that transaction is counted as the killing
  blow's first. What never leaves the pool in that transaction (claims, a flash round trip of the
  signer's own) stays with the signer, a router that delivers the BOSS in a later transaction keeps the
  kill, and of two kills in one transaction only the last one travels.
- Whoever executes the killing swap for you can keep the kill: a solver, an aggregator or a contract you
  hand the trade to can take the BOSS and deliver its own, take it with a flash and return it before your
  BOSS leaves the pool, or claim the prize between two unlocks of the same transaction. Routers that only
  route (the Uniswap app, the IMD explorer) and bundlers that only sign cannot. Trade through code you trust.
- Credit moved to a wallet that already collected that round is stranded: never paid twice, never recovered.
- The forfeit is measured in BOSS against what you bought in the current round, so BOSS from an earlier
  round leaving your wallet after a buy in this one counts against this round.
- `BossToken` makes one external call per transfer (`onBossTransfer`); it has no revert path, so it cannot
  block transfers, but token scanners may flag the pattern.
- The hook binds the token in its constructor; the token accepts a binding once, and only in a transaction
  signed by its deployer. The launch must deploy both in one transaction, as the IMD factory does: in
  between, any contract that key called could bind itself, and the real hook would then revert, loudly,
  rather than launch unscored.
- Bots race for the killing blow.
- After a high-volume round the next boss holds a large seed, and one wallet can take most of it by
  killing the fresh boss alone. The HP scaling (a boss that fell fast comes back 1.5x tougher) dampens this.
- Unclaimed prizes and rounding dust stay in the hook forever: there is no admin sweep.
- Abilities see the signer (`tx.origin`) and the amount of every trade. Condition (e) of the oracle question forbids
  address-specific logic, but that is enforced by the panel, not by the hook.
- The treasury depends on volume, and so does the pot.
- The launch must deploy the hook and initialize the pool atomically, because the first valid `initialize` binds the hook.
- Everything is denominated in IMD, so BOSS inherits IMD's risks (IMD must be a plain 18-decimals ERC-20).
- The IMD oracle signer is immutable: a key rotation freezes abilities at the last active one.

## Credits

The fee, claim and pool-binding machinery is adapted from launch-784 (the WIN hook), MIT licensed.
