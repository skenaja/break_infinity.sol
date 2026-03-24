// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Correctness tests for Phase H: floor, ceil, round, trunc.
contract DecimalHTest is Test {

    uint128 constant S = uint128(Decimal.MANTISSA_SCALE);

    // ── helpers ───────────────────────────────────────────────────────────────

    /// Build a D directly (assumes normalised inputs).
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

    // ── zero ─────────────────────────────────────────────────────────────────

    function test_floor_zero()  public pure { assertTrue(Decimal.eq(Decimal.floor(Decimal.zero()), Decimal.zero())); }
    function test_ceil_zero()   public pure { assertTrue(Decimal.eq(Decimal.ceil(Decimal.zero()),  Decimal.zero())); }
    function test_round_zero()  public pure { assertTrue(Decimal.eq(Decimal.round(Decimal.zero()), Decimal.zero())); }
    function test_trunc_zero()  public pure { assertTrue(Decimal.eq(Decimal.trunc(Decimal.zero()), Decimal.zero())); }

    // ── exact integers (no fractional part) ──────────────────────────────────

    function test_floor_integer_pos() public pure {
        // 5.0 — mantissa=5e18, exponent=0
        Decimal.D memory five = _d(5 * S, 0, false);
        assertTrue(Decimal.eq(Decimal.floor(five), five), "floor(5)==5");
    }

    function test_ceil_integer_neg() public pure {
        Decimal.D memory negThree = _d(3 * S, 0, true);
        assertTrue(Decimal.eq(Decimal.ceil(negThree), negThree), "ceil(-3)==-3");
    }

    function test_round_integer() public pure {
        Decimal.D memory seven = _d(7 * S, 0, false);
        assertTrue(Decimal.eq(Decimal.round(seven), seven), "round(7)==7");
    }

    function test_trunc_integer() public pure {
        Decimal.D memory negTwo = _d(2 * S, 0, true);
        assertTrue(Decimal.eq(Decimal.trunc(negTwo), negTwo), "trunc(-2)==-2");
    }

    // ── large values (exponent >= 18, already integer) ─────────────────────

    function test_floor_largeExp() public pure {
        Decimal.D memory big = _d(3_141_592_653_589_793_238, 20, false);
        assertTrue(Decimal.eq(Decimal.floor(big), big), "floor(big)==big");
    }

    function test_ceil_largeNegExp() public pure {
        Decimal.D memory big = _d(2 * S, 25, true);
        assertTrue(Decimal.eq(Decimal.ceil(big), big), "ceil(-big)==-big");
    }

    // ── positive fractions ────────────────────────────────────────────────────

    // 1.3 = mantissa 1.3e18, exponent 0
    function test_floor_1point3() public pure {
        Decimal.D memory a = _d(13 * S / 10, 0, false);
        assertTrue(Decimal.eq(Decimal.floor(a), Decimal.one()), "floor(1.3)==1");
    }

    function test_ceil_1point3() public pure {
        Decimal.D memory a = _d(13 * S / 10, 0, false);
        assertTrue(Decimal.eq(Decimal.ceil(a), _d(2 * S, 0, false)), "ceil(1.3)==2");
    }

    function test_round_1point3() public pure {
        Decimal.D memory a = _d(13 * S / 10, 0, false);
        assertTrue(Decimal.eq(Decimal.round(a), Decimal.one()), "round(1.3)==1");
    }

    function test_trunc_1point3() public pure {
        Decimal.D memory a = _d(13 * S / 10, 0, false);
        assertTrue(Decimal.eq(Decimal.trunc(a), Decimal.one()), "trunc(1.3)==1");
    }

    // 1.7
    function test_floor_1point7() public pure {
        Decimal.D memory a = _d(17 * S / 10, 0, false);
        assertTrue(Decimal.eq(Decimal.floor(a), Decimal.one()), "floor(1.7)==1");
    }

    function test_ceil_1point7() public pure {
        Decimal.D memory a = _d(17 * S / 10, 0, false);
        assertTrue(Decimal.eq(Decimal.ceil(a), _d(2 * S, 0, false)), "ceil(1.7)==2");
    }

    function test_round_1point7() public pure {
        Decimal.D memory a = _d(17 * S / 10, 0, false);
        assertTrue(Decimal.eq(Decimal.round(a), _d(2 * S, 0, false)), "round(1.7)==2");
    }

    function test_trunc_1point7() public pure {
        Decimal.D memory a = _d(17 * S / 10, 0, false);
        assertTrue(Decimal.eq(Decimal.trunc(a), Decimal.one()), "trunc(1.7)==1");
    }

    // 1.5 — tie goes up
    function test_round_1point5() public pure {
        Decimal.D memory a = _d(15 * S / 10, 0, false);
        assertTrue(Decimal.eq(Decimal.round(a), _d(2 * S, 0, false)), "round(1.5)==2");
    }

    // ── negative fractions ────────────────────────────────────────────────────

    // -1.3
    function test_floor_neg1point3() public pure {
        Decimal.D memory a    = _d(13 * S / 10, 0, true);
        Decimal.D memory neg2 = _d(2 * S, 0, true);
        assertTrue(Decimal.eq(Decimal.floor(a), neg2), "floor(-1.3)==-2");
    }

    function test_ceil_neg1point3() public pure {
        Decimal.D memory a    = _d(13 * S / 10, 0, true);
        Decimal.D memory neg1 = _d(S, 0, true);
        assertTrue(Decimal.eq(Decimal.ceil(a), neg1), "ceil(-1.3)==-1");
    }

    function test_round_neg1point3() public pure {
        Decimal.D memory a    = _d(13 * S / 10, 0, true);
        Decimal.D memory neg1 = _d(S, 0, true);
        assertTrue(Decimal.eq(Decimal.round(a), neg1), "round(-1.3)==-1");
    }

    function test_trunc_neg1point3() public pure {
        Decimal.D memory a    = _d(13 * S / 10, 0, true);
        Decimal.D memory neg1 = _d(S, 0, true);
        assertTrue(Decimal.eq(Decimal.trunc(a), neg1), "trunc(-1.3)==-1");
    }

    // -1.7
    function test_floor_neg1point7() public pure {
        Decimal.D memory a    = _d(17 * S / 10, 0, true);
        Decimal.D memory neg2 = _d(2 * S, 0, true);
        assertTrue(Decimal.eq(Decimal.floor(a), neg2), "floor(-1.7)==-2");
    }

    function test_ceil_neg1point7() public pure {
        Decimal.D memory a    = _d(17 * S / 10, 0, true);
        Decimal.D memory neg1 = _d(S, 0, true);
        assertTrue(Decimal.eq(Decimal.ceil(a), neg1), "ceil(-1.7)==-1");
    }

    function test_round_neg1point7() public pure {
        Decimal.D memory a    = _d(17 * S / 10, 0, true);
        Decimal.D memory neg2 = _d(2 * S, 0, true);
        assertTrue(Decimal.eq(Decimal.round(a), neg2), "round(-1.7)==-2");
    }

    function test_trunc_neg1point7() public pure {
        Decimal.D memory a    = _d(17 * S / 10, 0, true);
        Decimal.D memory neg1 = _d(S, 0, true);
        assertTrue(Decimal.eq(Decimal.trunc(a), neg1), "trunc(-1.7)==-1");
    }

    // -0.5 — ties round up (toward +∞), so round(-0.5) = 0
    function test_round_neg0point5() public pure {
        Decimal.D memory a = _d(5 * S, -1, true);
        assertTrue(Decimal.eq(Decimal.round(a), Decimal.zero()), "round(-0.5)==0");
    }

    // ── values in (0, 1) ─────────────────────────────────────────────────────

    // 0.3 — exponent=-1, mantissa=3e18
    function test_floor_0point3()  public pure { assertTrue(Decimal.eq(Decimal.floor(_d(3 * S, -1, false)), Decimal.zero()), "floor(0.3)==0"); }
    function test_ceil_0point3()   public pure { assertTrue(Decimal.eq(Decimal.ceil(_d(3 * S, -1, false)),  Decimal.one()),  "ceil(0.3)==1");  }
    function test_round_0point3()  public pure { assertTrue(Decimal.eq(Decimal.round(_d(3 * S, -1, false)), Decimal.zero()), "round(0.3)==0"); }
    function test_trunc_0point3()  public pure { assertTrue(Decimal.eq(Decimal.trunc(_d(3 * S, -1, false)), Decimal.zero()), "trunc(0.3)==0"); }

    // 0.7 — rounds up
    function test_round_0point7()  public pure { assertTrue(Decimal.eq(Decimal.round(_d(7 * S, -1, false)), Decimal.one()),  "round(0.7)==1");  }

    // ── values in (-1, 0) ────────────────────────────────────────────────────

    // -0.3
    function test_floor_neg0point3()  public pure { assertTrue(Decimal.eq(Decimal.floor(_d(3 * S, -1, true)), _d(S, 0, true)), "floor(-0.3)==-1"); }
    function test_ceil_neg0point3()   public pure { assertTrue(Decimal.eq(Decimal.ceil(_d(3 * S, -1, true)),  Decimal.zero()), "ceil(-0.3)==0");   }
    function test_round_neg0point3()  public pure { assertTrue(Decimal.eq(Decimal.round(_d(3 * S, -1, true)), Decimal.zero()), "round(-0.3)==0");  }
    function test_trunc_neg0point3()  public pure { assertTrue(Decimal.eq(Decimal.trunc(_d(3 * S, -1, true)), Decimal.zero()), "trunc(-0.3)==0");  }

    // -0.7 — rounds down
    function test_round_neg0point7()  public pure { assertTrue(Decimal.eq(Decimal.round(_d(7 * S, -1, true)), _d(S, 0, true)), "round(-0.7)==-1"); }

    // ── very small values (exponent < -1) — all round to 0 or ±1 ────────────

    function test_floor_tiny_pos()  public pure { assertTrue(Decimal.eq(Decimal.floor(_d(5 * S, -5, false)), Decimal.zero())); }
    function test_ceil_tiny_pos()   public pure { assertTrue(Decimal.eq(Decimal.ceil(_d(5 * S, -5, false)),  Decimal.one()));  }
    function test_round_tiny_pos()  public pure { assertTrue(Decimal.eq(Decimal.round(_d(5 * S, -5, false)), Decimal.zero())); }
    function test_trunc_tiny_pos()  public pure { assertTrue(Decimal.eq(Decimal.trunc(_d(5 * S, -5, false)), Decimal.zero())); }

    function test_floor_tiny_neg()  public pure { assertTrue(Decimal.eq(Decimal.floor(_d(5 * S, -5, true)), _d(S, 0, true))); }
    function test_ceil_tiny_neg()   public pure { assertTrue(Decimal.eq(Decimal.ceil(_d(5 * S, -5, true)),  Decimal.zero())); }
    function test_round_tiny_neg()  public pure { assertTrue(Decimal.eq(Decimal.round(_d(5 * S, -5, true)), Decimal.zero())); }
    function test_trunc_tiny_neg()  public pure { assertTrue(Decimal.eq(Decimal.trunc(_d(5 * S, -5, true)), Decimal.zero())); }

    // ── fuzz: invariants ─────────────────────────────────────────────────────

    function _fuzzD(uint64 mantRaw, int8 expRaw, bool neg) internal pure returns (Decimal.D memory) {
        uint128 m = uint128(mantRaw % (9 * uint64(S))) + S;
        return Decimal.D({mantissa: m, exponent: int64(expRaw), negative: neg});
    }

    /// floor(a) <= a <= ceil(a)
    function testFuzz_floor_le_ceil(uint64 mantRaw, int8 expRaw) public pure {
        Decimal.D memory a = _fuzzD(mantRaw, expRaw, false);
        assertTrue(Decimal.lte(Decimal.floor(a), a),    "floor(a) <= a");
        assertTrue(Decimal.lte(a, Decimal.ceil(a)),     "a <= ceil(a)");
    }

    /// trunc is between floor and ceil
    function testFuzz_trunc_between_floor_ceil(uint64 mantRaw, int8 expRaw, bool neg) public pure {
        Decimal.D memory a = _fuzzD(mantRaw, expRaw, neg);
        Decimal.D memory f = Decimal.floor(a);
        Decimal.D memory c = Decimal.ceil(a);
        Decimal.D memory t = Decimal.trunc(a);
        assertTrue(Decimal.lte(f, t), "floor(a) <= trunc(a)");
        assertTrue(Decimal.lte(t, c), "trunc(a) <= ceil(a)");
    }

    /// round returns either floor or ceil
    function testFuzz_round_is_floor_or_ceil(uint64 mantRaw, int8 expRaw, bool neg) public pure {
        Decimal.D memory a = _fuzzD(mantRaw, expRaw, neg);
        Decimal.D memory r = Decimal.round(a);
        bool isFloor = Decimal.eq(r, Decimal.floor(a));
        bool isCeil  = Decimal.eq(r, Decimal.ceil(a));
        assertTrue(isFloor || isCeil, "round(a) must be floor or ceil");
    }

    /// floor(n) == n for integer n (exponent=0, mantissa divisible by SCALE)
    function testFuzz_floor_integer_fixpoint(uint8 n) public pure {
        if (n == 0) return;
        Decimal.D memory a = Decimal.fromUint(n);
        assertTrue(Decimal.eq(Decimal.floor(a), a),  "floor(integer)==integer");
        assertTrue(Decimal.eq(Decimal.ceil(a), a),   "ceil(integer)==integer");
        assertTrue(Decimal.eq(Decimal.round(a), a),  "round(integer)==integer");
        assertTrue(Decimal.eq(Decimal.trunc(a), a),  "trunc(integer)==integer");
    }

    /// All outputs are normalised
    function testFuzz_outputs_normalised(uint64 mantRaw, int8 expRaw, bool neg) public pure {
        Decimal.D memory a = _fuzzD(mantRaw, expRaw, neg);
        _assertNorm(Decimal.floor(a), "floor");
        _assertNorm(Decimal.ceil(a),  "ceil");
        _assertNorm(Decimal.round(a), "round");
        _assertNorm(Decimal.trunc(a), "trunc");
    }

    /// ceil(a) - floor(a) is 0 or 1
    function testFuzz_ceil_minus_floor_is_0_or_1(uint64 mantRaw, int8 expRaw) public pure {
        Decimal.D memory a  = _fuzzD(mantRaw, expRaw, false);
        Decimal.D memory f  = Decimal.floor(a);
        Decimal.D memory c  = Decimal.ceil(a);
        Decimal.D memory diff = Decimal.sub(c, f);
        assertTrue(
            Decimal.eq(diff, Decimal.zero()) || Decimal.eq(diff, Decimal.one()),
            "ceil(a) - floor(a) must be 0 or 1"
        );
    }
}
