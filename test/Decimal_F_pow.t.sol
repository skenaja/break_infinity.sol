// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Tests for Phase F-15 - pow.
contract DecimalFPowTest is Test {
    uint128 constant S = uint128(Decimal.MANTISSA_SCALE); // 1e18

    // ── helpers ──────────────────────────────────────────────────────────────

    function _assertNorm(Decimal.D memory d, string memory lbl) internal pure {
        if (d.mantissa == 0) {
            assertEq(d.exponent, 0, string.concat(lbl, ": zero.exp"));
            assertFalse(d.negative, string.concat(lbl, ": zero.neg"));
        } else {
            assertGe(d.mantissa, S,      string.concat(lbl, ": mantissa >= SCALE"));
            assertLt(d.mantissa, 10 * S, string.concat(lbl, ": mantissa < MAX"));
        }
    }

    // Relative error |(a-b)/a| * 1e18.  Returns max uint256 when exponents differ by > 1.
    function _relErr(Decimal.D memory expected, Decimal.D memory got)
        internal pure returns (uint256)
    {
        int64 ed = expected.exponent - got.exponent;
        uint256 em = uint256(expected.mantissa);
        uint256 gm = uint256(got.mantissa);
        uint256 diff;
        if      (ed ==  0) { diff = em > gm ? em - gm : gm - em; }
        else if (ed ==  1) { em *= 10; diff = em > gm ? em - gm : gm - em; }
        else if (ed == -1) { gm *= 10; diff = em > gm ? em - gm : gm - em; }
        else               { return type(uint256).max; }
        return diff * 1e18 / em;
    }

    // ── base = 0, exponent = 0 ────────────────────────────────────────────────

    function test_pow_zeroBase_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.pow(Decimal.zero(), Decimal.fromUint(3)), Decimal.zero()));
    }

    function test_pow_anyBase_zeroExp_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.pow(Decimal.fromUint(42), Decimal.zero()), Decimal.one()));
    }

    function test_pow_one_zeroExp_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.pow(Decimal.one(), Decimal.zero()), Decimal.one()));
    }

    // ── exp = 1 ───────────────────────────────────────────────────────────────

    // pow(base, 1) passes through log10/exp10 so result is within 1e-9, not exact.
    function test_pow_exp1_approxBase() public pure {
        Decimal.D memory base = Decimal.fromUint(7);
        Decimal.D memory r    = Decimal.pow(base, Decimal.one());
        _assertNorm(r, "7^1");
        assertLe(_relErr(base, r), 2e9, "7^1 ~= 7 within 2e-9 (two-op chain)");
    }

    // ── base = 1 ──────────────────────────────────────────────────────────────

    function test_pow_base1_anyExp_isOne() public pure {
        assertTrue(Decimal.eq(Decimal.pow(Decimal.one(), Decimal.fromUint(1000)), Decimal.one()));
    }

    // ── powers of 10 - exact ─────────────────────────────────────────────────

    function test_pow_10_to2_is100() public pure {
        Decimal.D memory r = Decimal.pow(Decimal.pow10(1), Decimal.fromUint(2));
        _assertNorm(r, "10^2");
        assertTrue(Decimal.eq(r, Decimal.fromUint(100)), "10^2 == 100");
    }

    function test_pow_10_to3_is1000() public pure {
        Decimal.D memory r = Decimal.pow(Decimal.pow10(1), Decimal.fromUint(3));
        assertTrue(Decimal.eq(r, Decimal.fromUint(1000)), "10^3 == 1000");
    }

    function test_pow_pow10_100_sq_is_pow10_200() public pure {
        // (10^100)^2 == 10^200
        Decimal.D memory r = Decimal.pow(Decimal.pow10(100), Decimal.fromUint(2));
        _assertNorm(r, "(10^100)^2");
        assertTrue(Decimal.eq(r, Decimal.pow10(200)), "(10^100)^2 == 10^200");
    }

    function test_pow_pow10_neg50_sq_is_pow10_neg100() public pure {
        // (10^-50)^2 == 10^-100
        Decimal.D memory r = Decimal.pow(Decimal.pow10(-50), Decimal.fromUint(2));
        _assertNorm(r, "(10^-50)^2");
        assertTrue(Decimal.eq(r, Decimal.pow10(-100)), "(10^-50)^2 == 10^-100");
    }

    // ── square root via pow ───────────────────────────────────────────────────

    function test_pow_sqrt4_is2() public pure {
        // 4^0.5 == 2.  Represent 0.5 as D{5e18, -1, false}.
        Decimal.D memory half = Decimal.D({mantissa: 5 * S, exponent: -1, negative: false});
        Decimal.D memory r    = Decimal.pow(Decimal.fromUint(4), half);
        _assertNorm(r, "4^0.5");
        // Allow 1e-9 relative error
        assertLe(_relErr(Decimal.fromUint(2), r), 1e9, "4^0.5 within 1e-9");
    }

    function test_pow_sqrt100_is10() public pure {
        Decimal.D memory half = Decimal.D({mantissa: 5 * S, exponent: -1, negative: false});
        Decimal.D memory r    = Decimal.pow(Decimal.fromUint(100), half);
        _assertNorm(r, "100^0.5");
        assertLe(_relErr(Decimal.fromUint(10), r), 1e9, "100^0.5 == 10 within 1e-9");
    }

    // ── cube root via pow ─────────────────────────────────────────────────────

    function test_pow_cbrt8_is2() public pure {
        // 8^(1/3): represent 1/3 ~= 3_333_333_333_333_333_333e-19 - use D{3333..., -1}
        // 1/3 ~= D{mantissa: 3_333_333_333_333_333_333, exponent: -1}  (value ~= 0.3333...)
        Decimal.D memory third = Decimal.D({
            mantissa: 3_333_333_333_333_333_333,
            exponent: -1,
            negative: false
        });
        Decimal.D memory r = Decimal.pow(Decimal.fromUint(8), third);
        _assertNorm(r, "8^(1/3)");
        assertLe(_relErr(Decimal.fromUint(2), r), 1e9, "8^(1/3) ~= 2 within 1e-9");
    }

    // ── log-exp round-trip ────────────────────────────────────────────────────

    function test_pow_log10_roundTrip() public pure {
        // pow(10, log10(x)) ~= x
        // Use x = 7, log10(7) ~= 0.845
        // Computed externally: log10(7) * 1e18 ~= 845_098_040_014_256_826
        Decimal.D memory log10_7 = Decimal.D({
            mantissa: 8_450_980_400_142_568_260,
            exponent: -1,
            negative: false
        });
        Decimal.D memory r = Decimal.pow(Decimal.pow10(1), log10_7);
        _assertNorm(r, "10^log10(7)");
        assertLe(_relErr(Decimal.fromUint(7), r), 2e9, "10^log10(7) ~= 7 within 2e-9");
    }

    // ── negative base ─────────────────────────────────────────────────────────

    function test_pow_negBase_evenInt_isPositive() public pure {
        // (-2)^2 = 4 (positive)
        Decimal.D memory neg2 = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        Decimal.D memory r    = Decimal.pow(neg2, Decimal.fromUint(2));
        assertFalse(r.negative, "(-2)^2 is positive");
        assertLe(_relErr(Decimal.fromUint(4), r), 1e9, "(-2)^2 ~= 4");
    }

    function test_pow_negBase_oddInt_isNegative() public pure {
        // (-2)^3 = -8 (negative)
        Decimal.D memory neg2 = Decimal.D({mantissa: 2 * S, exponent: 0, negative: true});
        Decimal.D memory r    = Decimal.pow(neg2, Decimal.fromUint(3));
        assertTrue(r.negative, "(-2)^3 is negative");
        assertLe(_relErr(Decimal.fromUint(8), Decimal.abs(r)), 1e9, "(-2)^3 ~= -8");
    }

    // ── output is normalised ──────────────────────────────────────────────────

    function testFuzz_pow_normalised(uint64 mantissaRaw, int8 expRaw, uint8 expUint) public pure {
        uint128 m  = uint128(mantissaRaw % (9 * uint64(Decimal.MANTISSA_SCALE)))
                     + uint128(Decimal.MANTISSA_SCALE);
        int64   e  = int64(expRaw) * 10;
        uint256 n  = uint256(expUint) % 5 + 1; // exponent in [1,5]
        Decimal.D memory base = Decimal.normalize(Decimal.D({mantissa: m, exponent: e, negative: false}));
        if (base.mantissa == 0) return;

        Decimal.D memory r = Decimal.pow(base, Decimal.fromUint(n));
        _assertNorm(r, "fuzz pow");
    }
}
