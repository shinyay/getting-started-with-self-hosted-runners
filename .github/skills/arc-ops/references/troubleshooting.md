# ARC Troubleshooting — AKS + Actions Runner Controller

Failure modes specific to the Kubernetes/ARC path. For ACI-fleet job failures use
the **ghrunner-triage** skill; its `INF-AKS-STOPPED` and `AUTH-ARC-CREDS`
signatures point here.

| Symptom | Cause | Fix |
|---------|-------|-----|
| Jobs stuck **`queued`** + `kubectl` returns `... no such host` for the AKS API | The AKS cluster is **Stopped** (auto-stop / manual stop) | `az aks start -g <rg> -n <aks>` (control plane ~5 min). Then cancel stale runs, let runners drain, `gh run rerun`. |
| Listener pod (`*-listener` in `arc-systems`) not **Running** / not registering | Bad auth secret, wrong `githubConfigUrl`, or controller not ready | `kubectl -n arc-systems logs -l app.kubernetes.io/component=runner-scale-set-listener`; verify the secret keys and the repo/org URL. |
| Runner pod **`CrashLoopBackOff`** | Bad GitHub credentials (token expired / wrong App key / missing scopes) | Recreate the secret with a valid token or App key; re-check repo/org admin permission. |
| Runner pods stuck **`Pending`** | No schedulable nodes (cluster too small / autoscaler maxed) | Scale the node pool or enable the cluster autoscaler; check `kubectl describe pod`. |
| Job never starts; no runner pod appears | `runs-on` doesn't match the scale-set name, or `minRunners=0` and the listener isn't registered | Set `runs-on: <scale-set-name>` exactly; confirm the listener pod is Running. |
| Controller pod not Running | Chart install incomplete / version skew | `kubectl -n arc-systems get pods`; reinstall the controller chart; keep controller and scale-set chart versions aligned. |
| `helm install` of the scale set fails on the secret | The pre-created secret name/keys don't match | Secret keys must be exactly `github_token` (PAT) or `github_app_id` / `github_app_installation_id` / `github_app_private_key` (App). |

## Useful diagnostics

```bash
kubectl get pods -n arc-systems
kubectl get pods -n arc-runners
kubectl -n arc-systems logs -l app.kubernetes.io/name=gha-rs-controller --tail=50
kubectl -n arc-systems logs -l app.kubernetes.io/component=runner-scale-set-listener --tail=50
kubectl get autoscalingrunnersets,ephemeralrunnersets,ephemeralrunners -n arc-runners
az aks show -g <rg> -n <aks> --query powerState.code -o tsv   # "Running" or "Stopped"
```

## Copilot coding agent on ARC

For the Copilot coding agent on a private repo via ARC, also: disable the
repository **agent firewall** (docs/15 §2 / docs/16 §6), and ensure the runner
can reach `api.githubcopilot.com`, `uploads.github.com`,
`user-images.githubusercontent.com`. See `docs/16` for the end-to-end runbook.
