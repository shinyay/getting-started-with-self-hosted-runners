# Diagnostics — evidence collection

How to identify the failing run/job/runner and pull the right logs per platform.
All commands are **read-only**.

## 1. Identify the run, job, step, and runner

```bash
REPO="owner/repo"

# Most recent failed run id
RUN_ID="$(gh run list --repo "$REPO" --status failure -L 1 --json databaseId --jq '.[0].databaseId')"

# Run summary (status, conclusion, which workflow)
gh run view "$RUN_ID" --repo "$REPO"

# Per-job detail: which job failed, on which runner, at which step
gh api "repos/$REPO/actions/runs/$RUN_ID/jobs" \
  --jq '.jobs[] | select(.conclusion=="failure")
        | {job: .name, runner: .runner_name,
           failed_step: (.steps[]? | select(.conclusion=="failure") | .name)}'

# The failed step logs (the signature source)
gh run view "$RUN_ID" --repo "$REPO" --log-failed
```

The `runner_name` is the link to the host. For this repo's ACI fleet it looks
like `ghrunner-aci-NN`.

## 2. Map `runner_name` → container → repo (ACI)

The container↔repo mapping lives in `docs/runner-registry.md`. Confirm with:

```bash
grep -n "ghrunner-aci-NN" docs/runner-registry.md     # NN = the runner number
```

## 3. Pull platform logs

### ACI (this repo's fleet)

```bash
# Do NOT 'az account set'. If the RG is unreachable, add --subscription <id>.
az container show -g ghrunner-rg -n ghrunner-aci-NN --query instanceView.state -o tsv
az container logs -g ghrunner-rg -n ghrunner-aci-NN
```

### VM runner

```bash
sudo systemctl status actions.runner.*.service
sudo journalctl -u actions.runner.*.service --since "30 min ago" --no-pager
df -h /home/runner                                   # disk
curl -sS -o /dev/null -w "%{http_code}\n" https://api.github.com   # egress
```

### AKS / ARC

```bash
kubectl get pods -n arc-systems
kubectl get pods -n arc-runners
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50
kubectl get autoscalingrunnersets,ephemeralrunnersets,ephemeralrunners -n arc-runners
# If the API host fails to resolve, the cluster may be Stopped -> see INF-AKS-STOPPED
```

## 4. Classify and hand off

Feed the collected log text into [failure-catalog.md](./failure-catalog.md)
(or run [../scripts/triage.sh](../scripts/triage.sh)). Match a signature → read
its root cause and handoff. Apply the fix via the **`ghrunner-ops`** skill
(`A2`/`A3`/`A4`/`A6`) or the cited doc — never from this skill.

## Quick reference: list a repo's runners and labels

```bash
gh api "repos/$REPO/actions/runners" \
  --jq '.runners[] | {name, status, busy, labels: [.labels[].name]}'
```

Useful for `CFG-LABEL` (does any runner's labels match the workflow `runs-on`?).
