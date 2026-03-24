// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Tests for Phase F-17 — cbrt.
contract DecimalFCbrtTest is Test {

    uint128 constant S = uint128(Decimal.MANTISSA_SCALE); // 1e18

    function _assertNorm(Decimal.D memory d, string memory lbl) internal pure {
        if (d.mantissa == 0) {
            assertEq(d.exponent, 0, string.concat(lbl, ": zero.exp"));
            assertFalse(d.negative, string.concat(lbl, ": zero.neg"));
        } else {
            assertGe(d.mantissa, S,      string.concat(lbl, ": mantissa >= SCALE"));
            assertLt(d.mantissa, 10 * S, string.concat(lbl, ": mantissa < MAX"));
        }
    }

    // ── zero ─────────────────────────────────────────────────────────────────

    function test_cbrt_zero_isZero() public pure {
        assertTrue(Decimal.eq(Decimal.cbrt(Decimal.zero()), Decimal.zero()));
    }

    // ── perfect cubes (exact) ────────────────────────────────────────────────

    function test_cbrt_one() public pure {
        Decimal.D memory r = Decimal.cbrt(Decimal.one());
        _assertNorm(r, "cbrt(1)");
        assertTrue(Decimal.eq(r, Decimal.one()), "cbrt(1)==1");
    }

    function test_cbrt_eight() public pure {
        // 8 = fromUint(8): mantissa = 8e18, exp = 0, mod = 0
        Decimal.D memory r = Decimal.cbrt(Decimal.fromUint(8));
        _assertNorm(r, "cbrt(8)");
        assertTrue(Decimal.eq(r, Decimal.fromUint(2)), "cbrt(8)==2");
    }

    function test_cbrt_27() public pure {
        Decimal.D memory r = Decimal.cbrt(Decimal.fromUint(27));
        _assertNorm(r, "cbrt(27)");
        assertTrue(Decimal.eq(r, Decimal.fromUint(3)), "cbrt(27)==3");
    }

    function test_cbrt_1000() public pure {
        // 1000 = 1e3 → exp 3, mod 0
        Decimal.D memory r = Decimal.cbrt(Decimal.fromUint(1000));
        _assertNorm(r, "cbrt(1000)");
        assertTrue(Decimal.eq(r, Decimal.fromUint(10)), "cbrt(1000)==10");
    }

    // ── powers of 10 — exponent divisible by 3 ───────────────────────────────

    function test_cbrt_pow10_mod0() public pure {
        // cbrt(10^3) == 10^1
        assertTrue(Decimal.eq(Decimal.cbrt(Decimal.pow10(3)), Decimal.pow10(1)), "cbrt(10^3)==10");
    }

    function test_cbrt_pow10_mod0_large() public pure {
        // cbrt(10^300) == 10^100
        assertTrue(Decimal.eq(Decimal.cbrt(Decimal.pow10(300)), Decimal.pow10(100)), "cbrt(10^300)==10^100");
    }

    function test_cbrt_pow10_negMod0() public pure {
        // cbrt(10^-3) == 10^-1
        assertTrue(Decimal.eq(Decimal.cbrt(Decimal.pow10(-3)), Decimal.pow10(-1)), "cbrt(10^-3)==10^-1");
    }

    // ── powers of 10 — mod 1 ────────────────────────────────────────────────

    function test_cbrt_pow10_mod1() public pure {
        // cbrt(10^1) = 10^(1/3) ≈ 2.154e18 mantissa, exp 0
        Decimal.D memory r = Decimal.cbrt(Decimal.pow10(1));
        _assertNorm(r, "cbrt(10^1)");
        assertEq(r.exponent, 0, "cbrt(10^1) exp");
        // 10^(1/3) * 1e18 = floor(cbrt(1e55)) = 2_154_434_690_031_883_721
        uint256 expected = 2_154_434_690_031_883_721;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2, "cbrt(10^1) mantissa within 2 ULP");
    }

    function test_cbrt_pow10_mod1_negative() public pure {
        // cbrt(10^-2): exp -2, mod -2 → same k=1 branch as mod 1
        // cbrt(10^-2) = 10^(-2/3), exp should be -1, mantissa ≈ 1/cbrt(10)*1e18
        // = 10^(-1/3) * 1e18 ≈ 4.642e17... wait
        // 10^(-2/3) = 10^(-1) * 10^(1/3) ≈ 0.2154, exp -1, mantissa ≈ 2.154e18
        Decimal.D memory r = Decimal.cbrt(Decimal.pow10(-2));
        _assertNorm(r, "cbrt(10^-2)");
        assertEq(r.exponent, -1, "cbrt(10^-2) exp");
        uint256 expected = 2_154_434_690_031_883_721;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2, "cbrt(10^-2) mantissa within 2 ULP");
    }

    // ── powers of 10 — mod 2 ────────────────────────────────────────────────

    function test_cbrt_pow10_mod2() public pure {
        // cbrt(10^2) = 10^(2/3) ≈ 4.642e18 mantissa, exp 0
        Decimal.D memory r = Decimal.cbrt(Decimal.pow10(2));
        _assertNorm(r, "cbrt(10^2)");
        assertEq(r.exponent, 0, "cbrt(10^2) exp");
        // 10^(2/3) * 1e18 ≈ 4_641_588_833_612_778_892
        uint256 expected = 4_641_588_833_612_778_892;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2, "cbrt(10^2) mantissa within 2 ULP");
    }

    function test_cbrt_pow10_negMod2() public pure {
        // cbrt(10^-1): exp -1, mod -1 → k=2 branch
        // cbrt(10^-1) = 10^(-1/3), exp should be -1, mantissa ≈ 10^(2/3)*1e18
        // = 10^(-1/3) * 1e18; but exponent -1 means value = mantissa/1e18 * 10^-1
        // value = 10^(-1/3) = mantissa * 10^-1 → mantissa = 10^(2/3) ≈ 4.642e18
        Decimal.D memory r = Decimal.cbrt(Decimal.pow10(-1));
        _assertNorm(r, "cbrt(10^-1)");
        assertEq(r.exponent, -1, "cbrt(10^-1) exp");
        uint256 expected = 4_641_588_833_612_778_892;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2, "cbrt(10^-1) mantissa within 2 ULP");
    }

    // ── negative inputs ───────────────────────────────────────────────────────

    function test_cbrt_negativeEight_isNegTwo() public pure {
        Decimal.D memory r = Decimal.cbrt(Decimal.fromInt(-8));
        _assertNorm(r, "cbrt(-8)");
        assertTrue(Decimal.eq(r, Decimal.fromInt(-2)), "cbrt(-8)==-2");
    }

    function test_cbrt_negative27() public pure {
        Decimal.D memory r = Decimal.cbrt(Decimal.fromInt(-27));
        assertTrue(Decimal.eq(r, Decimal.fromInt(-3)), "cbrt(-27)==-3");
    }

    function test_cbrt_negativeResultIsNegative() public pure {
        Decimal.D memory r = Decimal.cbrt(Decimal.fromInt(-10));
        assertTrue(r.negative, "cbrt(-10) is negative");
    }

    // ── cube(cbrt(a)) round-trip ──────────────────────────────────────────────

    function test_cbrt_roundTrip_8() public pure {
        Decimal.D memory a = Decimal.fromUint(8);
        assertTrue(Decimal.eq(Decimal.cube(Decimal.cbrt(a)), a), "cube(cbrt(8))==8");
    }

    function test_cbrt_roundTrip_pow10_300() public pure {
        Decimal.D memory a = Decimal.pow10(300);
        assertTrue(Decimal.eq(Decimal.cube(Decimal.cbrt(a)), a), "cube(cbrt(10^300))==10^300");
    }

    function test_cbrt_roundTrip_pow10_neg300() public pure {
        Decimal.D memory a = Decimal.pow10(-300);
        assertTrue(Decimal.eq(Decimal.cube(Decimal.cbrt(a)), a), "cube(cbrt(10^-300))==10^-300");
    }

    // ── cbrt(cube(a)) == a for exact cubes ───────────────────────────────────

    function test_cbrt_cube_roundTrip_pow10() public pure {
        for (int64 e = -99; e <= 99; e += 3) {
            Decimal.D memory a = Decimal.pow10(e);
            assertTrue(Decimal.eq(Decimal.cbrt(Decimal.cube(a)), a),
                "cbrt(cube(10^e))==10^e");
        }
    }

    // ── output always normalised ──────────────────────────────────────────────

    function testFuzz_cbrt_normalised(uint64 mantissaRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantissaRaw % (9 * uint64(Decimal.MANTISSA_SCALE)))
                    + uint128(Decimal.MANTISSA_SCALE);
        int64 e = int64(expRaw) * 100;
        Decimal.D memory a = Decimal.normalize(Decimal.D({mantissa: m, exponent: e, negative: false}));
        if (a.mantissa == 0) return;

        Decimal.D memory r = Decimal.cbrt(a);
        _assertNorm(r, "fuzz cbrt");
    }

    function testFuzz_cbrt_negativeInputNegativeOutput(uint64 mantissaRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantissaRaw % (9 * uint64(Decimal.MANTISSA_SCALE)))
                    + uint128(Decimal.MANTISSA_SCALE);
        int64 e = int64(expRaw) * 100;
        Decimal.D memory a = Decimal.normalize(Decimal.D({mantissa: m, exponent: e, negative: true}));
        if (a.mantissa == 0) return;

        Decimal.D memory r = Decimal.cbrt(a);
        assertTrue(r.negative, "cbrt(negative) is negative");
    }
}
