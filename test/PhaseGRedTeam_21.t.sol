// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {IDecimalErrors} from "../src/interfaces/IDecimalErrors.sol";

/// @dev Harness for vm.expectRevert on internal library reverts.
contract Ln21Harness {
    function ln(Decimal.D calldata a) external pure returns (Decimal.D memory) {
        return Decimal.ln(a);
    }
}

/// @notice Red-team / adversarial test suite for Phase G-21: Decimal.ln.
///
/// Attack surfaces:
///   (1)  Zero input reverts with Decimal__InvalidInput
///   (2)  Negative input reverts with Decimal__NegativeLog
///   (3)  ln(1) = 0  (exact)
///   (4)  ln(e) ~= 1  (within 2e-9)
///   (5)  ln(10) ~= 2.302585  (known value)
///   (6)  ln(2) ~= 0.693147  (known value)
///   (7)  Sign: ln(a) > 0 iff a > 1;  ln(a) < 0 iff a < 1  (fuzz)
///   (8)  Monotonicity: a < b => ln(a) < ln(b)  (fuzz)
///   (9)  Additive: ln(a*b) ~= ln(a) + ln(b)  (fuzz, m >= 2*S)
///  (10)  Consistency with log10: ln(a) * log10(e) ~= log10(a)  (fuzz)
///  (11)  Consistency with log2: ln(a) / ln(2) ~= log2(a)  (fuzz)
///  (12)  Round-trip: e^ln(a) ~= a  (fuzz, via pow)
///  (13)  Output always normalised  (fuzz)
///  (14)  Large exponent near EXP_LIMIT  (normalised, consistent with log10)
///  (15)  ln(a^n) ~= n * ln(a)  (scaling, n=2 fuzz)
contract PhaseGRedTeam21Test is Test {

    uint128 constant S  = uint128(Decimal.MANTISSA_SCALE);
    int64   constant EL = Decimal.EXP_LIMIT;

    Ln21Harness h = new Ln21Harness();

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

    // ── (1) Zero reverts ──────────────────────────────────────────────────────

    function test_ln_zero_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.ln(Decimal.zero());
    }

    // ── (2) Negative reverts ──────────────────────────────────────────────────

    function test_ln_negative_reverts() public {
        Decimal.D memory neg = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        vm.expectRevert(IDecimalErrors.Decimal__NegativeLog.selector);
        h.ln(neg);
    }

    // ── (3) ln(1) = 0 ────────────────────────────────────────────────────────

    function test_ln_one_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.ln(Decimal.one()), Decimal.zero()), "ln(1) == 0");
    }

    // ── (4) ln(e) ~= 1 ───────────────────────────────────────────────────────

    function test_ln_e_approxOne() public pure {
        // e = 2.718281828459045235...
        Decimal.D memory e = Decimal.D({mantissa: 2_718_281_828_459_045_235, exponent: 0, negative: false});
        Decimal.D memory r = Decimal.ln(e);
        assertFalse(r.negative, "ln(e) is positive");
        assertLe(_relErr(r, Decimal.one()), 2e9, "ln(e) ~= 1 within 2e-9");
    }

    // ── (5) ln(10) ~= 2.302585 ────────────────────────────────────────────────

    function test_ln_ten_approx() public pure {
        Decimal.D memory ten = Decimal.D({mantissa: S, exponent: 1, negative: false});
        Decimal.D memory r   = Decimal.ln(ten);
        // ln(10) = 2.302585092994045684...
        // mantissa = 2_302_585_092_994_045_684, exponent = 0
        assertEq(r.exponent, 0, "ln(10) exponent == 0");
        assertFalse(r.negative, "ln(10) is positive");
        uint256 expected = 2_302_585_092_994_045_684;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2e9, "ln(10) mantissa within 2e-9");
    }

    // ── (6) ln(2) ~= 0.693147 ────────────────────────────────────────────────

    function test_ln_two_approx() public pure {
        Decimal.D memory two = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory r   = Decimal.ln(two);
        // ln(2) = 0.6931471805599453094...
        // mantissa = 6_931_471_805_599_453_094, exponent = -1
        assertFalse(r.negative, "ln(2) is positive");
        assertLe(_relErr(r, Decimal.D({mantissa: 6_931_471_805_599_453_094, exponent: -1, negative: false})),
            2e9, "ln(2) within 2e-9");
    }

    // ── (7) Sign invariants ───────────────────────────────────────────────────

    function testFuzz_ln_sign_gt1(uint64 mantRaw, uint8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(uint64(expRaw) % 100) + 1;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory r = Decimal.ln(a);
        assertFalse(r.negative, "ln(a>1) should be positive");
        assertTrue(r.mantissa > 0, "ln(a>1) should be nonzero");
    }

    function testFuzz_ln_sign_lt1(uint64 mantRaw, uint8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = -(int64(uint64(expRaw) % 100) + 1);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory r = Decimal.ln(a);
        assertTrue(r.negative, "ln(0<a<1) should be negative");
        assertTrue(r.mantissa > 0, "ln(0<a<1) should be nonzero");
    }

    // ── (8) Monotonicity ──────────────────────────────────────────────────────

    function testFuzz_ln_monotone(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        if (!Decimal.lt(a, b)) return;
        assertTrue(
            Decimal.lt(Decimal.ln(a), Decimal.ln(b)) ||
            Decimal.eq(Decimal.ln(a), Decimal.ln(b)),
            "ln not monotone"
        );
    }

    // ── (9) Additive: ln(a*b) ~= ln(a) + ln(b) ───────────────────────────────

    function testFuzz_ln_additive(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (8 * uint64(S))) + 2 * S;
        uint128 mb = uint128(mantB % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.ln(Decimal.mul(a, b));
        Decimal.D memory rhs = Decimal.add(Decimal.ln(a), Decimal.ln(b));
        assertLe(_relErr(lhs, rhs), 3e9, "ln(a*b) ~= ln(a)+ln(b)");
    }

    // ── (10) Consistency with log10: ln(a) * log10(e) ~= log10(a) ────────────

    function testFuzz_ln_consistentWithLog10(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        int64   e = int64(expRaw);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory lna  = Decimal.ln(a);
        Decimal.D memory l10a = Decimal.log10(a);
        // log10(e) = 4_342_944_819_032_518_277e-1
        Decimal.D memory log10e = Decimal.D({mantissa: 4_342_944_819_032_518_277, exponent: -1, negative: false});
        Decimal.D memory lhs = Decimal.mul(lna, log10e);
        assertLe(_relErr(lhs, l10a), 3e9, "ln(a)*log10(e) ~= log10(a)");
    }

    // ── (11) Consistency with log2: ln(a) / ln(2) ~= log2(a) ────────────────

    function testFuzz_ln_consistentWithLog2(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        int64   e = int64(expRaw);
        Decimal.D memory a   = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory lna = Decimal.ln(a);
        Decimal.D memory l2a = Decimal.log2(a);
        // ln(2) = 6_931_471_805_599_453_094e-1
        Decimal.D memory ln2 = Decimal.D({mantissa: 6_931_471_805_599_453_094, exponent: -1, negative: false});
        Decimal.D memory lhs = Decimal.div(lna, ln2);
        assertLe(_relErr(lhs, l2a), 3e9, "ln(a)/ln(2) ~= log2(a)");
    }

    // ── (12) Round-trip: e^ln(a) ~= a  (via pow) ──────────────────────────────
    // Restrict to exponent=0 (a in [2,10)) so |ln(a)| <= ln(10) ~= 2.3.
    // Error in pow amplifies absolute error in ln by |ln(a)|: max ~2.3*3e-9 = 7e-9.

    function testFuzz_ln_roundTrip(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a   = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory lna = Decimal.ln(a);
        Decimal.D memory eVal = Decimal.D({mantissa: 2_718_281_828_459_045_235, exponent: 0, negative: false});
        Decimal.D memory rt   = Decimal.pow(eVal, lna);
        _assertNorm(rt, "e^ln(a)");
        assertLe(_relErr(a, rt), 1e10, "e^ln(a) ~= a within 1e-8");
    }

    // ── (13) Output always normalised ─────────────────────────────────────────

    function testFuzz_ln_normalised(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        _assertNorm(Decimal.ln(a), "ln normalised");
    }

    // ── (14) Large exponent near EXP_LIMIT ────────────────────────────────────

    function test_ln_largeExp() public pure {
        int64 bigE = EL - 1;
        Decimal.D memory a   = Decimal.pow10(bigE);
        Decimal.D memory r   = Decimal.ln(a);
        _assertNorm(r, "ln(10^(EL-1))");
        // Cross-check: ln(a) * log10(e) ~= log10(a) = bigE
        Decimal.D memory log10e   = Decimal.D({mantissa: 4_342_944_819_032_518_277, exponent: -1, negative: false});
        Decimal.D memory recovered = Decimal.mul(r, log10e);
        Decimal.D memory expected  = Decimal.fromInt(bigE);
        assertLe(_relErr(recovered, expected), 3e9, "ln(10^(EL-1))*log10(e) ~= EL-1");
    }

    // ── (15) Scaling: ln(a^2) ~= 2 * ln(a) ───────────────────────────────────

    function testFuzz_ln_scaling_sqr(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a   = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.ln(Decimal.sqr(a));
        Decimal.D memory la  = Decimal.ln(a);
        Decimal.D memory rhs = Decimal.add(la, la);
        assertLe(_relErr(lhs, rhs), 3e9, "ln(a^2) ~= 2*ln(a)");
    }
}
