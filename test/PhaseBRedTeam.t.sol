// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Adversarial / red-team test suite for Phase B (cmp and derived ops).
///
/// Attack surfaces:
///   (1) Negative zero — raw D{0, e, true}: does cmp treat it as zero?
///   (2) Unnormalized equal values — same number, different mantissa/exponent pairs
///   (3) Extreme exponent values — int64.min / int64.max
///   (4) Mantissa at exact SCALE / MAX-1 boundaries
///   (5) Transitivity including negatives and mixed signs
///   (6) sign(a) consistency — cmp(a,0) agrees with positive/negative flag
///   (7) cmp result domain — always exactly -1, 0, or 1
///   (8) Antisymmetry with all four sign combinations
contract PhaseBRedTeamTest is Test {

    uint128 constant SCALE = uint128(Decimal.MANTISSA_SCALE);
    uint128 constant SMAX  = uint128(Decimal.MANTISSA_MAX) - 1; // 10e18 - 1

    function _d(uint128 m, int64 e, bool neg) internal pure returns (Decimal.D memory) {
        return Decimal.D({mantissa: m, exponent: e, negative: neg});
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (1) Negative zero
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev D{0, x, true} must equal D{0, 0, false} in all comparisons.
    function test_negativeZero_equalsZero() public pure {
        Decimal.D memory negZero = _d(0, 7, true);  // "negative zero" raw struct
        Decimal.D memory posZero = Decimal.zero();
        assertEq(Decimal.cmp(negZero, posZero), 0);
        assertEq(Decimal.cmp(posZero, negZero), 0);
    }

    function test_negativeZero_notGreaterThanPositive() public pure {
        Decimal.D memory negZero = _d(0, 0, true);
        assertEq(Decimal.cmp(negZero, Decimal.one()), -1);
    }

    function test_negativeZero_notLessThanNegative() public pure {
        Decimal.D memory negZero = _d(0, 0, true);
        assertEq(Decimal.cmp(negZero, Decimal.negOne()), 1);
    }

    function testFuzz_negativeZero_alwaysEqualsZero(int64 exp) public pure {
        Decimal.D memory negZero = _d(0, exp, true);
        assertEq(Decimal.cmp(negZero, Decimal.zero()), 0);
        assertEq(Decimal.cmp(Decimal.zero(), negZero), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (2) Unnormalized inputs — documented footgun
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Raw D{20e18, 0} and D{2e18, 1} both represent the value 20,
    ///      but cmp returns -1 because it compares exponents naively.
    ///      This documents that cmp requires normalized inputs.
    function test_unnormalized_sameValueDifferentForm_comparesUnequal() public pure {
        // 20e18 / 1e18 * 10^0 = 20
        Decimal.D memory a = _d(uint128(20 * uint256(SCALE)), 0, false);
        // 2e18  / 1e18 * 10^1 = 20
        Decimal.D memory b = _d(2 * SCALE, 1, false);

        // Both represent 20, but cmp sees exp(0) < exp(1) → a < b.
        // This is expected behaviour given the normalisation precondition.
        assertEq(Decimal.cmp(a, b), -1, "unnormalized: exponent drives result");
    }

    /// @dev Normalized forms of the same value compare equal.
    function test_normalized_sameValueComparesEqual() public pure {
        Decimal.D memory a = Decimal.fromParts(uint128(20 * uint256(SCALE)), 0, false); // normalises to {2e18, 1}
        Decimal.D memory b = Decimal.fromUint(20);
        assertEq(Decimal.cmp(a, b), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (3) Extreme exponent values
    // ─────────────────────────────────────────────────────────────────────────

    function test_extremeExponents_maxGtMin() public pure {
        Decimal.D memory big   = _d(SCALE, type(int64).max, false);
        Decimal.D memory small = _d(SCALE, type(int64).min, false);
        assertEq(Decimal.cmp(big, small),  1);
        assertEq(Decimal.cmp(small, big), -1);
    }

    function test_extremeExponents_sameExponentEqualMantissa() public pure {
        Decimal.D memory a = _d(SCALE, type(int64).max, false);
        Decimal.D memory b = _d(SCALE, type(int64).max, false);
        assertEq(Decimal.cmp(a, b), 0);
    }

    function test_extremeExponents_negativeNumbers() public pure {
        // -1 * 10^(int64.max) < -1 * 10^(int64.min) in the usual number line?
        // No: -10^max < -10^min because 10^max >> 10^min, so more negative.
        Decimal.D memory negBig   = _d(SCALE, type(int64).max, true);
        Decimal.D memory negSmall = _d(SCALE, type(int64).min, true);
        // negBig has larger magnitude → is more negative → is less
        assertEq(Decimal.cmp(negBig, negSmall), -1);
        assertEq(Decimal.cmp(negSmall, negBig),  1);
    }

    function test_extremeExponents_zeroVsExtreme() public pure {
        assertEq(Decimal.cmp(Decimal.zero(), _d(SCALE, type(int64).max, false)), -1);
        assertEq(Decimal.cmp(Decimal.zero(), _d(SCALE, type(int64).min, true)),   1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (4) Mantissa boundary values
    // ─────────────────────────────────────────────────────────────────────────

    function test_mantissaBoundary_scaleVsMaxMinus1() public pure {
        // 1e18 < 9.99...e18 at same exponent
        Decimal.D memory lo = _d(SCALE, 5, false);
        Decimal.D memory hi = _d(SMAX,  5, false);
        assertEq(Decimal.cmp(lo, hi), -1);
        assertEq(Decimal.cmp(hi, lo),  1);
    }

    function test_mantissaBoundary_scaleSameExponent() public pure {
        assertEq(Decimal.cmp(_d(SCALE, 3, false), _d(SCALE, 3, false)), 0);
    }

    function test_mantissaBoundary_negativeScaleVsMaxMinus1() public pure {
        // -(1e18 * 10^5) > -(9.99e18 * 10^5): smaller magnitude = larger value
        Decimal.D memory lessNeg = _d(SCALE, 5, true);
        Decimal.D memory moreNeg = _d(SMAX,  5, true);
        assertEq(Decimal.cmp(lessNeg, moreNeg),  1);
        assertEq(Decimal.cmp(moreNeg, lessNeg), -1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (5) Transitivity including negatives
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_cmp_transitiveWithNegatives(int32 rawA, int32 rawB, int32 rawC) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(rawA));
        Decimal.D memory b = Decimal.fromInt(int256(rawB));
        Decimal.D memory c = Decimal.fromInt(int256(rawC));

        // if a ≤ b and b ≤ c then a ≤ c
        if (Decimal.cmp(a, b) <= 0 && Decimal.cmp(b, c) <= 0) {
            assertLe(Decimal.cmp(a, c), int8(0), "transitivity violated");
        }
        // if a ≥ b and b ≥ c then a ≥ c
        if (Decimal.cmp(a, b) >= 0 && Decimal.cmp(b, c) >= 0) {
            assertGe(Decimal.cmp(a, c), int8(0), "reverse transitivity violated");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (6) sign(a) consistency: cmp(a, zero) agrees with a.negative
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_cmp_agreeWithSignFlag(int32 x) public pure {
        Decimal.D memory a    = Decimal.fromInt(int256(x));
        Decimal.D memory zero = Decimal.zero();
        int8 result = Decimal.cmp(a, zero);

        if (x > 0) assertEq(result,  1, "positive should be > 0");
        if (x < 0) assertEq(result, -1, "negative should be < 0");
        if (x == 0) assertEq(result, 0, "zero should be == 0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (7) Result domain: cmp always returns -1, 0, or 1
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_cmp_resultDomain(uint64 rawA, uint64 rawB) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(rawA));
        Decimal.D memory b = Decimal.fromUint(uint256(rawB));
        int8 r = Decimal.cmp(a, b);
        assertTrue(r == -1 || r == 0 || r == 1, "result outside {-1,0,1}");
    }

    function testFuzz_cmp_resultDomainWithNegatives(int32 rawA, int32 rawB) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(rawA));
        Decimal.D memory b = Decimal.fromInt(int256(rawB));
        int8 r = Decimal.cmp(a, b);
        assertTrue(r == -1 || r == 0 || r == 1, "result outside {-1,0,1}");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (8) Antisymmetry across all four sign combos
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_cmp_antisymmetric_allSigns(int32 rawA, int32 rawB) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(rawA));
        Decimal.D memory b = Decimal.fromInt(int256(rawB));
        assertEq(Decimal.cmp(a, b), -Decimal.cmp(b, a));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (9) max / min with extreme and mixed inputs
    // ─────────────────────────────────────────────────────────────────────────

    function test_max_posVsNeg_alwaysPos() public pure {
        // max(any positive, any negative) = the positive
        Decimal.D memory pos = _d(SCALE, 999, false);
        Decimal.D memory neg = _d(SMAX, 999, true);
        Decimal.D memory result = Decimal.max(pos, neg);
        assertEq(result.negative, false);
    }

    function test_min_posVsNeg_alwaysNeg() public pure {
        Decimal.D memory pos = _d(SCALE, 999, false);
        Decimal.D memory neg = _d(SMAX, 999, true);
        Decimal.D memory result = Decimal.min(pos, neg);
        assertEq(result.negative, true);
    }

    function testFuzz_max_idem(uint64 raw) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(raw));
        Decimal.D memory result = Decimal.max(a, a);
        assertEq(Decimal.cmp(result, a), 0);
    }

    function testFuzz_min_idem(uint64 raw) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(raw));
        Decimal.D memory result = Decimal.min(a, a);
        assertEq(Decimal.cmp(result, a), 0);
    }

    /// @dev max(a,b) is either a or b — no phantom third value.
    function testFuzz_max_isOneOfInputs(uint64 rawA, uint64 rawB) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(rawA));
        Decimal.D memory b = Decimal.fromUint(uint256(rawB));
        Decimal.D memory m = Decimal.max(a, b);
        assertTrue(Decimal.eq(m, a) || Decimal.eq(m, b), "max is not one of the inputs");
    }

    function testFuzz_min_isOneOfInputs(uint64 rawA, uint64 rawB) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(rawA));
        Decimal.D memory b = Decimal.fromUint(uint256(rawB));
        Decimal.D memory m = Decimal.min(a, b);
        assertTrue(Decimal.eq(m, a) || Decimal.eq(m, b), "min is not one of the inputs");
    }
}
