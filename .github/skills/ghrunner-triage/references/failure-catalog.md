# Failure Catalog — self-hosted runner job failures

Signature → root cause → fix, across all platforms (ACI, VM, ARC). Each entry
has a stable **ID** that `scripts/triage.sh` emits when it matches a log
signature. Remediation is a **handoff** — diagnose here, fix via the
`ghrunner-ops` skill or the cited doc. This skill never mutates infrastructure.

> Seeded from `docs/runner-registry.md` (Image versions), `docs/15`
> (Copilot agent FAQ), `docs/12` (troubleshooting + cheat sheet), and
> `docs/09`/`docs/16` (ARC). **Append new image versions / failure modes here**
> as they are discovered.

Handoff shorthand (operations in the `ghrunner-ops` skill):
`A2` add runner · `A3` redeploy/recover · `A4` image update · `A6` GH_PAT rotation.

> [!IMPORTANT]
> Image fixes follow the **`:latest` snapshot rule**: bumping the image is not
> enough — the affected container keeps its deploy-time snapshot, so you must
> **recreate** it (`A3`) to adopt the new image.

---

## IMAGE — runner image is missing a package/tool

Source: `docs/runner-registry.md` → Image versions.

| ID | Signature (in the failed step log) | Root cause | Fix / Handoff |
|----|------------------------------------|-----------|---------------|
| `IMG-LSB` | `lsb_release: command not found` or `gpg: command not found` (during `actions/setup-python@v5`) | Image lacks `lsb-release`/`gnupg`; the action probes `lsb_release -a` and the deadsnakes PPA via gpg | Use image ≥ `v0.6.2-lsb-fix`; `A4` then recreate (`A3`) |
| `IMG-CHROMIUM` | `error while loading shared libraries: libnss3` / `libgbm1` / `libasound2` (Playwright/Puppeteer) | Image lacks Chromium runtime libs; sudoless runner can't `apt-get install --with-deps` | Use image ≥ `v0.6.1`; `A4` + `A3` |
| `IMG-GH` | `gh: command not found` | Image lacks GitHub CLI | Use image ≥ `v0.5.0`; `A4` + `A3` |
| `IMG-LIBYAML` | `libyaml` load error during `ruby/setup-ruby@v1` | Prebuilt Ruby needs `libyaml-0-2` | Use image ≥ `v0.4.0`; `A4` + `A3` |
| `IMG-NODE24` | `node24` errors during `actions/checkout@v5` / other v5 actions | Runner binary < 2.327 (no node24) | Use image ≥ `v0.3.0` (runner `2.333.1`); `A4` + `A3` |
| `IMG-TOOLCACHE` | permission errors writing `/opt/hostedtoolcache` (`ruby/setup-ruby@v1`) | Tool cache dir not owned by `runner`; action hard-codes the path | Use image ≥ `v0.2.0`; `A4` + `A3` |

## AUTH — token / credential / access

| ID | Signature | Root cause | Fix / Handoff |
|----|-----------|-----------|---------------|
| `AUTH-TOKEN-TTL` | ephemeral ACI runner **crash-loops after ~1h**; container logs show registration/`config.sh` token rejected | Registration token baked in env expired (1h TTL) on `EPHEMERAL=true`+`restart-policy=Always` | Recreate with fresh token (`A3`) or move to GH_PAT self-minting image ≥ `v0.6.0` (`A6`) — see `docs/runner-registry.md` |
| `AUTH-PRIVATE-REPO` | `Repository not found` on a **private** repo (Copilot agent) | Vanilla self-hosted `GITHUB_TOKEN` lacks scopes the agent expects | Move repo to **ARC** (GitHub App auth), `docs/16`; or make repo public if appropriate (`docs/15` #4) |
| `AUTH-ARC-CREDS` | ARC pod `CrashLoopBackOff`; `kubectl logs` shows auth/credential errors | Bad GitHub App credentials/secret | Recreate the GitHub App secret (`docs/09`/`docs/16`); apply via the `arc-ops` skill |

## WORKFLOW — workflow YAML / agent configuration

| ID | Signature | Root cause | Fix / Handoff |
|----|-----------|-----------|---------------|
| `WF-UNRELATED-HISTORIES` | `fatal: refusing to merge unrelated histories` (Copilot agent) | Non-ephemeral runner with dirty `_work/` from a prior run | Make the runner ephemeral: `EPHEMERAL=true` + `--restart-policy Always` (`A3`/`A2`); `docs/15` #3 |
| `WF-FIREWALL` | network errors **before the first step** (Copilot agent) | Repository agent firewall still ON (unsupported on self-hosted) | Disable the agent firewall; `docs/15` #2 (gh.io/cca-self-hosted-disable-firewall) |
| `WF-SETUP-NODE-NOVER` | `actions/setup-node` fails to resolve a version | `node-version` not specified | Add `node-version: '20'` to the step; `docs/runner-registry.md` note |

## CONFIG — runner labels / groups (job never starts)

| ID | Signature | Root cause | Fix / Handoff |
|----|-----------|-----------|---------------|
| `CFG-LABEL` | run sits in **`queued`** forever / "not picking up jobs" | `runs-on` labels don't match any registered runner's labels | Align `runs-on` to the runner labels (`[self-hosted, linux, azure, aci]`), or fix labels; `docs/12`, `docs/15` |
| `CFG-RUNNER-GROUP` | queued; runner exists but is in a restricted group | Runner group → repo access policy excludes the repo | Add the repo to the runner group; `docs/12` |

## INFRA — host / cluster / network

| ID | Signature | Root cause | Fix / Handoff |
|----|-----------|-----------|---------------|
| `INF-OFFLINE` | runner shows **Offline** | Service crashed (VM) / VM deallocated / ACI container stopped | VM: `sudo ./svc.sh start` / `az vm start`; ACI: redeploy (`A3`); `docs/12` |
| `INF-DISK` | `No space left on device` / out of disk | `_work/` artifacts accumulated | Clean `_work/`, add disk; prefer ephemeral runners; `docs/12` |
| `INF-DNS` | `Could not resolve host` | DNS failure | Check DNS / `/etc/resolv.conf` / NSG egress; `docs/12`, `docs/04` |
| `INF-RESOURCE` | job **timeout** or OOM-killed | Insufficient CPU/memory | Resize VM / raise ACI `--cpu`/`--memory`; `docs/12` |
| `INF-ARC-PENDING` | ARC pods **Pending** | No schedulable nodes | Check cluster autoscaler / node pool; `docs/09` |
| `INF-AKS-STOPPED` | ARC run stuck **`queued`** + `kubectl` returns `... no such host` for the AKS API | AKS cluster is **Stopped** | `az aks start`; then cancel stale runs, drain runners to 0, `gh run rerun`; `docs/09`/`docs/16`; operate via the `arc-ops` skill |

---

## How `triage.sh` uses this catalog

The script embeds a compact `ID | regex` table mirroring the **Signature**
column above. On a match it prints the **ID**; look the ID up here for the root
cause and the handoff. The script is read-only and applies no fix.
