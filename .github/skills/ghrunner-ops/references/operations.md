# Operations Reference — ghrunner-ops

Full operation menu, the `ask_user` schema to render it, and per-operation
inputs and procedures. The authoritative commands live in
`docs/runner-registry.md`; this file is the orchestration layer.

## The `ask_user` Menu Schema

Render the menu with the `ask_user` tool using a single-select `operation`
field plus an optional `supplement` free-text field:

```jsonc
{
  "message": "ghrunner-ops — pick an operation. Add a supplement (target repo, runner number, etc.) if known.",
  "requestedSchema": {
    "properties": {
      "operation": {
        "type": "string",
        "title": "Operation",
        "oneOf": [
          { "const": "A1_inventory",  "title": "A1 Inventory & reconcile (read-only)" },
          { "const": "A2_add",        "title": "A2 Add a runner for a repository" },
          { "const": "A3_redeploy",   "title": "A3 Redeploy / recover a crashed runner" },
          { "const": "A4_image",      "title": "A4 Update runner image (ACR push)" },
          { "const": "A5_remove",     "title": "A5 Remove / deregister a runner" },
          { "const": "A6_pat",        "title": "A6 Rotate GH_PAT" },
          { "const": "B1_vm",         "title": "B1 VM runner (Bicep)" },
          { "const": "B2_arc",        "title": "B2 AKS + ARC autoscaling" },
          { "const": "C_image_dev",   "title": "C Image development (Dockerfile/entrypoint)" },
          { "const": "D_docs",        "title": "D Docs maintenance" }
        ]
      },
      "supplement": {
        "type": "string",
        "title": "Supplement (optional)",
        "description": "e.g. 'add ephemeral runner for shinyay/my-new-repo'"
      }
    },
    "required": ["operation"]
  }
}
```

Only `A1` is read-only. Treat everything else as mutating: confirm before
executing.

---

## A1 — Inventory & Reconcile (read-only)

**Inputs:** none (optional `--subscription`, `--resource-group`).

Run the bundled script. It parses the container→repo map from
`docs/runner-registry.md`, then compares against live Azure (`az container
show`: state, `EPHEMERAL`, image tag, restartCount) and GitHub
(`gh api .../actions/runners`: status, busy).

```bash
./.github/skills/ghrunner-ops/scripts/inventory.sh
# or, if the active subscription is wrong:
./.github/skills/ghrunner-ops/scripts/inventory.sh --subscription <id>
```

**Interpret the output:**

- `✗無` (no GitHub runner) or a container missing in Azure → real drift.
- `EPHEMERAL=true` but the ledger row lacks `(ephemeral)` → annotate it.
- Live image tag is a pinned version (e.g. `v0.6.2-lsb-fix`) that differs from
  the ledger → update the ledger version.
- Live tag is `latest` but the ledger records a semantic version → **keep the
  ledger value** (ACI snapshot rule).

Reflect any findings into the ledger (Step 6 of the main flow).

---

## A2 — Add a Runner

**Inputs:** target `OWNER/REPO`, next free `NN`, the `GH_PAT` token source
(ask the operator — see below), size (default 2 vCPU / 4 GB), labels (default
`azure,linux,x64,aci`).

Follow `docs/runner-registry.md` → **"How to Add a New Runner for a
Repository"** (fleet-standard note → get ACR creds → `az container create` →
verify → switch the target repo's workflows to
`runs-on: [self-hosted, linux, azure, aci]` → update the ledger).

- Default (fleet standard): `GH_PAT` (self-minting) + `EPHEMERAL=true` +
  `--restart-policy Always`, `--cpu 2 --memory 4` (`--cpu 1 --memory 2` is
  enough for light CI). Ephemeral also covers the Copilot coding agent and
  other dirty-`_work`-sensitive workloads (`docs/15-copilot-coding-agent.md`).
- Token: registry §"GH_PAT — Setup and Rotation" → **"Token source"**. Ask
  whether to use (a) a fine-grained PAT or (b) the operator's `gh auth token`
  (explicit approval required). Never assume a stored PAT exists or ask for a
  token the operator doesn't have.
- Legacy: the registry's one-shot `RUNNER_TOKEN` example
  (`--restart-policy Never`, `EPHEMERAL=false`) — only if the operator asks
  for it.

## A3 — Redeploy / Recover

**Inputs:** `NN`, target `OWNER/REPO`.

Follow `docs/runner-registry.md` → **"How to Redeploy a Crashed Runner"**
(delete container → mint fresh token → recreate). Tokens expire in 1h — mint
immediately before recreating.

- For a `GH_PAT` runner, skip the token mint: recreate it with `GH_PAT` from
  the source the operator chooses (registry → **"Token source"**) and the
  settings recorded in the ledger (ephemeral, restart policy, size).

## A4 — Update Runner Image

**Inputs:** new tag (e.g. `v0.6.3`), changelog line.

1. Edit `containers/runner/Dockerfile` / `entrypoint.sh` (operation `C`).
2. Build & push:
   ```bash
   az acr build -r shinyayacr202604 -t ghrunner:<newtag> -t ghrunner:latest containers/runner
   ```
   (or `docker build` + `docker push` after `az acr login -n shinyayacr202604`).
3. Add a row to the **Image versions** table in `docs/runner-registry.md`.
4. Existing containers keep their snapshot — recreate (A3) any runner that must
   adopt the new image.

## A5 — Remove / Deregister

**Inputs:** `NN`, target `OWNER/REPO`.

Follow `docs/runner-registry.md` → **"How to Remove a Runner"** (delete the ACI
container, then remove the stale runner from GitHub via the runners API).
Remove the row from the ledger.

## A6 — Rotate GH_PAT

**Inputs:** a new token from the source the operator chooses (registry →
**"Token source"**): a fine-grained PAT (`Administration: Read and write`) or
the operator's GitHub CLI token (`gh auth token`, explicit approval required).

Follow `docs/runner-registry.md` → **"GH_PAT — Setup and Rotation"**: get the
new token → `export GH_PAT=…` → recreate the GH_PAT-backed runners so the new
secret is baked into their secure env → revoke the old token once no runner
uses it.

---

## B1 — VM Runner (Bicep)

**Inputs:** target repo, VM size, region.

Deploy `bicep/vm-runner/main.bicep` (with `scripts/vm/cloud-init-runner.yaml`):

```bash
az deployment group create -g <rg> \
  --template-file bicep/vm-runner/main.bicep \
  --parameters bicep/vm-runner/main.parameters.json
```

See `docs/06-vm-manual-setup.md` and `docs/07-vm-automation.md`.

## B2 — AKS + ARC Autoscaling

**Inputs:** AKS cluster, GitHub App / PAT for ARC.

Apply the Actions Runner Controller manifests in `k8s/arc/`
(`values.yaml`, `runner-scale-set.yaml`, `network-policy.yaml`). Requires a
running AKS cluster. See `docs/09-aks-arc-setup.md` and
`docs/16-copilot-agent-arc-end-to-end.md`.

## C — Image Development

Edit `containers/runner/Dockerfile` and `entrypoint.sh`. Test locally
(`docker build` + `docker run` with `GITHUB_URL`/`RUNNER_TOKEN`), then publish
via operation `A4`. See `docs/08-aci-setup.md` Part 1.

## D — Docs Maintenance

Update `docs/**` and `docs/runner-registry.md`. Safe (no infra changes). Keep
the registry tables accurate; prefer running `A1` first to ground edits in
real state.
