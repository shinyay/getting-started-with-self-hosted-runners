#!/usr/bin/env python3
#
# runson.py - pure classifier for GitHub Actions `runs-on` values.
#
# classify_runs_on(value) -> one of:
#   "github_hosted"  : ubuntu-* / windows-* / macos-* (standard hosted labels)
#   "self_hosted"    : contains `self-hosted`, or a bare custom label
#   "dynamic"        : contains a ${{ ... }} expression (matrix/var) - review
#   "group_review"   : `group:` form - could be a larger-runner group or a
#                       self-hosted runner group; needs a human to confirm
#
# The value may be a YAML scalar ("ubuntu-latest"), a flow list
# ("[self-hosted, linux]") or a `{ group: name }` mapping. No I/O - unit-testable.

import re

_HOSTED_RE = re.compile(r"^(ubuntu|windows|macos)(-|$)", re.IGNORECASE)
_DYNAMIC_RE = re.compile(r"\$\{\{")


def _tokens(value):
    """Split a runs-on scalar / flow-list string into bare label tokens."""
    v = (value or "").strip().strip("'\"")
    if v.startswith("[") and v.endswith("]"):
        v = v[1:-1]
    parts = [p.strip().strip("'\"") for p in v.split(",")]
    return [p for p in parts if p]


def classify_detail(value):
    """Fine-grained bucket: github_hosted / self_hosted / custom_label /
    dynamic / group_review. `self_hosted` means the explicit `self-hosted`
    label is present; `custom_label` is a bare non-standard label that is
    *probably* self-hosted but could be a GitHub larger runner (needs review)."""
    if value is None:
        return "dynamic"
    raw = str(value).strip()
    if _DYNAMIC_RE.search(raw):
        return "dynamic"
    if re.search(r"\bgroup\s*:", raw):
        return "group_review"
    toks = _tokens(raw)
    if not toks:
        return "dynamic"
    if any(t.lower() == "self-hosted" for t in toks):
        return "self_hosted"
    if all(_HOSTED_RE.match(t) for t in toks):
        return "github_hosted"
    # Bare custom label(s), or a hosted label mixed with a custom one.
    return "custom_label"


def classify_runs_on(value):
    """Coarse bucket (back-compat): custom_label collapses into self_hosted."""
    d = classify_detail(value)
    return "self_hosted" if d == "custom_label" else d


def buckets(values):
    """Set of fine-grained detail buckets across a list of runs-on values."""
    return sorted({classify_detail(v) for v in (values or [])})


def strategy_from_details(details):
    s = set(details)
    if not s:
        return "none"
    hosted = "github_hosted" in s
    self_h = bool(s & {"self_hosted", "custom_label"})
    group = "group_review" in s
    if hosted and (self_h or group):
        return "mixed"
    if self_h:
        return "self_hosted"
    if group:
        return "group_review"
    if hosted:
        return "github_hosted"
    return "dynamic"


def aggregate(values):
    """Aggregate runs-on values into a coarse bucket set (back-compat)."""
    return sorted({classify_runs_on(v) for v in (values or [])})


def workflow_strategy(values):
    """One label for a whole workflow from its runs-on values."""
    return strategy_from_details(buckets(values))


def extract_runs_on(text):
    """Extract every `runs-on` value from a workflow YAML file's text.

    Handles inline scalars/flow-lists (`runs-on: ubuntu-latest`,
    `runs-on: [self-hosted, linux]`), block lists, and `runs-on:` followed by a
    `group:` mapping. Returns the raw value strings (one per `runs-on`). Pure
    text parsing - no YAML dependency.
    """
    lines = text.splitlines()
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"^(\s*)runs-on:\s*(.*)$", line)
        if not m:
            i += 1
            continue
        indent = len(m.group(1))
        value = m.group(2).strip()
        comment = value.split("#", 1)
        value = comment[0].strip()
        if value:
            out.append(value)
            i += 1
            continue
        # Empty inline value -> block list or a nested mapping (group/labels).
        j = i + 1
        items = []
        is_group = False
        labels_val = None
        while j < len(lines):
            nxt = lines[j]
            if not nxt.strip():
                j += 1
                continue
            nind = len(nxt) - len(nxt.lstrip())
            if nind <= indent:
                break
            item = nxt.strip()
            lm = re.match(r"^-\s*(.+)$", item)
            lab = re.match(r"^labels\s*:\s*(.+)$", item)
            if lm:
                items.append(lm.group(1).strip().strip("'\""))
            elif re.match(r"^group\s*:", item):
                is_group = True
            elif lab:
                labels_val = lab.group(1).strip()
            j += 1
        if labels_val:
            # `runs-on: { group:.., labels:[..] }` -> the labels decide.
            out.append(labels_val)
        elif is_group:
            out.append("group:")
        elif items:
            out.append("[%s]" % ", ".join(items))
        i = j
    return out

