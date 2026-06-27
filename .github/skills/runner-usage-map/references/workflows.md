# Census, toggle & migration handoff

## A. Census (read-only)

```bash
S=.github/skills/runner-usage-map/scripts

# Your whole account (owned, non-archived, non-fork):
bash "$S/usage-map.sh" --limit 200

# As CSV (good for many repos / spreadsheets):
bash "$S/usage-map.sh" --limit 200 --format csv --out fleet.usage.csv

# Specific repos, fast (skip workflow-file fetch -> classify by runners only):
bash "$S/usage-map.sh" --repo owner/a --repo owner/b --no-runson

# Gate on broken self-hosted repos (non-zero if any SELF_HOSTED_BUT_OFFLINE):
bash "$S/usage-map.sh" --limit 200 --strict

# Suggest hosted -> self-hosted migrations:
bash "$S/usage-map.sh" --limit 200 --suggest-migrations
```

Flags: `--owner`, `--limit`, `--repo` (repeatable), `--active-days`,
`--no-runson`, `--include-archived`, `--include-forks`, `--format md|csv|json`,
`--out`, `--strict`, `--suggest-migrations`.

Performance: each repo costs ~4 `gh api` GETs plus one per workflow file. For
large accounts use `--limit`, target with `--repo`, or `--no-runson` to skip
file fetches. Progress prints to stderr.

## B. Toggle Active ↔ Non-active (mutation, HITL)

`toggle-actions.sh` is **PREVIEW (dry-run) by default**; add `--apply` to perform
the change. It **refuses any repo in the protect list** (default: this repo) and
is idempotent.

```bash
S=.github/skills/runner-usage-map/scripts

# Preview disabling Actions on a repo:
bash "$S/toggle-actions.sh" --repo owner/repo --disable-actions

# Actually disable (Non-active):
bash "$S/toggle-actions.sh" --repo owner/repo --disable-actions --apply

# Re-enable (Active):
bash "$S/toggle-actions.sh" --repo owner/repo --enable-actions --apply

# Disable a single workflow (by name, file or id):
bash "$S/toggle-actions.sh" --repo owner/repo --disable-workflow ci.yml --apply
```

| Lever | API | Effect |
|-------|-----|--------|
| `--disable-actions` / `--enable-actions` | `PUT /repos/{r}/actions/permissions {enabled}` | repo-level Actions on/off |
| `--disable-workflow` / `--enable-workflow` | `PUT /repos/{r}/actions/workflows/{id}/disable\|enable` | one workflow on/off |

> [!IMPORTANT]
> Mutations are HITL: preview first, confirm, then `--apply`. The **repo you run
> from is auto-protected** (derived via `gh repo view`), and `--protect
> owner/a,owner/b` appends more. Matching is case-insensitive.

## C. GitHub-hosted → Self-hosted (delegated)

This skill **does not reimplement** workflow rewriting — it identifies
`HOSTED_CANDIDATE` repos and hands off to **`runner-workflow-onboard`**:

```bash
# 1) find candidates
bash "$S/usage-map.sh" --limit 200 --suggest-migrations

# 2) migrate one (preview, then --apply), then supply a runner:
bash .github/skills/runner-workflow-onboard/scripts/migrate-workflows.sh owner/repo          # preview
bash .github/skills/runner-workflow-onboard/scripts/migrate-workflows.sh owner/repo --apply  # migrate
bash .github/skills/ghrunner-provision/scripts/provision-aci.sh owner/repo                    # add a runner
```

## Related skills

- **runner-workflow-onboard** — performs the hosted→self-hosted rewrite
- **ghrunner-provision** / **ghrunner-ops** — supply / manage the runner
- **runner-fleet-health** — health of the self-hosted repos found here
- **runner-cost-optimizer** — cost of the self-hosted fleet
