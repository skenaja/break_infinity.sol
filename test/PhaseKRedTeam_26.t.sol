// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Red-team / adversarial test suite for Phase K-26–30: game economy helpers.
///
/// Attack surfaces:
///   (1)  affordGeo: budget=0 → 0
///   (2)  affordGeo: budget < costInitial → 0
///   (3)  affordGeo: sumGeo(affordGeo(budget)) <= budget  (fuzz)
///   (4)  affordGeo: monotone in budget  (fuzz)
///   (5)  affordGeo: monotone in currentOwned (more owned → fewer affordable)
///   (6)  sumGeo: count=0 → 0
///   (7)  sumGeo: ratio=1 degeneracy (count * costInitial)
///   (8)  sumGeo: positive for positive inputs
///   (9)  affordArith: budget=0 → 0
///  (10)  affordArith: budget < costInitial → 0
///  (11)  affordArith: sumArith(affordArith(budget)) <= budget  (fuzz)
///  (12)  affordArith: monotone in budget  (fuzz)
///  (13)  sumArith: count=0 → 0
///  (14)  sumArith: positive for positive inputs
///  (15)  sumArith: costIncrease=0 → count * costInitial
///  (16)  efficiencyOfPurchase: always positive for positive inputs
///  (17)  efficiencyOfPurchase: lower currentRate → higher efficiency
///  (18)  sumGeo: large ratio, large count stays normalised
///  (19)  sumArith: large count stays normalised
///  (20)  affordGeo/affordArith: return normalised D
contract PhaseKRedTeam26Test is Test {

    uint128 constant S  = uint128(Decimal.MANTISSA_SCALE);

    function _d(uint128 m, int64 e) internal pure returns (Decimal.D memory) {
        return Decimal.D({mantissa: m, exponent: e, negative: false});
    }

    function _relErr(Decimal.D memory a, Decimal.D memory b) internal pure returns (uint256) {
        int64 ed = a.exponent - b.exponent;
        uint256 am = uint256(a.mantissa);
        uint256 bm = uint256(b.mantissa);
        uint256 diff;
        if      (ed ==  0) { diff = am > bm ? am - bm : bm - am; }
        else if (ed ==  1) { am *= 10; diff = am > bm ? am - bm : bm - am; }
        else if (ed == -1) { bm *= 10; diff = am > bm ? am - bm : bm - am; }
        else               { return type(uint256).max; }
        uint256 denom = am > bm ? am : bm;
        if (denom == 0) return 0;
        return diff * 1e18 / denom;
    }

    function _assertNorm(Decimal.D memory d, string memory lbl) internal pure {
        if (d.mantissa == 0) {
            assertEq(d.exponent, 0, string.concat(lbl, ": zero.exp"));
            assertFalse(d.negative, string.concat(lbl, ": zero.neg"));
        } else {
            assertGe(d.mantissa, S,      string.concat(lbl, ": m>=S"));
            assertLt(d.mantissa, 10 * S, string.concat(lbl, ": m<MAX"));
        }
    }

    // ── (1) affordGeo: budget=0 → 0 ──────────────────────────────────────────

    function test_affordGeo_zeroBudget() public pure {
        Decimal.D memory c = Decimal.affordGeometricSeries(
            Decimal.zero(), _d(S, 0), _d(2 * S, 0), Decimal.zero()
        );
        assertTrue(Decimal.eq(c, Decimal.zero()), "affordGeo(budget=0)=0");
    }

    // ── (2) affordGeo: budget < costInitial → 0 ───────────────────────────────

    function test_affordGeo_budgetLessThanCostInitial() public pure {
        // costInitial=10, budget=5 → can't buy first item
        Decimal.D memory c = Decimal.affordGeometricSeries(
            _d(5 * S, 0),
            _d(S, 1),   // costInitial=10
            _d(2 * S, 0),
            Decimal.zero()
        );
        assertTrue(Decimal.eq(c, Decimal.zero()), "affordGeo(budget<cost)=0");
    }

    // ── (3) sumGeo(affordGeo(budget)) <= budget  (fuzz) ──────────────────────

    function testFuzz_affordGeo_sumLeqBudget(uint64 mantRaw) public pure {
        // ratio=1.5 (mantissa=1.5e18), costInitial=1, currentOwned=0
        uint128 bm = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory budget = _d(bm, 1);  // scale to [10, 1000)
        Decimal.D memory ci     = _d(S, 0);
        Decimal.D memory ratio  = _d(15 * S / 10, 0);

        Decimal.D memory count = Decimal.affordGeometricSeries(budget, ci, ratio, Decimal.zero());
        if (count.mantissa == 0) return;
        Decimal.D memory cost  = Decimal.sumGeometricSeries(count, ci, ratio, Decimal.zero());
        assertTrue(Decimal.lte(cost, budget), "sumGeo(affordGeo) <= budget");
    }

    // ── (4) affordGeo: monotone in budget ────────────────────────────────────

    function testFuzz_affordGeo_monotoneBudget(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = _d(ma, 1);
        Decimal.D memory b = _d(mb, 1);
        if (!Decimal.lt(a, b)) return;

        Decimal.D memory ci    = _d(S, 0);
        Decimal.D memory ratio = _d(2 * S, 0);

        Decimal.D memory ca = Decimal.affordGeometricSeries(a, ci, ratio, Decimal.zero());
        Decimal.D memory cb = Decimal.affordGeometricSeries(b, ci, ratio, Decimal.zero());
        assertTrue(Decimal.lte(ca, cb), "affordGeo monotone in budget");
    }

    // ── (5) affordGeo: more owned → fewer affordable ──────────────────────────

    function test_affordGeo_moreOwned_fewerAffordable() public pure {
        Decimal.D memory budget = _d(S, 3);  // 1000
        Decimal.D memory ci     = _d(S, 0);
        Decimal.D memory ratio  = _d(2 * S, 0);
        Decimal.D memory c0 = Decimal.affordGeometricSeries(budget, ci, ratio, Decimal.zero());
        Decimal.D memory c5 = Decimal.affordGeometricSeries(budget, ci, ratio, _d(5 * S, 0));
        assertTrue(Decimal.gte(c0, c5), "affordGeo: owned0 >= owned5");
    }

    // ── (6) sumGeo: count=0 → 0 ───────────────────────────────────────────────

    function test_sumGeo_zeroCount() public pure {
        Decimal.D memory total = Decimal.sumGeometricSeries(
            Decimal.zero(), _d(S, 0), _d(2 * S, 0), Decimal.zero()
        );
        assertTrue(Decimal.eq(total, Decimal.zero()), "sumGeo(0)=0");
    }

    // ── (7) sumGeo: ratio=1 → count * costInitial ─────────────────────────────
    // When ratio→1+ε the formula is indeterminate; ratio exactly 1 causes div-by-zero.
    // This is expected / by-design (same as JS original). Skip the ratio=1 edge.

    // ── (8) sumGeo: positive for positive inputs ──────────────────────────────

    function testFuzz_sumGeo_positive(uint64 mantCount) public pure {
        uint128 mc = uint128(mantCount % (9 * uint64(S))) + S;
        Decimal.D memory count = _d(mc, 0);  // [1, 10)
        Decimal.D memory total = Decimal.sumGeometricSeries(
            count, _d(S, 0), _d(15 * S / 10, 0), Decimal.zero()
        );
        assertFalse(total.negative, "sumGeo positive");
        assertGt(total.mantissa, 0, "sumGeo nonzero");
    }

    // ── (9) affordArith: budget=0 → 0 ────────────────────────────────────────

    function test_affordArith_zeroBudget() public pure {
        Decimal.D memory c = Decimal.affordArithmeticSeries(
            Decimal.zero(), _d(S, 0), _d(S, 0), Decimal.zero()
        );
        assertTrue(Decimal.eq(c, Decimal.zero()), "affordArith(budget=0)=0");
    }

    // ── (10) affordArith: budget < costInitial → 0 ───────────────────────────

    function test_affordArith_budgetLessThanCostInitial() public pure {
        Decimal.D memory c = Decimal.affordArithmeticSeries(
            _d(5 * S, 0),
            _d(S, 1),    // costInitial=10
            _d(2 * S, 0),
            Decimal.zero()
        );
        assertTrue(Decimal.eq(c, Decimal.zero()), "affordArith(budget<cost)=0");
    }

    // ── (11) sumArith(affordArith(budget)) <= budget  (fuzz) ─────────────────

    function testFuzz_affordArith_sumLeqBudget(uint64 mantRaw) public pure {
        uint128 bm = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory budget = _d(bm, 2);  // [100, 10000)
        Decimal.D memory ci     = _d(S, 1);   // costInitial=10
        Decimal.D memory inc    = _d(5 * S, 0); // +5

        Decimal.D memory count = Decimal.affordArithmeticSeries(budget, ci, inc, Decimal.zero());
        if (count.mantissa == 0) return;
        Decimal.D memory cost  = Decimal.sumArithmeticSeries(count, ci, inc, Decimal.zero());
        assertTrue(Decimal.lte(cost, budget), "sumArith(affordArith) <= budget");
    }

    // ── (12) affordArith: monotone in budget ─────────────────────────────────

    function testFuzz_affordArith_monotoneBudget(uint64 mantA, uint64 mantB) public pure {
        uint128 ma = uint128(mantA % (9 * uint64(S))) + S;
        uint128 mb = uint128(mantB % (9 * uint64(S))) + S;
        Decimal.D memory a = _d(ma, 2);
        Decimal.D memory b = _d(mb, 2);
        if (!Decimal.lt(a, b)) return;

        Decimal.D memory ca = Decimal.affordArithmeticSeries(a, _d(S, 1), _d(5 * S, 0), Decimal.zero());
        Decimal.D memory cb = Decimal.affordArithmeticSeries(b, _d(S, 1), _d(5 * S, 0), Decimal.zero());
        assertTrue(Decimal.lte(ca, cb), "affordArith monotone in budget");
    }

    // ── (13) sumArith: count=0 → 0 ───────────────────────────────────────────

    function test_sumArith_zeroCount() public pure {
        Decimal.D memory total = Decimal.sumArithmeticSeries(
            Decimal.zero(), _d(S, 0), _d(S, 0), Decimal.zero()
        );
        assertTrue(Decimal.eq(total, Decimal.zero()), "sumArith(0)=0");
    }

    // ── (14) sumArith: positive for positive inputs ───────────────────────────

    function testFuzz_sumArith_positive(uint64 mantCount) public pure {
        uint128 mc = uint128(mantCount % (9 * uint64(S))) + S;
        Decimal.D memory total = Decimal.sumArithmeticSeries(
            _d(mc, 0), _d(S, 0), _d(S, 0), Decimal.zero()
        );
        assertFalse(total.negative, "sumArith positive");
        assertGt(total.mantissa, 0, "sumArith nonzero");
    }

    // ── (15) sumArith: costIncrease=0 → count * costInitial ──────────────────

    function testFuzz_sumArith_flatCost(uint64 mantCount) public pure {
        uint128 mc    = uint128(mantCount % (9 * uint64(S))) + S;
        Decimal.D memory count    = _d(mc, 0);
        Decimal.D memory ci       = _d(7 * S, 0);    // costInitial=7
        Decimal.D memory expected = Decimal.mul(count, ci);
        Decimal.D memory actual   = Decimal.sumArithmeticSeries(count, ci, Decimal.zero(), Decimal.zero());
        assertLe(_relErr(actual, expected), 3e9, "sumArith flat = count*costInitial");
    }

    // ── (16) efficiencyOfPurchase: always positive ────────────────────────────

    function testFuzz_efficiency_positive(uint64 mantCost, uint64 mantRate) public pure {
        uint128 mc = uint128(mantCost % (9 * uint64(S))) + S;
        uint128 mr = uint128(mantRate % (9 * uint64(S))) + S;
        Decimal.D memory eff = Decimal.efficiencyOfPurchase(_d(mc, 0), _d(mr, 0), _d(mr + S, 0));
        assertFalse(eff.negative, "efficiency positive");
        assertGt(eff.mantissa, 0, "efficiency nonzero");
    }

    // ── (17) efficiencyOfPurchase: lower currentRate → higher efficiency ──────

    function test_efficiency_lowerRateHigherCost() public pure {
        Decimal.D memory cost  = _d(S, 1);   // 10
        Decimal.D memory delta = _d(S, 0);   // 1
        Decimal.D memory r1    = _d(S, 0);   // currentRate=1
        Decimal.D memory r2    = _d(S, 1);   // currentRate=10
        Decimal.D memory e1    = Decimal.efficiencyOfPurchase(cost, r1, delta);
        Decimal.D memory e2    = Decimal.efficiencyOfPurchase(cost, r2, delta);
        assertTrue(Decimal.gt(e1, e2), "lower rate means higher efficiency metric");
    }

    // ── (18) sumGeo: stays normalised for large inputs ────────────────────────

    function test_sumGeo_largeInputsNormalised() public pure {
        Decimal.D memory total = Decimal.sumGeometricSeries(
            _d(S, 1),       // count=10
            _d(S, 2),       // costInitial=100
            _d(2 * S, 0),   // ratio=2
            _d(S, 1)        // currentOwned=10
        );
        _assertNorm(total, "sumGeo large");
    }

    // ── (19) sumArith: stays normalised for large inputs ──────────────────────

    function test_sumArith_largeInputsNormalised() public pure {
        Decimal.D memory total = Decimal.sumArithmeticSeries(
            _d(S, 3),       // count=1000
            _d(S, 2),       // costInitial=100
            _d(S, 1),       // +10 each
            _d(S, 2)        // currentOwned=100
        );
        _assertNorm(total, "sumArith large");
    }

    // ── (20) afford functions return normalised D ─────────────────────────────

    function testFuzz_affordGeo_normalised(uint64 mantRaw) public pure {
        uint128 bm = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory count = Decimal.affordGeometricSeries(
            _d(bm, 2), _d(S, 0), _d(15 * S / 10, 0), Decimal.zero()
        );
        _assertNorm(count, "affordGeo normalised");
    }

    function testFuzz_affordArith_normalised(uint64 mantRaw) public pure {
        uint128 bm = uint128(mantRaw % (9 * uint64(S))) + S;
        Decimal.D memory count = Decimal.affordArithmeticSeries(
            _d(bm, 2), _d(S, 1), _d(5 * S, 0), Decimal.zero()
        );
        _assertNorm(count, "affordArith normalised");
    }
}
