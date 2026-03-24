// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Red-team / adversarial test suite for Phase F-17: Decimal.cbrt.
///
/// Attack surfaces:
///   (1)  Zero input returns zero
///   (2)  cbrt(1) = 1;  cbrt(-1) = -1
///   (3)  Sign: cbrt(negative) is negative  (fuzz)
///   (4)  cube(cbrt(a)) ~= a  (fuzz, general mantissa × all exponent mods)
///   (5)  cbrt(cube(a)) ~= a  (fuzz, reverse round-trip)
///   (6)  |cbrt(a)|^3 <= |a|  (floor property — icbrt rounds down)
///   (7)  Product: cbrt(a)*cbrt(b) ~= cbrt(mul(a,b))  (fuzz)
///   (8)  Monotonicity: a < b (positive) => cbrt(a) < cbrt(b)  (fuzz)
///   (9)  Output always normalised  (fuzz, positive and negative)
///  (10)  All exponent-mod branches: mod 0, mod 1, mod -1, mod 2, mod -2
///  (11)  Large exponents near EXP_LIMIT (divisible by 3, not divisible by 3)
///  (12)  cbrt(pow10(n)) == pow10(n/3) when n divisible by 3  (fuzz)
contract PhaseFRedTeam17Test is Test {

    uint128 constant S  = uint128(Decimal.MANTISSA_SCALE);
    int64   constant EL = Decimal.EXP_LIMIT;

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

    function test_cbrt_zero_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.cbrt(Decimal.zero()), Decimal.zero()));
    }

    // ── (2) cbrt(1) and cbrt(-1) ─────────────────────────────────────────────

    function test_cbrt_one_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.cbrt(Decimal.one()), Decimal.one()),
            "cbrt(1) == 1");
    }

    function test_cbrt_negOne_isNegOne() public pure {
        Decimal.D memory negOne = Decimal.D({mantissa: S, exponent: 0, negative: true});
        Decimal.D memory r = Decimal.cbrt(negOne);
        assertTrue(r.negative,               "cbrt(-1) is negative");
        assertEq(r.mantissa, S,              "cbrt(-1) mantissa == S");
        assertEq(r.exponent, int64(0),       "cbrt(-1) exponent == 0");
    }

    // ── (3) Sign invariant ────────────────────────────────────────────────────

    function testFuzz_cbrt_negativeIsNegative(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 10;
        Decimal.D memory a = Decimal.normalize(
            Decimal.D({mantissa: m, exponent: e, negative: true})
        );
        if (a.mantissa == 0) return;
        assertTrue(Decimal.cbrt(a).negative, "cbrt(negative) is negative");
    }

    function testFuzz_cbrt_positiveIsPositive(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 10;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        assertFalse(Decimal.cbrt(a).negative, "cbrt(positive) is positive");
    }

    // ── (4) cube(cbrt(a)) ~= a  (general fuzz) ───────────────────────────────

    function testFuzz_cbrt_cubeRoundTrip(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 10;
        Decimal.D memory a  = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory rt = Decimal.cube(Decimal.cbrt(a));
        _assertNorm(rt, "cube(cbrt(a))");
        assertLe(_relErr(a, rt), 3e9, "cube(cbrt(a)) ~= a within 3e-9");
    }

    // ── (5) cbrt(cube(a)) ~= a  (reverse round-trip) ─────────────────────────

    function testFuzz_cbrt_cubeReverseRoundTrip(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        // Keep exponent divisible by 3 so cube result exponent stays in range.
        int64   e = int64(expRaw) * 9; // multiple of 3
        Decimal.D memory a  = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory rt = Decimal.cbrt(Decimal.cube(a));
        _assertNorm(rt, "cbrt(cube(a))");
        assertLe(_relErr(a, rt), 3e9, "cbrt(cube(a)) ~= a within 3e-9");
    }

    // ── (6) |cbrt(a)|^3 <= |a|  (icbrt floors) ───────────────────────────────

    function testFuzz_cbrt_floorProperty(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 9; // mod-0 exponent: cleanest branch
        Decimal.D memory a  = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory c  = Decimal.cbrt(a);
        Decimal.D memory c3 = Decimal.cube(c);
        // c3 = cbrt(a)^3 must be <= a (floor)
        assertTrue(!Decimal.lt(a, c3), "cbrt(a)^3 > a (violates floor)");
    }

    // ── (7) Product property: cbrt(a)*cbrt(b) ~= cbrt(a*b) ──────────────────

    function testFuzz_cbrt_productProperty(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        // Use exponent 0 for both to keep mul result in range.
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.mul(Decimal.cbrt(a), Decimal.cbrt(b));
        Decimal.D memory rhs = Decimal.cbrt(Decimal.mul(a, b));
        _assertNorm(lhs, "cbrt product lhs");
        _assertNorm(rhs, "cbrt product rhs");
        assertLe(_relErr(lhs, rhs), 3e9, "cbrt(a)*cbrt(b) ~= cbrt(a*b) within 3e-9");
    }

    // ── (8) Monotonicity ──────────────────────────────────────────────────────

    function testFuzz_cbrt_monotone(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        if (!Decimal.lt(a, b)) return;
        assertTrue(
            Decimal.lt(Decimal.cbrt(a), Decimal.cbrt(b)) ||
            Decimal.eq(Decimal.cbrt(a), Decimal.cbrt(b)),
            "cbrt not monotone"
        );
    }

    // ── (9) Output always normalised ──────────────────────────────────────────

    function testFuzz_cbrt_normalisedPositive(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 10;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        _assertNorm(Decimal.cbrt(a), "fuzz cbrt positive");
    }

    function testFuzz_cbrt_normalisedNegative(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 10;
        Decimal.D memory a = Decimal.normalize(
            Decimal.D({mantissa: m, exponent: e, negative: true})
        );
        if (a.mantissa == 0) return;
        Decimal.D memory r = Decimal.cbrt(a);
        // normalised checks (sign may be negative)
        if (r.mantissa != 0) {
            assertGe(r.mantissa, S,      "cbrt neg: mantissa >= SCALE");
            assertLt(r.mantissa, 10 * S, "cbrt neg: mantissa < MAX");
        }
    }

    // ── (10) All exponent-mod branches ───────────────────────────────────────

    function test_cbrt_modBranches() public pure {
        // mod 0: cbrt(10^0) = 1, cbrt(10^3) = 10, cbrt(10^-3) = 10^-1
        assertTrue(Decimal.eq(Decimal.cbrt(Decimal.pow10(0)),  Decimal.pow10(0)),  "mod0: 10^0");
        assertTrue(Decimal.eq(Decimal.cbrt(Decimal.pow10(3)),  Decimal.pow10(1)),  "mod0: 10^3");
        assertTrue(Decimal.eq(Decimal.cbrt(Decimal.pow10(-3)), Decimal.pow10(-1)), "mod0: 10^-3");

        // mod 1 (e%3 == 1): cbrt(10^1), cbrt(10^4)
        Decimal.D memory r1 = Decimal.cbrt(Decimal.pow10(1));
        assertEq(r1.exponent, int64(0), "mod1: 10^1 exp");
        _assertNorm(r1, "mod1: 10^1");

        Decimal.D memory r4 = Decimal.cbrt(Decimal.pow10(4));
        assertEq(r4.exponent, int64(1), "mod1: 10^4 exp");
        _assertNorm(r4, "mod1: 10^4");

        // mod -2 (e%3 == -2 in Solidity): cbrt(10^-2)
        Decimal.D memory rn2 = Decimal.cbrt(Decimal.pow10(-2));
        assertEq(rn2.exponent, int64(-1), "mod-2: 10^-2 exp");
        _assertNorm(rn2, "mod-2: 10^-2");

        // mod 2 (e%3 == 2): cbrt(10^2), cbrt(10^5)
        Decimal.D memory r2 = Decimal.cbrt(Decimal.pow10(2));
        assertEq(r2.exponent, int64(0), "mod2: 10^2 exp");
        _assertNorm(r2, "mod2: 10^2");

        // mod -1 (e%3 == -1 in Solidity): cbrt(10^-1)
        Decimal.D memory rn1 = Decimal.cbrt(Decimal.pow10(-1));
        assertEq(rn1.exponent, int64(-1), "mod-1: 10^-1 exp");
        _assertNorm(rn1, "mod-1: 10^-1");
    }

    // ── (11) Near EXP_LIMIT ───────────────────────────────────────────────────

    function test_cbrt_largeExpDiv3() public pure {
        // EL = 9e15 = 9_000_000_000_000_000 — divisible by 3
        // cbrt(10^EL) should have exponent EL/3 = 3e15
        int64 bigE = EL - (EL % 3); // round down to multiple of 3
        Decimal.D memory r = Decimal.cbrt(Decimal.pow10(bigE));
        _assertNorm(r, "cbrt(10^bigE)");
        assertEq(r.exponent, bigE / 3, "cbrt(10^bigE) exp == bigE/3");
    }

    function test_cbrt_largeExpMod1() public pure {
        int64 bigE = EL - 1; // 8_999_999_999_999_999; mod 3 = 2 in Solidity (positive)
        // Actually bigE mod 3: 9e15 mod 3 = 0; (9e15 - 1) mod 3 = 2
        Decimal.D memory r = Decimal.cbrt(Decimal.pow10(bigE));
        _assertNorm(r, "cbrt(10^(EL-1))");
    }

    function test_cbrt_largeNegExp() public pure {
        int64 bigNeg = -(EL - (EL % 3)); // large negative multiple of 3
        Decimal.D memory r = Decimal.cbrt(Decimal.pow10(bigNeg));
        _assertNorm(r, "cbrt(10^-bigE)");
        assertEq(r.exponent, bigNeg / 3, "cbrt(10^-bigE) exp");
    }

    // ── (12) cbrt(pow10(3n)) == pow10(n)  (fuzz) ─────────────────────────────

    function testFuzz_cbrt_pow10_mod0(int8 rawN) public pure {
        int64 n  = int64(rawN);
        int64 n3 = 3 * n; // stays in int64 for int8 inputs
        assertTrue(
            Decimal.eq(Decimal.cbrt(Decimal.pow10(n3)), Decimal.pow10(n)),
            "cbrt(10^3n) == 10^n"
        );
    }
}
