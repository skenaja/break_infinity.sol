// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Tests for Phase B — comparison operators.
contract DecimalBTest is Test {

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _eq(Decimal.D memory a, Decimal.D memory b) internal pure returns (bool) {
        return a.mantissa == b.mantissa && a.exponent == b.exponent && a.negative == b.negative;
    }

    function _pos(uint256 x) internal pure returns (Decimal.D memory) {
        return Decimal.fromUint(x);
    }

    function _neg(uint256 x) internal pure returns (Decimal.D memory) {
        return Decimal.fromInt(-int256(x));
    }

    // ── cmp: zero cases ───────────────────────────────────────────────────────

    function test_cmp_zeroBoth() public pure {
        assertEq(Decimal.cmp(Decimal.zero(), Decimal.zero()), 0);
    }

    function test_cmp_zeroPosZero() public pure {
        // 0 < 1
        assertEq(Decimal.cmp(Decimal.zero(), Decimal.one()), -1);
    }

    function test_cmp_posZeroZero() public pure {
        // 1 > 0
        assertEq(Decimal.cmp(Decimal.one(), Decimal.zero()), 1);
    }

    function test_cmp_zeroVsNegative() public pure {
        // 0 > -1
        assertEq(Decimal.cmp(Decimal.zero(), Decimal.negOne()), 1);
    }

    function test_cmp_negativeVsZero() public pure {
        // -1 < 0
        assertEq(Decimal.cmp(Decimal.negOne(), Decimal.zero()), -1);
    }

    // ── cmp: opposite signs ───────────────────────────────────────────────────

    function test_cmp_posVsNeg() public pure {
        assertEq(Decimal.cmp(Decimal.one(), Decimal.negOne()), 1);
    }

    function test_cmp_negVsPos() public pure {
        assertEq(Decimal.cmp(Decimal.negOne(), Decimal.one()), -1);
    }

    function test_cmp_largePosVsSmallNeg() public pure {
        // 1e100 > -1e100
        Decimal.D memory a = Decimal.pow10(100);
        Decimal.D memory b = Decimal.neg(Decimal.pow10(100));
        assertEq(Decimal.cmp(a, b), 1);
    }

    // ── cmp: same sign, positive ──────────────────────────────────────────────

    function test_cmp_posLargerExponent() public pure {
        // 100 (exp=2) > 10 (exp=1)
        assertEq(Decimal.cmp(_pos(100), _pos(10)), 1);
    }

    function test_cmp_posSmallerExponent() public pure {
        assertEq(Decimal.cmp(_pos(10), _pos(100)), -1);
    }

    function test_cmp_posSameExponentLargerMantissa() public pure {
        // 50 vs 40: same exp=1, mantissa 5e18 > 4e18
        assertEq(Decimal.cmp(_pos(50), _pos(40)), 1);
    }

    function test_cmp_posSameExponentSmallerMantissa() public pure {
        assertEq(Decimal.cmp(_pos(40), _pos(50)), -1);
    }

    function test_cmp_posEqual() public pure {
        assertEq(Decimal.cmp(_pos(42), _pos(42)), 0);
    }

    function test_cmp_oneOne() public pure {
        assertEq(Decimal.cmp(Decimal.one(), Decimal.one()), 0);
    }

    function test_cmp_largeVsSmall() public pure {
        // 1e50 > 9e49
        Decimal.D memory a = Decimal.pow10(50);
        Decimal.D memory b = Decimal.fromParts(9 * uint128(Decimal.MANTISSA_SCALE), 49, false);
        assertEq(Decimal.cmp(a, b), 1);
    }

    // ── cmp: same sign, negative ──────────────────────────────────────────────

    function test_cmp_negEqual() public pure {
        assertEq(Decimal.cmp(_neg(5), _neg(5)), 0);
    }

    function test_cmp_negLessNegative() public pure {
        // -5 > -10  (less negative = greater)
        assertEq(Decimal.cmp(_neg(5), _neg(10)), 1);
    }

    function test_cmp_negMoreNegative() public pure {
        // -10 < -5
        assertEq(Decimal.cmp(_neg(10), _neg(5)), -1);
    }

    function test_cmp_negSameExpDifferentMantissa() public pure {
        // -40 > -50  (smaller abs = larger value when both negative)
        assertEq(Decimal.cmp(_neg(40), _neg(50)), 1);
    }

    function test_cmp_negSameExpDifferentMantissa2() public pure {
        // -50 < -40
        assertEq(Decimal.cmp(_neg(50), _neg(40)), -1);
    }

    // ── boolean wrappers ──────────────────────────────────────────────────────

    function test_eq_sameValue() public pure {
        assertTrue(Decimal.eq(_pos(7), _pos(7)));
    }

    function test_eq_differentValue() public pure {
        assertFalse(Decimal.eq(_pos(7), _pos(8)));
    }

    function test_lt_basic() public pure {
        assertTrue(Decimal.lt(_pos(3), _pos(5)));
        assertFalse(Decimal.lt(_pos(5), _pos(3)));
        assertFalse(Decimal.lt(_pos(5), _pos(5)));
    }

    function test_lte_basic() public pure {
        assertTrue(Decimal.lte(_pos(3), _pos(5)));
        assertTrue(Decimal.lte(_pos(5), _pos(5)));
        assertFalse(Decimal.lte(_pos(6), _pos(5)));
    }

    function test_gt_basic() public pure {
        assertTrue(Decimal.gt(_pos(5), _pos(3)));
        assertFalse(Decimal.gt(_pos(3), _pos(5)));
        assertFalse(Decimal.gt(_pos(5), _pos(5)));
    }

    function test_gte_basic() public pure {
        assertTrue(Decimal.gte(_pos(5), _pos(3)));
        assertTrue(Decimal.gte(_pos(5), _pos(5)));
        assertFalse(Decimal.gte(_pos(3), _pos(5)));
    }

    // ── max / min ─────────────────────────────────────────────────────────────

    function test_max_returnsLarger() public pure {
        Decimal.D memory result = Decimal.max(_pos(3), _pos(7));
        assertTrue(_eq(result, _pos(7)));
    }

    function test_max_commutative() public pure {
        assertTrue(_eq(
            Decimal.max(_pos(3), _pos(7)),
            Decimal.max(_pos(7), _pos(3))
        ));
    }

    function test_max_equal() public pure {
        assertTrue(_eq(Decimal.max(_pos(5), _pos(5)), _pos(5)));
    }

    function test_max_negatives() public pure {
        // max(-3, -7) = -3
        assertTrue(_eq(Decimal.max(_neg(3), _neg(7)), _neg(3)));
    }

    function test_max_mixedSigns() public pure {
        // max(-5, 2) = 2
        assertTrue(_eq(Decimal.max(_neg(5), _pos(2)), _pos(2)));
    }

    function test_min_returnsSmaller() public pure {
        Decimal.D memory result = Decimal.min(_pos(3), _pos(7));
        assertTrue(_eq(result, _pos(3)));
    }

    function test_min_commutative() public pure {
        assertTrue(_eq(
            Decimal.min(_pos(3), _pos(7)),
            Decimal.min(_pos(7), _pos(3))
        ));
    }

    function test_min_negatives() public pure {
        // min(-3, -7) = -7
        assertTrue(_eq(Decimal.min(_neg(3), _neg(7)), _neg(7)));
    }

    // ── clamp ─────────────────────────────────────────────────────────────────

    function test_clamp_withinRange() public pure {
        // clamp(5, 2, 10) = 5
        assertTrue(_eq(Decimal.clamp(_pos(5), _pos(2), _pos(10)), _pos(5)));
    }

    function test_clamp_belowLo() public pure {
        // clamp(1, 2, 10) = 2
        assertTrue(_eq(Decimal.clamp(_pos(1), _pos(2), _pos(10)), _pos(2)));
    }

    function test_clamp_aboveHi() public pure {
        // clamp(15, 2, 10) = 10
        assertTrue(_eq(Decimal.clamp(_pos(15), _pos(2), _pos(10)), _pos(10)));
    }

    function test_clamp_atLo() public pure {
        assertTrue(_eq(Decimal.clamp(_pos(2), _pos(2), _pos(10)), _pos(2)));
    }

    function test_clamp_atHi() public pure {
        assertTrue(_eq(Decimal.clamp(_pos(10), _pos(2), _pos(10)), _pos(10)));
    }

    function test_clampMin_basic() public pure {
        assertTrue(_eq(Decimal.clampMin(_pos(1), _pos(5)), _pos(5)));
        assertTrue(_eq(Decimal.clampMin(_pos(8), _pos(5)), _pos(8)));
    }

    function test_clampMax_basic() public pure {
        assertTrue(_eq(Decimal.clampMax(_pos(8), _pos(5)), _pos(5)));
        assertTrue(_eq(Decimal.clampMax(_pos(3), _pos(5)), _pos(3)));
    }

    // ── Fuzz ─────────────────────────────────────────────────────────────────

    /// @dev Reflexivity: cmp(a, a) == 0.
    function testFuzz_cmp_reflexive(uint64 x) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(x));
        assertEq(Decimal.cmp(a, a), 0);
    }

    /// @dev Antisymmetry: cmp(a, b) == -cmp(b, a).
    function testFuzz_cmp_antisymmetric(uint64 rawA, uint64 rawB) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(rawA));
        Decimal.D memory b = Decimal.fromUint(uint256(rawB));
        assertEq(Decimal.cmp(a, b), -Decimal.cmp(b, a));
    }

    /// @dev Transitivity: if a ≤ b and b ≤ c then a ≤ c.
    function testFuzz_cmp_transitive(uint64 rawA, uint64 rawB, uint64 rawC) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(rawA));
        Decimal.D memory b = Decimal.fromUint(uint256(rawB));
        Decimal.D memory c = Decimal.fromUint(uint256(rawC));
        if (Decimal.cmp(a, b) <= 0 && Decimal.cmp(b, c) <= 0) {
            assertLe(Decimal.cmp(a, c), int8(0));
        }
    }

    /// @dev Negation reverses order: cmp(a, b) == -cmp(-a, -b).
    function testFuzz_cmp_negationReversesOrder(uint64 rawA, uint64 rawB) public pure {
        vm.assume(rawA > 0 && rawB > 0);
        Decimal.D memory a  = Decimal.fromUint(uint256(rawA));
        Decimal.D memory b  = Decimal.fromUint(uint256(rawB));
        Decimal.D memory na = Decimal.neg(a);
        Decimal.D memory nb = Decimal.neg(b);
        assertEq(Decimal.cmp(a, b), -Decimal.cmp(na, nb));
    }

    /// @dev max(a, b) >= a and max(a, b) >= b.
    function testFuzz_max_geqBoth(uint64 rawA, uint64 rawB) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(rawA));
        Decimal.D memory b = Decimal.fromUint(uint256(rawB));
        Decimal.D memory m = Decimal.max(a, b);
        assertTrue(Decimal.gte(m, a));
        assertTrue(Decimal.gte(m, b));
    }

    /// @dev min(a, b) <= a and min(a, b) <= b.
    function testFuzz_min_leqBoth(uint64 rawA, uint64 rawB) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(rawA));
        Decimal.D memory b = Decimal.fromUint(uint256(rawB));
        Decimal.D memory m = Decimal.min(a, b);
        assertTrue(Decimal.lte(m, a));
        assertTrue(Decimal.lte(m, b));
    }

    /// @dev min(a, b) <= max(a, b).
    function testFuzz_minLeqMax(uint64 rawA, uint64 rawB) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(rawA));
        Decimal.D memory b = Decimal.fromUint(uint256(rawB));
        assertTrue(Decimal.lte(Decimal.min(a, b), Decimal.max(a, b)));
    }

    /// @dev clamp(x, lo, hi) is always in [lo, hi].
    function testFuzz_clamp_inRange(uint32 rawX, uint32 rawLo, uint32 rawHi) public pure {
        vm.assume(rawLo <= rawHi);
        Decimal.D memory x  = Decimal.fromUint(uint256(rawX));
        Decimal.D memory lo = Decimal.fromUint(uint256(rawLo));
        Decimal.D memory hi = Decimal.fromUint(uint256(rawHi));
        Decimal.D memory r  = Decimal.clamp(x, lo, hi);
        assertTrue(Decimal.gte(r, lo), "clamp < lo");
        assertTrue(Decimal.lte(r, hi), "clamp > hi");
    }

    /// @dev clamp is idempotent: clamp(clamp(x,lo,hi), lo, hi) == clamp(x,lo,hi).
    function testFuzz_clamp_idempotent(uint32 rawX, uint32 rawLo, uint32 rawHi) public pure {
        vm.assume(rawLo <= rawHi);
        Decimal.D memory x   = Decimal.fromUint(uint256(rawX));
        Decimal.D memory lo  = Decimal.fromUint(uint256(rawLo));
        Decimal.D memory hi  = Decimal.fromUint(uint256(rawHi));
        Decimal.D memory r1  = Decimal.clamp(x, lo, hi);
        Decimal.D memory r2  = Decimal.clamp(r1, lo, hi);
        assertEq(Decimal.cmp(r1, r2), 0, "clamp not idempotent");
    }

    /// @dev Ordering consistent with fromUint: a < b ↔ cmp < 0.
    function testFuzz_cmp_consistentWithUint(uint32 a, uint32 b) public pure {
        Decimal.D memory da = Decimal.fromUint(uint256(a));
        Decimal.D memory db = Decimal.fromUint(uint256(b));
        int8 result = Decimal.cmp(da, db);
        if      (a < b) assertEq(result, -1);
        else if (a > b) assertEq(result,  1);
        else            assertEq(result,  0);
    }
}
