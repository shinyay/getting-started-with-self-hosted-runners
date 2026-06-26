# Verification Reference — prove the runner works

Two checks make a runner "verified": it **registers online**, and it **runs a
real job to green**.

## 1. Online check

```bash
gh api "repos/<owner>/<repo>/actions/runners" \
  --jq '.runners[] | select(.name=="<runner-name>") | {name, status, busy, labels:[.labels[].name]}'
```

Expect `status: "online"`. If it never appears, the runner failed to register —
check construct logs (ACI: `az container logs`) and the **ghrunner-triage** skill
(`AUTH-TOKEN-TTL`, `CFG-LABEL`).

## 2. Green-job check (smoke workflow)

The smoke workflow is minimal and targets the runner's labels. `verify-runner.sh`
writes it, dispatches it, polls, and asserts success. Reference content:

```yaml
name: Runner Smoke Test
on:
  workflow_dispatch:
jobs:
  smoke:
    runs-on: [self-hosted, linux, <your-labels>]   # e.g. azure, aci
    steps:
      - name: Runner identity
        run: |
          echo "Runner: ${RUNNER_NAME:-unknown}"
          echo "OS: $(uname -srm)"
      - name: Prove execution
        run: echo "Self-hosted runner smoke test OK"
```

### Dispatch + poll (what `verify-runner.sh` automates)

```bash
# Put the workflow on the default branch (workflow_dispatch needs it there).
# Use git+SSH so you don't need the PAT 'workflow' scope to add a workflow file:
git clone --depth 1 git@github.com:<owner>/<repo>.git /tmp/smoke && cd /tmp/smoke
mkdir -p .github/workflows && cp runner-smoke.yml .github/workflows/
git add .github/workflows/runner-smoke.yml && git commit -m "ci: add runner smoke test"
git push origin HEAD                              # SSH push — no 'workflow' scope needed

gh workflow run runner-smoke.yml --repo <owner>/<repo>   # dispatch needs only 'repo' scope
sleep 5
RID=$(gh run list --repo <owner>/<repo> --workflow runner-smoke.yml -L1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RID" --repo <owner>/<repo> --exit-status     # non-zero if the run fails
gh api "repos/<owner>/<repo>/actions/runs/$RID/jobs" \
  --jq '.jobs[] | {conclusion, runner: .runner_name}'        # confirm it ran on our runner
```

> [!NOTE]
> Adding a file under `.github/workflows/` via a PAT/HTTPS requires the
> `workflow` token scope; **pushing over SSH does not**. `verify-runner.sh`
> clones+pushes over SSH for this reason. Dispatching an existing workflow only
> needs `repo`.

A pass = run `conclusion: success` **and** the job's `runner_name` equals the
runner we provisioned.

## 3. Teardown checklist (leave zero residue)

`teardown.sh` performs these; run it after a test or to decommission:

- [ ] Deregister the runner (mint `remove-token`, or `az container delete`
      triggers the entrypoint's graceful deregister on SIGTERM)
- [ ] `az container delete -g ghrunner-rg -n <name> --yes` (ACI) / `docker rm -f`
      (local) / platform teardown (VM/ARC)
- [ ] Delete throwaway ACR tag: `az acr repository delete -n shinyayacr202604
      --image ghrunner:<tag> --yes`
- [ ] Remove the smoke workflow from the repo (or delete the throwaway repo)
- [ ] Confirm: `az container list -g ghrunner-rg -o table` has no `<name>`, and
      `gh api repos/<owner>/<repo>/actions/runners` no longer lists it

> [!WARNING]
> Never delete or modify production fleet containers (`ghrunner-aci-01..11`) or
> the `:latest` image. Test resources use a `*-smoke` name and a throwaway tag.
