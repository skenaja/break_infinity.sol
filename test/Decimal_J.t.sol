// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {IDecimalErrors} from "../src/interfaces/IDecimalErrors.sol";

/// @dev Harness for vm.expectRevert on internal library reverts.
contract HyperbolicJHarness {
    function acosh(Decimal.D calldata a) external pure returns (Decimal.D memory) { return Decimal.acosh(a); }
    function atanh(Decimal.D calldata a) external pure returns (Decimal.D memory) { return Decimal.atanh(a); }
}

/// @notice Correctness tests for Phase J: sinh, cosh, tanh, asinh, acosh, atanh.
contract DecimalJTest is Test {

    uint128 constant S = uint128(Decimal.MANTISSA_SCALE);

    HyperbolicJHarness h = new HyperbolicJHarness();

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

    // ── cosh ─────────────────────────────────────────────────────────────────

    function test_cosh_zero_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.cosh(Decimal.zero()), Decimal.one()), "cosh(0)==1");
    }

    function test_cosh_one() public pure {
        // cosh(1) = 1.5430806348152437...
        Decimal.D memory r        = Decimal.cosh(Decimal.one());
        Decimal.D memory expected = Decimal.D({mantissa: 1_543_080_634_815_243_778, exponent: 0, negative: false});
        assertLe(_relErr(r, expected), 3e9, "cosh(1) within 3e-9");
    }

    function test_cosh_even() public pure {
        // cosh(-x) == cosh(x)
        Decimal.D memory pos = Decimal.D({mantissa: 15 * S / 10, exponent: 0, negative: false});
        Decimal.D memory neg = Decimal.D({mantissa: 15 * S / 10, exponent: 0, negative: true});
        assertTrue(Decimal.eq(Decimal.cosh(pos), Decimal.cosh(neg)), "cosh(-x)==cosh(x)");
    }

    function test_cosh_alwaysGteOne() public pure {
        // cosh(2) >= 1
        Decimal.D memory r = Decimal.cosh(Decimal.D({mantissa: 2 * S, exponent: 0, negative: false}));
        assertTrue(Decimal.gte(r, Decimal.one()), "cosh(x)>=1");
    }

    // ── sinh ─────────────────────────────────────────────────────────────────

    function test_sinh_zero_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.sinh(Decimal.zero()), Decimal.zero()), "sinh(0)==0");
    }

    function test_sinh_one() public pure {
        // sinh(1) = 1.1752011936438014...
        Decimal.D memory r        = Decimal.sinh(Decimal.one());
        Decimal.D memory expected = Decimal.D({mantissa: 1_175_201_193_643_801_457, exponent: 0, negative: false});
        assertLe(_relErr(r, expected), 3e9, "sinh(1) within 3e-9");
    }

    function test_sinh_odd() public pure {
        // sinh(-x) == -sinh(x)
        Decimal.D memory x    = Decimal.D({mantissa: 15 * S / 10, exponent: 0, negative: false});
        Decimal.D memory negX = Decimal.D({mantissa: 15 * S / 10, exponent: 0, negative: true});
        Decimal.D memory sp   = Decimal.sinh(x);
        Decimal.D memory sn   = Decimal.sinh(negX);
        assertEq(sp.mantissa, sn.mantissa, "sinh(-x) same magnitude");
        assertEq(sp.exponent, sn.exponent, "sinh(-x) same exponent");
        if (sp.mantissa != 0) {
            assertFalse(sp.negative, "sinh(x>0) positive");
            assertTrue(sn.negative,  "sinh(x<0) negative");
        }
    }

    // ── tanh ─────────────────────────────────────────────────────────────────

    function test_tanh_zero_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.tanh(Decimal.zero()), Decimal.zero()), "tanh(0)==0");
    }

    function test_tanh_one() public pure {
        // tanh(1) = 0.7615941559557649...
        Decimal.D memory r        = Decimal.tanh(Decimal.one());
        Decimal.D memory expected = Decimal.D({mantissa: 7_615_941_559_557_648_882, exponent: -1, negative: false});
        assertLe(_relErr(r, expected), 3e9, "tanh(1) within 3e-9");
    }

    function test_tanh_odd() public pure {
        Decimal.D memory x    = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory negX = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        Decimal.D memory tp   = Decimal.tanh(x);
        Decimal.D memory tn   = Decimal.tanh(negX);
        // Magnitudes should match within 1e-9 (different exp paths accumulate different rounding).
        Decimal.D memory tpAbs = Decimal.D({mantissa: tp.mantissa, exponent: tp.exponent, negative: false});
        Decimal.D memory tnAbs = Decimal.D({mantissa: tn.mantissa, exponent: tn.exponent, negative: false});
        assertLe(_relErr(tpAbs, tnAbs), 2e9, "tanh odd: |tanh(x)| ~= |tanh(-x)|");
        if (tp.mantissa != 0) {
            assertFalse(tp.negative, "tanh(x>0) positive");
            assertTrue(tn.negative,  "tanh(x<0) negative");
        }
    }

    function test_tanh_boundedByOne() public pure {
        // |tanh(x)| < 1 for any x
        Decimal.D memory r = Decimal.tanh(Decimal.D({mantissa: 5 * S, exponent: 0, negative: false}));
        assertTrue(Decimal.lt(r, Decimal.one()), "|tanh(x)| < 1");
    }

    // ── Pythagorean identity: cosh^2 - sinh^2 = 1 ────────────────────────────

    function test_pythagorean_identity() public pure {
        Decimal.D memory x  = Decimal.D({mantissa: 15 * S / 10, exponent: 0, negative: false});
        Decimal.D memory c2 = Decimal.sqr(Decimal.cosh(x));
        Decimal.D memory s2 = Decimal.sqr(Decimal.sinh(x));
        Decimal.D memory diff = Decimal.sub(c2, s2);
        assertLe(_relErr(diff, Decimal.one()), 3e9, "cosh^2 - sinh^2 ~= 1");
    }

    // ── asinh ────────────────────────────────────────────────────────────────

    function test_asinh_zero_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.asinh(Decimal.zero()), Decimal.zero()), "asinh(0)==0");
    }

    function test_asinh_one() public pure {
        // asinh(1) = ln(1 + sqrt(2)) = 0.8813735870195430...
        Decimal.D memory r        = Decimal.asinh(Decimal.one());
        Decimal.D memory expected = Decimal.D({mantissa: 8_813_735_870_195_430_252, exponent: -1, negative: false});
        assertLe(_relErr(r, expected), 3e9, "asinh(1) within 3e-9");
    }

    function test_asinh_roundTrip() public pure {
        Decimal.D memory x  = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory rt = Decimal.sinh(Decimal.asinh(x));
        assertLe(_relErr(rt, x), 3e9, "sinh(asinh(x)) ~= x");
    }

    // ── acosh ────────────────────────────────────────────────────────────────

    function test_acosh_one_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.acosh(Decimal.one()), Decimal.zero()), "acosh(1)==0");
    }

    function test_acosh_two() public pure {
        // acosh(2) = ln(2 + sqrt(3)) = 1.3169578969248168...
        Decimal.D memory two      = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory r        = Decimal.acosh(two);
        Decimal.D memory expected = Decimal.D({mantissa: 1_316_957_896_924_816_708, exponent: 0, negative: false});
        assertLe(_relErr(r, expected), 3e9, "acosh(2) within 3e-9");
    }

    function test_acosh_ltOne_reverts() public {
        Decimal.D memory half = Decimal.D({mantissa: 5 * S, exponent: -1, negative: false});
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.acosh(half);
    }

    function test_acosh_negative_reverts() public {
        Decimal.D memory neg = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.acosh(neg);
    }

    function test_acosh_roundTrip() public pure {
        Decimal.D memory x  = Decimal.D({mantissa: 3 * S, exponent: 0, negative: false});
        Decimal.D memory rt = Decimal.cosh(Decimal.acosh(x));
        assertLe(_relErr(rt, x), 3e9, "cosh(acosh(x)) ~= x");
    }

    // ── atanh ────────────────────────────────────────────────────────────────

    function test_atanh_zero_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.atanh(Decimal.zero()), Decimal.zero()), "atanh(0)==0");
    }

    function test_atanh_half() public pure {
        // atanh(0.5) = 0.5493061443340548...
        Decimal.D memory half     = Decimal.D({mantissa: 5 * S, exponent: -1, negative: false});
        Decimal.D memory r        = Decimal.atanh(half);
        Decimal.D memory expected = Decimal.D({mantissa: 5_493_061_443_340_548_457, exponent: -1, negative: false});
        assertLe(_relErr(r, expected), 3e9, "atanh(0.5) within 3e-9");
    }

    function test_atanh_geOne_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.atanh(Decimal.one());
    }

    function test_atanh_gtOne_reverts() public {
        Decimal.D memory two = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        vm.expectRevert(IDecimalErrors.Decimal__InvalidInput.selector);
        h.atanh(two);
    }

    function test_atanh_roundTrip() public pure {
        Decimal.D memory x  = Decimal.D({mantissa: 3 * S, exponent: -1, negative: false}); // 0.3
        Decimal.D memory rt = Decimal.tanh(Decimal.atanh(x));
        assertLe(_relErr(rt, x), 3e9, "tanh(atanh(x)) ~= x");
    }
}
