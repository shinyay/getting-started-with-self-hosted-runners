# Audit Runbook — how to run & interpret

## Pipeline

```
collect.sh  (live, read-only)        audit_rules.py (pure engine)
  az container list / gh api  ──►  normalize.py  ──►  scorecard (md/json)
```

- `collect.sh` runs only `az … show/list` and `gh api` GETs, then calls
  `normalize.py`. **No mutations**, and only environment-variable *names* are
  recorded — never a secret value.
- `normalize.py` is a **pure transform** (no I/O) → unit-testable.
- `audit_rules.py` is the **pure rule engine** (no I/O) → unit-testable.
- `audit.sh` chains them and sets the exit code.

## Run it

```bash
S=.github/skills/runner-hardening-audit/scripts
SUB=<subscription-id>

# Audit the ACI fleet:
bash "$S/audit.sh" -g ghrunner-rg --subscription "$SUB"

# Audit a repository's Actions settings:
bash "$S/audit.sh" --repo OWNER/REPO

# Both, machine-readable, fail CI on WARN too, save a copy:
bash "$S/audit.sh" -g ghrunner-rg --subscription "$SUB" --repo OWNER/REPO \
  --json --strict --out fleet.audit.json
```

Flags: `-g/--resource-group`, `--subscription`, `--repo`, `--registry`,
`--json`, `--strict`, `--out`. At least one of `-g`/`--repo` is required.

## Exit codes

| Condition | default | `--strict` |
|-----------|:-------:|:----------:|
| any FAIL  | 1 | 1 |
| any WARN  | 0 | 1 |
| clean     | 0 | 0 |

`MANUAL` items never affect the exit code — resolve them by hand.

## Interpreting the scorecard

- Findings are sorted **most-urgent first** (FAIL → WARN → MANUAL → INFO → PASS).
- The **Remediation** section lists only FAIL/WARN items with a suggested fix.
  Apply them yourself — this tool never mutates.
- See [controls.md](./controls.md) for each control's rationale and fix.

## Normalized document schema (engine input)

```jsonc
{
  "meta": {
    "resource_group": "ghrunner-rg",
    "latest_image_tag": "v0.6.3",                 // from the registry ledger
    "trusted_registry": "shinyayacr202604.azurecr.io"
  },
  "containers": [                                  // ACI fleet (optional)
    {
      "name": "ghrunner-aci-01",
      "state": "Running",
      "image": "…/ghrunner:v0.6.0",
      "image_tag": "v0.6.0",
      "image_registry": "shinyayacr202604.azurecr.io",
      "restart_count": 9,
      "ephemeral": true,                          // EPHEMERAL=true (config flag)
      "restart_policy": "Always",
      "provisioning_state": "Succeeded",          // group lifecycle (not runtime)
      "env_keys": ["EPHEMERAL", "GH_PAT"],        // NAMES only, never values
      "ip_type": null,                            // "Public" or null
      "repo": "owner/name",                       // mapped from the ledger
      "repo_visibility": "public"                 // when known
    }
  ],
  "repo": {                                        // GitHub side (optional)
    "full_name": "owner/name",
    "visibility": "public",
    "allowed_actions": "all",                     // all|selected|local_only
    "default_workflow_permissions": "write",      // read|write
    "fork_pr_approval": "unknown",
    "self_hosted_runners": [{"name": "…", "status": "online", "ephemeral": false}]
  }
}
```

## Verification (run before trusting changes)

```bash
S=.github/skills/runner-hardening-audit/scripts

# 1. Offline unit tests (deterministic, no cloud) — PASS and FAIL paths:
python3 "$S/test_audit_rules.py"

# 2. Render the bundled fixtures:
python3 "$S/audit_rules.py" "$S/fixtures/good-fleet.json"   # ✅ PASS
python3 "$S/audit_rules.py" "$S/fixtures/bad-fleet.json"    # ❌ FAIL
```

## CI usage

Add a scheduled job that runs `audit.sh --strict` against your fleet/repo and
fails the build on regressions. Because the engine is pure, you can also feed it
a pre-collected JSON document in air-gapped CI:

```bash
python3 "$S/audit_rules.py" --strict fleet.audit.json
```
