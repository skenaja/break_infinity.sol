// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {DecimalMath} from "../src/DecimalMath.sol";

/// @dev Harness for vm.expectRevert (internal library calls need an external call depth).
contract PhaseEHarness {
    function mul(Decimal.D memory a, Decimal.D memory b) external pure returns (Decimal.D memory) {
        return Decimal.mul(a, b);
    }
    function div(Decimal.D memory a, Decimal.D memory b) external pure returns (Decimal.D memory) {
        return Decimal.div(a, b);
    }
    function recip(Decimal.D memory a) external pure returns (Decimal.D memory) {
        return Decimal.recip(a);
    }
}

/// @notice Red-team suite for Phase E — mul, div, recip.
///
/// Attack surfaces:
///   (1)  Sign matrix — all four ±/± combos for mul AND div
///   (2)  Exponent arithmetic — carry (+1 from mantissa product), borrow (-1 from quotient)
///   (3)  Overflow boundary — exp sum at EXP_LIMIT, mantissa product forces +1 → revert
///   (4)  Overflow boundary — exp sum at EXP_LIMIT, mantissa = 1 each → NO carry → ok
///   (5)  Underflow in div — exp difference < -EXP_LIMIT → zero (no revert)
///   (6)  Underflow boundary — exp difference == -EXP_LIMIT → small valid value
///   (7)  Self-division a/a == 1 (mantissas cancel exactly)
///   (8)  mul commutativity fuzz
///   (9)  |a*b| == |a|*|b| fuzz (magnitude law)
///   (10) div monotonicity and mul monotonicity fuzz
///   (11) mul(a, recip(a)) == 1 for powers of ten
///   (12) Normalize shift==0 overflow via mul — the pre-fix silent bug
///   (13) recip involution and recip sign
///   (14) Division precision — mul(div(a,b),b) <= a (floor truncation only loses, never gains)
///   (15) Negative zero never produced
contract PhaseERedTeamTest is Test {

    PhaseEHarness dh = new PhaseEHarness();

    uint128 constant S  = uint128(Decimal.MANTISSA_SCALE);     // 1e18
    uint128 constant S9 = uint128(9 * uint256(Decimal.MANTISSA_SCALE)); // 9e18

    function _p(uint256 x) internal pure returns (Decimal.D memory) { return Decimal.fromUint(x); }
    function _n(uint256 x) internal pure returns (Decimal.D memory) { return Decimal.fromInt(-int256(x)); }
    function _d(uint128 m, int64 e, bool neg_) internal pure returns (Decimal.D memory) {
        return Decimal.D({mantissa: m, exponent: e, negative: neg_});
    }
    function _eq(Decimal.D memory a, Decimal.D memory b) internal pure returns (bool) {
        return Decimal.eq(a, b);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (1) Sign matrix — mul
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev (+) * (+) = (+)
    function test_mul_posPos_isPositive() public pure {
        Decimal.D memory r = Decimal.mul(_p(6), _p(7));
        assertFalse(r.negative);
        assertTrue(_eq(r, _p(42)));
    }

    /// @dev (+) * (-) = (-)
    function test_mul_posNeg_isNegative() public pure {
        Decimal.D memory r = Decimal.mul(_p(6), _n(7));
        assertTrue(r.negative);
        assertTrue(_eq(r, _n(42)));
    }

    /// @dev (-) * (+) = (-)
    function test_mul_negPos_isNegative() public pure {
        Decimal.D memory r = Decimal.mul(_n(6), _p(7));
        assertTrue(r.negative);
        assertTrue(_eq(r, _n(42)));
    }

    /// @dev (-) * (-) = (+)
    function test_mul_negNeg_isPositive() public pure {
        Decimal.D memory r = Decimal.mul(_n(6), _n(7));
        assertFalse(r.negative);
        assertTrue(_eq(r, _p(42)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (1) Sign matrix — div
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev (+) / (+) = (+)
    function test_div_posPos_isPositive() public pure {
        assertFalse(Decimal.div(_p(12), _p(4)).negative);
    }

    /// @dev (+) / (-) = (-)
    function test_div_posNeg_isNegative() public pure {
        assertTrue(Decimal.div(_p(12), _n(4)).negative);
    }

    /// @dev (-) / (+) = (-)
    function test_div_negPos_isNegative() public pure {
        assertTrue(Decimal.div(_n(12), _p(4)).negative);
    }

    /// @dev (-) / (-) = (+)
    function test_div_negNeg_isPositive() public pure {
        assertFalse(Decimal.div(_n(12), _n(4)).negative);
    }

    /// @dev Magnitude is sign-independent: |a*b| == |(-a)*b|.
    function test_mul_signDoesNotAffectMagnitude() public pure {
        Decimal.D memory pos = Decimal.mul(_p(7), _p(13));
        Decimal.D memory neg_pos = Decimal.mul(_n(7), _p(13));
        assertEq(pos.mantissa, neg_pos.mantissa);
        assertEq(pos.exponent, neg_pos.exponent);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (2) Exponent arithmetic — carry and borrow
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev When mulFixed result >= 10e18 the mantissa is renormalized with exponent+1.
    ///      Concrete: D{9e18, 3} * D{9e18, 5} → mulFixed=81e18 → shift+1 → exp = 3+5+1 = 9.
    function test_mul_mantissaCarry_bumpsExponentByOne() public pure {
        Decimal.D memory a = _d(S9, 3, false);
        Decimal.D memory b = _d(S9, 5, false);
        Decimal.D memory r = Decimal.mul(a, b);
        assertEq(r.exponent, 9, "expected exponent 3+5+1=9 after mantissa carry");
        // mulFixed(9e18, 9e18) = 9e18*9e18/1e18 = 81e18; normalize: 81e18/10=8.1e18, exp+1
        assertEq(r.mantissa, uint128(81 * uint256(S) / 10), "mantissa should be 8.1e18");
    }

    /// @dev When divFixed result < 1e18 the mantissa is renormalized with exponent-1.
    ///      Concrete: D{1e18, 7} / D{9e18, 3} → divFixed=1e18*1e18/9e18 ≈ 1.111e17 → shift-1 → exp = 7-3-1 = 3.
    function test_div_mantissaBorrow_lowersExponentByOne() public pure {
        Decimal.D memory a = _d(S, 7, false);   // 1e18 mantissa, exp=7
        Decimal.D memory b = _d(S9, 3, false);  // 9e18 mantissa, exp=3
        Decimal.D memory r = Decimal.div(a, b);
        assertEq(r.exponent, 3, "expected exponent 7-3-1=3 after mantissa borrow");
    }

    /// @dev mulFixed(1e18, 1e18) = 1e18 exactly — no carry, exponent unchanged.
    function test_mul_noCarry_sameExponent() public pure {
        // _p(1) has mantissa=1e18, exp=0; mul(1, 1) = 1
        assertTrue(_eq(Decimal.mul(Decimal.one(), Decimal.one()), Decimal.one()));
    }

    /// @dev divFixed(a, a) = 1e18 exactly — no borrow, sign cancels.
    function test_div_selfEqualsMantissaScale() public pure {
        // Both mantissas equal → divFixed = 1e18, shift=0, sign cancels
        Decimal.D memory a = _d(S9, 4, false);
        Decimal.D memory r = Decimal.div(a, a);
        assertEq(r.mantissa, S);
        assertEq(r.exponent, 0);
        assertFalse(r.negative);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (3) Overflow — exponent sum at EXP_LIMIT with mantissa carry
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev mul(D{9e18, EXP_LIMIT/2}, D{9e18, EXP_LIMIT/2}):
    ///      newExp = EXP_LIMIT before normalize, mantissa product = 81e18 → shift+1 → EXP_LIMIT+1 → revert.
    function test_mul_overflowViaCarry_reverts() public {
        int64 halfLimit = Decimal.EXP_LIMIT / 2;
        Decimal.D memory a = _d(S9, halfLimit, false);
        vm.expectRevert();
        dh.mul(a, a);
    }

    /// @dev mul(D{9e18, EXP_LIMIT/2}, D{9e18, EXP_LIMIT/2}) with negative — same overflow.
    function test_mul_overflowViaCarry_negativeReverts() public {
        int64 halfLimit = Decimal.EXP_LIMIT / 2;
        Decimal.D memory a = _d(S9, halfLimit, true);
        vm.expectRevert();
        dh.mul(a, a);
    }

    /// @dev mul(D{9e18, EXP_LIMIT/2+1}, D{anything}) where newExp > EXP_LIMIT → revert.
    function test_mul_overflowFromExponentSum_reverts() public {
        Decimal.D memory a = Decimal.pow10(Decimal.EXP_LIMIT);
        Decimal.D memory b = _p(10); // exp=1
        vm.expectRevert();
        dh.mul(a, b);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (4) No overflow — exp sum at EXP_LIMIT, mantissa product = 1e18 (no carry)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev mul(pow10(EXP_LIMIT/2), pow10(EXP_LIMIT/2)):
    ///      newExp = EXP_LIMIT, mantissa product = 1e18 * 1e18 / 1e18 = 1e18 → shift=0 → ok.
    function test_mul_exactlyAtLimit_noCarry_doesNotRevert() public pure {
        int64 halfLimit = Decimal.EXP_LIMIT / 2;
        Decimal.D memory a = Decimal.pow10(halfLimit);
        Decimal.D memory r = Decimal.mul(a, a);
        assertEq(r.exponent, Decimal.EXP_LIMIT);
        assertEq(r.mantissa, S);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (5) Underflow in div — exp difference drops below -EXP_LIMIT → zero
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev div(pow10(0), pow10(EXP_LIMIT+1)) would give exp = -(EXP_LIMIT+1) → zero.
    ///      We can't construct pow10(EXP_LIMIT+1) legitimately, so use:
    ///      div(pow10(-1), pow10(EXP_LIMIT)) → newExp = -1 - EXP_LIMIT = -(EXP_LIMIT+1) → zero.
    function test_div_underflow_returnsZero() public pure {
        Decimal.D memory small = _d(S, -1, false);          // 1e-1
        Decimal.D memory huge  = Decimal.pow10(Decimal.EXP_LIMIT); // 1e(EXP_LIMIT)
        Decimal.D memory r = Decimal.div(small, huge);
        // 1e-1 / 1e(EXP_LIMIT) = 1e-(EXP_LIMIT+1) — underflows
        assertTrue(_eq(r, Decimal.zero()), "should underflow to zero");
    }

    /// @dev Zero result is canonical (mantissa=0, exponent=0, negative=false).
    function test_div_underflow_isCanonicalZero() public pure {
        Decimal.D memory small = _d(S, -1, false);
        Decimal.D memory huge  = Decimal.pow10(Decimal.EXP_LIMIT);
        Decimal.D memory r = Decimal.div(small, huge);
        assertEq(r.mantissa, 0);
        assertEq(r.exponent, 0);
        assertFalse(r.negative);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (6) Underflow boundary — exp diff == -EXP_LIMIT → valid small value
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev div(pow10(0), pow10(EXP_LIMIT)): newExp = -EXP_LIMIT (before normalize).
    ///      mantissa quotient of 1e18/1e18 = 1e18 → shift=0 → exponent stays -EXP_LIMIT → ok.
    function test_div_exactlyAtNegLimit_isValidNotZero() public pure {
        Decimal.D memory a = Decimal.pow10(0);
        Decimal.D memory b = Decimal.pow10(Decimal.EXP_LIMIT);
        Decimal.D memory r = Decimal.div(a, b);
        assertEq(r.exponent, -Decimal.EXP_LIMIT, "exponent should be -EXP_LIMIT");
        assertFalse(_eq(r, Decimal.zero()), "should NOT be zero");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (7) Self-division — a / a == 1 for all non-zero a
    // ─────────────────────────────────────────────────────────────────────────

    function test_div_selfIsOne_concrete() public pure {
        assertTrue(_eq(Decimal.div(_p(42),   _p(42)),   Decimal.one()));
        assertTrue(_eq(Decimal.div(_p(1000), _p(1000)), Decimal.one()));
        assertTrue(_eq(Decimal.div(Decimal.pow10(50), Decimal.pow10(50)), Decimal.one()));
    }

    /// @dev a / a == 1 for all positive integers (uint8 range for speed).
    function testFuzz_div_selfIsOne(uint8 x) public pure {
        vm.assume(x > 0);
        assertTrue(_eq(Decimal.div(_p(x), _p(x)), Decimal.one()));
    }

    /// @dev (-a) / (-a) == 1 (negatives cancel).
    function testFuzz_div_negSelfIsOne(uint8 x) public pure {
        vm.assume(x > 0);
        assertTrue(_eq(Decimal.div(_n(x), _n(x)), Decimal.one()));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (8) mul commutativity
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_mul_commutative_posInts(uint16 rawA, uint16 rawB) public pure {
        vm.assume(rawA > 0 && rawB > 0);
        Decimal.D memory a = _p(rawA);
        Decimal.D memory b = _p(rawB);
        assertEq(Decimal.cmp(Decimal.mul(a, b), Decimal.mul(b, a)), 0, "commutativity");
    }

    function testFuzz_mul_commutative_mixedSigns(int16 rawA, int16 rawB) public pure {
        vm.assume(rawA != 0 && rawB != 0);
        Decimal.D memory a = Decimal.fromInt(int256(rawA));
        Decimal.D memory b = Decimal.fromInt(int256(rawB));
        assertEq(Decimal.cmp(Decimal.mul(a, b), Decimal.mul(b, a)), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (9) Magnitude law: |a*b| == |a|*|b|
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_mul_magnitudeLaw(int16 rawA, int16 rawB) public pure {
        vm.assume(rawA != 0 && rawB != 0);
        Decimal.D memory a  = Decimal.fromInt(int256(rawA));
        Decimal.D memory b  = Decimal.fromInt(int256(rawB));
        Decimal.D memory ab = Decimal.abs(Decimal.mul(a, b));
        Decimal.D memory ba = Decimal.mul(Decimal.abs(a), Decimal.abs(b));
        assertEq(Decimal.cmp(ab, ba), 0, "|a*b| != |a|*|b|");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (10) Monotonicity
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev a < b and c > 0 → a*c < b*c.
    function testFuzz_mul_monotone(uint8 rawA, uint8 rawB, uint8 rawC) public pure {
        vm.assume(rawA < rawB && rawC > 0);
        Decimal.D memory a = _p(rawA);
        Decimal.D memory b = _p(rawB);
        Decimal.D memory c = _p(rawC);
        assertTrue(Decimal.lt(Decimal.mul(a, c), Decimal.mul(b, c)), "a*c should be < b*c");
    }

    /// @dev a < b and c > 0 → a/c < b/c.
    function testFuzz_div_monotone(uint8 rawA, uint8 rawB, uint8 rawC) public pure {
        vm.assume(rawA < rawB && rawC > 0);
        Decimal.D memory a = _p(rawA);
        Decimal.D memory b = _p(rawB);
        Decimal.D memory c = _p(rawC);
        assertTrue(Decimal.lt(Decimal.div(a, c), Decimal.div(b, c)), "a/c should be < b/c");
    }

    /// @dev Multiplying both sides by the same value preserves comparison direction.
    function testFuzz_mul_preservesOrder(int8 rawA, int8 rawB, uint8 rawC) public pure {
        vm.assume(rawA < rawB && rawC > 0);
        Decimal.D memory a = Decimal.fromInt(int256(rawA));
        Decimal.D memory b = Decimal.fromInt(int256(rawB));
        Decimal.D memory c = _p(rawC);
        assertTrue(Decimal.lt(Decimal.mul(a, c), Decimal.mul(b, c)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (11) mul(a, recip(a)) == 1 for powers of ten
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev 10^n * 10^(-n) == 1 — recip of a power of ten is exact.
    function test_mul_recip_powersOfTen() public pure {
        for (int64 e = -10; e <= 10; e++) {
            Decimal.D memory a   = Decimal.pow10(e);
            Decimal.D memory inv = Decimal.recip(a);
            assertTrue(_eq(Decimal.mul(a, inv), Decimal.one()),
                "a * recip(a) should be 1 for power of ten");
        }
    }

    /// @dev recip(pow10(n)).exponent == -n.
    function test_recip_powOfTen_exponentNegated() public pure {
        Decimal.D memory r = Decimal.recip(Decimal.pow10(7));
        assertEq(r.exponent, -7);
        assertEq(r.mantissa, S);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (12) The "silent overflow" bug — normalize shift==0 path MUST still check EXP_LIMIT
    //      Before the fix: mul(D{1e18, EXP_LIMIT}, D{2e18, 1}) silently returned
    //      D{2e18, EXP_LIMIT+1} instead of reverting.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev mul where mantissa product doesn't carry (+shift=0) but newExp > EXP_LIMIT → revert.
    ///      D{1e18, EXP_LIMIT} * D{2e18, 1}: mulFixed(1e18, 2e18) = 2e18, shift=0;
    ///      but newExp = EXP_LIMIT + 1 > EXP_LIMIT → must revert.
    function test_mul_silentOverflowFix_shift0PathReverts() public {
        Decimal.D memory a = _d(S,       Decimal.EXP_LIMIT, false);  // mantissa=1e18, exp=EXP_LIMIT
        Decimal.D memory b = _d(2 * S,   1,                 false);  // mantissa=2e18, exp=1
        vm.expectRevert();
        dh.mul(a, b);
    }

    /// @dev Symmetric: the result must NOT silently carry a out-of-range exponent.
    function test_mul_silentOverflowFix_resultHasNoOutOfRangeExp() public {
        Decimal.D memory a = _d(S, Decimal.EXP_LIMIT, false);
        Decimal.D memory b = _d(2 * S, 1, false);
        bool reverted;
        try dh.mul(a, b) returns (Decimal.D memory r) {
            // If it somehow didn't revert, the exponent must still be within bounds
            assertTrue(r.exponent <= Decimal.EXP_LIMIT, "exponent out of range");
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "expected revert for out-of-range exponent");
    }

    /// @dev Counterpart: mul where shift=0 AND newExp == EXP_LIMIT (not >): OK.
    function test_mul_shift0_exactlyAtLimit_doesNotRevert() public pure {
        // D{1e18, EXP_LIMIT/2} * D{1e18, EXP_LIMIT/2}: mulFixed=1e18, shift=0, newExp=EXP_LIMIT
        int64 half = Decimal.EXP_LIMIT / 2;
        Decimal.D memory a = _d(S, half, false);
        Decimal.D memory r = Decimal.mul(a, a);
        assertEq(r.exponent, Decimal.EXP_LIMIT);
        assertEq(r.mantissa, S);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (13) recip sign and involution
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev recip of a negative is negative.
    function test_recip_negativeInput_isNegative() public pure {
        Decimal.D memory r = Decimal.recip(Decimal.negOne());
        assertTrue(r.negative);
        assertTrue(_eq(r, Decimal.negOne()));
    }

    /// @dev recip(recip(pow10(n))) == pow10(n).
    function test_recip_involution_powersOfTen() public pure {
        for (int64 e = -5; e <= 5; e++) {
            Decimal.D memory a = Decimal.pow10(e);
            assertTrue(_eq(Decimal.recip(Decimal.recip(a)), a),
                "recip(recip(a)) should equal a for powers of ten");
        }
    }

    /// @dev recip(zero) must revert.
    function test_recip_zero_reverts() public {
        vm.expectRevert();
        dh.recip(Decimal.zero());
    }

    /// @dev sign(recip(a)) == sign(a) for non-zero a.
    function testFuzz_recip_preservesSign(uint8 raw) public pure {
        vm.assume(raw > 0);
        Decimal.D memory a = _p(raw);
        assertFalse(Decimal.recip(a).negative, "recip of positive should be positive");
        Decimal.D memory an = _n(raw);
        assertTrue(Decimal.recip(an).negative, "recip of negative should be negative");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (14) Division precision — floor truncation: mul(div(a,b), b) <= a always
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev For positive integers where b divides a exactly, (a/b)*b == a.
    function test_div_exactDivision_roundtrip() public pure {
        // 100 / 5 = 20; 20 * 5 = 100
        assertTrue(_eq(Decimal.mul(Decimal.div(_p(100), _p(5)), _p(5)), _p(100)));
        // 1000 / 8 = 125; 125 * 8 = 1000
        assertTrue(_eq(Decimal.mul(Decimal.div(_p(1000), _p(8)), _p(8)), _p(1000)));
    }

    /// @dev For all uint8 pairs, (a/b)*b <= a (floor truncation never overcounts).
    function testFuzz_div_floorTruncation_leq(uint8 rawA, uint8 rawB) public pure {
        vm.assume(rawB > 0 && rawA > 0);
        Decimal.D memory a    = _p(rawA);
        Decimal.D memory b    = _p(rawB);
        Decimal.D memory quot = Decimal.div(a, b);
        Decimal.D memory back = Decimal.mul(quot, b);
        // back <= a (never greater due to floor)
        assertTrue(Decimal.lte(back, a), "(a/b)*b should be <= a");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (15) Negative zero never produced
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev 0 * anything = canonical zero (not negative zero).
    function testFuzz_mul_zeroNeverNegative(int16 raw) public pure {
        vm.assume(raw != 0);
        Decimal.D memory a = Decimal.fromInt(int256(raw));
        Decimal.D memory r = Decimal.mul(Decimal.zero(), a);
        assertFalse(r.negative, "zero * x should never be negative zero");
        assertEq(r.mantissa, 0);
    }

    /// @dev 0 / anything = canonical zero.
    function testFuzz_div_zeroNeverNegative(int16 raw) public pure {
        vm.assume(raw != 0);
        Decimal.D memory a = Decimal.fromInt(int256(raw));
        Decimal.D memory r = Decimal.div(Decimal.zero(), a);
        assertFalse(r.negative);
        assertEq(r.mantissa, 0);
    }

    /// @dev x * (-x) result should NOT be positive zero (it's negative).
    ///      But x * x for large exponent cancellation shouldn't produce negative zero either.
    function test_mul_sameValDiffSign_isNegative() public pure {
        // 5 * (-5) = -25, definitely negative
        Decimal.D memory r = Decimal.mul(_p(5), _n(5));
        assertTrue(r.negative);
        assertTrue(r.mantissa != 0, "should not be zero");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Bonus: normalization invariant
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_mul_alwaysNormalized(int8 rawA, int8 rawB) public pure {
        vm.assume(rawA != 0 && rawB != 0);
        Decimal.D memory r = Decimal.mul(
            Decimal.fromInt(int256(rawA)),
            Decimal.fromInt(int256(rawB))
        );
        assertGe(r.mantissa, S);
        assertLt(r.mantissa, 10 * S);
        assertFalse(r.negative == (rawA > 0) == (rawB > 0),
            "sign rule: pos*pos=pos, pos*neg=neg, neg*neg=pos");
    }

    function testFuzz_div_alwaysNormalized(int8 rawA, int8 rawB) public pure {
        vm.assume(rawA != 0 && rawB != 0);
        Decimal.D memory r = Decimal.div(
            Decimal.fromInt(int256(rawA)),
            Decimal.fromInt(int256(rawB))
        );
        assertGe(r.mantissa, S);
        assertLt(r.mantissa, 10 * S);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Bonus: consistency with integer arithmetic
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_mul_consistentWithInt(uint8 rawA, uint8 rawB) public pure {
        vm.assume(rawA > 0 && rawB > 0);
        uint256 expected = uint256(rawA) * uint256(rawB);
        assertTrue(_eq(Decimal.mul(_p(rawA), _p(rawB)), _p(expected)));
    }

    function testFuzz_div_exactIntegers(uint8 rawA, uint8 rawB) public pure {
        // rawB divides rawA
        vm.assume(rawB > 0 && rawA > 0 && uint256(rawA) % uint256(rawB) == 0);
        uint256 expected = uint256(rawA) / uint256(rawB);
        assertTrue(_eq(Decimal.div(_p(rawA), _p(rawB)), _p(expected)));
    }
}
