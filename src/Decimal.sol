// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DecimalMath} from "./DecimalMath.sol";
import {IDecimalErrors} from "./interfaces/IDecimalErrors.sol";

/// @title Decimal
/// @author break_infinity_sol contributors
/// @notice Solidity port of break_infinity.js — arbitrary-scale numbers for
///         on-chain incremental / idle-game mechanics.
///
/// @dev ═══════════════════════════════════════════════════════════════════════
///      DATA REPRESENTATION
///      ═══════════════════════════════════════════════════════════════════════
///      Every value is stored as:
///
///          value = (negative ? -1 : 1)  ×  (mantissa / MANTISSA_SCALE)  ×  10^exponent
///
///      where:
///        • mantissa  – uint128, in range [MANTISSA_SCALE, 10*MANTISSA_SCALE)
///                      i.e. the "real" mantissa is in [1, 10).
///                      Exception: mantissa == 0 encodes zero.
///        • exponent  – int64,   in range [-EXP_LIMIT, EXP_LIMIT]
///        • negative  – bool,    sign flag (false = positive)
///
///      Packing: the three fields are stored in a single `D` struct.
///      The struct is passed by value (stack/memory); the library exposes only
///      pure / view functions so it integrates without storage overhead.
///
///      ───────────────────────────────────────────────────────────────────────
///      WHY NOT uint256 FOR THE MANTISSA?
///      ───────────────────────────────────────────────────────────────────────
///      uint128 is sufficient (10 * 1e18 < 2^64 is false; 10e18 ≈ 1e19 < 2^64
///      is also false; 10e18 < 2^128 is true with enormous headroom).  We keep
///      uint128 to allow struct packing into one 256-bit slot.
///
///      ───────────────────────────────────────────────────────────────────────
///      CONSTANTS
///      ───────────────────────────────────────────────────────────────────────
///        MANTISSA_SCALE      = 1e18         (fixed-point basis)
///        MAX_SIGNIFICANT_DIGITS = 17        (digits before smaller term is insignificant)
///        EXP_LIMIT           = 9e15         (mirrors JS original)
///        NUMBER_EXP_MAX      = 308          (max native float exponent)
///        NUMBER_EXP_MIN      = -324         (min native float exponent)
///
///      ═══════════════════════════════════════════════════════════════════════
///      IMPLEMENTATION PHASES
///      ═══════════════════════════════════════════════════════════════════════
///
///      Phase A – Core struct + normalization
///        1. Define D struct (mantissa uint128, exponent int64, negative bool).
///        2. fromParts(): raw constructor; calls normalize().
///        3. normalize(): ensure mantissa ∈ [MANTISSA_SCALE, 10*MANTISSA_SCALE)
///           by shifting the exponent, or set both to 0 for zero.
///        4. ZERO, ONE, NEG_ONE sentinel helpers.
///
///      Phase B – Comparison
///        5.  cmp(a, b) → int8 (-1, 0, 1)
///        6.  eq, lt, lte, gt, gte as wrappers.
///        7.  max, min, clamp, clampMin, clampMax.
///
///      Phase C – Sign / absolute value
///        8.  neg(a), abs(a), sign(a).
///
///      Phase D – Addition & Subtraction
///        9.  add(a, b): align exponents, add mantissas, renormalize.
///        10. sub(a, b): negate b, call add.
///        Key edge case: if |exp_a - exp_b| > MAX_SIGNIFICANT_DIGITS,
///        return the larger-magnitude operand unchanged.
///
///      Phase E – Multiplication & Division
///        11. mul(a, b): multiply mantissas (via DecimalMath.mulFixed),
///            add exponents, renormalize.
///        12. div(a, b): divide mantissas (via DecimalMath.divFixed),
///            subtract exponents, renormalize.
///        13. recip(a): ONE / a.
///
///      Phase F – Power & roots
///        14. pow10(n): fast path — return D{1e18, int64(n), false}.
///        15. pow(base, exp): use log-multiply: 10^(exp * log10(base)).
///            Requires DecimalMath.log10Fixed + DecimalMath.exp10Fixed.
///        16. sqrt(a): pow(a, 0.5) or Newton's method for small exponents.
///        17. cbrt(a): pow(a, 1/3).
///        18. sqr(a), cube(a): mul(a,a), mul(a, sqr(a)).
///
///      Phase G – Logarithms
///        19. log10(a) = D{ mantissa_of_log10_mantissa + exponent, 0, ... }
///            (pure arithmetic, no transcendental needed for integer exponent part)
///        20. log2(a)  = log10(a) / log10(2)
///        21. ln(a)    = log10(a) / log10(e)
///        22. log(a, base) = log10(a) / log10(base)
///
///      Phase H – Rounding
///        23. floor, ceil, round, trunc.
///            Strategy: if exponent >= 17, value is already an integer.
///            Otherwise reconstruct the integer part.
///
///      Phase I – Exponential
///        24. exp(a) = e^a = pow(E_CONSTANT, a).
///
///      Phase J – Hyperbolic (optional / low priority)
///        25. sinh, cosh, tanh, asinh, acosh, atanh.
///
///      Phase K – Game economy helpers
///        26. affordGeometricSeries
///        27. sumGeometricSeries
///        28. affordArithmeticSeries
///        29. sumArithmeticSeries
///        30. efficiencyOfPurchase
///
///      Phase L – Misc
///        31. factorial(n): Stirling's approximation for large n.
///        32. pLog10(a): max(0, log10(a)).
///        33. absLog10(a): log10(abs(a)).
///        34. dp() / decimalPlaces(): meaningful decimal places.
///
///      ═══════════════════════════════════════════════════════════════════════
library Decimal {
    using DecimalMath for uint256;

    // ── Constants ─────────────────────────────────────────────────────────────

    uint128 internal constant MANTISSA_SCALE = 1e18;
    uint128 internal constant MANTISSA_MAX   = 10e18; // exclusive upper bound
    int64  internal constant EXP_LIMIT       = 9e15;
    uint8  internal constant MAX_SIGNIFICANT_DIGITS = 17;

    // ── Core struct ───────────────────────────────────────────────────────────

    /// @notice The core Decimal value type.
    /// @dev Fits in exactly 256 bits: 128 (mantissa) + 64 (exponent) + 8 (negative) + 56 padding.
    struct D {
        uint128 mantissa;  // [MANTISSA_SCALE, MANTISSA_MAX) or 0 for zero
        int64   exponent;  // [-EXP_LIMIT, EXP_LIMIT]
        bool    negative;  // sign flag
    }

    // ── Sentinel constants ────────────────────────────────────────────────────

    function zero() internal pure returns (D memory) {
        return D({mantissa: 0, exponent: 0, negative: false});
    }

    function one() internal pure returns (D memory) {
        return D({mantissa: MANTISSA_SCALE, exponent: 0, negative: false});
    }

    function negOne() internal pure returns (D memory) {
        return D({mantissa: MANTISSA_SCALE, exponent: 0, negative: true});
    }

    // ── Construction & normalization ──────────────────────────────────────────

    /// @notice Construct a D from raw mantissa (1e18-scaled), exponent, and sign.
    ///         Normalizes so mantissa ∈ [MANTISSA_SCALE, MANTISSA_MAX).
    function fromParts(uint128 mantissa, int64 exponent, bool negative)
        internal
        pure
        returns (D memory result)
    {
        result = D({mantissa: mantissa, exponent: exponent, negative: negative});
        result = normalize(result);
    }

    /// @notice Normalize: adjust exponent so mantissa ∈ [MANTISSA_SCALE, MANTISSA_MAX).
    ///         If mantissa == 0, returns zero().
    ///
    /// @dev Strategy: compute shift = floorLog10(mantissa) - 18 in one shot.
    ///      If shift > 0: mantissa is too large  → divide by 10^shift, exponent += shift.
    ///      If shift < 0: mantissa is too small  → multiply by 10^|shift|, exponent += shift.
    ///      Exponent overflow reverts; underflow returns zero (value rounds to 0).
    ///
    ///      The math guarantees the output is in range without a second pass:
    ///        mantissa ∈ [10^k, 10^(k+1))  after floorLog10 returns k
    ///        dividing/multiplying by 10^(k-18) maps to [10^18, 10^19) = [SCALE, MAX).
    function normalize(D memory d) internal pure returns (D memory) {
        if (d.mantissa == 0) return D({mantissa: 0, exponent: 0, negative: false});

        int256 mantissaLog = DecimalMath.floorLog10(uint256(d.mantissa));
        int256 shift = mantissaLog - 18; // target: floorLog10(mantissa) == 18

        if (shift == 0) return d;

        int256 newExp = int256(d.exponent) + shift;
        if (newExp >  int256(EXP_LIMIT)) revert IDecimalErrors.Decimal__ExponentOverflow(int64(newExp));
        if (newExp < -int256(EXP_LIMIT)) return D({mantissa: 0, exponent: 0, negative: false});

        uint128 newMantissa;
        if (shift > 0) {
            newMantissa = uint128(uint256(d.mantissa) / DecimalMath.pow10(uint256(shift)));
        } else {
            newMantissa = uint128(uint256(d.mantissa) * DecimalMath.pow10(uint256(-shift)));
        }

        return D({mantissa: newMantissa, exponent: int64(newExp), negative: d.negative});
    }

    // ── fromUint / fromInt ────────────────────────────────────────────────────

    /// @notice Convert a plain uint256 into a D.
    ///
    /// @dev Construction strategy (avoids calling normalize for efficiency):
    ///      1. k = floorLog10(x) — this becomes the exponent.
    ///      2. mantissa = x × 1e18 / 10^k, placing the real mantissa in [1, 10).
    ///         For k < 18 (x < 1e18): multiply first — x × 10^(18−k) never overflows
    ///         uint256 because x < 1e18 and 10^(18−k) ≤ 1e18, product < 1e36 < 2^256.
    ///         For k ≥ 18: use mulDiv for the 512-bit-safe computation.
    function fromUint(uint256 x) internal pure returns (D memory) {
        if (x == 0) return zero();
        int256 k = DecimalMath.floorLog10(x);
        uint128 mantissa;
        if (k < 18) {
            mantissa = uint128(x * DecimalMath.pow10(uint256(18 - uint256(k))));
        } else {
            mantissa = uint128(DecimalMath.mulDiv(x, MANTISSA_SCALE, DecimalMath.pow10(uint256(k))));
        }
        return D({mantissa: mantissa, exponent: int64(k), negative: false});
    }

    /// @notice Convert a signed int256 into a D.
    ///
    /// @dev Uses unchecked negation to handle type(int256).min correctly.
    ///      In checked arithmetic, -type(int256).min overflows int256 (the result 2^255
    ///      exceeds int256.max = 2^255 - 1).  In unchecked two's-complement arithmetic
    ///      the negation wraps back to type(int256).min, and casting that to uint256
    ///      yields 2^255, which is the correct absolute value.
    function fromInt(int256 x) internal pure returns (D memory) {
        if (x == 0) return zero();
        bool isNeg = x < 0;
        uint256 abs_;
        unchecked { abs_ = isNeg ? uint256(-x) : uint256(x); }
        D memory d = fromUint(abs_);
        d.negative = isNeg;
        return d;
    }

    // ── Comparison ────────────────────────────────────────────────────────────

    /// @notice Returns -1 if a < b, 0 if a == b, 1 if a > b.
    ///
    /// @dev Decision tree:
    ///      1. Both zero           → 0
    ///      2. One zero            → sign of the non-zero operand determines result
    ///      3. Opposite signs      → positive > negative
    ///      4. Same sign           → compare magnitude (exponent first, then mantissa)
    ///                               Negate for negatives: larger magnitude = smaller value
    function cmp(D memory a, D memory b) internal pure returns (int8) {
        bool aZero = a.mantissa == 0;
        bool bZero = b.mantissa == 0;

        if (aZero && bZero) return 0;
        if (aZero) return b.negative ? int8(1) : int8(-1);
        if (bZero) return a.negative ? int8(-1) : int8(1);

        // Both non-zero — opposite signs
        if (!a.negative && b.negative) return 1;
        if (a.negative && !b.negative) return -1;

        // Same sign — compare magnitude
        int8 mag;
        if      (a.exponent > b.exponent)  mag =  1;
        else if (a.exponent < b.exponent)  mag = -1;
        else if (a.mantissa > b.mantissa)  mag =  1;
        else if (a.mantissa < b.mantissa)  mag = -1;
        else                               mag =  0;

        // Negative numbers: larger magnitude means smaller value
        return a.negative ? -mag : mag;
    }

    function eq(D memory a, D memory b)  internal pure returns (bool) { return cmp(a,b) == 0; }
    function lt(D memory a, D memory b)  internal pure returns (bool) { return cmp(a,b) < 0;  }
    function lte(D memory a, D memory b) internal pure returns (bool) { return cmp(a,b) <= 0; }
    function gt(D memory a, D memory b)  internal pure returns (bool) { return cmp(a,b) > 0;  }
    function gte(D memory a, D memory b) internal pure returns (bool) { return cmp(a,b) >= 0; }

    function max(D memory a, D memory b) internal pure returns (D memory) {
        return gte(a, b) ? a : b;
    }
    function min(D memory a, D memory b) internal pure returns (D memory) {
        return lte(a, b) ? a : b;
    }
    function clamp(D memory x, D memory lo, D memory hi)
        internal pure returns (D memory)
    {
        return max(lo, min(x, hi));
    }

    function clampMin(D memory x, D memory lo) internal pure returns (D memory) {
        return max(lo, x);
    }

    function clampMax(D memory x, D memory hi) internal pure returns (D memory) {
        return min(x, hi);
    }

    // ── Sign / absolute value ─────────────────────────────────────────────────

    function neg(D memory a) internal pure returns (D memory) {
        if (a.mantissa == 0) return a;
        return D({mantissa: a.mantissa, exponent: a.exponent, negative: !a.negative});
    }

    function abs(D memory a) internal pure returns (D memory) {
        return D({mantissa: a.mantissa, exponent: a.exponent, negative: false});
    }

    /// @return -1, 0, or 1 as a D
    function sign(D memory a) internal pure returns (D memory) {
        if (a.mantissa == 0) return zero();
        return a.negative ? negOne() : one();
    }

    // ── Addition & Subtraction ────────────────────────────────────────────────

    /// @notice a + b
    ///
    /// @dev Algorithm:
    ///   1. Zero short-circuits.
    ///   2. Order by magnitude: big = the operand with larger |value|.
    ///      Exponent determines magnitude; tie-break on mantissa.
    ///   3. expDiff = big.exponent − small.exponent  (always ≥ 0).
    ///      If expDiff > MAX_SIGNIFICANT_DIGITS: small is negligible, return big.
    ///   4. Align: alignedSmall = small.mantissa / 10^expDiff.
    ///   5. Combine:
    ///      • same sign  → newMantissa = big.mantissa + alignedSmall
    ///      • diff sign  → newMantissa = big.mantissa − alignedSmall
    ///                     (exact cancellation → zero)
    ///   6. normalize(D{newMantissa, big.exponent, big.negative})
    function add(D memory a, D memory b) internal pure returns (D memory) {
        // ── Step 1: zero short-circuits ──────────────────────────────────────
        if (a.mantissa == 0) return b;
        if (b.mantissa == 0) return a;

        // ── Step 2: order by magnitude ────────────────────────────────────────
        bool aIsBig = (a.exponent != b.exponent)
            ? a.exponent > b.exponent
            : a.mantissa >= b.mantissa;
        D memory big   = aIsBig ? a : b;
        D memory small = aIsBig ? b : a;

        // ── Step 3: insignificance cutoff ─────────────────────────────────────
        int256 expDiff = int256(big.exponent) - int256(small.exponent);
        if (expDiff > int256(uint256(MAX_SIGNIFICANT_DIGITS))) return big;

        // ── Step 4: align small to big's exponent scale ───────────────────────
        uint128 alignedSmall = uint128(
            uint256(small.mantissa) / DecimalMath.pow10(uint256(expDiff))
        );

        // ── Step 5: combine ───────────────────────────────────────────────────
        uint128 newMantissa;
        if (big.negative == small.negative) {
            // Same sign: magnitudes add.
            // Max sum: ~10e18 + ~10e18 = ~20e18, fits in uint128.
            newMantissa = uint128(uint256(big.mantissa) + uint256(alignedSmall));
        } else {
            // Opposite sign: big always dominates (by construction).
            uint256 diff = uint256(big.mantissa) - uint256(alignedSmall);
            if (diff == 0) return zero();
            newMantissa = uint128(diff);
        }

        // ── Step 6: normalize ─────────────────────────────────────────────────
        return normalize(D({
            mantissa: newMantissa,
            exponent: big.exponent,
            negative: big.negative
        }));
    }

    /// @notice a - b
    function sub(D memory a, D memory b) internal pure returns (D memory) {
        return add(a, neg(b));
    }

    // ── Multiplication & Division ─────────────────────────────────────────────

    /// @notice a * b
    function mul(D memory a, D memory b) internal pure returns (D memory) {
        // TODO: Phase E-11
        //   newMantissa = mulFixed(a.mantissa, b.mantissa)  [intermediate in uint256]
        //   newExponent = a.exponent + b.exponent
        //   newNegative = a.negative XOR b.negative
        //   fromParts(newMantissa, newExponent, newNegative)
        revert("not implemented");
    }

    /// @notice a / b
    function div(D memory a, D memory b) internal pure returns (D memory) {
        // TODO: Phase E-12
        if (b.mantissa == 0) revert IDecimalErrors.Decimal__DivisionByZero();
        revert("not implemented");
    }

    /// @notice 1 / a
    function recip(D memory a) internal pure returns (D memory) {
        return div(one(), a);
    }

    // ── Powers ────────────────────────────────────────────────────────────────

    /// @notice 10^n (integer exponent fast path)
    function pow10(int64 n) internal pure returns (D memory) {
        return D({mantissa: MANTISSA_SCALE, exponent: n, negative: false});
    }

    /// @notice base^exp — uses log10 + exp10 strategy
    function pow(D memory base, D memory exponent) internal pure returns (D memory) {
        // TODO: Phase F-15
        // result = 10^(exponent * log10(base))
        revert("not implemented");
    }

    /// @notice Square root
    function sqrt(D memory a) internal pure returns (D memory) {
        // TODO: Phase F-16
        // Fast path: if exponent is even → sqrt(mantissa) * 10^(exponent/2)
        // Odd exponent: sqrt(mantissa * 10) * 10^((exponent-1)/2)
        revert("not implemented");
    }

    function cbrt(D memory a) internal pure returns (D memory) {
        // TODO: Phase F-17 — pow(a, 1/3)
        revert("not implemented");
    }

    function sqr(D memory a)  internal pure returns (D memory) { return mul(a, a); }
    function cube(D memory a) internal pure returns (D memory) { return mul(a, sqr(a)); }

    // ── Logarithms ────────────────────────────────────────────────────────────

    /// @notice log10(a) — core log, others derive from this
    function log10(D memory a) internal pure returns (D memory) {
        // TODO: Phase G-19
        // log10(m * 10^e) = log10(m) + e
        // log10(m) uses DecimalMath.log10Fixed on the mantissa
        revert("not implemented");
    }

    function log2(D memory a)  internal pure returns (D memory) {
        // TODO: Phase G-20 — log10(a) / log10(2)
        revert("not implemented");
    }

    function ln(D memory a) internal pure returns (D memory) {
        // TODO: Phase G-21 — log10(a) / log10(e)
        revert("not implemented");
    }

    function log(D memory a, D memory base) internal pure returns (D memory) {
        // TODO: Phase G-22 — log10(a) / log10(base)
        revert("not implemented");
    }

    /// @notice log10(|a|)
    function absLog10(D memory a) internal pure returns (D memory) {
        return log10(abs(a));
    }

    /// @notice max(0, log10(a))
    function pLog10(D memory a) internal pure returns (D memory) {
        D memory l = log10(a);
        return lt(l, zero()) ? zero() : l;
    }

    // ── Rounding ──────────────────────────────────────────────────────────────

    function floor(D memory a) internal pure returns (D memory) {
        // TODO: Phase H-23
        revert("not implemented");
    }

    function ceil(D memory a) internal pure returns (D memory) {
        // TODO: Phase H-23
        revert("not implemented");
    }

    function round(D memory a) internal pure returns (D memory) {
        // TODO: Phase H-23
        revert("not implemented");
    }

    function trunc(D memory a) internal pure returns (D memory) {
        // TODO: Phase H-23
        revert("not implemented");
    }

    // ── Exponential ───────────────────────────────────────────────────────────

    /// @notice e^a
    function exp(D memory a) internal pure returns (D memory) {
        // TODO: Phase I-24 — pow(E_CONSTANT, a)
        revert("not implemented");
    }

    // ── Game economy helpers ──────────────────────────────────────────────────

    /// @notice How many items you can afford when costs scale geometrically.
    /// @param budget        Available resources
    /// @param costInitial   Cost of the first item
    /// @param costRatio     Multiplicative cost growth per item (as D, e.g. 1.07)
    /// @param currentOwned  How many items already owned
    /// @return count        Number of additional items purchasable
    function affordGeometricSeries(
        D memory budget,
        D memory costInitial,
        D memory costRatio,
        D memory currentOwned
    ) internal pure returns (D memory count) {
        // TODO: Phase K-26
        // Formula: floor(log(budget / costInitial * (costRatio-1) + costRatio^currentOwned)
        //                / log(costRatio) - currentOwned)
        revert("not implemented");
    }

    /// @notice Total cost of buying `count` items from a geometric series.
    function sumGeometricSeries(
        D memory count,
        D memory costInitial,
        D memory costRatio,
        D memory currentOwned
    ) internal pure returns (D memory total) {
        // TODO: Phase K-27
        // Formula: costInitial * costRatio^currentOwned * (costRatio^count - 1) / (costRatio - 1)
        revert("not implemented");
    }

    /// @notice How many items you can afford when costs increase arithmetically.
    /// @param budget        Available resources
    /// @param costInitial   Cost of the first item
    /// @param costIncrease  Additive cost increase per item
    /// @param currentOwned  How many items already owned
    function affordArithmeticSeries(
        D memory budget,
        D memory costInitial,
        D memory costIncrease,
        D memory currentOwned
    ) internal pure returns (D memory count) {
        // TODO: Phase K-28
        // Uses quadratic formula: n = floor((-b + sqrt(b^2 + 4ac)) / 2a)
        // where a = costIncrease/2, b = costInitial + costIncrease*currentOwned - costIncrease/2
        revert("not implemented");
    }

    /// @notice Total cost of buying `count` items from an arithmetic series.
    function sumArithmeticSeries(
        D memory count,
        D memory costInitial,
        D memory costIncrease,
        D memory currentOwned
    ) internal pure returns (D memory total) {
        // TODO: Phase K-29
        // Formula: count * (costInitial + costIncrease*(currentOwned + (count-1)/2))
        revert("not implemented");
    }

    /// @notice Value metric for a purchase: lower is better.
    ///         efficiencyOfPurchase = cost/currentRate + cost/deltaRate
    function efficiencyOfPurchase(
        D memory cost,
        D memory currentRate,
        D memory deltaRate
    ) internal pure returns (D memory) {
        // TODO: Phase K-30
        return add(div(cost, currentRate), div(cost, deltaRate));
    }

    // ── Miscellaneous ─────────────────────────────────────────────────────────

    /// @notice n! using Stirling's approximation for large n.
    function factorial(D memory n) internal pure returns (D memory) {
        // TODO: Phase L-31
        // For n <= 18: use lookup table of exact values
        // For n > 18: Stirling: n! ≈ sqrt(2πn) * (n/e)^n
        revert("not implemented");
    }

    /// @notice Number of meaningful decimal places (mantissa digits beyond integer part).
    function decimalPlaces(D memory a) internal pure returns (uint256) {
        // TODO: Phase L-34
        revert("not implemented");
    }
}
