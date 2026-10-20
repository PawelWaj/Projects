#!/usr/bin/env python3
"""Clusters the flows of an OSB application by their PATTERN (what the pipeline does, in which order), from the inventory
written by osb_inventory.py. Stdlib only, names and counts only.

    flow_patterns.py <inventory dir> [-o PATTERNS.md] [--json patterns.json]

Signature of a flow = proxy transport | ordered action sequence of the request stages | of the response stages | of the
error stages | branch kinds | business-service transports. Flows with the same signature differ only in names, endpoints,
conditions and transformation files, i.e. in parameters, not in logic. Why it matters for a weak model: the agent
researches ONE representative per pattern with care (few-shot material for its siblings), scripts extract the
parameters of every sibling, and the tests check each sibling against its own real messages. Research calls drop from
one per flow to one per pattern, and every sibling's answer is checked against a known-good template."""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path


def signature(d: dict) -> tuple:
    pipe = d.get("pipeline") or {}
    by_type: dict = defaultdict(list)
    for st in pipe.get("stages") or []:
        by_type[st.get("type") or "?"].append("+".join(st.get("actions") or []))
    branches = tuple(sorted(b.get("type", "?") for b in pipe.get("branches") or []))
    biz = tuple(sorted(str(b.get("transport") or "?") for b in d.get("business") or []))
    return (str((d.get("proxy") or {}).get("transport") or "?"),
            " > ".join(by_type.get("request", [])), " > ".join(by_type.get("response", [])), " > ".join(by_type.get("error", [])),
            branches, biz)


def family(d: dict) -> str:
    """Coarse group by the constructs a flow uses: the level at which research and generator work are shared."""
    pipe = d.get("pipeline") or {}
    acts = set((pipe.get("action_counts") or {}).keys())
    tr = str((d.get("proxy") or {}).get("transport") or "?")
    biz = {str(b.get("transport") or "?") for b in d.get("business") or []}
    tags = [f"in={tr}"]
    if "nxsdTranslation" in acts:
        tags.append("nxsd")
    if {"wsCallout"} & acts:
        tags.append("callout")
    if "javaScript" in acts or "javascript" in acts:
        tags.append("js")
    if "jca" in biz or tr == "jca":
        tags.append("db")
    if {"foreach", "forEach"} & acts:
        tags.append("loop")
    if "reply" in acts and tr in ("http", "local", "sb"):
        tags.append("reply")
    tags.append("out=" + ",".join(sorted(biz)) if biz else "out=-")
    return " ".join(tags)


def label(sig: tuple) -> str:
    tr, req, resp, err, br, biz = sig
    parts = [f"in={tr}", f"request[{req or '-'}]"]
    if resp:
        parts.append(f"response[{resp}]")
    if err:
        parts.append(f"error[{err}]")
    if br:
        parts.append("branches=" + ",".join(br))
    parts.append("out=" + ",".join(biz) if biz else "out=-")
    return " | ".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inventory", type=Path)
    ap.add_argument("-o", "--out", type=Path)
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()
    files = sorted((a.inventory / "flows").glob("*.json"))
    if not files:
        print(f"no flows under {a.inventory}/flows (run osb_inventory.py first)")
        return 2
    clusters: dict = defaultdict(list)
    families: dict = defaultdict(list)
    for f in files:
        d = json.loads(f.read_text(encoding="utf-8"))
        name = f"{d.get('project', '')}/{(d.get('proxy') or {}).get('name') or f.stem}"
        clusters[signature(d)].append((name, (d.get("triage") or {}).get("tier", "-")))
        families[family(d)].append(name)
    ordered = sorted(clusters.items(), key=lambda kv: -len(kv[1]))
    n = len(files)
    fam = sorted(families.items(), key=lambda kv: -len(kv[1]))
    L = [f"# Flow patterns: {a.inventory}", "", f"{n} flows in {len(fam)} families (by constructs used) and {len(ordered)} exact patterns "
         "(by action sequence). Research one representative per family with care, one per exact pattern cheaply, extract the "
         "parameters of the others by script, test each flow against its own real messages.", "",
         "## Families", "", "| # | Flows | Family | Representative | Members |", "|---|---|---|---|---|"]
    for i, (k, names) in enumerate(fam, 1):
        L.append(f"| {i} | {len(names)} | {k} | {names[0]} | {', '.join(names[1:8])}{' ...' if len(names) > 8 else ''} |")
    L += ["", "## Exact patterns", "", "| # | Flows | Pattern | Representative | Members |", "|---|---|---|---|---|"]
    out_json = []
    for i, (sig, members) in enumerate(ordered, 1):
        names = [m[0] for m in members]
        L.append(f"| {i} | {len(members)} | {label(sig)} | {names[0]} | {', '.join(names[1:6])}{' ...' if len(names) > 6 else ''} |")
        out_json.append({"pattern": i, "flows": len(members), "signature": label(sig), "representative": names[0], "members": names})
    covered = sum(len(m) for _, m in ordered[:10])
    L += ["", f"The 10 largest patterns cover {covered} of {n} flows ({100 * covered // max(n, 1)}%)."]
    text = "\n".join(L) + "\n"
    if a.out:
        a.out.write_text(text, encoding="utf-8")
    if a.json:
        a.json.write_text(json.dumps(out_json, indent=2), encoding="utf-8")
    print("\n".join(L[:3] + L[7:7 + min(len(fam), 12)] + L[-1:]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
