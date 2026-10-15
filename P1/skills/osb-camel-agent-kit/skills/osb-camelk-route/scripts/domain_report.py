#!/usr/bin/env python3
"""Functional-testing report for one OSB application (domain): the proof, per flow and in total. Stdlib only.

    domain_report.py <workspace> [-o <workspace>/domain/FUNCTIONAL_TEST_REPORT.md]

Reads only what the other steps wrote (no payloads, no source): research packs, domain/COVERAGE.csv, the modules'
flow-test.json, case folders (counted), expected-output files (counted), surefire reports, GATES.json, MUTATION.json.
Per flow it answers the five proof questions:
  1 inputs     real masked Splunk messages / synthetic messages from the schema / none
  2 expected   outputs per scenario from the research pack; body: logged by OSB / original XQuery / not compared
  3 mocks      every queue and backend replaced (count), no broker
  4 result     tests run / failed against the Camel K route (or "not built yet")
  5 strength   deliberate route defects caught (mutation check)
and lists the gaps. Writes FUNCTIONAL_TEST_REPORT.md + functional-test-report.csv (names and counts only)."""
import argparse
import csv
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def load(p: Path, default):
    try:
        return json.loads(p.read_text(encoding="utf-8")) if p.is_file() else default
    except ValueError:
        return default


def surefire(mod: Path) -> dict | None:
    reps = list((mod / "target/surefire-reports").glob("TEST-*.xml"))
    if not reps:
        return None
    t = f = s = 0
    for rep in reps:
        r = ET.parse(rep).getroot()
        t += int(r.get("tests", 0))
        f += int(r.get("failures", 0)) + int(r.get("errors", 0))
        s += int(r.get("skipped", 0))
    return {"tests": t, "failed": f, "skipped": s}


def flow_row(ws: Path, project: str, proxy: str, coverage: dict) -> dict:
    res = load(ws / "research" / project / proxy / "research.json", {})
    share = load(ws / "research" / project / proxy / "SHARE_CHECK.json", {})
    mod = ws / "modules" / project / proxy
    cfg = load(mod / "src/test/resources/flow-test.json", {})
    par = mod / "src/test/resources/parity"
    cases = [p.parent for p in par.glob("**/input.payload")] if par.is_dir() else []
    real = [c for c in cases if "-synthetic" not in c.as_posix()]
    syn = [c for c in cases if "-synthetic" in c.as_posix()]
    logged = sum(1 for c in cases if any(c.glob("expected-output.*")))
    xq = any(t.get("mappings") for t in res.get("transforms") or [])
    gates = load(mod / "GATES.json", {})
    mut = load(mod / "MUTATION.json", {})
    sf = surefire(mod)
    card = (mod / "FLOW_CARD.md").read_text(encoding="utf-8") if (mod / "FLOW_CARD.md").is_file() else ""
    st = re.search(r"^Status:\s*(.+?)\s*$", card, re.M | re.I)          # the Status line, not the instruction text
    st = st.group(1).lower() if st else ""
    approved = "approved" if st == "approved" else ("POC run" if st.startswith("poc") else ("draft" if card else "-"))
    outputs = [o for o in (cfg.get("outputs") or {}) if o != "reply"]
    body = (f"compared for {logged} cases" if logged else
            ("XQuery: expected body pending" if xq else "not transformed (forwarded / no body)"))
    gaps = []
    if not share.get("pass"):
        gaps.append("research")
    if not cases:
        gaps.append("no test cases")
    elif not real:
        gaps.append("synthetic inputs only")
    if xq and not logged:
        gaps.append("body oracle")
    if sf is None:
        gaps.append("route not built")
    elif sf["failed"]:
        gaps.append(f"{sf['failed']} tests failing")
    if mut and mut.get("killed", 0) < mut.get("total", 0):
        gaps.append("mutation survived")
    if res.get("open_questions"):
        gaps.append(f"{len(res['open_questions'])} open questions")
    return {"project": project, "proxy": proxy, "group": coverage.get((project, proxy), "?"),
            "research": "PASS" if share.get("pass") else ("FAIL" if share else "-"),
            "scenarios": len(cfg.get("scenario_mapping") or []), "real_cases": len(real), "synthetic_cases": len(syn),
            "mocked_outputs": len(outputs) + len(cfg.get("backends") or {}), "reply": "yes" if "reply" in (cfg.get("outputs") or {}) else "no",
            "body_oracle": body, "card": approved,
            "tests": sf["tests"] if sf else "-", "failed": sf["failed"] if sf else "-",
            "mutations": f"{mut['killed']}/{mut['total']}" if mut else "-",
            "gates": gates.get("result", "-"), "gaps": "; ".join(gaps) or "none"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workspace", type=Path)
    ap.add_argument("-o", "--out", type=Path)
    a = ap.parse_args()
    ws = a.workspace
    status = ws / "domain/status.csv"
    if not status.is_file():
        sys.exit("domain/status.csv missing: run run_domain.sh <app> status first")
    flows = [(r["project"], r["proxy"]) for r in csv.DictReader(status.open(encoding="utf-8"))]
    coverage = {}
    cov = ws / "domain/coverage.csv"
    if cov.is_file():
        coverage = {(r["project"], r["proxy"]): r["group"].split(" ")[0] for r in csv.DictReader(cov.open(encoding="utf-8"))}
    rows = [flow_row(ws, p, x, coverage) for p, x in flows]
    out = a.out or ws / "domain/FUNCTIONAL_TEST_REPORT.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    cols = list(rows[0]) if rows else ["project"]
    with out.with_name("functional-test-report.csv").open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    n = len(rows)
    num = lambda k: sum(r[k] for r in rows if isinstance(r[k], int))  # noqa: E731
    built = [r for r in rows if isinstance(r["tests"], int)]
    green = [r for r in built if r["failed"] == 0]
    kill = [r["mutations"].split("/") for r in rows if "/" in r["mutations"]]
    proven = [r for r in green if "/" in r["mutations"] and r["mutations"].split("/")[0] == r["mutations"].split("/")[1]]
    md = [f"# Functional test report: {ws.resolve().name}", "",
          "Proof per flow: (1) inputs from production or the schema, (2) expected outputs from the OSB source and, for the "
          "body, from what OSB logged or the original XQuery, (3) every queue and backend mocked, (4) the Camel K route "
          "passes, (5) deliberate route defects are caught. Names and counts only.", "",
          "| Measure | Value |", "|---|---|",
          f"| Flows | {n} |",
          f"| Research packs PASS | {sum(r['research'] == 'PASS' for r in rows)} |",
          f"| Flows with a test pack | {sum((r['real_cases'] + r['synthetic_cases']) > 0 for r in rows)} |",
          f"| Scenarios / real cases / synthetic cases | {num('scenarios')} / {num('real_cases')} / {num('synthetic_cases')} |",
          f"| Flows built and run | {len(built)} |",
          f"| Flows green (0 failed) | {len(green)} |",
          f"| Tests run / failed | {sum(r['tests'] for r in built)} / {sum(r['failed'] for r in built)} |",
          f"| Mutations caught | {sum(int(k) for k, _ in kill)} / {sum(int(t) for _, t in kill)} |",
          f"| **Flows proven (green + every mutation caught)** | **{len(proven)}** |", "",
          "| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    md += ["| " + " | ".join(str(r[c]).replace("|", "/") for c in cols) + " |" for r in rows]
    open_gaps = {}
    for r in rows:
        for g in r["gaps"].split("; "):
            if g != "none":
                key = g.split(" ", 1)[1] if g[0].isdigit() else g
                open_gaps[key] = open_gaps.get(key, 0) + 1
    md += ["", "## Gaps across the domain", ""] + [f"- {k}: {v} flows" for k, v in sorted(open_gaps.items(), key=lambda kv: -kv[1])]
    out.write_text("\n".join(md) + "\n", encoding="utf-8")
    print(json.dumps({"flows": n, "built": len(built), "green": len(green), "proven": len(proven), "out": str(out)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
