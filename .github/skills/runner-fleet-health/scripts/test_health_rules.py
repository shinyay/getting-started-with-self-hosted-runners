#!/usr/bin/env python3
#
# test_health_rules.py - offline unit tests for the fleet-health engine.
# Run:  python3 .github/skills/runner-fleet-health/scripts/test_health_rules.py
# Proves HEALTHY, DEGRADED and UNHEALTHY paths deterministically (no cloud).

import json
import os
import sys
import unittest
import contextlib
import io

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import health_rules  # noqa: E402
import normalize_health  # noqa: E402


def run_main(argv):
    with contextlib.redirect_stdout(io.StringIO()):
        return health_rules.main(argv)


def status_of(result, sid, subject=None):
    for f in result["findings"]:
        if f["id"] == sid and (subject is None or f["subject"] == subject):
            return f["status"]
    return None


def load_fixture(name):
    with open(os.path.join(HERE, "fixtures", name)) as fh:
        return json.load(fh)


class Healthy(unittest.TestCase):
    def setUp(self):
        self.r = health_rules.evaluate(load_fixture("healthy.json"))

    def test_overall_healthy(self):
        self.assertEqual(self.r["overall"], "HEALTHY")

    def test_no_warn_or_crit(self):
        self.assertEqual(self.r["counts"].get("WARN", 0), 0)
        self.assertEqual(self.r["counts"].get("CRIT", 0), 0)

    def test_signals_ok(self):
        for sid in ("H1", "H2", "H3"):
            self.assertEqual(status_of(self.r, sid, "shinyay/ex"), "OK")


class Degraded(unittest.TestCase):
    def setUp(self):
        self.r = health_rules.evaluate(load_fixture("degraded.json"))

    def test_overall_degraded(self):
        self.assertEqual(self.r["overall"], "DEGRADED")

    def test_offline_runner_warns(self):
        self.assertEqual(status_of(self.r, "H1", "shinyay/ex"), "WARN")

    def test_slow_pickup_warns(self):
        self.assertEqual(status_of(self.r, "H2", "shinyay/ex"), "WARN")

    def test_success_rate_warns(self):
        # 7/10 = 70% -> between CRIT(50%) and WARN(80%) -> WARN
        self.assertEqual(status_of(self.r, "H3", "shinyay/ex"), "WARN")

    def test_nonephemeral_restart_spike_warns(self):
        self.assertEqual(status_of(self.r, "H4", "c1"), "WARN")

    def test_ephemeral_high_restart_ok(self):
        self.assertEqual(status_of(self.r, "H4", "c2"), "OK")

    def test_image_drift_info(self):
        self.assertEqual(status_of(self.r, "H5", "-"), "INFO")

    def test_no_crit(self):
        self.assertEqual(self.r["counts"].get("CRIT", 0), 0)


class Unhealthy(unittest.TestCase):
    def setUp(self):
        self.r = health_rules.evaluate(load_fixture("unhealthy.json"))

    def test_overall_unhealthy(self):
        self.assertEqual(self.r["overall"], "UNHEALTHY")

    def test_all_offline_crit(self):
        self.assertEqual(status_of(self.r, "H1", "shinyay/ex"), "CRIT")

    def test_queue_no_capacity_crit(self):
        self.assertEqual(status_of(self.r, "H2", "shinyay/ex"), "CRIT")

    def test_low_success_crit(self):
        # 1/4 = 25% < 50% -> CRIT
        self.assertEqual(status_of(self.r, "H3", "shinyay/ex"), "CRIT")


class Utilization(unittest.TestCase):
    def test_all_busy_info(self):
        doc = {"repos": [{"full_name": "o/r",
                          "runners": [{"name": "r1", "status": "online", "busy": True}],
                          "recent_runs": []}]}
        r = health_rules.evaluate(doc)
        self.assertEqual(status_of(r, "H6", "o/r"), "INFO")
        # busy-but-online still counts as available -> not CRIT/WARN on H1
        self.assertEqual(status_of(r, "H1", "o/r"), "OK")
        self.assertEqual(r["overall"], "HEALTHY")


class ExitSemantics(unittest.TestCase):
    def test_strict_degraded_nonzero(self):
        rc = run_main([os.path.join(HERE, "fixtures", "degraded.json"),
                               "--strict", "--json"])
        self.assertEqual(rc, 1)

    def test_degraded_zero_without_strict(self):
        rc = run_main([os.path.join(HERE, "fixtures", "degraded.json"), "--json"])
        self.assertEqual(rc, 0)

    def test_unhealthy_nonzero(self):
        rc = run_main([os.path.join(HERE, "fixtures", "unhealthy.json"), "--json"])
        self.assertEqual(rc, 1)


class NormalizeTransform(unittest.TestCase):
    def test_container_shaping(self):
        c = {"name": "ghrunner-aci-01", "state": "Running", "restart_count": 9,
             "restart_policy": "Always", "image": "x.azurecr.io/ghrunner:v0.6.0",
             "eph": "true"}
        out = normalize_health._container_norm(c, {"ghrunner-aci-01": "shinyay/foo"})
        self.assertEqual(out["image_tag"], "v0.6.0")
        self.assertIs(out["ephemeral"], True)
        self.assertEqual(out["repo"], "shinyay/foo")

    def test_repo_shaping(self):
        runners_raw = {"runners": [{"name": "r1", "status": "online", "busy": False}]}
        runs_raw = {"workflow_runs": [
            {"status": "completed", "conclusion": "success",
             "created_at": "2026-06-27T00:00:00Z", "run_started_at": "2026-06-27T00:00:05Z"}]}
        out = normalize_health._repo_norm("o/r", runners_raw, runs_raw)
        self.assertEqual(out["full_name"], "o/r")
        self.assertEqual(len(out["runners"]), 1)
        self.assertEqual(out["recent_runs"][0]["conclusion"], "success")

    def test_eph_unknown_is_none(self):
        out = normalize_health._container_norm({"name": "c", "image": "r/i:latest"}, {})
        self.assertIsNone(out["ephemeral"])
        self.assertEqual(out["image_tag"], "latest")


if __name__ == "__main__":
    unittest.main(verbosity=2)
