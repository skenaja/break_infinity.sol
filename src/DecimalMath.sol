// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DecimalMath
/// @notice Fixed-point math primitives used internally by the Decimal library.
///
/// @dev All values here operate on a MANTISSA_SCALE = 1e18 fixed-point basis.
///      That is, a "real" value of 1.5 is stored as 1_500_000_000_000_000_000.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// IMPLEMENTATION PLAN
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Phase 1 – log10Fixed / exp10Fixed  (Phase F of Decimal)
///   log10Fixed: integer part from floorLog10; fractional part via degree-6
///   minimax polynomial over [1, 10) scaled to MANTISSA_SCALE.
///   exp10Fixed: split x = n + f; integer part from pow10(n);
///   fractional part 10^f via degree-6 minimax polynomial over [0, 1).
///   Precision target: ≤ 1 ULP relative error (≤ 1e-9).
///
/// ─────────────────────────────────────────────────────────────────────────────
library DecimalMath {
    /// @dev Fixed-point scale: 1e18
    uint256 internal constant MANTISSA_SCALE = 1e18;

    /// @dev log2(10) * 1e18 — used to convert between log2 and log10 fixed-point.
    uint256 internal constant LOG2_10 = 3_321_928_094_887_362_347;

    error DecimalMath__InputZero();
    error DecimalMath__DivisionByZero();
    error DecimalMath__MulDivOverflow();
    error DecimalMath__Pow10Overflow();

    // ── pow10 ────────────────────────────────────────────────────────────────

    /// @notice Computes 10^n as a plain integer. Reverts if n > 77 (overflows uint256).
    /// @dev Uses binary exponentiation. The guard `if (n > 0) base *= base` prevents
    ///      squaring base on the final iteration (avoids overflow for n up to 77).
    function pow10(uint256 n) internal pure returns (uint256 r) {
        if (n > 77) revert DecimalMath__Pow10Overflow();
        unchecked {
            r = 1;
            uint256 base = 10;
            while (n > 0) {
                if (n & 1 == 1) r *= base;
                n >>= 1;
                if (n > 0) base *= base;
            }
        }
    }

    // ── floorLog10 ───────────────────────────────────────────────────────────

    /// @notice Computes floor(log10(x)) for x > 0, where x is a plain integer.
    /// @dev Halving binary search — O(log log x) branches, no multiplication.
    ///      Verified correct for all x in [1, 10^77].
    function floorLog10(uint256 x) internal pure returns (int256 r) {
        if (x == 0) revert DecimalMath__InputZero();
        unchecked {
            if (x >= 10 ** 64) { x /= 10 ** 64; r += 64; }
            if (x >= 10 ** 32) { x /= 10 ** 32; r += 32; }
            if (x >= 10 ** 16) { x /= 10 ** 16; r += 16; }
            if (x >= 10 ** 8)  { x /= 10 ** 8;  r += 8;  }
            if (x >= 10 ** 4)  { x /= 10 ** 4;  r += 4;  }
            if (x >= 10 ** 2)  { x /= 10 ** 2;  r += 2;  }
            if (x >= 10 ** 1)  {                 r += 1;  }
        }
    }

    // ── log10Fixed ───────────────────────────────────────────────────────────

    /// @notice Computes log10(x) as a MANTISSA_SCALE fixed-point signed integer.
    /// @param x A MANTISSA_SCALE-scaled positive value (i.e. real value = x / 1e18).
    /// @return result log10(real value of x), scaled by MANTISSA_SCALE.
    ///
    /// @dev Algorithm: log10(x/1e18) = log2(x/1e18) / log2(10).
    ///      1. integer_part = floorLog10(x) - 18
    ///      2. Normalize m = x / 10^integer_part  →  m ∈ [1e18, 10e18)
    ///      3. Reduce m to [1e18, 2e18) tracking integer log2 bits (0..3)
    ///      4. Bit-squeezing: 30 iterations of square-and-check extract the
    ///         fractional bits of log2(m/1e18) to ~1e-9 relative error
    ///      5. log10 = log2 / LOG2_10   (one mulDiv)
    function log10Fixed(uint256 x) internal pure returns (int256 result) {
        if (x == 0) revert DecimalMath__InputZero();

        // ── Step 1: integer part of log10(x/1e18) ────────────────────────────
        int256 intPart = floorLog10(x) - 18;

        // ── Step 2: normalize to m ∈ [1e18, 10e18) ───────────────────────────
        uint256 m;
        if (intPart > 0) {
            m = x / pow10(uint256(intPart));
        } else if (intPart < 0) {
            m = x * pow10(uint256(-intPart));
        } else {
            m = x;
        }

        // ── Step 3: reduce to [1e18, 2e18) for bit-squeezing ─────────────────
        uint256 mw = m;
        uint256 log2Int;
        if      (mw >= 8 * MANTISSA_SCALE) { mw >>= 3; log2Int = 3; }
        else if (mw >= 4 * MANTISSA_SCALE) { mw >>= 2; log2Int = 2; }
        else if (mw >= 2 * MANTISSA_SCALE) { mw >>= 1; log2Int = 1; }
        // else log2Int = 0; mw already in [1e18, 2e18)

        // ── Step 4: bit-squeezing (30 iterations ≈ 1e-9 error) ───────────────
        // Invariant: mw ∈ [1e18, 2e18) (real value ∈ [1, 2)).
        // Each iteration: square mw; if ≥ 2e18 the next log2 bit is 1 → record it.
        uint256 log2Frac;
        uint256 delta = MANTISSA_SCALE >> 1; // 5e17
        for (uint256 i; i < 30; ++i) {
            mw = mulFixed(mw, mw);          // mw = mw^2 / 1e18
            if (mw >= 2 * MANTISSA_SCALE) {
                log2Frac += delta;
                mw >>= 1;                   // keep mw in [1e18, 2e18)
            }
            delta >>= 1;
        }

        // ── Step 5: convert log2 → log10 ─────────────────────────────────────
        uint256 log2val = log2Int * MANTISSA_SCALE + log2Frac;
        uint256 fracPart = mulDiv(log2val, MANTISSA_SCALE, LOG2_10);

        result = intPart * int256(MANTISSA_SCALE) + int256(fracPart);
    }

    // ── exp10Fixed ───────────────────────────────────────────────────────────

    /// @notice Computes 10^(x/1e18) for x ∈ [0, MANTISSA_SCALE), returning a
    ///         MANTISSA_SCALE-scaled result in [1e18, 10e18).
    ///
    /// @dev Algorithm: 10^f = 2^(f · log2(10)) via greedy binary expansion.
    ///      g = f * LOG2_10 / 1e18  ∈ [0, LOG2_10) ≈ [0, 3.32 · 1e18)
    ///      Split: g_int = g / 1e18 ∈ {0,1,2,3},  g_frac = g % 1e18 ∈ [0, 1e18).
    ///      Expand g_frac in binary: for each bit k, if remaining ≥ 1e18/2^(k+1),
    ///      multiply result by TWO_POW[k] = 2^(1/2^(k+1)) · 1e18 and subtract.
    ///      Final result is multiplied by 2^g_int (bit-shift by g_int).
    ///      30 iterations → ≤ 1e-9 relative error.
    ///
    ///      TWO_POW[k] = floor(2^(1/2^(k+1)) · 1e18), computed by repeated _isqrt.
    function exp10Fixed(int256 x) internal pure returns (uint256 result) {
        require(x >= 0 && uint256(x) < MANTISSA_SCALE, "exp10Fixed: x out of [0,1)");

        // g = x * LOG2_10 / 1e18 — the binary exponent to compute 2^g
        uint256 g     = mulDiv(uint256(x), LOG2_10, MANTISSA_SCALE);
        uint256 gInt  = g / MANTISSA_SCALE;       // 0, 1, 2, or 3
        uint256 gFrac = g % MANTISSA_SCALE;       // [0, 1e18)

        // Greedy binary expansion of g_frac: result = 2^(g_frac / 1e18) * 1e18
        result = MANTISSA_SCALE; // 1.0 in 1e18-scaled
        uint256 rem   = gFrac;
        uint256 delta = MANTISSA_SCALE >> 1; // 5e17 (= 1e18/2)

        // TWO_POW[k] = floor(2^(1/2^(k+1)) * 1e18), k = 0..29
        // Generated by: TWO_POW[0] = _isqrt(2*1e36); TWO_POW[k] = _isqrt(TWO_POW[k-1]*1e18)
        if (rem >= delta) { result = mulFixed(result, 1_414_213_562_373_095_048); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_189_207_115_002_721_066); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_090_507_732_665_257_658); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_044_273_782_427_413_839); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_021_897_148_654_116_677); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_010_889_286_051_700_459); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_005_429_901_112_802_820); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_002_711_275_050_202_484); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_001_354_719_892_108_205); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_677_130_693_066_356); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_338_508_052_682_312); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_169_239_705_302_230); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_084_616_272_694_312); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_042_307_241_395_818); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_021_153_396_964_807); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_010_576_642_549_719); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_005_288_307_291_762); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_002_644_150_150_115); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_001_322_074_201_117); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_000_661_036_882_073); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_000_330_518_386_415); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_000_165_259_179_552); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_000_082_629_586_362); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_000_041_314_792_327); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_000_020_657_395_950); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_000_010_328_697_921); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_000_005_164_348_947); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_000_002_582_174_470); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_000_001_291_087_234); rem -= delta; } delta >>= 1;
        if (rem >= delta) { result = mulFixed(result, 1_000_000_000_645_543_616);               } // k=29, no delta update needed

        // Scale by 2^g_int (g_int ∈ {0,1,2,3} so result stays in [1e18, ~10e18))
        result <<= gInt;
    }

    // ── mulDiv ───────────────────────────────────────────────────────────────

    /// @notice Computes floor(a × b / denominator) with a full 512-bit intermediate,
    ///         rounding toward zero. Reverts on division by zero or result overflow.
    /// @dev Uniswap v3 FullMath algorithm. The result overflows iff denominator ≤ prod1
    ///      (the high 256 bits of a×b), which is checked before the division.
    function mulDiv(uint256 a, uint256 b, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        if (denominator == 0) revert DecimalMath__DivisionByZero();
        unchecked {
            // ── Step 1: 512-bit product [prod1 | prod0] = a * b ──────────────
            uint256 prod0 = a * b;
            uint256 prod1;
            assembly {
                // mulmod(a, b, 2^256) gives the full 256-bit remainder mod 2^256,
                // which equals the high word when combined with prod0.
                let mm := mulmod(a, b, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // ── Step 2: fast path when product fits in 256 bits ──────────────
            if (prod1 == 0) {
                return prod0 / denominator;
            }

            // Result must fit in 256 bits: denominator > prod1.
            if (denominator <= prod1) revert DecimalMath__MulDivOverflow();

            // ── Step 3: subtract remainder to make the division exact ─────────
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // ── Step 4: factor powers of two out of denominator ───────────────
            // twos = lowest set bit of denominator (= denominator & -denominator)
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0       := div(prod0, twos)
                // Merge the upper bits: twos = 2^256 / twos mod 2^256
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // ── Step 5: modular inverse of denominator mod 2^256 ─────────────
            // denominator is now odd; Newton-Raphson (6 iterations doubles precision).
            // Invariant: denominator * inv ≡ 1 (mod 2^k) for increasing k.
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; //  8 bits
            inv *= 2 - denominator * inv; // 16 bits
            inv *= 2 - denominator * inv; // 32 bits
            inv *= 2 - denominator * inv; // 64 bits
            inv *= 2 - denominator * inv; // 128 bits
            inv *= 2 - denominator * inv; // 256 bits

            result = prod0 * inv;
        }
    }

    // ── mulFixed / divFixed ───────────────────────────────────────────────────

    /// @notice Multiplies two MANTISSA_SCALE fixed-point values: (a × b) / 1e18.
    function mulFixed(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulDiv(a, b, MANTISSA_SCALE);
    }

    /// @notice Divides two MANTISSA_SCALE fixed-point values: (a × 1e18) / b.
    function divFixed(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulDiv(a, MANTISSA_SCALE, b);
    }
}
