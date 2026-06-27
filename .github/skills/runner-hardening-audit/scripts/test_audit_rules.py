#!/usr/bin/env python3
#
# test_audit_rules.py - offline unit tests for the hardening rule engine.
# Run:  python3 .github/skills/runner-hardening-audit/scripts/test_audit_rules.py
#   or: python3 -m unittest -v  (from the scripts/ directory)
#
# Proves both the PASS and the WARN/FAIL paths deterministically, with no cloud.

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import audit_rules  # noqa: E402


def status_of(result, cid, subject=None):
    for f in result["findings"]:
        if f["id"] == cid and (subject is None or f["subject"] == subject):
            return f["status"]
    return None


def load_fixture(name):
    with open(os.path.join(HERE, "fixtures", name)) as fh:
        return json.load(fh)


class GoodFleet(unittest.TestCase):
    def setUp(self):
        self.r = audit_rules.evaluate(load_fixture("good-fleet.json"))

    def test_overall_pass(self):
        self.assertEqual(self.r["overall"], "PASS")

    def test_no_fail_or_warn(self):
        self.assertEqual(self.r["counts"].get("FAIL", 0), 0)
        self.assertEqual(self.r["counts"].get("WARN", 0), 0)

    def test_each_aci_control_passes(self):
        for cid in ("A1", "A2", "A3", "A4", "A5", "A6"):
            self.assertEqual(status_of(self.r, cid, "ghrunner-aci-good"), "PASS",
                            "expected %s PASS" % cid)


class BadFleet(unittest.TestCase):
    def setUp(self):
        self.r = audit_rules.evaluate(load_fixture("bad-fleet.json"))

    def test_overall_fail(self):
        self.assertEqual(self.r["overall"], "FAIL")

    def test_stale_image_warns(self):
        self.assertEqual(status_of(self.r, "A1", "aci-stale"), "WARN")

    def test_nonephemeral_public_fails(self):
        self.assertEqual(status_of(self.r, "A2", "aci-pat-public"), "FAIL")

    def test_static_cred_env_warns(self):
        self.assertEqual(status_of(self.r, "A3", "aci-pat-public"), "WARN")

    def test_untrusted_registry_fails(self):
        self.assertEqual(status_of(self.r, "A5", "aci-untrusted"), "FAIL")

    def test_public_ip_warns(self):
        self.assertEqual(status_of(self.r, "A4", "aci-untrusted"), "WARN")

    def test_non_running_state_warns(self):
        self.assertEqual(status_of(self.r, "A6", "aci-untrusted"), "WARN")

    def test_good_container_in_bad_fleet_still_passes_auth(self):
        self.assertEqual(status_of(self.r, "A3", "aci-stale"), "PASS")


class WeakRepo(unittest.TestCase):
    def setUp(self):
        self.r = audit_rules.evaluate(load_fixture("weak-repo.json"))

    def test_overall_fail(self):
        self.assertEqual(self.r["overall"], "FAIL")

    def test_write_permissions_warn(self):
        self.assertEqual(status_of(self.r, "B1", "shinyay/weak-example"), "WARN")

    def test_fork_pr_manual(self):
        self.assertEqual(status_of(self.r, "B2", "shinyay/weak-example"), "MANUAL")

    def test_allowed_actions_all_warns(self):
        self.assertEqual(status_of(self.r, "B3", "shinyay/weak-example"), "WARN")

    def test_public_plus_self_hosted_fails(self):
        self.assertEqual(status_of(self.r, "B4", "shinyay/weak-example"), "FAIL")

    def test_offline_runner_warns(self):
        self.assertEqual(status_of(self.r, "B5", "shinyay/weak-example"), "WARN")


class TightRepo(unittest.TestCase):
    def test_hardened_repo_passes(self):
        doc = {"meta": {}, "repo": {
            "full_name": "shinyay/tight",
            "visibility": "private",
            "actions_enabled": True,
            "allowed_actions": "selected",
            "default_workflow_permissions": "read",
            "fork_pr_approval": "all",
            "self_hosted_runners": [{"name": "r1", "status": "online", "ephemeral": True}],
        }}
        r = audit_rules.evaluate(doc)
        for cid in ("B1", "B2", "B3", "B4", "B5"):
            self.assertEqual(status_of(r, cid, "shinyay/tight"), "PASS",
                            "expected %s PASS" % cid)
        self.assertEqual(r["overall"], "PASS")


class ExitSemantics(unittest.TestCase):
    def test_strict_warn_is_nonzero(self):
        # a WARN-only document: stale image, private repo
        doc = {"meta": {"latest_image_tag": "v0.6.3",
                        "trusted_registry": "shinyayacr202604.azurecr.io"},
               "containers": [{"name": "c", "state": "Running",
                               "image": "shinyayacr202604.azurecr.io/ghrunner:v0.6.1",
                               "image_tag": "v0.6.1",
                               "image_registry": "shinyayacr202604.azurecr.io",
                               "ephemeral": True, "restart_policy": "Always",
                               "env_keys": ["EPHEMERAL"], "ip_type": None,
                               "repo_visibility": "private"}]}
        r = audit_rules.evaluate(doc)
        self.assertEqual(r["overall"], "WARN")


class A6Health(unittest.TestCase):
    def _doc(self, **c):
        base = {"name": "x", "image": "shinyayacr202604.azurecr.io/ghrunner:v0.6.3",
                "image_tag": "v0.6.3", "image_registry": "shinyayacr202604.azurecr.io",
                "ephemeral": True, "restart_policy": "Always", "env_keys": ["EPHEMERAL"],
                "ip_type": None, "repo_visibility": "private"}
        base.update(c)
        return {"meta": {"latest_image_tag": "v0.6.3",
                        "trusted_registry": "shinyayacr202604.azurecr.io"},
                "containers": [base]}

    def test_state_not_reported_passes(self):
        # az container list omits runtime state -> None, provisioning Succeeded -> PASS
        r = audit_rules.evaluate(self._doc(state=None, provisioning_state="Succeeded"))
        self.assertEqual(status_of(r, "A6", "x"), "PASS")

    def test_ephemeral_terminated_passes(self):
        r = audit_rules.evaluate(self._doc(state="Terminated", ephemeral=True))
        self.assertEqual(status_of(r, "A6", "x"), "PASS")

    def test_nonephemeral_terminated_warns(self):
        r = audit_rules.evaluate(self._doc(state="Terminated", ephemeral=False,
                                          restart_policy="Never", env_keys=["RUNNER_LABELS"]))
        self.assertEqual(status_of(r, "A6", "x"), "WARN")

    def test_failed_provisioning_warns(self):
        r = audit_rules.evaluate(self._doc(state=None, provisioning_state="Failed"))
        self.assertEqual(status_of(r, "A6", "x"), "WARN")


if __name__ == "__main__":
    unittest.main(verbosity=2)
