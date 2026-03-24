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

        if (shift == 0) {
            // Mantissa already normal; still enforce exponent bounds.
            if (int256(d.exponent) >  int256(EXP_LIMIT)) revert IDecimalErrors.Decimal__ExponentOverflow(d.exponent);
            if (int256(d.exponent) < -int256(EXP_LIMIT)) return D({mantissa: 0, exponent: 0, negative: false});
            return d;
        }

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
    ///
    /// @dev Both inputs are normalized so mantissas are in [SCALE, 10*SCALE).
    ///      mulFixed(a.mantissa, b.mantissa) = a.mantissa * b.mantissa / 1e18
    ///      is in [1e18, ~100e18) — normalize adjusts the exponent by 0 or 1.
    ///      Exponents are in [-EXP_LIMIT, EXP_LIMIT] so their sum fits in int64.
    function mul(D memory a, D memory b) internal pure returns (D memory) {
        if (a.mantissa == 0 || b.mantissa == 0) return zero();
        uint128 newMantissa = uint128(DecimalMath.mulFixed(uint256(a.mantissa), uint256(b.mantissa)));
        int64   newExp      = a.exponent + b.exponent;
        bool    newNeg      = a.negative != b.negative;
        return normalize(D({mantissa: newMantissa, exponent: newExp, negative: newNeg}));
    }

    /// @notice a / b
    ///
    /// @dev divFixed(a.mantissa, b.mantissa) = a.mantissa * 1e18 / b.mantissa
    ///      is in (~1e17, 1e19) — normalize adjusts the exponent by -1 or 0.
    function div(D memory a, D memory b) internal pure returns (D memory) {
        if (b.mantissa == 0) revert IDecimalErrors.Decimal__DivisionByZero();
        if (a.mantissa == 0) return zero();
        uint128 newMantissa = uint128(DecimalMath.divFixed(uint256(a.mantissa), uint256(b.mantissa)));
        int64   newExp      = a.exponent - b.exponent;
        bool    newNeg      = a.negative != b.negative;
        return normalize(D({mantissa: newMantissa, exponent: newExp, negative: newNeg}));
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

    /// @notice base^exp — uses log10 + exp10 strategy.
    ///         base^0 = 1; 0^x = 0.
    ///
    /// @dev Algorithm:
    ///      1. log10(|base|) = base.exponent + log10(base.mantissa / SCALE)
    ///         The second term is in [0,1) and is passed unnormalized to add(),
    ///         which normalises the sum automatically.
    ///      2. t = exponent × log10(|base|)
    ///      3. Split t = floor(t) + frac(t), frac ∈ [0,1).
    ///      4. result.mantissa = exp10Fixed(frac × SCALE)
    ///         result.exponent = floor(t)
    ///      For negative base the sign is preserved only when exponent is a small
    ///      odd integer (≤ 17 decimal digits); non-integer exponents return positive.
    function pow(D memory base, D memory exponent) internal pure returns (D memory) {
        if (base.mantissa == 0) return zero();
        if (exponent.mantissa == 0) return one();

        bool baseNeg = base.negative;
        // Do NOT write back to base — memory structs are passed by reference and
        // mutating base.negative would corrupt the caller's variable.

        // log10(|base|) = base.exponent + log10(base.mantissa / SCALE)
        // log10Fixed returns a value in [0, SCALE) for mantissa ∈ [SCALE, 10*SCALE)
        uint256 logFrac = uint256(DecimalMath.log10Fixed(uint256(base.mantissa)));
        // D{logFrac, 0} is an unnormalized D representing logFrac/SCALE ∈ [0,1).
        // add() normalises the combined result, so we skip an explicit normalize() here.
        D memory logBase = add(
            fromInt(int256(base.exponent)),
            D({mantissa: uint128(logFrac), exponent: 0, negative: false})
        );

        // t = exponent × log10(base)
        D memory t = mul(exponent, logBase);

        // Decompose t into floor(t) and frac(t) × SCALE
        (int64 newExp, uint256 fracFixed) = _splitFloorFrac(t);

        // result mantissa = 10^frac
        uint128 newMantissa = uint128(DecimalMath.exp10Fixed(int256(fracFixed)));

        // Sign: negative base ^ odd-integer exponent → negative result
        bool newNeg = baseNeg && _isOddIntegerD(exponent);

        return normalize(D({mantissa: newMantissa, exponent: newExp, negative: newNeg}));
    }

    /// @dev Decompose a D into (floor(d), frac(d) × MANTISSA_SCALE).
    ///      fracFixed ∈ [0, MANTISSA_SCALE).
    function _splitFloorFrac(D memory t)
        private
        pure
        returns (int64 intPart, uint256 fracFixed)
    {
        if (t.mantissa == 0) return (0, 0);

        uint256 m = uint256(t.mantissa); // ∈ [SCALE, 10*SCALE)
        int64   e = t.exponent;
        uint256 magInt;
        uint256 magFrac; // ∈ [0, SCALE)

        if (e >= 18) {
            // |t| is a pure integer: m × 10^(e−18)
            uint256 shift = uint256(int256(e) - 18);
            // Guard against overflow: result > EXP_LIMIT means normalize will revert.
            // Using 18 as cap keeps us within uint256 without calling pow10 unsafely.
            magInt  = shift > 18
                ? uint256(int256(type(int64).max)) + 1 // sentinel — normalize will revert
                : m * DecimalMath.pow10(shift);
            magFrac = 0;
        } else if (e >= 0) {
            // |t| ∈ [1, 10^19): split integer and fractional parts
            uint256 scale = DecimalMath.pow10(uint256(int256(18) - int256(e)));
            magInt  = m / scale;
            magFrac = (m % scale) * DecimalMath.pow10(uint256(int256(e)));
        } else {
            // e < 0: |t| < 1 — no integer part
            magInt  = 0;
            uint256 abse = uint256(-int256(e));
            // For abse > 18: |t| < 1e-18, frac × SCALE < 1 → rounds to 0.
            magFrac = abse > 18 ? 0 : m / DecimalMath.pow10(abse);
        }

        uint256 maxSafe = uint256(int256(type(int64).max));
        if (!t.negative) {
            intPart   = magInt > maxSafe ? type(int64).max : int64(int256(magInt));
            fracFixed = magFrac;
        } else {
            if (magFrac == 0) {
                intPart   = magInt > maxSafe ? type(int64).min : -int64(int256(magInt));
                fracFixed = 0;
            } else {
                uint256 negMag = magInt + 1;
                intPart   = negMag > maxSafe ? type(int64).min : -int64(int256(negMag));
                fracFixed = uint256(MANTISSA_SCALE) - magFrac;
            }
        }
    }

    /// @dev Returns true if d represents an odd positive integer with ≤ 18 significant digits.
    function _isOddIntegerD(D memory d) private pure returns (bool) {
        if (d.negative)     return false; // only positive integer exponents tracked
        if (d.exponent < 0) return false; // fractional value
        if (d.exponent > 17) return false; // too large — TODO: use last digit
        uint256 m     = uint256(d.mantissa);
        uint256 scale = DecimalMath.pow10(uint256(int256(18) - int256(d.exponent)));
        if (m % scale != 0) return false;  // has fractional part
        return (m / scale) % 2 == 1;
    }

    /// @notice Square root
    ///
    /// @dev Mirrors break_infinity.js sqrt():
    ///      Real value = (m/1e18) × 10^e.
    ///      Even e: sqrt = sqrt(m/1e18) × 10^(e/2)
    ///               → new mantissa field = isqrt(m) × 1e9, newExp = e/2
    ///      Odd  e: absorb one factor of 10 into the mantissa:
    ///               sqrt = sqrt(10×m/1e18) × 10^(floor(e/2))
    ///               → new mantissa field = isqrt(10×m) × 1e9, newExp = (e−1)/2
    ///      Negative numbers revert; zero returns zero.
    function sqrt(D memory a) internal pure returns (D memory) {
        if (a.mantissa == 0) return zero();
        if (a.negative) revert IDecimalErrors.Decimal__NegativeSqrt();

        uint128 newMantissa;
        int64   newExp;

        if (a.exponent % 2 == 0) {
            // Even exponent.
            // newMantissa = sqrt(m/1e18) * 1e18 = sqrt(m * 1e18)
            // m ∈ [1e18, 10e18)  →  m*1e18 ∈ [1e36, 10e36)
            // isqrt ∈ [1e18, ~3.162e18) ✓
            newMantissa = uint128(_isqrt(uint256(a.mantissa) * 1e18));
            newExp      = a.exponent / 2;
        } else {
            // Odd exponent — absorb one factor of 10 into the mantissa.
            // newMantissa = sqrt(10*m/1e18) * 1e18 = sqrt(10*m*1e18)
            // 10*m ∈ [10e18, 100e18)  →  10*m*1e18 ∈ [1e37, 1e38) — no overflow ✓
            // isqrt ∈ [~3.162e18, 1e19) ✓
            // For negative odd e: Solidity truncates toward zero, so use (e−1)/2 = floor.
            newMantissa = uint128(_isqrt(uint256(a.mantissa) * 10 * 1e18));
            newExp      = (a.exponent - 1) / 2;
        }

        return normalize(D({mantissa: newMantissa, exponent: newExp, negative: false}));
    }

    /// @dev Integer square root — Babylonian / Newton's method, rounds down.
    function _isqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x >> 1) + 1;
        while (z < y) {
            y = z;
            z = (x / z + z) >> 1;
        }
    }

    /// @notice Cube root — exact for perfect cubes; ≤ 1 ULP error otherwise.
    ///         Negative inputs return a negative result.
    ///
    /// @dev Mirrors break_infinity.js cbrt():
    ///      mod = exponent % 3.  Absorb 10^k into the mantissa so the
    ///      remaining exponent is exactly divisible by 3:
    ///        mod ==  0          → k = 0 (no absorption)
    ///        mod ==  1, mod == -2 → k = 1 (absorb one factor of 10)
    ///        mod ==  2, mod == -1 → k = 2 (absorb two factors of 10)
    ///      Then newMantissa = icbrt(k_scaled_mantissa * 1e36)
    ///           newExp      = (exponent − k) / 3
    ///      (exact division guaranteed by construction).
    function cbrt(D memory a) internal pure returns (D memory) {
        if (a.mantissa == 0) return zero();

        int256 mod = a.exponent % 3;
        uint256 k;
        if (mod == 1 || mod == -2) {
            k = 1;
        } else if (mod == 2 || mod == -1) {
            k = 2;
        }
        // else k = 0 (mod == 0)

        // Scale mantissa by 10^k, then compute icbrt(scaled * 1e36).
        // Max input to icbrt: 10e18 * 100 * 1e36 = 1e57 < uint256.max ✓
        uint256 scaled  = uint256(a.mantissa) * DecimalMath.pow10(k);
        uint128 newMant = uint128(_icbrt(scaled * 1e36));
        int64   newExp  = int64((int256(a.exponent) - int256(k)) / 3);

        return normalize(D({mantissa: newMant, exponent: newExp, negative: a.negative}));
    }

    /// @dev Integer cube root — Babylonian Newton's method, rounds down.
    ///      Input range for this library: x ∈ [1e54, 1e57).
    ///      Starts at 1e19 (guaranteed overestimate) and converges downward.
    function _icbrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        unchecked {
            y = 1e19; // cbrt(x) < 1e19 for all x < 1e57
            uint256 z = (2 * y + x / (y * y)) / 3;
            while (z < y) {
                y = z;
                z = (2 * y + x / (y * y)) / 3;
            }
            // Floor adjustment (Newton lands on floor or floor+1)
            while (y * y * y > x) y--;
        }
    }

    function sqr(D memory a)  internal pure returns (D memory) { return mul(a, a); }
    function cube(D memory a) internal pure returns (D memory) { return mul(a, sqr(a)); }

    // ── Logarithms ────────────────────────────────────────────────────────────

    /// @notice log10(a) — core log, others derive from this
    /// @notice log10(a).  Reverts for a <= 0.
    ///
    /// @dev log10(mantissa * 10^exponent) = exponent + log10(mantissa / SCALE)
    ///      The second term is in [0, 1) and is represented by an unnormalized D
    ///      with exponent 0; add() + normalize() produce a correct result.
    function log10(D memory a) internal pure returns (D memory) {
        if (a.mantissa == 0) revert IDecimalErrors.Decimal__InvalidInput();
        if (a.negative)      revert IDecimalErrors.Decimal__NegativeLog();

        // Fractional part: log10(mantissa / SCALE) * SCALE ∈ [0, SCALE)
        uint256 fracScaled = uint256(DecimalMath.log10Fixed(uint256(a.mantissa)));
        D memory intPart   = fromInt(int256(a.exponent));

        // Fast path: exact power of 10 (mantissa == SCALE → fracScaled == 0)
        if (fracScaled == 0) return intPart;

        // D{fracScaled, 0} is unnormalized (fracScaled < SCALE).
        // add() short-circuits on zero intPart, so wrap in normalize().
        return normalize(add(intPart,
            D({mantissa: uint128(fracScaled), exponent: 0, negative: false})));
    }

    /// @notice log2(a) = log10(a) / log10(2).  Reverts for a <= 0.
    function log2(D memory a) internal pure returns (D memory) {
        D memory l = log10(a);
        if (l.mantissa == 0) return zero(); // a == 1
        // log10(2) = 0.30102999566... → D{3_010_299_956_639_811_952, -1, false}
        return div(l, D({mantissa: 3_010_299_956_639_811_952, exponent: -1, negative: false}));
    }

    /// @notice ln(a) = log10(a) / log10(e).  Reverts for a <= 0.
    function ln(D memory a) internal pure returns (D memory) {
        D memory l = log10(a);
        if (l.mantissa == 0) return zero(); // a == 1
        // log10(e) = 0.43429448190... → D{4_342_944_819_032_518_277, -1, false}
        return div(l, D({mantissa: 4_342_944_819_032_518_277, exponent: -1, negative: false}));
    }

    /// @notice log_base(a) = log10(a) / log10(base).
    ///         Reverts for a <= 0, base <= 0, or base == 1.
    function log(D memory a, D memory base) internal pure returns (D memory) {
        D memory logA    = log10(a);     // reverts if a <= 0
        D memory logBase = log10(base);  // reverts if base <= 0
        if (logBase.mantissa == 0)       // base == 1: log undefined
            revert IDecimalErrors.Decimal__InvalidInput();
        if (logA.mantissa == 0) return zero(); // a == 1: result is 0 for any base
        return div(logA, logBase);
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

    /// @notice Round toward −∞.
    function floor(D memory a) internal pure returns (D memory) {
        if (a.mantissa == 0) return zero();
        if (a.exponent >= 18) return a; // m × 10^(e−18) is already an exact integer
        // e < 0: 0 < |a| < 1. _splitFloorFrac truncates magFrac to 0 for |e| > 18,
        // so handle this range directly: floor rounds toward −∞.
        if (a.exponent < 0) return a.negative ? fromInt(-1) : zero();
        (int64 intPart, ) = _splitFloorFrac(a);
        return fromInt(intPart);
    }

    /// @notice Round toward +∞.
    function ceil(D memory a) internal pure returns (D memory) {
        if (a.mantissa == 0) return zero();
        if (a.exponent >= 18) return a;
        // e < 0: 0 < |a| < 1. ceil rounds toward +∞.
        if (a.exponent < 0) return a.negative ? zero() : fromInt(1);
        (int64 intPart, uint256 fracFixed) = _splitFloorFrac(a);
        if (fracFixed == 0) return fromInt(intPart);
        return fromInt(int256(intPart) + 1);
    }

    /// @notice Round to nearest integer, ties round toward +∞ (matches JS Math.round).
    function round(D memory a) internal pure returns (D memory) {
        if (a.mantissa == 0) return zero();
        if (a.exponent >= 18) return a;
        (int64 intPart, uint256 fracFixed) = _splitFloorFrac(a);
        if (fracFixed < uint256(MANTISSA_SCALE) / 2) return fromInt(intPart);
        return fromInt(int256(intPart) + 1);
    }

    /// @notice Round toward zero (drop the fractional part).
    function trunc(D memory a) internal pure returns (D memory) {
        if (a.mantissa == 0) return zero();
        if (a.exponent >= 18) return a;
        (int64 intPart, uint256 fracFixed) = _splitFloorFrac(a);
        if (!a.negative || fracFixed == 0) return fromInt(intPart);
        return fromInt(int256(intPart) + 1); // step toward zero for negative fractions
    }

    // ── Exponential ───────────────────────────────────────────────────────────

    /// @notice e^a
    function exp(D memory a) internal pure returns (D memory) {
        return pow(D({mantissa: 2_718_281_828_459_045_235, exponent: 0, negative: false}), a);
    }

    // ── Hyperbolic ────────────────────────────────────────────────────────────

    /// @dev Shared helper: compute (exp(a), exp(-a)) in one place.
    function _expPair(D memory a)
        private pure
        returns (D memory ePos, D memory eNeg)
    {
        ePos = exp(a);
        eNeg = exp(D({mantissa: a.mantissa, exponent: a.exponent, negative: !a.negative}));
    }

    /// @dev Divide by the integer 2.
    function _half(D memory a) private pure returns (D memory) {
        return div(a, D({mantissa: 2 * uint128(MANTISSA_SCALE), exponent: 0, negative: false}));
    }

    /// @notice (exp(a) + exp(-a)) / 2  — always >= 1
    function cosh(D memory a) internal pure returns (D memory) {
        (D memory ep, D memory en) = _expPair(a);
        return _half(add(ep, en));
    }

    /// @notice (exp(a) - exp(-a)) / 2  — sign matches a
    function sinh(D memory a) internal pure returns (D memory) {
        (D memory ep, D memory en) = _expPair(a);
        return _half(sub(ep, en));
    }

    /// @notice sinh(a) / cosh(a)  — result in (-1, 1)
    /// @dev Uses exp(2a) form to avoid cancellation for large |a|.
    function tanh(D memory a) internal pure returns (D memory) {
        // tanh = (e^2a - 1) / (e^2a + 1)
        D memory e2a = exp(add(a, a));
        D memory one = D({mantissa: uint128(MANTISSA_SCALE), exponent: 0, negative: false});
        return div(sub(e2a, one), add(e2a, one));
    }

    /// @notice ln(a + sqrt(a^2 + 1))  — defined for all real a
    function asinh(D memory a) internal pure returns (D memory) {
        // sqrt(a^2 + 1) — a^2 is always non-negative, so a^2+1 >= 1 > 0
        D memory a2p1 = add(sqr(a), D({mantissa: uint128(MANTISSA_SCALE), exponent: 0, negative: false}));
        return ln(add(a, sqrt(a2p1)));
    }

    /// @notice ln(a + sqrt(a^2 - 1))  — requires a >= 1
    function acosh(D memory a) internal pure returns (D memory) {
        // Domain: a >= 1  ↔  !a.negative && (a.exponent > 0 || a.mantissa >= MANTISSA_SCALE)
        // Simplest check: a must be >= 1, i.e. not negative and value >= 1.
        // Value >= 1 iff exponent >= 1 OR (exponent == 0 AND mantissa >= MANTISSA_SCALE).
        // Since mantissa is always >= MANTISSA_SCALE when nonzero, value >= 1 iff !negative && exponent >= 0.
        if (a.negative || a.exponent < 0)
            revert IDecimalErrors.Decimal__InvalidInput();
        // a^2 - 1: since a >= 1, a^2 >= 1, result >= 0; safe for sqrt.
        D memory a2m1 = sub(sqr(a), D({mantissa: uint128(MANTISSA_SCALE), exponent: 0, negative: false}));
        return ln(add(a, sqrt(a2m1)));
    }

    /// @notice ln((1+a)/(1-a)) / 2  — requires |a| < 1
    function atanh(D memory a) internal pure returns (D memory) {
        // Domain: |a| < 1  ↔  a.exponent < 0  OR  (a.exponent == 0 is impossible since
        // mantissa >= SCALE means |value| >= 1 when exponent == 0).
        // So |a| < 1 iff a.exponent < 0 (or a is zero).
        if (a.mantissa != 0 && a.exponent >= 0)
            revert IDecimalErrors.Decimal__InvalidInput();
        D memory one  = D({mantissa: uint128(MANTISSA_SCALE), exponent: 0, negative: false});
        D memory oneP = add(one, a);   // 1 + a
        D memory oneM = sub(one, a);   // 1 - a
        return _half(ln(div(oneP, oneM)));
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
