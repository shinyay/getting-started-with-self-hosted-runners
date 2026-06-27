#!/usr/bin/env python3
#
# normalize.py - pure transform: raw `az`/`gh` JSON + the registry ledger ->
# the normalized audit document consumed by audit_rules.py.
#
# This module performs NO network or cloud I/O (collect.sh does that and hands
# it file paths), so it is deterministic and unit-testable offline. It records
# environment-variable NAMES only; it never copies a secret value.
#
# Usage:
#   normalize.py [--registry PATH] [--aci FILE] [--repo-name NAME]
#                [--repo-meta FILE] [--repo-perm FILE] [--repo-wf FILE]
#                [--repo-runners FILE]
#
# Emits the normalized JSON document to stdout.

import argparse
import json
import re
import sys

DEFAULT_REGISTRY_HOST = "shinyayacr202604.azurecr.io"
_SEMVER = re.compile(r"v\d+\.\d+\.\d+")
_LEDGER_ROW = re.compile(r"`(ghrunner-aci-\d+)`.*?github\.com/([\w.-]+/[\w.-]+)")


def _load(path):
    if not path:
        return None
    try:
        with open(path) as fh:
            txt = fh.read().strip()
        return json.loads(txt) if txt else None
    except (OSError, ValueError):
        return None


def parse_registry(path):
    """Return (latest_tag, trusted_registry, {container: repo})."""
    latest, trusted, cmap = None, DEFAULT_REGISTRY_HOST, {}
    if not path:
        return latest, trusted, cmap
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except OSError:
        return latest, trusted, cmap
    for ln in lines:
        if latest is None and "current `latest`" in ln:
            m = _SEMVER.search(ln)
            if m:
                latest = m.group(0)
        if "azurecr.io" in ln and ("Registry" in ln or "Image" in ln):
            m = re.search(r"([a-z0-9]+\.azurecr\.io)", ln)
            if m:
                trusted = m.group(1)
        m = _LEDGER_ROW.search(ln)
        if m:
            cmap[m.group(1)] = m.group(2)
    return latest, trusted, cmap


def _split_image(image):
    """image -> (registry, tag)."""
    if not image:
        return None, None
    registry = image.split("/", 1)[0] if "/" in image else None
    tag = image.rsplit(":", 1)[1] if ":" in image.rsplit("/", 1)[-1] else None
    return registry, tag


def _container_from_group(g, cmap):
    cs = (g.get("containers") or [{}])[0]
    iv = cs.get("instanceView") or {}
    # Container *runtime* state (Running/Terminated/Waiting). `az container list`
    # often omits instanceView, so this is None there; the group's
    # provisioningState is tracked separately and must not be confused with it.
    state = (iv.get("currentState") or {}).get("state")
    env = cs.get("environmentVariables") or []
    env_keys = [e.get("name") for e in env if e.get("name")]
    ephemeral = None
    for e in env:
        if e.get("name") == "EPHEMERAL" and e.get("value") is not None:
            ephemeral = str(e.get("value")).lower() == "true"
    image = cs.get("image")
    registry, tag = _split_image(image)
    name = g.get("name")
    return {
        "name": name,
        "state": state,
        "provisioning_state": g.get("provisioningState"),
        "image": image,
        "image_tag": tag,
        "image_registry": registry,
        "restart_count": iv.get("restartCount"),
        "ephemeral": ephemeral,
        "restart_policy": g.get("restartPolicy"),
        "env_keys": env_keys,
        "ip_type": (g.get("ipAddress") or {}).get("type"),
        "repo": cmap.get(name),
        "repo_visibility": None,
    }


def build(args):
    latest, trusted, cmap = parse_registry(args.registry)
    doc = {"meta": {
        "resource_group": args.resource_group,
        "latest_image_tag": latest,
        "trusted_registry": trusted,
    }, "containers": []}

    aci = _load(args.aci)
    if isinstance(aci, list):
        doc["containers"] = [_container_from_group(g, cmap) for g in aci]

    if args.repo_name:
        meta = _load(args.repo_meta) or {}
        perm = _load(args.repo_perm) or {}
        wf = _load(args.repo_wf) or {}
        runners_doc = _load(args.repo_runners) or {}
        runners = []
        for r in (runners_doc.get("runners") or []):
            runners.append({
                "name": r.get("name"),
                "status": r.get("status"),
                "ephemeral": r.get("ephemeral"),  # usually absent -> None
            })
        doc["repo"] = {
            "full_name": meta.get("full_name") or args.repo_name,
            "visibility": meta.get("visibility"),
            "actions_enabled": perm.get("enabled"),
            "allowed_actions": perm.get("allowed_actions"),
            "default_workflow_permissions": wf.get("default_workflow_permissions"),
            "fork_pr_approval": "unknown",
            "self_hosted_runners": runners,
        }
    return doc


def main(argv=None):
    ap = argparse.ArgumentParser(description="Normalize raw az/gh JSON for the audit engine")
    ap.add_argument("--registry")
    ap.add_argument("--resource-group", default=None)
    ap.add_argument("--aci")
    ap.add_argument("--repo-name")
    ap.add_argument("--repo-meta")
    ap.add_argument("--repo-perm")
    ap.add_argument("--repo-wf")
    ap.add_argument("--repo-runners")
    args = ap.parse_args(argv)
    sys.stdout.write(json.dumps(build(args), indent=2, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
