# Classification reference

## `runs-on` → strategy buckets

`runson.py::classify_runs_on` maps each `runs-on` value to a bucket:

| `runs-on` value | Bucket | Notes |
|-----------------|--------|-------|
| `ubuntu-*`, `windows-*`, `macos-*` | **github_hosted** | standard GitHub-hosted images |
| `[ubuntu-latest]` (list of hosted) | **github_hosted** | flow list, all hosted |
| `self-hosted` / `[self-hosted, linux, x64]` | **self_hosted** | the `self-hosted` label |
| `my-custom-label` (bare custom) | **self_hosted** | almost always a self-hosted runner label* |
| `${{ matrix.os }}` and any expression | **dynamic** | cannot resolve statically — review |
| `runs-on:\n  group: name` | **group_review** | larger-runner group OR self-hosted group — verify |

\* A bare custom label *could* be a GitHub **larger runner** with a custom name.
The tool leans `self_hosted` and you confirm; this is the same ambiguity GitHub
itself surfaces only in the UI.

**Workflow strategy** = aggregate of its jobs' buckets. **Repo strategy** =
aggregate of all its workflows: `github_hosted` / `self_hosted` / `mixed`
(both) / `dynamic` / `none` (no workflows).

## `runs-on` extraction

`runson.py::extract_runs_on(text)` parses a workflow YAML file (no YAML
dependency) and returns every `runs-on` value, handling:

- inline scalar — `runs-on: ubuntu-latest`
- inline flow list — `runs-on: [self-hosted, linux]`
- block list —
  ```yaml
  runs-on:
    - self-hosted
    - x64
  ```
- group mapping — `runs-on:\n  group: my-runners` → `group:`
- trailing `# comments` are stripped

## "Active" definition

A repo is **Active** when **Actions is enabled** AND either:

- a workflow **run occurred within `--active-days`** (default 30), OR
- a **self-hosted runner is online** for the repo.

A repo with **Actions disabled** is **Non-active** (`ACTIONS_DISABLED`). An
enabled-but-inactive repo with workflows is `DORMANT`. (GitHub also auto-disables
individual workflows after 60 days of repo inactivity — the report shows the
disabled-workflow count per repo.)

## Flags

| Flag | Meaning | Suggested action |
|------|---------|------------------|
| **SELF_HOSTED_BUT_OFFLINE** | self-hosted strategy, no online **repo-level** runner | provision/recover a runner (`ghrunner-provision`/`ghrunner-ops`) or migrate back to hosted |
| **HOSTED_CANDIDATE** | GitHub-hosted & active, no unresolved dynamic jobs | candidate to migrate to self-hosted (`runner-workflow-onboard`) |
| **ACTIONS_DISABLED** | repo Actions disabled | Non-active |
| **DORMANT** | enabled but not active | review whether still needed |
| **DYNAMIC_REVIEW** | a `runs-on` is an expression | confirm manually |
| **GROUP_REVIEW** | a `runs-on` uses `group:` | could be a larger-runner group OR a self-hosted group — confirm |
| **CUSTOM_LABEL_REVIEW** | a bare custom label is used | probably self-hosted, but could be a custom larger runner — confirm |
| **NO_WORKFLOWS** | no workflows present | informational |

## Known limitations

- **Org/enterprise runners are not visible** via `repos/{repo}/actions/runners`,
  so a repo served only by org-level self-hosted runners may be flagged
  `SELF_HOSTED_BUT_OFFLINE`. The flag fires only when there is concrete
  self-hosted/custom-label evidence (never for `group:`- or `dynamic`-only repos).
- **`SELF_HOSTED_BUT_OFFLINE` does not match required labels** — it checks only
  whether *any* repo-level runner is online, not whether one matches the job's
  exact labels. Treat it as a strong hint, then verify.
- **GitHub larger runners** can use custom names indistinguishable from
  self-hosted labels; those surface as `CUSTOM_LABEL_REVIEW` / `GROUP_REVIEW`.
