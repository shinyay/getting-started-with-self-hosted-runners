#!/usr/bin/env python3
#
# test_classify.py - offline unit tests for the runner-usage classifier:
# runs-on classification, runs-on extraction, repo classification + flags, and
# CSV/JSON rendering. No cloud/network. Run:
#   python3 .github/skills/runner-usage-map/scripts/test_classify.py

import contextlib
import csv
import io
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import runson    # noqa: E402
import classify  # noqa: E402

NOW = classify._ts("2026-06-27T00:00:00Z")


def find(result, repo):
    for r in result["rows"]:
        if r["repo"] == repo:
            return r
    return None


def run_main(argv):
    with contextlib.redirect_stdout(io.StringIO()):
        return classify.main(argv)


class RunsOnClassify(unittest.TestCase):
    def test_buckets(self):
        cases = {
            "ubuntu-latest": "github_hosted",
            "ubuntu-22.04": "github_hosted",
            "windows-latest": "github_hosted",
            "macos-14": "github_hosted",
            "self-hosted": "self_hosted",
            "[self-hosted, linux, x64]": "self_hosted",
            "[ubuntu-latest]": "github_hosted",
            "my-custom-label": "self_hosted",
            "${{ matrix.os }}": "dynamic",
            "group:": "group_review",
        }
        for value, expected in cases.items():
            self.assertEqual(runson.classify_runs_on(value), expected, value)

    def test_workflow_strategy(self):
        self.assertEqual(runson.workflow_strategy(["ubuntu-latest"]), "github_hosted")
        self.assertEqual(runson.workflow_strategy(["self-hosted"]), "self_hosted")
        self.assertEqual(runson.workflow_strategy(["ubuntu-latest", "self-hosted"]), "mixed")
        self.assertEqual(runson.workflow_strategy(["${{ matrix.os }}"]), "dynamic")
        self.assertEqual(runson.workflow_strategy([]), "none")


class ExtractRunsOn(unittest.TestCase):
    def test_inline_list_block_dynamic(self):
        text = (
            "jobs:\n"
            "  a:\n    runs-on: ubuntu-latest\n"
            "  b:\n    runs-on: [self-hosted, linux]\n"
            "  c:\n    runs-on:\n      - self-hosted\n      - x64\n"
            "  d:\n    runs-on: ${{ matrix.os }}\n"
        )
        vals = runson.extract_runs_on(text)
        self.assertEqual(vals[0], "ubuntu-latest")
        self.assertEqual(vals[1], "[self-hosted, linux]")
        self.assertEqual(vals[2], "[self-hosted, x64]")
        self.assertIn("${{", vals[3])

    def test_comment_stripped(self):
        self.assertEqual(runson.extract_runs_on("    runs-on: ubuntu-latest # note"),
                        ["ubuntu-latest"])

    def test_group_form(self):
        text = "  a:\n    runs-on:\n      group: my-larger-runners\n"
        self.assertEqual(runson.extract_runs_on(text), ["group:"])


class ClassifyRepo(unittest.TestCase):
    def setUp(self):
        self.doc = json.load(open(os.path.join(HERE, "fixtures", "sample-usage.json")))
        self.r = classify.evaluate(self.doc)

    def test_hosted_candidate(self):
        self.assertEqual(find(self.r, "demo/hosted")["strategy"], "github_hosted")
        self.assertIn("HOSTED_CANDIDATE", find(self.r, "demo/hosted")["flags"])

    def test_self_hosted_offline(self):
        row = find(self.r, "demo/sh-offline")
        self.assertEqual(row["strategy"], "self_hosted")
        self.assertIn("SELF_HOSTED_BUT_OFFLINE", row["flags"])

    def test_self_hosted_online_clean(self):
        row = find(self.r, "demo/sh-online")
        self.assertTrue(row["active"])
        self.assertEqual(row["flags"], [])

    def test_mixed(self):
        self.assertEqual(find(self.r, "demo/mixed")["strategy"], "mixed")

    def test_dynamic_review(self):
        self.assertIn("DYNAMIC_REVIEW", find(self.r, "demo/dynamic")["flags"])

    def test_none(self):
        row = find(self.r, "demo/none")
        self.assertEqual(row["strategy"], "none")
        self.assertIn("NO_WORKFLOWS", row["flags"])

    def test_disabled_not_active(self):
        row = find(self.r, "demo/disabled")
        self.assertFalse(row["active"])
        self.assertIn("ACTIONS_DISABLED", row["flags"])

    def test_summary_counts(self):
        s = self.r["summary"]
        self.assertEqual(s["repos"], 7)
        self.assertEqual(s["self_hosted_offline"], 1)
        self.assertEqual(s["hosted_candidates"], 1)


class ActiveBoundary(unittest.TestCase):
    def _repo(self, last_run):
        return {"name": "x", "actions_enabled": True, "last_run_at": last_run,
                "workflows": [{"name": "ci", "state": "active", "runs_on": ["ubuntu-latest"]}],
                "runners": []}

    def test_recent_run_active(self):
        row = classify.classify_repo(self._repo("2026-06-26T00:00:00Z"), 30, NOW)
        self.assertTrue(row["active"])

    def test_old_run_dormant(self):
        row = classify.classify_repo(self._repo("2026-05-01T00:00:00Z"), 30, NOW)
        self.assertFalse(row["active"])
        self.assertIn("DORMANT", row["flags"])

    def test_offline_runner_does_not_make_active(self):
        repo = self._repo("2026-05-01T00:00:00Z")
        repo["runs_on"] = ["self-hosted"]
        repo["workflows"][0]["runs_on"] = ["self-hosted"]
        repo["runners"] = [{"name": "r", "status": "offline"}]
        row = classify.classify_repo(repo, 30, NOW)
        self.assertFalse(row["active"])


class Render(unittest.TestCase):
    def setUp(self):
        self.doc = json.load(open(os.path.join(HERE, "fixtures", "sample-usage.json")))
        self.result = classify.evaluate(self.doc)

    def test_csv_parses(self):
        text = classify.render_csv(self.result)
        rows = list(csv.reader(io.StringIO(text)))
        self.assertEqual(rows[0][0], "repo")
        self.assertEqual(len(rows), 1 + self.result["summary"]["repos"])

    def test_json_format(self):
        rc = run_main([os.path.join(HERE, "fixtures", "sample-usage.json"), "--format", "json"])
        self.assertEqual(rc, 0)


class StrictExit(unittest.TestCase):
    def test_strict_nonzero_on_offline(self):
        rc = run_main([os.path.join(HERE, "fixtures", "sample-usage.json"),
                      "--strict", "--format", "json"])
        self.assertEqual(rc, 1)  # sample has a SELF_HOSTED_BUT_OFFLINE


class ReviewFixes(unittest.TestCase):
    """Covers correctness fixes from code review."""

    def test_classify_detail_distinguishes_custom_and_explicit(self):
        self.assertEqual(runson.classify_detail("self-hosted"), "self_hosted")
        self.assertEqual(runson.classify_detail("my-label"), "custom_label")
        self.assertEqual(runson.classify_detail("ubuntu-latest"), "github_hosted")
        self.assertEqual(runson.classify_detail("group:"), "group_review")

    def test_dynamic_plus_hosted_is_not_hosted_candidate(self):
        # one hosted job + one matrix job -> hosted strategy but NOT a candidate
        repo = {"name": "x", "actions_enabled": True, "last_run_at": "2026-06-26T00:00:00Z",
                "workflows": [{"name": "ci", "state": "active",
                               "runs_on": ["ubuntu-latest", "${{ matrix.os }}"]}],
                "runners": []}
        row = classify.classify_repo(repo, 30, NOW)
        self.assertNotIn("HOSTED_CANDIDATE", row["flags"])
        self.assertIn("DYNAMIC_REVIEW", row["flags"])

    def test_group_only_not_offline(self):
        repo = {"name": "x", "actions_enabled": True, "last_run_at": "2026-06-26T00:00:00Z",
                "workflows": [{"name": "ci", "state": "active", "runs_on": ["group:"]}],
                "runners": []}
        row = classify.classify_repo(repo, 30, NOW)
        self.assertEqual(row["strategy"], "group_review")
        self.assertNotIn("SELF_HOSTED_BUT_OFFLINE", row["flags"])
        self.assertIn("GROUP_REVIEW", row["flags"])

    def test_custom_label_review_flag(self):
        repo = {"name": "x", "actions_enabled": True, "last_run_at": "2026-06-26T00:00:00Z",
                "workflows": [{"name": "ci", "state": "active", "runs_on": ["my-fleet"]}],
                "runners": [{"name": "r", "status": "offline"}]}
        row = classify.classify_repo(repo, 30, NOW)
        self.assertIn("CUSTOM_LABEL_REVIEW", row["flags"])
        # a bare custom label is self-hosted evidence -> offline still flagged
        self.assertIn("SELF_HOSTED_BUT_OFFLINE", row["flags"])

    def test_active_window_uses_full_timedelta(self):
        # 30 days + 23h ago with a 30-day window -> dormant (not active)
        repo = {"name": "x", "actions_enabled": True,
                "last_run_at": "2026-05-27T23:00:00Z",
                "workflows": [{"name": "ci", "state": "active", "runs_on": ["ubuntu-latest"]}],
                "runners": []}
        row = classify.classify_repo(repo, 30, NOW)
        self.assertFalse(row["active"])

    def test_extract_group_with_labels(self):
        text = ("  a:\n    runs-on:\n      group: my-group\n"
                "      labels: [self-hosted, linux]\n")
        vals = runson.extract_runs_on(text)
        self.assertEqual(vals, ["[self-hosted, linux]"])
        self.assertEqual(runson.classify_detail(vals[0]), "self_hosted")


if __name__ == "__main__":
    unittest.main(verbosity=2)
