#!/usr/bin/env python3
#
# audit_rules.py - pure security-posture rule engine for self-hosted runners.
#
# Input  : a normalized JSON document (see references/audit-runbook.md schema)
#          produced by collect.sh, read from a file argument or stdin.
# Output : a Markdown (default) or JSON scorecard of findings + an overall
#          verdict. This module performs NO I/O against Azure or GitHub and
#          never reads secret values - it only reasons over collected facts,
#          so it is fully deterministic and unit-testable offline.
#
# Usage:
#   audit_rules.py [INPUT.json] [--json] [--strict]
#   cat doc.json | audit_rules.py
#
# Exit code: 0 when there is no FAIL (WARN tolerated). With --strict, any WARN
# or FAIL yields a non-zero exit (for CI gating). A MANUAL item never fails.

import argparse
import json
import re
import sys

# Severity ordering for sorting (higher = more urgent).
SEV = {"FAIL": 4, "WARN": 3, "MANUAL": 2, "INFO": 1, "PASS": 0}

# Env-variable NAMES that indicate a long-lived credential baked into the
# container (as opposed to a short-lived registration token / OIDC / App).
# These are matched by name only; values are never collected or inspected.
STATIC_CRED_KEYS = ["GH_PAT", "RUNNER_TOKEN", "GITHUB_TOKEN", "PAT", "GH_TOKEN"]

_SEMVER = re.compile(r"v?(\d+)\.(\d+)\.(\d+)")


def _parse_semver(tag):
    if not tag:
        return None
    m = _SEMVER.search(tag)
    if not m:
        return None
    return tuple(int(x) for x in m.groups())


def _finding(cid, title, group, subject, status, detail, remediation=""):
    return {
        "id": cid,
        "title": title,
        "group": group,
        "subject": subject,
        "status": status,
        "detail": detail,
        "remediation": remediation,
    }


# --------------------------------------------------------------------------
# Group A - ACI fleet controls (one set of findings per container)
# --------------------------------------------------------------------------
def _audit_container(c, meta):
    out = []
    name = c.get("name", "?")
    latest = meta.get("latest_image_tag")
    trusted = meta.get("trusted_registry")
    visibility = c.get("repo_visibility")
    tag = c.get("image_tag")

    # A1 image-freshness
    if tag and latest and tag == latest:
        out.append(_finding("A1", "Image freshness", "ACI", name, "PASS",
                            "running latest released image %s" % tag))
    elif tag == "latest" or tag is None:
        out.append(_finding("A1", "Image freshness", "ACI", name, "WARN",
                            "image tag is unpinned/unknown (%r)" % tag,
                            "Pin to the latest released tag %s and redeploy." % latest))
    else:
        cur, lat = _parse_semver(tag), _parse_semver(latest)
        if cur and lat and cur < lat:
            out.append(_finding("A1", "Image freshness", "ACI", name, "WARN",
                                "stale image %s (latest is %s)" % (tag, latest),
                                "Recreate the container on %s (ACI keeps the "
                                "deploy-time snapshot)." % latest))
        else:
            out.append(_finding("A1", "Image freshness", "ACI", name, "PASS",
                                "image %s" % tag))

    # A2 ephemeral
    eph = c.get("ephemeral") is True
    pol = (c.get("restart_policy") or "").lower()
    if eph and pol == "always":
        out.append(_finding("A2", "Ephemeral runner", "ACI", name, "PASS",
                            "EPHEMERAL=true + restart-policy Always"))
    else:
        sev = "FAIL" if visibility == "public" else "WARN"
        out.append(_finding("A2", "Ephemeral runner", "ACI", name, sev,
                            "non-ephemeral runner (eph=%s policy=%s)%s" % (
                                c.get("ephemeral"), c.get("restart_policy"),
                                " on a PUBLIC repo" if visibility == "public" else ""),
                            "Re-register with EPHEMERAL=true and "
                            "--restart-policy Always to avoid job-to-job state reuse."))

    # A3 auth-method (long-lived credential baked in env)
    keys = c.get("env_keys") or []
    static = [k for k in keys if k in STATIC_CRED_KEYS]
    if static:
        out.append(_finding("A3", "Runner auth method", "ACI", name, "WARN",
                            "long-lived credential env present: %s" % ", ".join(sorted(static)),
                            "Prefer a short-lived registration token, OIDC, or a "
                            "GitHub App. Rotate the credential and scope it minimally."))
    else:
        out.append(_finding("A3", "Runner auth method", "ACI", name, "PASS",
                            "no long-lived credential env detected"))

    # A4 public-exposure
    iptype = (c.get("ip_type") or "").lower()
    if iptype == "public":
        out.append(_finding("A4", "Network exposure", "ACI", name, "WARN",
                            "container has a PUBLIC IP; runners should be egress-only",
                            "Remove the public IP / inbound ports; runners only "
                            "need outbound HTTPS to GitHub."))
    else:
        out.append(_finding("A4", "Network exposure", "ACI", name, "PASS",
                            "no public ingress (egress-only)"))

    # A5 image-provenance
    reg = c.get("image_registry")
    if trusted and reg and reg != trusted:
        out.append(_finding("A5", "Image provenance", "ACI", name, "FAIL",
                            "image from untrusted registry %s" % reg,
                            "Rebuild/pull from the trusted registry %s." % trusted))
    elif tag == "latest":
        out.append(_finding("A5", "Image provenance", "ACI", name, "WARN",
                            "uses mutable :latest (no immutable provenance)",
                            "Deploy an immutable semantic tag (e.g. %s)." % latest))
    else:
        out.append(_finding("A5", "Image provenance", "ACI", name, "PASS",
                            "trusted registry, pinned tag"))

    # A6 health (distinguish provisioning vs runtime state; list often omits runtime)
    state = c.get("state")
    prov = c.get("provisioning_state")
    if prov and prov not in ("Succeeded",):
        out.append(_finding("A6", "Runner health", "ACI", name, "WARN",
                            "provisioning state is %s (expected Succeeded)" % prov,
                            "Investigate with ghrunner-triage; redeploy if failed."))
    elif state in (None, "Running"):
        out.append(_finding("A6", "Runner health", "ACI", name, "PASS",
                            "running state %s" % (state or "not reported (provisioned OK)")))
    elif state in ("Terminated", "Waiting") and eph:
        out.append(_finding("A6", "Runner health", "ACI", name, "PASS",
                            "ephemeral runner cycling (%s)" % state))
    else:
        out.append(_finding("A6", "Runner health", "ACI", name, "WARN",
                            "container state is %s (expected Running)" % state,
                            "Investigate with ghrunner-triage; redeploy if crashed."))
    return out


# --------------------------------------------------------------------------
# Group B - GitHub repository controls
# --------------------------------------------------------------------------
def _audit_repo(repo):
    out = []
    name = repo.get("full_name", "?")
    visibility = repo.get("visibility")
    runners = repo.get("self_hosted_runners") or []

    # B1 default workflow permissions
    perm = repo.get("default_workflow_permissions")
    if perm == "read":
        out.append(_finding("B1", "Default GITHUB_TOKEN permissions", "GitHub", name,
                            "PASS", "default_workflow_permissions=read"))
    elif perm == "write":
        out.append(_finding("B1", "Default GITHUB_TOKEN permissions", "GitHub", name,
                            "WARN", "default_workflow_permissions=write (over-broad)",
                            "Set default permissions to read in "
                            "Settings > Actions > Workflow permissions."))
    else:
        out.append(_finding("B1", "Default GITHUB_TOKEN permissions", "GitHub", name,
                            "MANUAL", "could not determine default permissions",
                            "Verify Settings > Actions > Workflow permissions = read."))

    # B2 fork-PR approval
    fpr = repo.get("fork_pr_approval")
    if fpr in ("all", "everyone"):
        out.append(_finding("B2", "Fork PR approval", "GitHub", name, "PASS",
                            "approval required for all outside contributors"))
    elif fpr in (None, "", "unknown"):
        out.append(_finding("B2", "Fork PR approval", "GitHub", name, "MANUAL",
                            "fork-PR approval policy not exposed via API",
                            "Confirm Settings > Actions > Fork pull request "
                            "workflows requires approval for all outside collaborators."))
    else:
        out.append(_finding("B2", "Fork PR approval", "GitHub", name, "WARN",
                            "fork-PR approval is '%s' (not all)" % fpr,
                            "Require approval for ALL outside collaborators - "
                            "critical when self-hosted runners are present."))

    # B3 allowed actions policy
    allowed = repo.get("allowed_actions")
    if allowed in ("selected", "local_only"):
        out.append(_finding("B3", "Allowed actions policy", "GitHub", name, "PASS",
                            "allowed_actions=%s" % allowed))
    elif allowed == "all":
        out.append(_finding("B3", "Allowed actions policy", "GitHub", name, "WARN",
                            "any action from anywhere is allowed",
                            "Restrict to selected/verified actions in "
                            "Settings > Actions > Actions permissions."))
    else:
        out.append(_finding("B3", "Allowed actions policy", "GitHub", name, "MANUAL",
                            "allowed_actions unknown",
                            "Review Settings > Actions > Actions permissions."))

    # B4 public repo + self-hosted runner (high-risk combo)
    if visibility == "public" and runners:
        out.append(_finding("B4", "Public repo + self-hosted runner", "GitHub", name,
                            "FAIL", "%d self-hosted runner(s) attached to a PUBLIC repo"
                            % len(runners),
                            "Fork PRs can run untrusted code on your runner. Use "
                            "ephemeral runners, require fork-PR approval, or move to "
                            "GitHub-hosted runners for the public repo."))
    elif runners:
        out.append(_finding("B4", "Public repo + self-hosted runner", "GitHub", name,
                            "PASS", "self-hosted runner on a non-public repo"))
    else:
        out.append(_finding("B4", "Public repo + self-hosted runner", "GitHub", name,
                            "PASS", "no self-hosted runners attached"))

    # B5 runner sanity
    offline = [r.get("name") for r in runners if (r.get("status") or "").lower() == "offline"]
    nonephem_pub = [r.get("name") for r in runners
                    if r.get("ephemeral") is False and visibility == "public"]
    if offline:
        out.append(_finding("B5", "Runner registration sanity", "GitHub", name, "WARN",
                            "offline runner(s): %s" % ", ".join(offline),
                            "Deregister stale runners (a lingering token is a risk)."))
    elif nonephem_pub:
        out.append(_finding("B5", "Runner registration sanity", "GitHub", name, "WARN",
                            "non-ephemeral runner(s) on a public repo: %s"
                            % ", ".join(nonephem_pub),
                            "Switch to ephemeral runners for public repos."))
    elif runners:
        out.append(_finding("B5", "Runner registration sanity", "GitHub", name, "PASS",
                            "%d runner(s), none offline" % len(runners)))
    return out


def evaluate(doc):
    meta = doc.get("meta") or {}
    findings = []
    for c in doc.get("containers") or []:
        findings.extend(_audit_container(c, meta))
    if doc.get("repo"):
        findings.extend(_audit_repo(doc["repo"]))

    # Group C - VM/ARC are catalog-level; surface a pointer if not collected.
    if not (doc.get("containers") or doc.get("repo")):
        findings.append(_finding("C0", "No live targets", "Scope", "-", "MANUAL",
                                "no ACI containers or repo were collected",
                                "Pass -g <rg> and/or --repo <owner/repo>."))
    findings.append(_finding("C1", "VM hardening (catalog)", "VM/ARC", "-", "INFO",
                            "NSG no 0.0.0.0/0 SSH, MI least-privilege, OS patched",
                            "See references/controls.md (Group C) for VM/ARC items."))

    counts = {k: 0 for k in SEV}
    for f in findings:
        counts[f["status"]] = counts.get(f["status"], 0) + 1
    if counts.get("FAIL"):
        overall = "FAIL"
    elif counts.get("WARN"):
        overall = "WARN"
    else:
        overall = "PASS"
    return {"meta": meta, "findings": findings, "counts": counts, "overall": overall}


_EMOJI = {"PASS": "✅", "WARN": "⚠️", "FAIL": "❌", "INFO": "ℹ️", "MANUAL": "🔎"}


def render_markdown(result):
    L = []
    o = result["overall"]
    c = result["counts"]
    L.append("# Runner Hardening Audit — %s %s" % (_EMOJI.get(o, ""), o))
    L.append("")
    L.append("FAIL=%d  WARN=%d  MANUAL=%d  INFO=%d  PASS=%d" % (
        c.get("FAIL", 0), c.get("WARN", 0), c.get("MANUAL", 0),
        c.get("INFO", 0), c.get("PASS", 0)))
    L.append("")
    L.append("| ! | ID | Control | Subject | Finding |")
    L.append("|---|----|---------|---------|---------|")
    ordered = sorted(result["findings"], key=lambda f: (-SEV.get(f["status"], 0),
                                                        f["subject"], f["id"]))
    for f in ordered:
        L.append("| %s | %s | %s | %s | %s |" % (
            _EMOJI.get(f["status"], ""), f["id"], f["title"], f["subject"], f["detail"]))
    rem = [f for f in ordered if f["status"] in ("FAIL", "WARN") and f["remediation"]]
    if rem:
        L.append("")
        L.append("## Remediation (review before applying — this tool never mutates)")
        for f in rem:
            L.append("- **%s %s/%s** — %s" % (
                _EMOJI.get(f["status"], ""), f["id"], f["subject"], f["remediation"]))
    return "\n".join(L) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Self-hosted runner hardening rule engine")
    ap.add_argument("input", nargs="?", help="normalized JSON file (default: stdin)")
    ap.add_argument("--json", action="store_true", help="emit JSON scorecard")
    ap.add_argument("--strict", action="store_true", help="WARN also yields non-zero exit")
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

    if result["overall"] == "FAIL":
        return 1
    if args.strict and result["overall"] == "WARN":
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
