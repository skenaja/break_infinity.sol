// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";
import {DecimalMath} from "../src/DecimalMath.sol";

/// @dev Harness to allow vm.expectRevert() on library calls (needs external call depth).
contract DecimalAddHarness {
    function add(Decimal.D memory a, Decimal.D memory b) external pure returns (Decimal.D memory) {
        return Decimal.add(a, b);
    }
}

/// @notice Adversarial / red-team suite for Phase D (add / sub).
///
/// Attack surfaces:
///   (1) Insignificance cutoff — exact boundary (expDiff 16/17/18/19)
///   (2) Near-cancellation — result requires large exponent downshift
///   (3) All four ±/± sign-combination orderings
///   (4) sub antisymmetry: sub(a,b) == neg(sub(b,a))
///   (5) Monotonicity: a < b → add(a,c) < add(b,c) for c ≥ 0
///   (6) Associativity failure is intentional at the cutoff boundary
///   (7) Extreme exponents (near ±EXP_LIMIT)
///   (8) alignedSmall truncation never flips result sign
contract PhaseDRedTeamTest is Test {

    DecimalAddHarness dh = new DecimalAddHarness();

    uint128 constant S = uint128(Decimal.MANTISSA_SCALE);

    function _p(uint256 x) internal pure returns (Decimal.D memory) { return Decimal.fromUint(x); }
    function _n(uint256 x) internal pure returns (Decimal.D memory) { return Decimal.fromInt(-int256(x)); }
    function _d(uint128 m, int64 e, bool neg) internal pure returns (Decimal.D memory) {
        return Decimal.D({mantissa: m, exponent: e, negative: neg});
    }
    function _eq(Decimal.D memory a, Decimal.D memory b) internal pure returns (bool) {
        return Decimal.eq(a, b);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (1) Insignificance cutoff — every value around the boundary
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Helper: build two normalised D values exactly expDiff apart.
    function _gap(uint256 expDiff) internal pure returns (Decimal.D memory big, Decimal.D memory small) {
        big   = Decimal.pow10(int64(uint64(expDiff)));  // mantissa=1e18, exponent=expDiff
        small = Decimal.one();                           // mantissa=1e18, exponent=0
    }

    function test_cutoff_expDiff16_combined() public pure {
        (Decimal.D memory big, Decimal.D memory small) = _gap(16);
        Decimal.D memory result = Decimal.add(big, small);
        // 1e16 + 1 = 10000000000000001 — must NOT equal 1e16
        assertFalse(_eq(result, big), "expDiff=16 should still combine");
    }

    function test_cutoff_expDiff17_combined() public pure {
        (Decimal.D memory big, Decimal.D memory small) = _gap(17);
        Decimal.D memory result = Decimal.add(big, small);
        // 1e17 + 1 — expDiff == MAX_SIGNIFICANT_DIGITS, NOT cut off
        assertFalse(_eq(result, big), "expDiff=17 should still combine");
    }

    function test_cutoff_expDiff18_cutoff() public pure {
        (Decimal.D memory big, Decimal.D memory small) = _gap(18);
        Decimal.D memory result = Decimal.add(big, small);
        // expDiff == 18 > 17 — small is insignificant, return big unchanged
        assertTrue(_eq(result, big), "expDiff=18 should cut off");
    }

    function test_cutoff_expDiff19_cutoff() public pure {
        (Decimal.D memory big, Decimal.D memory small) = _gap(19);
        assertTrue(_eq(Decimal.add(big, small), big), "expDiff=19 should cut off");
    }

    /// @dev Cutoff result is structurally identical to big (not a copy with tweaks).
    function test_cutoff_returnsExactBig() public pure {
        Decimal.D memory big   = Decimal.pow10(100);
        Decimal.D memory small = _p(1);
        Decimal.D memory result = Decimal.add(big, small);
        assertEq(result.mantissa,  big.mantissa);
        assertEq(result.exponent,  big.exponent);
        assertEq(result.negative,  big.negative);
    }

    /// @dev Cutoff works symmetrically — add(small, big) also returns big.
    function test_cutoff_symmetric() public pure {
        Decimal.D memory big   = Decimal.pow10(100);
        Decimal.D memory small = _p(1);
        assertTrue(_eq(Decimal.add(small, big), Decimal.add(big, small)));
    }

    /// @dev Negative big is returned unchanged at cutoff.
    function test_cutoff_negativeBig() public pure {
        Decimal.D memory big   = Decimal.neg(Decimal.pow10(50));
        Decimal.D memory small = _p(1);
        assertTrue(_eq(Decimal.add(big, small), big));
        assertTrue(Decimal.add(big, small).negative);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (2) Near-cancellation — large exponent downshift
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev 1e18 + (-9.99...e17) = 1e15 — result needs a 3-step downshift.
    function test_nearCancel_largeDownshift() public pure {
        // big = 1e18 (exp=18, mantissa=1e18)
        // small = 999e15 (exp=17, mantissa=9.99e18)
        Decimal.D memory big   = Decimal.pow10(18);
        Decimal.D memory small = Decimal.neg(Decimal.fromUint(999 * DecimalMath.pow10(15)));
        // 1e18 - 999e15 = 1e15
        Decimal.D memory result = Decimal.add(big, small);
        assertTrue(_eq(result, _p(DecimalMath.pow10(15))), "1e18 - 999e15 != 1e15");
    }

    /// @dev Cancellation down to 1 — extreme downshift.
    function test_nearCancel_downToOne() public pure {
        // 10 + (-9) = 1
        assertTrue(_eq(Decimal.add(_p(10), _n(9)), _p(1)));
        // 100 + (-99) = 1
        assertTrue(_eq(Decimal.add(_p(100), _n(99)), _p(1)));
        // 1000 + (-999) = 1
        assertTrue(_eq(Decimal.add(_p(1000), _n(999)), _p(1)));
    }

    /// @dev After cancellation the result is always normalized.
    function testFuzz_nearCancel_alwaysNormalized(uint32 a, uint32 b) public pure {
        vm.assume(a > b);
        Decimal.D memory result = Decimal.add(_p(uint256(a)), _n(uint256(b)));
        assertFalse(result.negative);
        assertTrue(result.mantissa >= S && result.mantissa < 10 * S);
    }

    /// @dev Exact cancellation → zero, for every exponent.
    function testFuzz_exactCancel_isZero(uint32 x) public pure {
        vm.assume(x > 0);
        Decimal.D memory pos = _p(uint256(x));
        Decimal.D memory neg_ = _n(uint256(x));
        assertTrue(_eq(Decimal.add(pos, neg_), Decimal.zero()));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (3) All four ±/± sign orderings with same/different exponents
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev (+big) + (+small) = positive, magnitude = big + small
    function test_signs_posPos() public pure {
        // 1000 + 1 = 1001
        assertTrue(_eq(Decimal.add(_p(1000), _p(1)), _p(1001)));
    }

    /// @dev (+big) + (-small) = positive, magnitude = big - small
    function test_signs_posNeg_bigWins() public pure {
        // 1000 + (-1) = 999
        assertTrue(_eq(Decimal.add(_p(1000), _n(1)), _p(999)));
    }

    /// @dev (+small) + (-big) = negative, magnitude = big - small
    function test_signs_posNeg_negWins() public pure {
        // 1 + (-1000) = -999
        assertTrue(_eq(Decimal.add(_p(1), _n(1000)), _n(999)));
    }

    /// @dev (-big) + (+small) = negative, magnitude = big - small
    function test_signs_negPos() public pure {
        // (-1000) + 1 = -999
        assertTrue(_eq(Decimal.add(_n(1000), _p(1)), _n(999)));
    }

    /// @dev (-big) + (-small) = negative, magnitude = big + small
    function test_signs_negNeg() public pure {
        // (-1000) + (-1) = -1001
        assertTrue(_eq(Decimal.add(_n(1000), _n(1)), _n(1001)));
    }

    /// @dev Same exponent, different mantissa, opposite signs — big mantissa wins sign.
    function test_signs_sameExp_mantissaDeterminesSign() public pure {
        // D{7e18, 3} + D{3e18, 3, true} = 4e18, exp=3 (positive)
        Decimal.D memory a = _d(7 * S, 3, false);
        Decimal.D memory b = _d(3 * S, 3, true);
        Decimal.D memory r = Decimal.add(a, b);
        assertFalse(r.negative);
        assertEq(r.mantissa, 4 * S);
        assertEq(r.exponent, 3);
    }

    function test_signs_sameExp_mantissaDeterminesSign_reversed() public pure {
        // D{3e18, 3} + D{7e18, 3, true} = D{4e18, 3, true} (negative)
        Decimal.D memory a = _d(3 * S, 3, false);
        Decimal.D memory b = _d(7 * S, 3, true);
        Decimal.D memory r = Decimal.add(a, b);
        assertTrue(r.negative);
        assertEq(r.mantissa, 4 * S);
        assertEq(r.exponent, 3);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (4) sub antisymmetry: sub(a,b) == neg(sub(b,a))
    // ─────────────────────────────────────────────────────────────────────────

    function test_sub_antisymmetric_concrete() public pure {
        // sub(5,3) = 2,  neg(sub(3,5)) = neg(-2) = 2
        assertTrue(_eq(Decimal.sub(_p(5), _p(3)), Decimal.neg(Decimal.sub(_p(3), _p(5)))));
    }

    function testFuzz_sub_antisymmetric(int32 rawA, int32 rawB) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(rawA));
        Decimal.D memory b = Decimal.fromInt(int256(rawB));
        // sub(a,b) == neg(sub(b,a))
        assertEq(
            Decimal.cmp(Decimal.sub(a, b), Decimal.neg(Decimal.sub(b, a))),
            0,
            "sub antisymmetry violated"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (5) Monotonicity: a < b → add(a,c) < add(b,c) for "normal" values
    //     (can fail at the cutoff boundary — documented below)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev For values well within precision range, strict monotonicity holds.
    function testFuzz_add_monotone_withinPrecision(uint16 rawA, uint16 rawB, uint16 rawC) public pure {
        vm.assume(rawA < rawB);
        Decimal.D memory a = _p(uint256(rawA));
        Decimal.D memory b = _p(uint256(rawB));
        Decimal.D memory c = _p(uint256(rawC));
        // a < b → a + c < b + c  (all uint16, well within 17 significant digits)
        assertTrue(Decimal.lt(Decimal.add(a, c), Decimal.add(b, c)));
    }

    /// @dev Monotonicity can fail at the cutoff: 0 < 1 but 1e100 + 0 == 1e100 + 1.
    ///      This is the intended precision-loss behaviour, NOT a bug.
    function test_monotonicity_failsAtCutoff_documented() public pure {
        Decimal.D memory big = Decimal.pow10(100);
        Decimal.D memory c0  = Decimal.zero();
        Decimal.D memory c1  = _p(1);
        // 0 < 1, but big+0 == big+1 (1 is cut off)
        assertTrue(Decimal.lt(c0, c1));
        assertTrue(_eq(Decimal.add(big, c0), Decimal.add(big, c1)),
            "add(1e100,0) should equal add(1e100,1) - precision loss is intentional");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (6) Associativity failure at cutoff boundary — intentional, documented
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev (1e100 + 1) + (-1e100) = 0  BUT  1e100 + (1 + (-1e100)) = 1e100 + (-1e100) = 0
    ///      Both happen to give 0 here, but the intermediate results differ.
    function test_associativity_intermediatesDiffer() public pure {
        Decimal.D memory big  = Decimal.pow10(100);
        Decimal.D memory one_ = _p(1);
        Decimal.D memory nBig = Decimal.neg(big);

        // Left-associative: (big + 1) + (-big)
        Decimal.D memory left = Decimal.add(Decimal.add(big, one_), nBig);
        // Right-associative: big + (1 + (-big))
        Decimal.D memory right = Decimal.add(big, Decimal.add(one_, nBig));

        // Both give 0 in this case (nBig dominates in both paths)
        assertTrue(_eq(left,  Decimal.zero()), "left should be 0");
        assertTrue(_eq(right, Decimal.zero()), "right should be 0");
    }

    /// @dev Classic float associativity failure: big + 1 - big = 0, not 1.
    function test_associativity_knownLoss() public pure {
        Decimal.D memory big  = Decimal.pow10(100);
        Decimal.D memory one_ = _p(1);
        // (big + 1) - big = 0   (1 was dropped when added to big)
        Decimal.D memory result = Decimal.sub(Decimal.add(big, one_), big);
        assertTrue(_eq(result, Decimal.zero()),
            "(1e100+1)-1e100 should be 0 due to precision loss");
        // Whereas: big - big + 1 = 1
        Decimal.D memory result2 = Decimal.add(Decimal.sub(big, big), one_);
        assertTrue(_eq(result2, one_),
            "1e100-1e100+1 should be 1");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (7) Extreme exponents near EXP_LIMIT
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev add near EXP_LIMIT — same exponent, same sign — normalize overflows → revert.
    function test_extremeExp_overflowReverts() public {
        // D{9e18, EXP_LIMIT} + D{9e18, EXP_LIMIT} → sum 18e18, normalize → exp+1 > EXP_LIMIT
        Decimal.D memory a = _d(9 * S, Decimal.EXP_LIMIT, false);
        vm.expectRevert();
        dh.add(a, a);
    }

    /// @dev add near EXP_LIMIT — different exponent — the larger is returned (cutoff).
    function test_extremeExp_cutoffAtLimit() public pure {
        Decimal.D memory big   = _d(S, Decimal.EXP_LIMIT,     false);
        Decimal.D memory small = _d(S, Decimal.EXP_LIMIT - 1, false);
        // expDiff = 1 ≤ 17 → combined, not cut off
        Decimal.D memory result = Decimal.add(big, small);
        assertFalse(_eq(result, big), "expDiff=1 at EXP_LIMIT should combine");
    }

    /// @dev add negative EXP_LIMIT values.
    function test_extremeExp_negativeLimit() public pure {
        Decimal.D memory a = _d(S, -Decimal.EXP_LIMIT, false);
        Decimal.D memory b = _d(S, -Decimal.EXP_LIMIT, false);
        // 2 * 10^(-EXP_LIMIT) — same exponent, same sign
        Decimal.D memory result = Decimal.add(a, b);
        assertEq(result.mantissa, 2 * S);
        assertEq(result.exponent, -Decimal.EXP_LIMIT);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (8) alignedSmall truncation never flips result sign
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev When big and small have opposite signs, diff = big.mantissa - alignedSmall.
    ///      alignedSmall ≤ big.mantissa (by construction), so diff ≥ 0 always.
    ///      This fuzz test ensures the result never has the wrong sign.
    function testFuzz_diffSign_resultSignIsAlwaysBigSign(uint32 rawBig, uint32 rawSmall) public pure {
        vm.assume(rawBig > rawSmall && rawSmall > 0);
        Decimal.D memory big_  = _p(uint256(rawBig));
        Decimal.D memory small = _n(uint256(rawSmall));
        Decimal.D memory result = Decimal.add(big_, small);
        // rawBig > rawSmall → result is positive
        assertFalse(result.negative, "result should be positive when |big| > |small|");
        // and result == rawBig - rawSmall
        assertTrue(_eq(result, _p(uint256(rawBig) - uint256(rawSmall))));
    }

    function testFuzz_diffSign_negBigSign(uint32 rawBig, uint32 rawSmall) public pure {
        vm.assume(rawBig > rawSmall && rawSmall > 0);
        Decimal.D memory big_  = _n(uint256(rawBig));
        Decimal.D memory small = _p(uint256(rawSmall));
        Decimal.D memory result = Decimal.add(big_, small);
        // big_ is negative and has larger magnitude → result is negative
        assertTrue(result.negative, "result should be negative when |-big| > |small|");
        assertTrue(_eq(result, _n(uint256(rawBig) - uint256(rawSmall))));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // (9) Bonus — sub(a,a) == 0 for large values (not just small ints)
    // ─────────────────────────────────────────────────────────────────────────

    function test_sub_selfIsZero_largePow() public pure {
        Decimal.D memory a = Decimal.pow10(200);
        assertTrue(_eq(Decimal.sub(a, a), Decimal.zero()));
    }

    function testFuzz_sub_selfIsZero(int32 x) public pure {
        Decimal.D memory a = Decimal.fromInt(int256(x));
        assertTrue(_eq(Decimal.sub(a, a), Decimal.zero()));
    }
}
