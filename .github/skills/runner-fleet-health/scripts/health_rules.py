#!/usr/bin/env python3
#
# health_rules.py - pure fleet-health rule engine for self-hosted runners.
#
# Input  : a normalized JSON document (see references/signals.md) produced by
#          collect-health.sh, read from a file argument or stdin.
# Output : a Markdown (default) or JSON health scorecard with an overall verdict
#          (HEALTHY / DEGRADED / UNHEALTHY). This module performs NO cloud or
#          network I/O and never reads secret values, so it is deterministic and
#          unit-testable offline.
#
# Usage:
#   health_rules.py [INPUT.json] [--json] [--strict]
#   cat doc.json | health_rules.py
#
# Exit code: UNHEALTHY -> 1. DEGRADED -> 1 only with --strict (else 0). HEALTHY -> 0.

import argparse
import datetime
import json
import sys

ORDER = {"CRIT": 3, "WARN": 2, "INFO": 1, "OK": 0}

# Thresholds (tunable; documented in references/signals.md).
WAIT_WARN_S = 120          # queued->started wait above this is slow pickup
SUCCESS_WARN = 0.80        # success rate below this -> WARN
SUCCESS_CRIT = 0.50        # success rate below this -> CRIT
RESTART_WARN = 5           # non-ephemeral restartCount above this -> WARN


def _f(sid, title, scope, subject, status, detail, hint=""):
    return {"id": sid, "title": title, "scope": scope, "subject": subject,
            "status": status, "detail": detail, "hint": hint}


def _parse_ts(ts):
    if not ts:
        return None
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


# --------------------------------------------------------------------------
# Per-repository signals
# --------------------------------------------------------------------------
def _audit_repo(repo):
    out = []
    name = repo.get("full_name", "?")
    runners = repo.get("runners") or []
    online = [r for r in runners if (r.get("status") or "").lower() == "online"]
    offline = [r for r in runners if (r.get("status") or "").lower() == "offline"]
    idle = [r for r in online if not r.get("busy")]
    runs = repo.get("recent_runs") or []

    # H1 runner availability
    if not runners:
        out.append(_f("H1", "Runner availability", "repo", name, "WARN",
                     "no runners registered for this repo",
                     "Provision a runner (ghrunner-provision / ghrunner-ops)."))
    elif not online:
        out.append(_f("H1", "Runner availability", "repo", name, "CRIT",
                     "all %d runner(s) offline" % len(runners),
                     "No capacity: redeploy/recover the runner (ghrunner-triage)."))
    elif offline:
        out.append(_f("H1", "Runner availability", "repo", name, "WARN",
                     "%d online, %d offline" % (len(online), len(offline)),
                     "Deregister or recover offline runners."))
    else:
        out.append(_f("H1", "Runner availability", "repo", name, "OK",
                     "%d runner(s) online" % len(online)))

    # H2 queue depth & wait time
    queued = [r for r in runs if (r.get("status") or "").lower() == "queued"]
    waits = []
    for r in runs:
        c, s = _parse_ts(r.get("created_at")), _parse_ts(r.get("run_started_at"))
        if c and s and s >= c:
            waits.append((s - c).total_seconds())
    max_wait = max(waits) if waits else 0
    if queued and not idle:
        out.append(_f("H2", "Queue / capacity", "repo", name, "CRIT",
                     "%d run(s) queued with no idle runner" % len(queued),
                     "Add runners or raise maxRunners (capacity gap)."))
    elif max_wait > WAIT_WARN_S:
        out.append(_f("H2", "Queue / capacity", "repo", name, "WARN",
                     "slow job pickup (max wait %ds)" % int(max_wait),
                     "Check runner availability / autoscaling latency."))
    else:
        out.append(_f("H2", "Queue / capacity", "repo", name, "OK",
                     "%d queued, max wait %ds" % (len(queued), int(max_wait))))

    # H3 recent job success rate
    completed = [r for r in runs if (r.get("status") or "").lower() == "completed"]
    decided = [r for r in completed
               if (r.get("conclusion") or "") in ("success", "failure")]
    if decided:
        succ = sum(1 for r in decided if r.get("conclusion") == "success")
        rate = succ / len(decided)
        pct = "%d%% (%d/%d)" % (round(rate * 100), succ, len(decided))
        if rate < SUCCESS_CRIT:
            out.append(_f("H3", "Job success rate", "repo", name, "CRIT",
                         "low success rate %s" % pct,
                         "Diagnose failures with ghrunner-triage."))
        elif rate < SUCCESS_WARN:
            out.append(_f("H3", "Job success rate", "repo", name, "WARN",
                         "degraded success rate %s" % pct,
                         "Review recent failures (ghrunner-triage)."))
        else:
            out.append(_f("H3", "Job success rate", "repo", name, "OK",
                         "success rate %s" % pct))
    else:
        out.append(_f("H3", "Job success rate", "repo", name, "INFO",
                     "no completed runs to score"))

    # H6 utilization (capacity pressure)
    if online and not idle:
        out.append(_f("H6", "Utilization", "repo", name, "INFO",
                     "all %d runner(s) busy (no idle capacity)" % len(online),
                     "Consider raising capacity if queues form."))
    return out


# --------------------------------------------------------------------------
# Container & fleet signals
# --------------------------------------------------------------------------
def _audit_containers(containers):
    out = []
    for c in containers:
        name = c.get("name", "?")
        # H4 restart spike (ephemeral runners restart by design -> not flagged)
        rc = c.get("restart_count")
        if c.get("ephemeral") is not True and isinstance(rc, int) and rc > RESTART_WARN:
            out.append(_f("H4", "Restart spike", "container", name, "WARN",
                         "non-ephemeral runner restarted %d times" % rc,
                         "Investigate crashes (ghrunner-triage)."))
        else:
            out.append(_f("H4", "Restart spike", "container", name, "OK",
                         "restartCount=%s%s" % (rc, " (ephemeral)" if c.get("ephemeral") else "")))
    # H5 image drift (fleet-wide)
    tags = [c.get("image_tag") for c in containers if c.get("image_tag")]
    if tags:
        uniq = sorted(set(tags))
        if any(t == "latest" for t in tags):
            out.append(_f("H5", "Image drift", "fleet", "-", "WARN",
                         "unpinned :latest present across the fleet",
                         "Pin immutable tags (ghrunner-image-release / audit A5)."))
        elif len(uniq) > 1:
            out.append(_f("H5", "Image drift", "fleet", "-", "INFO",
                         "mixed image versions: %s" % ", ".join(uniq),
                         "Roll the fleet to one tag (ghrunner-image-release)."))
        else:
            out.append(_f("H5", "Image drift", "fleet", "-", "OK",
                         "uniform image %s" % uniq[0]))
    return out


def evaluate(doc):
    findings = []
    for repo in doc.get("repos") or []:
        findings.extend(_audit_repo(repo))
    findings.extend(_audit_containers(doc.get("containers") or []))

    if not (doc.get("repos") or doc.get("containers")):
        findings.append(_f("H0", "No data", "scope", "-", "INFO",
                          "no repos or containers were collected",
                          "Pass --repo <owner/repo> and/or -g <rg>."))

    counts = {k: 0 for k in ORDER}
    for f in findings:
        counts[f["status"]] = counts.get(f["status"], 0) + 1
    if counts.get("CRIT"):
        overall = "UNHEALTHY"
    elif counts.get("WARN"):
        overall = "DEGRADED"
    else:
        overall = "HEALTHY"
    return {"meta": doc.get("meta") or {}, "findings": findings,
            "counts": counts, "overall": overall}


_EMOJI = {"OK": "✅", "WARN": "⚠️", "CRIT": "❌", "INFO": "ℹ️"}
_VERDICT = {"HEALTHY": "✅", "DEGRADED": "⚠️", "UNHEALTHY": "❌"}


def render_markdown(result):
    L = []
    o = result["overall"]
    c = result["counts"]
    L.append("# Runner Fleet Health — %s %s" % (_VERDICT.get(o, ""), o))
    L.append("")
    L.append("CRIT=%d  WARN=%d  INFO=%d  OK=%d" % (
        c.get("CRIT", 0), c.get("WARN", 0), c.get("INFO", 0), c.get("OK", 0)))
    L.append("")
    L.append("| ! | ID | Signal | Subject | Reading |")
    L.append("|---|----|--------|---------|---------|")
    ordered = sorted(result["findings"],
                     key=lambda f: (-ORDER.get(f["status"], 0), f["subject"], f["id"]))
    for f in ordered:
        L.append("| %s | %s | %s | %s | %s |" % (
            _EMOJI.get(f["status"], ""), f["id"], f["title"], f["subject"], f["detail"]))
    hints = [f for f in ordered if f["status"] in ("CRIT", "WARN") and f["hint"]]
    if hints:
        L.append("")
        L.append("## Suggested actions (read-only tool — apply yourself)")
        for f in hints:
            L.append("- **%s %s/%s** — %s" % (
                _EMOJI.get(f["status"], ""), f["id"], f["subject"], f["hint"]))
    return "\n".join(L) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Self-hosted runner fleet-health engine")
    ap.add_argument("input", nargs="?", help="normalized JSON (default: stdin)")
    ap.add_argument("--json", action="store_true", help="emit JSON scorecard")
    ap.add_argument("--strict", action="store_true", help="DEGRADED also exits non-zero")
    args = ap.parse_args(argv)

    raw = open(args.input).read() if args.input else sys.stdin.read()
    try:
        doc = json.loads(raw)
    except ValueError as e:
        sys.stderr.write("ERROR: input is not valid JSON: %s\n" % e)
        return 2

    result = evaluate(doc)
    if args.json:
        sys.stdout.write(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    else:
        sys.stdout.write(render_markdown(result))

    if result["overall"] == "UNHEALTHY":
        return 1
    if args.strict and result["overall"] == "DEGRADED":
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
