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
    /// @dev Phase F (Decimal). Stub — reverts until implemented.
    function log10Fixed(uint256 x) internal pure returns (int256 result) {
        if (x == 0) revert DecimalMath__InputZero();
        // TODO: Phase F
        // 1. integer_part = floorLog10(x) - 18  (since x is 1e18-scaled)
        // 2. m = x / 10^(integer_part+18), brings x into [1e18, 10e18)
        // 3. fractional_part = poly(m) — degree-6 minimax polynomial
        //    over m ∈ [1e18, 10e18) mapped to t = (m - MIDPOINT) / RANGE ∈ [-1, 1]
        // 4. return (integer_part * MANTISSA_SCALE) + fractional_part
        revert("not implemented");
    }

    // ── exp10Fixed ───────────────────────────────────────────────────────────

    /// @notice Computes 10^x as a MANTISSA_SCALE fixed-point value.
    /// @param x Signed MANTISSA_SCALE fixed-point exponent (real value = x / 1e18).
    ///          Must satisfy x / 1e18 < 308 (otherwise result overflows uint256).
    /// @return result 10^(x/1e18), scaled by MANTISSA_SCALE.
    /// @dev Phase F (Decimal). Stub — reverts until implemented.
    function exp10Fixed(int256 x) internal pure returns (uint256 result) {
        // TODO: Phase F
        // 1. n = x / int256(MANTISSA_SCALE)       (integer floor, signed)
        // 2. f = x - n * int256(MANTISSA_SCALE)   (fractional part, [0, MANTISSA_SCALE))
        // 3. integer_result = pow10(abs(n)) or its reciprocal if n < 0
        // 4. frac_result    = poly(f)  — degree-6 minimax for 10^(f/1e18) over [0,1)
        // 5. return mulFixed(integer_result, frac_result)
        revert("not implemented");
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
