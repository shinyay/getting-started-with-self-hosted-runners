# Verification — prove a migrated workflow works

After migrating, confirm a workflow actually runs **green on a self-hosted
runner**.

## Prerequisites

- The workflow has a `workflow_dispatch` trigger on the default branch (so it can
  be dispatched on demand). Most CI workflows already do, or add it.
- A self-hosted runner is registered and **online** for the repo. Bring one up
  with the **ghrunner-provision** skill (use the `ghrunner` v0.6.3+ image).

## Run the verifier

```bash
./.github/skills/runner-workflow-onboard/scripts/verify-migration.sh \
  OWNER/REPO --workflow ci.yml --runner <runner-name>
```

It dispatches the workflow, waits for a **new** run (no stale-run race), and
asserts:

- `conclusion == success`, and
- the job's labels include `self-hosted` (i.e. the migration actually retargeted
  it), and
- (optional) it ran on `--runner <name>`.

## Manual equivalent

```bash
gh workflow run ci.yml --repo OWNER/REPO --ref main
RID=$(gh run list --repo OWNER/REPO --workflow ci.yml -L1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RID" --repo OWNER/REPO --exit-status
gh api repos/OWNER/REPO/actions/runs/$RID/jobs \
  --jq '.jobs[] | {conclusion, runner: .runner_name, labels: [.labels[].name]}'
```

## On failure

- Job stuck `queued` → labels don't match any runner: re-check the migrated
  `runs-on` vs the runner's labels.
- A step fails on a missing tool → runner-image gap; bump the image
  (`ghrunner-ops` A4 + A3). Use the **ghrunner-triage** skill to classify the
  failure signature.
