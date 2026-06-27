#!/usr/bin/env python3
"""Migrate a single GitHub Actions workflow to self-hosted runners.

Line-oriented (no YAML round-trip) so comments and formatting are preserved.
Reads a workflow on stdin, writes the transformed workflow on stdout, and a
change log on stderr. Exit status is always 0 (a no-op file is emitted
unchanged); whether anything changed is reported on stderr.

Transforms:
  * runs-on: ubuntu-latest | ubuntu-22.04 | ubuntu-24.04 | ubuntu-20.04
    (optionally quoted, or a single-item list [ubuntu-latest]) -> the target
    label list (default: [self-hosted, linux, azure, aci]).
  * runs-on: ${{ matrix.os }}  -> WARN only (cannot auto-map).
  * actions/setup-node@* without node-version: -> insert node-version (default 20).
  * actions/setup-python@* without python-version: -> insert python-version (3.12).

Idempotent: already-self-hosted / already-pinned inputs are left unchanged.

Usage:
  transform_workflow.py [--labels L] [--node-version V] [--python-version V]
                        [--name FILE] < workflow.yml > migrated.yml
"""
import argparse
import re
import sys

UBUNTU_RE = re.compile(r"^(ubuntu-latest|ubuntu-22\.04|ubuntu-24\.04|ubuntu-20\.04)$")


def is_ubuntu(token: str) -> bool:
    return bool(UBUNTU_RE.match(token.strip().strip("\"'")))


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def transform(lines, labels, node_version, python_version, fname):
    out = []
    changes = []
    target = "[" + ", ".join(labels) + "]"

    # Pass 1: runs-on rewrites (line-local).
    for idx, line in enumerate(lines):
        m = re.match(r"^(\s*)runs-on:\s*(.+?)\s*$", line)
        if not m:
            out.append(line)
            continue
        pad, value = m.group(1), m.group(2)
        # strip trailing inline comment for analysis (keep simple: no '#' in our values)
        v = value.strip()
        if "matrix.os" in v or "${{" in v and "matrix" in v:
            changes.append(f"WARN {fname}:{idx+1}: runs-on uses a matrix/expression "
                           f"({v}) - not auto-mapped; map matrix os values manually.")
            out.append(line)
            continue
        # single-item list form [ubuntu-latest]
        lst = re.match(r"^\[\s*([^\],]+)\s*\]$", v)
        if lst and is_ubuntu(lst.group(1)):
            out.append(f"{pad}runs-on: {target}\n")
            changes.append(f"{fname}:{idx+1}: runs-on {v} -> {target}")
            continue
        if is_ubuntu(v):
            out.append(f"{pad}runs-on: {target}\n")
            changes.append(f"{fname}:{idx+1}: runs-on {v} -> {target}")
            continue
        # already self-hosted or some other value: leave as-is
        out.append(line)

    # Pass 2: setup-node / setup-python version pinning (block-aware).
    out = pin_action_version(out, changes, fname,
                             action="actions/setup-node",
                             key="node-version", value=node_version)
    out = pin_action_version(out, changes, fname,
                             action="actions/setup-python",
                             key="python-version", value=python_version)
    return out, changes


def pin_action_version(lines, changes, fname, action, key, value):
    """Ensure each step using `<action>@...` declares `key:`; insert if missing.

    Step-block oriented: a step is a `- ` list item; the `uses:` may be on the
    dash line or on a following line within the same block.
    """
    result = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        m = re.match(r"^(\s*)-\s", line)
        if not m:
            result.append(line)
            i += 1
            continue
        item_indent = len(m.group(1))
        # Collect the step block: subsequent lines more indented than the dash.
        j = i + 1
        while j < n:
            ln = lines[j]
            if ln.strip() == "":
                j += 1
                continue
            if indent_of(ln) <= item_indent:
                break
            j += 1
        block = lines[i:j]
        uses_this = any(re.search(r"uses:\s*" + re.escape(action) + r"@", b) for b in block)
        if not uses_this:
            result.extend(block)
            i = j
            continue
        has_key = any(re.match(r"^\s*" + re.escape(key) + r":\s*\S", b) for b in block)
        if has_key:
            result.extend(block)
            i = j
            continue
        content_indent = item_indent + 2  # keys like uses:/with: sit here
        with_idx = None
        with_indent = None
        for k, b in enumerate(block):
            wm = re.match(r"^(\s*)with:\s*$", b)
            if wm:
                with_idx = k
                with_indent = len(wm.group(1))
                break
        new_block = list(block)
        if with_idx is not None:
            ins = " " * (with_indent + 2) + f"{key}: '{value}'\n"
            new_block.insert(with_idx + 1, ins)
            changes.append(f"{fname}: {action} step: added {key}: '{value}'")
        else:
            # Insert a `with:` block right after the line that has `uses: <action>`.
            uses_k = next(k for k, b in enumerate(block)
                          if re.search(r"uses:\s*" + re.escape(action) + r"@", b))
            with_line = " " * content_indent + "with:\n"
            ins = " " * (content_indent + 2) + f"{key}: '{value}'\n"
            new_block.insert(uses_k + 1, with_line)
            new_block.insert(uses_k + 2, ins)
            changes.append(f"{fname}: {action} step: added with.{key}: '{value}'")
        result.extend(new_block)
        i = j
    return result


def main():
    ap = argparse.ArgumentParser(description="Migrate a workflow to self-hosted runners.")
    ap.add_argument("--labels", default="self-hosted,linux,azure,aci",
                    help="comma-separated target runs-on labels")
    ap.add_argument("--node-version", default="20")
    ap.add_argument("--python-version", default="3.12")
    ap.add_argument("--name", default="<stdin>", help="file name for the change log")
    args = ap.parse_args()

    labels = [x.strip() for x in args.labels.split(",") if x.strip()]
    lines = sys.stdin.readlines()
    out, changes = transform(lines, labels, args.node_version, args.python_version, args.name)
    sys.stdout.write("".join(out))
    for c in changes:
        sys.stderr.write(c + "\n")
    # Communicate "changed?" via a trailing marker line on stderr.
    edits = [c for c in changes if not c.startswith("WARN ")]
    sys.stderr.write(f"__CHANGED__={'1' if edits else '0'}\n")


if __name__ == "__main__":
    main()
