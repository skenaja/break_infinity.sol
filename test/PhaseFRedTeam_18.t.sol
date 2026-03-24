// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Red-team / adversarial test suite for Phase F-18:
///         Decimal.sqr(a) = mul(a,a)  and  Decimal.cube(a) = mul(a, sqr(a)).
///
/// Attack surfaces:
///   (1)  sqr(0) = 0;  cube(0) = 0
///   (2)  sqr(1) = 1;  cube(1) = 1
///   (3)  sqr(-a) = sqr(a)  (sign cancels)
///   (4)  cube(-a) = -cube(a)  (sign preserved)
///   (5)  sqr(pow10(n)) = pow10(2n)  (exact)
///   (6)  cube(pow10(n)) = pow10(3n)  (exact)
///   (7)  sqr(a) = mul(a, a)  (consistency, fuzz)
///   (8)  cube(a) = mul(sqr(a), a) = mul(a, mul(a, a))  (consistency, fuzz)
///   (9)  sqr(a) >= 0  always  (non-negative output)
///  (10)  cube(a) sign == a sign  (cube preserves sign)
///  (11)  Monotonicity of sqr for positive a: a < b => sqr(a) < sqr(b)  (fuzz)
///  (12)  Monotonicity of cube: a < b => cube(a) < cube(b)  (fuzz, same sign)
///  (13)  sqr(a) = pow(a, 2) ~= a^2  (consistency with pow, fuzz)
///  (14)  cube(a) = pow(a, 3) ~= a^3  (consistency with pow, fuzz)
///  (15)  Output always normalised  (fuzz)
///  (16)  sqrt(sqr(a)) ~= |a|;  cbrt(cube(a)) ~= a  (inverse relations, fuzz)
///  (17)  sqr(a) * sqr(b) = sqr(mul(a,b))  (exact for pow10, fuzz approx)
contract PhaseFRedTeam18Test is Test {

    uint128 constant S = uint128(Decimal.MANTISSA_SCALE);

    // ── helpers ──────────────────────────────────────────────────────────────

    function _assertNorm(Decimal.D memory d, string memory lbl) internal pure {
        if (d.mantissa == 0) {
            assertEq(d.exponent, 0,   string.concat(lbl, ": zero.exp"));
            assertFalse(d.negative,   string.concat(lbl, ": zero.neg"));
        } else {
            assertGe(d.mantissa, S,      string.concat(lbl, ": mantissa >= SCALE"));
            assertLt(d.mantissa, 10 * S, string.concat(lbl, ": mantissa < MAX"));
        }
    }

    function _relErr(Decimal.D memory a, Decimal.D memory b)
        internal pure returns (uint256)
    {
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

    // ── (1) Zero ──────────────────────────────────────────────────────────────

    function test_sqr_zero_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.sqr(Decimal.zero()), Decimal.zero()));
    }

    function test_cube_zero_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.cube(Decimal.zero()), Decimal.zero()));
    }

    // ── (2) Identity ──────────────────────────────────────────────────────────

    function test_sqr_one_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.sqr(Decimal.one()), Decimal.one()), "sqr(1)==1");
    }

    function test_cube_one_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.cube(Decimal.one()), Decimal.one()), "cube(1)==1");
    }

    // ── (3) sqr(-a) = sqr(a) ─────────────────────────────────────────────────

    function testFuzz_sqr_signCancels(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory pos = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory neg = Decimal.D({mantissa: m, exponent: e, negative: true});
        assertTrue(Decimal.eq(Decimal.sqr(pos), Decimal.sqr(neg)),
            "sqr(-a) == sqr(a)");
    }

    // ── (4) cube(-a) = -cube(a) ───────────────────────────────────────────────

    function testFuzz_cube_signPreserved(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory pos  = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory neg  = Decimal.D({mantissa: m, exponent: e, negative: true});
        Decimal.D memory cp   = Decimal.cube(pos);
        Decimal.D memory cn   = Decimal.cube(neg);
        // magnitudes equal, signs opposite
        assertEq(cp.mantissa, cn.mantissa, "cube: same magnitude");
        assertEq(cp.exponent, cn.exponent, "cube: same exponent");
        if (cp.mantissa != 0) {
            assertFalse(cp.negative,  "cube(pos) is positive");
            assertTrue(cn.negative,   "cube(neg) is negative");
        }
    }

    // ── (5) sqr(pow10(n)) = pow10(2n)  (exact) ───────────────────────────────

    function testFuzz_sqr_pow10_exact(int8 rawN) public pure {
        int64 n = int64(rawN);
        assertTrue(
            Decimal.eq(Decimal.sqr(Decimal.pow10(n)), Decimal.pow10(2 * n)),
            "sqr(10^n) == 10^2n"
        );
    }

    // ── (6) cube(pow10(n)) = pow10(3n)  (exact) ──────────────────────────────

    function testFuzz_cube_pow10_exact(int8 rawN) public pure {
        int64 n = int64(rawN);
        assertTrue(
            Decimal.eq(Decimal.cube(Decimal.pow10(n)), Decimal.pow10(3 * n)),
            "cube(10^n) == 10^3n"
        );
    }

    // ── (7) sqr(a) = mul(a, a)  (consistency) ────────────────────────────────

    function testFuzz_sqr_eqMulAA(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        assertTrue(Decimal.eq(Decimal.sqr(a), Decimal.mul(a, a)),
            "sqr(a) == mul(a,a)");
    }

    // ── (8) cube(a) = mul(a, mul(a, a))  (associativity consistency) ─────────

    function testFuzz_cube_eqTripleMul(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory vCube = Decimal.cube(a);
        Decimal.D memory vMul3 = Decimal.mul(a, Decimal.mul(a, a));
        assertTrue(Decimal.eq(vCube, vMul3), "cube(a) == a*a*a");
    }

    // ── (9) sqr always non-negative ───────────────────────────────────────────

    function testFuzz_sqr_nonNegative(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: true});
        assertFalse(Decimal.sqr(a).negative, "sqr is never negative");
    }

    // ── (10) cube sign == a sign ──────────────────────────────────────────────

    function testFuzz_cube_signMatchesInput(uint64 mantRaw, int8 expRaw, bool neg) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: neg});
        Decimal.D memory r = Decimal.cube(a);
        if (r.mantissa == 0) return;
        assertEq(r.negative, neg, "cube(a) sign == a sign");
    }

    // ── (11) Monotonicity of sqr (positive inputs) ────────────────────────────

    function testFuzz_sqr_monotone(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        if (!Decimal.lt(a, b)) return;
        assertTrue(
            Decimal.lt(Decimal.sqr(a), Decimal.sqr(b)) ||
            Decimal.eq(Decimal.sqr(a), Decimal.sqr(b)),
            "sqr not monotone for positive inputs"
        );
    }

    // ── (12) Monotonicity of cube (same sign) ─────────────────────────────────

    function testFuzz_cube_monotone(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        if (!Decimal.lt(a, b)) return;
        assertTrue(
            Decimal.lt(Decimal.cube(a), Decimal.cube(b)) ||
            Decimal.eq(Decimal.cube(a), Decimal.cube(b)),
            "cube not monotone for positive inputs"
        );
    }

    // ── (13) sqr(a) ~= pow(a, 2) ─────────────────────────────────────────────

    function testFuzz_sqr_consistentWithPow(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory vSqr = Decimal.sqr(a);
        Decimal.D memory vPow = Decimal.pow(a, Decimal.fromUint(2));
        _assertNorm(vSqr, "sqr");
        _assertNorm(vPow, "pow2");
        // pow uses log/exp so 2e-9 relative error vs exact sqr
        assertLe(_relErr(vSqr, vPow), 2e9, "sqr(a) ~= pow(a,2) within 2e-9");
    }

    // ── (14) cube(a) ~= pow(a, 3) ────────────────────────────────────────────

    function testFuzz_cube_consistentWithPow(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory vCube = Decimal.cube(a);
        Decimal.D memory vPow  = Decimal.pow(a, Decimal.fromUint(3));
        _assertNorm(vCube, "cube");
        _assertNorm(vPow,  "pow3");
        assertLe(_relErr(vCube, vPow), 3e9, "cube(a) ~= pow(a,3) within 3e-9");
    }

    // ── (15) Output always normalised ─────────────────────────────────────────

    function testFuzz_sqr_normalised(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        _assertNorm(
            Decimal.sqr(Decimal.D({mantissa: m, exponent: int64(expRaw), negative: false})),
            "sqr normalised"
        );
    }

    function testFuzz_cube_normalised(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        _assertNorm(
            Decimal.cube(Decimal.D({mantissa: m, exponent: int64(expRaw), negative: false})),
            "cube normalised"
        );
    }

    // ── (16) Inverse relations: sqrt(sqr(a)) ~= a;  cbrt(cube(a)) ~= a ───────

    function testFuzz_sqrt_inverts_sqr(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 2;  // even so sqrt takes clean branch
        Decimal.D memory a  = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory rt = Decimal.sqrt(Decimal.sqr(a));
        _assertNorm(rt, "sqrt(sqr(a))");
        assertLe(_relErr(a, rt), 2e9, "sqrt(sqr(a)) ~= a within 2e-9");
    }

    function testFuzz_cbrt_inverts_cube(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 9;  // multiple of 3 for clean cbrt branch
        Decimal.D memory a  = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory rt = Decimal.cbrt(Decimal.cube(a));
        _assertNorm(rt, "cbrt(cube(a))");
        assertLe(_relErr(a, rt), 3e9, "cbrt(cube(a)) ~= a within 3e-9");
    }

    // ── (17) sqr(a)*sqr(b) = sqr(mul(a,b))  (exact for pow10, approx fuzz) ──

    function testFuzz_sqr_productProperty(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.mul(Decimal.sqr(a), Decimal.sqr(b));
        Decimal.D memory rhs = Decimal.sqr(Decimal.mul(a, b));
        _assertNorm(lhs, "sqr product lhs");
        _assertNorm(rhs, "sqr product rhs");
        // mul has 1 ULP rounding; three mul ops total -> ~3e-9 relative
        assertLe(_relErr(lhs, rhs), 3e9, "sqr(a)*sqr(b) ~= sqr(a*b) within 3e-9");
    }
}
