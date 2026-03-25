// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Cross-checks Solidity output against break_infinity.js reference values.
///
/// Reference values were computed with:
///   node -e "const D = require('break_infinity.js'); ..."
///
/// Precision note: for geometric-series functions, relative error grows as
///   ~count * ln(10) * |ε_log10|
/// where ε_log10 is the absolute error in our log10 primitive (~2e-10).
/// For count ≤ 1 000 this stays below 5e-7; for count = 1e6 it reaches ~4.5e-4.
contract DecimalJsRefTest is Test {

    uint128 constant S = uint128(Decimal.MANTISSA_SCALE);

    function _d(uint128 m, int64 e) internal pure returns (Decimal.D memory) {
        return Decimal.D({mantissa: m, exponent: e, negative: false});
    }

    /// Returns relative error as a 1e18-scaled fraction.
    function _relErr(Decimal.D memory a, Decimal.D memory b) internal pure returns (uint256) {
        int64 ed = a.exponent - b.exponent;
        uint256 am = uint256(a.mantissa);
        uint256 bm = uint256(b.mantissa);
        uint256 diff;
        if      (ed ==  0) { diff = am > bm ? am - bm : bm - am; }
        else if (ed ==  1) { am *= 10; diff = am > bm ? am - bm : bm - am; }
        else if (ed == -1) { bm *= 10; diff = am > bm ? am - bm : bm - am; }
        else               { return type(uint256).max; }
        uint256 denom = am > bm ? am : bm;
        if (denom == 0) return 0;
        return diff * 1e18 / denom;
    }

    // ── sumGeometricSeries ────────────────────────────────────────────────────

    /// count=100, costInitial=100, costRatio=1.2, currentOwned=0
    /// JS: 4.1408986761007094e10  →  mantissa=4140898676100709376 exp=10
    function test_sumGeo_count100_ref() public pure {
        Decimal.D memory result = Decimal.sumGeometricSeries(
            _d(S, 2),                        // count=100
            _d(S, 2),                        // costInitial=100
            _d(1_200_000_000_000_000_000, 0), // costRatio=1.2
            Decimal.zero()
        );
        Decimal.D memory expected = _d(4_140_898_676_100_709_376, 10);
        assertEq(result.exponent, 10, "sumGeo count=100: exp");
        // actual relative error ~4.5e-8 (count * ln(10) * ε_log10)
        assertLe(_relErr(result, expected), 1e11, "sumGeo count=100: 1e-7 rel");
    }

    /// count=1000, costInitial=100, costRatio=1.2, currentOwned=0
    /// JS: 7.589550445861228e81  →  mantissa=7589550445861227520 exp=81
    function test_sumGeo_count1000_ref() public pure {
        Decimal.D memory result = Decimal.sumGeometricSeries(
            _d(S, 3),                        // count=1000
            _d(S, 2),                        // costInitial=100
            _d(1_200_000_000_000_000_000, 0),
            Decimal.zero()
        );
        Decimal.D memory expected = _d(7_589_550_445_861_227_520, 81);
        assertEq(result.exponent, 81, "sumGeo count=1000: exp");
        // error budget: 1000 * ln(10) * 2e-10 ~= 4.6e-7
        assertLe(_relErr(result, expected), 5e11, "sumGeo count=1000: 5e-7 rel");
    }

    /// count=500, costInitial=50, costRatio=1.07, currentOwned=10
    /// JS: 6.9119181043856384e17  →  mantissa=6911918104385638400 exp=17
    function test_sumGeo_gameScenario1_ref() public pure {
        Decimal.D memory result = Decimal.sumGeometricSeries(
            _d(5 * S, 2),                    // count=500
            _d(5 * S, 1),                    // costInitial=50
            _d(1_070_000_000_000_000_000, 0), // costRatio=1.07
            _d(S, 1)                         // currentOwned=10
        );
        Decimal.D memory expected = _d(6_911_918_104_385_638_400, 17);
        assertEq(result.exponent, 17, "sumGeo game1: exp");
        assertLe(_relErr(result, expected), 5e11, "sumGeo game1: 5e-7 rel");
    }

    /// count=200, costInitial=10, costRatio=1.1, currentOwned=5
    /// JS: 3.058443451818336e10  →  mantissa=3058443451818336256 exp=10
    function test_sumGeo_gameScenario2_ref() public pure {
        Decimal.D memory result = Decimal.sumGeometricSeries(
            _d(2 * S, 2),                    // count=200
            _d(S, 1),                        // costInitial=10
            _d(1_100_000_000_000_000_000, 0), // costRatio=1.1
            _d(5 * S, 0)                     // currentOwned=5
        );
        Decimal.D memory expected = _d(3_058_443_451_818_336_256, 10);
        assertEq(result.exponent, 10, "sumGeo game2: exp");
        assertLe(_relErr(result, expected), 5e11, "sumGeo game2: 5e-7 rel");
    }

    /// count=1e4, costInitial=100, costRatio=1.2, currentOwned=0
    /// JS: 3.24661268059908e794  →  mantissa=3246612680599080960 exp=794
    function test_sumGeo_count1e4_ref() public pure {
        Decimal.D memory result = Decimal.sumGeometricSeries(
            _d(S, 4),                        // count=10000
            _d(S, 2),                        // costInitial=100
            _d(1_200_000_000_000_000_000, 0),
            Decimal.zero()
        );
        Decimal.D memory expected = _d(3_246_612_680_599_080_960, 794);
        assertEq(result.exponent, 794, "sumGeo count=1e4: exp");
        // error budget: 1e4 * ln(10) * 2e-10 ~= 4.6e-6
        assertLe(_relErr(result, expected), 5e12, "sumGeo count=1e4: 5e-6 rel");
    }

    /// count=1e6, costInitial=100, costRatio=1.2, currentOwned=0
    /// JS: 8.810846378333549e79183  →  mantissa=8810846378333549568 exp=79183
    ///
    /// NOTE: Error is fundamentally bounded by count * |log(ratio)| * ε_log10
    /// ~= 1e6 * 0.0792 * 1e-10 ~= 8e-6 (two pow calls, so ~1e-5 net).
    function test_sumGeo_count1e6_ref() public pure {
        Decimal.D memory result = Decimal.sumGeometricSeries(
            _d(S, 6),                        // count=1e6
            _d(S, 2),                        // costInitial=100
            _d(1_200_000_000_000_000_000, 0),
            Decimal.zero()
        );
        Decimal.D memory expected = _d(8_810_846_378_333_549_568, 79183);
        assertEq(result.exponent, 79183, "sumGeo count=1e6: exp");
        // 1e-5 relative tolerance — limited by error amplification via two pow(ratio, 1e6) calls
        assertLe(_relErr(result, expected), 1e13, "sumGeo count=1e6: 1e-5 rel");
    }

    // ── sumArithmeticSeries ───────────────────────────────────────────────────

    /// count=1e4, costInitial=100, costIncrease=5, currentOwned=0
    /// JS: 2.509750000000000e8  →  mantissa=2509750000000000000 exp=8
    function test_sumArith_count1e4_ref() public pure {
        Decimal.D memory result = Decimal.sumArithmeticSeries(
            _d(S, 4),       // count=10000
            _d(S, 2),       // costInitial=100
            _d(5 * S, 0),   // costIncrease=5
            Decimal.zero()
        );
        Decimal.D memory expected = _d(2_509_750_000_000_000_000, 8);
        assertEq(result.exponent, 8, "sumArith 1e4: exp");
        assertLe(_relErr(result, expected), 1e9, "sumArith 1e4: 1e-9 rel");
    }

    /// count=1e6, costInitial=100, costIncrease=5, currentOwned=0
    /// JS: 2.5000975e12  →  mantissa=2500097500000000000 exp=12
    function test_sumArith_count1e6_ref() public pure {
        Decimal.D memory result = Decimal.sumArithmeticSeries(
            _d(S, 6),       // count=1e6
            _d(S, 2),       // costInitial=100
            _d(5 * S, 0),   // costIncrease=5
            Decimal.zero()
        );
        Decimal.D memory expected = _d(2_500_097_500_000_000_000, 12);
        assertEq(result.exponent, 12, "sumArith 1e6: exp");
        assertLe(_relErr(result, expected), 1e9, "sumArith 1e6: 1e-9 rel");
    }

    // ── affordGeometricSeries ─────────────────────────────────────────────────

    /// budget=1e6, costInitial=100, costRatio=1.2, currentOwned=0
    /// JS: 41  →  mantissa=4099999999999999488 exp=1
    function test_affordGeo_budget1e6_ref() public pure {
        Decimal.D memory result = Decimal.affordGeometricSeries(
            _d(S, 6),                        // budget=1e6
            _d(S, 2),                        // costInitial=100
            _d(1_200_000_000_000_000_000, 0), // costRatio=1.2
            Decimal.zero()
        );
        // JS returns 41 exactly
        Decimal.D memory expected = _d(41 * S, 0);
        assertEq(result.exponent, 1, "affordGeo budget=1e6: exp");
        assertLe(_relErr(result, expected), 1e9, "affordGeo budget=1e6: 1e-9 rel");
    }

    /// budget=1e15, costInitial=10, costRatio=1.07, currentOwned=50
    /// JS: 387  →  mantissa=3870000000000000000 exp=2
    function test_affordGeo_largeGame_ref() public pure {
        Decimal.D memory result = Decimal.affordGeometricSeries(
            _d(S, 15),                       // budget=1e15
            _d(S, 1),                        // costInitial=10
            _d(1_070_000_000_000_000_000, 0), // costRatio=1.07
            _d(5 * S, 1)                     // currentOwned=50
        );
        Decimal.D memory expected = _d(3_870_000_000_000_000_000, 2); // 387 normalised
        assertEq(result.exponent, 2, "affordGeo large: exp");
        assertLe(_relErr(result, expected), 1e9, "affordGeo large: 1e-9 rel");
    }

    // ── Phase B: comparisons ──────────────────────────────────────────────────
    // JS: a.cmp(b), a.eq(b), a.lt(b), a.gt(b)

    function test_cmp_equal() public pure {
        // JS: 1e100.cmp(1e100) = 0
        Decimal.D memory a = _d(S, 100);
        assertEq(Decimal.cmp(a, a), 0, "cmp equal");
        assertTrue(Decimal.eq(a, a),  "eq equal");
        assertFalse(Decimal.lt(a, a), "lt equal");
        assertFalse(Decimal.gt(a, a), "gt equal");
    }

    function test_cmp_less() public pure {
        // JS: 1e100.cmp(1e101) = -1
        Decimal.D memory a = _d(S, 100);
        Decimal.D memory b = _d(S, 101);
        assertEq(Decimal.cmp(a, b), -1, "cmp a<b");
        assertTrue(Decimal.lt(a, b),   "lt a<b");
        assertTrue(Decimal.lte(a, b),  "lte a<b");
        assertFalse(Decimal.gt(a, b),  "gt a<b");
        assertFalse(Decimal.gte(a, b), "gte a<b");
    }

    function test_cmp_greater() public pure {
        // JS: 1e101.cmp(1e100) = 1
        Decimal.D memory a = _d(S, 101);
        Decimal.D memory b = _d(S, 100);
        assertEq(Decimal.cmp(a, b), 1,  "cmp a>b");
        assertTrue(Decimal.gt(a, b),    "gt a>b");
        assertTrue(Decimal.gte(a, b),   "gte a>b");
        assertFalse(Decimal.lt(a, b),   "lt a>b");
        assertFalse(Decimal.lte(a, b),  "lte a>b");
    }

    function test_cmp_negVsPos() public pure {
        // JS: (-1e100).cmp(1e100) = -1
        Decimal.D memory neg = Decimal.D({mantissa: S, exponent: 100, negative: true});
        Decimal.D memory pos = _d(S, 100);
        assertEq(Decimal.cmp(neg, pos), -1, "neg < pos");
        assertTrue(Decimal.lt(neg, pos),    "lt neg<pos");
    }

    function test_cmp_bothNegative() public pure {
        // JS: (-5).cmp(-3) = -1  (−5 is smaller than −3)
        Decimal.D memory n5 = Decimal.D({mantissa: 5 * S, exponent: 0, negative: true});
        Decimal.D memory n3 = Decimal.D({mantissa: 3 * S, exponent: 0, negative: true});
        assertEq(Decimal.cmp(n5, n3), -1, "cmp -5 < -3");
        assertEq(Decimal.cmp(n3, n5),  1, "cmp -3 > -5");
    }

    function test_cmp_zero() public pure {
        // JS: 0.cmp(0) = 0, 0.cmp(1) = -1, 1.cmp(0) = 1
        Decimal.D memory z = Decimal.zero();
        Decimal.D memory one = Decimal.one();
        assertEq(Decimal.cmp(z, z),   0,  "cmp 0==0");
        assertEq(Decimal.cmp(z, one), -1, "cmp 0<1");
        assertEq(Decimal.cmp(one, z),  1, "cmp 1>0");
    }

    function test_cmp_closeMantissa() public pure {
        // JS: 1.5e50.cmp(1.500000001e50) = -1
        // 1.5e50   → mantissa=1500000000000000000, exp=50
        // 1.500000001e50 → mantissa=1500000001000000000 (approx), exp=50
        Decimal.D memory a = _d(1_500_000_000_000_000_000, 50);
        Decimal.D memory b = _d(1_500_000_001_000_000_000, 50);
        assertEq(Decimal.cmp(a, b), -1, "cmp close mantissa");
        assertTrue(Decimal.lt(a, b),    "lt close mantissa");
    }

    function test_max_posValues() public pure {
        // JS: max(3, 5) = 5
        Decimal.D memory three = _d(3 * S, 0);
        Decimal.D memory five  = _d(5 * S, 0);
        assertTrue(Decimal.eq(Decimal.max(three, five), five),  "max(3,5)=5");
        assertTrue(Decimal.eq(Decimal.max(five, three), five),  "max(5,3)=5");
    }

    function test_min_posValues() public pure {
        // JS: min(3, 5) = 3
        Decimal.D memory three = _d(3 * S, 0);
        Decimal.D memory five  = _d(5 * S, 0);
        assertTrue(Decimal.eq(Decimal.min(three, five), three), "min(3,5)=3");
        assertTrue(Decimal.eq(Decimal.min(five, three), three), "min(5,3)=3");
    }

    function test_max_mixedSign() public pure {
        // JS: max(-1e50, 1e50) = 1e50
        Decimal.D memory neg = Decimal.D({mantissa: S, exponent: 50, negative: true});
        Decimal.D memory pos = _d(S, 50);
        assertTrue(Decimal.eq(Decimal.max(neg, pos), pos), "max(-1e50,1e50)=1e50");
        assertTrue(Decimal.eq(Decimal.min(neg, pos), neg), "min(-1e50,1e50)=-1e50");
    }

    // ── Phase A: fromUint / fromInt ───────────────────────────────────────────

    function test_fromUint_one() public pure {
        // JS: fromNumber(1) → mantissa=1e18 exp=0
        Decimal.D memory r = Decimal.fromUint(1);
        assertEq(r.mantissa, S, "fromUint(1): m");
        assertEq(r.exponent, 0, "fromUint(1): e");
        assertFalse(r.negative, "fromUint(1): neg");
    }

    function test_fromUint_largeInt() public pure {
        // JS: fromNumber(123456) → mantissa=1234560000000000000 exp=5
        Decimal.D memory r = Decimal.fromUint(123456);
        assertEq(r.mantissa, 1_234_560_000_000_000_000, "fromUint(123456): m");
        assertEq(r.exponent, 5, "fromUint(123456): e");
        assertFalse(r.negative, "fromUint(123456): neg");
    }

    function test_fromInt_negative() public pure {
        // JS: fromNumber(-1000) → mantissa=1e18 exp=3 neg=true
        Decimal.D memory r = Decimal.fromInt(-1000);
        assertEq(r.mantissa, S, "fromInt(-1000): m");
        assertEq(r.exponent, 3, "fromInt(-1000): e");
        assertTrue(r.negative, "fromInt(-1000): neg");
    }

    // ── Phase C: neg / abs / sign ─────────────────────────────────────────────

    function test_neg_positive() public pure {
        // JS: neg(1e50) → mantissa=1e18 exp=50 neg=true
        Decimal.D memory r = Decimal.neg(_d(S, 50));
        assertEq(r.mantissa, S,  "neg(1e50): m");
        assertEq(r.exponent, 50, "neg(1e50): e");
        assertTrue(r.negative,   "neg(1e50): negative");
    }

    function test_neg_negative() public pure {
        // JS: neg(-1e50) → mantissa=1e18 exp=50 neg=false
        Decimal.D memory neg50 = Decimal.D({mantissa: S, exponent: 50, negative: true});
        Decimal.D memory r = Decimal.neg(neg50);
        assertFalse(r.negative, "neg(-1e50): positive");
        assertEq(r.mantissa, S,  "neg(-1e50): m");
    }

    function test_abs_negative() public pure {
        // JS: abs(-1e50) → mantissa=1e18 exp=50 neg=false
        Decimal.D memory neg50 = Decimal.D({mantissa: S, exponent: 50, negative: true});
        Decimal.D memory r = Decimal.abs(neg50);
        assertFalse(r.negative, "abs(-1e50): positive");
        assertEq(r.mantissa, S,  "abs(-1e50): m");
    }

    function test_sign_values() public pure {
        // JS: sign(1e50)=1, sign(-1e50)=-1, sign(0)=0
        Decimal.D memory neg50 = Decimal.D({mantissa: S, exponent: 50, negative: true});
        assertTrue(Decimal.eq(Decimal.sign(_d(S, 50)), Decimal.one()),     "sign(pos)=1");
        assertTrue(Decimal.eq(Decimal.sign(neg50),     Decimal.negOne()),  "sign(neg)=-1");
        assertTrue(Decimal.eq(Decimal.sign(Decimal.zero()), Decimal.zero()), "sign(0)=0");
    }

    // ── Phase D: add / sub ────────────────────────────────────────────────────

    function test_add_sameExponent() public pure {
        // JS: 1e50 + 2e50 = 3e50
        Decimal.D memory r = Decimal.add(_d(S, 50), _d(2 * S, 50));
        assertEq(r.exponent, 50, "add same exp: e");
        assertLe(_relErr(r, _d(3 * S, 50)), 1e9, "add 1e50+2e50=3e50");
    }

    function test_sub_sameExponent() public pure {
        // JS: 5e100 - 2e100 = 3e100
        Decimal.D memory r = Decimal.sub(_d(5 * S, 100), _d(2 * S, 100));
        assertEq(r.exponent, 100, "sub same exp: e");
        assertLe(_relErr(r, _d(3 * S, 100)), 1e9, "sub 5e100-2e100=3e100");
    }

    function test_add_dominated() public pure {
        // JS: 1e50 + 1e30 ~= 1e50 (small term absorbed beyond sig-digits)
        Decimal.D memory r = Decimal.add(_d(S, 50), _d(S, 30));
        assertEq(r.exponent, 50, "add dominated: e");
        assertLe(_relErr(r, _d(S, 50)), 1e9, "add dominated");
    }

    function test_sub_cancellation() public pure {
        // JS: 1e50 - 1e50 = 0
        Decimal.D memory r = Decimal.sub(_d(S, 50), _d(S, 50));
        assertTrue(Decimal.eq(r, Decimal.zero()), "sub cancel=0");
    }

    function test_add_mixedSign() public pure {
        // JS: 3 + (-5) = -2
        Decimal.D memory n5 = Decimal.D({mantissa: 5 * S, exponent: 0, negative: true});
        Decimal.D memory r = Decimal.add(_d(3 * S, 0), n5);
        assertTrue(r.negative, "3+(-5): negative");
        assertLe(_relErr(r, _d(2 * S, 0)), 1e9, "3+(-5)=-2");
    }

    function test_add_bothNegative() public pure {
        // JS: -3 + (-5) = -8
        Decimal.D memory n3 = Decimal.D({mantissa: 3 * S, exponent: 0, negative: true});
        Decimal.D memory n5 = Decimal.D({mantissa: 5 * S, exponent: 0, negative: true});
        Decimal.D memory r = Decimal.add(n3, n5);
        assertTrue(r.negative, "-3+(-5): negative");
        assertLe(_relErr(r, _d(8 * S, 0)), 1e9, "-3+(-5)=-8");
    }

    // ── Phase E: mul / div / recip ────────────────────────────────────────────

    function test_mul_positive() public pure {
        // JS: 3e50 * 2e30 = 6e80
        Decimal.D memory r = Decimal.mul(_d(3 * S, 50), _d(2 * S, 30));
        assertEq(r.exponent, 80, "mul: e");
        assertLe(_relErr(r, _d(6 * S, 80)), 1e9, "3e50*2e30=6e80");
    }

    function test_div_positive() public pure {
        // JS: 6e80 / 2e30 = 3e50
        Decimal.D memory r = Decimal.div(_d(6 * S, 80), _d(2 * S, 30));
        assertEq(r.exponent, 50, "div: e");
        assertLe(_relErr(r, _d(3 * S, 50)), 1e9, "6e80/2e30=3e50");
    }

    function test_recip_four() public pure {
        // JS: recip(4) = 0.25 = 2.5e-1 → mantissa=2500000000000000000 exp=-1
        Decimal.D memory r = Decimal.recip(_d(4 * S, 0));
        assertEq(r.exponent, -1, "recip(4): e");
        assertLe(_relErr(r, _d(2_500_000_000_000_000_000, -1)), 1e9, "recip(4)=0.25");
    }

    function test_mul_mixedSign() public pure {
        // JS: 2e50 * (-3e20) = -6e70
        Decimal.D memory neg3e20 = Decimal.D({mantissa: 3 * S, exponent: 20, negative: true});
        Decimal.D memory r = Decimal.mul(_d(2 * S, 50), neg3e20);
        assertTrue(r.negative,   "mul mixed: negative");
        assertEq(r.exponent, 70, "mul mixed: e");
        assertLe(_relErr(r, _d(6 * S, 70)), 1e9, "2e50*(-3e20)=-6e70");
    }

    // ── Phase F: sqrt / cbrt / sqr / cube / pow ───────────────────────────────

    function test_sqrt_four() public pure {
        // JS: sqrt(4) = 2
        assertLe(_relErr(Decimal.sqrt(_d(4 * S, 0)), _d(2 * S, 0)), 1e10, "sqrt(4)=2");
    }

    function test_sqrt_largePow() public pure {
        // JS: sqrt(1e100) = 1e50
        Decimal.D memory r = Decimal.sqrt(_d(S, 100));
        assertEq(r.exponent, 50, "sqrt(1e100): e");
        assertLe(_relErr(r, _d(S, 50)), 1e10, "sqrt(1e100)=1e50");
    }

    function test_cbrt_eight() public pure {
        // JS: cbrt(8) = 2
        assertLe(_relErr(Decimal.cbrt(_d(8 * S, 0)), _d(2 * S, 0)), 1e10, "cbrt(8)=2");
    }

    function test_cbrt_largePow() public pure {
        // JS: cbrt(1e99) = 1e33
        Decimal.D memory r = Decimal.cbrt(_d(S, 99));
        assertEq(r.exponent, 33, "cbrt(1e99): e");
        assertLe(_relErr(r, _d(S, 33)), 1e10, "cbrt(1e99)=1e33");
    }

    function test_sqr_three() public pure {
        // JS: sqr(3) = 9
        assertLe(_relErr(Decimal.sqr(_d(3 * S, 0)), _d(9 * S, 0)), 1e9, "sqr(3)=9");
    }

    function test_cube_two() public pure {
        // JS: cube(2) = 8
        assertLe(_relErr(Decimal.cube(_d(2 * S, 0)), _d(8 * S, 0)), 1e9, "cube(2)=8");
    }

    function test_pow_intExponent() public pure {
        // JS: pow(2, 10) = 1024 → mantissa=1024000000000000000 exp=3
        Decimal.D memory r = Decimal.pow(_d(2 * S, 0), _d(S, 1));
        assertEq(r.exponent, 3, "pow(2,10): e");
        assertLe(_relErr(r, _d(1_024_000_000_000_000_000, 3)), 1e10, "pow(2,10)=1024");
    }

    function test_pow_largePow() public pure {
        // JS: pow(1e10, 5) = 1e50
        Decimal.D memory r = Decimal.pow(_d(S, 10), _d(5 * S, 0));
        assertEq(r.exponent, 50, "pow(1e10,5): e");
        assertLe(_relErr(r, _d(S, 50)), 1e10, "pow(1e10,5)=1e50");
    }

    function test_pow_negativeExponent() public pure {
        // JS: pow(2, -3) = 0.125 → mantissa=1250000000000000000 exp=-1
        Decimal.D memory neg3 = Decimal.D({mantissa: 3 * S, exponent: 0, negative: true});
        Decimal.D memory r = Decimal.pow(_d(2 * S, 0), neg3);
        assertEq(r.exponent, -1, "pow(2,-3): e");
        assertLe(_relErr(r, _d(1_250_000_000_000_000_000, -1)), 1e10, "pow(2,-3)=0.125");
    }

    // ── Phase G: log10 / log2 / ln / log ─────────────────────────────────────

    function test_log10_intPower() public pure {
        // JS: log10(1e50) = 50 → D{5e18, 1}
        Decimal.D memory r = Decimal.log10(_d(S, 50));
        assertEq(r.exponent, 1, "log10(1e50): e");
        assertLe(_relErr(r, _d(5 * S, 1)), 1e9, "log10(1e50)=50");
    }

    function test_log10_two() public pure {
        // JS: log10(2) = 0.30102999566… → D{3010299956639812000, -1}
        Decimal.D memory r = Decimal.log10(_d(2 * S, 0));
        assertEq(r.exponent, -1, "log10(2): e");
        assertLe(_relErr(r, _d(3_010_299_956_639_812_000, -1)), 1e10, "log10(2)");
    }

    function test_log2_exactPow() public pure {
        // JS: log2(32) = 5 → D{5e18, 0}
        // (1024=10 sits on an exp boundary; 32=5 avoids that.)
        Decimal.D memory r = Decimal.log2(_d(32 * S, 0));
        assertEq(r.exponent, 0, "log2(32): e");
        assertLe(_relErr(r, _d(5 * S, 0)), 1e10, "log2(32)=5");
    }

    function test_ln_e() public pure {
        // JS: ln(e) ~= 1.0 → D{1e18, 0}
        Decimal.D memory e_val = _d(2_718_281_828_459_044_864, 0);
        Decimal.D memory r = Decimal.ln(e_val);
        assertLe(_relErr(r, _d(S, 0)), 1e10, "ln(e)~=1");
    }

    function test_log_base2() public pure {
        // JS: log(8, 2) = 3 → D{3e18, 0}
        assertLe(_relErr(Decimal.log(_d(8 * S, 0), _d(2 * S, 0)), _d(3 * S, 0)), 1e10, "log(8,2)=3");
    }

    function test_log_base10_largePow() public pure {
        // JS: log(1e30, 10) = 30 → D{3e18, 1}
        Decimal.D memory r = Decimal.log(_d(S, 30), _d(S, 1));
        assertEq(r.exponent, 1, "log(1e30,10): e");
        assertLe(_relErr(r, _d(3 * S, 1)), 1e9, "log(1e30,10)=30");
    }

    // ── Phase H: floor / ceil / round / trunc ─────────────────────────────────

    function test_floor_positiveFrac() public pure {
        // JS: floor(3.7) = 3
        assertTrue(Decimal.eq(Decimal.floor(_d(3_700_000_000_000_000_000, 0)), _d(3 * S, 0)), "floor(3.7)=3");
    }

    function test_floor_negativeFrac() public pure {
        // JS: floor(-3.7) = -4
        Decimal.D memory neg37 = Decimal.D({mantissa: 3_700_000_000_000_000_000, exponent: 0, negative: true});
        Decimal.D memory expected = Decimal.D({mantissa: 4 * S, exponent: 0, negative: true});
        assertTrue(Decimal.eq(Decimal.floor(neg37), expected), "floor(-3.7)=-4");
    }

    function test_ceil_positiveFrac() public pure {
        // JS: ceil(3.2) = 4
        assertTrue(Decimal.eq(Decimal.ceil(_d(3_200_000_000_000_000_000, 0)), _d(4 * S, 0)), "ceil(3.2)=4");
    }

    function test_ceil_negativeFrac() public pure {
        // JS: ceil(-3.2) = -3
        Decimal.D memory neg32 = Decimal.D({mantissa: 3_200_000_000_000_000_000, exponent: 0, negative: true});
        Decimal.D memory expected = Decimal.D({mantissa: 3 * S, exponent: 0, negative: true});
        assertTrue(Decimal.eq(Decimal.ceil(neg32), expected), "ceil(-3.2)=-3");
    }

    function test_round_halfUp() public pure {
        // JS: round(3.5) = 4
        assertTrue(Decimal.eq(Decimal.round(_d(3_500_000_000_000_000_000, 0)), _d(4 * S, 0)), "round(3.5)=4");
    }

    function test_round_down() public pure {
        // JS: round(3.4) = 3
        assertTrue(Decimal.eq(Decimal.round(_d(3_400_000_000_000_000_000, 0)), _d(3 * S, 0)), "round(3.4)=3");
    }

    function test_trunc_positive() public pure {
        // JS: trunc(3.9) = 3
        assertTrue(Decimal.eq(Decimal.trunc(_d(3_900_000_000_000_000_000, 0)), _d(3 * S, 0)), "trunc(3.9)=3");
    }

    function test_trunc_negative() public pure {
        // JS: trunc(-3.9) = -3
        Decimal.D memory neg39 = Decimal.D({mantissa: 3_900_000_000_000_000_000, exponent: 0, negative: true});
        Decimal.D memory expected = Decimal.D({mantissa: 3 * S, exponent: 0, negative: true});
        assertTrue(Decimal.eq(Decimal.trunc(neg39), expected), "trunc(-3.9)=-3");
    }

    // ── Phase I: exp ──────────────────────────────────────────────────────────

    function test_exp_zero() public pure {
        // JS: exp(0) = 1
        assertTrue(Decimal.eq(Decimal.exp(Decimal.zero()), Decimal.one()), "exp(0)=1");
    }

    function test_exp_one() public pure {
        // JS: exp(1) = e → mantissa=2718281828459044864 exp=0
        Decimal.D memory r = Decimal.exp(Decimal.one());
        assertEq(r.exponent, 0, "exp(1): e");
        assertLe(_relErr(r, _d(2_718_281_828_459_044_864, 0)), 1e10, "exp(1)=e");
    }

    function test_exp_ten() public pure {
        // JS: exp(10) → mantissa=2202646579480672000 exp=4
        Decimal.D memory r = Decimal.exp(_d(S, 1));
        assertEq(r.exponent, 4, "exp(10): e");
        assertLe(_relErr(r, _d(2_202_646_579_480_672_000, 4)), 1e10, "exp(10)");
    }

    function test_exp_negOne() public pure {
        // JS: exp(-1) = 1/e → mantissa=3678794411714423296 exp=-1
        Decimal.D memory r = Decimal.exp(Decimal.negOne());
        assertEq(r.exponent, -1, "exp(-1): e");
        assertLe(_relErr(r, _d(3_678_794_411_714_423_296, -1)), 1e10, "exp(-1)=1/e");
    }

    function test_exp_hundred() public pure {
        // JS: exp(100) → mantissa=2688117141816135168 exp=43
        Decimal.D memory r = Decimal.exp(_d(S, 2));
        assertEq(r.exponent, 43, "exp(100): e");
        // actual relative error ~4.4e-8
        assertLe(_relErr(r, _d(2_688_117_141_816_135_168, 43)), 5e10, "exp(100)");
    }

    /// exp(1e6): minimax polynomial brings this within precision target.
    /// JS: 3.0332153969064635e434294  →  mantissa=3033215396906463232 exp=434294
    function test_exp_1e6_ref() public pure {
        Decimal.D memory r = Decimal.exp(_d(S, 6));
        assertEq(r.exponent, 434294, "exp(1e6): e");
        // 1e-9 relative tolerance — minimax polynomial brings this within precision target
        assertLe(_relErr(r, _d(3_033_215_396_906_463_232, 434294)), 1e9, "exp(1e6): 1e-9 rel");
    }

    // ── Phase J: sinh / cosh / tanh / asinh / acosh / atanh ──────────────────

    function test_sinh_zero() public pure {
        // JS: sinh(0) = 0
        assertTrue(Decimal.eq(Decimal.sinh(Decimal.zero()), Decimal.zero()), "sinh(0)=0");
    }

    function test_cosh_zero() public pure {
        // JS: cosh(0) = 1
        assertTrue(Decimal.eq(Decimal.cosh(Decimal.zero()), Decimal.one()), "cosh(0)=1");
    }

    function test_tanh_zero() public pure {
        // JS: tanh(0) = 0
        assertTrue(Decimal.eq(Decimal.tanh(Decimal.zero()), Decimal.zero()), "tanh(0)=0");
    }

    function test_sinh_one() public pure {
        // JS: sinh(1) → mantissa=1175201193643800064 exp=0
        Decimal.D memory r = Decimal.sinh(Decimal.one());
        assertEq(r.exponent, 0, "sinh(1): e");
        assertLe(_relErr(r, _d(1_175_201_193_643_800_064, 0)), 1e10, "sinh(1)");
    }

    function test_cosh_one() public pure {
        // JS: cosh(1) → mantissa=1543080634815245056 exp=0
        Decimal.D memory r = Decimal.cosh(Decimal.one());
        assertEq(r.exponent, 0, "cosh(1): e");
        assertLe(_relErr(r, _d(1_543_080_634_815_245_056, 0)), 1e10, "cosh(1)");
    }

    function test_tanh_one() public pure {
        // JS: tanh(1) → mantissa=7615941559557633024 exp=-1
        Decimal.D memory r = Decimal.tanh(Decimal.one());
        assertEq(r.exponent, -1, "tanh(1): e");
        assertLe(_relErr(r, _d(7_615_941_559_557_633_024, -1)), 1e10, "tanh(1)");
    }

    function test_sinh_ten() public pure {
        // JS: sinh(10) → mantissa=1101323287470339968 exp=4
        Decimal.D memory r = Decimal.sinh(_d(S, 1));
        assertEq(r.exponent, 4, "sinh(10): e");
        assertLe(_relErr(r, _d(1_101_323_287_470_339_968, 4)), 1e10, "sinh(10)");
    }

    function test_cosh_ten() public pure {
        // JS: cosh(10) → mantissa=1101323292010335104 exp=4
        Decimal.D memory r = Decimal.cosh(_d(S, 1));
        assertEq(r.exponent, 4, "cosh(10): e");
        assertLe(_relErr(r, _d(1_101_323_292_010_335_104, 4)), 1e10, "cosh(10)");
    }

    function test_asinh_one() public pure {
        // Math.asinh(1) = 0.881373587019543 → 8.81373… × 10^-1
        Decimal.D memory r = Decimal.asinh(Decimal.one());
        assertEq(r.exponent, -1, "asinh(1): e");
        assertLe(_relErr(r, _d(8_813_735_870_195_430_000, -1)), 1e10, "asinh(1)");
    }

    function test_acosh_two() public pure {
        // Math.acosh(2) = 1.3169578969248166 → 1.3169… × 10^0
        Decimal.D memory r = Decimal.acosh(_d(2 * S, 0));
        assertEq(r.exponent, 0, "acosh(2): e");
        assertLe(_relErr(r, _d(1_316_957_896_924_816_600, 0)), 1e10, "acosh(2)");
    }

    function test_atanh_half() public pure {
        // Math.atanh(0.5) = 0.5493061443340548 → 5.493… × 10^-1
        // 0.5 = D{5e18, -1}
        Decimal.D memory r = Decimal.atanh(_d(5 * S, -1));
        assertEq(r.exponent, -1, "atanh(0.5): e");
        assertLe(_relErr(r, _d(5_493_061_443_340_548_000, -1)), 1e10, "atanh(0.5)");
    }

    // ── Phase L: factorial / pLog10 / absLog10 / decimalPlaces ───────────────

    function test_factorial_five() public pure {
        // 5! = 120 → D{1.2e18, 2}; Stirling-based, JS: mantissa~=1200000001961021440
        Decimal.D memory r = Decimal.factorial(_d(5 * S, 0));
        assertEq(r.exponent, 2, "factorial(5): e");
        assertLe(_relErr(r, _d(1_200_000_000_000_000_000, 2)), 1e12, "factorial(5)~=120");
    }

    function test_factorial_ten() public pure {
        // 10! = 3628800 → D{3.6288e18, 6}; JS: mantissa=3628800000087976448
        Decimal.D memory r = Decimal.factorial(_d(S, 1));
        assertEq(r.exponent, 6, "factorial(10): e");
        assertLe(_relErr(r, _d(3_628_800_000_000_000_000, 6)), 1e10, "factorial(10)~=3628800");
    }

    function test_factorial_hundred() public pure {
        // log10(100!) = 157.9700… → exp=157; JS: mantissa=9332621544394332160
        Decimal.D memory r = Decimal.factorial(_d(S, 2));
        assertEq(r.exponent, 157, "factorial(100): e");
        // actual relative error ~1.6e-7
        assertLe(_relErr(r, _d(9_332_621_544_394_332_160, 157)), 2e11, "factorial(100)");
    }

    function test_pLog10_largePow() public pure {
        // JS: pLog10(1e50) = 50 → D{5e18, 1}
        Decimal.D memory r = Decimal.pLog10(_d(S, 50));
        assertEq(r.exponent, 1, "pLog10(1e50): e");
        assertLe(_relErr(r, _d(5 * S, 1)), 1e9, "pLog10(1e50)=50");
    }

    function test_pLog10_smallValue() public pure {
        // JS: pLog10(0.001) = max(0, -3) = 0
        assertTrue(Decimal.eq(Decimal.pLog10(_d(S, -3)), Decimal.zero()), "pLog10(0.001)=0");
    }

    function test_absLog10_negative() public pure {
        // JS: absLog10(-1e50) = 50 → D{5e18, 1}
        Decimal.D memory neg50 = Decimal.D({mantissa: S, exponent: 50, negative: true});
        Decimal.D memory r = Decimal.absLog10(neg50);
        assertEq(r.exponent, 1, "absLog10(-1e50): e");
        assertLe(_relErr(r, _d(5 * S, 1)), 1e9, "absLog10(-1e50)=50");
    }

    function test_decimalPlaces_integer() public pure {
        // JS: dp(1e50) = 0
        assertEq(Decimal.decimalPlaces(_d(S, 50)), 0, "dp(1e50)=0");
    }

    function test_decimalPlaces_fracPart() public pure {
        // JS: dp(1.5) = 1  →  D{1.5e18, 0}
        assertEq(Decimal.decimalPlaces(_d(1_500_000_000_000_000_000, 0)), 1, "dp(1.5)=1");
    }
}
