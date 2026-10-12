#!/usr/bin/env python3
"""Step 1: read the logging contract from OSB source.

Parses every Log action in an OSB export (12c .pipeline files, 11g inline routers in .proxy files) and turns its XQuery
expression into a log signature: a regex that matches the line the action writes, with one named group per variable
part, the longest literal as a search anchor, and the roles of the groups (correlation id, payload, fault, headers).

Usage: osb_log_signatures.py <osb-export-dir> -o signatures.json
Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

CORRELATION_HINT = re.compile(r"uuid|traceid|trace_id|correlation|messageid|msgid", re.I)
PIPELINE_SUFFIXES = {".pipeline", ".proxy", ".ptx"}


def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def split_top_level(args: str) -> list[str]:
    """Split the argument list of fn:concat on commas that are not inside quotes, parentheses or brackets."""
    parts, depth, buf, quote = [], 0, [], None
    i = 0
    while i < len(args):
        ch = args[i]
        if quote:
            buf.append(ch)
            if ch == quote:
                if i + 1 < len(args) and args[i + 1] == quote:   # XQuery escapes a quote by doubling it
                    buf.append(args[i + 1]); i += 1
                else:
                    quote = None
        elif ch in "\"'":
            quote = ch; buf.append(ch)
        elif ch in "([{":
            depth += 1; buf.append(ch)
        elif ch in ")]}":
            depth -= 1; buf.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(buf).strip()); buf = []
        else:
            buf.append(ch)
        i += 1
    if buf:
        parts.append("".join(buf).strip())
    return parts


def concat_args(expr: str) -> list[str]:
    e = expr.strip()
    m = re.match(r"^(?:fn:)?concat\s*\((.*)\)\s*$", e, re.S)
    return split_top_level(m.group(1)) if m else [e]


def is_literal(arg: str) -> bool:
    return len(arg) >= 2 and arg[0] == arg[-1] and arg[0] in "\"'"


def literal_value(arg: str) -> str:
    q = arg[0]
    return arg[1:-1].replace(q + q, q)


def group_name(arg: str, used: dict) -> str:
    a = arg.strip()
    m = re.search(r"user-header\[@name\s*=\s*[\"']([^\"']+)[\"']\]", a)
    if m:
        name = "hdr_" + m.group(1)
    elif "$fault" in a:
        name = "fault"
    elif "$body" in a:
        m = re.findall(r"[/:]([A-Za-z_][\w.-]*)\s*(?:/text\(\))?\s*\)?\s*$", a.replace("*:", ":"))
        name = "body_" + m[-1] if m and m[-1] not in ("body", "text") else "body"
    else:
        m = re.findall(r"\$([A-Za-z_][\w.-]*)", a)
        name = m[-1] if m else "expr"
    name = re.sub(r"[^A-Za-z0-9_]", "_", name)
    used[name] = used.get(name, 0) + 1
    return name if used[name] == 1 else f"{name}_{used[name]}"


def to_regex(literal: str) -> str:
    return r"\s+".join(re.escape(tok) for tok in literal.split()) if literal.strip() else re.escape(literal)


def build_signature(expr: str) -> dict:
    args = concat_args(expr)
    regex, groups, literals, warnings, used = [], [], [], [], {}
    prev_group = False
    for i, arg in enumerate(args):
        if is_literal(arg):
            lit = literal_value(arg)
            literals.append(lit)
            body = to_regex(lit.strip())
            lead = r"\s*" if lit[:1].isspace() else ""
            trail = r"\s*" if lit[-1:].isspace() else ""
            regex.append(lead + body + trail if lit.strip() else r"\s*")
            prev_group = False
        else:
            if prev_group:
                warnings.append(f"two variable parts without a literal between them (arg {i}); split is ambiguous")
            name = group_name(arg, used)
            last = i == len(args) - 1
            regex.append(f"(?P<{name}>.*)" if last else f"(?P<{name}>.*?)")
            groups.append({"name": name, "expr": arg})
            prev_group = True
    anchor = max(literals, key=lambda s: len(s.strip()), default="").strip()
    if len(anchor) < 12:
        warnings.append("no literal of 12+ characters: weak Splunk anchor, expect false matches")
    names = [g["name"] for g in groups]
    roles = {
        "correlation": [n for n in names if CORRELATION_HINT.search(n)],
        "payload": [n for n in names if n == "body"],
        "fault": [n for n in names if n == "fault"],
        "headers": [n for n in names if n.startswith("hdr_")],
        "business_keys": [n for n in names if n.startswith("body_")],
    }
    if not roles["correlation"]:
        warnings.append("no correlation field: lines cannot be grouped into traces")
    return {"regex": "".join(regex), "anchor": anchor, "groups": groups, "roles": roles, "warnings": warnings}


def parse_file(path: Path, root: Path) -> list[dict]:
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        return [{"file": str(path.relative_to(root)), "error": f"unparseable XML: {exc}"}]
    parent = {c: p for p in tree.iter() for c in p}
    rel = path.relative_to(root)
    project = rel.parts[0] if len(rel.parts) > 1 else rel.stem
    flow = f"{project}/{path.stem}"
    out, n = [], 0
    for el in tree.iter():
        if local(el.tag) != "log":
            continue
        n += 1
        expr = next((t.text for t in el.iter() if local(t.tag) == "xqueryText" and t.text), None)
        level = next((t.text.strip() for t in el.iter() if local(t.tag) == "logLevel" and t.text), "")
        annotation = next((t.text.strip() for t in el.iter() if local(t.tag) == "message" and t.text), "")
        stage, ptype, node = None, None, el
        while node in parent:
            node = parent[node]
            ln = local(node.tag)
            if ln == "stage" and stage is None:
                stage = node.get("name")
            if ln == "pipeline" and ptype is None:
                ptype = node.get("type")
            if ln == "route-node" and ptype is None:
                ptype, stage = "route", stage or node.get("name")
        sig = {"id": f"{flow}#{n}", "flow": flow, "file": str(rel), "pipeline_type": ptype or "unknown", "stage": stage,
               "level": level.lower(), "annotation": annotation, "expression": (expr or "").strip()}
        if expr:
            sig.update(build_signature(expr))
        else:
            sig.update({"regex": None, "warnings": ["log action without an XQuery expression"]})
        out.append(sig)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("export", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=Path("signatures.json"))
    args = ap.parse_args()
    if not args.export.is_dir():
        print(f"not a directory: {args.export}", file=sys.stderr)
        return 2
    sigs = []
    for p in sorted(args.export.rglob("*")):
        if p.suffix in PIPELINE_SUFFIXES and p.is_file():
            sigs.extend(parse_file(p, args.export))
    args.out.write_text(json.dumps({"source": str(args.export), "signatures": sigs}, indent=2), encoding="utf-8")
    levels = {}
    for s in sigs:
        levels[s.get("level", "?")] = levels.get(s.get("level", "?"), 0) + 1
    warn = sum(1 for s in sigs if s.get("warnings"))
    print(f"{len(sigs)} log signatures from {len({s.get('flow') for s in sigs})} flows; levels {levels}; {warn} with warnings -> {args.out}")
    if levels.get("debug"):
        print("NOTE: debug-level log actions are usually disabled in PROD; their lines (often the ones with the payload) may be missing in Splunk.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
