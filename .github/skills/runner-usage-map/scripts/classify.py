#!/usr/bin/env python3
#
# classify.py - pure engine: a normalized repo-usage document -> a per-repo
# runner-strategy classification with Active status and flags, plus a fleet
# summary. Renders Markdown (default), CSV or JSON. No cloud/network I/O and no
# secret values, so it is deterministic and unit-testable offline.
#
# Usage:
#   classify.py [INPUT.json] [--format md|csv|json] [--strict]
#
# Exit code: 0. With --strict, non-zero if any repo is flagged
# SELF_HOSTED_BUT_OFFLINE (a self-hosted repo with no online runner).

import argparse
import csv
import datetime
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import runson  # noqa: E402

DEF_ACTIVE_DAYS = 30


def _ts(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def classify_repo(repo, active_days, now=None):
    now = now or _now()
    name = repo.get("name", "?")
    enabled = repo.get("actions_enabled", True)
    workflows = repo.get("workflows") or []
    runners = repo.get("runners") or []
    online = [r for r in runners if (r.get("status") or "").lower() == "online"]

    all_runs_on = []
    active_runs_on = []
    disabled_wf = 0
    for wf in workflows:
        vals = wf.get("runs_on") or []
        all_runs_on.extend(vals)
        if (wf.get("state") or "active") != "active":
            disabled_wf += 1
        else:
            active_runs_on.extend(vals)

    details = set(runson.buckets(all_runs_on))
    has_dynamic = "dynamic" in details
    has_group = "group_review" in details
    has_custom = "custom_label" in details
    has_self_hosted = bool(details & {"self_hosted", "custom_label"})

    if not workflows:
        strategy = "none"
    else:
        strategy = runson.strategy_from_details(details)

    last = _ts(repo.get("last_run_at"))
    recent = bool(last and (now - last) <= datetime.timedelta(days=active_days))
    active = enabled and (recent or len(online) > 0)

    flags = []
    if not enabled:
        flags.append("ACTIONS_DISABLED")
    # Offline only when there is real self-hosted/custom evidence (not a
    # group- or dynamic-only repo, whose runners we cannot see at repo level).
    if has_self_hosted and strategy in ("self_hosted", "mixed") and enabled and not online:
        flags.append("SELF_HOSTED_BUT_OFFLINE")
    # Migration candidate only for purely GitHub-hosted, active repos with no
    # unresolved dynamic jobs (which might already target self-hosted).
    if strategy == "github_hosted" and active and not has_dynamic:
        flags.append("HOSTED_CANDIDATE")
    if enabled and not active and strategy != "none":
        flags.append("DORMANT")
    if has_dynamic:
        flags.append("DYNAMIC_REVIEW")
    if has_group:
        flags.append("GROUP_REVIEW")
    if has_custom:
        flags.append("CUSTOM_LABEL_REVIEW")
    if strategy == "none":
        flags.append("NO_WORKFLOWS")

    return {
        "repo": name,
        "visibility": repo.get("visibility"),
        "strategy": strategy,
        "active": active,
        "last_run_at": repo.get("last_run_at"),
        "runners_online": len(online),
        "runners_total": len(runners),
        "workflows": len(workflows),
        "workflows_disabled": disabled_wf,
        "flags": flags,
    }


def evaluate(doc):
    meta = doc.get("meta") or {}
    active_days = int(meta.get("active_days", DEF_ACTIVE_DAYS))
    now = _ts(meta.get("now")) or _now()
    rows = [classify_repo(r, active_days, now) for r in (doc.get("repos") or [])]

    by_strategy = {}
    active_n = dormant_n = 0
    self_off = hosted_cand = 0
    for r in rows:
        by_strategy[r["strategy"]] = by_strategy.get(r["strategy"], 0) + 1
        if r["active"]:
            active_n += 1
        else:
            dormant_n += 1
        if "SELF_HOSTED_BUT_OFFLINE" in r["flags"]:
            self_off += 1
        if "HOSTED_CANDIDATE" in r["flags"]:
            hosted_cand += 1
    summary = {
        "repos": len(rows),
        "by_strategy": by_strategy,
        "active": active_n,
        "dormant": dormant_n,
        "self_hosted_offline": self_off,
        "hosted_candidates": hosted_cand,
        "active_days": active_days,
    }
    return {"meta": meta, "rows": rows, "summary": summary}


def render_markdown(result):
    s = result["summary"]
    L = []
    L.append("# Runner Usage Map — %d repo(s)" % s["repos"])
    L.append("")
    bys = ", ".join("%s=%d" % (k, v) for k, v in sorted(s["by_strategy"].items()))
    L.append("Strategy: %s  ·  active=%d dormant=%d  ·  self-hosted-offline=%d  ·  "
             "hosted-candidates=%d  (active window %dd)" % (
                 bys or "-", s["active"], s["dormant"], s["self_hosted_offline"],
                 s["hosted_candidates"], s["active_days"]))
    L.append("")
    L.append("| Repo | Strategy | Active | Runners | Workflows | Flags |")
    L.append("|------|----------|:------:|:-------:|:---------:|-------|")
    for r in sorted(result["rows"], key=lambda x: (x["strategy"], x["repo"])):
        runners = "%d/%d online" % (r["runners_online"], r["runners_total"]) if r["runners_total"] else "-"
        wf = "%d%s" % (r["workflows"], (" (%d off)" % r["workflows_disabled"]) if r["workflows_disabled"] else "")
        L.append("| %s | %s | %s | %s | %s | %s |" % (
            r["repo"], r["strategy"], "✅" if r["active"] else "💤",
            runners, wf, ", ".join(r["flags"])))
    return "\n".join(L) + "\n"


def render_csv(result):
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["repo", "visibility", "strategy", "active", "last_run_at",
                "runners_online", "runners_total", "workflows",
                "workflows_disabled", "flags"])
    for r in sorted(result["rows"], key=lambda x: (x["strategy"], x["repo"])):
        w.writerow([r["repo"], r["visibility"], r["strategy"], r["active"],
                    r["last_run_at"], r["runners_online"], r["runners_total"],
                    r["workflows"], r["workflows_disabled"], ";".join(r["flags"])])
    return buf.getvalue()


def main(argv=None):
    ap = argparse.ArgumentParser(description="Cross-repo runner-usage classifier")
    ap.add_argument("input", nargs="?", help="normalized JSON (default: stdin)")
    ap.add_argument("--format", choices=["md", "csv", "json"], default="md")
    ap.add_argument("--strict", action="store_true",
                    help="non-zero exit if any SELF_HOSTED_BUT_OFFLINE")
    args = ap.parse_args(argv)

    raw = open(args.input).read() if args.input else sys.stdin.read()
    try:
        doc = json.loads(raw)
    except ValueError as e:
        sys.stderr.write("ERROR: input is not valid JSON: %s\n" % e)
        return 2

    result = evaluate(doc)
    if args.format == "json":
        sys.stdout.write(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    elif args.format == "csv":
        sys.stdout.write(render_csv(result))
    else:
        sys.stdout.write(render_markdown(result))

    if args.strict and result["summary"]["self_hosted_offline"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
