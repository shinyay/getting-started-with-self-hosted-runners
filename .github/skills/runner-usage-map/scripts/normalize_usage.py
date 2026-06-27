#!/usr/bin/env python3
#
# normalize_usage.py - pure transform: raw `gh` JSON + downloaded workflow files
# -> the normalized repo-usage document consumed by classify.py. No network/cloud
# I/O (collect-usage.sh gathers everything and passes a spec), so it is
# deterministic and unit-testable offline.
#
# Usage:
#   normalize_usage.py --repo-spec FILE [--active-days N] [--owner O]
#
# --repo-spec : JSON array of per-repo entries:
#   { "name": "o/r", "visibility": "...", "permissions": <path>,
#     "workflows": <path>, "runners": <path>, "lastrun": <path>,
#     "wf_files": [ { "name": "...", "path": "...", "state": "...", "file": <path> } ] }

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import runson  # noqa: E402


def _load(path):
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path) as fh:
            txt = fh.read().strip()
        return json.loads(txt) if txt else None
    except (OSError, ValueError):
        return None


def _read(path):
    if not path or not os.path.exists(path):
        return ""
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:
        return ""


def _repo(entry):
    perm = _load(entry.get("permissions")) or {}
    runners_doc = _load(entry.get("runners")) or {}
    lastrun_doc = _load(entry.get("lastrun")) or {}

    workflows = []
    for wf in entry.get("wf_files") or []:
        runs_on = runson.extract_runs_on(_read(wf.get("file")))
        workflows.append({
            "name": wf.get("name"),
            "path": wf.get("path"),
            "state": wf.get("state"),
            "runs_on": runs_on,
        })

    runners = [{"name": r.get("name"), "status": r.get("status"), "busy": r.get("busy"),
                "labels": [l.get("name") for l in (r.get("labels") or []) if l.get("name")]}
               for r in (runners_doc.get("runners") or [])]
    runs = lastrun_doc.get("workflow_runs") or []
    last_run_at = runs[0].get("created_at") if runs else None

    return {
        "name": entry.get("name"),
        "visibility": entry.get("visibility"),
        "actions_enabled": perm.get("enabled", True),
        "workflows": workflows,
        "runners": runners,
        "last_run_at": last_run_at,
    }


def build(args):
    spec = _load(args.repo_spec) or []
    return {
        "meta": {"owner": args.owner, "active_days": args.active_days},
        "repos": [_repo(e) for e in spec],
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="Normalize raw gh JSON for the usage classifier")
    ap.add_argument("--repo-spec", required=True)
    ap.add_argument("--active-days", type=int, default=30)
    ap.add_argument("--owner", default=None)
    args = ap.parse_args(argv)
    sys.stdout.write(json.dumps(build(args), indent=2, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
