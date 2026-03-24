// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Correctness tests for Phase L: factorial, decimalPlaces, pLog10, absLog10.
contract DecimalLTest is Test {

    uint128 constant S = uint128(Decimal.MANTISSA_SCALE);

    function _d(uint128 m, int64 e) internal pure returns (Decimal.D memory) {
        return Decimal.D({mantissa: m, exponent: e, negative: false});
    }

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

    // ── factorial — exact values ──────────────────────────────────────────────

    function test_factorial_zero_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.factorial(Decimal.zero()), Decimal.one()), "0! = 1");
    }

    function test_factorial_one_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.factorial(Decimal.one()), Decimal.one()), "1! = 1");
    }

    function test_factorial_two() public pure {
        Decimal.D memory r = Decimal.factorial(_d(2 * S, 0));
        assertLe(_relErr(r, _d(2 * S, 0)), 0, "2! = 2");
    }

    function test_factorial_five() public pure {
        // 5! = 120
        Decimal.D memory r = Decimal.factorial(_d(5 * S, 0));
        assertLe(_relErr(r, _d(12 * S, 1)), 0, "5! = 120");
    }

    function test_factorial_ten() public pure {
        // 10! = 3628800  →  D{mantissa: 3628800 / 1e6 * 1e18, exponent: 6}
        Decimal.D memory r        = Decimal.factorial(_d(S, 1));
        Decimal.D memory expected = Decimal.D({mantissa: 3_628_800_000_000_000_000, exponent: 6, negative: false});
        assertLe(_relErr(r, expected), 0, "10! = 3628800");
    }

    function test_factorial_eighteen() public pure {
        // 18! = 6402373705728000  (last exact lookup entry)
        Decimal.D memory r        = Decimal.factorial(_d(18 * S, 0));
        Decimal.D memory expected = Decimal.D({
            mantissa: 6_402_373_705_728_000 * S / 1_000_000_000_000_000,
            exponent: 15,
            negative: false
        });
        // 6402373705728000 = 6.402373705728 e15  →  mantissa ≈ 6.4e18, exponent=15
        assertLe(_relErr(r, expected), 1e9, "18! exact lookup");
    }

    // ── factorial — Stirling approximation ────────────────────────────────────

    function test_factorial_twenty() public pure {
        // 20! = 2432902008176640000 = 2.432902008176640000e18  exponent=18
        // With 1/(12n) Stirling correction: error O(1/n^3) ~3.5e-7 for n=20
        Decimal.D memory r        = Decimal.factorial(_d(2 * S, 1));
        Decimal.D memory expected = Decimal.D({mantissa: 2_432_902_008_176_640_000, exponent: 18, negative: false});
        assertLe(_relErr(r, expected), 5e11, "20! Stirling+correction within 5e-7");
    }

    function test_factorial_fifty() public pure {
        // 50! ~= 3.04140932e64
        // With correction: error O(1/n^3) ~2.2e-9 for n=50
        Decimal.D memory r        = Decimal.factorial(_d(5 * S, 1));
        Decimal.D memory expected = Decimal.D({mantissa: 3_041_409_320_171_337_804, exponent: 64, negative: false});
        assertLe(_relErr(r, expected), 1e11, "50! Stirling within 1e-7");
    }

    function test_factorial_hundred() public pure {
        // 100! ~= 9.3326215e157
        // With correction: error O(1/n^3) ~2.8e-10 for n=100
        Decimal.D memory r        = Decimal.factorial(_d(S, 2));
        Decimal.D memory expected = Decimal.D({mantissa: 9_332_621_544_394_415_268, exponent: 157, negative: false});
        assertLe(_relErr(r, expected), 3e11, "100! Stirling within 3e-7");
    }

    // ── factorial — boundary and edge cases ──────────────────────────────────

    function test_factorial_negative_isFact0() public pure {
        // negative input  ->  treated as 0  ->  1
        Decimal.D memory neg = Decimal.D({mantissa: S, exponent: 0, negative: true});
        assertTrue(Decimal.eq(Decimal.factorial(neg), Decimal.one()), "factorial(-x) = 1");
    }

    function test_factorial_fraction_isFact0() public pure {
        // fractional input (exponent < 0)  ->  floor = 0  ->  0! = 1
        Decimal.D memory half = Decimal.D({mantissa: 5 * S, exponent: -1, negative: false});
        assertTrue(Decimal.eq(Decimal.factorial(half), Decimal.one()), "factorial(0.5) = 1");
    }

    function test_factorial_positive() public pure {
        // n! is always >= 1 for n >= 0
        assertTrue(Decimal.gte(Decimal.factorial(_d(7 * S, 0)), Decimal.one()), "7! >= 1");
    }

    // ── factorial — monotonicity at boundary ─────────────────────────────────

    function test_factorial_boundary_18_to_19() public pure {
        // 19! > 18!
        Decimal.D memory f18 = Decimal.factorial(_d(18 * S, 0));
        Decimal.D memory f19 = Decimal.factorial(_d(19 * S, 0));
        assertTrue(Decimal.gt(f19, f18), "19! > 18! (boundary)");
    }

    // ── decimalPlaces ─────────────────────────────────────────────────────────

    function test_decimalPlaces_zero_isZero() public pure {
        assertEq(Decimal.decimalPlaces(Decimal.zero()), 0, "decimalPlaces(0) = 0");
    }

    function test_decimalPlaces_integer() public pure {
        // 1000 = {mantissa: 1e18, exponent: 3}  ->  trailing zeros = 18, 18-3-18 = -3  ->  0
        assertEq(Decimal.decimalPlaces(_d(S, 3)), 0, "decimalPlaces(1000) = 0");
    }

    function test_decimalPlaces_one() public pure {
        // 1 = {mantissa: 1e18, exponent: 0}  ->  trailing zeros = 18  ->  18-0-18 = 0
        assertEq(Decimal.decimalPlaces(Decimal.one()), 0, "decimalPlaces(1) = 0");
    }

    function test_decimalPlaces_pointOne() public pure {
        // 0.1 = {mantissa: 1e18, exponent: -1}  ->  tz=18  ->  18-18-(-1) = 1
        assertEq(Decimal.decimalPlaces(_d(S, -1)), 1, "decimalPlaces(0.1) = 1");
    }

    function test_decimalPlaces_pointZeroZeroOne() public pure {
        // 0.001 = {mantissa: 1e18, exponent: -3}  ->  tz=18  ->  18-18+3 = 3
        assertEq(Decimal.decimalPlaces(_d(S, -3)), 3, "decimalPlaces(0.001) = 3");
    }

    function test_decimalPlaces_onePointFive() public pure {
        // 1.5 = {mantissa: 1.5e18 = 1500000000000000000, exponent: 0}
        // trailing zeros of 1500000000000000000 = 17  ->  18-0-17 = 1
        Decimal.D memory onePointFive = Decimal.D({mantissa: 15 * S / 10, exponent: 0, negative: false});
        assertEq(Decimal.decimalPlaces(onePointFive), 1, "decimalPlaces(1.5) = 1");
    }

    function test_decimalPlaces_fivePointTwoFive() public pure {
        // 5.25 = {mantissa: 5.25e18 = 5250000000000000000, exponent: 0}
        // trailing zeros of 5250000000000000000 = 16  ->  18-0-16 = 2
        Decimal.D memory d = Decimal.D({mantissa: 525 * S / 100, exponent: 0, negative: false});
        assertEq(Decimal.decimalPlaces(d), 2, "decimalPlaces(5.25) = 2");
    }

    function test_decimalPlaces_large_isZero() public pure {
        // 1e20 = {mantissa: 1e18, exponent: 20}  ->  tz=18  ->  18-20-18 < 0  ->  0
        assertEq(Decimal.decimalPlaces(_d(S, 20)), 0, "decimalPlaces(1e20) = 0");
    }

    // ── pLog10 ────────────────────────────────────────────────────────────────

    function test_pLog10_one_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.pLog10(Decimal.one()), Decimal.zero()), "pLog10(1) = 0");
    }

    function test_pLog10_ten_isOne() public pure {
        Decimal.D memory r = Decimal.pLog10(_d(S, 1));
        assertLe(_relErr(r, Decimal.one()), 2e9, "pLog10(10) = 1");
    }

    function test_pLog10_lessThanOne_isZero() public pure {
        // pLog10(0.5) = max(0, log10(0.5)) = max(0, -0.3..) = 0
        Decimal.D memory half = Decimal.D({mantissa: 5 * S, exponent: -1, negative: false});
        assertTrue(Decimal.eq(Decimal.pLog10(half), Decimal.zero()), "pLog10(0.5) = 0");
    }

    function test_pLog10_gtOne_positive() public pure {
        Decimal.D memory r = Decimal.pLog10(_d(2 * S, 0));
        assertTrue(Decimal.gt(r, Decimal.zero()), "pLog10(2) > 0");
    }

    // ── absLog10 ──────────────────────────────────────────────────────────────

    function test_absLog10_positive() public pure {
        Decimal.D memory r = Decimal.absLog10(_d(S, 1));
        assertLe(_relErr(r, Decimal.one()), 2e9, "absLog10(10) = 1");
    }

    function test_absLog10_negative() public pure {
        // log10(|-10|) = log10(10) = 1
        Decimal.D memory negTen = Decimal.D({mantissa: S, exponent: 1, negative: true});
        Decimal.D memory r      = Decimal.absLog10(negTen);
        assertLe(_relErr(r, Decimal.one()), 2e9, "absLog10(-10) = 1");
    }

    function test_absLog10_equals_log10_for_positive() public pure {
        Decimal.D memory x  = _d(3 * S, 0);
        assertLe(_relErr(Decimal.absLog10(x), Decimal.log10(x)), 0, "absLog10(x) == log10(x) for x>0");
    }
}
