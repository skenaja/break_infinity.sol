// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Red-team / adversarial test suite for Phase H-23: floor, ceil, round, trunc.
///
/// Attack surfaces:
///   (1)  Zero: all four return zero
///   (2)  Exact integers: all four are identity
///   (3)  Large exponent (e >= 18): all four return a unchanged
///   (4)  Values in (0, 1):  floor=0, ceil=1, trunc=0, round depends on >=0.5
///   (5)  Values in (-1, 0): floor=-1, ceil=0, trunc=0, round depends on |v|>=0.5
///   (6)  Very small positive (|e| > 18): floor=0, ceil=1, round=0, trunc=0
///   (7)  Very small negative (|e| > 18): floor=-1, ceil=0, round=0, trunc=0
///   (8)  Fractional positive (e in [0,18)): floor < a <= ceil  (fuzz)
///   (9)  Fractional negative (e in [0,18)): floor <= a < ceil  (fuzz)
///  (10)  ceil(a) - floor(a) in {0, 1}  (fuzz)
///  (11)  trunc is between floor and ceil  (fuzz)
///  (12)  round is floor or ceil  (fuzz)
///  (13)  floor(a) <= a <= ceil(a)  (all exponents, pos and neg)  (fuzz)
///  (14)  Tie-breaking: round(n + 0.5) = n+1  (half-up, positive)  (fuzz)
///  (15)  Tie-breaking: round(-(n+0.5)) = -n  (half-up toward +∞, negative)  (fuzz)
///  (16)  floor = trunc for positive; floor <= trunc for negative  (fuzz)
///  (17)  ceil = trunc for positive non-integer?  No — ceil = trunc+1 if fractional
///         Correct: trunc = ceil for negative non-integers  (fuzz)
///  (18)  All outputs always normalised  (fuzz)
///  (19)  Idempotency: floor(floor(a)) = floor(a)  (fuzz)
///  (20)  Monotonicity: a < b => floor(a) <= floor(b)  (fuzz)
contract PhaseHRedTeam23Test is Test {

    uint128 constant S  = uint128(Decimal.MANTISSA_SCALE);
    int64   constant EL = Decimal.EXP_LIMIT;

    // ── helpers ──────────────────────────────────────────────────────────────

    function _d(uint128 m, int64 e, bool neg) internal pure returns (Decimal.D memory) {
        return Decimal.D({mantissa: m, exponent: e, negative: neg});
    }

    function _assertNorm(Decimal.D memory d, string memory lbl) internal pure {
        if (d.mantissa == 0) {
            assertEq(d.exponent, 0,  string.concat(lbl, ": zero.exp"));
            assertFalse(d.negative,  string.concat(lbl, ": zero.neg"));
        } else {
            assertGe(d.mantissa, S,      string.concat(lbl, ": mantissa >= S"));
            assertLt(d.mantissa, 10 * S, string.concat(lbl, ": mantissa < MAX"));
        }
    }

    // ── (1) Zero ─────────────────────────────────────────────────────────────

    function test_allOps_zero() public pure {
        assertTrue(Decimal.eq(Decimal.floor(Decimal.zero()), Decimal.zero()),  "floor(0)");
        assertTrue(Decimal.eq(Decimal.ceil(Decimal.zero()),  Decimal.zero()),  "ceil(0)");
        assertTrue(Decimal.eq(Decimal.round(Decimal.zero()), Decimal.zero()),  "round(0)");
        assertTrue(Decimal.eq(Decimal.trunc(Decimal.zero()), Decimal.zero()),  "trunc(0)");
    }

    // ── (2) Exact integers ────────────────────────────────────────────────────

    function testFuzz_integers_areIdentity(uint8 nRaw) public pure {
        if (nRaw == 0) return;
        Decimal.D memory n = Decimal.fromUint(nRaw);
        assertTrue(Decimal.eq(Decimal.floor(n), n),  "floor(n)==n");
        assertTrue(Decimal.eq(Decimal.ceil(n),  n),  "ceil(n)==n");
        assertTrue(Decimal.eq(Decimal.round(n), n),  "round(n)==n");
        assertTrue(Decimal.eq(Decimal.trunc(n), n),  "trunc(n)==n");
    }

    function testFuzz_negIntegers_areIdentity(uint8 nRaw) public pure {
        if (nRaw == 0) return;
        Decimal.D memory n = Decimal.neg(Decimal.fromUint(nRaw));
        assertTrue(Decimal.eq(Decimal.floor(n), n),  "floor(-n)==-n");
        assertTrue(Decimal.eq(Decimal.ceil(n),  n),  "ceil(-n)==-n");
        assertTrue(Decimal.eq(Decimal.round(n), n),  "round(-n)==-n");
        assertTrue(Decimal.eq(Decimal.trunc(n), n),  "trunc(-n)==-n");
    }

    // ── (3) Large exponent (e >= 18) ──────────────────────────────────────────

    function testFuzz_largeExp_identity(uint64 mantRaw, uint8 expAdd) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = 18 + int64(uint64(expAdd) % 100);
        Decimal.D memory a = _d(m, e, false);
        assertTrue(Decimal.eq(Decimal.floor(a), a), "floor(largeExp)==a");
        assertTrue(Decimal.eq(Decimal.ceil(a),  a), "ceil(largeExp)==a");
        assertTrue(Decimal.eq(Decimal.round(a), a), "round(largeExp)==a");
        assertTrue(Decimal.eq(Decimal.trunc(a), a), "trunc(largeExp)==a");
    }

    // ── (4) Values in (0,1): floor=0, ceil=1, trunc=0 ────────────────────────

    function testFuzz_posLtOne_floorZero(uint64 mantRaw, uint8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = -(int64(uint64(expRaw) % 50) + 1);
        Decimal.D memory a = _d(m, e, false);
        assertTrue(Decimal.eq(Decimal.floor(a), Decimal.zero()), "floor((0,1))==0");
        assertTrue(Decimal.eq(Decimal.ceil(a),  Decimal.one()),  "ceil((0,1))==1");
        assertTrue(Decimal.eq(Decimal.trunc(a), Decimal.zero()), "trunc((0,1))==0");
    }

    // ── (5) Values in (-1,0): floor=-1, ceil=0, trunc=0 ──────────────────────

    function testFuzz_negLtOne_floorNegOne(uint64 mantRaw, uint8 expRaw) public pure {
        uint128 m  = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e  = -(int64(uint64(expRaw) % 50) + 1);
        Decimal.D memory a    = _d(m, e, true);
        Decimal.D memory neg1 = _d(S, 0, true);
        assertTrue(Decimal.eq(Decimal.floor(a), neg1),          "floor((-1,0))==-1");
        assertTrue(Decimal.eq(Decimal.ceil(a),  Decimal.zero()), "ceil((-1,0))==0");
        assertTrue(Decimal.eq(Decimal.trunc(a), Decimal.zero()), "trunc((-1,0))==0");
    }

    // ── (6) Very small positive (|e| > 18) ───────────────────────────────────

    function testFuzz_verySmallPos(uint64 mantRaw, uint8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e = -(int64(uint64(expRaw) % 100) + 19);
        Decimal.D memory a = _d(m, e, false);
        assertTrue(Decimal.eq(Decimal.floor(a), Decimal.zero()), "floor(vsmall+)==0");
        assertTrue(Decimal.eq(Decimal.ceil(a),  Decimal.one()),  "ceil(vsmall+)==1");
        assertTrue(Decimal.eq(Decimal.round(a), Decimal.zero()), "round(vsmall+)==0");
        assertTrue(Decimal.eq(Decimal.trunc(a), Decimal.zero()), "trunc(vsmall+)==0");
    }

    // ── (7) Very small negative (|e| > 18) ───────────────────────────────────

    function testFuzz_verySmallNeg(uint64 mantRaw, uint8 expRaw) public pure {
        uint128 m  = uint128(mantRaw % (9 * uint64(S))) + S;
        int64   e  = -(int64(uint64(expRaw) % 100) + 19);
        Decimal.D memory a    = _d(m, e, true);
        Decimal.D memory neg1 = _d(S, 0, true);
        assertTrue(Decimal.eq(Decimal.floor(a), neg1),           "floor(vsmall-)==-1");
        assertTrue(Decimal.eq(Decimal.ceil(a),  Decimal.zero()),  "ceil(vsmall-)==0");
        assertTrue(Decimal.eq(Decimal.round(a), Decimal.zero()),  "round(vsmall-)==0");
        assertTrue(Decimal.eq(Decimal.trunc(a), Decimal.zero()),  "trunc(vsmall-)==0");
    }

    // ── (8)+(9) floor <= a <= ceil (general) ─────────────────────────────────

    function testFuzz_floor_le_a_le_ceil(uint64 mantRaw, int8 expRaw, bool neg) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: neg});
        assertTrue(Decimal.lte(Decimal.floor(a), a),         "floor(a) <= a");
        assertTrue(Decimal.lte(a, Decimal.ceil(a)),          "a <= ceil(a)");
    }

    // ── (10) ceil - floor in {0, 1} ───────────────────────────────────────────

    function testFuzz_ceil_minus_floor(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory a    = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: false});
        Decimal.D memory diff = Decimal.sub(Decimal.ceil(a), Decimal.floor(a));
        assertTrue(
            Decimal.eq(diff, Decimal.zero()) || Decimal.eq(diff, Decimal.one()),
            "ceil-floor must be 0 or 1"
        );
    }

    // ── (11) trunc between floor and ceil ─────────────────────────────────────

    function testFuzz_trunc_between(uint64 mantRaw, int8 expRaw, bool neg) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: neg});
        assertTrue(Decimal.lte(Decimal.floor(a), Decimal.trunc(a)), "floor <= trunc");
        assertTrue(Decimal.lte(Decimal.trunc(a), Decimal.ceil(a)),  "trunc <= ceil");
    }

    // ── (12) round is floor or ceil ───────────────────────────────────────────

    function testFuzz_round_floorOrCeil(uint64 mantRaw, int8 expRaw, bool neg) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: neg});
        Decimal.D memory r = Decimal.round(a);
        assertTrue(
            Decimal.eq(r, Decimal.floor(a)) || Decimal.eq(r, Decimal.ceil(a)),
            "round must be floor or ceil"
        );
    }

    // ── (13) floor <= a <= ceil (with negative inputs too) ───────────────────
    // Already covered by (8)+(9) above with neg param.

    // ── (14) Tie-breaking positive: round(n + 0.5) = n+1 ────────────────────

    function testFuzz_round_tie_positive(uint8 nRaw) public pure {
        // Build n + 0.5: mantissa = (n + 0.5) * S. For small n, use fromUint + 0.5.
        // Easier: value = (2n+1) / 2 = D{(2*n+1)*S, 0} / 2 — but let's just construct directly.
        // n + 0.5 with n in [0,9]: mantissa = (n*10 + 5) * S / 10, exponent = 0
        uint128 n = uint128(nRaw % 9); // n in [0,8]
        // mantissa for n + 0.5:
        uint128 m = (n * 10 + 5) * S / 10; // e.g. n=1: m=15e17=1.5e18
        Decimal.D memory a     = _d(m, 0, false);
        Decimal.D memory nPlus1 = Decimal.fromUint(n + 1);
        assertTrue(Decimal.eq(Decimal.round(a), nPlus1),
            "round(n+0.5) == n+1 (half-up)");
    }

    // ── (15) Tie-breaking negative: round(-(n+0.5)) = -n ─────────────────────

    function testFuzz_round_tie_negative(uint8 nRaw) public pure {
        uint128 n = uint128(nRaw % 9);
        uint128 m = (n * 10 + 5) * S / 10;
        Decimal.D memory a = _d(m, 0, true); // -(n + 0.5)
        // Half-up (toward +∞): -(n+0.5) rounds to -n
        Decimal.D memory expected = n == 0 ? Decimal.zero() : Decimal.neg(Decimal.fromUint(n));
        assertTrue(Decimal.eq(Decimal.round(a), expected),
            "round(-(n+0.5)) == -n (half-up)");
    }

    // ── (16) floor = trunc for positive; floor <= trunc for negative ──────────

    function testFuzz_floor_trunc_positive(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: false});
        assertTrue(Decimal.eq(Decimal.floor(a), Decimal.trunc(a)), "floor==trunc for positive");
    }

    function testFuzz_floor_le_trunc_negative(uint64 mantRaw, int8 expRaw) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: true});
        assertTrue(Decimal.lte(Decimal.floor(a), Decimal.trunc(a)), "floor <= trunc for negative");
    }

    // ── (17) trunc = ceil for negative non-integers ───────────────────────────

    function testFuzz_trunc_eq_ceil_negative(uint64 mantRaw, uint8 expAdd) public pure {
        // Use exponent in [0, 17] to guarantee a non-integer fractional negative.
        uint128 m = uint128(mantRaw % (8 * uint64(S))) + 2 * S; // m in [2S, 10S), so always has frac
        int64   e = int64(uint64(expAdd) % 18);                  // exponent in [0,17]
        Decimal.D memory a = _d(m, e, true);
        // Negative non-integer: trunc rounds toward zero = ceil
        assertTrue(Decimal.eq(Decimal.trunc(a), Decimal.ceil(a)), "trunc == ceil for neg non-int");
    }

    // ── (18) All outputs normalised ───────────────────────────────────────────

    function testFuzz_normalised(uint64 mantRaw, int8 expRaw, bool neg) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: neg});
        _assertNorm(Decimal.floor(a), "floor");
        _assertNorm(Decimal.ceil(a),  "ceil");
        _assertNorm(Decimal.round(a), "round");
        _assertNorm(Decimal.trunc(a), "trunc");
    }

    // ── (19) Idempotency: floor(floor(a)) = floor(a) ─────────────────────────

    function testFuzz_idempotent(uint64 mantRaw, int8 expRaw, bool neg) public pure {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: m, exponent: int64(expRaw), negative: neg});
        Decimal.D memory f = Decimal.floor(a);
        Decimal.D memory c = Decimal.ceil(a);
        Decimal.D memory r = Decimal.round(a);
        Decimal.D memory t = Decimal.trunc(a);
        assertTrue(Decimal.eq(Decimal.floor(f), f), "floor idempotent");
        assertTrue(Decimal.eq(Decimal.ceil(c),  c), "ceil idempotent");
        assertTrue(Decimal.eq(Decimal.round(r), r), "round idempotent");
        assertTrue(Decimal.eq(Decimal.trunc(t), t), "trunc idempotent");
    }

    // ── (20) Monotonicity: a < b => floor(a) <= floor(b) ─────────────────────

    function testFuzz_floor_monotone(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = Decimal.D({mantissa: ma, exponent: 0, negative: false});
        Decimal.D memory b = Decimal.D({mantissa: mb, exponent: 0, negative: false});
        if (!Decimal.lt(a, b)) return;
        assertTrue(Decimal.lte(Decimal.floor(a), Decimal.floor(b)), "floor monotone");
        assertTrue(Decimal.lte(Decimal.ceil(a),  Decimal.ceil(b)),  "ceil monotone");
    }
}
