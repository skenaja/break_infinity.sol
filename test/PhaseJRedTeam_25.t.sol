// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {IDecimalErrors} from "../src/interfaces/IDecimalErrors.sol";

contract Hyp25Harness {
    function acosh(Decimal.D calldata a) external pure returns (Decimal.D memory) { return Decimal.acosh(a); }
    function atanh(Decimal.D calldata a) external pure returns (Decimal.D memory) { return Decimal.atanh(a); }
}

/// @notice Red-team / adversarial test suite for Phase J-25: sinh, cosh, tanh, asinh, acosh, atanh.
///
/// Attack surfaces:
///   (1)  cosh(0)=1, sinh(0)=0, tanh(0)=0, asinh(0)=0, atanh(0)=0  (exact)
///   (2)  cosh(-x) = cosh(x)  (even function, fuzz)
///   (3)  sinh(-x) = -sinh(x)  (odd function, fuzz)
///   (4)  tanh(-x) = -tanh(x)  (odd function, fuzz)
///   (5)  cosh^2(x) - sinh^2(x) = 1  (Pythagorean identity, fuzz)
///   (6)  tanh(x) = sinh(x)/cosh(x)  (consistency, fuzz)
///   (7)  cosh(x) >= 1 always  (fuzz)
///   (8)  |tanh(x)| < 1 always  (fuzz)
///   (9)  sinh(asinh(x)) ~= x  (round-trip, fuzz)
///  (10)  cosh(acosh(x)) ~= x  (round-trip, fuzz, x >= 1)
///  (11)  tanh(atanh(x)) ~= x  (round-trip, fuzz, |x| < 1)
///  (12)  acosh: revert for x < 1, negative x  (fuzz)
///  (13)  atanh: revert for |x| >= 1  (fuzz)
///  (14)  acosh(1) = 0, atanh(0) = 0  (boundary exact)
///  (15)  All outputs normalised  (fuzz)
///  (16)  Monotonicity of cosh for x >= 0  (fuzz)
///  (17)  Monotonicity of sinh  (fuzz)
///  (18)  sinh(a+b) ~= sinh(a)cosh(b) + cosh(a)sinh(b)  (addition formula, concrete)
///  (19)  cosh(a+b) ~= cosh(a)cosh(b) + sinh(a)sinh(b)  (addition formula, concrete)
contract PhaseJRedTeam25Test is Test {

    uint128 constant S = uint128(Decimal.MANTISSA_SCALE);

    Hyp25Harness h = new Hyp25Harness();

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

    // ── (1) Identity values at zero ───────────────────────────────────────────

    function test_identities_at_zero() public pure {
        assertTrue(Decimal.eq(Decimal.cosh(Decimal.zero()),  Decimal.one()),  "cosh(0)==1");
        assertTrue(Decimal.eq(Decimal.sinh(Decimal.zero()),  Decimal.zero()), "sinh(0)==0");
        assertTrue(Decimal.eq(Decimal.tanh(Decimal.zero()),  Decimal.zero()), "tanh(0)==0");
        assertTrue(Decimal.eq(Decimal.asinh(Decimal.zero()), Decimal.zero()), "asinh(0)==0");
        assertTrue(Decimal.eq(Decimal.atanh(Decimal.zero()), Decimal.zero()), "atanh(0)==0");
    }

    // ── (2) cosh is even ──────────────────────────────────────────────────────

    function testFuzz_cosh_even(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory x    = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory negX = Decimal.D({mantissa: m, exponent: 0, negative: true});
        assertLe(_relErr(Decimal.cosh(x), Decimal.cosh(negX)), 2e9, "cosh(-x)~=cosh(x)");
    }

    // ── (3) sinh is odd ───────────────────────────────────────────────────────

    function testFuzz_sinh_odd(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory x    = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory negX = Decimal.D({mantissa: m, exponent: 0, negative: true});
        Decimal.D memory sp   = Decimal.sinh(x);
        Decimal.D memory sn   = Decimal.sinh(negX);
        Decimal.D memory spAbs = Decimal.D({mantissa: sp.mantissa, exponent: sp.exponent, negative: false});
        Decimal.D memory snAbs = Decimal.D({mantissa: sn.mantissa, exponent: sn.exponent, negative: false});
        assertLe(_relErr(spAbs, snAbs), 2e9, "sinh odd: magnitudes match");
        if (sp.mantissa != 0) {
            assertFalse(sp.negative, "sinh(pos) positive");
            assertTrue(sn.negative,  "sinh(neg) negative");
        }
    }

    // ── (4) tanh is odd ───────────────────────────────────────────────────────

    function testFuzz_tanh_odd(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory x    = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory negX = Decimal.D({mantissa: m, exponent: 0, negative: true});
        Decimal.D memory tp   = Decimal.tanh(x);
        Decimal.D memory tn   = Decimal.tanh(negX);
        Decimal.D memory tpAbs = Decimal.D({mantissa: tp.mantissa, exponent: tp.exponent, negative: false});
        Decimal.D memory tnAbs = Decimal.D({mantissa: tn.mantissa, exponent: tn.exponent, negative: false});
        assertLe(_relErr(tpAbs, tnAbs), 2e9, "tanh odd: magnitudes match");
        if (tp.mantissa != 0) {
            assertFalse(tp.negative, "tanh(pos) positive");
            assertTrue(tn.negative,  "tanh(neg) negative");
        }
    }

    // ── (5) Pythagorean identity: cosh^2 - sinh^2 = 1 ────────────────────────

    function testFuzz_pythagorean(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory x  = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory c2 = Decimal.sqr(Decimal.cosh(x));
        Decimal.D memory s2 = Decimal.sqr(Decimal.sinh(x));
        Decimal.D memory diff = Decimal.sub(c2, s2);
        assertLe(_relErr(diff, Decimal.one()), 3e9, "cosh^2 - sinh^2 ~= 1");
    }

    // ── (6) tanh = sinh/cosh ──────────────────────────────────────────────────

    function testFuzz_tanh_consistency(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory x    = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory lhs  = Decimal.tanh(x);
        Decimal.D memory rhs  = Decimal.div(Decimal.sinh(x), Decimal.cosh(x));
        assertLe(_relErr(lhs, rhs), 3e9, "tanh ~= sinh/cosh");
    }

    // ── (7) cosh >= 1 always ─────────────────────────────────────────────────

    function testFuzz_cosh_gteOne(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory x = Decimal.D({mantissa: m, exponent: int64(expRaw) % 5, negative: false});
        assertTrue(Decimal.gte(Decimal.cosh(x), Decimal.one()), "cosh >= 1");
    }

    // ── (8) |tanh| < 1 always ────────────────────────────────────────────────

    function testFuzz_tanh_ltOne(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory x = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory r = Decimal.tanh(x);
        Decimal.D memory rAbs = Decimal.D({mantissa: r.mantissa, exponent: r.exponent, negative: false});
        assertTrue(Decimal.lt(rAbs, Decimal.one()), "|tanh| < 1");
    }

    // ── (9) sinh(asinh(x)) ~= x ───────────────────────────────────────────────

    function testFuzz_sinh_asinh_roundTrip(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        Decimal.D memory x  = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory rt = Decimal.sinh(Decimal.asinh(x));
        assertLe(_relErr(rt, x), 3e9, "sinh(asinh(x)) ~= x");
    }

    // ── (10) cosh(acosh(x)) ~= x  (x >= 1) ───────────────────────────────────
    // Cap exponent at 0 (x in [2,10)) — error amplification = sqrt(x²-1)*acosh(x)/x*ε
    // grows with x; for x<10 max error ~12e-9, so tolerance 1.5e10.

    function testFuzz_cosh_acosh_roundTrip(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        Decimal.D memory x  = Decimal.D({mantissa: m, exponent: 0, negative: false});
        Decimal.D memory rt = Decimal.cosh(Decimal.acosh(x));
        assertLe(_relErr(rt, x), 15e9, "cosh(acosh(x)) ~= x");
    }

    // ── (11) tanh(atanh(x)) ~= x  (|x| < 1) ─────────────────────────────────

    function testFuzz_tanh_atanh_roundTrip(uint64 mantRaw) public pure {
        // x in (0,1): exponent = -1, mantissa in [2*S, 10*S) gives x in [0.2, 1)
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S;
        Decimal.D memory x  = Decimal.D({mantissa: m, exponent: -1, negative: false});
        Decimal.D memory rt = Decimal.tanh(Decimal.atanh(x));
        assertLe(_relErr(rt, x), 4e9, "tanh(atanh(x)) ~= x");
    }

    // ── (12) acosh domain errors ──────────────────────────────────────────────

    function testFuzz_acosh_revert_ltOne(uint64 mantRaw, uint8 expRaw) public {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = -(int64(uint64(expRaw) % 50) + 1); // e < 0 → |value| < 1
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.acosh(Decimal.D({mantissa: m, exponent: e, negative: false}));
    }

    function testFuzz_acosh_revert_negative(uint64 mantRaw) public {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.acosh(Decimal.D({mantissa: m, exponent: 0, negative: true}));
    }

    // ── (13) atanh domain errors ──────────────────────────────────────────────

    function testFuzz_atanh_revert_gteOne(uint64 mantRaw, uint8 expAdd) public {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = int64(uint64(expAdd) % 10); // e >= 0 → |value| >= 1
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.atanh(Decimal.D({mantissa: m, exponent: e, negative: false}));
    }

    // ── (14) Boundary exact values ────────────────────────────────────────────

    function test_acosh_one_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.acosh(Decimal.one()), Decimal.zero()), "acosh(1)==0");
    }

    function test_atanh_zero_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.atanh(Decimal.zero()), Decimal.zero()), "atanh(0)==0");
    }

    // ── (15) All outputs normalised ───────────────────────────────────────────

    function testFuzz_outputs_normalised(uint64 mantRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory x = Decimal.D({mantissa: m, exponent: 0, negative: false});
        _assertNorm(Decimal.cosh(x),  "cosh");
        _assertNorm(Decimal.sinh(x),  "sinh");
        _assertNorm(Decimal.tanh(x),  "tanh");
        _assertNorm(Decimal.asinh(x), "asinh");
        // acosh: x must be >= 1, m >= S and e=0 satisfies this
        _assertNorm(Decimal.acosh(x), "acosh");
        // atanh: x must be < 1; use e=-1
        Decimal.D memory xSmall = Decimal.D({mantissa: m, exponent: -1, negative: false});
        _assertNorm(Decimal.atanh(xSmall), "atanh");
    }

    // ── (16) Monotonicity of cosh (x >= 0) ───────────────────────────────────

    function testFuzz_cosh_monotone_pos(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        if (!Decimal.lt(a, b)) return;
        // Skip inputs too close to distinguish after exp (~1e-9 precision): require >2e-9 relative gap.
        if (_relErr(a, b) <= 2e9) return;
        assertTrue(
            Decimal.lte(Decimal.cosh(a), Decimal.cosh(b)),
            "cosh monotone for x>=0"
        );
    }

    // ── (17) Monotonicity of sinh ─────────────────────────────────────────────

    function testFuzz_sinh_monotone(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        if (!Decimal.lt(a, b)) return;
        assertTrue(Decimal.lte(Decimal.sinh(a), Decimal.sinh(b)), "sinh monotone");
    }

    // ── (18) sinh addition formula ────────────────────────────────────────────

    function test_sinh_addition() public pure {
        // sinh(a+b) = sinh(a)*cosh(b) + cosh(a)*sinh(b)
        Decimal.D memory a = Decimal.D({mantissa: S, exponent: 0, negative: false});       // 1
        Decimal.D memory b = Decimal.D({mantissa: 5 * S / 10, exponent: 0, negative: false}); // 0.5... wait, 5*S/10 = 5e17 < S
        // Use a=1, b mantissa = 15*S/10 = 1.5
        b = Decimal.D({mantissa: 15 * S / 10, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.sinh(Decimal.add(a, b));
        Decimal.D memory rhs = Decimal.add(
            Decimal.mul(Decimal.sinh(a), Decimal.cosh(b)),
            Decimal.mul(Decimal.cosh(a), Decimal.sinh(b))
        );
        assertLe(_relErr(lhs, rhs), 3e9, "sinh(a+b) addition formula");
    }

    // ── (19) cosh addition formula ────────────────────────────────────────────

    function test_cosh_addition() public pure {
        // cosh(a+b) = cosh(a)*cosh(b) + sinh(a)*sinh(b)
        Decimal.D memory a = Decimal.D({mantissa: S, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: 15 * S / 10, exponent: 0, negative: false});
        Decimal.D memory lhs = Decimal.cosh(Decimal.add(a, b));
        Decimal.D memory rhs = Decimal.add(
            Decimal.mul(Decimal.cosh(a), Decimal.cosh(b)),
            Decimal.mul(Decimal.sinh(a), Decimal.sinh(b))
        );
        assertLe(_relErr(lhs, rhs), 3e9, "cosh(a+b) addition formula");
    }
}
