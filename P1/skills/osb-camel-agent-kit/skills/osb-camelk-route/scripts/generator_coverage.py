#!/usr/bin/env python3
"""Which flows of an OSB application the generator can produce today, and which OSB constructs block the rest.
Reads the inventory written by osb_inventory.py (flows/*.json). Stdlib only, prints names and counts, no data.

    generator_coverage.py <inventory dir> [-o COVERAGE_GENERATOR.md]

Per flow: every pipeline action type, the proxy/business transports and the fn-bea functions are compared with what
assemble_jbang.py / body_chain.py generate today. A flow is "generated" when all of them are covered, else "blocked by"
the list of constructs. Per construct: how many flows use it, so the generator is extended in the order that frees
the most flows. The one-time extension replaces per-flow manual work."""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

# what the generator produces today (keep in sync with body_chain.py / assemble_jbang.py)
COVERED_ACTIONS = {"assign", "replace", "nxsdTranslation", "ifThenElse", "route", "log", "transportHeaders",
                   "transport-headers", "reply", "Error", "raiseError", "resume", "skip", "report", "alert"}
COVERED_TRANSPORTS = {"jms"}
COVERED_FN_BEA = {"uuid", "serialize"}
# covered with a documented assumption (listed under notes, not as a blocker)
NOTE_ONLY = {"routing-options": "route retry/URI overrides: generator uses the business-service defaults (retry 0); check BODY_CHAIN.md",
             "routingOptions": "see routing-options",
             "fn-bea:serialize": "serialize(): shim in OsbXQuery.java (Saxon serializer)"}
# how an uncovered construct is handled until the generator knows it
HOW = {"wsCallout": "service callout: generate to:{{backend}} + response variable; stub from WSDL/XSD",
       "javaCallout": "compiled Java in the export: port or wrap once per jar, cannot be generated",
       "javaScript": "JavaScript action: run the same script on Camel's JavaScript language (GraalJS) with a shim for the OSB process.* API; port by hand only where that fails",
       "javascript": "see javaScript",
       "publish": "publish: generate as fire-and-forget to:{{out}}", "publishTable": "publish table: generate as choice",
       "routeTable": "routing table: generate as choice", "dynamicRoute": "dynamic route: generate recipientList from the expression",
       "dynamicPublish": "dynamic publish: generate recipientList", "forEach": "forEach: generate split/aggregate",
       "insert": "insert/delete/rename: generate as an XQuery update step on Saxon", "delete": "see insert",
       "rename": "see insert", "validate": "validate: generate validator:{{xsd}}", "mflTransform": "MFL: no Camel equivalent, by hand",
       "nXSDTransform": "nXSD transform (XML-To-Native): reverse converter needed", "routingOptions": "routing options: map to endpoint options",
       "routing-options": "see routingOptions", "http": "HTTP transport: generate platform-http / http endpoints + reply",
       "sb": "SB transport: generate direct/endpoint", "jdbc": "JDBC: generate sql endpoint + stub",
       "jca": "JCA DB adapter (poller / insert / stored procedure): generate camel-sql / camel-jdbc endpoints from the adapter config; test with H2 stub",
       "lookupBasicCredentials": "service-account credentials: shim that reads a property/secret per account name",
       "execute-sql": "SQL inside XQuery: shim backed by camel-sql datasource, or move the query to a sql: step",
       "binary-to-text": "shim: base64/binary -> string", "inlinedXML": "shim: parse string -> node", "trim": "shim", "format-number": "shim",
       "fn-bea": "OSB XQuery function: one Saxon extension shim in OsbXQuery.java, written once, reused by every flow"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inventory", type=Path)
    ap.add_argument("-o", "--out", type=Path)
    a = ap.parse_args()
    files = sorted((a.inventory / "flows").glob("*.json"))
    if not files:
        print(f"no flows under {a.inventory}/flows (run osb_inventory.py first)")
        return 2
    rows, blockers, by_tier = [], Counter(), Counter()
    for f in files:
        d = json.loads(f.read_text(encoding="utf-8"))
        pipe = d.get("pipeline") or {}
        acts = set((pipe.get("action_counts") or {}).keys()) | set(pipe.get("unknown_actions") or [])
        trans = {str((d.get("proxy") or {}).get("transport") or "").lower()} | {str(b.get("transport") or "").lower() for b in d.get("business") or []}
        trans.discard("")
        fnbea = {fn for t in d.get("transforms") or [] for fn in t.get("fn_bea") or []} | set(pipe.get("fn_bea_inline") or [])
        xml_to_native = any("xml-to-native" in str(v).lower() for v in (pipe.get("nxsd_types") or []))
        raw = ((acts - COVERED_ACTIONS) | {t for t in trans if t not in COVERED_TRANSPORTS}
               | {f"fn-bea:{fn}" for fn in fnbea if fn not in COVERED_FN_BEA} | ({"nXSD XML-To-Native"} if xml_to_native else set()))
        notes = sorted(x for x in raw if x in NOTE_ONLY)
        bl = sorted(x for x in raw if x not in NOTE_ONLY)
        name = f"{d.get('project', '')}/{(d.get('proxy') or {}).get('name') or f.stem}"
        rows.append((name, (d.get("triage") or {}).get("tier", "-"), bl, notes))
        blockers.update(bl)
        by_tier[("generated" if not bl else "blocked")] += 1
    L = [f"# Generator coverage: {a.inventory}", "", f"{len(rows)} flows: {by_tier['generated']} generated today, {by_tier['blocked']} blocked by constructs the generator does not know yet.", "",
         "## Constructs by number of flows (extend the generator in this order)", "", "| Construct | Flows | How to cover it |", "|---|---|---|"]
    for c, n in blockers.most_common():
        key = c.split(":", 1)[1] if c.startswith("fn-bea:") else c
        L.append(f"| {c} | {n} | {HOW.get(key, HOW.get(c, 'extend body_chain/assemble_jbang'))} |")
    L += ["", "Covered with a documented assumption (not blockers): " + "; ".join(f"{k}: {v}" for k, v in NOTE_ONLY.items() if k != "routingOptions"), ""]
    L += ["## Flows", "", "| Flow | Triage tier | Status | Notes |", "|---|---|---|---|"]
    for name, tier, bl, notes in rows:
        L.append(f"| {name} | {tier} | {'generated' if not bl else 'blocked by ' + ', '.join(bl)} | {', '.join(notes)} |")
    text = "\n".join(L) + "\n"
    if a.out:
        a.out.write_text(text, encoding="utf-8")
    print("\n".join(L[:4 + min(len(blockers), 12) + 4]))
    if a.out:
        print(f"-> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
