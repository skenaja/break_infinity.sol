// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {IDecimalErrors} from "../src/interfaces/IDecimalErrors.sol";

/// @dev Harness for vm.expectRevert on internal library reverts.
contract Log220Harness {
    function log2(Decimal.D calldata a) external pure returns (Decimal.D memory) {
        return Decimal.log2(a);
    }
}

/// @notice Red-team / adversarial test suite for Phase G-20: Decimal.log2.
///
/// Attack surfaces:
///   (1)  Zero input reverts with Decimal__InvalidInput
///   (2)  Negative input reverts with Decimal__NegativeLog
///   (3)  log2(1) = 0  (exact)
///   (4)  log2(2) ~= 1  (within 2e-9)
///   (5)  log2(4) ~= 2  (exact powers of 2)
///   (6)  log2(2^n) ~= n  (fuzz, n = int8)
///   (7)  log2(10) ~= 3.32193  (known value within 2e-9)
///   (8)  Sign: log2(a) > 0 iff a > 1;  log2(a) < 0 iff a < 1  (fuzz)
///   (9)  Monotonicity: a < b => log2(a) < log2(b)  (fuzz)
///  (10)  Additive: log2(a*b) ~= log2(a) + log2(b)  (fuzz, m >= 2*S)
///  (11)  Consistency with log10: log2(a) * log10(2) ~= log10(a)  (fuzz)
///  (12)  Consistency with ln: log2(a) * ln(2) ~= ln(a)  (fuzz)
///  (13)  Round-trip: 2^log2(a) ~= a  (fuzz)
///  (14)  Output always normalised  (fuzz)
///  (15)  Large exponent near EXP_LIMIT  (exact integer multiple result)
contract PhaseGRedTeam20Test is Test {

    uint128 constant S  = uint128(Decimal.MANTISSA_SCALE);
    int64   constant EL = Decimal.EXP_LIMIT;

    Log220Harness h = new Log220Harness();

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

    function test_log2_zero_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.log2(Decimal.zero());
    }

    // ── (2) Negative reverts ──────────────────────────────────────────────────

    function test_log2_negative_reverts() public {
        Decimal.D memory neg = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        vm.expectRevert(IDecimalErrors.Decimal__NegativeLog.selector);
        h.log2(neg);
    }

    // ── (3) log2(1) = 0 ──────────────────────────────────────────────────────

    function test_log2_one_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.log2(Decimal.one()), Decimal.zero()), "log2(1) == 0");
    }

    // ── (4) log2(2) ~= 1 ─────────────────────────────────────────────────────

    function test_log2_two_isOne() public pure {
        Decimal.D memory two = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory r   = Decimal.log2(two);
        assertFalse(r.negative, "log2(2) is positive");
        // Result may normalise as D{~9.999e18, -1} (just below S) or D{1e18, 0}.
        // Check via relative error against one().
        assertLe(_relErr(r, Decimal.one()), 2e9, "log2(2) ~= 1 within 2e-9");
    }

    // ── (5) log2(4) ~= 2 ─────────────────────────────────────────────────────

    function test_log2_four_isTwo() public pure {
        Decimal.D memory four = Decimal.D({mantissa: 4 * S, exponent: 0, negative: false});
        Decimal.D memory r    = Decimal.log2(four);
        assertFalse(r.negative, "log2(4) is positive");
        // Check via relative error against D{2e18, 0} (the value 2).
        Decimal.D memory two = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        assertLe(_relErr(r, two), 2e9, "log2(4) ~= 2 within 2e-9");
    }

    // ── (6) log2(2^n) ~= n  (fuzz, n = int8) ────────────────────────────────

    function testFuzz_log2_pow2_isN(int8 rawN) public pure {
        int64 n = int64(rawN);
        // 2^n = 10^(n * log10(2)) — represent via pow
        // Use pow(two, fromInt(n)) to get 2^n
        Decimal.D memory two  = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory a    = Decimal.pow(two, Decimal.fromInt(n));
        if (a.mantissa == 0) return; // underflow/overflow edge
        Decimal.D memory r    = Decimal.log2(a);
        Decimal.D memory expN = Decimal.fromInt(n);
        // log/exp chain: ~4e-9 relative error
        assertLe(_relErr(r, expN), 4e9, "log2(2^n) ~= n");
    }

    // ── (7) log2(10) ~= 3.32193 ──────────────────────────────────────────────

    function test_log2_ten_approx() public pure {
        Decimal.D memory ten = Decimal.D({mantissa: S, exponent: 1, negative: false});
        Decimal.D memory r   = Decimal.log2(ten);
        // log2(10) = 3.321928094887362347...
        // mantissa = 3_321_928_094_887_362_347, exponent = 0
        assertEq(r.exponent, 0, "log2(10) exponent == 0");
        assertFalse(r.negative, "log2(10) is positive");
        uint256 expected = 3_321_928_094_887_362_347;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2e9, "log2(10) mantissa within 2e-9");
    }

    // ── (8) Sign invariants ───────────────────────────────────────────────────

    function testFuzz_log2_sign_gt1(uint64 mantRaw, uint8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(uint64(expRaw) % 100) + 1;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory r = Decimal.log2(a);
        assertFalse(r.negative, "log2(a>1) should be positive");
        assertTrue(r.mantissa > 0, "log2(a>1) should be nonzero");
    }

    function testFuzz_log2_sign_lt1(uint64 mantRaw, uint8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = -(int64(uint64(expRaw) % 100) + 1);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory r = Decimal.log2(a);
        assertTrue(r.negative, "log2(0<a<1) should be negative");
        assertTrue(r.mantissa > 0, "log2(0<a<1) should be nonzero");
    }

    // ── (9) Monotonicity ─────────────────────────────────────────────────────

    function testFuzz_log2_monotone(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        if (!Decimal.lt(a, b)) return;
        assertTrue(
            Decimal.lt(Decimal.log2(a), Decimal.log2(b)) ||
            Decimal.eq(Decimal.log2(a), Decimal.log2(b)),
            "log2 not monotone"
        );
    }

    // ── (10) Additive: log2(a*b) ~= log2(a) + log2(b) ────────────────────────

    function testFuzz_log2_additive(uint64 mantA, uint64 mantB) public pure {
        // m >= 2*S keeps log2Fixed away from zero's absolute error floor
        uint128 ma = uint128(mantA % (8 * uint64(S))) + 2 * S;
        uint128 mb = uint128(mantB % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.log2(Decimal.mul(a, b));
        Decimal.D memory rhs = Decimal.add(Decimal.log2(a), Decimal.log2(b));
        assertLe(_relErr(lhs, rhs), 3e9, "log2(a*b) ~= log2(a)+log2(b)");
    }

    // ── (11) Consistency with log10: log2(a) * log10(2) ~= log10(a) ──────────

    function testFuzz_log2_consistentWithLog10(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        int64   e = int64(expRaw);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory l2 = Decimal.log2(a);
        Decimal.D memory l10 = Decimal.log10(a);
        // log10(2) = 3_010_299_956_639_811_952e-1
        Decimal.D memory log10_2 = Decimal.D({mantissa: 3_010_299_956_639_811_952, exponent: -1, negative: false});
        Decimal.D memory lhs = Decimal.mul(l2, log10_2);
        assertLe(_relErr(lhs, l10), 3e9, "log2(a)*log10(2) ~= log10(a)");
    }

    // ── (12) Consistency with ln: log2(a) * ln(2) ~= ln(a) ──────────────────

    function testFuzz_log2_consistentWithLn(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        int64   e = int64(expRaw);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory l2  = Decimal.log2(a);
        Decimal.D memory lna = Decimal.ln(a);
        // ln(2) = 6_931_471_805_599_453_094e-1
        Decimal.D memory ln2 = Decimal.D({mantissa: 6_931_471_805_599_453_094, exponent: -1, negative: false});
        Decimal.D memory lhs = Decimal.mul(l2, ln2);
        assertLe(_relErr(lhs, lna), 3e9, "log2(a)*ln(2) ~= ln(a)");
    }

    // ── (13) Round-trip: 2^log2(a) ~= a ──────────────────────────────────────

    function testFuzz_log2_roundTrip(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        int64   e = int64(expRaw);
        Decimal.D memory a  = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory la = Decimal.log2(a);
        Decimal.D memory two = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory rt  = Decimal.pow(two, la);
        _assertNorm(rt, "2^log2(a)");
        assertLe(_relErr(a, rt), 3e9, "2^log2(a) ~= a within 3e-9");
    }

    // ── (14) Output always normalised ─────────────────────────────────────────

    function testFuzz_log2_normalised(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        _assertNorm(Decimal.log2(a), "log2 normalised");
    }

    // ── (15) Large exponent near EXP_LIMIT ────────────────────────────────────

    function test_log2_largeExp() public pure {
        // log2(10^(EL-1)) = (EL-1) * log2(10) — must be normalised and consistent
        int64 bigE = EL - 1;
        Decimal.D memory a   = Decimal.pow10(bigE);
        Decimal.D memory r   = Decimal.log2(a);
        _assertNorm(r, "log2(10^(EL-1))");
        // Cross-check: log2(a) * log10(2) ~= log10(a) = EL-1
        Decimal.D memory log10_2 = Decimal.D({mantissa: 3_010_299_956_639_811_952, exponent: -1, negative: false});
        Decimal.D memory recovered = Decimal.mul(r, log10_2);
        Decimal.D memory expected  = Decimal.fromInt(bigE);
        assertLe(_relErr(recovered, expected), 3e9, "log2(10^(EL-1))*log10(2) ~= EL-1");
    }
}
