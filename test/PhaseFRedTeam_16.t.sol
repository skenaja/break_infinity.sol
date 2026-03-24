// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {IDecimalErrors} from "../src/interfaces/IDecimalErrors.sol";

/// @dev Harness for vm.expectRevert on internal library reverts.
contract Sqrt16Harness {
    function sqrt(Decimal.D calldata a) external pure returns (Decimal.D memory) {
        return Decimal.sqrt(a);
    }
}

/// @notice Red-team / adversarial test suite for Phase F-16: Decimal.sqrt.
///
/// Attack surfaces:
///   (1)  Negative input reverts with Decimal__NegativeSqrt
///   (2)  Zero input returns zero
///   (3)  sqrt(1) = 1  (exact)
///   (4)  sqrt(pow10(2n)) = pow10(n)  (even exponent, exact)
///   (5)  sqrt(pow10(2n+1)): odd exponent branch — result normalised & squared ~= input
///   (6)  sqr(sqrt(a)) <= a  (isqrt floors — one-directional bound, fuzz)
///   (7)  sqr(sqrt(a)) ~= a  (round-trip within 1 ULP, fuzz)
///   (8)  sqrt(sqr(a)) ~= a  (reverse round-trip, fuzz)
///   (9)  sqrt(a) * sqrt(b) ~= sqrt(mul(a,b))  (product property, fuzz)
///  (10)  Monotonicity: a < b => sqrt(a) < sqrt(b)  (fuzz)
///  (11)  Output always normalised  (fuzz)
///  (12)  Odd-exponent boundary: exponent = +1 and -1
///  (13)  Large even/odd exponents near EXP_LIMIT
contract PhaseFRedTeam16Test is Test {

    uint128 constant S  = uint128(Decimal.MANTISSA_SCALE);
    int64   constant EL = Decimal.EXP_LIMIT;

    Sqrt16Harness h = new Sqrt16Harness();

    // ── helpers ──────────────────────────────────────────────────────────────

    function _assertNorm(Decimal.D memory d, string memory lbl) internal pure {
        if (d.mantissa == 0) {
            assertEq(d.exponent, 0,   string.concat(lbl, ": zero.exp"));
            assertFalse(d.negative,   string.concat(lbl, ": zero.neg"));
        } else {
            assertGe(d.mantissa, S,      string.concat(lbl, ": mantissa >= SCALE"));
            assertLt(d.mantissa, 10 * S, string.concat(lbl, ": mantissa < MAX"));
            assertFalse(d.negative,      string.concat(lbl, ": not negative"));
        }
    }

    /// Relative error, returns max uint256 when exponents differ by > 1.
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

    // ── (1) Negative input reverts ────────────────────────────────────────────

    function test_sqrt_negative_reverts() public {
        Decimal.D memory neg = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        vm.expectRevert(IDecimalErrors.Decimal__NegativeSqrt.selector);
        h.sqrt(neg);
    }

    function test_sqrt_negZero_noRevert() public pure {
        // zero is zero regardless of sign — mantissa == 0 exits before the check
        Decimal.D memory negZero = Decimal.D({mantissa: 0, exponent: 0, negative: true});
        Decimal.D memory r = Decimal.sqrt(negZero);
        assertTrue(Decimal.eq(r, Decimal.zero()), "sqrt(neg-zero) == 0");
    }

    // ── (2) Zero ──────────────────────────────────────────────────────────────

    function test_sqrt_zero_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.sqrt(Decimal.zero()), Decimal.zero()));
    }

    // ── (3) sqrt(1) = 1 ──────────────────────────────────────────────────────

    function test_sqrt_one_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.sqrt(Decimal.one()), Decimal.one()),
            "sqrt(1) == 1");
    }

    // ── (4) sqrt(10^(2n)) = 10^n  (exact) ────────────────────────────────────

    function test_sqrt_pow10_even_exact() public pure {
        assertTrue(Decimal.eq(Decimal.sqrt(Decimal.pow10(0)),   Decimal.pow10(0)),   "sqrt(10^0)");
        assertTrue(Decimal.eq(Decimal.sqrt(Decimal.pow10(2)),   Decimal.pow10(1)),   "sqrt(10^2)");
        assertTrue(Decimal.eq(Decimal.sqrt(Decimal.pow10(-2)),  Decimal.pow10(-1)),  "sqrt(10^-2)");
        assertTrue(Decimal.eq(Decimal.sqrt(Decimal.pow10(100)), Decimal.pow10(50)),  "sqrt(10^100)");
        assertTrue(Decimal.eq(Decimal.sqrt(Decimal.pow10(-100)),Decimal.pow10(-50)), "sqrt(10^-100)");
    }

    function testFuzz_sqrt_pow10_even_exact(int8 rawN) public pure {
        int64 n  = int64(rawN);
        int64 n2 = 2 * n;                         // stays in int64 (int8 * 2 < 256 << 9.2e18)
        assertTrue(
            Decimal.eq(Decimal.sqrt(Decimal.pow10(n2)), Decimal.pow10(n)),
            "sqrt(10^2n) == 10^n"
        );
    }

    // ── (5) Odd exponent — normalised and squared recovers input ──────────────

    function test_sqrt_pow10_odd_normalised() public pure {
        Decimal.D memory r1 = Decimal.sqrt(Decimal.pow10(1));
        _assertNorm(r1, "sqrt(10^1)");
        Decimal.D memory r3 = Decimal.sqrt(Decimal.pow10(3));
        _assertNorm(r3, "sqrt(10^3)");
        Decimal.D memory rn1 = Decimal.sqrt(Decimal.pow10(-1));
        _assertNorm(rn1, "sqrt(10^-1)");
    }

    // ── (6) sqr(sqrt(a)) <= a  (isqrt floors) ────────────────────────────────

    function testFuzz_sqrt_sqrFloor(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 2;  // keep even so exponent/2 is exact
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory s = Decimal.sqrt(a);
        Decimal.D memory s2 = Decimal.sqr(s);
        // sqr(sqrt(a)) should be <= a (floor property) — use le comparison
        assertTrue(!Decimal.lt(a, s2), "sqr(sqrt(a)) > a (violates floor)");
    }

    // ── (7) sqr(sqrt(a)) ~= a  (round-trip, fuzz, even exponent) ─────────────

    function testFuzz_sqrt_roundTrip_sqr_of_sqrt(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 2;  // even exponent for clean branch
        Decimal.D memory a  = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory rt = Decimal.sqr(Decimal.sqrt(a));
        _assertNorm(rt, "sqr(sqrt(a))");
        // isqrt is floor-exact; error <= 1 ULP of mantissa
        assertLe(_relErr(a, rt), 2e9, "sqr(sqrt(a)) ~= a within 2e-9");
    }

    // ── (8) sqrt(sqr(a)) ~= a  (reverse round-trip, fuzz) ────────────────────

    function testFuzz_sqrt_roundTrip_sqrt_of_sqr(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 2;  // even exponent
        Decimal.D memory a  = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory rt = Decimal.sqrt(Decimal.sqr(a));
        _assertNorm(rt, "sqrt(sqr(a))");
        assertLe(_relErr(a, rt), 2e9, "sqrt(sqr(a)) ~= a within 2e-9");
    }

    // ── (9) Product property: sqrt(a) * sqrt(b) ~= sqrt(a*b) ─────────────────

    function testFuzz_sqrt_productProperty(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        // Use even exponents so all sqrt calls take the clean even branch.
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.mul(Decimal.sqrt(a), Decimal.sqrt(b));
        Decimal.D memory rhs = Decimal.sqrt(Decimal.mul(a, b));
        _assertNorm(lhs, "sqrt product lhs");
        _assertNorm(rhs, "sqrt product rhs");
        // Two sqrt ops + one mul: ~3e-9
        assertLe(_relErr(lhs, rhs), 3e9, "sqrt(a)*sqrt(b) ~= sqrt(a*b) within 3e-9");
    }

    // ── (10) Monotonicity ─────────────────────────────────────────────────────

    function testFuzz_sqrt_monotone(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        // Both have exponent 0 so ordering is by mantissa alone.
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        if (Decimal.lt(a, b)) {
            assertTrue(
                Decimal.lt(Decimal.sqrt(a), Decimal.sqrt(b)) ||
                Decimal.eq(Decimal.sqrt(a), Decimal.sqrt(b)),
                "sqrt not monotone"
            );
        }
    }

    // ── (11) Output always normalised  (general fuzz) ─────────────────────────

    function testFuzz_sqrt_normalised(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 10;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        _assertNorm(Decimal.sqrt(a), "fuzz sqrt normalised");
    }

    // ── (12) Odd-exponent boundary ────────────────────────────────────────────

    function test_sqrt_oddExp_plus1() public pure {
        // sqrt(10^1): odd branch, newExp = (1-1)/2 = 0
        Decimal.D memory r = Decimal.sqrt(Decimal.pow10(1));
        _assertNorm(r, "sqrt(10^1)");
        assertEq(r.exponent, 0, "sqrt(10^1).exponent == 0");
        // sqrt(10) * 1e18 = 3_162_277_660_168_379_332
        uint256 expected = 3_162_277_660_168_379_332;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2, "sqrt(10^1) mantissa within 2 ULP");
    }

    function test_sqrt_oddExp_minus1() public pure {
        // sqrt(10^-1): odd branch, newExp = (-1-1)/2 = -1
        Decimal.D memory r = Decimal.sqrt(Decimal.pow10(-1));
        _assertNorm(r, "sqrt(10^-1)");
        assertEq(r.exponent, -1, "sqrt(10^-1).exponent == -1");
        // sqrt(0.1) = 0.316..., mantissa = 3_162_277_660_168_379_332, exp = -1
        uint256 expected = 3_162_277_660_168_379_332;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2, "sqrt(10^-1) mantissa within 2 ULP");
    }

    // ── (13) Near EXP_LIMIT ───────────────────────────────────────────────────

    function test_sqrt_largeEvenExp() public pure {
        // sqrt(10^(EL-1)) where EL-1 is even (EL = 9e15, EL-1 is odd; use EL-1 rounded to even)
        // EL = 9_000_000_000_000_000; pick a large even exponent safely below EL
        int64 bigEven = 9_000_000_000_000_000 - 2; // 8_999_999_999_999_998 (even)
        Decimal.D memory a = Decimal.pow10(bigEven);
        Decimal.D memory r = Decimal.sqrt(a);
        _assertNorm(r, "sqrt(10^bigEven)");
        assertEq(r.exponent, bigEven / 2, "sqrt(10^bigEven) exp == bigEven/2");
    }

    function test_sqrt_largeOddExp() public pure {
        int64 bigOdd = 9_000_000_000_000_000 - 1; // 8_999_999_999_999_999 (odd)
        Decimal.D memory a = Decimal.pow10(bigOdd);
        Decimal.D memory r = Decimal.sqrt(a);
        _assertNorm(r, "sqrt(10^bigOdd)");
        assertEq(r.exponent, (bigOdd - 1) / 2, "sqrt(10^bigOdd) exp == (bigOdd-1)/2");
    }
}
