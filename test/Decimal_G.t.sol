// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {IDecimalErrors} from "../src/interfaces/IDecimalErrors.sol";

/// @dev Harness for vm.expectRevert on library reverts.
contract GHarness {
    function log10(Decimal.D calldata a) external pure returns (Decimal.D memory) {
        return Decimal.log10(a);
    }
    function log2(Decimal.D calldata a) external pure returns (Decimal.D memory) {
        return Decimal.log2(a);
    }
    function ln(Decimal.D calldata a) external pure returns (Decimal.D memory) {
        return Decimal.ln(a);
    }
    function logBase(Decimal.D calldata a, Decimal.D calldata base)
        external pure returns (Decimal.D memory)
    {
        return Decimal.log(a, base);
    }
}

/// @notice Tests for Phase G: log10, log2, ln, log(a, base).
contract DecimalGTest is Test {

    uint128 constant S = uint128(Decimal.MANTISSA_SCALE);
    GHarness h = new GHarness();

    // ── helpers ──────────────────────────────────────────────────────────────

    function _assertNorm(Decimal.D memory d, string memory lbl) internal pure {
        if (d.mantissa == 0) {
            assertEq(d.exponent, 0,  string.concat(lbl, ": zero.exp"));
            assertFalse(d.negative,  string.concat(lbl, ": zero.neg"));
        } else {
            assertGe(d.mantissa, S,      string.concat(lbl, ": >= SCALE"));
            assertLt(d.mantissa, 10 * S, string.concat(lbl, ": < MAX"));
        }
    }

    /// Absolute diff scaled to 1e18 denominator (both D must share exponent or differ by 1).
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

    // =========================================================================
    // log10
    // =========================================================================

    // ── revert cases ──────────────────────────────────────────────────────────

    function test_log10_zero_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.log10(Decimal.zero());
    }

    function test_log10_negative_reverts() public {
        Decimal.D memory neg = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        vm.expectRevert(IDecimalErrors.Decimal__NegativeLog.selector);
        h.log10(neg);
    }

    // ── exact integer results ─────────────────────────────────────────────────

    function test_log10_one_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.log10(Decimal.one()), Decimal.zero()),
            "log10(1) == 0");
    }

    function test_log10_ten_isOne() public pure {
        // log10(10) = 1
        assertTrue(Decimal.eq(Decimal.log10(Decimal.fromUint(10)), Decimal.one()),
            "log10(10) == 1");
    }

    function test_log10_hundred_isTwo() public pure {
        assertTrue(Decimal.eq(Decimal.log10(Decimal.fromUint(100)), Decimal.fromUint(2)),
            "log10(100) == 2");
    }

    function test_log10_pointOne_isNegOne() public pure {
        // 0.1 = D{1e18, -1, false} / ... actually fromUint can't do fractions.
        // 10^-1 = pow10(-1)
        Decimal.D memory r = Decimal.log10(Decimal.pow10(-1));
        assertTrue(Decimal.eq(r, Decimal.fromInt(-1)), "log10(0.1) == -1");
    }

    function testFuzz_log10_pow10_isN(int8 rawN) public pure {
        int64 n = int64(rawN);
        Decimal.D memory r = Decimal.log10(Decimal.pow10(n));
        assertTrue(Decimal.eq(r, Decimal.fromInt(int256(n))),
            "log10(10^n) == n");
    }

    // ── sign: log10 < 0 for a < 1, > 0 for a > 1 ────────────────────────────

    function test_log10_sign_lt1() public pure {
        // log10(0.5) < 0
        Decimal.D memory half = Decimal.D({mantissa: 5 * S, exponent: -1, negative: false});
        assertTrue(Decimal.lt(Decimal.log10(half), Decimal.zero()), "log10(0.5) < 0");
    }

    function test_log10_sign_gt1() public pure {
        // log10(2) > 0
        assertTrue(Decimal.lt(Decimal.zero(), Decimal.log10(Decimal.fromUint(2))),
            "log10(2) > 0");
    }

    // ── known fractional value: log10(2) ~= 0.30103 ──────────────────────────

    function test_log10_two_approx() public pure {
        Decimal.D memory r = Decimal.log10(Decimal.fromUint(2));
        // Expected: D{3010299956639811952, -1, false}  (≈ 0.30103)
        Decimal.D memory expected = Decimal.D({
            mantissa: 3_010_299_956_639_811_952,
            exponent: -1,
            negative: false
        });
        assertLe(_relErr(r, expected), 2e9, "log10(2) within 2e-9");
    }

    // ── normalisation (fuzz) ──────────────────────────────────────────────────

    function testFuzz_log10_normalised(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw) * 5;
        _assertNorm(Decimal.log10(Decimal.D({mantissa: m, exponent: e, negative: false})),
            "log10 normalised");
    }

    // ── monotonicity (fuzz) ───────────────────────────────────────────────────

    function testFuzz_log10_monotone(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        if (!Decimal.lt(a, b)) return;
        Decimal.D memory la = Decimal.log10(a);
        Decimal.D memory lb = Decimal.log10(b);
        assertTrue(Decimal.lt(la, lb) || Decimal.eq(la, lb), "log10 not monotone");
    }

    // ── round-trip: pow(10, log10(x)) ~= x ───────────────────────────────────

    function testFuzz_log10_roundTrip(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory x  = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory rt = Decimal.pow(Decimal.pow10(1), Decimal.log10(x));
        _assertNorm(rt, "pow(10, log10(x))");
        assertLe(_relErr(x, rt), 2e9, "pow(10, log10(x)) ~= x within 2e-9");
    }

    // =========================================================================
    // log2
    // =========================================================================

    function test_log2_zero_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.log2(Decimal.zero());
    }

    function test_log2_negative_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__NegativeLog.selector);
        h.log2(Decimal.D({mantissa: S, exponent: 0, negative: true}));
    }

    function test_log2_one_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.log2(Decimal.one()), Decimal.zero()), "log2(1)==0");
    }

    function test_log2_two_isOne() public pure {
        // log2(2) = 1
        Decimal.D memory r = Decimal.log2(Decimal.fromUint(2));
        assertLe(_relErr(r, Decimal.one()), 2e9, "log2(2) ~= 1 within 2e-9");
    }

    function test_log2_four_isTwo() public pure {
        Decimal.D memory r = Decimal.log2(Decimal.fromUint(4));
        assertLe(_relErr(r, Decimal.fromUint(2)), 2e9, "log2(4) ~= 2 within 2e-9");
    }

    function test_log2_pow10_1_approx() public pure {
        // log2(10) ~= 3.32193
        Decimal.D memory r = Decimal.log2(Decimal.pow10(1));
        Decimal.D memory expected = Decimal.D({
            mantissa: 3_321_928_094_887_362_347,
            exponent: 0,
            negative: false
        });
        assertLe(_relErr(r, expected), 2e9, "log2(10) within 2e-9");
    }

    function testFuzz_log2_normalised(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        _assertNorm(
            Decimal.log2(Decimal.D({mantissa: m, exponent: int64(expRaw), negative: false})),
            "log2 normalised"
        );
    }

    // log2(a) = log10(a) / log10(2)  (consistency with log10)
    function testFuzz_log2_consistentWithLog10(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory a  = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory l2 = Decimal.log2(a);
        Decimal.D memory l10 = Decimal.log10(a);
        if (l10.mantissa == 0) { assertTrue(l2.mantissa == 0, "log2(1)==0"); return; }
        // log2(a) * log10(2) ~= log10(a)
        Decimal.D memory check = Decimal.mul(l2,
            Decimal.D({mantissa: 3_010_299_956_639_811_952, exponent: -1, negative: false}));
        assertLe(_relErr(check, l10), 2e9, "log2*log10(2) ~= log10 within 2e-9");
    }

    // =========================================================================
    // ln
    // =========================================================================

    function test_ln_zero_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.ln(Decimal.zero());
    }

    function test_ln_negative_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__NegativeLog.selector);
        h.ln(Decimal.D({mantissa: S, exponent: 0, negative: true}));
    }

    function test_ln_one_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.ln(Decimal.one()), Decimal.zero()), "ln(1)==0");
    }

    function test_ln_e_approxOne() public pure {
        // e ~= 2.71828...: represent as D{2718281828459045235, 0, false}
        Decimal.D memory e_val = Decimal.D({
            mantissa: 2_718_281_828_459_045_235,
            exponent: 0,
            negative: false
        });
        Decimal.D memory r = Decimal.ln(e_val);
        assertLe(_relErr(r, Decimal.one()), 2e9, "ln(e) ~= 1 within 2e-9");
    }

    function test_ln_ten_approx() public pure {
        // ln(10) ~= 2.302585...
        Decimal.D memory r = Decimal.ln(Decimal.pow10(1));
        Decimal.D memory expected = Decimal.D({
            mantissa: 2_302_585_092_994_045_684,
            exponent: 0,
            negative: false
        });
        assertLe(_relErr(r, expected), 2e9, "ln(10) within 2e-9");
    }

    function testFuzz_ln_normalised(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        _assertNorm(
            Decimal.ln(Decimal.D({mantissa: m, exponent: int64(expRaw), negative: false})),
            "ln normalised"
        );
    }

    // ln and log2 must be consistent: ln(a) = log2(a) * ln(2)
    function testFuzz_ln_consistentWithLog2(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory a   = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory lna = Decimal.ln(a);
        Decimal.D memory l2a = Decimal.log2(a);
        if (lna.mantissa == 0 || l2a.mantissa == 0) return;
        // ln(a) / log2(a) ~= ln(2) = 0.693147...
        Decimal.D memory ratio = Decimal.div(lna, l2a);
        Decimal.D memory ln2   = Decimal.D({
            mantissa: 6_931_471_805_599_453_094,
            exponent: -1,
            negative: false
        });
        assertLe(_relErr(ratio, ln2), 2e9, "ln/log2 ~= ln(2) within 2e-9");
    }

    // =========================================================================
    // log(a, base)
    // =========================================================================

    function test_log_base1_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.logBase(Decimal.fromUint(5), Decimal.one());
    }

    function test_log_zeroArg_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.logBase(Decimal.zero(), Decimal.fromUint(2));
    }

    function test_log_negBase_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__NegativeLog.selector);
        h.logBase(Decimal.fromUint(8),
            Decimal.D({mantissa: 2 * S, exponent: 0, negative: true}));
    }

    function test_log_selfBase_isOne() public pure {
        // log_b(b) = 1 for any valid base
        Decimal.D memory b = Decimal.fromUint(7);
        assertLe(_relErr(Decimal.log(b, b), Decimal.one()), 2e9, "log_b(b) ~= 1");
    }

    function test_log_base10_matchesLog10() public pure {
        Decimal.D memory x = Decimal.fromUint(42);
        Decimal.D memory r1 = Decimal.log10(x);
        Decimal.D memory r2 = Decimal.log(x, Decimal.pow10(1));
        assertLe(_relErr(r1, r2), 2e9, "log(x,10) ~= log10(x)");
    }

    function test_log_base2_matchesLog2() public pure {
        Decimal.D memory x = Decimal.fromUint(42);
        Decimal.D memory r1 = Decimal.log2(x);
        Decimal.D memory r2 = Decimal.log(x, Decimal.fromUint(2));
        assertLe(_relErr(r1, r2), 2e9, "log(x,2) ~= log2(x)");
    }

    function test_log_oneArg_isZero() public pure {
        // log_b(1) = 0 for any base
        assertTrue(Decimal.eq(
            Decimal.log(Decimal.one(), Decimal.fromUint(7)),
            Decimal.zero()
        ), "log_b(1) == 0");
    }

    function test_log_base10_pow_isN() public pure {
        // log_10(10^5) = 5
        Decimal.D memory r = Decimal.log(Decimal.pow10(5), Decimal.pow10(1));
        assertLe(_relErr(r, Decimal.fromUint(5)), 2e9, "log_10(10^5) ~= 5");
    }

    function testFuzz_log_normalised(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory x = Decimal.D({mantissa: m, exponent: e, negative: false});
        // Use base 10 to avoid pathological bases
        _assertNorm(Decimal.log(x, Decimal.pow10(1)), "log(x,10) normalised");
    }

    // Change-of-base: log_b(x) * log_c(b) ~= log_c(x)
    function testFuzz_log_changeOfBase(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(expRaw);
        Decimal.D memory x    = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory b    = Decimal.fromUint(2);
        Decimal.D memory c    = Decimal.pow10(1); // base 10
        Decimal.D memory logBX = Decimal.log(x, b);
        Decimal.D memory logCB = Decimal.log(b, c);
        if (logBX.mantissa == 0 || logCB.mantissa == 0) return;
        Decimal.D memory lhs  = Decimal.mul(logBX, logCB);   // log_b(x) * log_10(2)
        Decimal.D memory rhs  = Decimal.log(x, c);           // log_10(x)
        if (rhs.mantissa == 0) return;
        assertLe(_relErr(lhs, rhs), 3e9, "change-of-base within 3e-9");
    }
}
