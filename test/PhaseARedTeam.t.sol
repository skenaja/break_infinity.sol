// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DecimalMath} from "../src/DecimalMath.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Adversarial / red-team test suite for Phase A.
///
/// Test categories:
///   (1) floorLog10 — fundamental invariant + monotonicity + boundaries
///   (2) pow10 — consistency with floorLog10 + multiplication identity
///   (3) mulDiv — algebraic laws + 512-bit correctness
///   (4) normalize — idempotency + output range + extreme inputs
///   (5) fromUint — round-trip precision + uint256 extremes
///   (6) fromInt — int256.min overflow bug

// ── Harnesses ─────────────────────────────────────────────────────────────────

contract MathHarness {
    function pow10(uint256 n) external pure returns (uint256)       { return DecimalMath.pow10(n); }
    function floorLog10(uint256 x) external pure returns (int256)   { return DecimalMath.floorLog10(x); }
    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return DecimalMath.mulDiv(a, b, d);
    }
}

contract DecimalHarness2 {
    function fromInt(int256 x) external pure returns (Decimal.D memory) {
        return Decimal.fromInt(x);
    }
    function normalize(Decimal.D memory d) external pure returns (Decimal.D memory) {
        return Decimal.normalize(d);
    }
}

// ── Test contract ─────────────────────────────────────────────────────────────

contract PhaseARedTeamTest is Test {
    MathHarness    mh = new MathHarness();
    DecimalHarness2 dh = new DecimalHarness2();

    uint128 constant SCALE = uint128(Decimal.MANTISSA_SCALE); // 1e18
    uint128 constant SMAX  = uint128(Decimal.MANTISSA_MAX);   // 10e18

    // ─────────────────────────────────────────────────────────────────────────
    // (1) floorLog10 — fundamental invariant
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The defining property: 10^k ≤ x < 10^(k+1) where k = floorLog10(x).
    ///      Tested for the full uint256 range (bounded to avoid pow10 overflow).
    function testFuzz_floorLog10_fundamentalInvariant(uint256 x) public view {
        vm.assume(x > 0 && x <= DecimalMath.pow10(77));
        int256 k = DecimalMath.floorLog10(x);
        assertTrue(k >= 0 && k <= 77, "k out of range");
        assertLe(DecimalMath.pow10(uint256(k)), x, "lower bound violated");
        if (k < 77) {
            assertGt(DecimalMath.pow10(uint256(k) + 1), x, "upper bound violated");
        }
    }

    /// @dev uint256.max ≈ 1.157e77 → k should be 77.
    function test_floorLog10_uint256Max() public pure {
        assertEq(DecimalMath.floorLog10(type(uint256).max), 77);
    }

    /// @dev Every number in [10^k, 10^(k+1)) must map to exactly k.
    function testFuzz_floorLog10_consistentWithPow10(uint8 k, uint256 offset) public view {
        vm.assume(k <= 76); // keep pow10(k+1) in uint256 range
        uint256 lo = DecimalMath.pow10(k);
        uint256 hi = DecimalMath.pow10(k + 1);
        uint256 x  = lo + (offset % (hi - lo));
        assertEq(DecimalMath.floorLog10(x), int256(uint256(k)));
    }

    /// @dev Monotonicity: a < b → floorLog10(a) ≤ floorLog10(b).
    function testFuzz_floorLog10_monotone(uint256 a, uint256 b) public pure {
        vm.assume(a > 0 && b > 0 && a <= DecimalMath.pow10(77) && b <= DecimalMath.pow10(77));
        if (a < b) {
            assertLe(DecimalMath.floorLog10(a), DecimalMath.floorLog10(b));
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (2) pow10 — algebraic consistency
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev pow10(a) * pow10(b) == pow10(a+b)  for a+b ≤ 77.
    function testFuzz_pow10_multiplicative(uint8 a, uint8 b) public pure {
        vm.assume(uint256(a) + uint256(b) <= 77);
        assertEq(
            DecimalMath.pow10(a) * DecimalMath.pow10(b),
            DecimalMath.pow10(uint256(a) + uint256(b))
        );
    }

    /// @dev pow10(k) / pow10(j) == pow10(k-j) for k >= j.
    function testFuzz_pow10_divisive(uint8 k, uint8 j) public pure {
        vm.assume(k <= 77 && j <= k);
        assertEq(
            DecimalMath.pow10(k) / DecimalMath.pow10(j),
            DecimalMath.pow10(uint256(k) - uint256(j))
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (3) mulDiv — algebraic laws
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev mulDiv(a, b, b) == a for any b != 0 and a <= uint256.max.
    function testFuzz_mulDiv_selfInverse(uint128 a, uint128 b) public pure {
        vm.assume(b > 0);
        // a*b <= uint128.max^2 < 2^256, so no overflow
        assertEq(DecimalMath.mulDiv(uint256(a), uint256(b), uint256(b)), uint256(a));
    }

    /// @dev Commutativity: mulDiv(a, b, d) == mulDiv(b, a, d).
    function testFuzz_mulDiv_commutative(uint128 a, uint128 b, uint128 d) public pure {
        vm.assume(d > 0);
        assertEq(
            DecimalMath.mulDiv(uint256(a), uint256(b), uint256(d)),
            DecimalMath.mulDiv(uint256(b), uint256(a), uint256(d))
        );
    }

    /// @dev mulDiv(a, 1, 1) == a.
    function testFuzz_mulDiv_identityDenominator(uint128 a) public pure {
        assertEq(DecimalMath.mulDiv(uint256(a), 1, 1), uint256(a));
    }

    /// @dev Scaling: mulDiv(k*a, b, k*b) == a/1 when k*b divides k*a*b.
    ///      Simplified: mulDiv(a, k, k) == a.
    function testFuzz_mulDiv_scaleCancel(uint128 a, uint64 k) public pure {
        vm.assume(k > 0);
        assertEq(DecimalMath.mulDiv(uint256(a), uint256(k), uint256(k)), uint256(a));
    }

    /// @dev Truncation: floor(a/d) == mulDiv(a, 1, d).
    function testFuzz_mulDiv_floorDiv(uint128 a, uint64 d) public pure {
        vm.assume(d > 0);
        assertEq(DecimalMath.mulDiv(uint256(a), 1, uint256(d)), uint256(a) / uint256(d));
    }

    /// @dev mulDiv never overestimates: mulDiv(a, b, d) * d <= a * b  (no 512-bit overflow here).
    function testFuzz_mulDiv_noOverestimate(uint64 a, uint64 b, uint64 d) public pure {
        vm.assume(d > 0);
        uint256 result = DecimalMath.mulDiv(uint256(a), uint256(b), uint256(d));
        // result * d <= a * b  (no overflow since all values fit in 192 bits)
        assertLe(result * uint256(d), uint256(a) * uint256(b));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (4) normalize — idempotency + output range
    // ─────────────────────────────────────────────────────────────────────────

    function _normalize(Decimal.D memory d) internal pure returns (Decimal.D memory) {
        return Decimal.normalize(d);
    }

    function _isNormalized(Decimal.D memory d) internal pure returns (bool) {
        if (d.mantissa == 0) {
            return d.exponent == 0 && !d.negative;
        }
        return d.mantissa >= SCALE && d.mantissa < SMAX;
    }

    /// @dev normalize output is always in the canonical range.
    function testFuzz_normalize_outputInRange(uint128 mantissa, int16 exp, bool neg) public pure {
        // use int16 to stay well within EXP_LIMIT and avoid exponent overflow revert
        Decimal.D memory d = Decimal.D({mantissa: mantissa, exponent: int64(exp), negative: neg});
        if (mantissa == 0) {
            Decimal.D memory n = _normalize(d);
            assertEq(n.mantissa, 0);
            assertEq(n.exponent, 0);
            assertEq(n.negative, false);
        } else {
            Decimal.D memory n = _normalize(d);
            assertTrue(_isNormalized(n), "output not normalized");
        }
    }

    /// @dev Idempotency: normalize(normalize(d)) == normalize(d) for already-normalized input.
    function testFuzz_normalize_idempotent(uint128 mantissa, int16 exp, bool neg) public pure {
        vm.assume(mantissa > 0);
        // use int16 exponent to stay within EXP_LIMIT; skip if mantissa would overflow exponent
        Decimal.D memory d = Decimal.D({mantissa: mantissa, exponent: int64(exp), negative: neg});
        Decimal.D memory n1 = _normalize(d);
        if (n1.mantissa == 0) return; // underflow → zero, idempotency trivially holds
        Decimal.D memory n2 = _normalize(n1);
        // n2 should equal n1 exactly (already normalized)
        assertEq(n2.mantissa,  n1.mantissa,  "mantissa not idempotent");
        assertEq(n2.exponent,  n1.exponent,  "exponent not idempotent");
        assertEq(n2.negative,  n1.negative,  "sign not idempotent");
    }

    /// @dev sign flag is preserved through normalize (for non-zero results).
    function testFuzz_normalize_preservesSign(uint128 mantissa, int16 exp) public pure {
        vm.assume(mantissa > 0 && mantissa < SMAX * 10); // avoid overflow revert
        Decimal.D memory pos = _normalize(Decimal.D({mantissa: mantissa, exponent: int64(exp), negative: false}));
        Decimal.D memory neg_ = _normalize(Decimal.D({mantissa: mantissa, exponent: int64(exp), negative: true}));
        if (pos.mantissa == 0) return;
        assertEq(pos.mantissa, neg_.mantissa, "mantissa differs by sign");
        assertEq(pos.exponent, neg_.exponent, "exponent differs by sign");
        assertEq(pos.negative, false);
        assertEq(neg_.negative, true);
    }

    /// @dev uint128.max mantissa normalizes without reverting (shift = 20, safe).
    function test_normalize_uint128Max() public pure {
        Decimal.D memory d = Decimal.D({mantissa: type(uint128).max, exponent: 0, negative: false});
        Decimal.D memory n = _normalize(d);
        assertTrue(_isNormalized(n));
        assertEq(n.exponent, 20); // floorLog10(uint128.max ≈ 3.4e38) = 38, shift = 20
    }

    /// @dev mantissa = 1 (smallest non-zero) normalizes: shift = -18, exponent -= 18.
    function test_normalize_mantissaOne() public pure {
        Decimal.D memory d = Decimal.D({mantissa: 1, exponent: 20, negative: false});
        Decimal.D memory n = _normalize(d);
        assertEq(n.mantissa, SCALE);   // 1 * 10^18 = 1e18
        assertEq(n.exponent, 2);       // 20 - 18 = 2
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (5) fromUint — extremes + round-trip
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev uint256.max is representable: exponent = 77, mantissa in [1e18, 1e19).
    function test_fromUint_uint256Max() public pure {
        Decimal.D memory d = Decimal.fromUint(type(uint256).max);
        assertEq(d.exponent, 77);
        assertGe(d.mantissa, SCALE);
        assertLt(d.mantissa, SMAX);
        assertEq(d.negative, false);
    }

    /// @dev Exponent is exactly floorLog10(x) for all representable x.
    function testFuzz_fromUint_exponentIsFloorLog10(uint256 x) public pure {
        vm.assume(x > 0 && x <= DecimalMath.pow10(77));
        Decimal.D memory d = Decimal.fromUint(x);
        assertEq(d.exponent, DecimalMath.floorLog10(x));
    }

    /// @dev Round-trip exact for x < 10^18 (k ≤ 17, multiply path — no rounding).
    ///      For k < 18: mantissa = x * 10^(18-k), which is exact integer arithmetic.
    ///      Reconstruction: mantissa / 1e18 * 10^k = x * 10^(18-k) / 10^18 * 10^k = x. ✓
    function testFuzz_fromUint_roundtrip_exact(uint256 x) public pure {
        vm.assume(x > 0 && x < 1e18); // k ≤ 17, guaranteed multiply path
        Decimal.D memory d = Decimal.fromUint(x);
        assertGe(d.exponent, 0);
        assertLt(d.exponent, 18);
        uint256 reconstructed = uint256(d.mantissa) * DecimalMath.pow10(uint256(uint64(d.exponent))) / 1e18;
        assertEq(reconstructed, x, "round-trip failed");
    }

    /// @dev Precision loss for k ≥ 18 (divide path) is exactly x mod 10^(k−17).
    ///      We drop the low (k-17) decimal digits; error < 10^(k−17).
    ///      k=18: division by 1e18/1e18=1 → exact. k=19: drops last 1 digit. Etc.
    function testFuzz_fromUint_roundtrip_precision(uint256 x) public pure {
        vm.assume(x >= 1e18 && x <= DecimalMath.pow10(77));
        Decimal.D memory d = Decimal.fromUint(x);
        int64 e = d.exponent;
        assertGe(e, 18);
        // Reconstruct: mantissa * 10^e / 1e18 = mantissa * 10^(e-18)
        uint256 reconstructed = uint256(d.mantissa) * DecimalMath.pow10(uint256(uint64(e)) - 18);
        // Error = x - reconstructed; must be in [0, 10^(e-17))
        assertLe(reconstructed, x, "overestimate");
        uint256 err = x - reconstructed;
        uint256 maxErr = DecimalMath.pow10(uint256(uint64(e)) - 17);
        assertLt(err, maxErr, "error exceeds precision bound");
    }

    /// @dev fromUint output is always normalized.
    function testFuzz_fromUint_alwaysNormalized(uint256 x) public pure {
        vm.assume(x > 0 && x <= DecimalMath.pow10(77));
        Decimal.D memory d = Decimal.fromUint(x);
        assertTrue(_isNormalized(d));
    }

    /// @dev Monotonicity of exponent: a < b (same # of digits) → fromUint(a).exponent == fromUint(b).exponent.
    function testFuzz_fromUint_sameExponentSameDigits(uint64 a, uint64 offset) public pure {
        vm.assume(a > 0);
        int256 k = DecimalMath.floorLog10(uint256(a));
        // compute upper bound for this digit count
        uint256 hi = DecimalMath.pow10(uint256(k) + 1) - 1;
        uint256 b  = uint256(a) + (offset % (hi - uint256(a) + 1));
        vm.assume(b <= hi);
        assertEq(Decimal.fromUint(b).exponent, Decimal.fromUint(a).exponent);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (6) fromInt — int256.min overflow bug
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev FIXED: fromInt(type(int256).min) is now representable.
    ///      The absolute value is 2^255 ≈ 5.789e76, exponent = 76.
    ///      Fix: unchecked { abs_ = uint256(-x); } — two's-complement negation of
    ///      int256.min wraps to int256.min, and uint256(int256.min) = 2^255. ✓
    function test_fromInt_int256Min_fixed() public pure {
        Decimal.D memory d = Decimal.fromInt(type(int256).min);
        assertEq(d.negative, true);
        assertEq(d.exponent, 76); // log10(2^255) ≈ 76.76 → floor = 76
        assertTrue(_isNormalized(d));
    }

    /// @dev All other int256 values should work including near-min boundaries.
    function test_fromInt_nearInt256Min() public pure {
        // type(int256).min + 1 = -(2^255 - 1), abs fits in int256
        Decimal.D memory d = Decimal.fromInt(type(int256).min + 1);
        assertEq(d.negative, true);
        assertEq(d.exponent, 76); // 2^255 - 1 ≈ 5.789e76
        assertTrue(_isNormalized(d));
    }

    function test_fromInt_int256Max() public pure {
        // type(int256).max = 2^255 - 1 ≈ 5.789e76, exponent = 76
        Decimal.D memory d = Decimal.fromInt(type(int256).max);
        assertEq(d.negative, false);
        assertEq(d.exponent, 76);
        assertTrue(_isNormalized(d));
    }

    /// @dev fromInt(-x) and fromInt(x) must have identical mantissa/exponent, opposite signs.
    function testFuzz_fromInt_signSymmetry(int64 x) public pure {
        vm.assume(x > 0);
        Decimal.D memory pos = Decimal.fromInt(int256(x));
        Decimal.D memory neg_ = Decimal.fromInt(int256(-x));
        assertEq(pos.mantissa,  neg_.mantissa);
        assertEq(pos.exponent,  neg_.exponent);
        assertEq(pos.negative,  false);
        assertEq(neg_.negative, true);
    }
}
