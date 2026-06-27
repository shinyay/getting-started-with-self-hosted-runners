# Control Catalog — Runner Hardening Audit

Each control has an **ID**, a default **severity**, what it checks, **why** it
matters, how it is **detected**, and the **remediation**. The rule engine
(`scripts/audit_rules.py`) emits one of: `PASS`, `WARN`, `FAIL`, `INFO`,
`MANUAL`. The tool is **read-only** — remediation is printed for you to apply.

Overall verdict: any `FAIL` → **FAIL**; else any `WARN` → **WARN**; else
**PASS**. `MANUAL` items never change the verdict but require a human check.

---

## Group A — ACI runner fleet (live)

### A1 · Image freshness · WARN
- **Checks**: the container's running image tag vs the latest released tag
  (top row of the *Image versions* table in `docs/runner-registry.md`).
- **Why**: stale images miss security patches and tool fixes (CVEs, base-image
  updates).
- **Detect**: `image_tag == latest` → PASS; older semver → WARN; `:latest` or
  unknown → WARN (unpinned).
- **Fix**: recreate the container on the latest tag. ACI keeps the *deploy-time*
  snapshot, so pushing a new `:latest` does **not** update a running container.

### A2 · Ephemeral runner · WARN (FAIL on public repo)
- **Checks**: `EPHEMERAL=true` **and** `--restart-policy Always`.
- **Why**: non-ephemeral runners reuse `_work` between jobs → state/secret
  bleed between jobs. On a **public** repo this is a remote-code-execution
  vector via fork PRs, hence **FAIL**.
- **Detect**: env `EPHEMERAL` value + restart policy.
- **Fix**: re-register the runner with `EPHEMERAL=true` and
  `--restart-policy Always` (see `ghrunner-ops`).

### A3 · Runner auth method · WARN
- **Checks**: a long-lived credential baked into the container env
  (`GH_PAT`, `RUNNER_TOKEN`, `GITHUB_TOKEN`, `GH_TOKEN`, `PAT`).
- **Why**: long-lived credentials are high-value, broadly-scoped, and survive
  in the container definition. Short-lived registration tokens, OIDC, or a
  GitHub App are safer.
- **Detect**: environment-variable **names** only — values are never read.
- **Fix**: prefer a short-lived registration token, OIDC (`gha-azure-oidc`), or
  a GitHub App (`github-app-runner-auth`). Rotate and minimally scope any PAT.

### A4 · Network exposure · WARN
- **Checks**: the container group exposes a **public IP** / inbound ports.
- **Why**: runners only need **outbound** HTTPS to GitHub; inbound exposure
  enlarges the attack surface.
- **Detect**: `ipAddress.type == "Public"`.
- **Fix**: remove the public IP / inbound ports (egress-only).

### A5 · Image provenance · FAIL (untrusted registry) / WARN (`:latest`)
- **Checks**: the image comes from the trusted ACR and uses an immutable tag.
- **Why**: images from public/unknown registries or mutable `:latest` lack
  provenance and can be swapped underneath you.
- **Detect**: registry host vs `trusted_registry`; tag `== latest`.
- **Fix**: pull/rebuild from the trusted ACR with an immutable semantic tag.

### A6 · Runner health · WARN
- **Checks**: container state is `Running`.
- **Why**: a `Terminated`/crashed runner may indicate tampering or instability.
- **Detect**: `instanceView.currentState.state`.
- **Note**: high `restartCount` is **normal** for `EPHEMERAL=true` +
  `restart-policy Always` (one job → exit → restart) and is not flagged.
- **Fix**: triage with `ghrunner-triage`; redeploy if crashed.

---

## Group B — GitHub repository Actions settings (live, `--repo`)

### B1 · Default `GITHUB_TOKEN` permissions · WARN
- **Checks**: repo default workflow permissions are `read`, not `write`.
- **Why**: `write` grants every workflow broad repo write by default
  (supply-chain risk).
- **Detect**: `GET /repos/{o}/{r}/actions/permissions/workflow`.
- **Fix**: Settings → Actions → *Workflow permissions* → **Read repository
  contents**.

### B2 · Fork-PR approval · MANUAL
- **Checks**: workflows from outside collaborators require approval.
- **Why**: with self-hosted runners, an un-approved fork PR can run untrusted
  code on your infrastructure.
- **Detect**: not reliably exposed via REST → reported **MANUAL**.
- **Fix**: Settings → Actions → *Fork pull request workflows* → require
  approval for **all outside collaborators**.

### B3 · Allowed actions policy · WARN
- **Checks**: which actions may run (`all` vs `selected`/`local_only`).
- **Why**: allowing any action from anywhere widens the supply-chain surface.
- **Detect**: `allowed_actions` from `GET .../actions/permissions`.
- **Fix**: restrict to selected/verified actions.

### B4 · Public repo + self-hosted runner · FAIL
- **Checks**: a **public** repo with self-hosted runners attached.
- **Why**: the single highest-risk self-hosted-runner misconfiguration — fork
  PRs can execute attacker code on your runner.
- **Detect**: repo visibility + `GET .../actions/runners`.
- **Fix**: use ephemeral runners, require fork-PR approval, or use
  GitHub-hosted runners for public repos.

### B5 · Runner registration sanity · WARN
- **Checks**: no `offline` runners; no non-ephemeral runners on public repos.
- **Why**: stale registrations hold lingering tokens; non-ephemeral public
  runners are risky.
- **Detect**: `GET .../actions/runners`.
- **Fix**: deregister stale runners; switch public repos to ephemeral runners.

---

## Group C — VM & AKS/ARC (catalog + best-effort)

These are **catalog-level** guidance for the VM (`vm-runner-ops`) and AKS+ARC
(`arc-ops`) alternatives. The engine surfaces a `C1` INFO pointer; collect live
data when those resources exist.

### C1 · VM hardening
- NSG must not allow inbound `0.0.0.0/0` on SSH (22); prefer Just-In-Time or
  bastion access, or no inbound at all (egress-only).
- The VM's managed identity should be **least-privilege** (no `Owner`/broad
  `Contributor` unless required).
- Keep the OS patched (unattended-upgrades / image refresh).
- The runner agent should run as a non-root, sudo-less user.

### C2 · AKS / ARC hardening
- Authenticate ARC with a **GitHub App** or least-privilege credential, not a
  broad PAT (`github-app-runner-auth`).
- ARC runners are **ephemeral by design** — keep it that way.
- Isolate runners in their own namespace; avoid privileged pods / hostPath.
- Restrict which repos/orgs may target the scale set (runner groups).

---

## Mapping to other skills

| Finding | Remediate with |
|---------|----------------|
| A1 / A5 stale or unpinned image | `ghrunner-image-release`, `ghrunner-ops` |
| A2 non-ephemeral | `ghrunner-ops` (re-register ephemeral) |
| A3 long-lived PAT | `gha-azure-oidc`, `github-app-runner-auth` |
| A6 unhealthy runner | `ghrunner-triage` |
| C1 / C2 | `vm-runner-ops`, `arc-ops` |
