// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Decimal} from "../src/Decimal.sol";

/// @notice Correctness tests for Phase K: game economy helpers.
contract DecimalKTest is Test {

    uint128 constant S = uint128(Decimal.MANTISSA_SCALE);

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

    // ── efficiencyOfPurchase ──────────────────────────────────────────────────

    function test_efficiency_basic() public pure {
        // cost=10, currentRate=2, deltaRate=5
        // efficiency = 10/2 + 10/5 = 5 + 2 = 7
        Decimal.D memory cost  = _d(S, 1);   // 10
        Decimal.D memory r1    = _d(2 * S, 0); // 2
        Decimal.D memory r2    = _d(5 * S, 0); // 5
        Decimal.D memory seven = _d(7 * S, 0);
        Decimal.D memory eff   = Decimal.efficiencyOfPurchase(cost, r1, r2);
        assertLe(_relErr(eff, seven), 2e9, "efficiency basic");
    }

    function test_efficiency_symmetric() public pure {
        // cost/r1 + cost/r2 == cost/r2 + cost/r1 (trivially, but verifies no side effects)
        Decimal.D memory cost = _d(3 * S, 0);
        Decimal.D memory r1   = _d(4 * S, 0);
        Decimal.D memory r2   = _d(6 * S, 0);
        Decimal.D memory e1   = Decimal.efficiencyOfPurchase(cost, r1, r2);
        Decimal.D memory e2   = Decimal.efficiencyOfPurchase(cost, r2, r1);
        assertLe(_relErr(e1, e2), 2e9, "efficiency symmetric");
    }

    // ── sumGeometricSeries ────────────────────────────────────────────────────

    function test_sumGeo_zeroCount_isZero() public pure {
        // buying 0 items costs 0
        Decimal.D memory total = Decimal.sumGeometricSeries(
            Decimal.zero(),
            _d(S, 0),    // costInitial=1
            _d(107 * S / 100, 0), // ratio=1.07  (approx)
            Decimal.zero()
        );
        assertTrue(Decimal.eq(total, Decimal.zero()), "sum(0 items)=0");
    }

    function test_sumGeo_oneItem_equalsCostAtCurrentOwned() public pure {
        // sumGeo(count=1, costInitial=1, ratio=2, currentOwned=3)
        // = 1 * 2^3 * (2^1 - 1) / (2 - 1) = 8 * 1 / 1 = 8
        Decimal.D memory total = Decimal.sumGeometricSeries(
            Decimal.one(),
            Decimal.one(),
            _d(2 * S, 0),
            _d(3 * S, 0)
        );
        Decimal.D memory expected = _d(8 * S, 0);
        assertLe(_relErr(total, expected), 3e9, "sum(1 item at slot 3) = 8");
    }

    function test_sumGeo_twoItems_knownValue() public pure {
        // sumGeo(count=2, costInitial=1, ratio=2, currentOwned=0)
        // = 1 * 2^0 * (2^2 - 1) / (2 - 1) = 1 * 3 / 1 = 3
        Decimal.D memory total = Decimal.sumGeometricSeries(
            _d(2 * S, 0),
            Decimal.one(),
            _d(2 * S, 0),
            Decimal.zero()
        );
        Decimal.D memory expected = _d(3 * S, 0);
        assertLe(_relErr(total, expected), 3e9, "sum(2 items, ratio=2) = 3");
    }

    function test_sumGeo_knownValue_threeItems() public pure {
        // sumGeo(count=3, costInitial=1, ratio=2, currentOwned=1)
        // = 1 * 2^1 * (2^3 - 1) / (2 - 1) = 2 * 7 / 1 = 14
        Decimal.D memory total = Decimal.sumGeometricSeries(
            _d(3 * S, 0),
            Decimal.one(),
            _d(2 * S, 0),
            Decimal.one()
        );
        assertLe(_relErr(total, _d(14 * S, 0)), 3e9, "sumGeo(3 items, owned=1) = 14");
    }

    // ── sumArithmeticSeries ───────────────────────────────────────────────────

    function test_sumArith_zeroCount_isZero() public pure {
        Decimal.D memory total = Decimal.sumArithmeticSeries(
            Decimal.zero(), Decimal.one(), Decimal.one(), Decimal.zero()
        );
        assertTrue(Decimal.eq(total, Decimal.zero()), "sumArith(0)=0");
    }

    function test_sumArith_oneItem() public pure {
        // sumArith(count=1, costInitial=5, costIncrease=2, currentOwned=0)
        // = 1 * (5 + 2*(0 + (1-1)/2)) = 1 * 5 = 5
        Decimal.D memory total = Decimal.sumArithmeticSeries(
            Decimal.one(),
            _d(5 * S, 0),
            _d(2 * S, 0),
            Decimal.zero()
        );
        assertLe(_relErr(total, _d(5 * S, 0)), 3e9, "sumArith(1 item) = 5");
    }

    function test_sumArith_threeItems_knownValue() public pure {
        // sumArith(count=3, costInitial=10, costIncrease=5, currentOwned=0)
        // costs: 10, 15, 20  →  total = 45
        Decimal.D memory total = Decimal.sumArithmeticSeries(
            _d(3 * S, 0),
            _d(S, 1),     // 10
            _d(5 * S, 0), // +5 each
            Decimal.zero()
        );
        Decimal.D memory expected = _d(45 * S, 0);
        assertLe(_relErr(total, expected), 3e9, "sumArith(3 items) = 45");
    }

    function test_sumArith_withCurrentOwned() public pure {
        // sumArith(count=2, costInitial=10, costIncrease=5, currentOwned=2)
        // item 2 costs 10+5*2=20, item 3 costs 10+5*3=25  →  total = 45
        Decimal.D memory total = Decimal.sumArithmeticSeries(
            _d(2 * S, 0),
            _d(S, 1),
            _d(5 * S, 0),
            _d(2 * S, 0)
        );
        Decimal.D memory expected = _d(45 * S, 0);
        assertLe(_relErr(total, expected), 3e9, "sumArith(2 items, owned=2) = 45");
    }

    function test_sumArith_zeroIncrease() public pure {
        // flat cost: 3 items at 7 each = 21
        Decimal.D memory total = Decimal.sumArithmeticSeries(
            _d(3 * S, 0),
            _d(7 * S, 0),
            Decimal.zero(),
            Decimal.zero()
        );
        Decimal.D memory expected = _d(21 * S, 0);
        assertLe(_relErr(total, expected), 3e9, "sumArith(flat) = 21");
    }

    // ── affordGeometricSeries ─────────────────────────────────────────────────

    function test_affordGeo_zeroBudget_isZero() public pure {
        Decimal.D memory count = Decimal.affordGeometricSeries(
            Decimal.zero(), Decimal.one(), _d(2 * S, 0), Decimal.zero()
        );
        assertTrue(Decimal.eq(count, Decimal.zero()), "afford(budget=0)=0");
    }

    function test_affordGeo_knownValue_ratio2() public pure {
        // costInitial=1, ratio=2, currentOwned=0
        // item 0 costs 1, item 1 costs 2, item 2 costs 4  →  budget=7 buys 3 items
        // floor(log2(7*(2-1)/1 + 2^0) / log2(2) - 0) = floor(log2(8)) = floor(3) = 3
        Decimal.D memory count = Decimal.affordGeometricSeries(
            _d(7 * S, 0),
            Decimal.one(),
            _d(2 * S, 0),
            Decimal.zero()
        );
        Decimal.D memory expected = _d(3 * S, 0);
        assertLe(_relErr(count, expected), 3e9, "afford(7, ratio=2) = 3");
    }

    function test_affordGeo_knownValue_ratio3() public pure {
        // costInitial=1, ratio=3, currentOwned=0
        // items cost 1, 3, 9, 27...  sum(3)=13, sum(4)=40
        // budget=13 exactly affords 3 items
        // floor(log3(13*(3-1)/1 + 1) - 0) = floor(log3(27)) = floor(3) = 3
        // Use budget=12 (strictly less than 13) to avoid exact-boundary fragility
        // items 0,1,2 cost 1,3,9 = sum 13; budget=12 affords only 2
        Decimal.D memory count = Decimal.affordGeometricSeries(
            _d(12 * S, 0),
            Decimal.one(),
            _d(3 * S, 0),
            Decimal.zero()
        );
        assertLe(_relErr(count, _d(2 * S, 0)), 3e9, "afford(12, ratio=3) = 2");
    }

    // ── affordArithmeticSeries ────────────────────────────────────────────────

    function test_affordArith_zeroBudget_isZero() public pure {
        Decimal.D memory count = Decimal.affordArithmeticSeries(
            Decimal.zero(), Decimal.one(), Decimal.one(), Decimal.zero()
        );
        assertTrue(Decimal.eq(count, Decimal.zero()), "affordArith(budget=0)=0");
    }

    function test_affordArith_knownValue() public pure {
        // costInitial=10, costIncrease=5, currentOwned=0
        // items cost: 10, 15, 20, 25...  sum(3)=45, sum(4)=70
        // budget=50 should afford 3 items
        Decimal.D memory count = Decimal.affordArithmeticSeries(
            _d(5 * S, 1),   // budget=50
            _d(S, 1),       // costInitial=10
            _d(5 * S, 0),   // costIncrease=5
            Decimal.zero()
        );
        Decimal.D memory expected = _d(3 * S, 0);
        assertLe(_relErr(count, expected), 3e9, "affordArith(50) = 3");
    }

    function test_affordArith_exactBudget() public pure {
        // budget = sumArith(count=4, costInitial=10, costIncrease=5, currentOwned=0)
        // = 4*(10 + 5*(0 + 3/2)) = 4*(10 + 7.5) = 4*17.5 = 70
        Decimal.D memory budget = Decimal.sumArithmeticSeries(
            _d(4 * S, 0),
            _d(S, 1),
            _d(5 * S, 0),
            Decimal.zero()
        );
        Decimal.D memory count = Decimal.affordArithmeticSeries(
            budget,
            _d(S, 1),
            _d(5 * S, 0),
            Decimal.zero()
        );
        assertLe(_relErr(count, _d(4 * S, 0)), 3e9, "affordArith(sumArith(4)) = 4");
    }

    function test_affordArith_withCurrentOwned() public pure {
        // costInitial=5, costIncrease=3, currentOwned=2
        // item 2 costs 5+3*2=11, item 3 costs 14  →  sum(2 items from slot 2) = 25
        Decimal.D memory budget = Decimal.sumArithmeticSeries(
            _d(2 * S, 0),
            _d(5 * S, 0),
            _d(3 * S, 0),
            _d(2 * S, 0)
        );
        Decimal.D memory count = Decimal.affordArithmeticSeries(
            budget,
            _d(5 * S, 0),
            _d(3 * S, 0),
            _d(2 * S, 0)
        );
        assertLe(_relErr(count, _d(2 * S, 0)), 3e9, "affordArith(owned=2) round-trip");
    }

    // ── afford/sum round-trip consistency ────────────────────────────────────

    function test_geoRoundTrip_sumOfAfforded_leqBudget() public pure {
        // If you can afford N items, the cost of N items should be <= budget
        Decimal.D memory budget = _d(S, 3);   // 1000
        Decimal.D memory ci     = _d(S, 1);   // costInitial=10
        Decimal.D memory ratio  = _d(15 * S / 10, 0); // ratio=1.5 (approx)
        Decimal.D memory owned  = _d(2 * S, 0);

        Decimal.D memory count = Decimal.affordGeometricSeries(budget, ci, ratio, owned);
        if (count.mantissa == 0) return;  // can't afford any
        Decimal.D memory cost  = Decimal.sumGeometricSeries(count, ci, ratio, owned);
        assertTrue(Decimal.lte(cost, budget), "sumGeo(affordGeo) <= budget");
    }

    function test_arithRoundTrip_sumOfAfforded_leqBudget() public pure {
        Decimal.D memory budget = _d(S, 3);   // 1000
        Decimal.D memory ci     = _d(S, 1);   // 10
        Decimal.D memory inc    = _d(5 * S, 0); // +5
        Decimal.D memory owned  = _d(3 * S, 0);

        Decimal.D memory count = Decimal.affordArithmeticSeries(budget, ci, inc, owned);
        if (count.mantissa == 0) return;
        Decimal.D memory cost  = Decimal.sumArithmeticSeries(count, ci, inc, owned);
        assertTrue(Decimal.lte(cost, budget), "sumArith(affordArith) <= budget");
    }
}
