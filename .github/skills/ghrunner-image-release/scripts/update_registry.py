#!/usr/bin/env python3
"""Insert a release row into the Image versions table of docs/runner-registry.md.

Line-oriented (no Markdown round-trip): the rest of the file is preserved
byte-for-byte. Idempotent — if a row for the tag already exists, nothing changes.

The Image versions table looks like:

    | Tag | Changes |
    |-----|---------|
    | `v0.6.3` (current `latest`) | ... |
    | `v0.6.2-lsb-fix` | ... |

With --also-latest, the new row is annotated "(current `latest`)" and that
annotation is stripped from the row that previously held it.

Usage:
  update_registry.py --registry PATH --tag TAG --changelog TEXT [--also-latest]
Exit status: 0 on success (changed or already-present), 2 on bad table/args.
A trailing "__CHANGED__=0|1" line is printed to stderr.
"""
import argparse
import re
import sys

LATEST_ANNOT = " (current `latest`)"


def find_table(lines):
    """Return (header_idx, separator_idx) of the Image versions table, or None."""
    for i, ln in enumerate(lines):
        if re.match(r"^\|\s*Tag\s*\|\s*Changes\s*\|\s*$", ln):
            if i + 1 < len(lines) and re.match(r"^\|[-\s|]+\|\s*$", lines[i + 1]):
                return i, i + 1
    return None


def has_tag(lines, sep_idx, tag):
    for ln in lines[sep_idx + 1:]:
        if not ln.startswith("|"):
            break
        if re.match(r"^\|\s*`" + re.escape(tag) + r"`(\s|\()", ln):
            return True
    return False


def strip_latest_annotation(lines, sep_idx):
    for k in range(sep_idx + 1, len(lines)):
        if not lines[k].startswith("|"):
            break
        if LATEST_ANNOT in lines[k]:
            lines[k] = lines[k].replace(LATEST_ANNOT, "", 1)
            return True
    return False


def main():
    ap = argparse.ArgumentParser(description="Insert a runner image release row.")
    ap.add_argument("--registry", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--changelog", required=True)
    ap.add_argument("--also-latest", action="store_true")
    args = ap.parse_args()

    with open(args.registry, "r") as fh:
        lines = fh.readlines()

    tbl = find_table(lines)
    if not tbl:
        sys.stderr.write("ERROR: Image versions table not found in registry\n")
        sys.stderr.write("__CHANGED__=0\n")
        sys.exit(2)
    _, sep_idx = tbl

    if has_tag(lines, sep_idx, args.tag):
        sys.stderr.write(f"Tag `{args.tag}` already present — no change.\n")
        sys.stderr.write("__CHANGED__=0\n")
        return

    if args.also_latest:
        strip_latest_annotation(lines, sep_idx)

    annot = LATEST_ANNOT if args.also_latest else ""
    eol = "\n" if not lines[sep_idx].endswith("\r\n") else "\r\n"
    new_row = f"| `{args.tag}`{annot} | {args.changelog} |{eol}"
    lines.insert(sep_idx + 1, new_row)

    with open(args.registry, "w") as fh:
        fh.writelines(lines)
    sys.stderr.write(f"Inserted Image versions row for `{args.tag}`"
                     f"{' (current latest)' if args.also_latest else ''}.\n")
    sys.stderr.write("__CHANGED__=1\n")


if __name__ == "__main__":
    main()
