// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {IDecimalErrors} from "../src/interfaces/IDecimalErrors.sol";

/// @dev Harness for vm.expectRevert on internal library reverts.
contract Log1019Harness {
    function log10(Decimal.D calldata a) external pure returns (Decimal.D memory) {
        return Decimal.log10(a);
    }
}

/// @notice Red-team / adversarial test suite for Phase G-19: Decimal.log10.
///
/// Attack surfaces:
///   (1)  Zero input reverts with Decimal__InvalidInput
///   (2)  Negative input reverts with Decimal__NegativeLog
///   (3)  log10(1) = 0  (exact)
///   (4)  log10(10^n) = n  (fuzz, all int8 n)
///   (5)  log10(0.1) = -1;  log10(100) = 2  (known exact)
///   (6)  Sign: log10(a) > 0 iff a > 1;  log10(a) < 0 iff a < 1  (fuzz)
///   (7)  Monotonicity: a < b => log10(a) < log10(b)  (fuzz)
///   (8)  Additive: log10(a*b) ~= log10(a) + log10(b)  (fuzz)
///   (9)  Round-trip: 10^log10(a) ~= a  (fuzz)
///  (10)  Scaling: log10(a^n) ~= n * log10(a)  (n=2,3 fuzz)
///  (11)  Output always normalised  (fuzz)
///  (12)  Known value: log10(2) ~= 0.30103  (within 2e-9)
///  (13)  Known value: log10(e) ~= 0.43429  (within 2e-9)
///  (14)  Large exponent near EXP_LIMIT  (exact integer result)
///  (15)  Subtraction: log10(a/b) ~= log10(a) - log10(b)  (fuzz)
contract PhaseGRedTeam19Test is Test {

    uint128 constant S  = uint128(Decimal.MANTISSA_SCALE);
    int64   constant EL = Decimal.EXP_LIMIT;

    Log1019Harness h = new Log1019Harness();

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

    function test_log10_zero_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.log10(Decimal.zero());
    }

    // ── (2) Negative reverts ──────────────────────────────────────────────────

    function test_log10_negative_reverts() public {
        Decimal.D memory neg = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        vm.expectRevert(IDecimalErrors.Decimal__NegativeLog.selector);
        h.log10(neg);
    }

    // ── (3) log10(1) = 0 ─────────────────────────────────────────────────────

    function test_log10_one_isZero() public pure {
        Decimal.D memory r = Decimal.log10(Decimal.one());
        assertTrue(Decimal.eq(r, Decimal.zero()), "log10(1) == 0");
    }

    // ── (4) log10(10^n) = n  (fuzz) ───────────────────────────────────────────

    function testFuzz_log10_pow10_isN(int8 rawN) public pure {
        int64 n = int64(rawN);
        Decimal.D memory r = Decimal.log10(Decimal.pow10(n));
        Decimal.D memory expected = Decimal.fromInt(n);
        assertTrue(Decimal.eq(r, expected),
            string.concat("log10(10^n) == n for n=", vm.toString(n)));
    }

    // ── (5) Known exact values ─────────────────────────────────────────────────

    function test_log10_pointOne_isNegOne() public pure {
        // 0.1 = 10^-1
        Decimal.D memory a = Decimal.pow10(-1);
        assertTrue(Decimal.eq(Decimal.log10(a), Decimal.fromInt(-1)), "log10(0.1) == -1");
    }

    function test_log10_hundred_isTwo() public pure {
        // 100 = 10^2
        Decimal.D memory a = Decimal.pow10(2);
        assertTrue(Decimal.eq(Decimal.log10(a), Decimal.fromInt(2)), "log10(100) == 2");
    }

    // ── (6) Sign invariants ────────────────────────────────────────────────────

    function testFuzz_log10_sign_gt1(uint64 mantRaw, uint8 expRaw) public pure {
        // a > 1 => log10(a) > 0
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        // Use positive exponent so a >= 1e18/1e18 * 10^1 > 1
        int64 e = int64(uint64(expRaw) % 100) + 1;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory r = Decimal.log10(a);
        assertFalse(r.negative, "log10(a>1) should be positive");
        assertTrue(r.mantissa > 0, "log10(a>1) should be nonzero");
    }

    function testFuzz_log10_sign_lt1(uint64 mantRaw, uint8 expRaw) public pure {
        // a in (0,1) => log10(a) < 0
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        // Negative exponent: a = m/S * 10^(-e) < 1 for e >= 1 since m < 10*S
        int64 e = -(int64(uint64(expRaw) % 100) + 1);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory r = Decimal.log10(a);
        assertTrue(r.negative, "log10(0<a<1) should be negative");
        assertTrue(r.mantissa > 0, "log10(0<a<1) should be nonzero");
    }

    // ── (7) Monotonicity ───────────────────────────────────────────────────────

    function testFuzz_log10_monotone(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        if (!Decimal.lt(a, b)) return;
        Decimal.D memory la = Decimal.log10(a);
        Decimal.D memory lb = Decimal.log10(b);
        assertTrue(
            Decimal.lt(la, lb) || Decimal.eq(la, lb),
            "log10 not monotone"
        );
    }

    // ── (8) Additive: log10(a*b) ~= log10(a) + log10(b) ──────────────────────

    function testFuzz_log10_additive(uint64 mantA, uint64 mantB) public pure {
        // Use m >= 2*S so log10Fixed(m) >= log10(2)*1e18 ~= 3e17, well above absolute error floor.
        uint128 ma = uint128(mantA % (8 * uint64(S))) + 2 * S;
        uint128 mb = uint128(mantB % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.log10(Decimal.mul(a, b));
        Decimal.D memory rhs = Decimal.add(Decimal.log10(a), Decimal.log10(b));
        // Three transcendental ops: ~3e-9 tolerance
        assertLe(_relErr(lhs, rhs), 3e9, "log10(a*b) ~= log10(a)+log10(b)");
    }

    // ── (9) Round-trip: 10^log10(a) ~= a ──────────────────────────────────────

    function testFuzz_log10_roundTrip(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory a  = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory la = Decimal.log10(a);
        // 10^log10(a) via pow(ten, la)
        Decimal.D memory ten = Decimal.D({mantissa: S, exponent: 1, negative: false});
        Decimal.D memory rt = Decimal.pow(ten, la);
        _assertNorm(rt, "10^log10(a)");
        assertLe(_relErr(a, rt), 3e9, "10^log10(a) ~= a within 3e-9");
    }

    // ── (10) Scaling: log10(a^n) ~= n * log10(a) ──────────────────────────────

    function testFuzz_log10_scaling_sqr(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a   = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.log10(Decimal.sqr(a));
        Decimal.D memory rhs = Decimal.add(Decimal.log10(a), Decimal.log10(a));
        assertLe(_relErr(lhs, rhs), 3e9, "log10(a^2) ~= 2*log10(a)");
    }

    function testFuzz_log10_scaling_cube(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a   = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory la  = Decimal.log10(a);
        Decimal.D memory lhs = Decimal.log10(Decimal.cube(a));
        Decimal.D memory rhs = Decimal.add(la, Decimal.add(la, la));
        assertLe(_relErr(lhs, rhs), 3e9, "log10(a^3) ~= 3*log10(a)");
    }

    // ── (11) Output always normalised ──────────────────────────────────────────

    function testFuzz_log10_normalised(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        _assertNorm(Decimal.log10(a), "log10 normalised");
    }

    // ── (12) Known value: log10(2) ────────────────────────────────────────────

    function test_log10_two_approx() public pure {
        Decimal.D memory two = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory r   = Decimal.log10(two);
        // log10(2) = 0.3010299956639811952...
        // mantissa = 3_010_299_956_639_811_952, exponent = -1
        assertEq(r.exponent, -1, "log10(2) exponent == -1");
        assertFalse(r.negative, "log10(2) is positive");
        uint256 expected = 3_010_299_956_639_811_952;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2e9, "log10(2) mantissa within 2e-9 relative");
    }

    // ── (13) Known value: log10(e) ────────────────────────────────────────────

    function test_log10_e_approx() public pure {
        // e ~= 2.718281828459045235
        // Represent e as D: mantissa = 2_718_281_828_459_045_235, exponent = 0
        Decimal.D memory e = Decimal.D({mantissa: 2_718_281_828_459_045_235, exponent: 0, negative: false});
        Decimal.D memory r = Decimal.log10(e);
        // log10(e) = 0.4342944819032518277...
        // mantissa = 4_342_944_819_032_518_277, exponent = -1
        assertEq(r.exponent, -1, "log10(e) exponent == -1");
        assertFalse(r.negative, "log10(e) is positive");
        uint256 expected = 4_342_944_819_032_518_277;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2e9, "log10(e) mantissa within 2e-9 relative");
    }

    // ── (14) Large exponent near EXP_LIMIT ────────────────────────────────────

    function test_log10_largeExp_exact() public pure {
        // log10(10^(EL-1)) = EL-1 exactly
        int64 bigE = EL - 1;
        Decimal.D memory a = Decimal.pow10(bigE);
        Decimal.D memory r = Decimal.log10(a);
        assertTrue(Decimal.eq(r, Decimal.fromInt(bigE)),
            "log10(10^(EL-1)) == EL-1");
    }

    function test_log10_largeNegExp_exact() public pure {
        int64 bigNeg = -(EL - 1);
        Decimal.D memory a = Decimal.pow10(bigNeg);
        Decimal.D memory r = Decimal.log10(a);
        assertTrue(Decimal.eq(r, Decimal.fromInt(bigNeg)),
            "log10(10^-(EL-1)) == -(EL-1)");
    }

    // ── (15) Subtraction: log10(a/b) ~= log10(a) - log10(b) ─────────────────

    function testFuzz_log10_subtraction(uint64 mantA, uint64 mantB) public pure {
        // Use m >= 2*S and different exponents so log10(a) - log10(b) never cancels near zero.
        // a.exp=1: log10(a) in [1.30, 2), b.exp=0: log10(b) in [0.30, 1) => diff in (0.30, 1.70).
        uint128 ma = uint128(mantA % (8 * uint64(S))) + 2 * S;
        uint128 mb = uint128(mantB % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 1, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.log10(Decimal.div(a, b));
        Decimal.D memory rhs = Decimal.sub(Decimal.log10(a), Decimal.log10(b));
        assertLe(_relErr(lhs, rhs), 3e9, "log10(a/b) ~= log10(a)-log10(b)");
    }
}
