// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DecimalMath} from "../src/DecimalMath.sol";

/// @dev Thin wrapper so vm.expectRevert() can intercept reverts in internal library calls.
contract DecimalMathHarness {
    function pow10(uint256 n) external pure returns (uint256) { return DecimalMath.pow10(n); }
    function floorLog10(uint256 x) external pure returns (int256) { return DecimalMath.floorLog10(x); }
    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) { return DecimalMath.mulDiv(a, b, d); }
    function log10Fixed(uint256 x) external pure returns (int256) { return DecimalMath.log10Fixed(x); }
    function exp10Fixed(int256 x) external pure returns (uint256) { return DecimalMath.exp10Fixed(x); }
}

contract DecimalMathTest is Test {
    uint256 constant S = DecimalMath.MANTISSA_SCALE; // 1e18
    DecimalMathHarness h = new DecimalMathHarness();

    // ── pow10 ─────────────────────────────────────────────────────────────────

    function test_pow10_zero() public pure {
        assertEq(DecimalMath.pow10(0), 1);
    }

    function test_pow10_one() public pure {
        assertEq(DecimalMath.pow10(1), 10);
    }

    function test_pow10_18() public pure {
        assertEq(DecimalMath.pow10(18), 1e18);
    }

    function test_pow10_77() public pure {
        // 10^77 must fit in uint256 (log2(10^77) ≈ 255.8, just under 256)
        uint256 v = DecimalMath.pow10(77);
        assertGt(v, 0);
        // Verify: 10^77 / 10^76 == 10
        assertEq(v / DecimalMath.pow10(76), 10);
    }

    function test_pow10_overflow_reverts() public {
        vm.expectRevert(DecimalMath.DecimalMath__Pow10Overflow.selector);
        h.pow10(78);
    }

    // ── floorLog10 ────────────────────────────────────────────────────────────

    function test_floorLog10_zero_reverts() public {
        vm.expectRevert(DecimalMath.DecimalMath__InputZero.selector);
        h.floorLog10(0);
    }

    function test_floorLog10_one() public pure {
        assertEq(DecimalMath.floorLog10(1), 0);
    }

    function test_floorLog10_nine() public pure {
        assertEq(DecimalMath.floorLog10(9), 0);
    }

    function test_floorLog10_ten() public pure {
        assertEq(DecimalMath.floorLog10(10), 1);
    }

    function test_floorLog10_42() public pure {
        assertEq(DecimalMath.floorLog10(42), 1);
    }

    function test_floorLog10_99() public pure {
        assertEq(DecimalMath.floorLog10(99), 1);
    }

    function test_floorLog10_100() public pure {
        assertEq(DecimalMath.floorLog10(100), 2);
    }

    function test_floorLog10_999() public pure {
        assertEq(DecimalMath.floorLog10(999), 2);
    }

    function test_floorLog10_1e18() public pure {
        assertEq(DecimalMath.floorLog10(1e18), 18);
    }

    function test_floorLog10_justBelow1e18() public pure {
        assertEq(DecimalMath.floorLog10(1e18 - 1), 17);
    }

    function test_floorLog10_1e77() public pure {
        assertEq(DecimalMath.floorLog10(DecimalMath.pow10(77)), 77);
    }

    /// @dev floorLog10 must equal k for all exact powers of 10.
    function test_floorLog10_exactPowersOf10() public pure {
        for (uint256 k = 0; k <= 77; k++) {
            assertEq(DecimalMath.floorLog10(DecimalMath.pow10(k)), int256(k));
        }
    }

    /// @dev One below a power of 10 gives k-1.
    function test_floorLog10_oneBelowPowerOf10() public pure {
        for (uint256 k = 1; k <= 18; k++) {
            assertEq(DecimalMath.floorLog10(DecimalMath.pow10(k) - 1), int256(k) - 1);
        }
    }

    // ── mulDiv ────────────────────────────────────────────────────────────────

    function test_mulDiv_basic() public pure {
        assertEq(DecimalMath.mulDiv(3, 4, 2), 6);
    }

    function test_mulDiv_identity() public pure {
        // a * 1e18 / 1e18 == a
        assertEq(DecimalMath.mulDiv(12345, S, S), 12345);
    }

    function test_mulDiv_truncation() public pure {
        // 10 / 3 = 3 (floor)
        assertEq(DecimalMath.mulDiv(10, 1, 3), 3);
    }

    function test_mulDiv_largeIntermediate() public pure {
        // (2^128) * (2^128) / (2^128) = 2^128 — intermediate is 2^256 - 1 bits
        uint256 half = type(uint128).max; // 2^128 - 1
        uint256 result = DecimalMath.mulDiv(half, half, half);
        assertEq(result, half);
    }

    function test_mulDiv_divisionByZero_reverts() public {
        vm.expectRevert(DecimalMath.DecimalMath__DivisionByZero.selector);
        h.mulDiv(1, 1, 0);
    }

    function test_mulDiv_overflow_reverts() public {
        vm.expectRevert(DecimalMath.DecimalMath__MulDivOverflow.selector);
        h.mulDiv(type(uint256).max, type(uint256).max, 1);
    }

    // ── mulFixed / divFixed ───────────────────────────────────────────────────

    function test_mulFixed_identity() public pure {
        // 1.0 * 1.0 == 1.0
        assertEq(DecimalMath.mulFixed(S, S), S);
    }

    function test_mulFixed_half() public pure {
        // 0.5 * 2.0 == 1.0
        assertEq(DecimalMath.mulFixed(S / 2, 2 * S), S);
    }

    function test_mulFixed_scales() public pure {
        // 3.0 * 4.0 == 12.0
        assertEq(DecimalMath.mulFixed(3 * S, 4 * S), 12 * S);
    }

    function test_divFixed_identity() public pure {
        // 1.0 / 1.0 == 1.0
        assertEq(DecimalMath.divFixed(S, S), S);
    }

    function test_divFixed_half() public pure {
        // 1.0 / 2.0 == 0.5
        assertEq(DecimalMath.divFixed(S, 2 * S), S / 2);
    }

    function test_divFixed_scales() public pure {
        // 12.0 / 4.0 == 3.0
        assertEq(DecimalMath.divFixed(12 * S, 4 * S), 3 * S);
    }

    // ── stubs still revert ────────────────────────────────────────────────────

    function test_log10Fixed_stub_reverts() public {
        vm.expectRevert();
        h.log10Fixed(S);
    }

    function test_exp10Fixed_stub_reverts() public {
        vm.expectRevert();
        h.exp10Fixed(0);
    }
}
