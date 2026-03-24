// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {IDecimalErrors} from "../src/interfaces/IDecimalErrors.sol";

/// @dev Harness so vm.expectRevert can intercept internal library reverts.
contract SqrtHarness {
    function sqrt(Decimal.D memory a) external pure returns (Decimal.D memory) {
        return Decimal.sqrt(a);
    }
}

/// @notice Tests for Phase F-16 — sqrt.
contract DecimalFSqrtTest is Test {
    SqrtHarness h = new SqrtHarness();

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

    // Relative error between two D values, returned as a fraction of 1e18.
    // i.e. returns abs(a - b) / a * 1e18.
    function _relErrFixed(Decimal.D memory expected, Decimal.D memory got)
        internal pure returns (uint256)
    {
        // Convert to a comparable scale: work in exponent-difference space.
        // Both must be positive and non-zero.
        int64 expDiff = expected.exponent - got.exponent;
        // Bring both mantissas to the same exponent.
        uint256 eMant = uint256(expected.mantissa);
        uint256 gMant = uint256(got.mantissa);
        uint256 diff;
        if (expDiff == 0) {
            diff = eMant > gMant ? eMant - gMant : gMant - eMant;
        } else if (expDiff == 1) {
            eMant *= 10;
            diff = eMant > gMant ? eMant - gMant : gMant - eMant;
        } else if (expDiff == -1) {
            gMant *= 10;
            diff = eMant > gMant ? eMant - gMant : gMant - eMant;
        } else {
            // Large difference — caller should just check exponent equality.
            return type(uint256).max;
        }
        return diff * 1e18 / eMant; // relative, scaled by 1e18
    }

    // ── zero ─────────────────────────────────────────────────────────────────

    function test_sqrt_zero_isZero() public pure {
        Decimal.D memory r = Decimal.sqrt(Decimal.zero());
        assertTrue(Decimal.eq(r, Decimal.zero()));
    }

    // ── negative reverts ─────────────────────────────────────────────────────

    function test_sqrt_negative_reverts() public {
        vm.expectRevert(IDecimalErrors.Decimal__NegativeSqrt.selector);
        h.sqrt(Decimal.fromInt(-4));
    }

    // ── output is normalised ──────────────────────────────────────────────────

    function test_sqrt_one_isOne() public pure {
        Decimal.D memory r = Decimal.sqrt(Decimal.one());
        _assertNorm(r, "sqrt(1)");
        assertTrue(Decimal.eq(r, Decimal.one()), "sqrt(1) == 1");
    }

    function test_sqrt_hundredIsEven() public pure {
        // 100 = (1e18 mantissa) * 10^2  → even exponent
        // sqrt(100) = 10
        Decimal.D memory r = Decimal.sqrt(Decimal.fromUint(100));
        _assertNorm(r, "sqrt(100)");
        assertTrue(Decimal.eq(r, Decimal.fromUint(10)), "sqrt(100)==10");
    }

    function test_sqrt_tenIsOdd() public pure {
        // 10 = (1e18 mantissa) * 10^1  → odd exponent
        // sqrt(10) ≈ 3.16227766...
        Decimal.D memory r = Decimal.sqrt(Decimal.fromUint(10));
        _assertNorm(r, "sqrt(10)");
        // Expect exponent 0, mantissa ≈ 3.162e18
        assertEq(r.exponent, 0, "sqrt(10) exponent");
        // mantissa should be ≈ 3_162_277_660_168_379_332 (floor of sqrt(10)*1e18)
        // Allow ±2 ULP relative to 1e18
        uint256 expected = 3_162_277_660_168_379_332;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2, "sqrt(10) mantissa within 2 ULP");
    }

    // ── powers of 10 — round-trip ─────────────────────────────────────────────

    function test_sqrt_pow10_even() public pure {
        // sqrt(10^4) == 10^2
        Decimal.D memory a = Decimal.pow10(4);
        Decimal.D memory r = Decimal.sqrt(a);
        _assertNorm(r, "sqrt(10^4)");
        assertTrue(Decimal.eq(r, Decimal.pow10(2)), "sqrt(10^4)==10^2");
    }

    function test_sqrt_pow10_large_even() public pure {
        // sqrt(10^100) == 10^50
        Decimal.D memory a = Decimal.pow10(100);
        Decimal.D memory r = Decimal.sqrt(a);
        _assertNorm(r, "sqrt(10^100)");
        assertTrue(Decimal.eq(r, Decimal.pow10(50)), "sqrt(10^100)==10^50");
    }

    function test_sqrt_pow10_odd() public pure {
        // sqrt(10^3) == 10^1.5 = 10 * sqrt(10) ≈ 31.6227...
        // Exponent should be 1, mantissa ≈ 3.162e18
        Decimal.D memory a = Decimal.pow10(3);
        Decimal.D memory r = Decimal.sqrt(a);
        _assertNorm(r, "sqrt(10^3)");
        assertEq(r.exponent, 1, "sqrt(10^3) exponent");
        uint256 expected = 3_162_277_660_168_379_332;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2, "sqrt(10^3) mantissa within 2 ULP");
    }

    function test_sqrt_pow10_negativeEven() public pure {
        // sqrt(10^-4) == 10^-2
        Decimal.D memory a = Decimal.pow10(-4);
        Decimal.D memory r = Decimal.sqrt(a);
        _assertNorm(r, "sqrt(10^-4)");
        assertTrue(Decimal.eq(r, Decimal.pow10(-2)), "sqrt(10^-4)==10^-2");
    }

    function test_sqrt_pow10_negativeOdd() public pure {
        // sqrt(10^-3) == 10^-1.5 — exponent should be -2, mantissa ≈ 3.162e18
        Decimal.D memory a = Decimal.pow10(-3);
        Decimal.D memory r = Decimal.sqrt(a);
        _assertNorm(r, "sqrt(10^-3)");
        assertEq(r.exponent, -2, "sqrt(10^-3) exponent");
        uint256 expected = 3_162_277_660_168_379_332;
        uint256 got      = uint256(r.mantissa);
        uint256 diff     = got > expected ? got - expected : expected - got;
        assertLe(diff, 2, "sqrt(10^-3) mantissa within 2 ULP");
    }

    // ── sqr(sqrt(a)) ≈ a round-trip ──────────────────────────────────────────

    function test_sqrt_roundTrip_4() public pure {
        Decimal.D memory a = Decimal.fromUint(4);
        Decimal.D memory r = Decimal.sqr(Decimal.sqrt(a));
        // sqr(sqrt(4)) should equal 4 exactly
        assertTrue(Decimal.eq(r, a), "sqr(sqrt(4))==4");
    }

    function test_sqrt_roundTrip_9() public pure {
        Decimal.D memory a = Decimal.fromUint(9);
        Decimal.D memory r = Decimal.sqr(Decimal.sqrt(a));
        assertTrue(Decimal.eq(r, a), "sqr(sqrt(9))==9");
    }

    function test_sqrt_roundTrip_largeEven() public pure {
        // 10^1000 — even exponent
        Decimal.D memory a = Decimal.pow10(1000);
        Decimal.D memory r = Decimal.sqr(Decimal.sqrt(a));
        assertTrue(Decimal.eq(r, a), "sqr(sqrt(10^1000))==10^1000");
    }

    // ── output is never negative ──────────────────────────────────────────────

    function test_sqrt_resultIsNotNegative() public pure {
        Decimal.D memory r = Decimal.sqrt(Decimal.fromUint(7));
        assertFalse(r.negative, "sqrt result non-negative");
    }

    // ── fuzz: output is normalised and non-negative ───────────────────────────

    function testFuzz_sqrt_normalised(uint64 mantissaRaw, int8 expRaw) public pure {
        // Build a valid positive D by shifting mantissaRaw into [1e18, 10e18).
        uint128 m = uint128(mantissaRaw % (9 * uint64(Decimal.MANTISSA_SCALE)))
                    + uint128(Decimal.MANTISSA_SCALE);
        int64 e = int64(expRaw) * 100; // spread across ±EXP_LIMIT safely
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: e, negative: false});
        a = Decimal.normalize(a);
        if (a.mantissa == 0) return; // skip degenerate

        Decimal.D memory r = Decimal.sqrt(a);
        _assertNorm(r, "fuzz sqrt");
        assertFalse(r.negative, "fuzz sqrt non-negative");
    }
}
