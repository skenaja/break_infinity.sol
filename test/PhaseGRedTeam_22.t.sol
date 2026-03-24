// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {IDecimalErrors} from "../src/interfaces/IDecimalErrors.sol";

/// @dev Harness for vm.expectRevert on internal library reverts.
contract Log22Harness {
    function log(Decimal.D calldata a, Decimal.D calldata base)
        external pure returns (Decimal.D memory)
    {
        return Decimal.log(a, base);
    }
    function log10(Decimal.D calldata a) external pure returns (Decimal.D memory) {
        return Decimal.log10(a);
    }
}

/// @notice Red-team / adversarial test suite for Phase G-22: Decimal.log(a, base).
///
/// Attack surfaces:
///   (1)  Zero argument reverts with Decimal__InvalidInput
///   (2)  Negative argument reverts with Decimal__NegativeLog
///   (3)  Zero base reverts with Decimal__InvalidInput
///   (4)  Negative base reverts with Decimal__NegativeLog
///   (5)  Base = 1 reverts with Decimal__InvalidInput (log base 1 undefined)
///   (6)  log(1, b) = 0  for any valid base  (fuzz)
///   (7)  log(b, b) ~= 1  for any valid base  (fuzz)
///   (8)  log(a, 10) ~= log10(a)  (consistency, fuzz)
///   (9)  log(a, 2)  ~= log2(a)   (consistency, fuzz)
///  (10)  log(a, e)  ~= ln(a)     (consistency, fuzz)
///  (11)  Change of base: log(a, b) = log10(a) / log10(b)  (fuzz)
///  (12)  Inverse: b^log(a,b) ~= a  (fuzz, base in [2,10), exponent=0)
///  (13)  Composition: log(a^n, b) ~= n * log(a, b)  (n=2, fuzz)
///  (14)  Monotonicity (base > 1): a < c => log(a,b) < log(c,b)  (fuzz)
///  (15)  Output always normalised  (fuzz)
///  (16)  Known: log(1000, 10) = 3  (exact)
///  (17)  Known: log(8, 2) ~= 3    (within 2e-9)
contract PhaseGRedTeam22Test is Test {

    uint128 constant S  = uint128(Decimal.MANTISSA_SCALE);
    int64   constant EL = Decimal.EXP_LIMIT;

    Log22Harness h = new Log22Harness();

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

    // ── (1) Zero argument reverts ─────────────────────────────────────────────

    function test_log_zeroArg_reverts() public {
        Decimal.D memory ten = Decimal.D({mantissa: S, exponent: 1, negative: false});
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.log(Decimal.zero(), ten);
    }

    // ── (2) Negative argument reverts ────────────────────────────────────────

    function test_log_negArg_reverts() public {
        Decimal.D memory neg = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        Decimal.D memory ten = Decimal.D({mantissa: S, exponent: 1, negative: false});
        vm.expectRevert(IDecimalErrors.Decimal__NegativeLog.selector);
        h.log(neg, ten);
    }

    // ── (3) Zero base reverts ─────────────────────────────────────────────────

    function test_log_zeroBase_reverts() public {
        Decimal.D memory two = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.log(two, Decimal.zero());
    }

    // ── (4) Negative base reverts ─────────────────────────────────────────────

    function test_log_negBase_reverts() public {
        Decimal.D memory two    = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory negTwo = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        vm.expectRevert(IDecimalErrors.Decimal__NegativeLog.selector);
        h.log(two, negTwo);
    }

    // ── (5) Base = 1 reverts ──────────────────────────────────────────────────

    function test_log_base1_reverts() public {
        Decimal.D memory two = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.log(two, Decimal.one());
    }

    // ── (6) log(1, b) = 0 ────────────────────────────────────────────────────

    function testFuzz_log_oneArg_isZero(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S; // base > 1
        Decimal.D memory base = Decimal.D({mantissa: m, exponent: 0, negative: false});
        assertTrue(Decimal.eq(Decimal.log(Decimal.one(), base), Decimal.zero()),
            "log(1, b) == 0");
    }

    // ── (7) log(b, b) ~= 1 ───────────────────────────────────────────────────

    function testFuzz_log_selfBase_isOne(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        Decimal.D memory base = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory r    = Decimal.log(base, base);
        assertLe(_relErr(r, Decimal.one()), 2e9, "log(b,b) ~= 1 within 2e-9");
    }

    // ── (8) log(a, 10) ~= log10(a) ────────────────────────────────────────────

    function testFuzz_log_base10_matchesLog10(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        int64   e = int64(expRaw);
        Decimal.D memory a   = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory ten = Decimal.D({mantissa: S, exponent: 1, negative: false});
        Decimal.D memory r1  = Decimal.log(a, ten);
        Decimal.D memory r2  = Decimal.log10(a);
        assertLe(_relErr(r1, r2), 3e9, "log(a,10) ~= log10(a)");
    }

    // ── (9) log(a, 2) ~= log2(a) ─────────────────────────────────────────────

    function testFuzz_log_base2_matchesLog2(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        int64   e = int64(expRaw);
        Decimal.D memory a   = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory two = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory r1  = Decimal.log(a, two);
        Decimal.D memory r2  = Decimal.log2(a);
        assertLe(_relErr(r1, r2), 3e9, "log(a,2) ~= log2(a)");
    }

    // ── (10) log(a, e) ~= ln(a) ──────────────────────────────────────────────

    function testFuzz_log_baseE_matchesLn(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        int64   e = int64(expRaw);
        Decimal.D memory a    = Decimal.D({mantissa: m, exponent: e, negative: false});
        Decimal.D memory eVal = Decimal.D({mantissa: 2_718_281_828_459_045_235, exponent: 0, negative: false});
        Decimal.D memory r1   = Decimal.log(a, eVal);
        Decimal.D memory r2   = Decimal.ln(a);
        assertLe(_relErr(r1, r2), 3e9, "log(a,e) ~= ln(a)");
    }

    // ── (11) Change of base: log(a, b) * log10(b) ~= log10(a) ────────────────

    function testFuzz_log_changeOfBase(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (8 * uint64(S))) + 2 * S;
        uint128 mb = uint128(mantB % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a    = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory base = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        Decimal.D memory lab  = Decimal.log(a, base);
        Decimal.D memory l10b = Decimal.log10(base);
        Decimal.D memory l10a = Decimal.log10(a);
        Decimal.D memory recovered = Decimal.mul(lab, l10b);
        assertLe(_relErr(recovered, l10a), 3e9, "log(a,b)*log10(b) ~= log10(a)");
    }

    // ── (12) Inverse: b^log(a,b) ~= a ────────────────────────────────────────
    // Restrict base and a to exponent=0, mantissa in [2*S, 10*S) to bound error amplification.

    function testFuzz_log_inverse(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (8 * uint64(S))) + 2 * S;
        uint128 mb = uint128(mantB % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a    = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory base = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        Decimal.D memory lab  = Decimal.log(a, base);
        Decimal.D memory rt   = Decimal.pow(base, lab);
        _assertNorm(rt, "b^log(a,b)");
        assertLe(_relErr(a, rt), 1e10, "b^log(a,b) ~= a within 1e-8");
    }

    // ── (13) Composition: log(a^2, b) ~= 2 * log(a, b) ───────────────────────

    function testFuzz_log_scalingSquare(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (8 * uint64(S))) + 2 * S;
        uint128 mb = uint128(mantB % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a    = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory base = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        Decimal.D memory lhs  = Decimal.log(Decimal.sqr(a), base);
        Decimal.D memory la   = Decimal.log(a, base);
        Decimal.D memory rhs  = Decimal.add(la, la);
        assertLe(_relErr(lhs, rhs), 3e9, "log(a^2,b) ~= 2*log(a,b)");
    }

    // ── (14) Monotonicity (base > 1) ─────────────────────────────────────────

    function testFuzz_log_monotone(uint64 mantA, uint64 mantC, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (8 * uint64(S))) + 2 * S;
        uint128 mc = uint128(mantC % (8 * uint64(S))) + 2 * S;
        uint128 mb = uint128(mantB % (8 * uint64(S))) + 2 * S;
        Decimal.D memory a    = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory c    = Decimal.D({mantissa: mc, exponent: 0, negative: false});
        Decimal.D memory base = Decimal.D({mantissa: mb, exponent: 1, negative: false}); // base >= 20 > 1
        if (!Decimal.lt(a, c)) return;
        assertTrue(
            Decimal.lt(Decimal.log(a, base), Decimal.log(c, base)) ||
            Decimal.eq(Decimal.log(a, base), Decimal.log(c, base)),
            "log not monotone for base > 1"
        );
    }

    // ── (15) Output always normalised ─────────────────────────────────────────

    function testFuzz_log_normalised(uint64 mantA, uint64 mantB, int8 expRaw) public pure {
        uint128 ma = uint128(mantA % (8 * uint64(S))) + 2 * S;
        uint128 mb = uint128(mantB % (8 * uint64(S))) + 2 * S;
        int64   e  = int64(expRaw);
        Decimal.D memory a    = Decimal.D({mantissa: ma, exponent: e, negative: false});
        Decimal.D memory base = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        _assertNorm(Decimal.log(a, base), "log normalised");
    }

    // ── (16) Known: log(1000, 10) = 3 ────────────────────────────────────────

    function test_log_base10_pow_isN() public pure {
        Decimal.D memory a   = Decimal.pow10(3); // 1000
        Decimal.D memory ten = Decimal.D({mantissa: S, exponent: 1, negative: false});
        Decimal.D memory r   = Decimal.log(a, ten);
        assertTrue(Decimal.eq(r, Decimal.fromInt(3)), "log(1000,10) == 3");
    }

    // ── (17) Known: log(8, 2) ~= 3 ───────────────────────────────────────────

    function test_log_base2_8_isThree() public pure {
        Decimal.D memory eight = Decimal.D({mantissa: 8 * S, exponent: 0, negative: false});
        Decimal.D memory two   = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory r     = Decimal.log(eight, two);
        Decimal.D memory three = Decimal.D({mantissa: 3 * S, exponent: 0, negative: false});
        assertLe(_relErr(r, three), 2e9, "log(8,2) ~= 3 within 2e-9");
    }
}
