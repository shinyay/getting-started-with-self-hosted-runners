#!/usr/bin/env python3
#
# test_cost_rules.py - offline unit tests for the cost-optimization engine,
# the normalize transform, and the static price resolver. No cloud/network.
# Run: python3 .github/skills/runner-cost-optimizer/scripts/test_cost_rules.py

import argparse
import contextlib
import io
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cost_rules        # noqa: E402
import normalize_cost    # noqa: E402
import prices            # noqa: E402

META = {"region": "eastus",
        "rates": {"vcpu_second": 0.0000135, "mem_gb_second": 0.0000015, "source": "static-default"},
        "seconds_per_month": 2628000, "baseline_cpu": 1.0, "baseline_mem_gb": 2.0,
        "low_util_pct": 15.0, "very_low_util_pct": 10.0, "high_util_pct": 60.0,
        "offhours_save_frac": 0.60}


def find(result, rid, subject):
    for f in result["findings"]:
        if f["id"] == rid and f["subject"] == subject:
            return f
    return None


def run_main(argv):
    with contextlib.redirect_stdout(io.StringIO()):
        return cost_rules.main(argv)


class CostMath(unittest.TestCase):
    def test_monthly_cost_2vcpu_4gb(self):
        c = cost_rules.monthly_cost(2.0, 4.0, META)
        # 2*0.0000135*2628000 + 4*0.0000015*2628000 = 70.956 + 15.768 = 86.724
        self.assertAlmostEqual(c, 86.724, places=2)


class IdleRunner(unittest.TestCase):
    def setUp(self):
        doc = {"meta": META, "containers": [
            {"name": "idle", "cpu": 2.0, "memory_gb": 4.0, "running": True,
             "repo": "o/idle", "util_pct": 3.0}]}
        self.r = cost_rules.evaluate(doc)

    def test_scale_to_zero_save(self):
        self.assertEqual(find(self.r, "R2", "idle")["status"], "SAVE")

    def test_arc_migration_save(self):
        self.assertEqual(find(self.r, "R3", "idle")["status"], "SAVE")

    def test_rightsize_review(self):
        self.assertEqual(find(self.r, "R1", "idle")["status"], "REVIEW")

    def test_best_saving_is_arc(self):
        # ARC (1-util) > scale-to-zero (60%) for very low util -> potential = R3
        self.assertAlmostEqual(self.r["summary"]["potential_savings"],
                              find(self.r, "R3", "idle")["saving"], places=2)

    def test_overall_savings(self):
        self.assertEqual(self.r["overall"], "SAVINGS AVAILABLE")


class BusyRunner(unittest.TestCase):
    def setUp(self):
        doc = {"meta": META, "containers": [
            {"name": "busy", "cpu": 2.0, "memory_gb": 4.0, "running": True,
             "repo": "o/busy", "util_pct": 75.0}]}
        self.r = cost_rules.evaluate(doc)

    def test_reserved_info(self):
        self.assertEqual(find(self.r, "R4", "busy")["status"], "INFO")

    def test_no_scale_to_zero(self):
        self.assertIsNone(find(self.r, "R2", "busy"))

    def test_rightsize_excluded_from_potential(self):
        # busy runner's right-size must NOT inflate fleet potential
        self.assertEqual(self.r["summary"]["potential_savings"], 0.0)
        self.assertEqual(self.r["overall"], "OPTIMIZED")


class OptimizedFleet(unittest.TestCase):
    def test_rightsized_well_utilized_is_ok(self):
        doc = {"meta": META, "containers": [
            {"name": "ok", "cpu": 1.0, "memory_gb": 2.0, "running": True,
             "repo": "o/ok", "util_pct": 40.0}]}
        r = cost_rules.evaluate(doc)
        self.assertEqual(find(r, "OK", "ok")["status"], "OK")
        self.assertEqual(r["summary"]["potential_savings"], 0.0)
        self.assertEqual(r["overall"], "OPTIMIZED")


class UnknownUtil(unittest.TestCase):
    def test_unknown_util_info_but_rightsize_applies(self):
        doc = {"meta": META, "containers": [
            {"name": "u", "cpu": 2.0, "memory_gb": 4.0, "running": True,
             "repo": None, "util_pct": None}]}
        r = cost_rules.evaluate(doc)
        self.assertEqual(find(r, "U0", "u")["status"], "INFO")
        self.assertEqual(find(r, "R1", "u")["status"], "REVIEW")
        # unknown util -> right-size counts toward potential
        self.assertGreater(r["summary"]["potential_savings"], 0.0)


class FleetTotals(unittest.TestCase):
    def test_potential_is_sum_of_best(self):
        r = cost_rules.evaluate(json.load(open(os.path.join(HERE, "fixtures", "savings-fleet.json"))))
        idle_best = find(r, "R3", "aci-idle")["saving"]
        unknown_best = find(r, "R1", "aci-unknown")["saving"]
        # busy contributes 0; total = idle R3 + unknown R1
        self.assertAlmostEqual(r["summary"]["potential_savings"],
                              round(idle_best + unknown_best, 2), places=2)


class ExitSemantics(unittest.TestCase):
    def test_strict_nonzero_when_save(self):
        rc = run_main([os.path.join(HERE, "fixtures", "savings-fleet.json"), "--strict", "--json"])
        self.assertEqual(rc, 1)

    def test_strict_zero_when_optimized(self):
        rc = run_main([os.path.join(HERE, "fixtures", "optimized-fleet.json"), "--strict", "--json"])
        self.assertEqual(rc, 0)


class NormalizeUtil(unittest.TestCase):
    def test_utilization_pct(self):
        runs = [
            {"created_at": "2026-06-26T00:00:00Z", "run_started_at": "2026-06-26T00:00:00Z",
             "updated_at": "2026-06-26T00:10:00Z"},
            {"created_at": "2026-06-27T00:00:00Z", "run_started_at": "2026-06-27T00:00:00Z",
             "updated_at": "2026-06-27T00:10:00Z"},
        ]
        # 20 min total over a 1-day span -> 20/1440 = 1.389%
        self.assertAlmostEqual(normalize_cost.utilization_pct(runs), 1.3889, places=3)

    def test_no_runs_is_none(self):
        self.assertIsNone(normalize_cost.utilization_pct([]))


class PriceResolver(unittest.TestCase):
    def test_static_default(self):
        a = argparse.Namespace(live=False, region="eastus", vcpu_rate=None, mem_rate=None)
        r = prices.resolve(a)
        self.assertEqual(r["source"], "static-default")
        self.assertEqual(r["vcpu_second"], prices.DEF_VCPU_SECOND)

    def test_override_wins(self):
        a = argparse.Namespace(live=True, region="eastus", vcpu_rate=0.01, mem_rate=0.02)
        r = prices.resolve(a)
        self.assertEqual(r["source"], "override")
        self.assertEqual(r["vcpu_second"], 0.01)


if __name__ == "__main__":
    unittest.main(verbosity=2)
