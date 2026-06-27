# Verification — a VM runner works

Prove the VM's self-hosted runner registered and runs a job **green**.

## Steps

1. Provision the VM (`vm-up.sh`). The runner registers via cloud-init a few
   minutes after the deployment returns.
2. Verify:
   ```bash
   ./.github/skills/vm-runner-ops/scripts/vm-verify.sh OWNER/REPO \
     --runner ghrunner-vm-01 --labels azure,linux,x64,vm
   ```
   It waits for the runner to be **online** (cloud-init delay, up to 10 min),
   pushes a `workflow_dispatch` smoke workflow over git+SSH, dispatches it, and
   asserts `conclusion=success` on a self-hosted runner.

## If the runner never comes online

cloud-init may still be installing, or registration failed. SSH in and check:
```bash
ssh azureuser@<public-ip>
sudo cat /var/log/cloud-init-output.log        # look for config.sh / svc.sh output
sudo systemctl status 'actions.runner.*'
```
Common causes:
- **Registration token expired** (>1h between mint and boot) → recreate the VM
  with a fresh token (`vm-up.sh` mints one each run).
- **No outbound 443** to GitHub → check the NSG / egress.
- Diagnose signatures with the **ghrunner-triage** skill (`INF-OFFLINE`,
  `INF-DNS`).

## Manual equivalent

```bash
gh workflow run vm-smoke.yml --repo OWNER/REPO --ref main
RID=$(gh run list --repo OWNER/REPO --workflow vm-smoke.yml -L1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RID" --repo OWNER/REPO --exit-status
gh api repos/OWNER/REPO/actions/runs/$RID/jobs --jq '.jobs[] | {conclusion, runner: .runner_name}'
```
