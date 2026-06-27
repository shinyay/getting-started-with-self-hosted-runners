#!/usr/bin/env python3
#
# normalize_cost.py - pure transform: raw `az`/`gh` JSON + pricing rates -> the
# normalized cost document consumed by cost_rules.py. No network/cloud I/O
# (collect-cost.sh gathers facts and rates and passes file paths), so it is
# deterministic and unit-testable offline. Records sizing & utilization only.
#
# Usage:
#   normalize_cost.py [--registry PATH] [--containers FILE] [--repo-spec FILE]
#                     [--rates FILE] [--region R]
#                     [--baseline-cpu C] [--baseline-mem M]
#                     [--low-util P] [--very-low-util P] [--high-util P]
#                     [--offhours-save F]

import argparse
import datetime
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


def _ts(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def utilization_pct(runs):
    """Average busy minutes/day as a percent of the 1440-min day, from run history."""
    durations = []
    created = []
    for r in runs or []:
        st, en = _ts(r.get("run_started_at")), _ts(r.get("updated_at"))
        c = _ts(r.get("created_at"))
        if c:
            created.append(c)
        if st and en and en >= st:
            durations.append((en - st).total_seconds() / 60.0)
    if not durations or not created:
        return None
    span_days = max((max(created) - min(created)).total_seconds() / 86400.0, 1.0)
    per_day_min = sum(durations) / span_days
    return min(per_day_min / 1440.0 * 100.0, 100.0)


def build(args):
    cmap = parse_registry(args.registry)
    rates = _load(args.rates) or {}

    # Per-repo utilization from job history.
    util_by_repo = {}
    spec = _load(args.repo_spec)
    if isinstance(spec, list):
        for entry in spec:
            runs_doc = _load(entry.get("runs")) or {}
            util_by_repo[entry.get("full_name")] = utilization_pct(
                runs_doc.get("workflow_runs"))

    meta = {
        "region": args.region,
        "rates": {
            "vcpu_second": rates.get("vcpu_second"),
            "mem_gb_second": rates.get("mem_gb_second"),
            "source": rates.get("source", "static-default"),
        },
        "baseline_cpu": args.baseline_cpu,
        "baseline_mem_gb": args.baseline_mem,
        "low_util_pct": args.low_util,
        "very_low_util_pct": args.very_low_util,
        "high_util_pct": args.high_util,
        "offhours_save_frac": args.offhours_save,
    }
    doc = {"meta": meta, "containers": []}

    containers = _load(args.containers)
    if isinstance(containers, list):
        for c in containers:
            name = c.get("name")
            repo = cmap.get(name)
            state = c.get("state")
            doc["containers"].append({
                "name": name,
                "cpu": c.get("cpu"),
                "memory_gb": c.get("memory_gb"),
                "restart_policy": c.get("restart_policy"),
                "ephemeral": (str(c.get("eph")).lower() == "true") if c.get("eph") is not None else None,
                "running": state != "Stopped",
                "repo": repo,
                "util_pct": util_by_repo.get(repo),
            })
    return doc


def main(argv=None):
    ap = argparse.ArgumentParser(description="Normalize raw az/gh JSON for the cost engine")
    ap.add_argument("--registry")
    ap.add_argument("--containers")
    ap.add_argument("--repo-spec")
    ap.add_argument("--rates")
    ap.add_argument("--region", default="eastus")
    ap.add_argument("--baseline-cpu", type=float, default=1.0)
    ap.add_argument("--baseline-mem", type=float, default=2.0)
    ap.add_argument("--low-util", type=float, default=15.0)
    ap.add_argument("--very-low-util", type=float, default=10.0)
    ap.add_argument("--high-util", type=float, default=60.0)
    ap.add_argument("--offhours-save", type=float, default=0.60)
    args = ap.parse_args(argv)
    sys.stdout.write(json.dumps(build(args), indent=2, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
