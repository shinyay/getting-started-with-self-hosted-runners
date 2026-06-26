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

**Inputs:** target `OWNER/REPO`, next free `NN`, `EPHEMERAL` (true/false),
labels (default `azure,linux,x64,aci`).

Follow `docs/runner-registry.md` → **"How to Add a New Runner for a
Repository"** (mint registration token → get ACR creds → `az container create`
→ verify → switch the target repo's workflows to
`runs-on: [self-hosted, linux, azure, aci]` → update the ledger).

- Default `--restart-policy Never`, `EPHEMERAL=false`.
- For Copilot coding agent or dirty-`_work`-sensitive workloads: `EPHEMERAL=true`
  + `--restart-policy Always` (see `docs/15-copilot-coding-agent.md`).

## A3 — Redeploy / Recover

**Inputs:** `NN`, target `OWNER/REPO`.

Follow `docs/runner-registry.md` → **"How to Redeploy a Crashed Runner"**
(delete container → mint fresh token → recreate). Tokens expire in 1h — mint
immediately before recreating.

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

Follow the delete block in `docs/runner-registry.md` (delete the ACI container,
then remove the stale runner from GitHub via the runners API). Remove the row
from the ledger.

## A6 — Rotate GH_PAT

**Inputs:** new `GH_PAT` (fine-grained, `Administration: read & write`).

Follow `docs/runner-registry.md` → **"GH_PAT — Setup and Rotation"**: generate
new PAT → `export GH_PAT=…` → recreate the GH_PAT-backed runners so the new
secret is baked into their secure env → revoke the old PAT.

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
