// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Red-team / adversarial test suite for Phase L-31/34: factorial, decimalPlaces.
///
/// Attack surfaces:
///   (1)  factorial(0) = 1
///   (2)  factorial(1) = 1
///   (3)  factorial always >= 1 for n >= 0
///   (4)  factorial monotone: n < m => n! < m!  (fuzz, exact range)
///   (5)  factorial monotone: n < m => n! < m!  (fuzz, Stirling range)
///   (6)  factorial product: n! = n * (n-1)!  (fuzz, exact range)
///   (7)  factorial boundary: 19! > 18! (exact/Stirling crossover)
///   (8)  factorial: negative input = 1
///   (9)  factorial: fractional input = 1
///  (10)  factorial: result always normalised
///  (11)  decimalPlaces(0) = 0
///  (12)  decimalPlaces: integer values have 0 decimal places
///  (13)  decimalPlaces: 10^-k has exactly k decimal places  (fuzz k)
///  (14)  decimalPlaces: adding exponent decreases places  (fuzz)
///  (15)  decimalPlaces: symmetric (negative same as positive)
///  (16)  decimalPlaces: exact integer D has 0 places
///  (17)  pLog10: always >= 0
///  (18)  pLog10: pLog10(x) = log10(x) for x >= 1
///  (19)  absLog10: absLog10(x) = absLog10(-x)
///  (20)  absLog10: absLog10(x) = log10(x) for x > 0
contract PhaseLRedTeam31Test is Test {

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

    function _assertNorm(Decimal.D memory d, string memory lbl) internal pure {
        if (d.mantissa == 0) {
            assertEq(d.exponent, 0, string.concat(lbl, ": zero.exp"));
            assertFalse(d.negative, string.concat(lbl, ": zero.neg"));
        } else {
            assertGe(d.mantissa, S,      string.concat(lbl, ": m>=S"));
            assertLt(d.mantissa, 10 * S, string.concat(lbl, ": m<MAX"));
        }
    }

    // ── (1) factorial(0) = 1 ─────────────────────────────────────────────────

    function test_factorial_zero() public pure {
        assertTrue(Decimal.eq(Decimal.factorial(Decimal.zero()), Decimal.one()), "0! = 1");
    }

    // ── (2) factorial(1) = 1 ─────────────────────────────────────────────────

    function test_factorial_one() public pure {
        assertTrue(Decimal.eq(Decimal.factorial(Decimal.one()), Decimal.one()), "1! = 1");
    }

    // ── (3) factorial always >= 1 ────────────────────────────────────────────

    function testFuzz_factorial_gteOne(uint8 n) public pure {
        uint128 m = uint128(n % 18) + 1;  // n in [1, 18]
        assertTrue(
            Decimal.gte(Decimal.factorial(_d(m * S, 0)), Decimal.one()),
            "n! >= 1"
        );
    }

    // ── (4) factorial monotone — exact range ─────────────────────────────────

    function testFuzz_factorial_monotone_exact(uint8 raw) public pure {
        uint128 a = uint128(raw % 17) + 1; // a in [1, 17]
        uint128 b = a + 1;                 // b = a+1, both in [1, 18]
        Decimal.D memory fa = Decimal.factorial(_d(a * S, 0));
        Decimal.D memory fb = Decimal.factorial(_d(b * S, 0));
        assertTrue(Decimal.lt(fa, fb), "a! < (a+1)! in exact range");
    }

    // ── (5) factorial monotone — Stirling range ───────────────────────────────

    function testFuzz_factorial_monotone_stirling(uint8 raw) public pure {
        // n in [19, 40], m = n+1
        uint128 n = uint128(raw % 22) + 19;
        Decimal.D memory fn = Decimal.factorial(_d(n * S, 0));
        Decimal.D memory fm = Decimal.factorial(_d((n + 1) * S, 0));
        assertTrue(Decimal.lt(fn, fm), "Stirling monotone");
    }

    // ── (6) factorial product: n! = n * (n-1)! ───────────────────────────────

    function testFuzz_factorial_product(uint8 raw) public pure {
        // n in [2, 18]
        uint128 n  = uint128(raw % 17) + 2;
        Decimal.D memory fn   = Decimal.factorial(_d(n * S, 0));
        Decimal.D memory fnm1 = Decimal.factorial(_d((n - 1) * S, 0));
        Decimal.D memory nD   = _d(n * S, 0);
        // n! should equal n * (n-1)!
        Decimal.D memory product = Decimal.mul(nD, fnm1);
        assertLe(_relErr(fn, product), 0, "n! = n*(n-1)!");
    }

    // ── (7) factorial boundary 19! > 18! ─────────────────────────────────────

    function test_factorial_boundary() public pure {
        Decimal.D memory f18 = Decimal.factorial(_d(18 * S, 0));
        Decimal.D memory f19 = Decimal.factorial(_d(19 * S, 0));
        assertTrue(Decimal.gt(f19, f18), "19! > 18! at exact/Stirling boundary");
    }

    // ── (8) factorial: negative input returns 1 ───────────────────────────────

    function test_factorial_negative() public pure {
        Decimal.D memory neg = Decimal.D({mantissa: 5 * S, exponent: 0, negative: true});
        assertTrue(Decimal.eq(Decimal.factorial(neg), Decimal.one()), "factorial(neg) = 1");
    }

    // ── (9) factorial: fractional input returns 1 ─────────────────────────────

    function test_factorial_fraction() public pure {
        // 0.7 = {m: 7e18, e: -1}
        Decimal.D memory frac = Decimal.D({mantissa: 7 * S, exponent: -1, negative: false});
        assertTrue(Decimal.eq(Decimal.factorial(frac), Decimal.one()), "factorial(0.7) = 1");
    }

    // ── (10) factorial: normalised output ────────────────────────────────────

    function testFuzz_factorial_normalised(uint8 raw) public pure {
        uint128 n = uint128(raw % 30) + 1;
        _assertNorm(Decimal.factorial(_d(n * S, 0)), "factorial normalised");
    }

    // ── (11) decimalPlaces(0) = 0 ────────────────────────────────────────────

    function test_decimalPlaces_zero() public pure {
        assertEq(Decimal.decimalPlaces(Decimal.zero()), 0, "decimalPlaces(0) = 0");
    }

    // ── (12) decimalPlaces: integers >= 1 have 0 places ──────────────────────

    function testFuzz_decimalPlaces_integers(uint8 raw) public pure {
        // values 1, 10, 100... using exponent >= 0 with mantissa = 1e18
        int64 e = int64(uint64(raw % 10));
        assertEq(Decimal.decimalPlaces(_d(S, e)), 0, "decimalPlaces(10^e) = 0");
    }

    // ── (13) decimalPlaces: 10^-k has exactly k places ───────────────────────

    function testFuzz_decimalPlaces_negExp(uint8 raw) public pure {
        int64 k = int64(uint64(raw % 15)) + 1; // k in [1, 15]
        // 10^-k = {mantissa: 1e18, exponent: -k}
        uint256 dp = Decimal.decimalPlaces(_d(S, -k));
        assertEq(dp, uint256(uint64(k)), "decimalPlaces(10^-k) = k");
    }

    // ── (14) decimalPlaces: shifting exponent up by 1 decreases places by 1 ──

    function test_decimalPlaces_exponentShift() public pure {
        // 0.05 = {m: 5e18, e: -2}: trailing zeros = 18, places = 18 - (-2) - 18 = 2
        // 0.5  = {m: 5e18, e: -1}: trailing zeros = 18, places = 18 - (-1) - 18 = 1
        Decimal.D memory a = Decimal.D({mantissa: 5 * S, exponent: -2, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: 5 * S, exponent: -1, negative: false});
        uint256 dpA = Decimal.decimalPlaces(a);
        uint256 dpB = Decimal.decimalPlaces(b);
        assertEq(dpA, dpB + 1, "exponent+1 => places-1");
    }

    // ── (15) decimalPlaces: sign doesn't affect result ────────────────────────

    function testFuzz_decimalPlaces_signSymmetric(uint8 raw) public pure {
        int64 e = -int64(uint64(raw % 8)) - 1; // e in [-8, -1]
        Decimal.D memory pos = Decimal.D({mantissa: 3 * S, exponent: e, negative: false});
        Decimal.D memory neg = Decimal.D({mantissa: 3 * S, exponent: e, negative: true});
        assertEq(
            Decimal.decimalPlaces(pos),
            Decimal.decimalPlaces(neg),
            "decimalPlaces same for +/-"
        );
    }

    // ── (16) decimalPlaces: large exponent always 0 ───────────────────────────

    function testFuzz_decimalPlaces_largeExp(uint8 raw) public pure {
        int64 e = int64(uint64(raw % 10)) + 18; // e in [18, 27]
        assertEq(Decimal.decimalPlaces(_d(S, e)), 0, "decimalPlaces(large exp) = 0");
    }

    // ── (17) pLog10 always >= 0 ───────────────────────────────────────────────

    function testFuzz_pLog10_nonNegative(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory r = Decimal.pLog10(_d(m, 0));
        assertFalse(r.negative, "pLog10 >= 0");
    }

    // ── (18) pLog10(x) = log10(x) for x >= 1 ────────────────────────────────

    function testFuzz_pLog10_equalsLog10_forGteOne(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory x  = _d(m, 0);  // x in [1, 10)
        Decimal.D memory p  = Decimal.pLog10(x);
        Decimal.D memory l  = Decimal.log10(x);
        assertLe(_relErr(p, l), 0, "pLog10(x) == log10(x) for x>=1");
    }

    // ── (19) absLog10: absLog10(x) = absLog10(-x) ────────────────────────────

    function testFuzz_absLog10_symmetric(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory pos = _d(m, 1);
        Decimal.D memory neg = Decimal.D({mantissa: m, exponent: 1, negative: true});
        Decimal.D memory lp  = Decimal.absLog10(pos);
        Decimal.D memory ln_ = Decimal.absLog10(neg);
        assertLe(_relErr(lp, ln_), 0, "absLog10 symmetric");
    }

    // ── (20) absLog10(x) = log10(x) for x > 0 ───────────────────────────────

    function testFuzz_absLog10_equalsLog10(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory x  = _d(m, 1);
        Decimal.D memory al = Decimal.absLog10(x);
        Decimal.D memory l  = Decimal.log10(x);
        assertLe(_relErr(al, l), 0, "absLog10(x) == log10(x) for x>0");
    }
}
