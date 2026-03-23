// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Tests + red-team for Phase C — neg, abs, sign.
///
/// Properties verified:
///   neg  – involution, field preservation, zero short-circuit
///   abs  – idempotency, always non-negative, field preservation
///   sign – idempotency, range {-1,0,1}, consistency with cmp
///
/// Footguns documented:
///   • neg(non-canonical-zero) returns the input unchanged (not canonical zero)
///   • abs(non-canonical-zero) strips the sign but keeps a non-zero exponent
contract DecimalCTest is Test {

    uint128 constant SCALE = uint128(Decimal.MANTISSA_SCALE);

    function _pos(uint256 x) internal pure returns (Decimal.D memory) {
        return Decimal.fromUint(x);
    }
    function _neg(uint256 x) internal pure returns (Decimal.D memory) {
        return Decimal.fromInt(-int256(x));
    }
    function _raw(uint128 m, int64 e, bool s) internal pure returns (Decimal.D memory) {
        return Decimal.D({mantissa: m, exponent: e, negative: s});
    }
    function _same(Decimal.D memory a, Decimal.D memory b) internal pure returns (bool) {
        return a.mantissa == b.mantissa && a.exponent == b.exponent && a.negative == b.negative;
    }

    // ── neg: basic ────────────────────────────────────────────────────────────

    function test_neg_zero_returnsZero() public pure {
        // neg(0) must be zero (mantissa == 0 short-circuit)
        Decimal.D memory r = Decimal.neg(Decimal.zero());
        assertEq(r.mantissa, 0);
        assertFalse(r.negative); // canonical zero has negative == false
    }

    function test_neg_positiveBecomesNegative() public pure {
        Decimal.D memory r = Decimal.neg(_pos(5));
        assertEq(r.mantissa, 5 * SCALE);
        assertEq(r.exponent, 0);
        assertTrue(r.negative);
    }

    function test_neg_negativeBecomesPositive() public pure {
        Decimal.D memory r = Decimal.neg(_neg(5));
        assertEq(r.mantissa, 5 * SCALE);
        assertEq(r.exponent, 0);
        assertFalse(r.negative);
    }

    function test_neg_preservesMantissa() public pure {
        Decimal.D memory a = _pos(42);
        assertEq(Decimal.neg(a).mantissa, a.mantissa);
    }

    function test_neg_preservesExponent() public pure {
        Decimal.D memory a = _pos(42);
        assertEq(Decimal.neg(a).exponent, a.exponent);
    }

    // ── neg: involution ───────────────────────────────────────────────────────

    function test_neg_involution_positive() public pure {
        Decimal.D memory a = _pos(999);
        assertTrue(_same(Decimal.neg(Decimal.neg(a)), a));
    }

    function test_neg_involution_negative() public pure {
        Decimal.D memory a = _neg(999);
        assertTrue(_same(Decimal.neg(Decimal.neg(a)), a));
    }

    function test_neg_involution_zero() public pure {
        // neg(neg(0)) == 0
        assertTrue(_same(Decimal.neg(Decimal.neg(Decimal.zero())), Decimal.zero()));
    }

    function testFuzz_neg_involution(uint64 x) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(x));
        assertTrue(_same(Decimal.neg(Decimal.neg(a)), a));
    }

    // ── neg: footgun — non-canonical zero ─────────────────────────────────────

    /// @dev neg(D{0, 5, true}) returns the input unchanged — it does NOT produce
    ///      the canonical zero D{0, 0, false}.  The result still compares equal to
    ///      zero (cmp checks mantissa first), but callers should never pass raw
    ///      non-canonical zero structs to library functions.
    function test_neg_nonCanonicalZero_returnsInputUnchanged() public pure {
        Decimal.D memory nz = _raw(0, 5, true);
        Decimal.D memory r  = Decimal.neg(nz);
        // Returns input as-is — same non-canonical state
        assertEq(r.mantissa,  uint128(0));
        assertEq(r.exponent,  int64(5));
        assertEq(r.negative,  true);
        // But it still equals zero in comparisons
        assertEq(Decimal.cmp(r, Decimal.zero()), 0);
    }

    // ── abs: basic ────────────────────────────────────────────────────────────

    function test_abs_zero() public pure {
        Decimal.D memory r = Decimal.abs(Decimal.zero());
        assertEq(r.mantissa,  uint128(0));
        assertFalse(r.negative);
    }

    function test_abs_positiveUnchanged() public pure {
        Decimal.D memory a = _pos(7);
        assertTrue(_same(Decimal.abs(a), a));
    }

    function test_abs_negativeBecomesPositive() public pure {
        Decimal.D memory a = _neg(7);
        Decimal.D memory r = Decimal.abs(a);
        assertFalse(r.negative);
        assertEq(r.mantissa, a.mantissa);
        assertEq(r.exponent, a.exponent);
    }

    function test_abs_alwaysNonNegative() public pure {
        assertTrue(Decimal.gte(Decimal.abs(_neg(999)), Decimal.zero()));
    }

    // ── abs: idempotency ──────────────────────────────────────────────────────

    function test_abs_idempotent_positive() public pure {
        Decimal.D memory a = _pos(42);
        assertTrue(_same(Decimal.abs(Decimal.abs(a)), Decimal.abs(a)));
    }

    function test_abs_idempotent_negative() public pure {
        Decimal.D memory a = _neg(42);
        assertTrue(_same(Decimal.abs(Decimal.abs(a)), Decimal.abs(a)));
    }

    function testFuzz_abs_idempotent(uint64 x) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(x));
        assertTrue(_same(Decimal.abs(Decimal.abs(a)), Decimal.abs(a)));
    }

    function testFuzz_abs_alwaysNonNegative(int32 x) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(x));
        assertFalse(Decimal.abs(a).negative);
        assertTrue(Decimal.gte(Decimal.abs(a), Decimal.zero()));
    }

    // ── abs: footgun — non-canonical zero ─────────────────────────────────────

    /// @dev abs(D{0, 5, true}) = D{0, 5, false} — the exponent is NOT reset to 0.
    ///      Still compares equal to zero, but is not the canonical form.
    function test_abs_nonCanonicalZero_stripsSignOnly() public pure {
        Decimal.D memory nz = _raw(0, 5, true);
        Decimal.D memory r  = Decimal.abs(nz);
        assertEq(r.mantissa,  uint128(0));
        assertEq(r.exponent,  int64(5)); // exponent left as-is
        assertFalse(r.negative);
        assertEq(Decimal.cmp(r, Decimal.zero()), 0); // still equals zero
    }

    // ── abs + neg relationship ─────────────────────────────────────────────────

    function testFuzz_abs_neg_sameResult(uint64 x) public pure {
        // abs(a) == abs(neg(a)) — flipping sign doesn't change absolute value
        Decimal.D memory a = Decimal.fromUint(uint256(x));
        assertTrue(_same(Decimal.abs(a), Decimal.abs(Decimal.neg(a))));
    }

    function testFuzz_abs_geq_zero(int32 x) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(x));
        assertTrue(Decimal.gte(Decimal.abs(a), Decimal.zero()));
    }

    // ── sign: basic ───────────────────────────────────────────────────────────

    function test_sign_zero() public pure {
        assertTrue(_same(Decimal.sign(Decimal.zero()), Decimal.zero()));
    }

    function test_sign_positive() public pure {
        assertTrue(_same(Decimal.sign(_pos(999)), Decimal.one()));
    }

    function test_sign_negative() public pure {
        assertTrue(_same(Decimal.sign(_neg(999)), Decimal.negOne()));
    }

    function test_sign_one() public pure {
        assertTrue(_same(Decimal.sign(Decimal.one()), Decimal.one()));
    }

    function test_sign_negOne() public pure {
        assertTrue(_same(Decimal.sign(Decimal.negOne()), Decimal.negOne()));
    }

    // ── sign: idempotency ─────────────────────────────────────────────────────

    function test_sign_idempotent_pos() public pure {
        assertTrue(_same(Decimal.sign(Decimal.sign(_pos(5))), Decimal.sign(_pos(5))));
    }

    function test_sign_idempotent_neg() public pure {
        assertTrue(_same(Decimal.sign(Decimal.sign(_neg(5))), Decimal.sign(_neg(5))));
    }

    function test_sign_idempotent_zero() public pure {
        assertTrue(_same(Decimal.sign(Decimal.sign(Decimal.zero())), Decimal.zero()));
    }

    function testFuzz_sign_idempotent(int32 x) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(x));
        assertTrue(_same(Decimal.sign(Decimal.sign(a)), Decimal.sign(a)));
    }

    // ── sign: range ───────────────────────────────────────────────────────────

    function testFuzz_sign_alwaysOneOfThree(int32 x) public pure {
        Decimal.D memory s = Decimal.sign(Decimal.fromInt(int256(x)));
        bool isZero    = _same(s, Decimal.zero());
        bool isOne     = _same(s, Decimal.one());
        bool isNegOne  = _same(s, Decimal.negOne());
        assertTrue(isZero || isOne || isNegOne, "sign not in {-1,0,1}");
    }

    // ── sign: consistency with cmp ────────────────────────────────────────────

    function testFuzz_sign_consistentWithCmp(int32 x) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(x));
        Decimal.D memory s = Decimal.sign(a);
        int8 cmpResult = Decimal.cmp(a, Decimal.zero());
        // cmp(a,0) and cmp(sign(a),0) must agree
        assertEq(Decimal.cmp(s, Decimal.zero()), cmpResult);
    }

    function testFuzz_sign_negationFlipsSign(int32 x) public pure {
        vm.assume(x != 0);
        Decimal.D memory a  = Decimal.fromInt(int256(x));
        Decimal.D memory na = Decimal.neg(a);
        // sign(a) and sign(neg(a)) must be negatives of each other
        assertTrue(_same(Decimal.sign(na), Decimal.neg(Decimal.sign(a))));
    }

    // ── cross-function properties ─────────────────────────────────────────────

    function testFuzz_abs_isNeg_ofNegInput(int32 x) public pure {
        vm.assume(x < 0);
        Decimal.D memory a = Decimal.fromInt(int256(x));
        // abs(a) == neg(a) when a is negative
        assertTrue(_same(Decimal.abs(a), Decimal.neg(a)));
    }

    function testFuzz_abs_isSelf_ofPosInput(uint32 x) public pure {
        Decimal.D memory a = Decimal.fromUint(uint256(x));
        // abs(a) == a when a is non-negative
        assertTrue(_same(Decimal.abs(a), a));
    }

    function testFuzz_neg_and_abs_commute_via_sign(uint32 x) public pure {
        vm.assume(x > 0);
        Decimal.D memory a = Decimal.fromUint(uint256(x));
        // neg(a) is negative, abs(neg(a)) == a
        assertTrue(_same(Decimal.abs(Decimal.neg(a)), a));
    }
}
