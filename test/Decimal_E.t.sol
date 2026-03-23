// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {DecimalMath} from "../src/DecimalMath.sol";

/// @dev Harness for vm.expectRevert on internal library calls.
contract DecimalEHarness {
    function mul(Decimal.D memory a, Decimal.D memory b) external pure returns (Decimal.D memory) {
        return Decimal.mul(a, b);
    }
    function div(Decimal.D memory a, Decimal.D memory b) external pure returns (Decimal.D memory) {
        return Decimal.div(a, b);
    }
}

/// @notice Tests for Phase E — mul, div, recip.
contract DecimalETest is Test {

    DecimalEHarness dh = new DecimalEHarness();

    uint128 constant S = uint128(Decimal.MANTISSA_SCALE);

    function _p(uint256 x) internal pure returns (Decimal.D memory) { return Decimal.fromUint(x); }
    function _n(uint256 x) internal pure returns (Decimal.D memory) { return Decimal.fromInt(-int256(x)); }
    function _eq(Decimal.D memory a, Decimal.D memory b) internal pure returns (bool) {
        return Decimal.eq(a, b);
    }
    function _assertNorm(Decimal.D memory d, string memory lbl) internal pure {
        if (d.mantissa == 0) {
            assertEq(d.exponent, 0, string.concat(lbl, ": zero exp"));
            assertFalse(d.negative, string.concat(lbl, ": zero sign"));
        } else {
            assertGe(d.mantissa, S,      string.concat(lbl, ": mantissa >= SCALE"));
            assertLt(d.mantissa, 10 * S, string.concat(lbl, ": mantissa < MAX"));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // mul — zero short-circuits
    // ═══════════════════════════════════════════════════════════════════════════

    function test_mul_zeroTimesX_isZero() public pure {
        assertTrue(_eq(Decimal.mul(Decimal.zero(), _p(42)), Decimal.zero()));
    }

    function test_mul_xTimesZero_isZero() public pure {
        assertTrue(_eq(Decimal.mul(_p(42), Decimal.zero()), Decimal.zero()));
    }

    function test_mul_zeroTimesZero_isZero() public pure {
        assertTrue(_eq(Decimal.mul(Decimal.zero(), Decimal.zero()), Decimal.zero()));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // mul — identity (× 1)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_mul_oneIsIdentity_right() public pure {
        assertTrue(_eq(Decimal.mul(_p(7), Decimal.one()), _p(7)));
    }

    function test_mul_oneIsIdentity_left() public pure {
        assertTrue(_eq(Decimal.mul(Decimal.one(), _p(7)), _p(7)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // mul — concrete values
    // ═══════════════════════════════════════════════════════════════════════════

    function test_mul_twoTimesThree() public pure {
        assertTrue(_eq(Decimal.mul(_p(2), _p(3)), _p(6)));
    }

    function test_mul_tenTimesTen() public pure {
        assertTrue(_eq(Decimal.mul(_p(10), _p(10)), _p(100)));
    }

    function test_mul_largePowersOfTen() public pure {
        // 1e50 * 1e30 = 1e80
        Decimal.D memory a = Decimal.pow10(50);
        Decimal.D memory b = Decimal.pow10(30);
        Decimal.D memory r = Decimal.mul(a, b);
        assertEq(r.exponent, 80);
        assertEq(r.mantissa, S);
    }

    function test_mul_negTimesPos_isNeg() public pure {
        // (-3) * 4 = -12
        assertTrue(_eq(Decimal.mul(_n(3), _p(4)), _n(12)));
    }

    function test_mul_negTimesNeg_isPos() public pure {
        // (-3) * (-4) = 12
        assertTrue(_eq(Decimal.mul(_n(3), _n(4)), _p(12)));
    }

    function test_mul_posTimesNeg_isNeg() public pure {
        // 5 * (-6) = -30
        assertTrue(_eq(Decimal.mul(_p(5), _n(6)), _n(30)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // mul — normalization
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_mul_alwaysNormalized(uint16 rawA, uint16 rawB) public pure {
        vm.assume(rawA > 0 && rawB > 0);
        Decimal.D memory r = Decimal.mul(_p(rawA), _p(rawB));
        _assertNorm(r, "mul");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // mul — algebraic laws
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Commutativity: a * b == b * a
    function testFuzz_mul_commutative(uint16 rawA, uint16 rawB) public pure {
        vm.assume(rawA > 0 && rawB > 0);
        Decimal.D memory a = _p(rawA);
        Decimal.D memory b = _p(rawB);
        assertEq(Decimal.cmp(Decimal.mul(a, b), Decimal.mul(b, a)), 0);
    }

    /// @dev Consistent with integer arithmetic for small values.
    function testFuzz_mul_consistentWithInt(uint16 rawA, uint16 rawB) public pure {
        vm.assume(rawA > 0 && rawB > 0);
        uint256 expected = uint256(rawA) * uint256(rawB);
        assertTrue(_eq(Decimal.mul(_p(rawA), _p(rawB)), _p(expected)));
    }

    /// @dev a * (-1) == neg(a)
    function testFuzz_mul_negOneFlipsSign(int16 rawA) public pure {
        vm.assume(rawA != 0);
        Decimal.D memory a = Decimal.fromInt(int256(rawA));
        assertTrue(_eq(Decimal.mul(a, Decimal.negOne()), Decimal.neg(a)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // mul — overflow at EXP_LIMIT
    // ═══════════════════════════════════════════════════════════════════════════

    function test_mul_overflowReverts() public {
        // 1e(EXP_LIMIT) * 1e(EXP_LIMIT) would have exponent 2*EXP_LIMIT > EXP_LIMIT
        Decimal.D memory a = Decimal.pow10(Decimal.EXP_LIMIT);
        vm.expectRevert();
        dh.mul(a, a);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // div — zero / error cases
    // ═══════════════════════════════════════════════════════════════════════════

    function test_div_byZero_reverts() public {
        vm.expectRevert();
        dh.div(_p(5), Decimal.zero());
    }

    function test_div_zeroByX_isZero() public pure {
        assertTrue(_eq(Decimal.div(Decimal.zero(), _p(7)), Decimal.zero()));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // div — concrete values
    // ═══════════════════════════════════════════════════════════════════════════

    function test_div_oneByOne() public pure {
        assertTrue(_eq(Decimal.div(Decimal.one(), Decimal.one()), Decimal.one()));
    }

    function test_div_sixByTwo() public pure {
        assertTrue(_eq(Decimal.div(_p(6), _p(2)), _p(3)));
    }

    function test_div_tenByTen() public pure {
        assertTrue(_eq(Decimal.div(_p(10), _p(10)), Decimal.one()));
    }

    function test_div_largePowersOfTen() public pure {
        // 1e80 / 1e30 = 1e50
        Decimal.D memory a = Decimal.pow10(80);
        Decimal.D memory b = Decimal.pow10(30);
        assertTrue(_eq(Decimal.div(a, b), Decimal.pow10(50)));
    }

    function test_div_negByPos_isNeg() public pure {
        // (-12) / 4 = -3
        assertTrue(_eq(Decimal.div(_n(12), _p(4)), _n(3)));
    }

    function test_div_negByNeg_isPos() public pure {
        // (-12) / (-4) = 3
        assertTrue(_eq(Decimal.div(_n(12), _n(4)), _p(3)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // div — normalization
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_div_alwaysNormalized(uint16 rawA, uint16 rawB) public pure {
        vm.assume(rawA > 0 && rawB > 0);
        Decimal.D memory r = Decimal.div(_p(rawA), _p(rawB));
        _assertNorm(r, "div");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // div — round-trip with mul
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev (a * b) / b == a for exact integer multiples (small values).
    function testFuzz_mul_div_roundtrip(uint8 rawA, uint8 rawB) public pure {
        vm.assume(rawA > 0 && rawB > 0);
        Decimal.D memory a = _p(rawA);
        Decimal.D memory b = _p(rawB);
        // a * b / b should equal a exactly (both are small integers)
        assertTrue(_eq(Decimal.div(Decimal.mul(a, b), b), a));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // recip
    // ═══════════════════════════════════════════════════════════════════════════

    function test_recip_one() public pure {
        assertTrue(_eq(Decimal.recip(Decimal.one()), Decimal.one()));
    }

    function test_recip_ten() public pure {
        // 1 / 10 — exponent -1, mantissa 1e18
        Decimal.D memory r = Decimal.recip(_p(10));
        assertEq(r.exponent, -1);
        assertEq(r.mantissa, S);
    }

    function test_recip_involution() public pure {
        // 1 / (1 / 4) == 4 (exact for powers of 2? No, 1/4 = 0.25 = 2.5e17 @ exp=-1)
        // Use power-of-ten for exact round-trip: recip(recip(100)) == 100
        assertTrue(_eq(Decimal.recip(Decimal.recip(_p(100))), _p(100)));
    }

    function test_recip_byZero_reverts() public {
        vm.expectRevert();
        dh.div(Decimal.one(), Decimal.zero());
    }
}
