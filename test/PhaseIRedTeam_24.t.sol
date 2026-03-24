// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Red-team / adversarial test suite for Phase I-24: Decimal.exp.
///
/// Attack surfaces:
///   (1)  exp(0) = 1  (exact)
///   (2)  exp(1) ~= e  (within 2e-9)
///   (3)  exp(-1) ~= 1/e  (within 2e-9)
///   (4)  exp always positive  (fuzz)
///   (5)  exp always normalised  (fuzz)
///   (6)  Monotonicity: a < b => exp(a) < exp(b)  (fuzz)
///   (7)  Additive: exp(a+b) ~= exp(a)*exp(b)  (fuzz, small exponents)
///   (8)  Round-trip: ln(exp(a)) ~= a  (fuzz, small a)
///   (9)  Round-trip: exp(ln(a)) ~= a  (fuzz, positive a)
///  (10)  exp(a) * exp(-a) ~= 1  (product with negation)  (fuzz)
///  (11)  exp(2*a) ~= exp(a)^2  (doubling property)  (fuzz)
///  (12)  Large positive a: exp overflows to huge D (but doesn't revert for valid range)
///  (13)  Large negative a: exp approaches zero (tiny D)
///  (14)  Known: exp(ln(10)) ~= 10
///  (15)  Known: exp(2) ~= 7.38906
///  (16)  Consistency with pow: exp(a) ~= pow(e, a)  (fuzz)
contract PhaseIRedTeam24Test is Test {

    uint128 constant S  = uint128(Decimal.MANTISSA_SCALE);
    int64   constant EL = Decimal.EXP_LIMIT;

    Decimal.D internal E_VAL = Decimal.D({mantissa: 2_718_281_828_459_045_235, exponent: 0, negative: false});

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

    // ── (1) exp(0) = 1 ───────────────────────────────────────────────────────

    function test_exp_zero_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.exp(Decimal.zero()), Decimal.one()), "exp(0)==1");
    }

    // ── (2) exp(1) ~= e ──────────────────────────────────────────────────────

    function test_exp_one_isE() public view {
        assertLe(_relErr(Decimal.exp(Decimal.one()), E_VAL), 2e9, "exp(1)~=e");
    }

    // ── (3) exp(-1) ~= 1/e ───────────────────────────────────────────────────

    function test_exp_negOne_isRecipE() public pure {
        Decimal.D memory r        = Decimal.exp(Decimal.D({mantissa: S, exponent: 0, negative: true}));
        Decimal.D memory expected = Decimal.D({mantissa: 3_678_794_411_714_423_216, exponent: -1, negative: false});
        assertFalse(r.negative, "exp(-1) is positive");
        assertLe(_relErr(r, expected), 2e9, "exp(-1)~=1/e");
    }

    // ── (4) exp always positive ───────────────────────────────────────────────

    function testFuzz_exp_alwaysPositive(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) % 10;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory r = Decimal.exp(a);
        assertFalse(r.negative, "exp(a) is always positive");
        assertTrue(r.mantissa > 0, "exp(a) is always nonzero");
    }

    function testFuzz_exp_negInput_alwaysPositive(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) % 10;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: true});
        Decimal.D memory r = Decimal.exp(a);
        assertFalse(r.negative, "exp(negative a) is always positive");
        assertTrue(r.mantissa > 0, "exp(negative a) is nonzero");
    }

    // ── (5) exp always normalised ─────────────────────────────────────────────

    function testFuzz_exp_normalised(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) % 10;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        _assertNorm(Decimal.exp(a), "exp normalised");
    }

    // ── (6) Monotonicity ──────────────────────────────────────────────────────

    function testFuzz_exp_monotone(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        if (!Decimal.lt(a, b)) return;
        assertTrue(
            Decimal.lt(Decimal.exp(a), Decimal.exp(b)) ||
            Decimal.eq(Decimal.exp(a), Decimal.exp(b)),
            "exp not monotone"
        );
    }

    // ── (7) Additive: exp(a+b) ~= exp(a)*exp(b) ──────────────────────────────
    // Use small exponents (exponent=-1) so a,b ∈ [0.1, 1) and sum stays bounded.

    function testFuzz_exp_additive(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: -1, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: -1, negative: false});
        Decimal.D memory lhs = Decimal.exp(Decimal.add(a, b));
        Decimal.D memory rhs = Decimal.mul(Decimal.exp(a), Decimal.exp(b));
        assertLe(_relErr(lhs, rhs), 3e9, "exp(a+b) ~= exp(a)*exp(b)");
    }

    // ── (8) Round-trip: ln(exp(a)) ~= a ──────────────────────────────────────
    // Restrict a to exponent=0 to bound |a| and avoid ln precision blow-up.

    function testFuzz_exp_lnRoundTrip(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a  = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory rt = Decimal.ln(Decimal.exp(a));
        assertLe(_relErr(rt, a), 1e10, "ln(exp(a)) ~= a within 1e-8");
    }

    // ── (9) Round-trip: exp(ln(a)) ~= a ──────────────────────────────────────

    function testFuzz_exp_expLnRoundTrip(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a  = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory rt = Decimal.exp(Decimal.ln(a));
        assertLe(_relErr(rt, a), 1e10, "exp(ln(a)) ~= a within 1e-8");
    }

    // ── (10) exp(a) * exp(-a) ~= 1 ───────────────────────────────────────────

    function testFuzz_exp_timesRecip_isOne(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory a    = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory negA = Decimal.D({mantissa: m, exponent: 0, negative: true});
        Decimal.D memory lhs  = Decimal.mul(Decimal.exp(a), Decimal.exp(negA));
        assertLe(_relErr(lhs, Decimal.one()), 3e9, "exp(a)*exp(-a) ~= 1");
    }

    // ── (11) exp(2*a) ~= exp(a)^2 ────────────────────────────────────────────

    function testFuzz_exp_doubling(uint64 mantRaw) public pure {
        uint128 m    = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory a   = Decimal.D({mantissa: m, exponent: -1, negative: false});
        Decimal.D memory twoA = Decimal.add(a, a);
        Decimal.D memory lhs  = Decimal.exp(twoA);
        Decimal.D memory ea   = Decimal.exp(a);
        Decimal.D memory rhs  = Decimal.mul(ea, ea);
        assertLe(_relErr(lhs, rhs), 3e9, "exp(2a) ~= exp(a)^2");
    }

    // ── (12) Large positive: result is huge but normalised ────────────────────

    function test_exp_largePosInput() public pure {
        // exp(100): a very large number, should not revert
        Decimal.D memory a = Decimal.D({mantissa: S, exponent: 2, negative: false});
        Decimal.D memory r = Decimal.exp(a);
        _assertNorm(r, "exp(100)");
        assertFalse(r.negative, "exp(100) positive");
        // exp(100) = 10^(100*log10(e)) = 10^43.429... exponent ~= 43
        assertGe(r.exponent, 40, "exp(100) exponent >= 40");
    }

    // ── (13) Large negative: result is tiny but nonzero ───────────────────────

    function test_exp_largeNegInput() public pure {
        // exp(-100): tiny positive number
        Decimal.D memory a = Decimal.D({mantissa: S, exponent: 2, negative: true});
        Decimal.D memory r = Decimal.exp(a);
        _assertNorm(r, "exp(-100)");
        assertFalse(r.negative, "exp(-100) positive");
        assertLe(r.exponent, -40, "exp(-100) exponent <= -40");
    }

    // ── (14) Known: exp(ln(10)) ~= 10 ────────────────────────────────────────

    function test_exp_ln10_isTen() public pure {
        Decimal.D memory ten   = Decimal.D({mantissa: S, exponent: 1, negative: false});
        Decimal.D memory lnTen = Decimal.ln(ten);
        Decimal.D memory r     = Decimal.exp(lnTen);
        assertLe(_relErr(r, ten), 3e9, "exp(ln(10)) ~= 10");
    }

    // ── (15) Known: exp(2) ~= 7.38906 ────────────────────────────────────────

    function test_exp_two_known() public pure {
        Decimal.D memory two      = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory r        = Decimal.exp(two);
        Decimal.D memory expected = Decimal.D({mantissa: 7_389_056_098_930_650_227, exponent: 0, negative: false});
        assertLe(_relErr(r, expected), 2e9, "exp(2) ~= 7.38906");
    }

    // ── (16) Consistency with pow(e, a) ──────────────────────────────────────

    function testFuzz_exp_consistentWithPow(uint64 mantRaw, int8 expRaw) public view {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) % 5;
        Decimal.D memory a    = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory r1   = Decimal.exp(a);
        Decimal.D memory r2   = Decimal.pow(E_VAL, a);
        assertLe(_relErr(r1, r2), 3e9, "exp(a) ~= pow(e,a)");
    }
}
