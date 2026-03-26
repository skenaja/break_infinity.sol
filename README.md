# break_infinity.sol

A Solidity port of [break_infinity.js](https://github.com/Patashu/break_infinity.js) — arbitrary-scale floating-point decimals optimised for on-chain incremental / idle-game mechanics.

Numbers are represented as `sign × (mantissa / 1e18) × 10^exponent`, packing the full range from `10^-9e15` to `10^9e15` into a single 256-bit storage slot. All operations are `internal pure` library calls with no storage, no events, no deployment.

---

## Installation

**npm / Hardhat / Truffle**

```sh
npm install break_infinity.sol
```

Then import directly:

```solidity
import {Decimal} from "break_infinity.sol/Decimal.sol";
```

Hardhat resolves `node_modules` imports by default, so no remapping is needed. If you use a custom sources path, add to `hardhat.config.js`:

```js
paths: { sources: "./contracts" }
```

**Foundry (forge install)**

```sh
forge install skenaja/break_infinity.sol
```

Add a remapping in `foundry.toml`:

```toml
remappings = ["break_infinity.sol/=lib/break_infinity.sol/src/"]
```

**Foundry + npm**

If you prefer npm over git submodules in a Foundry project, install the package and map it:

```sh
npm install break_infinity.sol
```

```toml
# foundry.toml
remappings = ["break_infinity.sol/=node_modules/break_infinity.sol/src/"]
```

**Manual copy**

Copy `src/Decimal.sol`, `src/DecimalMath.sol`, and `src/interfaces/IDecimalErrors.sol` into your project.

---

## Quick start

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Decimal} from "break_infinity.sol/Decimal.sol";

contract IdleGame {
    using Decimal for Decimal.D;

    // Store a D in one slot (128+64+8+56 padding = 256 bits).
    Decimal.D public gold;

    function earn(uint256 amount) external {
        gold = Decimal.add(gold, Decimal.fromUint(amount));
    }

    function canAfford(Decimal.D calldata price) external view returns (bool) {
        return Decimal.gte(gold, price);
    }
}
```

---

## The `D` struct

```solidity
struct D {
    uint128 mantissa;   // always in [1e18, 10e18) when non-zero
    int64   exponent;   // range ±9e15
    bool    negative;
}
```

`value = (negative ? -1 : 1) × (mantissa / 1e18) × 10^exponent`

Construct values with the helper functions — do not set struct fields directly unless you know the mantissa is normalised.

---

## API reference

### Constructors

| Function | Description |
|---|---|
| `zero()` | Returns 0 |
| `one()` | Returns 1 |
| `fromUint(uint256 n)` | Convert a plain integer |
| `fromInt(int256 n)` | Convert a signed integer |
| `fromParts(int256 intPart, uint256 fracPart)` | e.g. `fromParts(3, 14)` → 3.14 |

### Comparison

| Function | Returns |
|---|---|
| `eq(a, b)` | `a == b` |
| `lt(a, b)` | `a < b` |
| `lte(a, b)` | `a <= b` |
| `gt(a, b)` | `a > b` |
| `gte(a, b)` | `a >= b` |
| `cmp(a, b)` | `-1 / 0 / 1` |

### Arithmetic

| Function | Description | Typical gas |
|---|---|---|
| `add(a, b)` | a + b | ~6 k |
| `sub(a, b)` | a − b | ~7 k |
| `mul(a, b)` | a × b | ~6 k |
| `div(a, b)` | a / b | ~8 k |
| `recip(a)` | 1 / a | ~5 k |
| `neg(a)` | −a | < 1 k |
| `abs(a)` | \|a\| | < 1 k |
| `sqr(a)` | a² | ~6 k |

### Powers & roots

| Function | Description | Typical gas |
|---|---|---|
| `sqrt(a)` | √a | ~15 k |
| `cbrt(a)` | ∛a | ~5 k |
| `pow(base, exp)` | base^exp (real exponents) | ~20 k |

### Logarithms & exponential

| Function | Description | Typical gas |
|---|---|---|
| `log10(a)` | log₁₀(a) | ~13 k |
| `log2(a)` | log₂(a) | ~20 k |
| `ln(a)` | natural log | ~15 k |
| `log(a, base)` | log_base(a) | ~30 k |
| `exp(a)` | e^a | ~20 k |
| `pLog10(a)` | max(0, log₁₀(a)) | ~17 k |
| `absLog10(a)` | log₁₀(\|a\|) | ~13 k |

### Rounding

| Function | Description |
|---|---|
| `floor(a)` | Round toward −∞ |
| `ceil(a)` | Round toward +∞ |
| `round(a)` | Round half-up (toward +∞ on tie) |
| `trunc(a)` | Round toward zero |

### Hyperbolic

| Function | Description |
|---|---|
| `sinh(a)` | Hyperbolic sine |
| `cosh(a)` | Hyperbolic cosine |
| `tanh(a)` | Hyperbolic tangent |
| `asinh(a)` | Inverse hyperbolic sine |
| `acosh(a)` | Inverse hyperbolic cosine (requires a ≥ 1) |
| `atanh(a)` | Inverse hyperbolic tangent (requires \|a\| < 1) |

### Game economy helpers

| Function | Description |
|---|---|
| `affordGeometricSeries(budget, costInitial, costRatio, owned)` | Items purchasable with geometric cost scaling |
| `sumGeometricSeries(count, costInitial, costRatio, owned)` | Total cost for `count` items, geometric scaling |
| `affordArithmeticSeries(budget, costInitial, costIncrease, owned)` | Items purchasable with arithmetic cost scaling |
| `sumArithmeticSeries(count, costInitial, costIncrease, owned)` | Total cost for `count` items, arithmetic scaling |
| `efficiencyOfPurchase(cost, currentRate, deltaRate)` | `cost/currentRate + cost/deltaRate` — lower is better |

### Miscellaneous

| Function | Description |
|---|---|
| `factorial(n)` | n! — exact lookup for n ≤ 18, Stirling for n > 18 |
| `decimalPlaces(a)` | Significant fractional decimal digits |
| `sign(a)` | −1, 0, or 1 as `D` |

---

## Precision

All transcendental functions (`pow`, `sqrt`, `log*`, `exp`, hyperbolic) target **≤ 1 ULP** relative error (≤ 1×10⁻⁹). Compound round-trips accumulate proportionally; practical error for a 3–4 op chain stays below 5×10⁻⁹.

Factorial via Stirling+correction has error O(1/n³): ~3×10⁻⁷ at n=20, ~2×10⁻⁹ at n=50.

---

## Gas reference (optimizer 200 runs, via-ir)

| Operation | Gas |
|---|---|
| `add` / `sub` | 5–7 k |
| `mul` / `div` | 6–8 k |
| `sqrt` | ~15 k |
| `pow` | ~20 k |
| `ln` / `log10` | 13–15 k |
| `exp` | ~20 k |
| `cosh` / `sinh` | ~43 k |
| `affordGeometricSeries` | ~40 k |
| `affordArithmeticSeries` | ~40 k |

---

## Error conditions

| Error | When |
|---|---|
| `Decimal__DivisionByZero` | `div` or `recip` with zero denominator |
| `Decimal__ExponentOverflow` | Result exponent exceeds ±9×10¹⁵ |
| `Decimal__InvalidInput` | `sqrt` of negative; `ln`/`log` of non-positive; `acosh(x < 1)`; `atanh(|x| >= 1)` |

---

## Running tests

```sh
~/.foundry/bin/forge test          # 850 tests
~/.foundry/bin/forge test -vvv     # with revert traces
~/.foundry/bin/forge snapshot      # update gas snapshot
```

---

## Architecture

```
src/
  interfaces/IDecimalErrors.sol   custom errors
  DecimalMath.sol                 fixed-point primitives (mulDiv, log10Fixed, exp10Fixed)
  Decimal.sol                     main library — D struct + all operations
```

`DecimalMath` is an independent library of fixed-point primitives and can be used separately if needed.

---

## Acknowledgements

- **[break_infinity.js](https://github.com/Patashu/break_infinity.js)** by Patashu — the original JavaScript library this is a direct port of. All algorithms, data representation, and game economy helpers derive from it.
- **[Uniswap v3 FullMath](https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/FullMath.sol)** — the 512-bit intermediate `mulDiv` implementation used in `DecimalMath`.
- **[mpmath](https://mpmath.org/)** — used to compute the degree-20 minimax polynomial coefficients for the `log2` fractional part at 80-digit precision via Chebyshev-node interpolation.

---
