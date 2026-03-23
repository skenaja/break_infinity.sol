// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {DecimalMath} from "../src/DecimalMath.sol";
import {IDecimalErrors} from "../src/interfaces/IDecimalErrors.sol";

/// @dev Harness for testing stubs that should revert (vm.expectRevert needs an external call).
contract DecimalHarness {
    function cmp(Decimal.D memory a, Decimal.D memory b) external pure returns (int8) { return Decimal.cmp(a, b); }
    function add(Decimal.D memory a, Decimal.D memory b) external pure returns (Decimal.D memory) { return Decimal.add(a, b); }
    function mul(Decimal.D memory a, Decimal.D memory b) external pure returns (Decimal.D memory) { return Decimal.mul(a, b); }
}

contract DecimalTest is Test {
    uint128 constant S  = uint128(Decimal.MANTISSA_SCALE); // 1e18
    uint128 constant S10 = uint128(Decimal.MANTISSA_MAX);  // 10e18
    DecimalHarness dh = new DecimalHarness();

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _d(uint128 m, int64 e, bool neg) internal pure returns (Decimal.D memory) {
        return Decimal.D({mantissa: m, exponent: e, negative: neg});
    }

    function _assertNormalized(Decimal.D memory d, string memory label) internal pure {
        if (d.mantissa == 0) {
            assertEq(d.exponent, 0, string.concat(label, ": zero exponent"));
            assertEq(d.negative, false, string.concat(label, ": zero sign"));
        } else {
            assertGe(d.mantissa, S,  string.concat(label, ": mantissa >= SCALE"));
            assertLt(d.mantissa, S10, string.concat(label, ": mantissa < MAX"));
        }
    }

    // ── Sentinels ─────────────────────────────────────────────────────────────

    function test_zero() public pure {
        Decimal.D memory z = Decimal.zero();
        assertEq(z.mantissa, 0);
        assertEq(z.exponent, 0);
        assertEq(z.negative, false);
    }

    function test_one() public pure {
        Decimal.D memory o = Decimal.one();
        assertEq(o.mantissa, S);
        assertEq(o.exponent, 0);
        assertEq(o.negative, false);
    }

    function test_negOne() public pure {
        Decimal.D memory n = Decimal.negOne();
        assertEq(n.mantissa, S);
        assertEq(n.exponent, 0);
        assertEq(n.negative, true);
    }

    // ── normalize ─────────────────────────────────────────────────────────────

    function test_normalize_alreadyNormal() public pure {
        // mantissa = 5e18 (real 5.0), exponent = 3 → no-op
        Decimal.D memory d = _d(5 * S, 3, false);
        Decimal.D memory n = Decimal.normalize(d);
        assertEq(n.mantissa, 5 * S);
        assertEq(n.exponent, 3);
    }

    function test_normalize_zero() public pure {
        Decimal.D memory d = _d(0, 7, true);
        Decimal.D memory n = Decimal.normalize(d);
        assertEq(n.mantissa, 0);
        assertEq(n.exponent, 0);
        assertEq(n.negative, false);
    }

    function test_normalize_mantissaTooLarge_byOne() public pure {
        // mantissa = 1e19 (10x too large), exponent = 3 → mantissa = 1e18, exponent = 4
        Decimal.D memory d = _d(10 * S, 3, false);
        Decimal.D memory n = Decimal.normalize(d);
        assertEq(n.mantissa, S);
        assertEq(n.exponent, 4);
    }

    function test_normalize_mantissaTooLarge_byTwo() public pure {
        // mantissa = 1e20, exponent = 0 → mantissa = 1e18, exponent = 2
        Decimal.D memory d = _d(uint128(100 * uint256(S)), 0, false);
        Decimal.D memory n = Decimal.normalize(d);
        assertEq(n.mantissa, S);
        assertEq(n.exponent, 2);
    }

    function test_normalize_mantissaTooSmall_byOne() public pure {
        // mantissa = 1e17 (10x too small), exponent = 5 → mantissa = 1e18, exponent = 4
        Decimal.D memory d = _d(S / 10, 5, false);
        Decimal.D memory n = Decimal.normalize(d);
        assertEq(n.mantissa, S);
        assertEq(n.exponent, 4);
    }

    function test_normalize_mantissaTooSmall_byTwo() public pure {
        // mantissa = 1e16, exponent = 5 → mantissa = 1e18, exponent = 3
        Decimal.D memory d = _d(S / 100, 5, false);
        Decimal.D memory n = Decimal.normalize(d);
        assertEq(n.mantissa, S);
        assertEq(n.exponent, 3);
    }

    function test_normalize_preservesSign() public pure {
        Decimal.D memory d = _d(50 * S, 0, true); // mantissa too large, negative
        Decimal.D memory n = Decimal.normalize(d);
        assertEq(n.negative, true);
        assertEq(n.exponent, 1);
        _assertNormalized(n, "normalized negative");
    }

    function test_normalize_exponentUnderflow_returnsZero() public pure {
        // exponent = -9e15 (EXP_LIMIT), mantissa = 1e16 (shift = -2) → new exp = -EXP_LIMIT - 2 → underflow → zero
        Decimal.D memory d = _d(S / 100, -int64(Decimal.EXP_LIMIT), false);
        Decimal.D memory n = Decimal.normalize(d);
        assertEq(n.mantissa, 0);
    }

    // ── fromUint ──────────────────────────────────────────────────────────────

    function test_fromUint_zero() public pure {
        Decimal.D memory d = Decimal.fromUint(0);
        assertEq(d.mantissa, 0);
        assertEq(d.exponent, 0);
    }

    function test_fromUint_one() public pure {
        // 1 → mantissa = 1e18, exponent = 0
        Decimal.D memory d = Decimal.fromUint(1);
        assertEq(d.mantissa, S);
        assertEq(d.exponent, 0);
        assertEq(d.negative, false);
    }

    function test_fromUint_nine() public pure {
        // 9 → mantissa = 9e18, exponent = 0
        Decimal.D memory d = Decimal.fromUint(9);
        assertEq(d.mantissa, 9 * S);
        assertEq(d.exponent, 0);
    }

    function test_fromUint_ten() public pure {
        // 10 → mantissa = 1e18, exponent = 1
        Decimal.D memory d = Decimal.fromUint(10);
        assertEq(d.mantissa, S);
        assertEq(d.exponent, 1);
    }

    function test_fromUint_42() public pure {
        // 42 → mantissa = 4.2e18, exponent = 1
        Decimal.D memory d = Decimal.fromUint(42);
        assertEq(d.mantissa, 42 * DecimalMath.pow10(17));
        assertEq(d.exponent, 1);
    }

    function test_fromUint_100() public pure {
        // 100 → mantissa = 1e18, exponent = 2
        Decimal.D memory d = Decimal.fromUint(100);
        assertEq(d.mantissa, S);
        assertEq(d.exponent, 2);
    }

    function test_fromUint_1e18() public pure {
        // 1e18 → mantissa = 1e18, exponent = 18
        Decimal.D memory d = Decimal.fromUint(1e18);
        assertEq(d.mantissa, S);
        assertEq(d.exponent, 18);
    }

    function test_fromUint_5e18() public pure {
        // 5e18 → mantissa = 5e18, exponent = 18
        Decimal.D memory d = Decimal.fromUint(5e18);
        assertEq(d.mantissa, 5 * S);
        assertEq(d.exponent, 18);
    }

    function test_fromUint_1e30() public pure {
        // 1e30 → mantissa = 1e18, exponent = 30
        Decimal.D memory d = Decimal.fromUint(DecimalMath.pow10(30));
        assertEq(d.mantissa, S);
        assertEq(d.exponent, 30);
    }

    function test_fromUint_1e77() public pure {
        // Largest representable uint256 power of 10
        Decimal.D memory d = Decimal.fromUint(DecimalMath.pow10(77));
        assertEq(d.mantissa, S);
        assertEq(d.exponent, 77);
    }

    /// @dev Every fromUint result must be normalised.
    function testFuzz_fromUint_normalized(uint256 x) public pure {
        vm.assume(x > 0 && x <= DecimalMath.pow10(77));
        Decimal.D memory d = Decimal.fromUint(x);
        _assertNormalized(d, "fromUint");
    }

    /// @dev Value round-trip: fromUint(x).mantissa * 10^exponent / 1e18 == x
    ///      (for small x so we can verify exactly without overflow).
    function testFuzz_fromUint_roundtrip_small(uint64 x) public pure {
        vm.assume(x > 0);
        Decimal.D memory d = Decimal.fromUint(uint256(x));
        // Reconstruct: mantissa / 1e18 * 10^exponent
        // For exponent >= 0: value = mantissa * 10^exponent / 1e18
        // For exponent  < 0: value = mantissa / (1e18 * 10^|exponent|) — not an integer, skip
        if (d.exponent >= 0 && d.exponent <= 18) {
            uint256 reconstructed = uint256(d.mantissa) * DecimalMath.pow10(uint256(uint64(d.exponent))) / 1e18;
            assertEq(reconstructed, x);
        }
    }

    // ── fromInt ───────────────────────────────────────────────────────────────

    function test_fromInt_zero() public pure {
        Decimal.D memory d = Decimal.fromInt(0);
        assertEq(d.mantissa, 0);
    }

    function test_fromInt_positive() public pure {
        Decimal.D memory pos = Decimal.fromInt(42);
        Decimal.D memory uint_ = Decimal.fromUint(42);
        assertEq(pos.mantissa,  uint_.mantissa);
        assertEq(pos.exponent,  uint_.exponent);
        assertEq(pos.negative,  false);
    }

    function test_fromInt_negative() public pure {
        Decimal.D memory d = Decimal.fromInt(-42);
        assertEq(d.mantissa, 42 * DecimalMath.pow10(17));
        assertEq(d.exponent, 1);
        assertEq(d.negative, true);
    }

    function test_fromInt_negOne() public pure {
        Decimal.D memory d = Decimal.fromInt(-1);
        assertEq(d.mantissa, S);
        assertEq(d.exponent, 0);
        assertEq(d.negative, true);
    }

    function testFuzz_fromInt_normalized(int64 x) public pure {
        vm.assume(x != 0);
        Decimal.D memory d = Decimal.fromInt(int256(x));
        _assertNormalized(d, "fromInt");
    }

    // ── fromParts (via normalize) ─────────────────────────────────────────────

    function test_fromParts_normal() public pure {
        // 3.7 × 10^5 = 370000
        Decimal.D memory d = Decimal.fromParts(37 * S / 10, 5, false);
        _assertNormalized(d, "fromParts");
        assertEq(d.exponent, 5);
    }

    function test_fromParts_unnormalized() public pure {
        // mantissa = 25e18 (too large), exponent = 2 → normalize → mantissa = 2.5e18, exp = 3
        Decimal.D memory d = Decimal.fromParts(uint128(25 * uint256(S)), 2, false);
        assertEq(d.mantissa, 25 * S / 10);
        assertEq(d.exponent, 3);
    }

    // ── mul smoke tests ───────────────────────────────────────────────────────

    function test_mul_oneTimesOne() public pure {
        Decimal.D memory r = Decimal.mul(Decimal.one(), Decimal.one());
        assertEq(r.mantissa, S);
        assertEq(r.exponent, 0);
        assertFalse(r.negative);
    }

    function test_mul_twoTimesThree() public pure {
        // 2 * 3 = 6
        Decimal.D memory r = Decimal.mul(Decimal.fromUint(2), Decimal.fromUint(3));
        assertTrue(Decimal.eq(r, Decimal.fromUint(6)));
    }
}
