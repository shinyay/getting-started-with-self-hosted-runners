#!/usr/bin/env python3
#
# normalize_health.py - pure transform: raw `az`/`gh` JSON -> the normalized
# fleet-health document consumed by health_rules.py. No network/cloud I/O
# (collect-health.sh does that and passes file paths), so it is unit-testable.
# Records runner/run facts only; never copies a secret value.
#
# Usage:
#   normalize_health.py [--registry PATH] [--containers FILE] [--repo-spec FILE]
#
# --containers : JSON array of per-container `az container show --query` objects
#                {name,state,restart_count,restart_policy,image,eph}
# --repo-spec  : JSON array of {full_name, runners, runs} where runners/runs are
#                paths to the raw `gh api` responses for that repo.

import argparse
import json
import re
import sys

_LEDGER_ROW = re.compile(r"`(ghrunner-aci-\d+)`.*?github\.com/([\w.-]+/[\w.-]+)")


def _load(path):
    if not path:
        return None
    try:
        with open(path) as fh:
            txt = fh.read().strip()
        return json.loads(txt) if txt else None
    except (OSError, ValueError):
        return None


def parse_registry(path):
    cmap = {}
    if not path:
        return cmap
    try:
        with open(path) as fh:
            for ln in fh:
                m = _LEDGER_ROW.search(ln)
                if m:
                    cmap[m.group(1)] = m.group(2)
    except OSError:
        pass
    return cmap


def _image_tag(image):
    if not image:
        return None
    last = image.rsplit("/", 1)[-1]
    return last.rsplit(":", 1)[1] if ":" in last else None


def _container_norm(c, cmap):
    eph = c.get("eph")
    ephemeral = (str(eph).lower() == "true") if eph is not None else None
    name = c.get("name")
    return {
        "name": name,
        "state": c.get("state"),
        "restart_count": c.get("restart_count"),
        "restart_policy": c.get("restart_policy"),
        "ephemeral": ephemeral,
        "image_tag": _image_tag(c.get("image")),
        "repo": cmap.get(name),
    }


def _repo_norm(full_name, runners_raw, runs_raw):
    runners = []
    for r in (runners_raw or {}).get("runners", []) or []:
        runners.append({
            "name": r.get("name"),
            "status": r.get("status"),
            "busy": r.get("busy"),
        })
    runs = []
    for r in (runs_raw or {}).get("workflow_runs", []) or []:
        runs.append({
            "status": r.get("status"),
            "conclusion": r.get("conclusion"),
            "created_at": r.get("created_at"),
            "run_started_at": r.get("run_started_at"),
        })
    return {"full_name": full_name, "runners": runners, "recent_runs": runs}


def build(args):
    cmap = parse_registry(args.registry)
    doc = {"meta": {"expected_runners": len(cmap) or None},
           "containers": [], "repos": []}

    containers = _load(args.containers)
    if isinstance(containers, list):
        doc["containers"] = [_container_norm(c, cmap) for c in containers]

    spec = _load(args.repo_spec)
    if isinstance(spec, list):
        for entry in spec:
            doc["repos"].append(_repo_norm(
                entry.get("full_name"),
                _load(entry.get("runners")),
                _load(entry.get("runs")),
            ))
    return doc


def main(argv=None):
    ap = argparse.ArgumentParser(description="Normalize raw az/gh JSON for the health engine")
    ap.add_argument("--registry")
    ap.add_argument("--containers")
    ap.add_argument("--repo-spec")
    args = ap.parse_args(argv)
    sys.stdout.write(json.dumps(build(args), indent=2, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
