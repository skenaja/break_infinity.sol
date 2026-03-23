// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Tests for Phase D — add / sub, built up step by step.
contract DecimalDTest is Test {

    function _p(uint256 x) internal pure returns (Decimal.D memory) { return Decimal.fromUint(x); }
    function _n(uint256 x) internal pure returns (Decimal.D memory) { return Decimal.fromInt(-int256(x)); }
    function _eq(Decimal.D memory a, Decimal.D memory b) internal pure returns (bool) {
        return Decimal.eq(a, b);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Slice 1 — zero short-circuits
    // ═══════════════════════════════════════════════════════════════════════════

    function test_add_zeroPlusX_returnsX() public pure {
        assertTrue(_eq(Decimal.add(Decimal.zero(), _p(7)), _p(7)));
    }

    function test_add_xPlusZero_returnsX() public pure {
        assertTrue(_eq(Decimal.add(_p(7), Decimal.zero()), _p(7)));
    }

    function test_add_zeroPlusZero() public pure {
        assertTrue(_eq(Decimal.add(Decimal.zero(), Decimal.zero()), Decimal.zero()));
    }

    function test_add_zeroPlusNegative() public pure {
        assertTrue(_eq(Decimal.add(Decimal.zero(), _n(5)), _n(5)));
    }

    function test_sub_zeroPlusX() public pure {
        assertTrue(_eq(Decimal.sub(Decimal.zero(), _p(3)), _n(3)));
    }

    function test_sub_xMinusZero() public pure {
        assertTrue(_eq(Decimal.sub(_p(3), Decimal.zero()), _p(3)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Slice 2 — insignificance cutoff (expDiff > 17 → return big)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_add_insignificant_smallIgnored() public pure {
        // 1e100 + 1 — gap of 100 >> 17, small is ignored
        Decimal.D memory big   = Decimal.pow10(100);
        Decimal.D memory small = _p(1);
        assertTrue(_eq(Decimal.add(big, small), big));
    }

    function test_add_insignificant_commutative() public pure {
        Decimal.D memory big   = Decimal.pow10(100);
        Decimal.D memory small = _p(1);
        assertTrue(_eq(Decimal.add(small, big), big));
    }

    function test_add_insignificant_negativeSmall() public pure {
        // 1e100 + (-1) — still 1e100
        Decimal.D memory big   = Decimal.pow10(100);
        Decimal.D memory small = _n(1);
        assertTrue(_eq(Decimal.add(big, small), big));
    }

    function test_add_exactlyAtCutoff_isStillCombined() public pure {
        // gap == 17 is NOT cut off — values exactly 17 apart are still added
        // 1e18 (exp=18) + 1 (exp=0) — diff = 18 → cut off
        // 1e17 (exp=17) + 1 (exp=0) — diff = 17 → combined
        Decimal.D memory a = Decimal.pow10(17); // exp=17, mantissa=1e18
        Decimal.D memory b = _p(1);             // exp=0,  mantissa=1e18
        // gap = 17, should NOT be cut off — result != a
        assertFalse(_eq(Decimal.add(a, b), a));
    }

    function test_add_onePastCutoff_isCutOff() public pure {
        // gap == 18 → cut off
        Decimal.D memory a = Decimal.pow10(18);
        Decimal.D memory b = _p(1);
        assertTrue(_eq(Decimal.add(a, b), a));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Slice 3 — same-sign addition
    // ═══════════════════════════════════════════════════════════════════════════

    function test_add_oneOne() public pure {
        assertTrue(_eq(Decimal.add(_p(1), _p(1)), _p(2)));
    }

    function test_add_fiveThree() public pure {
        assertTrue(_eq(Decimal.add(_p(5), _p(3)), _p(8)));
    }

    function test_add_negNeg() public pure {
        // (-5) + (-3) = -8
        assertTrue(_eq(Decimal.add(_n(5), _n(3)), _n(8)));
    }

    function test_add_sameExpCarry() public pure {
        // 9e18/1e18 * 10^0 = 9;  9+9=18 → mantissa carries to next exponent
        // D{9e18,0} + D{9e18,0} → sum mantissa = 18e18 → normalize → D{1.8e18,1}
        Decimal.D memory a   = Decimal.fromParts(uint128(9 * uint256(Decimal.MANTISSA_SCALE)), 0, false);
        Decimal.D memory res = Decimal.add(a, a);
        assertEq(res.exponent, 1);
        assertEq(res.mantissa, uint128(18 * uint256(Decimal.MANTISSA_SCALE) / 10)); // 1.8e18
    }

    function test_add_differentExp() public pure {
        // 1000 + 1 = 1001
        assertTrue(_eq(Decimal.add(_p(1000), _p(1)), _p(1001)));
    }

    function test_add_largePowersOfTen() public pure {
        // 1e50 + 1e50 = 2e50
        Decimal.D memory half = Decimal.pow10(50);
        Decimal.D memory res  = Decimal.add(half, half);
        assertEq(res.exponent, 50);
        assertEq(res.mantissa, 2 * uint128(Decimal.MANTISSA_SCALE));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Slice 4 — different-sign (subtraction of magnitudes)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_add_posAndNeg_netPositive() public pure {
        // 5 + (-3) = 2
        assertTrue(_eq(Decimal.add(_p(5), _n(3)), _p(2)));
    }

    function test_add_posAndNeg_netNegative() public pure {
        // 3 + (-5) = -2
        assertTrue(_eq(Decimal.add(_p(3), _n(5)), _n(2)));
    }

    function test_add_posAndNeg_exactCancel() public pure {
        // 5 + (-5) = 0
        assertTrue(_eq(Decimal.add(_p(5), _n(5)), Decimal.zero()));
    }

    function test_add_negAndPos_exactCancel() public pure {
        assertTrue(_eq(Decimal.add(_n(5), _p(5)), Decimal.zero()));
    }

    function test_add_negAndPos_netNegative() public pure {
        // (-7) + 3 = -4
        assertTrue(_eq(Decimal.add(_n(7), _p(3)), _n(4)));
    }

    function test_sub_basic() public pure {
        // 8 - 3 = 5
        assertTrue(_eq(Decimal.sub(_p(8), _p(3)), _p(5)));
    }

    function test_sub_xMinusX() public pure {
        // x - x = 0 for any x
        assertTrue(_eq(Decimal.sub(_p(42), _p(42)), Decimal.zero()));
    }

    function test_sub_negResult() public pure {
        // 3 - 8 = -5
        assertTrue(_eq(Decimal.sub(_p(3), _p(8)), _n(5)));
    }

    function test_add_differentExp_oppositeSign() public pure {
        // 1000 + (-1) = 999
        assertTrue(_eq(Decimal.add(_p(1000), _n(1)), _p(999)));
    }

    function test_add_nearlyCancels_smallRemainder() public pure {
        // 1e18 + (-9.999...e17) should give a small positive
        // Use: 10 + (-9) = 1
        assertTrue(_eq(Decimal.add(_p(10), _n(9)), _p(1)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fuzz — algebraic laws
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Commutativity: a + b == b + a
    function testFuzz_add_commutative(int32 rawA, int32 rawB) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(rawA));
        Decimal.D memory b = Decimal.fromInt(int256(rawB));
        assertEq(Decimal.cmp(Decimal.add(a, b), Decimal.add(b, a)), 0);
    }

    /// @dev Identity: a + 0 == a
    function testFuzz_add_zeroIdentity(int32 rawA) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(rawA));
        assertEq(Decimal.cmp(Decimal.add(a, Decimal.zero()), a), 0);
    }

    /// @dev Inverse: a + (-a) == 0
    function testFuzz_add_selfInverse(int32 rawA) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(rawA));
        assertTrue(_eq(Decimal.add(a, Decimal.neg(a)), Decimal.zero()));
    }

    /// @dev sub(a, b) == add(a, neg(b))
    function testFuzz_sub_equalsAddNeg(int32 rawA, int32 rawB) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(rawA));
        Decimal.D memory b = Decimal.fromInt(int256(rawB));
        assertEq(Decimal.cmp(Decimal.sub(a, b), Decimal.add(a, Decimal.neg(b))), 0);
    }

    /// @dev Result sign: add of same-sign inputs keeps that sign (unless cancellation).
    function testFuzz_add_sameSignPreservesSign(uint32 rawA, uint32 rawB) public pure {
        vm.assume(rawA > 0 && rawB > 0);
        Decimal.D memory a   = Decimal.fromUint(uint256(rawA));
        Decimal.D memory b   = Decimal.fromUint(uint256(rawB));
        Decimal.D memory sum = Decimal.add(a, b);
        assertFalse(sum.negative, "sum of two positives should be positive");
        assertTrue(Decimal.gte(sum, a), "sum >= a");
        assertTrue(Decimal.gte(sum, b), "sum >= b");
    }

    /// @dev add is consistent with integer arithmetic for small values.
    function testFuzz_add_consistentWithInt(uint16 rawA, uint16 rawB) public pure {
        uint256 expected = uint256(rawA) + uint256(rawB);
        Decimal.D memory result = Decimal.add(
            Decimal.fromUint(uint256(rawA)),
            Decimal.fromUint(uint256(rawB))
        );
        assertTrue(_eq(result, Decimal.fromUint(expected)));
    }

    /// @dev sub is consistent with integer arithmetic for small values (a >= b).
    function testFuzz_sub_consistentWithInt(uint16 rawA, uint16 rawB) public pure {
        vm.assume(rawA >= rawB);
        uint256 expected = uint256(rawA) - uint256(rawB);
        Decimal.D memory result = Decimal.sub(
            Decimal.fromUint(uint256(rawA)),
            Decimal.fromUint(uint256(rawB))
        );
        assertTrue(_eq(result, Decimal.fromUint(expected)));
    }

    /// @dev Output of add is always normalized.
    function testFuzz_add_alwaysNormalized(int32 rawA, int32 rawB) public pure {
        Decimal.D memory result = Decimal.add(
            Decimal.fromInt(int256(rawA)),
            Decimal.fromInt(int256(rawB))
        );
        if (result.mantissa == 0) {
            assertEq(result.exponent, 0);
            assertFalse(result.negative);
        } else {
            assertGe(result.mantissa, uint128(Decimal.MANTISSA_SCALE));
            assertLt(result.mantissa, uint128(Decimal.MANTISSA_MAX));
        }
    }
}
