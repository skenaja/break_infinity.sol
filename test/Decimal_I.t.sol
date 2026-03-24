// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Correctness tests for Phase I: exp.
contract DecimalITest is Test {

    uint128 constant S = uint128(Decimal.MANTISSA_SCALE);

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

    // ── known values ──────────────────────────────────────────────────────────

    function test_exp_zero_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.exp(Decimal.zero()), Decimal.one()), "exp(0)==1");
    }

    function test_exp_one_isE() public view {
        Decimal.D memory r = Decimal.exp(Decimal.one());
        assertLe(_relErr(r, E_VAL), 2e9, "exp(1) ~= e within 2e-9");
    }

    function test_exp_negOne_isRecipE() public pure {
        // e^-1 = 1/e = 0.36787944117144233...
        // mantissa = 3_678_794_411_714_423_216, exponent = -1
        Decimal.D memory r        = Decimal.exp(Decimal.D({mantissa: S, exponent: 0, negative: true}));
        Decimal.D memory expected = Decimal.D({mantissa: 3_678_794_411_714_423_216, exponent: -1, negative: false});
        assertLe(_relErr(r, expected), 2e9, "exp(-1) ~= 1/e within 2e-9");
    }

    function test_exp_two() public pure {
        // e^2 = 7.38905609893065023...
        Decimal.D memory r        = Decimal.exp(Decimal.D({mantissa: 2 * S, exponent: 0, negative: false}));
        Decimal.D memory expected = Decimal.D({mantissa: 7_389_056_098_930_650_227, exponent: 0, negative: false});
        assertLe(_relErr(r, expected), 2e9, "exp(2) ~= e^2 within 2e-9");
    }

    // ── round-trips ───────────────────────────────────────────────────────────

    function test_exp_ln_roundTrip() public pure {
        // exp(ln(10)) ~= 10
        Decimal.D memory ten  = Decimal.D({mantissa: S, exponent: 1, negative: false});
        Decimal.D memory lnTen = Decimal.ln(ten);
        Decimal.D memory rt   = Decimal.exp(lnTen);
        assertLe(_relErr(rt, ten), 3e9, "exp(ln(10)) ~= 10");
    }

    function test_ln_exp_roundTrip() public pure {
        // ln(exp(2)) ~= 2
        Decimal.D memory two  = Decimal.D({mantissa: 2 * S, exponent: 0, negative: false});
        Decimal.D memory r    = Decimal.ln(Decimal.exp(two));
        assertLe(_relErr(r, two), 3e9, "ln(exp(2)) ~= 2");
    }

    // ── additive property ─────────────────────────────────────────────────────

    function test_exp_additive() public pure {
        // exp(1) * exp(1) ~= exp(2)
        Decimal.D memory e1  = Decimal.exp(Decimal.one());
        Decimal.D memory e2  = Decimal.exp(Decimal.D({mantissa: 2 * S, exponent: 0, negative: false}));
        Decimal.D memory lhs = Decimal.mul(e1, e1);
        assertLe(_relErr(lhs, e2), 3e9, "exp(1)*exp(1) ~= exp(2)");
    }

    // ── sign invariant ────────────────────────────────────────────────────────

    function test_exp_alwaysPositive() public pure {
        // exp of a large negative should still be positive
        Decimal.D memory negTen = Decimal.D({mantissa: S, exponent: 1, negative: true});
        Decimal.D memory r = Decimal.exp(negTen);
        assertFalse(r.negative, "exp(-10) is positive");
        assertTrue(r.mantissa > 0, "exp(-10) is nonzero");
    }

    // ── monotonicity ──────────────────────────────────────────────────────────

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

    // ── normalised output ─────────────────────────────────────────────────────

    function testFuzz_exp_normalised(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        // Keep exponent small to avoid overflow
        int64 e = int64(expRaw) % 10;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        _assertNorm(Decimal.exp(a), "exp normalised");
    }
}
