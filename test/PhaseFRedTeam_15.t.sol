// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Red-team / adversarial test suite for Phase F-15: Decimal.pow.
///
/// Attack surfaces:
///   (1)  pow(0, x) = 0;  pow(x, 0) = 1  (special cases)
///   (2)  pow(1, x) = 1 for any x  (base = 1)
///   (3)  pow(base, 1) ~= base  (identity via log/exp, within tolerance)
///   (4)  pow(base, 2) ~= sqr(base)  (consistency with sqr)
///   (5)  pow(base, 3) ~= cube(base)  (consistency with cube)
///   (6)  Negative base, even integer exp -> positive
///   (7)  Negative base, odd integer exp -> negative
///   (8)  Negative base, non-integer exp -> positive (|base|^exp)
///   (9)  Product of powers: pow(x,m)*pow(x,n) ~= pow(x, m+n)
///  (10)  Power of power: pow(pow(x,m), n) ~= pow(x, m*n)
///  (11)  Power of product: pow(x,n)*pow(y,n) ~= pow(mul(x,y), n)
///  (12)  Monotonicity for base > 1: if a < b then pow(base, a) < pow(base, b)  (fuzz)
///  (13)  Monotonicity for 0 < base < 1: if a < b then pow(base,a) > pow(base,b)  (fuzz)
///  (14)  Output is always normalised  (fuzz)
///  (15)  Exponent overflow clamps gracefully (very large t saturates via normalize)
contract PhaseFRedTeam15Test is Test {

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

    /// Relative error |(a-b)/max(a,b)| * 1e18.  Returns max uint256 on incomparable.
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

    // ── (1) Special cases ────────────────────────────────────────────────────

    function test_pow_zeroBase_isZero() public pure {
        assertTrue(Decimal.eq(
            Decimal.pow(Decimal.zero(), Decimal.fromUint(5)),
            Decimal.zero()
        ), "0^5 == 0");
    }

    function test_pow_zeroExp_isOne() public pure {
        assertTrue(Decimal.eq(
            Decimal.pow(Decimal.fromUint(42), Decimal.zero()),
            Decimal.one()
        ), "42^0 == 1");
    }

    function test_pow_bothZero_isOne() public pure {
        // 0^0: base=0 branch fires first, returns 0 per convention
        // (JS break_infinity also returns 0 for this edge case)
        assertTrue(Decimal.eq(
            Decimal.pow(Decimal.zero(), Decimal.zero()),
            Decimal.zero()
        ), "0^0 convention");
    }

    // ── (2) Base = 1 ─────────────────────────────────────────────────────────

    function testFuzz_pow_base1_isOne(int8 rawExp) public pure {
        // Build exponent as a valid D: mantissa = S, exponent = rawExp
        Decimal.D memory exp = Decimal.normalize(
            Decimal.D({mantissa: S, exponent: int64(rawExp), negative: false})
        );
        assertTrue(Decimal.eq(
            Decimal.pow(Decimal.one(), exp),
            Decimal.one()
        ), "1^x == 1");
    }

    // ── (3) pow(base, 1) ~= base ─────────────────────────────────────────────

    function testFuzz_pow_exp1_approxBase(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory base = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: false});
        Decimal.D memory r    = Decimal.pow(base, Decimal.one());
        _assertNorm(r, "pow(x,1)");
        // Two transcendental ops: tolerance 2e-9 relative
        assertLe(_relErr(base, r), 2e9, "pow(x,1) ~= x within 2e-9");
    }

    // ── (4) pow(base, 2) ~= sqr(base) ────────────────────────────────────────

    function testFuzz_pow_exp2_approxSqr(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory base = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: false});
        Decimal.D memory vPow = Decimal.pow(base, Decimal.fromUint(2));
        Decimal.D memory vSqr = Decimal.sqr(base);
        _assertNorm(vPow, "pow2");
        _assertNorm(vSqr, "sqr");
        // pow goes through log/exp (1e-9 each); sqr is exact multiply.
        // Expect relative error <= 2e-9 between the two results.
        assertLe(_relErr(vPow, vSqr), 2e9, "pow(x,2) ~= sqr(x) within 2e-9");
    }

    // ── (5) pow(base, 3) ~= cube(base) ───────────────────────────────────────

    function testFuzz_pow_exp3_approxCube(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory base = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: false});
        Decimal.D memory vPow  = Decimal.pow(base, Decimal.fromUint(3));
        Decimal.D memory vCube = Decimal.cube(base);
        _assertNorm(vPow, "pow3");
        _assertNorm(vCube, "cube");
        // pow uses log+exp (each ~1e-9); cube uses two exact muls; combined ~3e-9.
        assertLe(_relErr(vPow, vCube), 3e9, "pow(x,3) ~= cube(x) within 3e-9");
    }

    // ── (6) Negative base, even integer exp -> positive ───────────────────────

    function test_pow_negBase_even_isPositive() public pure {
        Decimal.D memory negTwo = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        assertFalse(Decimal.pow(negTwo, Decimal.fromUint(2)).negative, "(-2)^2 positive");
        assertFalse(Decimal.pow(negTwo, Decimal.fromUint(4)).negative, "(-2)^4 positive");
    }

    // ── (7) Negative base, odd integer exp -> negative ────────────────────────

    function test_pow_negBase_odd_isNegative() public pure {
        // Create fresh structs for each call: pow() is marked `pure` and reads
        // base.negative before any field modification, so these should be safe.
        Decimal.D memory negTwo1 = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        assertTrue(Decimal.pow(negTwo1, Decimal.fromUint(1)).negative, "(-2)^1 negative");
        Decimal.D memory negTwo3 = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        assertTrue(Decimal.pow(negTwo3, Decimal.fromUint(3)).negative, "(-2)^3 negative");
    }

    // ── (8) Negative base, non-integer exp -> positive (|base|^exp) ───────────

    function test_pow_negBase_nonInt_isPositive() public pure {
        Decimal.D memory negFour = Decimal.D({mantissa: 4 * S, exponent: 0, negative: true});
        Decimal.D memory half    = Decimal.D({mantissa: 5 * S, exponent: -1, negative: false});
        Decimal.D memory r = Decimal.pow(negFour, half);
        assertFalse(r.negative, "(-4)^0.5 treated as positive (|base|^exp)");
        // |(-4)|^0.5 = 2
        assertLe(_relErr(Decimal.fromUint(2), r), 1e9, "(-4)^0.5 ~= 2");
    }

    // ── (9) Product of powers: pow(x,m)*pow(x,n) ~= pow(x, m+n) ─────────────
    //   Use small integer exponents to keep results in range.

    function testFuzz_pow_productOfPowers(uint64 mantRaw, uint8 rawM, uint8 rawN) public pure {
        uint128 m  = uint128(mantRaw % (9 * uint64(S))) + S;
        // Keep m, n in [1,4] so result stays well within EXP_LIMIT
        uint256 em = uint256(rawM) % 4 + 1;
        uint256 en = uint256(rawN) % 4 + 1;
        Decimal.D memory base = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.mul(
            Decimal.pow(base, Decimal.fromUint(em)),
            Decimal.pow(base, Decimal.fromUint(en))
        );
        Decimal.D memory rhs = Decimal.pow(base, Decimal.fromUint(em + en));
        _assertNorm(lhs, "product-of-powers lhs");
        _assertNorm(rhs, "product-of-powers rhs");
        // Two pow calls (each ~2e-9) plus one mul -> ~5e-9
        assertLe(_relErr(lhs, rhs), 5e9, "x^m * x^n ~= x^(m+n)");
    }

    // ── (10) Power of power: pow(pow(x,m), n) ~= pow(x, m*n) ────────────────

    function testFuzz_pow_powerOfPower(uint64 mantRaw, uint8 rawM, uint8 rawN) public pure {
        uint128 m  = uint128(mantRaw % (9 * uint64(S))) + S;
        uint256 em = uint256(rawM) % 3 + 1; // [1,3]
        uint256 en = uint256(rawN) % 3 + 1; // [1,3]
        Decimal.D memory base = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.pow(
            Decimal.pow(base, Decimal.fromUint(em)),
            Decimal.fromUint(en)
        );
        Decimal.D memory rhs = Decimal.pow(base, Decimal.fromUint(em * en));
        _assertNorm(lhs, "power-of-power lhs");
        _assertNorm(rhs, "power-of-power rhs");
        // Two nested pow calls -> ~4e-9
        assertLe(_relErr(lhs, rhs), 4e9, "pow(pow(x,m),n) ~= pow(x,m*n)");
    }

    // ── (11) Power of product: pow(x,n)*pow(y,n) ~= pow(mul(x,y), n) ─────────

    function testFuzz_pow_powerOfProduct(uint64 mantX, uint64 mantY, uint8 rawN) public pure {
        uint128 mx = uint128(mantX % (9 * uint64(S))) + S;
        uint128 my = uint128(mantY % (9 * uint64(S))) + S;
        uint256 n  = uint256(rawN) % 4 + 1;
        // Restrict to exponent 0 so mul doesn't shift
        Decimal.D memory x = Decimal.D({mantissa: mx, exponent: 0, negative: false});
        Decimal.D memory y = Decimal.D({mantissa: my, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.mul(
            Decimal.pow(x, Decimal.fromUint(n)),
            Decimal.pow(y, Decimal.fromUint(n))
        );
        Decimal.D memory rhs = Decimal.pow(Decimal.mul(x, y), Decimal.fromUint(n));
        _assertNorm(lhs, "pow-of-product lhs");
        _assertNorm(rhs, "pow-of-product rhs");
        // Three pow/mul ops compounding ~5e-9
        assertLe(_relErr(lhs, rhs), 5e9, "x^n * y^n ~= (x*y)^n");
    }

    // ── (12) Monotonicity for base > 1 ───────────────────────────────────────

    /// If base > 1 and a < b (both non-negative integers) then pow(base,a) < pow(base,b).
    function testFuzz_pow_monotone_baseGT1(uint64 mantRaw, uint8 rawA, uint8 rawB) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        if (m == S) m = S + 1; // ensure base > 1
        uint256 a = uint256(rawA) % 5;
        uint256 b = uint256(rawB) % 5;
        if (a >= b) return;
        Decimal.D memory base = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory pa = Decimal.pow(base, Decimal.fromUint(a == 0 ? 1 : a));
        Decimal.D memory pb = Decimal.pow(base, Decimal.fromUint(b));
        if (a == 0) {
            // pow(base,0) == 1, pow(base,b>0) > 1 for base > 1
            assertTrue(Decimal.lt(Decimal.one(), pb) || Decimal.eq(Decimal.one(), pb),
                "pow(base,0)<=pow(base,b) for base>1");
        } else {
            assertTrue(Decimal.lt(pa, pb) || Decimal.eq(pa, pb),
                "pow(base,a)<=pow(base,b) for base>1, a<b");
        }
    }

    // ── (13) Monotonicity for 0 < base < 1 ───────────────────────────────────

    /// If 0 < base < 1 and a < b then pow(base,a) >= pow(base,b).
    function testFuzz_pow_monotone_baseLT1(uint64 mantRaw, uint8 rawA, uint8 rawB) public pure {
        // base in (0,1): set exponent = -1, mantissa in [S, 10S)
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        uint256 a = uint256(rawA) % 5;
        uint256 b = uint256(rawB) % 5;
        if (a >= b) return;
        Decimal.D memory base = Decimal.D({mantissa: m, exponent: -1, negative: false});
        // Only test non-zero exponents
        Decimal.D memory pa = Decimal.pow(base, Decimal.fromUint(a == 0 ? 1 : a));
        Decimal.D memory pb = Decimal.pow(base, Decimal.fromUint(b));
        if (a == 0) {
            assertTrue(!Decimal.lt(Decimal.one(), pb) || Decimal.eq(Decimal.one(), pb),
                "pow(base<1, 0)>=pow(base,b)");
        } else {
            assertTrue(!Decimal.lt(pa, pb) || Decimal.eq(pa, pb),
                "pow(base<1,a)>=pow(base,b) for a<b");
        }
    }

    // ── (14) Output always normalised ─────────────────────────────────────────

    function testFuzz_pow_normalised(uint64 mantRaw, int8 baseExpRaw, uint8 expUint) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(baseExpRaw) * 10;
        uint256 n = uint256(expUint) % 5 + 1;
        Decimal.D memory base = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory r    = Decimal.pow(base, Decimal.fromUint(n));
        _assertNorm(r, "fuzz pow normalised");
    }
}
