# Verification — a new runner image works

Prove a freshly built image actually has the capability you added, by running a
**capability-check job** to green on a runner that uses the image.

## Steps

1. Provision a runner on the new tag (use the **ghrunner-provision** skill):
   ```bash
   ./.github/skills/ghrunner-provision/scripts/provision-aci.sh OWNER/REPO \
     --name ghrunner-aci-imgcheck --image shinyayacr202604.azurecr.io/ghrunner:<tag> \
     --ephemeral true
   ```
2. Run the capability check:
   ```bash
   ./.github/skills/ghrunner-image-release/scripts/verify-image.sh OWNER/REPO \
     --runner ghrunner-aci-imgcheck --check "<command that needs the new tool>"
   ```
   It pushes a `workflow_dispatch` workflow (over git+SSH) whose single step runs
   `--check`, dispatches it, and asserts `conclusion=success`.

## Choosing a `--check`

Make the check exercise exactly the capability you added:

| Release added | `--check` |
|---------------|-----------|
| Azure CLI | `az version` |
| GitHub CLI | `gh --version` |
| A new apt package (e.g. tree) | `tree --version` |
| Chromium libs | `npx --yes playwright install chromium && echo ok` |
| node24 runner | `node --version` |

Default check: `az version; gh --version; node --version`.

## Interpreting the result

- **green** → the image ships the tool; safe to roll out (recreate runners onto
  the new tag with `recreate-on-image.sh`).
- **red** with `command not found` → the package didn't make it into the image;
  fix the Dockerfile and re-release. Diagnose signatures with **ghrunner-triage**
  (IMG-* catalog).

## Cleanup

`verify-image.sh` removes its workflow automatically. Delete a throwaway runner
and (for test builds) the throwaway ACR tag:
```bash
az container delete -g ghrunner-rg -n ghrunner-aci-imgcheck --yes
az acr repository delete -n shinyayacr202604 --image ghrunner:<throwaway-tag> --yes
```
