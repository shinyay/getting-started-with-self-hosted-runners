# Migration Rules — workflows → self-hosted

What `transform_workflow.py` changes when migrating a workflow to the
self-hosted fleet. The transform is **line-oriented** (comments and formatting
are preserved) and **idempotent** (already-migrated files are left unchanged).

## `runs-on` mapping

| Source `runs-on` | Result |
|------------------|--------|
| `ubuntu-latest` | `[self-hosted, linux, azure, aci]` |
| `ubuntu-22.04` / `ubuntu-24.04` / `ubuntu-20.04` (pinned) | `[self-hosted, linux, azure, aci]` |
| `"ubuntu-latest"` (quoted) | `[self-hosted, linux, azure, aci]` |
| `[ubuntu-latest]` (single-item list) | `[self-hosted, linux, azure, aci]` |
| `${{ matrix.os }}` / matrix expression | **WARN, unchanged** — map matrix `os` values manually |
| already `[self-hosted, …]` / non-ubuntu | unchanged |

Target labels are configurable: `--labels self-hosted,linux,azure,aci`. GitHub
also auto-attaches `self-hosted`, `Linux`, `X64`; a job runs only on a runner
that has **all** listed labels.

## Compatibility fixes (safe, auto-applied)

These address known failures on the sudoless fleet (see registry Step 5 and
`docs/15`). Each is inserted only when missing; existing values are respected.

| Action | Fix | Why |
|--------|-----|-----|
| `actions/setup-node@*` without `node-version:` | insert `node-version: '20'` (create a `with:` block if needed) | setup-node fails to resolve a version otherwise |
| `actions/setup-python@*` without `python-version:` | insert `python-version: '3.12'` | same; also needs `lsb-release`/`gnupg` in the image (present from v0.6.x) |

Versions are configurable: `--node-version`, `--python-version`.

## Manual fixes (not auto-applied)

The transform does not detect or apply these. Check every migrated workflow for
them before the verify run — each one broke a real migration to the ACI fleet.

1. **`actions/setup-python` jobs need `AGENT_TOOLSDIRECTORY`.** Set it at job
   level:

   ```yaml
   jobs:
     test:
       runs-on: [self-hosted, linux, azure, aci]
       env:
         AGENT_TOOLSDIRECTORY: /opt/hostedtoolcache
   ```

   Without it, setup-python installs into the runner's default tool cache
   (`_work/_tool`), but the actions/python-versions builds have RUNPATH
   `/opt/hostedtoolcache/Python/<ver>/x64/lib`, and setup-python only exports
   `LD_LIBRARY_PATH` to later steps. Anything that starts Python with a reduced
   environment (e.g. a test that spawns `python3` with a clean `env`) then
   fails with:
   `python3: error while loading shared libraries: libpython3.12.so.1.0: cannot open shared object file`.
   setup-python maps `AGENT_TOOLSDIRECTORY` to `RUNNER_TOOL_CACHE` (its
   `docs/advanced-usage.md` documents this for self-hosted Ubuntu), and the
   image (≥ v0.2.0) pre-creates `/opt/hostedtoolcache` owned by `runner`.
   Triage ID: `WF-SETUP-PYTHON-RUNPATH`.
2. **No `docker build` / `docker run` on ACI.** The runner container has no
   Docker daemon. Install the pinned tools the step needs directly in the job
   instead (e.g. download the release binary of the pinned version).
3. **actionlint needs the custom labels.** If the repo lints workflows with
   actionlint, register the fleet's custom labels in `.github/actionlint.yaml`,
   or it reports `label "azure" is unknown`:

   ```yaml
   self-hosted-runner:
     labels: [azure, aci]
   ```

4. **Playwright:** run `playwright install chromium` **without** `--with-deps`
   (no sudo on the runner; the image already ships Chromium's runtime
   libraries), with the pinned Node from `actions/setup-node` on `PATH`.
5. **`python3 -m venv` needs setup-python first.** The image has no
   `python3-venv`, so the system `python3` fails with
   `ensurepip is not available`. Run `actions/setup-python` (with fix 1)
   before creating the venv.

## Things the transform does NOT do (warn / manual)

- **Matrix `runs-on`** (`${{ matrix.os }}`): a job may intentionally target
  multiple OSes. Decide which matrix legs move to self-hosted and edit the
  `matrix.os` list by hand.
- **Service containers / `container:` jobs**: ACI runners don't support
  Docker-in-Docker (see `docs/02`/`docs/08`); review before moving.
- **`actions/cache`**: works, but the self-hosted cache is local to the runner;
  no behavioural change is made.

## Related: Copilot coding agent

For repos used by the GitHub Copilot coding agent, a
`.github/workflows/copilot-setup-steps.yml` (single job named
`copilot-setup-steps`, `runs-on` = your labels, **ephemeral** runner) is needed
— see `docs/15-copilot-coding-agent.md`. This skill migrates ordinary
workflows; create the Copilot setup workflow per that guide.

## Runner image expectations

The migrated workflows assume the fleet image (`ghrunner` **v0.6.3+**) which
ships `git`, `gh`, `jq`, Chromium libs, and the **Azure CLI**. If a step needs a
tool the image lacks, bump the image via the `ghrunner-ops` skill (A4 + A3) and
recreate the runner; diagnose failures with `ghrunner-triage`.
