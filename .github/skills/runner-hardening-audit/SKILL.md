---
name: runner-hardening-audit
license: MIT
description: >-
  Audit and harden the self-hosted GitHub Actions runner fleet (ACI containers,
  plus the VM and AKS/ARC alternatives) and a repository's Actions settings. Use
  when you need to scan for security misconfigurations and check posture: stale or unpinned
  runner images, non-ephemeral runners, long-lived PAT credentials baked into
  containers, public network exposure, untrusted image provenance, over-broad
  default workflow permissions, fork-PR approval gaps, and the high-risk
  public-repo + self-hosted-runner combination. Read-only: it produces a
  PASS/WARN/FAIL scorecard with remediation you apply yourself, never mutating
  anything, and never reads secret values. Verify findings against the
  docs/runner-registry.md ledger. Pairs with ghrunner-ops, ghrunner-triage,
  ghrunner-image-release, gha-azure-oidc, github-app-runner-auth. Trigger
  phrases: harden runners, runner security audit, self-hosted runner hardening,
  audit runner fleet, runner posture, secure self-hosted runner, check runner
  permissions.
---

# runner-hardening-audit — Self-Hosted Runner Security Posture

A **read-only** security audit for the self-hosted runner fleet in this
repository. It collects live facts (Azure ACI + GitHub Actions settings),
applies a catalog of hardening controls, and prints a **PASS/WARN/FAIL
scorecard** with remediation. It never mutates anything and never reads a
secret value — only environment-variable *names*.

The control catalog is **[references/controls.md](./references/controls.md)**;
how to run and interpret results is in
**[references/audit-runbook.md](./references/audit-runbook.md)**.

## When to Use This Skill

- Periodically review the security posture of the ACI runner fleet
- Vet a repository's Actions settings before attaching a self-hosted runner
- Catch stale/unpinned images, non-ephemeral runners, or PAT-in-env drift
- Gate CI on runner hardening (`--strict` exit code)
- Before/after onboarding a repo with `runner-workflow-onboard`

## What It Checks

| Group | Controls |
|-------|----------|
| **A — ACI fleet** (live) | A1 image freshness · A2 ephemeral · A3 auth method (long-lived cred in env) · A4 public exposure · A5 image provenance · A6 health |
| **B — GitHub repo** (live, `--repo`) | B1 default workflow permissions · B2 fork-PR approval · B3 allowed-actions policy · B4 public-repo + self-hosted runner · B5 runner sanity |
| **C — VM / ARC** | C1 VM hardening · C2 ARC hardening (catalog + best-effort) |

Verdict: any `FAIL` → **FAIL**; else any `WARN` → **WARN**; else **PASS**.
`MANUAL` items need a human check; `INFO` is advisory.

## Prerequisites

- `az` CLI authenticated and able to reach **`ghrunner-rg`** (for ACI audit)
- `gh` CLI authenticated as the fleet owner (**`shinyay`**) (for repo audit)
- `python3` (standard library only — no third-party packages)

## Critical Guardrails

> [!IMPORTANT]
> This skill is **read-only by design**. Keep it that way.

- **Never mutates** Azure or GitHub. Remediation is *printed* for you to apply
  (Human-in-the-Loop).
- **Never reads secret values** — only environment-variable names. Do not change
  the collectors to read `.value`.
- **Never run `az account set`.** `~/.azure` may be shared with other sessions;
  target a subscription with `--subscription <id>`.
- **Do not commit reports.** The `.gitignore` excludes `reports/`, `*.audit.json`,
  `*.audit.md`. Never commit `resume` or any `*.pem`.

## The Audit Flow

### Step 1 — Choose the target (menu)

Use the **`ask_user`** tool to offer a single-select target:

- **ACI fleet** — audit the `ghrunner-rg` containers
- **Repository** — audit one `owner/repo`'s Actions settings
- **Both**

Collect the subscription id (for ACI) and/or `owner/repo` (for GitHub).

### Step 2 — Run the audit (read-only)

```bash
S=.github/skills/runner-hardening-audit/scripts

# ACI fleet
bash "$S/audit.sh" -g ghrunner-rg --subscription <SUB>

# A repository
bash "$S/audit.sh" --repo OWNER/REPO

# Both, and save a copy (gitignored)
bash "$S/audit.sh" -g ghrunner-rg --subscription <SUB> --repo OWNER/REPO \
  --out fleet.audit.md
```

### Step 3 — Present the scorecard & remediate (HITL)

- Show the scorecard. Lead with `FAIL`, then `WARN`, then `MANUAL`.
- For each finding, point to the matching control in
  [controls.md](./references/controls.md) and the skill that fixes it
  (e.g. `ghrunner-ops` for A2, `github-app-runner-auth`/`gha-azure-oidc` for A3,
  `ghrunner-image-release` for A1/A5, `ghrunner-triage` for A6).
- Apply fixes only with explicit user approval.

## Scripts

| Script | Role | I/O |
|--------|------|-----|
| `scripts/collect.sh` | Live, read-only collectors (`az`/`gh`) → normalized JSON | live |
| `scripts/normalize.py` | Pure transform: raw JSON + ledger → normalized doc | pure |
| `scripts/audit_rules.py` | Pure rule engine: normalized doc → scorecard | pure |
| `scripts/audit.sh` | Orchestrator (`collect` → `rules`), exit code | live |
| `scripts/test_audit_rules.py` | Offline unit tests (PASS + FAIL paths) | pure |

The two pure Python modules are unit-tested offline, so audit logic is verified
without touching the cloud. Run `--help` on any script for usage.

## Verify

```bash
S=.github/skills/runner-hardening-audit/scripts
python3 "$S/test_audit_rules.py"                          # offline unit tests
python3 "$S/audit_rules.py" "$S/fixtures/bad-fleet.json"  # demo: ❌ FAIL
python3 "$S/audit_rules.py" "$S/fixtures/good-fleet.json" # demo: ✅ PASS
```

## Related Skills

- **ghrunner-ops** — fleet inventory & lifecycle (fix A2, A6)
- **ghrunner-triage** — failure root-cause (A6)
- **ghrunner-image-release** — image build/release (A1, A5)
- **gha-azure-oidc** / **github-app-runner-auth** — passwordless auth (A3)
- **vm-runner-ops** / **arc-ops** — VM and AKS/ARC lifecycle (Group C)
- Ledger: **`docs/runner-registry.md`**
