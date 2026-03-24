// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Red-team / adversarial test suite for Phase F-14:
///         Decimal.pow10(int64 n) -- fast-path constructor.
///
/// Attack surfaces:
///   (1)  Struct fields: mantissa == MANTISSA_SCALE, exponent == n, negative == false
///   (2)  Already normalised: mantissa in [SCALE, 10*SCALE)
///   (3)  pow10(0) == one()
///   (4)  Boundary exponents: EXP_LIMIT, -EXP_LIMIT
///   (5)  Monotonicity: pow10(a) < pow10(b) iff a < b  (fuzz)
///   (6)  Multiplicative inverse: mul(pow10(n), pow10(-n)) == one()  (fuzz)
///   (7)  Composition: mul(pow10(a), pow10(b)) == pow10(a+b)  (fuzz, within EXP_LIMIT)
///   (8)  Division: div(pow10(n), pow10(n)) == one()  (fuzz)
///   (9)  Negative exponents: eq(pow10(-n), recip(pow10(n)))  (fuzz)
///  (10)  Cube / square identities: sq(pow10(n)) == pow10(2n), cube == pow10(3n)
contract PhaseFRedTeam14Test is Test {

    uint128 constant S  = uint128(Decimal.MANTISSA_SCALE);
    int64   constant EL = Decimal.EXP_LIMIT;

    // -------------------------------------------------------------------------
    // (1) Struct fields are exact
    // -------------------------------------------------------------------------

    function test_pow10_fields_positive() public pure {
        Decimal.D memory d = Decimal.pow10(7);
        assertEq(d.mantissa, S,    "mantissa == SCALE");
        assertEq(d.exponent, 7,    "exponent == n");
        assertFalse(d.negative,    "negative == false");
    }

    function test_pow10_fields_negative() public pure {
        Decimal.D memory d = Decimal.pow10(-5);
        assertEq(d.mantissa, S,    "mantissa == SCALE");
        assertEq(d.exponent, -5,   "exponent == n");
        assertFalse(d.negative,    "negative == false");
    }

    function testFuzz_pow10_fields(int8 rawN) public pure {
        int64 n = int64(rawN);
        Decimal.D memory d = Decimal.pow10(n);
        assertEq(d.mantissa, S,  "mantissa == SCALE");
        assertEq(d.exponent, n,  "exponent == n");
        assertFalse(d.negative,  "negative == false");
    }

    // -------------------------------------------------------------------------
    // (2) Already normalised
    // -------------------------------------------------------------------------

    function testFuzz_pow10_normalised(int8 rawN) public pure {
        int64 n = int64(rawN);
        Decimal.D memory d = Decimal.pow10(n);
        assertGe(d.mantissa, S,      "mantissa >= SCALE");
        assertLt(d.mantissa, 10 * S, "mantissa < 10*SCALE");
        assertFalse(d.negative,      "not negative");
    }

    // -------------------------------------------------------------------------
    // (3) pow10(0) == one()
    // -------------------------------------------------------------------------

    function test_pow10_zero_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.pow10(0), Decimal.one()), "pow10(0) == 1");
    }

    // -------------------------------------------------------------------------
    // (4) Boundary exponents
    // -------------------------------------------------------------------------

    function test_pow10_atExpLimit() public pure {
        Decimal.D memory d = Decimal.pow10(EL);
        assertEq(d.exponent, EL, "exponent at EXP_LIMIT");
        assertEq(d.mantissa, S,  "mantissa == SCALE");
    }

    function test_pow10_atNegExpLimit() public pure {
        Decimal.D memory d = Decimal.pow10(-EL);
        assertEq(d.exponent, -EL, "exponent at -EXP_LIMIT");
        assertEq(d.mantissa, S,   "mantissa == SCALE");
    }

    // -------------------------------------------------------------------------
    // (5) Monotonicity: pow10(a) < pow10(b) when a < b
    // -------------------------------------------------------------------------

    function testFuzz_pow10_monotone(int8 rawA, int8 rawB) public pure {
        int64 a = int64(rawA);
        int64 b = int64(rawB);
        if (a >= b) return;
        assertTrue(Decimal.lt(Decimal.pow10(a), Decimal.pow10(b)),
            "pow10 not monotone");
    }

    // -------------------------------------------------------------------------
    // (6) Multiplicative inverse: pow10(n) * pow10(-n) == 1
    // -------------------------------------------------------------------------

    function testFuzz_pow10_mulInverse(int8 rawN) public pure {
        int64 n = int64(rawN);
        // Both n and -n must be within EXP_LIMIT (all int8 values are safe)
        Decimal.D memory r = Decimal.mul(Decimal.pow10(n), Decimal.pow10(-n));
        assertTrue(Decimal.eq(r, Decimal.one()),
            "pow10(n) * pow10(-n) != 1");
    }

    // -------------------------------------------------------------------------
    // (7) Composition: mul(pow10(a), pow10(b)) == pow10(a+b)
    //     Restrict to int8 so a+b stays within int64 and EXP_LIMIT.
    // -------------------------------------------------------------------------

    function testFuzz_pow10_composition(int8 rawA, int8 rawB) public pure {
        int64 a = int64(rawA);
        int64 b = int64(rawB);
        Decimal.D memory prod     = Decimal.mul(Decimal.pow10(a), Decimal.pow10(b));
        Decimal.D memory expected = Decimal.pow10(a + b);
        assertTrue(Decimal.eq(prod, expected),
            "mul(pow10(a), pow10(b)) != pow10(a+b)");
    }

    // -------------------------------------------------------------------------
    // (8) Division identity: pow10(n) / pow10(n) == 1
    // -------------------------------------------------------------------------

    function testFuzz_pow10_divSelf(int8 rawN) public pure {
        int64 n = int64(rawN);
        Decimal.D memory r = Decimal.div(Decimal.pow10(n), Decimal.pow10(n));
        assertTrue(Decimal.eq(r, Decimal.one()),
            "pow10(n) / pow10(n) != 1");
    }

    // -------------------------------------------------------------------------
    // (9) Reciprocal: recip(pow10(n)) == pow10(-n)
    // -------------------------------------------------------------------------

    function testFuzz_pow10_recip(int8 rawN) public pure {
        int64 n = int64(rawN);
        Decimal.D memory r = Decimal.recip(Decimal.pow10(n));
        assertTrue(Decimal.eq(r, Decimal.pow10(-n)),
            "recip(pow10(n)) != pow10(-n)");
    }

    // -------------------------------------------------------------------------
    // (10) Square and cube identities
    // -------------------------------------------------------------------------

    function testFuzz_pow10_square(int8 rawN) public pure {
        int64 n = int64(rawN);
        // sqr(pow10(n)) = mul(pow10(n), pow10(n)) = pow10(2n)
        // Restrict: 2n must stay within int64 range for int8 input, guaranteed.
        Decimal.D memory r = Decimal.sqr(Decimal.pow10(n));
        assertTrue(Decimal.eq(r, Decimal.pow10(2 * n)),
            "sqr(pow10(n)) != pow10(2n)");
    }

    function testFuzz_pow10_cube(int8 rawN) public pure {
        int64 n = int64(rawN);
        // cube(pow10(n)) = pow10(3n); int8 * 3 fits in int64.
        Decimal.D memory r = Decimal.cube(Decimal.pow10(n));
        assertTrue(Decimal.eq(r, Decimal.pow10(3 * n)),
            "cube(pow10(n)) != pow10(3n)");
    }
}
