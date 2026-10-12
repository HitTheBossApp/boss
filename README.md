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
the signer can name another wallet. A contract you call for anything else can only sell its own BOSS or
hand you BOSS (audit `2f96ed9f`, findings 1 and 2, and the identity limits that followed them).

Inside one transaction (audit `be67d693`, findings 1 and 2): a sell takes back the pending credit of the
BOSS it hands in, so a buy and a sell settled against each other inside the PoolManager (a flash round
trip, no token moves) leave no credit behind; and the net credit a transaction creates (credited minus
forfeited) never exceeds the HP it has removed in the round by the moment that credit is delivered,
every earlier heal in it included, in whatever order and through however many contracts (independent
reviews 3 and 4). A heal later in the same transaction counts as it would in the next one. Pending and
killing credit belong to the router that swapped (the
`sender` the PoolManager reports): a swap by another router later in the same transaction, as in a
bundle of several players' operations, voids what is left of it, so one party's leftovers never merge
into another party's swap or killing blow here. A relayer or bundler signing for you changes nothing as
long as your router delivers the BOSS in that transaction, which every standard router does. The one
trust left is in the code that executes your killing swap (see Known limits).

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
- Gas, router included, with an active ability: buy about 263k, sell about 246k. A BOSS transfer costs about
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
  kept as ERC-6909 claims earns no credit by itself, but BOSS taken out later in that transaction (claims
  burned, an LP withdrawal) collects it, until another router swaps. If no BOSS leaves, the credit
  vanishes and dilutes nobody. Depositing BOSS into the pool as claims counts as handing it back.
- Credit is scoped by router, not by player: two players whose operations go through the same router
  contract in one bundle cannot be told apart. BOSS a router leaves inside the PoolManager (ERC-6909
  claims) carries its pending credit, and the rest of a killing blow with its prize, to whoever next takes
  BOSS out of the PoolManager in that transaction (from this pool, another BOSS pool or claims), unless
  another router swaps on this pool first: the hook cannot tell that taker from the router itself
  (independent review 3, finding B). Every standard router takes all the BOSS out in the same operation.
- The credit cap counts every heal earlier in the transaction: in a bundle, a sell placed before your buy
  lowers the credit your buy can earn (it never raises anyone's). In one transaction, selling BOSS that
  appreciated since it was bought heals a little more than the credit it forfeits, and that difference is
  taken from the credit of a later buy in the same transaction (in two transactions it is not).
- The killing blow and its damage are credited to the signer at the kill and travel with that BOSS for
  the rest of the transaction, through any router, aggregator or solver that custodies it on the way;
  the killer prize goes to whoever holds the largest share of the BOSS that left the pool with the killing
  blow, re-decided whenever the largest holder hands some away (blow BOSS handed back to the pool or sent
  to the hook is held by nobody; other BOSS of that round moving in the same transaction carries its
  credit but never the prize). BOSS the signer's router takes out of the pool later in that transaction
  is counted as the killing blow's first. What never leaves the pool in that transaction (claims, a flash
  round trip), or is still inside when another router swaps, stays with the signer (unless another party
  takes BOSS out first, see above); a router that
  delivers the BOSS in a later transaction keeps the kill; and of two kills in one transaction only the
  last one travels.
- The signer of a relayed or bundled transaction is the relayer or bundler (`tx.origin`). If your router
  keeps the killing BOSS inside the PoolManager (ERC-6909 claims, liquidity) or delivers it in a later
  transaction, the relayer or bundler keeps the kill and its damage (audit `be67d693`, finding 5). Every
  standard router (the Uniswap app, the Universal Router, the IMD explorer) delivers it in the same
  transaction.
- Whoever executes the killing swap for you can keep the kill: a solver, an aggregator or a contract you
  hand the trade to can take the BOSS and deliver its own, take it with a flash and return it before your
  BOSS leaves the pool, or claim the prize between two unlocks of the same transaction. Routers that only
  route (the Uniswap app, the IMD explorer) and bundlers that only sign cannot, as long as the router
  delivers the BOSS in that transaction. Trade through code you trust.
- Credit moved to a wallet that already collected that round is stranded: never paid twice, never recovered.
- The forfeit is measured in BOSS against what the sending wallet bought in the current round. BOSS from an
  earlier round, or held by a wallet that bought nothing this round, heals the boss when sold and forfeits
  nothing: a player can buy from one wallet and sell older BOSS from another, keeping the first wallet's
  credit while the boss heals. It costs about 7.5% of that volume in fees, which grow the pot, and it never
  brings the kill closer (audit `be67d693`, finding 7, kept as the agreed rule). On a day whose ability
  makes heals stronger than hits it is cheaper: there a buy and a sell in one operation heal the boss on
  net with no BOSS at all, and the credit cap keeps them from earning any credit. BOSS from an earlier
  round leaving your wallet after a buy in this one counts against this round.
- Exact-input buys and exact-output sells take the hook fee from the specified amount before the swap, so
  they must fill completely: with a price limit the pool stops at, they revert (`PartialFillNotSupported`)
  instead of filling in part. Protect those trades with a minimum output, not a price limit. The Universal
  Router's v4 swap has no price limit, so the Uniswap app and the IMD explorer are never affected (audit
  `be67d693`, finding 4).
- BOSS sent to the hook, or taken out of the pool to it, is lost for good (the hook cannot move BOSS), and
  its credit is forfeited like BOSS handed back to the pool.
- A trade under 40 wei of IMD pays no hook fee (rounding) but still hits or heals; that is far below gas cost.
- Each time the holder of the most of the killing blow's BOSS hands some away, the prize is re-decided over
  every wallet that received some in that transaction (about 350 gas per wallet). Splitting the blow among
  hundreds of wallets in one transaction can exceed a block; only whoever holds it can do that.
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
- The keeper is immutable: a lost keeper key sends the treasury to a wallet nobody controls and stops new
  abilities (the last active one stays in force).

## Credits

The fee, claim and pool-binding machinery is adapted from launch-784 (the WIN hook), MIT licensed.
