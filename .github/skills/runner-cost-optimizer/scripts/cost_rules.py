#!/usr/bin/env python3
#
# cost_rules.py - pure cost-optimization engine for the self-hosted runner fleet.
#
# Input  : a normalized JSON document (see references/pricing.md) produced by
#          collect-cost.sh, with ACI sizing, per-runner utilization and the
#          pricing rates. Read from a file argument or stdin.
# Output : a Markdown (default) or JSON cost report: per-runner monthly cost,
#          utilization and right-sizing / scale-to-zero recommendations with
#          savings estimates, plus a fleet total and potential savings.
#
# This module performs NO cloud/network I/O (collect-cost.sh gathers the facts
# and the rates) and never reads secret values, so it is deterministic and
# unit-testable offline. All monetary figures are ESTIMATES.
#
# Usage:
#   cost_rules.py [INPUT.json] [--json] [--strict]
#
# Exit code: 0. With --strict, non-zero when a clear saving (SAVE) is found
# (so it can gate a budget check in CI).

import argparse
import json
import sys

# Defaults used only if the input doc does not supply meta values.
DEF_SECONDS_PER_MONTH = 2628000      # 730 h
DEF_VCPU_SECOND = 0.0000135          # USD per vCPU-second (East US Linux, approx)
DEF_MEM_GB_SECOND = 0.0000015        # USD per GB-second (approx)
DEF_BASELINE_CPU = 1.0
DEF_BASELINE_MEM = 2.0
DEF_LOW_UTIL = 15.0                  # below this -> scale-to-zero candidate
DEF_VERY_LOW_UTIL = 10.0             # below this -> ARC migration candidate
DEF_HIGH_UTIL = 60.0                 # at/above this -> reserved-instance candidate
DEF_OFFHOURS_SAVE = 0.60             # fraction of cost saved by off-hours stop
DEF_RESERVED_SAVE = 0.30             # 1-year reserved approx discount


def _money(x):
    return "$%.2f" % (x or 0.0)


def _f(rid, title, subject, status, detail, saving=0.0):
    return {"id": rid, "title": title, "subject": subject, "status": status,
            "detail": detail, "saving": round(saving, 2)}


def _rates(meta):
    r = meta.get("rates") or {}
    return (
        float(r.get("vcpu_second", DEF_VCPU_SECOND)),
        float(r.get("mem_gb_second", DEF_MEM_GB_SECOND)),
        float(meta.get("seconds_per_month", DEF_SECONDS_PER_MONTH)),
    )


def monthly_cost(cpu, mem, meta):
    vcpu_rate, mem_rate, spm = _rates(meta)
    return ((cpu or 0) * vcpu_rate + (mem or 0) * mem_rate) * spm


def _audit_container(c, meta):
    name = c.get("name", "?")
    cpu = c.get("cpu")
    mem = c.get("memory_gb")
    util = c.get("util_pct")              # may be None (unknown)
    running = c.get("running", True)
    base_cpu = float(meta.get("baseline_cpu", DEF_BASELINE_CPU))
    base_mem = float(meta.get("baseline_mem_gb", DEF_BASELINE_MEM))
    low = float(meta.get("low_util_pct", DEF_LOW_UTIL))
    vlow = float(meta.get("very_low_util_pct", DEF_VERY_LOW_UTIL))
    high = float(meta.get("high_util_pct", DEF_HIGH_UTIL))
    off = float(meta.get("offhours_save_frac", DEF_OFFHOURS_SAVE))
    reserved = float(meta.get("reserved_save_frac", DEF_RESERVED_SAVE))

    cost = monthly_cost(cpu, mem, meta) if running else 0.0
    findings = []
    util_str = ("%.1f%%" % util) if util is not None else "unknown"
    findings.append(_f("C0", "Monthly cost", name, "INFO",
                      "%s vCPU / %s GB, util %s -> ~%s/mo%s" % (
                          cpu, mem, util_str, _money(cost),
                          "" if running else " (stopped)")))

    best = 0.0
    if not running:
        return findings, cost, best

    # R1 right-size (does not need utilization; only counts toward fleet
    # potential when the runner is not heavily utilized — a busy runner likely
    # needs its cores).
    if (cpu and cpu > base_cpu) or (mem and mem > base_mem):
        resized = (min(cpu or 0, base_cpu) * _rates(meta)[0]
                   + min(mem or 0, base_mem) * _rates(meta)[1]) * _rates(meta)[2]
        saving = max(cost - resized, 0.0)
        findings.append(_f("R1", "Right-size", name, "REVIEW",
                          "%svCPU/%sGB -> %svCPU/%sGB saves ~%s/mo (validate workload)" % (
                              cpu, mem, min(cpu, base_cpu), min(mem, base_mem), _money(saving)),
                          saving))
        if util is None or util < high:
            best = max(best, saving)

    # R2 scale-to-zero (off-hours)
    if util is not None and util < low:
        saving = cost * off
        findings.append(_f("R2", "Scale-to-zero", name, "SAVE",
                          "util %.1f%% -> off-hours stop saves ~%s/mo" % (util, _money(saving)),
                          saving))
        best = max(best, saving)

    # R3 ARC migration (very low utilization)
    if util is not None and util < vlow:
        saving = cost * (1.0 - util / 100.0)
        findings.append(_f("R3", "ARC migration", name, "SAVE",
                          "util %.1f%% -> ARC native scale-to-zero saves up to ~%s/mo (structural)" % (
                              util, _money(saving)),
                          saving))
        best = max(best, saving)

    # R4 reserved instance (steady high utilization)
    if util is not None and util >= high:
        saving = cost * reserved
        findings.append(_f("R4", "Reserved capacity", name, "INFO",
                          "util %.1f%% steady -> 1yr reserved/commitment ~%s/mo off" % (
                              util, _money(saving)),
                          saving))

    if util is None:
        findings.append(_f("U0", "Utilization", name, "INFO",
                          "utilization unknown (no mapped repo / job history)"))
    elif best == 0.0 and util < high:
        findings.append(_f("OK", "Right-sized", name, "OK",
                          "reasonably sized & utilized; no change recommended"))
    return findings, cost, best


def evaluate(doc):
    meta = doc.get("meta") or {}
    findings = []
    total_cost = 0.0
    total_savings = 0.0
    for c in doc.get("containers") or []:
        fs, cost, best = _audit_container(c, meta)
        findings.extend(fs)
        total_cost += cost
        total_savings += best

    summary = {
        "monthly_cost": round(total_cost, 2),
        "potential_savings": round(total_savings, 2),
        "optimized_cost": round(total_cost - total_savings, 2),
        "savings_pct": round((total_savings / total_cost * 100.0), 1) if total_cost else 0.0,
        "rate_source": (meta.get("rates") or {}).get("source", "static-default"),
        "region": meta.get("region", "eastus"),
    }
    overall = "SAVINGS AVAILABLE" if total_savings > 0.005 else "OPTIMIZED"
    return {"meta": meta, "findings": findings, "summary": summary, "overall": overall}


_EMOJI = {"OK": "✅", "REVIEW": "🔧", "SAVE": "💰", "INFO": "ℹ️"}
_ORDER = {"SAVE": 3, "REVIEW": 2, "INFO": 1, "OK": 0}


def render_markdown(result):
    s = result["summary"]
    L = []
    L.append("# Runner Cost Optimizer — %s" % result["overall"])
    L.append("")
    L.append("Fleet: **%s/mo** now → **%s/mo** optimized "
             "(**save ~%s/mo, %.1f%%**)  ·  rates: %s, %s" % (
                 _money(s["monthly_cost"]), _money(s["optimized_cost"]),
                 _money(s["potential_savings"]), s["savings_pct"],
                 s["rate_source"], s["region"]))
    L.append("")
    L.append("> Monetary figures are estimates. See references/pricing.md.")
    L.append("")
    L.append("| ! | ID | Recommendation | Runner | Detail | ~Saving/mo |")
    L.append("|---|----|----------------|--------|--------|-----------:|")
    ordered = sorted(result["findings"],
                     key=lambda f: (f["subject"], -_ORDER.get(f["status"], 0), f["id"]))
    for f in ordered:
        sv = _money(f["saving"]) if f["saving"] else ""
        L.append("| %s | %s | %s | %s | %s | %s |" % (
            _EMOJI.get(f["status"], ""), f["id"], f["title"], f["subject"], f["detail"], sv))
    return "\n".join(L) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Self-hosted runner cost-optimization engine")
    ap.add_argument("input", nargs="?", help="normalized JSON (default: stdin)")
    ap.add_argument("--json", action="store_true", help="emit JSON report")
    ap.add_argument("--strict", action="store_true", help="non-zero exit if a SAVE is found")
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

    if args.strict and any(f["status"] == "SAVE" for f in result["findings"]):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
