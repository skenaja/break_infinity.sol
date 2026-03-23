# break_infinity_sol

Solidity port of [break_infinity.js](https://github.com/Patashu/break_infinity.js) —
arbitrary-scale fixed-point decimals optimised for on-chain incremental / idle-game mechanics.

## Commands

`forge` is not on PATH; use the full path:

```sh
~/.foundry/bin/forge build
~/.foundry/bin/forge test
~/.foundry/bin/forge test -vvv                  # verbose (shows revert reasons)
~/.foundry/bin/forge test --match-test <name>   # single test
~/.foundry/bin/forge snapshot                   # update gas snapshots
~/.foundry/bin/forge fmt                        # format sources
```

## Architecture

All logic lives in two pure Solidity libraries — no contracts, no storage, no deployment needed.

```
src/
  interfaces/IDecimalErrors.sol   custom errors (imported by Decimal)
  DecimalMath.sol                 fixed-point primitives: mulDiv, log10Fixed, exp10Fixed
  Decimal.sol                     main library — D struct + every public operation
```

### Data representation

```
D { uint128 mantissa,  int64 exponent,  bool negative }
  value = sign × (mantissa / 1e18) × 10^exponent
```

- Packed into one 256-bit slot (128 + 64 + 8 + 56 padding).
- Mantissa is **always normalised** to `[1e18, 10e18)`, or `0` for zero.
- Exponent range: `±9e15` (mirrors the JS original's `EXP_LIMIT`).
- `MANTISSA_SCALE = 1e18` is the fixed-point basis throughout.

### DecimalMath primitives

| Function | Purpose |
|---|---|
| `mulDiv(a, b, denom)` | 512-bit intermediate multiply-then-divide (Uniswap FullMath pattern) |
| `mulFixed(a, b)` | `a * b / 1e18` for mantissa multiplication |
| `divFixed(a, b)` | `a * 1e18 / b` for mantissa division |
| `log10Fixed(x)` | `log10(x)` as a signed 1e18-scaled fixed-point result |
| `exp10Fixed(x)` | `10^x` as a 1e18-scaled fixed-point result |
| `floorLog10(x)` | `floor(log10(x))` for plain integers (used in normalization) |

### Implementation phases (in dependency order)

| Phase | What | Key dependency |
|---|---|---|
| A | `normalize`, `fromUint`, `fromInt` | none |
| B | Comparison (`cmp`, `eq`, `lt` …) | A |
| C | `neg`, `abs`, `sign` | A |
| D | `add`, `sub` | A–C |
| E | `mul`, `div`, `recip` + `mulDiv` | A–C |
| F | `sqrt`, `pow`, `cbrt`, `sqr`, `cube` + `log10Fixed`, `exp10Fixed` | E |
| G | `log10`, `log2`, `ln`, `log` | F |
| H | `floor`, `ceil`, `round`, `trunc` | A–B |
| I | `exp` | F–G |
| J | Hyperbolic (`sinh` … `atanh`) — low priority | I |
| K | Game economy helpers | F–G |
| L | `factorial`, `pLog10`, `absLog10`, `decimalPlaces` | F–G |

Always implement and test one phase fully before starting the next.

## Testing

Tests live in `test/`. Cross-check expected values against the JS reference:

```sh
node -e "const D = require('./break_infinity.js'); console.log(D.fromNumber(42).log10().toNumber())"
```

**Invariants to fuzz:**
- `a - a == 0`
- `a * b == b * a` (commutativity)
- `10^log10(a) ≈ a` (round-trip)
- `a + b - b ≈ a`

Gas targets (rough): `add` < 5k, `mul` < 3k, `pow` < 15k.
Run `forge snapshot` after every phase and commit the `.gas-snapshot` file.

## Conventions

- All functions are `internal pure` — no state, no events.
- `D` structs are always passed and returned **by memory value**.
- Use `revert("not implemented")` as the placeholder body for stubs.
- Do not add Solidity `// @notice` comments to functions that already have NatSpec in the source.
- Precision target: ≤ 1 ULP error (relative ≤ 1e-9) for transcendental functions.
