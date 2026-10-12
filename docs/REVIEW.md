# Test and size report

Numbers measured on this repository with Foundry 1.8.5, solc 0.8.26, `evm_version = "cancun"`,
optimizer 1000 runs, `via_ir = false`, `bytecode_hash = "none"`, `cbor_metadata = false`.

## Sizes (`forge build --sizes`)

| Contract | Runtime (B) | Initcode (B) | Runtime margin (B) |
|---|---|---|---|
| BossHook | 19,508 | 21,296 | 5,068 |
| BossToken | 1,338 | 1,464 | 23,238 |
| AbilityBoard | 830 | 1,000 | 23,746 |

## Tests (`forge test`)

13 suites, 141 tests passed, 0 failed, 0 skipped. Forge reports the invariant campaign as one test
that holds six invariants.

| Suite | Tests | What it covers |
|---|---|---|
| `BossHook.Fees.t.sol` (x3: BOSS/IMD with BOSS as currency0, with BOSS as currency1, and a native-ETH pair) | 15 each | The 2.5% fee on all four swap shapes (exact in/out x buy/sell), treasury claims paid only to the keeper, the pool pin (wrong currency, fee, spacing, start price, second pool), the 9 flat constructor args |
| `BossHook.Game.t.sol` (x2: BOSS as currency0 and as currency1) | 19 each | Damage, healing, the forfeit on sell, the killing blow, pot split and claims, rollover when nobody is eligible, next-boss HP, buyer attribution through `hookData` and the `tx.origin` fallback, sells credited only to the signer |
| `BossHook.Ability.t.sol` | 9 | Hostile abilities: reverting, gas bomb, short return data, huge values (clamped), state writer, gas starvation (the swap reverts instead of falling back) |
| `BossHook.Registry.t.sol` | 12 | `acceptAbility`: approved and rejected answers, old ids, replays, attestations issued before the proposal, the 12 h delay, one activation per 24 h, expiry, wrong signer |
| `OracleGate.t.sol` | 16 | Every field check, malleable signatures, and a real IMD mainnet attestation whose digest must recover to IMD's signer |
| `AbilityBoard.t.sol` | 5 | Keeper-only proposals, code required, ids |
| `BossMath.t.sol` | 11 | Clamps, scaling, next-boss HP, pot split, with fuzzing (256 runs) |
| `BossToken.t.sol` | 3 | Supply and transfers |
| `BossHook.Gas.t.sol` | 1 | Gas per swap with an active ability |
| `invariant/BossInvariant.t.sol` | 1 | Six invariants, below |

## Invariants

`test/invariant/BossHandler.sol` drives 5 actors doing exact-input and exact-output buys and sells,
time warps, `claimDamage`, `claimKill` and `claimTreasury`, with an ability (`FixedAbility(15000, 7500)`)
active. Campaign: 64 runs x depth 64 = 4,096 calls, 0 reverts.

- Money accounting: the hook's ERC-6909 claims on the pool manager equal pot + treasury owed + reserved prizes,
  and the hook never holds BOSS, raw ETH or raw IMD.
- Fees charged == paid out + treasury paid + claims held.
- HP never exceeds max HP, and max HP stays between 1/4x and 16x the initial HP.
- Closed rounds never overpay: eligible damage == the non-sellers' damage, and damage claims per round
  never exceed that round's damage pool.
- Kill claims never exceed the killer prizes won (paid + unclaimed == won).
- A call summary (log only).

## Gas

`test_gas_buyAndSell_withAbility`, router included, warm pool, with an active ability:

- Buy: 234,211 gas
- Sell: 253,569 gas
