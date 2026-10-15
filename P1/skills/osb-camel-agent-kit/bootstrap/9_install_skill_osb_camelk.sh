#!/usr/bin/env bash
# Paste into the migration workspace root on the VDI and run: bash 9_install_skill_osb_camelk.sh
# Skill osb-camelk-route (research pack -> Camel K YAML module + tests + gates) under .pi/skills/ + implementer role + pi runners (one flow, whole domain).
set -euo pipefail
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/SKILL.md")"
cat > '.pi/skills/osb-camelk-route/SKILL.md' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SKILL_MD'
---
name: osb-camelk-route
description: "Turn one OSB proxy's research pack (research.json from osb-research) into a Camel K integration in YAML DSL with helper beans and L1 tests (Camel 4.18, mock endpoints, real masked log cases), then make it green against fixed gates. Use when asked to build, implement, generate or migrate a Camel K route from a research pack or FLOW_CARD.md, or when the user says osb-camelk-route."
---

# Research pack → Camel K route (YAML DSL) + tests

Input: `research/<project>/<proxy>/research.json` (the shareable pack, check PASS) and, on the client machine, the
masked task-1 cases. Output: `modules/<project>/<proxy>/`, a Maven test module around a `*.camel.yaml` route
(Camel 4.18.4 = Camel Quarkus 3.33.3, the Camel K runtime pin). Pattern: `pilot/sample-adjustment` in the repo.

## Rules

1. **Tests first and fixed.** `FlowParityTest.java` and `flow-test.json` are generated from research.json and are
   hash-checked (gate K5). Never edit them, never add `@Disabled`. If a test is wrong, the research is wrong: say so.
2. **The card decides.** Nothing is implemented before `FLOW_CARD.md` has `Status: approved` and an approver. Every
   behaviour in the route traces to a card section; anything not on the card is an open question, not code.
3. **Same behaviour as OSB, quirks included**: same outputs per scenario, body forwarded unchanged when OSB forwards it,
   same log line text under logName `oracle.osb.logging.pipeline`, same error headers, same retries.
   A difference you cannot avoid goes into `MIGRATION_NOTES.md` (what, why, who must accept it).
4. **No infrastructure in code.** Endpoints are `{{properties}}`; no hosts, ports, credentials (gate K4).
5. **Original transforms stay.** XQuery/XSLT/XSD files are copied from the OSB source into
   `src/main/resources/osb/` and run by `camel-saxon` / `camel-xslt-saxon`; never rewritten "because it is cleaner".
   They stay on the client machine with the module (client Git), never in a research pack.
6. Component options: check the Camel 4.18 docs; do not guess. Patterns proven on the pilot: `references/yaml-patterns.md`.

## Steps

1. **Scaffold (script):**
   `python <skill>/scripts/scaffold_camelk.py research/<project>/<proxy> -o modules/<project>/<proxy> --project <project> [--parity task1/fixtures/parity]`
   Writes the route skeleton (ids `branch-*`, `out-*`, `backend-*`; gaps marked `TODO(flow-card)`), properties,
   helper bean, generated tests, `FLOW_CARD.md` (draft). Route, properties and card are written once; tests always
   follow research.json.
2. **Approval (human):** a person checks the card against `RESEARCH.md`, resolves or accepts each open question, sets
   `Status: approved`, `Approver:`, `Date:`.
2b. **Test inputs where Splunk has none (pi tester, before the route):** every `scenario_mapping` row needs a case
   (gate K9). Rows without a real Splunk message get a synthetic case written by the tester role
   (`agents/tester-camelk.md`): fake values, built from the message schema in the OSB source, under
   `src/test/resources/parity/<project>-<proxy>-synthetic/`. Then
   `scaffold_camelk.py … --freeze-synthetic` records their hashes, so gate K5 also protects them from the implementer.
3. **Implement the route:** replace every `TODO(flow-card)` from the card. Keep the ids. Log templates become simple
   expressions with the same literal text. Conditions use the headers the helper bean sets (`${header.x}`).
4. **Error tests:** `src/test/java/<pkg>/FlowErrorTest.java`, at least one test per error scope on the card: invalid
   payload, each output/backend failing (mock `whenAnyExchangeReceived` throwing), retries counted
   (`getReceivedCounter()`), error headers and original body on the error output, generated traceId. Set retry delays
   to 0 through properties in the test, never by changing production defaults.
5. **Stubs:** one file per backend whose response is used: `src/test/resources/stubs/<backend>.json|xml|txt`,
   shape from research Q8, fake values only.
6. **Run until green:** `mvn -B test` then `python <skill>/scripts/check_camelk.py modules/<project>/<proxy>`. Gates:
   K1 card approved · K2 no TODO(flow-card) in src/main · K3 every route id present · K4 no infrastructure ·
   K5 generated tests and frozen synthetic cases untouched, nothing disabled · K6 stubs · K7 error tests ≥ error scopes ·
   K8 tests green · K9 every scenario_mapping row has a case.
7. **Prove the tests bite:** `python <skill>/scripts/mutate_route.py modules/<project>/<proxy> --mvn "mvn -B -q -s ~/.m2/settings.xml"`
   breaks the route on purpose (conditions negated, outputs swapped or dropped, retries removed); every mutation must
   make a test fail. A survivor means a missing test: add it to FlowErrorTest, never weaken the route to pass.
8. **Matrix:** `python <skill>/scripts/test_matrix.py modules/<project>/<proxy>` → `TEST_MATRIX.md` (P scenarios with
   real messages, E error tests, K gates, M mutations).
9. **Report** (five lines): proxy, gates result, tests run/failed/skipped (skipped = golden outputs pending),
   differences recorded in MIGRATION_NOTES.md, open questions left.

## What the generated parity test proves

Each case is sent to `direct:in` as request/reply. Request-response proxies (HTTP, local) have an output `reply`:
the answer to the caller, checked like a queue (present, no exception, body = golden where one exists).
Each real masked case is sent to `direct:in`. Its `SCENARIO.txt` is matched against `scenario_mapping` in research.json
(`k=v` equal, `k!=v` different or missing, first row wins) and must reach exactly those outputs, no others, with the
correlation header. Where `expected-output.json|xml` exists (the original XQuery run by golden_runner), the body must
be equal. Invalid JSON must reach the error output. The scenario fields the route branches on must be task-1
scenario dims (`SCENARIO_DIMS=...,body:<path>` from research `scenario_dims`), or the mapping cannot match.
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SKILL_MD
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/check_camelk.py")"
cat > '.pi/skills/osb-camelk-route/scripts/check_camelk.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_CHECK_CAMELK_PY'
#!/usr/bin/env python3
"""Gates for ONE generated Camel K module (run after `mvn test`). Stdlib only.

    check_camelk.py modules/<project>/<proxy> [--no-surefire]

K1 card approved       FLOW_CARD.md has `Status: approved` and an approver name
K2 no gaps left        no TODO(flow-card) in src/main (route, properties, beans)
K3 route ids           every branch-*, out-*, backend-* id from .scaffold.json is in the YAML route
K4 no infrastructure   no host names, IP addresses, host:port URIs or credentials in src/main
K5 tests untouched     FlowParityTest.java and flow-test.json equal their scaffold hash; no @Disabled anywhere
K6 backend stubs       a stub file per backend whose response is used
K7 error tests         FlowErrorTest has at least one test per error scope in research.json
K8 tests green         surefire reports: tests > 0, failures 0, errors 0 (skipped = golden pending, reported)
K9 scenarios covered   every scenario_mapping row has at least one case (real from Splunk or synthetic)
Writes GATES.json next to the module's pom; exit 1 if any gate fails."""
import argparse
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HOST = [(re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"), "IP address"),
        (re.compile(r"://(?!\{\{)[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "host name in a URI"),
        (re.compile(r"://[^/\s\"']*:\d{2,5}"), "host:port"),
        (re.compile(r"(?i)\b(password|passwd|secret|token|apikey|api-key)\s*[=:]\s*(?!\{\{|\$\{)[^\s\"',}]+"), "credential")]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--no-surefire", action="store_true", help="skip K8 (before mvn test ran)")
    a = ap.parse_args()
    mod = a.module
    meta = json.loads((mod / ".scaffold.json").read_text(encoding="utf-8"))
    gates = {}

    card = (mod / "FLOW_CARD.md").read_text(encoding="utf-8") if (mod / "FLOW_CARD.md").is_file() else ""
    approved = re.search(r"^Status:\s*approved\s*$", card, re.M | re.I) and re.search(r"^Approver:\s*\S+", card, re.M)
    gates["K1_card_approved"] = {"ok": bool(approved)}

    main_files = [p for p in (mod / "src/main").rglob("*") if p.is_file()]
    todo = [f"{p.relative_to(mod)}:{i}" for p in main_files for i, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1)
            if "TODO(flow-card)" in line]
    gates["K2_no_gaps"] = {"ok": not todo, "left": len(todo), "where": todo[:20]}

    route = "\n".join(p.read_text(encoding="utf-8") for p in (mod / "src/main/resources/routes").glob("*.camel.yaml"))
    missing = [i for i in meta["route_ids"] if not re.search(rf"\bid:\s*[\"']?{re.escape(i)}[\"']?\s*$", route, re.M)
               and not re.search(rf"\bid:\s*[\"']?{re.escape(i)}[\"']?\s*[,}}]", route)]
    gates["K3_route_ids"] = {"ok": not missing, "missing": missing}

    infra = []
    for p in main_files:
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if line.lstrip().startswith("#") or "xmlns" in line or "namespace" in line.lower():
                continue
            for rx, what in HOST:
                if rx.search(line):
                    infra.append(f"{p.relative_to(mod)}:{i} {what}")
    gates["K4_no_infrastructure"] = {"ok": not infra, "findings": infra[:20]}

    changed = [f for f, h in meta["generated"].items()
               if not (mod / f).is_file() or hashlib.sha256((mod / f).read_bytes()).hexdigest() != h]
    disabled = [str(p.relative_to(mod)) for p in (mod / "src/test").rglob("*.java") if "@Disabled" in p.read_text(encoding="utf-8")]
    gates["K5_tests_untouched"] = {"ok": not changed and not disabled, "changed": changed, "disabled": disabled}

    stubs = mod / "src/test/resources/stubs"
    no_stub = [b for b in meta.get("backends_with_response", []) if not any((stubs / f"{b}{e}").is_file() for e in (".json", ".xml", ".txt"))]
    gates["K6_backend_stubs"] = {"ok": not no_stub, "missing": no_stub}

    err_tests = 0
    for p in (mod / "src/test").rglob("FlowErrorTest.java"):
        err_tests += len(re.findall(r"@(Test|ParameterizedTest)\b", p.read_text(encoding="utf-8")))
    gates["K7_error_tests"] = {"ok": err_tests >= meta.get("errors", 0) and (err_tests > 0 or meta.get("errors", 0) == 0),
                               "tests": err_tests, "error_scopes": meta.get("errors", 0)}

    cfg = json.loads((mod / "src/test/resources/flow-test.json").read_text(encoding="utf-8"))
    scen = [dict(p.split("=", 1) for p in sc.read_text(encoding="utf-8").strip().split("|") if "=" in p)
            for sc in (mod / "src/test/resources/parity").glob("*/*/SCENARIO.txt")]

    def hit(key: str, v: dict) -> bool:
        for p in key.split("|"):
            if "!=" in p:
                k, x = p.split("!=", 1)
                if v.get(k) == x:
                    return False
            elif "=" in p:
                k, x = p.split("=", 1)
                if v.get(k) != x:
                    return False
        return bool(key)
    uncovered = [m["scenario"] for m in cfg.get("scenario_mapping", []) if not any(hit(m["scenario"], v) for v in scen)]
    gates["K9_scenarios_covered"] = {"ok": not uncovered, "uncovered": uncovered}

    if not a.no_surefire:
        t = f = e = s = 0
        for rep in (mod / "target/surefire-reports").glob("TEST-*.xml"):
            r = ET.parse(rep).getroot()
            t += int(r.get("tests", 0))
            f += int(r.get("failures", 0))
            e += int(r.get("errors", 0))
            s += int(r.get("skipped", 0))
        gates["K8_tests_green"] = {"ok": t > 0 and f == 0 and e == 0, "tests": t, "failures": f, "errors": e, "skipped": s}

    ok = all(g["ok"] for g in gates.values())
    out = {"proxy": meta["proxy"], "project": meta["project"], "result": "PASS" if ok else "FAIL", "gates": gates}
    (mod / "GATES.json").write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    for k, g in gates.items():
        print(f"{'ok  ' if g['ok'] else 'FAIL'} {k} " + json.dumps({x: y for x, y in g.items() if x != 'ok'}))
    print(out["result"])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_CHECK_CAMELK_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/domain_report.py")"
cat > '.pi/skills/osb-camelk-route/scripts/domain_report.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_DOMAIN_REPORT_PY'
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
    approved = "approved" if "Status: approved" in card else ("POC run" if "Status: poc" in card.lower() else ("draft" if card else "-"))
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
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_DOMAIN_REPORT_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/mutate_route.py")"
cat > '.pi/skills/osb-camelk-route/scripts/mutate_route.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_MUTATE_ROUTE_PY'
#!/usr/bin/env python3
"""Mutation check for ONE Camel K module: break the YAML route on purpose, one defect at a time, and prove the tests
notice. A test suite that stays green on a broken route proves nothing. Stdlib only.

    mutate_route.py modules/<project>/<proxy> [--mvn "mvn -B -q -s ~/.m2/settings.xml"] [--max 12]

Mutations (generic, from the route text):
  negate      every simple condition: '==' <-> '!=' (a branch taken for the wrong messages)
  swap-out    every output endpoint {{out.a}} -> another output {{out.b}} (message sent to the wrong queue)
  drop-out    every output step removed (message silently lost)
  no-retry    every redelivery count -> 0 (business service retry ignored)
Each mutation runs `mvn test`; a non-zero exit = caught. The route file is always restored, even on Ctrl-C.
Writes MUTATION.json (what, killed) next to the pom. Exit 1 if any mutation survived."""
import argparse
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path


def mutations(text: str) -> list[tuple[str, str]]:
    out = []
    for m in re.finditer(r"(simple:\s*\"[^\"]*?)(==|!=)", text):
        flip = "!=" if m.group(2) == "==" else "=="
        ids = re.findall(r"\bid:\s*([\w.-]+)", text[:m.start(2)])
        out.append((f"negate condition of {ids[-1] if ids else 'a branch'}", text[:m.start(2)] + flip + text[m.end(2):]))
    outs = re.findall(r"\{\{out\.([\w.-]+)\}\}", text)
    names = sorted(set(outs))
    for m in re.finditer(r"\{\{out\.([\w.-]+)\}\}", text):
        other = next((n for n in names if n != m.group(1)), None)
        if other:
            out.append((f"send to out-{other} instead of out-{m.group(1)}", text[:m.start()] + "{{out." + other + "}}" + text[m.end():]))
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if re.match(r"\s*- to:\s*$", line) and i + 2 < len(lines) and "{{out." in "".join(lines[i + 1:i + 3]):
            ind = len(line) - len(line.lstrip())
            j = i + 1
            while j < len(lines) and (len(lines[j]) - len(lines[j].lstrip())) > ind and lines[j].strip():
                j += 1
            target = re.search(r"\{\{out\.([\w.-]+)\}\}", "".join(lines[i:j])).group(1)
            stub = " " * ind + "- log:\n" + " " * (ind + 4) + "message: \"mutation: output removed\"\n"
            out.append((f"drop the step sending to out-{target}", "".join(lines[:i]) + stub + "".join(lines[j:])))
    for m in re.finditer(r"(maximumRedeliveries:\s*\")([^\"]+)(\")", text):
        out.append(("retry count set to 0", text[:m.start(2)] + "0" + text[m.end(2):]))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--mvn", default="mvn -B -q")
    ap.add_argument("--max", type=int, default=12)
    a = ap.parse_args()
    a.mvn = " ".join(shlex.quote(os.path.expanduser(x)) for x in shlex.split(a.mvn))   # ~ in -s ~/.m2/settings.xml
    routes = sorted((a.module / "src/main/resources/routes").glob("*.camel.yaml"))
    if not routes:
        sys.exit("no *.camel.yaml route in the module")
    base = subprocess.run(shlex.split(a.mvn) + ["-f", str(a.module / "pom.xml"), "test"], capture_output=True, text=True)
    if base.returncode:
        sys.exit("tests are not green on the unchanged route: fix that first (mutation check needs a green baseline)")
    results = []
    for route in routes:
        orig = route.read_text(encoding="utf-8")
        try:
            for what, text in mutations(orig)[:a.max]:
                route.write_text(text, encoding="utf-8")
                r = subprocess.run(shlex.split(a.mvn) + ["-f", str(a.module / "pom.xml"), "test"], capture_output=True, text=True)
                results.append({"route": route.name, "what": what, "killed": r.returncode != 0})
                print(f"{'caught  ' if r.returncode else 'MISSED  '}{what}", flush=True)
        finally:
            route.write_text(orig, encoding="utf-8")
    subprocess.run(shlex.split(a.mvn) + ["-f", str(a.module / "pom.xml"), "test"], capture_output=True)   # leave green reports
    killed = sum(m["killed"] for m in results)
    (a.module / "MUTATION.json").write_text(json.dumps({"killed": killed, "total": len(results), "mutations": results}, indent=2) + "\n",
                                            encoding="utf-8")
    print(f"mutations caught {killed}/{len(results)}")
    return 0 if killed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_MUTATE_ROUTE_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/scaffold_camelk.py")"
cat > '.pi/skills/osb-camelk-route/scripts/scaffold_camelk.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_SCAFFOLD_CAMELK_PY'
#!/usr/bin/env python3
"""Research pack -> Camel K module skeleton for ONE proxy (deterministic, no judgement).

    scaffold_camelk.py research/<project>/<proxy> -o modules/<project>/<proxy> --project <project>
                       [--parity task1/fixtures/parity] [--correlation-header traceId] [--force]

Reads research.json (+ facts.json for log scenario counts) and writes the module the pi implementer completes:
  FLOW_CARD.md                         the card a human approves (Status: draft -> approved)
  pom.xml                              Camel 4.18.4 test module (pilot pattern), extra deps from the transforms
  src/main/resources/routes/<proxy>.camel.yaml   route skeleton: entry, helper bean, OSB log lines, one choice per
                                       branch with ids branch-*, outputs out-*, backends listed, error catch;
                                       every gap is marked TODO(flow-card) and check_camelk.py fails until it is gone
  src/main/resources/application.properties      endpoints as properties (no hosts: env placeholders)
  src/main/java/<pkg>/OsbJson.java     lenient JSON + scenario headers (JSON flows only)
  src/test/java/<pkg>/FlowParityTest.java        generic parity test driven by
  src/test/resources/flow-test.json    outputs, backends, scenario_mapping, error output (from research.json)
  src/test/resources/stubs/README.md   which backend stubs the implementer must write (shape from research Q8)
  .scaffold.json                       hashes of the generated tests + the ids the route must contain
Route, properties and card are written once (the implementer edits them); tests and flow-test.json are regenerated
on every run so they always follow research.json. --parity copies the masked task-1 cases into the module (VDI only;
.gitignore keeps them out of Git). Stdlib only."""
import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

TPL = Path(__file__).resolve().parents[1] / "assets/templates"
TODO = "TODO(flow-card)"


def slug(s: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", (s or "").lower())).strip("-") or "x"


def java_pkg(project: str, proxy: str) -> str:
    part = lambda s: re.sub(r"^(\d)", r"_\1", re.sub(r"[^a-z0-9]", "", s.lower())) or "x"  # noqa: E731
    return f"osb.{part(project)}.{part(proxy)}"


def q(s) -> str:
    """YAML double-quoted scalar (JSON string syntax is valid YAML)."""
    return json.dumps(str(s), ensure_ascii=False)


def endpoint(dest: str, kind: str) -> str:
    """Production endpoint for a research destination (scheme:name, never a host)."""
    d = (dest or "").strip()
    if not d or d.upper() == "UNKNOWN":
        return f"{TODO} destination of {kind}"
    m = re.match(r"^(https?):(/.*)$", d)
    if m:
        return f"{m.group(1)}://{{{{env:{slug(kind).upper().replace('-', '_')}_HOST}}}}{m.group(2)}"
    name = re.sub(r"^(jms|amqp|queue|topic):", "", d)
    kind_ = "topic" if d.startswith("topic:") else "queue"
    return f"amqp:{kind_}:{name}"


def model(r: dict, facts: dict, corr: str) -> dict:
    """Normalise research.json: outputs keyed by the business service that writes them (JMS backends ARE outputs and
    get no reply stub), branch paths and scenario mapping resolved to those keys, one error output."""
    raw_backends = r.get("backends") or []
    outputs, alias = {}, {}
    for o in r.get("outputs") or []:
        dest = o.get("destination") or ""
        owner = next((b for b in raw_backends if dest and dest in (b.get("operation") or "", b.get("destination") or "")), None)
        key = slug(o.get("business_service") or (owner.get("name") if owner else o.get("name")))
        outputs[key] = {"name": o.get("name"), "destination": dest, "on_path": o.get("on_path") or o.get("on") or "",
                        "headers": o.get("headers") or [], "backend": owner.get("name") if owner else None}
        for a in (o.get("name"), dest, owner.get("name") if owner else None, key):
            if a:
                alias[slug(a)] = key
    entry = r.get("entry") or {}
    wants_reply = (str(entry.get("transport") or "").lower().startswith(("http", "local", "sb"))
                   or str(entry.get("response_required") or "").lower() == "true"
                   or any(str(o).lower() == "reply" for x in r.get("scenario_mapping") or [] for o in (x.get("outputs") or [])))
    if wants_reply:
        outputs["reply"] = {"name": "reply to the caller", "destination": "caller", "on_path": "end of the request pipeline",
                            "headers": [], "backend": None}
        alias["reply"] = "reply"
    resolve = lambda x: alias.get(slug(x), slug(x))  # noqa: E731
    err = next((k for k, o in outputs.items() if re.search(r"error", f"{o['on_path']} {o['name']} {o['destination']}", re.I)), None)
    for e in r.get("errors") or []:
        if err:
            break
        g = e.get("goes_to") or ""
        err = next((k for a, k in alias.items() if a and a in slug(g)), None)
    if err is None:
        outputs["error"] = {"name": "error", "destination": "", "on_path": "error handler", "headers": [], "backend": None}
        err = "error"
    backends = {slug(b.get("name")): b for b in raw_backends if slug(b.get("name")) not in outputs}
    paths = []
    for b in r.get("branches") or []:
        for p in b.get("paths") or []:
            paths.append({"branch": slug(b.get("name")), "id": f"branch-{slug(b.get('name'))}-{slug(p.get('label'))}",
                          "label": p.get("label", ""), "plain": p.get("condition_plain", ""), "expr": p.get("condition_expr", ""),
                          "outputs": [resolve(x) for x in p.get("outputs") or [] if resolve(x) in outputs]})
    mapping = []
    for x in r.get("scenario_mapping") or []:
        outs = x.get("outputs") if isinstance(x.get("outputs"), list) else [x.get("output")]
        outs = [resolve(o) for o in outs if o and str(o).lower() not in ("none", "-")]
        sc = x.get("scenario", "")
        mapping.append({"scenario": sc if "=" in sc else "*", "outputs": outs, "branch": x.get("branch", ""), "path": x.get("path", "")})
    dims = [(d.lstrip("/").split(".")[-1], d) for d in r.get("scenario_dims") or [] if d]
    fmt = ((r.get("entry") or {}).get("payload_format") or "UNKNOWN").lower()
    return {"outputs": outputs, "error": err, "backends": backends, "paths": paths, "mapping": mapping, "dims": dims,
            "format": fmt, "corr": corr, "logs": r.get("logs") or [], "transforms": r.get("transforms") or [],
            "branches": r.get("branches") or [], "entry": r.get("entry") or {}}


def route_yaml(proxy: str, project: str, pkg: str, m: dict) -> str:
    L = [f"# Camel K route (YAML DSL) for OSB project {project}, proxy {proxy}.",
         "# GENERATED SKELETON from the research pack (osb-camelk-route). The implementer fills every gap marked TODO",
         "# using FLOW_CARD.md; ids branch-*, out-*, backend-* must stay (check_camelk.py and the tests rely on them).",
         "# Endpoints are properties: production values in application.properties (Camel K: traits.camel.properties),",
         "# tests replace them with direct:/mock: endpoints.",
         "- route:", f"    id: {proxy}", "    from:", '      uri: "{{flow.input}}"', "      steps:",
         "        - doTry:", "            steps:"]
    ind = " " * 14
    if m["format"] == "json":
        L += [f"{ind}- bean:", f"{ind}    beanType: {pkg}.OsbJson", f"{ind}    method: annotate"]
    main_logs = [lg for lg in m["logs"] if not re.search(r"error", lg.get("stage") or "", re.I)]
    err_logs = [lg for lg in m["logs"] if lg not in main_logs]
    for lg in main_logs:
        L += [f"{ind}- log:", f"{ind}    loggingLevel: {(lg.get('level') or 'INFO').upper() if (lg.get('level') or '').upper() in ('INFO', 'DEBUG', 'WARN', 'ERROR', 'TRACE') else 'INFO'}",
              f"{ind}    logName: oracle.osb.logging.pipeline",
              f"{ind}    message: {q(TODO + ' convert to simple: ' + (lg.get('template') or ''))}"]
    L.append(f"{ind}# --- BEGIN flow logic (from the approved FLOW_CARD.md) ---")
    for t in m["transforms"]:
        L.append(f"{ind}# transform {t.get('name')}: {t.get('purpose', '')} -> keep the original file, see FLOW_CARD.md")
    for k, b in m["backends"].items():
        L.append(f"{ind}# place: - to: {{id: backend-{k}, uri: \"{{{{backend.{k}}}}}\"}}   ({b.get('type', '')} {b.get('operation', '')}; "
                 f"called when: {b.get('called_when', '')})")
    by_branch = {}
    for p in m["paths"]:
        by_branch.setdefault(p["branch"], []).append(p)
    placed = set()
    for b, ps in by_branch.items():
        L += [f"{ind}- choice:", f"{ind}    id: branch-{b}", f"{ind}    when:"]
        for p in ps:
            L += [f"{ind}      - id: {p['id']}", f"{ind}        simple: {q(TODO + ' ' + (p['plain'] or p['label']))}",
                  f"{ind}        steps:"]
            outs = p["outputs"] or []
            for o in outs:
                if o == "reply":
                    L += [f"{ind}          - log:", f"{ind}              message: {q(TODO + ' build the reply to the caller here (body at the end of the route)')}"]
                    placed.add(o)
                    continue
                L += [f"{ind}          - to:", f"{ind}              id: out-{o}", f'{ind}              uri: "{{{{out.{o}}}}}"']
                placed.add(o)
            if not outs:
                L += [f"{ind}          - log:", f"{ind}              message: {q(TODO + ' path ' + p['label'] + ': no output in research')}"]
    rest = [o for o in m["outputs"] if o not in placed and o not in (m["error"], "reply")]
    if rest and not by_branch:
        for o in rest:
            L += [f"{ind}- to:", f"{ind}    id: out-{o}", f'{ind}    uri: "{{{{out.{o}}}}}"']
    elif rest:
        L.append(f"{ind}# {TODO} outputs not on any branch path in research.json, place them: " + ", ".join(f"out-{o}" for o in rest))
    L += [f"{ind}# --- END flow logic ---", "            doCatch:", "              - exception:", "                  - java.lang.Exception",
          "                steps:"]
    for lg in err_logs:
        L += ["                  - log:", "                      loggingLevel: INFO", "                      logName: oracle.osb.logging.pipeline",
              f"                      message: {q(TODO + ' convert to simple: ' + (lg.get('template') or ''))}"]
    L += ["                  - setHeader:", "                      name: errorCode",
          f"                      constant: {q(TODO + ' errorCode per research Q9')}",
          "                  - setHeader:", "                      name: errorMessage", '                      simple: "${exception.message}"',
          "                  - to:", f"                      id: out-{m['error']}", f'                      uri: "{{{{out.{m["error"]}}}}}"']
    return "\n".join(L) + "\n"


def properties(proxy: str, m: dict) -> str:
    e = m["entry"]
    dest, sub = e.get("destination") or "", str(e.get("durable_subscription") or "")
    if sub.lower() in ("true", "yes"):
        sub = proxy                      # OSB names the subscription itself; on Artemis the subscription queue is ours to name
    name = re.sub(r"^(jms|amqp|queue|topic):", "", dest)
    if not name or name.upper() == "UNKNOWN":
        inp = f"{TODO} entry destination"
    elif e.get("is_topic") and sub:
        inp = f"amqp:queue:{name}::{sub}"
    elif e.get("is_topic"):
        inp = f"{TODO} topic {name} without a durable subscription name"
    else:
        inp = f"amqp:queue:{name}"
    L = ["# Production endpoints (Camel K: spec.traits.camel.properties or a mounted config). No hosts, ports or",
         "# credentials here: HTTP hosts come from env, broker connection from the platform config.",
         "# Durable topic subscription = subscription queue consumed by FQQN <address>::<subscription> (AGENTS.md).",
         f"camel.main.name={proxy}", "camel.main.routes-include-pattern=classpath:routes/*.camel.yaml", f"flow.input={inp}"]
    L += [f"out.{k}={endpoint(o['destination'], k)}" for k, o in m["outputs"].items() if k != "reply"]
    L += [f"backend.{k}={endpoint(b.get('operation') if (b.get('type') or '').lower().startswith('http') else b.get('name'), k)}"
          for k, b in m["backends"].items()]
    return "\n".join(L) + "\n"


def test_props(m: dict) -> list[str]:
    return (["flow.input=direct:in"] + [f"out.{k}=mock:out-{k}" for k in m["outputs"] if k != "reply"]
            + [f"backend.{k}=mock:backend-{k}" for k in m["backends"]])


def unmapped_scenarios(m: dict, facts: dict) -> list[str]:
    keys = [x["scenario"] for x in m["mapping"] if x["scenario"]]
    return [s.get("scenario", "") for s in facts.get("log_scenarios") or [] if not any(matches(k, s.get("scenario", "")) for k in keys)]


def parts(scenario: str) -> dict:
    return dict(p.split("=", 1) for p in scenario.split("|") if "=" in p and "!=" not in p)


def matches(key: str, scenario: str) -> bool:
    """Same rule as FlowParityTest: every k=v of the key equals the scenario's value, every k!=v differs (missing counts as different)."""
    sc = parts(scenario)
    for p in key.split("|"):
        if "!=" in p:
            k, v = p.split("!=", 1)
            if sc.get(k) == v:
                return False
        elif "=" in p:
            k, v = p.split("=", 1)
            if sc.get(k) != v:
                return False
    return True


def card(proxy: str, project: str, r: dict, facts: dict, m: dict, rsha: str) -> str:
    counts = {s.get("scenario"): s.get("count") for s in facts.get("log_scenarios") or []}
    unmapped = unmapped_scenarios(m, facts)
    row = lambda *c: "| " + " | ".join(str(x if x not in (None, "") else "-").replace("|", "/").replace("\n", " ") for x in c) + " |"  # noqa: E731
    L = [f"# Flow card: {project} / {proxy}", "",
         f"Source: research pack `research.json` sha256 {rsha[:16]} (no OSB code in this card).",
         "Status: draft", "Approver: ", "Date: ", "",
         "Approve by setting `Status: approved`, your name and the date, after checking every table against RESEARCH.md",
         "and resolving or accepting each open question. The implementer does not start before that.", "",
         "## 1 Entry", "", "| Item | Value |", "|---|---|"]
    L += [row(k, v) for k, v in m["entry"].items()]
    L += ["", "## 2 Branches (route ids)", "", "| Route id | Condition (plain) | Condition (OSB) | Outputs |", "|---|---|---|---|"]
    L += [row(p["id"], p["plain"], p["expr"], ", ".join("out-" + o for o in p["outputs"])) for p in m["paths"]] or ["| none | | | |"]
    L += ["", "## 3 Scenario mapping (from the logs → tests)", "", "| Scenario | Messages in export | Branch / path | Output |", "|---|---|---|---|"]
    L += [row(x["scenario"], sum(v or 0 for s, v in counts.items() if matches(x["scenario"], s)),
              f"{x['branch']} / {x['path']}", ", ".join("out-" + o for o in x["outputs"]) or "none") for x in m["mapping"]]
    if unmapped:
        L += ["", f"**{len(unmapped)} log scenario(s) without a mapping** (their parity tests fail until research.json maps them):"]
        L += [f"- {s}" for s in unmapped]
    L += ["", "## 4 Outputs", "", "| Route id | Name | Destination | Property | Headers |", "|---|---|---|---|---|"]
    L += [row("out-" + k, o["name"], o["destination"], f"out.{k}", ", ".join(f"{h.get('name')}←{h.get('source')}" for h in o["headers"]))
          for k, o in m["outputs"].items()]
    L += ["", f"Error output: `out-{m['error']}`.", "", "## 5 Backends (L1: mock endpoints with stubs)", "",
          "| Route id | Type | Operation | Called when | Response use | Retry | Timeout | On fault |", "|---|---|---|---|---|---|---|---|"]
    L += [row("backend-" + k, b.get("type"), b.get("operation"), b.get("called_when"), b.get("response_use"), b.get("retry"),
              b.get("timeout"), b.get("on_fault")) for k, b in m["backends"].items()] or ["| none | | | | | | | |"]
    L += ["", "## 6 Transforms (original files kept, run by camel-saxon / camel-xslt-saxon)", "",
          "| Name | Purpose | fn-bea functions | Mappings in research |", "|---|---|---|---|"]
    L += [row(t.get("name"), t.get("purpose"), ", ".join(t.get("fn_bea") or []), len(t.get("mappings") or [])) for t in m["transforms"]] or ["| none | | | |"]
    L += ["", "## 7 Errors (one test each in FlowErrorTest)", "", "| Scope | Catches | Goes to | Headers | Redelivery |", "|---|---|---|---|---|"]
    L += [row(e.get("scope"), e.get("catches"), e.get("goes_to"), ", ".join(e.get("headers") or []), e.get("redelivery")) for e in r.get("errors") or []] or ["| none | | | | |"]
    L += ["", "## 8 Log lines (same text as OSB, logName oracle.osb.logging.pipeline)", "", "| Stage | Level | Template |", "|---|---|---|"]
    L += [row(x.get("stage"), x.get("level"), x.get("template")) for x in m["logs"]] or ["| none | | |"]
    L += ["", "## 9 Open questions (each: answered, or accepted with a reason, before approval)", ""]
    L += [f"- [ ] {x}" for x in r.get("open_questions") or []] or ["- none"]
    return "\n".join(L) + "\n"


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def write_once(p: Path, text: str, force: bool) -> bool:
    if p.exists() and not force:
        return False
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("research", type=Path)
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--parity", type=Path, help="task1/fixtures/parity (masked cases; copied, never committed)")
    ap.add_argument("--correlation-header", default="traceId")
    ap.add_argument("--force", action="store_true", help="also overwrite route, properties and card")
    ap.add_argument("--freeze-synthetic", action="store_true",
                    help="only record hashes of the tester's synthetic cases (parity/*-synthetic/**) so gate K5 protects them")
    a = ap.parse_args()
    if a.freeze_synthetic:
        moved = []
        # a case folder sits BELOW its scenario folder (SCENARIO.txt); move cases written next to SCENARIO.txt into case1/
        for scen in (a.out / "src/test/resources/parity").glob("*-synthetic/**/SCENARIO.txt"):
            loose = [p for p in scen.parent.iterdir() if p.is_file() and p.name != "SCENARIO.txt"]
            if any(p.name == "input.payload" for p in loose):
                case = scen.parent / "case1"
                case.mkdir(exist_ok=True)
                for p in loose:
                    p.rename(case / p.name)
                    moved.append(p.relative_to(a.out).as_posix())
        meta = json.loads((a.out / ".scaffold.json").read_text(encoding="utf-8"))
        for k in moved:                     # a hash frozen at the old place moves with the file (it was not edited)
            if k in meta["generated"]:
                meta["generated"][k.rsplit("/", 1)[0] + "/case1/" + k.rsplit("/", 1)[1]] = meta["generated"].pop(k)
        syn = sorted(p for p in (a.out / "src/test/resources/parity").glob("*-synthetic/**/*") if p.is_file())
        for p in syn:                       # first freeze wins: a later change shows up in gate K5, it is never re-blessed
            meta["generated"].setdefault(p.relative_to(a.out).as_posix(), sha(p))
        (a.out / ".scaffold.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"frozen_synthetic_files": len(syn)}))
        return 0
    rp = a.research / "research.json"
    if not rp.is_file():
        sys.exit(f"missing {rp}: run pi/run_research.sh first")
    r = json.loads(rp.read_text(encoding="utf-8"))
    fp = a.research / "facts.json"
    facts = json.loads(fp.read_text(encoding="utf-8")) if fp.is_file() else {}
    proxy = r.get("proxy") or a.research.name
    pkg = java_pkg(a.project, proxy)
    m = model(r, facts, a.correlation_header)
    o = a.out
    deps = []
    kinds = " ".join((t.get("name") or "") + " " + (t.get("purpose") or "") for t in m["transforms"]).lower()
    ref_kinds = " ".join((t.get("ref") or "") + " " + (t.get("kind") or "") for t in facts.get("transforms") or []).lower()
    if "xq" in ref_kinds or "xquery" in kinds:
        deps.append("camel-saxon")
    if "xsl" in ref_kinds or "xslt" in kinds:
        deps.append("camel-xslt-saxon")
    pom = (TPL / "pom.xml").read_text(encoding="utf-8").replace("@@GROUP@@", "osb." + slug(a.project)).replace(
        "@@ARTIFACT@@", slug(proxy)).replace("@@PROJECT@@", a.project).replace("@@PROXY@@", proxy).replace(
        "<!-- @@EXTRA_DEPS@@ -->", "\n    ".join(f"<dependency><groupId>org.apache.camel</groupId><artifactId>{d}</artifactId></dependency>"
                                            for d in deps) or "<!-- no transform dependencies -->")
    written = []
    jdir = pkg.replace(".", "/")
    for path, text, once in [
        (o / "pom.xml", pom, True),
        (o / f"src/main/resources/routes/{proxy}.camel.yaml", route_yaml(proxy, a.project, pkg, m), True),
        (o / "src/main/resources/application.properties", properties(proxy, m), True),
        (o / "FLOW_CARD.md", card(proxy, a.project, r, facts, m, sha(rp)), True),
        (o / ".gitignore", "target/\nsrc/test/resources/parity/\n", True),
    ]:
        if write_once(path, text, a.force):
            written.append(path.relative_to(o).as_posix())
    if m["format"] == "json":
        bean = (TPL / "OsbJson.java.tpl").read_text(encoding="utf-8").replace("@@PACKAGE@@", pkg).replace(
            "@@HEADER_PATHS@@", ", ".join("{" + q(h) + ", " + q(p) + "}" for h, p in m["dims"]))
        if write_once(o / f"src/main/java/{jdir}/OsbJson.java", bean, a.force):
            written.append(f"src/main/java/{jdir}/OsbJson.java")
    test = (TPL / "FlowParityTest.java.tpl").read_text(encoding="utf-8").replace("@@PACKAGE@@", pkg).replace(
        "@@PROJECT@@", a.project).replace("@@PROXY@@", proxy).replace("@@INPUT@@", "direct:in").replace(
        "@@TEST_PROPERTIES@@", ", ".join(q(p) for p in test_props(m)))
    cfg = {"outputs": {k: ("reply" if k == "reply" else f"mock:out-{k}") for k in m["outputs"]}, "error_output": m["error"],
           "backends": {k: {"mock": f"mock:backend-{k}", "response_use": b.get("response_use", "")} for k, b in m["backends"].items()},
           "scenario_mapping": [{"scenario": x["scenario"], "outputs": x["outputs"]} for x in m["mapping"]],
           "correlation_header": m["corr"], "payload_format": m["format"]}
    tp = o / f"src/test/java/{jdir}/FlowParityTest.java"
    cp = o / "src/test/resources/flow-test.json"
    for path, text in [(tp, test), (cp, json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")]:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        written.append(path.relative_to(o).as_posix())
    stubs = ["# Backend stubs for the L1 tests", "", "One file per backend, named <backend>.json / .xml / .txt: the response shape from",
             "research Q8 (WSDL/XSD), with FAKE values only. FlowErrorTest makes the same mocks throw for the error tests.", ""]
    stubs += [f"- `{k}.*`: {b.get('type', '')} {b.get('operation', '')}; response use: {b.get('response_use', '') or '-'}" for k, b in m["backends"].items()] or ["- no backends"]
    write_once(o / "src/test/resources/stubs/README.md", "\n".join(stubs) + "\n", True)
    copied = 0
    if a.parity and a.parity.is_dir():
        dst = o / "src/test/resources/parity"
        for flow_dir in a.parity.iterdir():
            if flow_dir.is_dir():
                shutil.copytree(flow_dir, dst / flow_dir.name, dirs_exist_ok=True)
                copied += sum(1 for _ in (dst / flow_dir.name).glob("*/*/input.payload"))
    old_meta = json.loads((o / ".scaffold.json").read_text(encoding="utf-8")) if (o / ".scaffold.json").is_file() else {}
    ids = ([f"branch-{b}" for b in {p["branch"] for p in m["paths"]}] + [p["id"] for p in m["paths"]]
           + [f"out-{k}" for k in m["outputs"] if k != "reply"] + [f"backend-{k}" for k in m["backends"]])
    meta = {"proxy": proxy, "project": a.project, "package": pkg, "research_sha256": sha(rp),
            "generated": {**{k: v for k, v in (old_meta.get("generated") or {}).items() if "-synthetic/" in k},
                          tp.relative_to(o).as_posix(): sha(tp), cp.relative_to(o).as_posix(): sha(cp)},
            "route_ids": sorted(ids), "errors": len(r.get("errors") or []),
            "task1": str(a.parity.parent.parent.resolve()) if a.parity and a.parity.is_dir() else (old_meta.get("task1") or ""),
            "backends_with_response": [k for k, b in m["backends"].items()
                                       if (b.get("response_use") or "").strip().lower() not in ("", "none", "ignored", "not used", "-")]}
    (o / ".scaffold.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"proxy": proxy, "module": str(o), "written": len(written), "parity_cases": copied,
                      "branches": len(m["paths"]), "outputs": len(m["outputs"]), "backends": len(m["backends"]),
                      "unmapped_log_scenarios": len(unmapped_scenarios(m, facts))}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_SCAFFOLD_CAMELK_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/test_matrix.py")"
cat > '.pi/skills/osb-camelk-route/scripts/test_matrix.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_TEST_MATRIX_PY'
#!/usr/bin/env python3
"""Test matrix: what was tested, with which inputs, and the result, per flow and for a whole domain. Stdlib only.

    test_matrix.py modules/<project>/<proxy>            -> <module>/TEST_MATRIX.md + test-matrix.csv
    test_matrix.py --domain modules -o domain           -> domain/TEST_MATRIX.md + test-matrix.csv (one row per flow)

Per flow it joins: flow-test.json (expected outputs per scenario, from the research pack), the case folders
(SCENARIO.txt: which real masked messages were used), the surefire XML reports (display name "route <case>" /
"body <case>" per message), GATES.json (K1-K8) and MUTATION.json (route mutations the tests caught). Rows:
  P<n>  one per scenario seen in the logs: messages in the export, cases tested, expected outputs, passed/failed
  S<n>  one per scenario covered only by synthetic messages (flows that log no payload)
  E<n>  every other test method (error handler, retries, headers, invalid payload)
  K<n>  the gates;  M<n>  the mutations
No payload values are read or written: only folder names, scenario keys and counts."""
import argparse
import csv
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path


def results(mod: Path) -> dict:
    """testcase display name -> pass / fail / skip."""
    out = {}
    for rep in (mod / "target/surefire-reports").glob("TEST-*.xml"):
        for tc in ET.parse(rep).getroot().iter("testcase"):
            st = "fail" if tc.find("failure") is not None or tc.find("error") is not None else \
                 "skip" if tc.find("skipped") is not None else "pass"
            out[f"{tc.get('classname', '').split('.')[-1]}::{tc.get('name', '')}"] = st
    return out


def load(p: Path, default):
    return json.loads(p.read_text(encoding="utf-8")) if p.is_file() else default


def flow_matrix(mod: Path) -> tuple[list[dict], dict]:
    cfg = load(mod / "src/test/resources/flow-test.json", {})
    meta = load(mod / ".scaffold.json", {})
    res = results(mod)
    parity = mod / "src/test/resources/parity"
    counts = {}
    sc_json = Path(meta.get("task1", "")) / "traces/scenarios.json" if meta.get("task1") else None
    if sc_json and sc_json.is_file():
        counts = {s["scenario"]: s["count"] for s in json.loads(sc_json.read_text(encoding="utf-8"))}
    by_scenario = defaultdict(list)
    for sc in sorted(parity.glob("*/*/SCENARIO.txt")):
        key = sc.read_text(encoding="utf-8").strip()
        by_scenario[key] += [c for c in sorted(sc.parent.iterdir()) if (c / "input.payload").is_file()]

    def expected(key: str) -> str:
        if "|error|" in key:
            return "out-" + cfg.get("error_output", "?")
        vals = dict(p.split("=", 1) for p in key.split("|") if "=" in p)
        for m in cfg.get("scenario_mapping", []):
            ok = True
            for p in m["scenario"].split("|"):
                if "!=" in p:
                    k, v = p.split("!=", 1)
                    ok &= vals.get(k) != v
                elif "=" in p:
                    k, v = p.split("=", 1)
                    ok &= vals.get(k) == v
            if ok and m["scenario"]:
                return ", ".join(o if o == "reply" else "out-" + o for o in m["outputs"]) or "nothing sent"
        return "NOT MAPPED"

    rows, used = [], set()
    for i, (key, cases) in enumerate(sorted(by_scenario.items(), key=lambda kv: -counts.get(kv[0], len(kv[1]))), 1):
        rel = [c.relative_to(parity).as_posix() for c in cases]
        st = [res.get(f"FlowParityTest::reachesTheSameOutputAsOsb(String, Path) route {r}") for r in rel]
        body = [res.get(f"FlowParityTest::bodyEqualsOriginalXQueryResult(String, Path) body {r}") for r in rel]
        used.update(f"FlowParityTest::reachesTheSameOutputAsOsb(String, Path) route {r}" for r in rel)
        used.update(f"FlowParityTest::bodyEqualsOriginalXQueryResult(String, Path) body {r}" for r in rel)
        scen = "|".join(p for p in key.split("|")[2:])
        synthetic = all("-synthetic/" in r for r in rel)
        rows.append({"id": f"{'S' if synthetic else 'P'}{i:02d}",
                     "kind": "synthetic (fake values, from the schema)" if synthetic else "parity (real masked messages)",
                     "what": scen or key,
                     "inputs": f"{len(cases)} synthetic" if synthetic else f"{len(cases)} of {counts.get(key, '?')} in export",
                     "expected": expected(key),
                     "passed": st.count("pass"), "failed": st.count("fail"), "not_run": st.count(None),
                     "body_check": "pass" if body and all(b == "pass" for b in body) else
                                   ("pending (no golden)" if body and all(b == "skip" for b in body) else
                                    ("FAIL" if "fail" in body else "-")),
                     "result": "PASS" if st and all(s == "pass" for s in st) else ("FAIL" if "fail" in st else "NOT RUN")})
    other = sorted(k for k in res if k not in used)
    for j, k in enumerate(other, 1):
        cls, name = k.split("::", 1)
        rows.append({"id": f"E{j:02d}", "kind": "error/behaviour" if cls != "FlowParityTest" else "parity (generic)",
                     "what": re.sub(r"(?<!^)(?=[A-Z])", " ", name.split("(")[0]).lower(), "inputs": "fake values",
                     "expected": "-", "passed": int(res[k] == "pass"), "failed": int(res[k] == "fail"),
                     "not_run": 0, "body_check": "-", "result": {"pass": "PASS", "fail": "FAIL", "skip": "SKIP"}[res[k]]})
    for k, g in load(mod / "GATES.json", {}).get("gates", {}).items():
        rows.append({"id": k.split("_")[0], "kind": "gate", "what": k.split("_", 1)[1].replace("_", " "), "inputs": "-",
                     "expected": "ok", "passed": int(g["ok"]), "failed": int(not g["ok"]), "not_run": 0, "body_check": "-",
                     "result": "PASS" if g["ok"] else "FAIL"})
    mut = load(mod / "MUTATION.json", {})
    for n, m in enumerate(mut.get("mutations", []), 1):
        rows.append({"id": f"M{n:02d}", "kind": "mutation (route broken on purpose)", "what": m["what"], "inputs": "all tests",
                     "expected": "tests fail", "passed": int(m["killed"]), "failed": int(not m["killed"]), "not_run": 0,
                     "body_check": "-", "result": "CAUGHT" if m["killed"] else "MISSED"})
    p = [r for r in rows if r["id"][0] in "PS" and r["kind"] != "gate"]
    summary = {"flow": f"{meta.get('project', '?')}/{meta.get('proxy', mod.name)}",
               "scenarios": len(p), "scenarios_pass": sum(r["result"] == "PASS" for r in p),
               "unmapped": sum(r["expected"] == "NOT MAPPED" for r in p),
               "cases": sum(r["passed"] + r["failed"] + r["not_run"] for r in p),
               "cases_failed": sum(r["failed"] for r in p),
               "error_tests": sum(r["kind"] == "error/behaviour" for r in rows),
               "error_tests_failed": sum(r["kind"] == "error/behaviour" and r["result"] == "FAIL" for r in rows),
               "gates": load(mod / "GATES.json", {}).get("result", "not run"),
               "mutations": f"{sum(m['killed'] for m in mut.get('mutations', []))}/{len(mut.get('mutations', []))}" if mut else "not run",
               "reports": "yes" if res else "no (run mvn test)"}
    return rows, summary


COLS = ["id", "kind", "what", "inputs", "expected", "passed", "failed", "not_run", "body_check", "result"]


def write(out_md: Path, title: str, intro: list[str], cols: list[str], rows: list[dict]) -> None:
    with out_md.with_name("test-matrix.csv").open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    md = [f"# {title}", ""] + intro + ["", "| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    md += ["| " + " | ".join(str(r.get(c, "")).replace("|", " / ") for c in cols) + " |" for r in rows]
    out_md.write_text("\n".join(md) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path, nargs="?")
    ap.add_argument("--domain", type=Path, help="modules root: every */*/.scaffold.json below it")
    ap.add_argument("-o", "--out", type=Path)
    a = ap.parse_args()
    if a.domain:
        mods = sorted(p.parent for p in a.domain.glob("*/*/.scaffold.json"))
        sums = []
        for m in mods:
            rows, s = flow_matrix(m)
            write(m / "TEST_MATRIX.md", f"Test matrix: {s['flow']}", [], COLS, rows)
            sums.append(s)
        out = a.out or a.domain
        out.mkdir(parents=True, exist_ok=True)
        cols = list(sums[0]) if sums else ["flow"]
        green = sum(s["gates"] == "PASS" and s["cases_failed"] == 0 for s in sums)
        write(out / "TEST_MATRIX.md", "Test matrix: domain", [
            f"{len(sums)} flows, {green} fully green (gates PASS, no failed case). Per flow: modules/<project>/<proxy>/TEST_MATRIX.md.",
            "scenarios = scenarios seen in the Splunk logs; cases = real masked messages run through the Camel route; "
            "error_tests = error handler / retry / header tests; mutations = route defects inserted on purpose that the tests caught."],
              cols, sums)
        print(json.dumps({"flows": len(sums), "green": green, "out": str(out / "TEST_MATRIX.md")}))
        return 0
    if not a.module:
        ap.error("module or --domain required")
    rows, s = flow_matrix(a.module)
    write(a.module / "TEST_MATRIX.md", f"Test matrix: {s['flow']}", [
        f"Scenarios {s['scenarios_pass']}/{s['scenarios']} pass, {s['cases']} real masked messages "
        f"({s['cases_failed']} failed), error tests {s['error_tests']} ({s['error_tests_failed']} failed), "
        f"gates {s['gates']}, mutations caught {s['mutations']}.",
        "P = real messages from Splunk, expected outputs from the research pack (OSB source). E = error handler and "
        "behaviour tests. K = gates. M = the route broken on purpose: each must make tests fail."], COLS, rows)
    print(json.dumps(s))
    return 0 if s["cases_failed"] == 0 and s["error_tests_failed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_TEST_MATRIX_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/references/yaml-patterns.md")"
cat > '.pi/skills/osb-camelk-route/references/yaml-patterns.md' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_REFERENCES_YAML_PATTERNS_MD'
# OSB pipeline → Camel K YAML DSL (Camel 4.18), patterns proven on the pilot

All of these ran green in `pilot/sample-adjustment` (Camel 4.18.4, `camel-test-main-junit5`). Anything else: check
the Camel 4.18 documentation of the component or EIP before writing it.

| OSB | Camel K YAML |
|---|---|
| `assign $uuId := header traceId or fn-bea:uuid()` | `- setHeader: {name: traceId, simple: "${header.traceId} ?: ${uuid(random)}"}` (`uuid(random)` = java UUID, 36 chars like fn-bea:uuid) |
| Log action | `- log: {loggingLevel: INFO, logName: oracle.osb.logging.pipeline, message: "<same literal text> ${header.x} ::${body}"}`; keep the position (OSB logs before nXSD) |
| nXSD JSON→XML used only for conditions | helper bean `OsbJson.annotate`: lenient parse (raw control characters, text after the JSON), sets condition fields as headers, **does not change the body** |
| `ifThenElse` with one case (no else) | `- choice: {id: branch-<x>, when: [{id: branch-<x>-<path>, simple: "${header.f} == 'true'", steps: [...]}]}`; no `otherwise` = nothing happens, like OSB |
| Two independent `ifThenElse` in one stage | two `choice` blocks one after the other (both can fire) |
| XPath `//*:f/text()='true'` | header from bean with path `//f` (first field of that name at any depth) or `a.b.f`; compare as text: JSON `true` and `"true"` both give `true` |
| Route/publish to a JMS business service | `- to: {id: out-<bs>, uri: "{{out.<bs>}}"}`; property `out.<bs>=amqp:queue:<name>` |
| Business service retry-count N, interval S | send through `direct:send-<bs>` in its own route with `routeConfigurationId` → `routeConfiguration` + `errorHandler.defaultErrorHandler.redeliveryPolicy {maximumRedeliveries: "{{retry.<bs>.count:N}}", redeliveryDelay: "{{retry.<bs>.delay:S000}}"}`; after the last retry the exception returns to the caller's `doCatch` |
| Pipeline error handler → error queue with headers | `doTry` around the flow, `doCatch: [{exception: [java.lang.Exception], steps: [log, setHeader errorCode/errorMessage/debugInfo, removeHeaders of internal headers, to out-<error-bs>]}]`; inbound headers (resource, eventType, traceId) travel with the message |
| Error queue gets `$requestDoc` (original body) | keep the body unchanged everywhere before the catch (the bean never replaces it) |
| `replace` with stored XQuery | `- to: "xquery:osb/<project>/<file>.xqy"` (camel-saxon), parameters as headers; fn-bea functions via the shim in skill osb-to-camel |
| XSLT | `- to: "xslt-saxon:osb/<project>/<file>.xsl"` |
| Durable topic subscription + selector | not in the route: subscription queue `<address>::<subscription>` with the selector as broker filter (Artemis config); `flow.input=amqp:queue:<address>::<subscription>`; selector tests are L2 |

Tests: `@CamelMainTest(properties = {"flow.input=direct:in", "out.x=mock:out-x", "retry.x.delay=0", ...})`,
`@Produce("direct:in") ProducerTemplate in`, mocks by `in.getCamelContext().getEndpoint("mock:out-x", MockEndpoint.class)`,
failures by `mock.whenAnyExchangeReceived(e -> { throw new IOException("down"); })`, retries by `getReceivedCounter()`.
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_REFERENCES_YAML_PATTERNS_MD
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/assets/templates/FlowParityTest.java.tpl")"
cat > '.pi/skills/osb-camelk-route/assets/templates/FlowParityTest.java.tpl' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_FLOWPARITYTEST_JAVA_TPL'
package @@PACKAGE@@;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.camel.CamelContext;
import org.apache.camel.Exchange;
import org.apache.camel.ExchangePattern;
import org.apache.camel.Message;
import org.apache.camel.Produce;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.test.main.junit5.CamelMainTest;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.w3c.dom.Document;
import org.w3c.dom.Node;

import javax.xml.parsers.DocumentBuilderFactory;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * GENERATED by osb-camelk-route from research/@@PROJECT@@/@@PROXY@@/research.json. Do not edit: check_camelk.py
 * compares this file with its scaffold hash. Flow-specific tests (errors, transforms) go in other test classes.
 *
 * L1 test of the YAML route with Camel mock endpoints (Maven only, no broker, no cluster). Inputs are the real masked
 * messages from task 1 (src/test/resources/parity/**, copied on the VDI, never committed). For each case:
 *   - the scenario (SCENARIO.txt) is looked up in scenario_mapping (research Q5) -> the outputs it must reach;
 *   - no other output receives anything; the correlation header is carried through;
 *   - if expected-output.json/.xml exists, the body must equal it: the body OSB itself logged on its way out (task 1),
 *     or the original XQuery run on the input (golden_runner). XML is compared by namespace, not by prefix.
 * Backends are mock endpoints answering with src/test/resources/stubs/<backend>.* (shape from research Q8).
 * Cases come from Splunk (parity/<flow>/) or, where the flow logs no payload, are synthetic (parity/<flow>-synthetic/,
 * fake values from the message schema, written by the tester before the route and frozen like this file).
 */
@CamelMainTest(properties = {@@TEST_PROPERTIES@@})
class FlowParityTest {

    static final Path PARITY = Path.of("src/test/resources/parity");
    static final Path STUBS = Path.of("src/test/resources/stubs");
    static final ObjectMapper JSON = new ObjectMapper();
    static final JsonNode CFG = load();
    static final String REPLY = "reply";

    @Produce("@@INPUT@@")
    ProducerTemplate in;

    static JsonNode load() {
        try {
            return JSON.readTree(Path.of("src/test/resources/flow-test.json").toFile());
        } catch (Exception e) {
            throw new IllegalStateException("src/test/resources/flow-test.json missing or invalid", e);
        }
    }

    CamelContext ctx() {
        return in.getCamelContext();
    }

    MockEndpoint mock(String uri) {
        return ctx().getEndpoint(uri, MockEndpoint.class);
    }

    @BeforeEach
    void stubBackends() throws Exception {
        for (var it = CFG.path("backends").fields(); it.hasNext(); ) {
            var b = it.next();
            Path stub = null;
            for (String ext : new String[] {".json", ".xml", ".txt"}) {
                Path p = STUBS.resolve(b.getKey() + ext);
                if (Files.exists(p)) {
                    stub = p;
                }
            }
            if (stub != null) {
                String body = Files.readString(stub);
                mock(b.getValue().path("mock").asText()).whenAnyExchangeReceived(e -> e.getMessage().setBody(body));
            }
        }
    }

    static Stream<Arguments> cases() throws Exception {
        if (!Files.isDirectory(PARITY)) {
            return Stream.empty();
        }
        try (Stream<Path> s = Files.walk(PARITY)) {
            return s.filter(p -> p.getFileName().toString().equals("input.payload")).map(Path::getParent).sorted()
                .map(c -> Arguments.of(PARITY.relativize(c).toString(), c)).toList().stream();
        }
    }

    @Test
    void caseFoldersArePresent() throws Exception {
        assertFalse(cases().toList().isEmpty(), "no test cases: copy task1/fixtures/parity/* into " + PARITY);
    }

    /** Outputs this case must reach: error output for error cases, else the first scenario_mapping row whose key
     *  matches the case's SCENARIO.txt (k=v equal, k!=v different or missing). Empty list = consumed, nothing sent. */
    static List<String> expectedOutputs(Path c, JsonNode expected) throws Exception {
        if (!"success".equals(expected.path("outcome").asText())) {
            String err = CFG.path("error_output").asText("");
            assertFalse(err.isEmpty(), "case expects an error but research.json names no error output");
            return List.of(err);
        }
        Path sc = c.getParent().resolve("SCENARIO.txt");
        Map<String, String> values = new HashMap<>();
        for (String part : (Files.exists(sc) ? Files.readString(sc).strip() : "").split("\\|")) {
            int i = part.indexOf('=');
            if (i > 0) {
                values.put(part.substring(0, i), part.substring(i + 1));
            }
        }
        for (JsonNode m : CFG.path("scenario_mapping")) {
            if (matches(m.path("scenario").asText(), values)) {
                List<String> outs = new ArrayList<>();
                m.path("outputs").forEach(o -> outs.add(o.asText()));
                return outs;
            }
        }
        return fail("scenario not mapped in research.json scenario_mapping: " + values);
    }

    static boolean matches(String key, Map<String, String> values) {
        if (key.isBlank()) {
            return false;
        }
        for (String p : key.split("\\|")) {
            int ne = p.indexOf("!=");
            int eq = p.indexOf('=');
            if (ne > 0 && p.substring(ne + 2).equals(values.get(p.substring(0, ne)))) {
                return false;
            }
            if (ne < 0 && eq > 0 && !p.substring(eq + 1).equals(values.get(p.substring(0, eq)))) {
                return false;
            }
        }
        return true;
    }

    /** Sends the case (request/reply, so request-response flows return their reply); every output in targets
     *  receives exactly one message, every other output none. Output "reply" = the answer to the caller. */
    List<Message> send(Path c, List<String> targets) throws Exception {
        for (var it = CFG.path("outputs").fields(); it.hasNext(); ) {
            var o = it.next();
            if (!REPLY.equals(o.getKey())) {
                mock(o.getValue().asText()).expectedMessageCount(targets.contains(o.getKey()) ? 1 : 0);
            }
        }
        @SuppressWarnings("unchecked")
        Map<String, Object> headers = JSON.readValue(c.resolve("headers.json").toFile(), Map.class);
        String body = Files.readString(c.resolve("input.payload"));
        Exchange ex = in.send(e -> {
            e.setPattern(ExchangePattern.InOut);
            e.getMessage().setBody(body);
            e.getMessage().setHeaders(new HashMap<>(headers));
        });
        MockEndpoint.assertIsSatisfied(ctx());
        List<Message> out = new ArrayList<>();
        for (String t : targets) {
            if (REPLY.equals(t)) {
                assertNull(ex.getException(), "the caller must get a reply, not an exception");
                out.add(ex.getMessage());
                continue;
            }
            String uri = CFG.path("outputs").path(t).asText("");
            assertFalse(uri.isEmpty(), "scenario_mapping names output '" + t + "' that is not in outputs");
            out.add(mock(uri).getExchanges().get(0).getMessage());
        }
        return out;
    }

    @ParameterizedTest(name = "route {0}")
    @MethodSource("cases")
    void reachesTheSameOutputAsOsb(String name, Path c) throws Exception {
        JsonNode expected = JSON.readTree(c.resolve("expected.json").toFile());
        String corr = CFG.path("correlation_header").asText("traceId");
        try {
            for (Message out : send(c, expectedOutputs(c, expected))) {
                assertEquals(expected.path("correlation").asText(), out.getHeader(corr, String.class), corr + " must be carried through");
            }
        } catch (AssertionError e) {
            throw new AssertionError("case " + name + ": " + e.getMessage(), e);   // surefire reports show only [n]
        }
    }

    @ParameterizedTest(name = "body {0}")
    @MethodSource("cases")
    void bodyEqualsOriginalXQueryResult(String name, Path c) throws Exception {
        Path json = c.resolve("expected-output.json");
        Path xml = c.resolve("expected-output.xml");
        Assumptions.assumeTrue(Files.exists(json) || Files.exists(xml), "expected output pending (golden_runner on the VDI)");
        JsonNode expected = JSON.readTree(c.resolve("expected.json").toFile());
        List<String> targets = expectedOutputs(c, expected);
        List<Message> outs = send(c, targets);
        assertFalse(outs.isEmpty(), "golden output exists but the scenario maps to no output");
        // the body that is compared: the reply to the caller if the flow has one, else the first queue output
        String body = outs.get(targets.contains(REPLY) ? targets.indexOf(REPLY) : 0).getBody(String.class);
        if (Files.exists(json)) {
            assertEquals(JSON.readTree(json.toFile()), JSON.readTree(body));
        } else {
            assertTrue(xmlEqual(Files.readString(xml), body), "body differs from the OSB result (logged by OSB or the original XQuery)");
        }
    }

    @Test
    void unreadablePayloadGoesToTheErrorOutput() throws Exception {
        String err = CFG.path("error_output").asText("");
        Assumptions.assumeTrue("json".equals(CFG.path("payload_format").asText()) && !err.isEmpty(), "not a JSON flow or no error output");
        for (var it = CFG.path("outputs").fields(); it.hasNext(); ) {
            var o = it.next();
            if (!REPLY.equals(o.getKey())) {
                mock(o.getValue().asText()).expectedMessageCount(o.getKey().equals(err) ? 1 : 0);
            }
        }
        String corr = CFG.path("correlation_header").asText("traceId");
        in.sendBodyAndHeaders("not json at all", Map.of(corr, "t-invalid"));
        MockEndpoint.assertIsSatisfied(ctx());
        Message m = mock(CFG.path("outputs").path(err).asText()).getExchanges().get(0).getMessage();
        assertEquals("t-invalid", m.getHeader(corr), corr + " must reach the error output");
    }

    static boolean xmlEqual(String a, String b) throws Exception {
        var f = DocumentBuilderFactory.newInstance();
        f.setNamespaceAware(true);
        f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        Document da = f.newDocumentBuilder().parse(new ByteArrayInputStream(a.getBytes(StandardCharsets.UTF_8)));
        Document db = f.newDocumentBuilder().parse(new ByteArrayInputStream(b.getBytes(StandardCharsets.UTF_8)));
        strip(da);
        strip(db);
        da.normalizeDocument();
        db.normalizeDocument();
        return sameXml(da.getDocumentElement(), db.getDocumentElement());
    }

    /** Same elements (namespace + local name, prefixes ignored), same attributes, same text, same order. */
    static boolean sameXml(Node a, Node b) {
        if (a.getNodeType() != b.getNodeType()) {
            return false;
        }
        if (a.getNodeType() == Node.TEXT_NODE || a.getNodeType() == Node.CDATA_SECTION_NODE) {
            return a.getNodeValue().strip().equals(b.getNodeValue().strip());
        }
        if (!java.util.Objects.equals(a.getNamespaceURI(), b.getNamespaceURI())
            || !java.util.Objects.equals(a.getLocalName(), b.getLocalName())) {
            return false;
        }
        var aa = attrs(a);
        if (!aa.equals(attrs(b))) {
            return false;
        }
        var ca = a.getChildNodes();
        var cb = b.getChildNodes();
        if (ca.getLength() != cb.getLength()) {
            return false;
        }
        for (int i = 0; i < ca.getLength(); i++) {
            if (!sameXml(ca.item(i), cb.item(i))) {
                return false;
            }
        }
        return true;
    }

    static Map<String, String> attrs(Node n) {
        Map<String, String> m = new HashMap<>();
        var at = n.getAttributes();
        for (int i = 0; at != null && i < at.getLength(); i++) {
            Node x = at.item(i);
            if (!"http://www.w3.org/2000/xmlns/".equals(x.getNamespaceURI())) {      // namespace declarations: prefixes only
                m.put(x.getNamespaceURI() + "|" + x.getLocalName(), x.getNodeValue());
            }
        }
        return m;
    }

    static void strip(Node n) {
        for (Node c = n.getFirstChild(); c != null; ) {
            Node next = c.getNextSibling();
            if (c.getNodeType() == Node.TEXT_NODE && c.getTextContent().isBlank() || c.getNodeType() == Node.COMMENT_NODE) {
                n.removeChild(c);
            } else {
                strip(c);
            }
            c = next;
        }
    }
}
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_FLOWPARITYTEST_JAVA_TPL
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/assets/templates/OsbJson.java.tpl")"
cat > '.pi/skills/osb-camelk-route/assets/templates/OsbJson.java.tpl' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_OSBJSON_JAVA_TPL'
package @@PACKAGE@@;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.json.JsonReadFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.json.JsonMapper;
import org.apache.camel.Exchange;

/**
 * Helper bean for the YAML route: reads the payload the way OSB accepts it. OSB logs showed raw control
 * characters inside strings and text after the closing brace; Jackson rejects both by default, so this bean is
 * lenient on exactly those two points and nothing else. It also lifts the scenario fields into headers.
 */
public final class OsbJson {

    static final ObjectMapper LENIENT = JsonMapper.builder()
        .enable(JsonReadFeature.ALLOW_UNESCAPED_CONTROL_CHARS)
        .disable(com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
        .build();

    private OsbJson() {
    }

    /** Parse leniently (control characters, trailing text ignored); fails on anything that is not JSON. */
    public static JsonNode parse(String body) {
        if (body == null || body.isBlank()) {
            throw new IllegalArgumentException("empty payload");
        }
        try (JsonParser p = LENIENT.createParser(body.strip())) {
            JsonNode node = LENIENT.readTree(p);
            if (node == null || !node.isObject()) {
                throw new IllegalArgumentException("payload is not a JSON object");
            }
            return node;
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
            // original message only: Jackson's full message quotes the payload, which must not reach error headers/logs
            throw new IllegalArgumentException("payload is not JSON: " + e.getOriginalMessage());
        } catch (java.io.IOException e) {
            throw new IllegalArgumentException("payload could not be read");
        }
    }

    /** Fields lifted into headers so branch conditions can use ${header.x}; set by the scaffold from research
     *  scenario_dims. "a.b.c" = that path; "//name" = first field with that name at any depth (OSB //*:name). */
    static final String[][] HEADERS = {@@HEADER_PATHS@@};

    /** Route step: checks the payload parses like OSB accepts it and sets the scenario headers. The body is NOT
     *  changed: OSB forwards the original text ($requestDoc), so the outputs must carry it byte for byte. */
    public static void annotate(Exchange exchange) throws Exception {
        JsonNode root = parse(exchange.getMessage().getBody(String.class));
        for (String[] h : HEADERS) {
            JsonNode n;
            if (h[1].startsWith("//")) {
                n = root.findValue(h[1].substring(2));
            } else {
                n = root;
                for (String part : h[1].split("\\.")) {
                    n = n.path(part);
                }
            }
            exchange.getMessage().setHeader(h[0], n == null || n.isMissingNode() || n.isNull() ? null : n.asText());
        }
    }
}
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_OSBJSON_JAVA_TPL
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/assets/templates/pom.xml")"
cat > '.pi/skills/osb-camelk-route/assets/templates/pom.xml' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_POM_XML'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Test module for the Camel K flow @@PROJECT@@ / @@PROXY@@ (generated by osb-camelk-route).
     Camel K builds the integration from the YAML route itself; this pom exists to TEST that route (L1) and to
     package the helper beans the route calls. Camel 4.18.4 = the Camel inside Camel Quarkus 3.33.3, the runtime
     pinned on the cluster with camel.runtime-version=3.33.3 (decision 2026-10-14: Camel 4.18). -->
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>@@GROUP@@</groupId>
  <artifactId>@@ARTIFACT@@</artifactId>
  <version>0.1.0-SNAPSHOT</version>

  <properties>
    <camel.version>4.18.4</camel.version>
    <junit.version>5.12.2</junit.version>
    <maven.compiler.release>21</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>

  <dependencyManagement>
    <dependencies>
      <dependency>
        <groupId>org.apache.camel</groupId>
        <artifactId>camel-bom</artifactId>
        <version>${camel.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
      <dependency>
        <groupId>org.junit</groupId>
        <artifactId>junit-bom</artifactId>
        <version>${junit.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
    </dependencies>
  </dependencyManagement>

  <dependencies>
    <!-- what the route uses (on Camel K these come from the route's own dependencies) -->
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-main</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-yaml-dsl</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-direct</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-log</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-bean</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-jackson</artifactId></dependency>
    <!-- @@EXTRA_DEPS@@ -->

    <!-- tests -->
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-test-main-junit5</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-mock</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter-params</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.slf4j</groupId><artifactId>slf4j-simple</artifactId><version>2.0.17</version><scope>test</scope></dependency>
  </dependencies>

  <build>
    <plugins>
      <!-- pinned: older Maven installs default to compiler 3.1, which ignores maven.compiler.release and compiles as Java 1.5 -->
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>3.13.0</version>
        <configuration><release>21</release></configuration>
      </plugin>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-resources-plugin</artifactId>
        <version>3.3.1</version>
      </plugin>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-surefire-plugin</artifactId>
        <version>3.5.3</version>
        <!-- display names in the XML reports ("route <case folder>"): test_matrix.py maps every result to its case -->
        <configuration>
          <statelessTestsetReporter implementation="org.apache.maven.plugin.surefire.extensions.junit5.JUnit5Xml30StatelessReporter">
            <usePhrasedTestCaseMethodName>true</usePhrasedTestCaseMethodName>
          </statelessTestsetReporter>
        </configuration>
      </plugin>
    </plugins>
  </build>
</project>
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_POM_XML
mkdir -p "$(dirname "agents/implementer-camelk.md")"
cat > 'agents/implementer-camelk.md' <<'KIT_EOF_AGENTS_IMPLEMENTER_CAMELK_MD'
# Role: implementer (Camel K YAML route from an approved card)

You implement ONE flow in `modules/<project>/<proxy>/` with skill `osb-camelk-route`, from its approved FLOW_CARD.md and
research pack. You never change the OSB source, the research pack, FlowParityTest.java, flow-test.json or any test case folder (real or synthetic), and you never
disable or weaken a test. You may copy original XQuery/XSLT/XSD files from the OSB source into the module.
Behaviour that is not on the card is not implemented: record it as an open question in MIGRATION_NOTES.md.
Finish only when check_camelk.py prints PASS, or stop and report which gate fails and why it cannot pass.
KIT_EOF_AGENTS_IMPLEMENTER_CAMELK_MD
mkdir -p "$(dirname "agents/tester-camelk.md")"
cat > 'agents/tester-camelk.md' <<'KIT_EOF_AGENTS_TESTER_CAMELK_MD'
# Role: tester (synthetic test messages for scenarios Splunk cannot supply)

You write test INPUTS for ONE flow, before any route exists, so the implementer cannot shape them to its code.
For every scenario_mapping row in `src/test/resources/flow-test.json` that has no case yet, write one case folder under
`src/test/resources/parity/<project>-<proxy>-synthetic/<row-slug>/<case-id>/`, i.e. THREE folder levels below parity:
```
parity/sample-transform-prj-sample-transform-synthetic/all/SCENARIO.txt
parity/sample-transform-prj-sample-transform-synthetic/all/case1/input.payload   (+ headers.json, expected.json)
```
(scenario `*` = every message: SCENARIO.txt is then `<project>/<proxy>|success` with no keys)
- `input.payload`: a message the OSB proxy accepts, built from the message schema in the OSB source (XSD, nXSD, WSDL,
  JSON sample in the export), with FAKE values only (masked_..., 1000000001 ...). The fields the row's key names must
  have exactly the row's values (k=v), or a different value / be absent (k!=v).
- `headers.json`: transport headers the flow reads (resource, eventType ...) + a traceId.
- `expected.json`: {"outcome": "success", "destination": "see mapping", "correlation": "<the traceId>"}.
- `../SCENARIO.txt`: `<project>/<proxy>|success|k=v|...` with every key of the row.
You never write or change the route, the beans, FlowParityTest.java, flow-test.json, or real (Splunk) case folders.
If the schema is missing from the export, write nothing for that row and report it.
KIT_EOF_AGENTS_TESTER_CAMELK_MD
mkdir -p "$(dirname "pi/run_camelk.sh")"
cat > 'pi/run_camelk.sh' <<'KIT_EOF_PI_RUN_CAMELK_SH'
#!/usr/bin/env bash
# Research pack -> Camel K module for ONE proxy: functional tests (pi/run_tests.sh) -> approval gate -> implement (pi)
# -> mvn test -> gates.
#
# Usage: pi/run_camelk.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]
#   research-dir   research/<project>/<proxy> with research.json (+ facts.json), check PASS
#   module-dir     modules/<project>/<proxy> (created on the first run)
#   task1-dir      its fixtures/parity/* are copied into the module as test inputs (masked; .gitignore keeps them out of Git)
# Env: OSB_SRC (OSB project folder: the implementer may copy original XQuery/XSLT/XSD into the module), MVN_ARGS
#      (e.g. "-s ~/.m2/client-settings.xml"), OSB_PI_MODEL, PI_THINKING (default high), KIT, PYTHON
# Exit: 0 gates PASS, 3 card not approved yet (expected after the first run), 1 anything else.
set -euo pipefail
[ -f "${OSB_KIT_ENV:-$HOME/.osb-kit.env}" ] && . "${OSB_KIT_ENV:-$HOME/.osb-kit.env}"   # local client settings, never in Git
RES=${1:?usage: run_camelk.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]}
MOD=${2:?module dir}
PRJ=${3:?osb project name}
TASK1=${4:-}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$KIT/pi/pi_call.sh"
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
skill_dir() { if [ -d "$KIT/skills/$1" ]; then echo "$KIT/skills/$1"; elif [ -d "$KIT/.pi/skills/$1" ]; then echo "$KIT/.pi/skills/$1"; fi; }
SK=$(skill_dir osb-camelk-route); [ -n "$SK" ] || { echo "skill osb-camelk-route not found under $KIT"; exit 1; }
[ -s "$RES/research.json" ] || { echo "missing $RES/research.json: run pi/run_research.sh first"; exit 1; }
if [ -f "$RES/SHARE_CHECK.json" ] && ! grep -q '"pass": true' "$RES/SHARE_CHECK.json"; then echo "research pack did not pass its check: $RES/SHARE_CHECK.json"; exit 1; fi

echo "== 1 functional tests: generated tests + mocks, synthetic inputs, frozen (pi/run_tests.sh)"
bash "$KIT/pi/run_tests.sh" "$RES" "$MOD" "$PRJ" ${TASK1:+"$TASK1"} || echo "some scenarios have no test case yet (gate K9 will fail)"

echo "== 2 approval"
if [ "${POC:-0}" = 1 ] && ! grep -qiE '^Status:[[:space:]]*approved' "$MOD/FLOW_CARD.md"; then
  # proof-of-concept run without a sign-off: build anyway, mark the card, gate K1 stays FAIL
  sed -i.bak 's/^Status:.*/Status: poc-run (NOT approved)/' "$MOD/FLOW_CARD.md" && rm -f "$MOD/FLOW_CARD.md.bak"
  echo "   POC=1: card not approved, built for the proof of concept only (gate K1 stays FAIL)"
elif ! grep -qiE '^Status:[[:space:]]*approved[[:space:]]*$' "$MOD/FLOW_CARD.md" || ! grep -qE '^Approver:[[:space:]]*[^[:space:]]' "$MOD/FLOW_CARD.md"; then
  echo "card not approved: review $MOD/FLOW_CARD.md against $RES/RESEARCH.md, set 'Status: approved' + Approver + Date, rerun"
  exit 3
fi

LOG="$MOD/.agent-logs"; mkdir -p "$LOG"
echo "== 3 implement (pi)"
PI=(pi --print --no-session --thinking "${PI_THINKING:-high}" --skill "$SK" --tools "read,bash,edit,write"
    --append-system-prompt "$KIT/agents/implementer-camelk.md")
[ -n "${OSB_PI_MODEL:-}" ] && PI+=(--model "$OSB_PI_MODEL")
pi_call "$LOG/implement.out" "$LOG/implement.err" "${PI[@]}" "Use skill osb-camelk-route. Module: $MOD. Approved card: $MOD/FLOW_CARD.md. Research: $RES/RESEARCH.md and $RES/research.json. ${OSB_SRC:+OSB source (read only): $OSB_SRC.} Do steps 3-6 of the skill: fill every TODO(flow-card) in the route, write FlowErrorTest (one test per error scope at least) and the backend stubs, run 'mvn -B ${MVN_ARGS:-} -f $MOD/pom.xml test' and '$PY $SK/scripts/check_camelk.py $MOD' until it prints PASS. Never edit FlowParityTest.java or flow-test.json. Write nothing outside $MOD." || true

echo "== 4 verify"
mvn -B -q ${MVN_ARGS:-} -f "$MOD/pom.xml" test > "$LOG/mvn.out" 2>&1 || true
grep -h "Tests run:" "$LOG/mvn.out" | tail -1 || true
"$PY" "$SK/scripts/check_camelk.py" "$MOD"
KIT_EOF_PI_RUN_CAMELK_SH
mkdir -p "$(dirname "pi/run_domain.sh")"
cat > 'pi/run_domain.sh' <<'KIT_EOF_PI_RUN_DOMAIN_SH'
#!/usr/bin/env bash
# One OSB application (domain) with many projects and proxies: run the per-flow steps for all of them, keep going when
# one flow fails, and keep a status table. Safe to rerun: finished steps are skipped.
#
# Usage: pi/run_domain.sh <osb-app-dir> <stage> [workspace]
#   osb-app-dir  e.g. /e/osb-application (the folder holding the *-prj projects)
# Short form with APP in .osb-kit.env: run_domain.sh <stage> [workspace]
# BATCH_NO=n (with BATCH_SIZE, default 10): the n-th slice of the project list, no names to type; 'batches' lists them.
#   stage        list      projects and proxies found (no agent) -> domain/projects.txt, domain/flows.txt
#                batches   how many batches of BATCH_SIZE projects, with the command for each
#                coverage  which proxies get real Splunk test messages and which synthetic ones (needs SPLUNK_COVERAGE =
#                          CSV of the Splunk "stats count by project, proxy, payload" table) -> domain/COVERAGE.md
#                research  research pack per proxy -> <ws>/research/<project>/<proxy>/   (skips packs that PASS)
#                task1     Splunk test cases for every researched proxy, split by the fields its branches use
#                          (research scenario_dims) -> <ws>/task1/flows/<project>-<proxy>/   (needs EXPORT, MASK_KEY)
#                tests     FUNCTIONAL TESTS per researched proxy (no route needed): generated tests + mocks, real Splunk
#                          cases, synthetic cases from the schema where Splunk has none (pi tester), frozen, catalogue
#                          -> <ws>/modules/<project>/<proxy>/src/test/** + TEST_MATRIX.md
#                scaffold  same module without the tester step
#                build     implement + test + gates for every proxy whose card is approved
#                matrix    mutation check (route broken on purpose) + test matrix per flow and for the domain
#                functional  the whole proof: research -> task1 -> tests -> build -> matrix -> report
#                          (build needs approved cards, or POC=1 for a proof-of-concept run: cards marked, K1 FAIL)
#                report    domain/FUNCTIONAL_TEST_REPORT.md: inputs, expected outputs, mocks, results, mutations per flow
#                auto      research -> task1 -> tests: the functional test pack for every flow, then stops
#                          (routes: approve the cards, then build and matrix)
#                status    only rewrite <ws>/domain/STATUS.md + status.csv
#   workspace    default: current folder
# PROJECTS matches whole project names: 'a-prj|b-.*' (regex, anchored).
# Env: PI_PAUSE (seconds between two flows in a pi stage, default 30: keeps under the model's rate limit),
#      PI_RETRIES / PI_BACKOFF (retries after a 429, see pi_call.sh),
#      PROJECTS (regex on project names, e.g. 'beneficiary|cancel-'), EXPORT (one Splunk CSV export with all flows of
#      the domain, raw or *.masked.csv), MASK_KEY, MVN_ARGS (e.g. "-s ~/.m2/settings.xml"), MUTATE=0 to skip mutations,
#      MASK_JSON_KEYS ('fieldA fieldB': extra JSON/XML fields to mask in task1, when the residue check finds one),
#      plus the env of run_research.sh / run_camelk.sh (OSB_PI_MODEL, ...).
set -uo pipefail
# local client settings, never in Git: $OSB_KIT_ENV, else ./.osb-kit.env, else ~/.osb-kit.env
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
STAGES='list|batches|coverage|research|task1|tests|scaffold|build|matrix|report|functional|auto|status'
if echo "${1:-}" | grep -Eqx "($STAGES)"; then         # short form: run_domain.sh <stage> [workspace], APP from the env file
  STAGE=$1; WS=${2:-${WS:-.}}; APP=${APP:?set APP in .osb-kit.env or use: run_domain.sh <osb-app-dir> <stage>}
else
  APP=${1:?usage: run_domain.sh [<osb-app-dir>] <stage> [workspace]   stages: $STAGES}
  STAGE=${2:?stage}
  WS=${3:-${WS:-.}}
fi
case "$APP" in *\\*|[A-Za-z]:*) command -v cygpath >/dev/null && APP=$(cygpath -u "$APP");; esac
[ -d "$APP" ] || { echo "OSB application folder not found: $APP (Git Bash: /e/folder, not E:\\folder)"; exit 2; }
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
FILTER=${PROJECTS:-.*}
mkdir -p "$WS/domain"
SK="$KIT/skills/osb-camelk-route/scripts"; [ -d "$SK" ] || SK="$KIT/.pi/skills/osb-camelk-route/scripts"
BATCH=$(for d in "$KIT/../../vdi-osb-migration/bin" "$KIT/bin"; do [ -f "$d/batch_task1.py" ] && echo "$d/batch_task1.py" && break; done)
t1dir() { local d="$WS/task1/flows/$(echo "$1-$2" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//;s/-$//' | tr 'A-Z' 'a-z' | cut -c1-80)"; [ -d "$d/fixtures/parity" ] && echo "$d"; }

projects() {   # project folders (sorted), after PROJECTS; BATCH_NO=n keeps the n-th slice of BATCH_SIZE (default 10)
  local all
  all=$(for prj in "$APP"/*/; do p=$(basename "$prj"); [ "${p#.}" != "$p" ] && continue
        echo "$p" | grep -Eqx "($FILTER)" && find "$prj" -type f \( -name '*.proxy' -o -name '*.ProxyService' \) | grep -q . && echo "$p"; done)
  if [ -n "${BATCH_NO:-}" ]; then
    echo "$all" | awk -v n="$BATCH_NO" -v s="${BATCH_SIZE:-10}" 'NR > (n-1)*s && NR <= n*s'
  else echo "$all"; fi
}

flows() {   # "<project> <proxy>" for every proxy file (12c .proxy, sbconfig .ProxyService) in the selected projects
  for p in $(projects); do
    prj="$APP/$p/"
    find "$prj" -type f \( -name '*.proxy' -o -name '*.ProxyService' \) | sort | while read -r f; do
      n=$(basename "$f"); echo "$p ${n%.*}"
    done
  done
}

status() {
  local csv="$WS/domain/status.csv" md="$WS/domain/STATUS.md"
  echo "project,proxy,research,open_questions,test_cases,card,gates,tests" > "$csv"
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; m="$WS/modules/$p/$x"
    rs=-; [ -f "$r/SHARE_CHECK.json" ] && { grep -q '"pass": true' "$r/SHARE_CHECK.json" && rs=PASS || rs=FAIL; }
    oq=-; [ -s "$r/research.json" ] && oq=$("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1], encoding='utf-8')).get('open_questions') or []))" "$r/research.json")
    tc=-; [ -d "$m/src/test/resources/parity" ] && tc=$(find "$m/src/test/resources/parity" -name input.payload | wc -l | tr -d ' ')
    cs=-; [ -f "$m/FLOW_CARD.md" ] && { grep -qiE '^Status:[[:space:]]*approved' "$m/FLOW_CARD.md" && cs=approved || cs=draft; }
    gs=-; ts=-; if [ -f "$m/GATES.json" ]; then grep -q '"result": "PASS"' "$m/GATES.json" && gs=PASS || gs=FAIL
      ts=$("$PY" -c "import json,sys; g=json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}); print(f\"{g.get('tests','-')}/{g.get('failures','-')}F/{g.get('skipped','-')}S\")" "$m/GATES.json"); fi
    echo "$p,$x,$rs,$oq,$tc,$cs,$gs,$ts" >> "$csv"
  done
  { echo "# Domain status: $(basename "$APP")"; echo; echo "Generated $(date '+%F %H:%M'). research = pack check, card = FLOW_CARD.md, gates = check_camelk.py, tests = run/failed/skipped."; echo
    echo "| Project | Proxy | Research | Open questions | Test cases | Card | Gates | Tests |"; echo "|---|---|---|---|---|---|---|---|"
    tail -n +2 "$csv" | awk -F, '{printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6,$7,$8}'
    echo; tail -n +2 "$csv" | awk -F, '{n++; if($3=="PASS")r++; if($5!="-")t++; if($6=="approved")c++; if($7=="PASS")g++} END{printf "%d proxies: %d researched, %d with Splunk test cases, %d cards approved, %d green\n",n,r,t,c,g}'
  } > "$md"
  tail -1 "$md"
}

task1_of() {   # task-1 folder of a proxy: domain batch first, then TASK1_ROOT/<proxy>/task1
  local t; t=$(t1dir "$1" "$2"); [ -z "$t" ] && [ -n "${TASK1_ROOT:-}" ] && [ -d "$TASK1_ROOT/$2/task1" ] && t="$TASK1_ROOT/$2/task1"; echo "$t"
}

do_research() {
  flows | while read -r p x; do
    out="$WS/research/$p/$x"
    if [ -f "$out/SHARE_CHECK.json" ] && grep -q '"pass": true' "$out/SHARE_CHECK.json"; then echo "skip $p/$x (PASS)"; continue; fi
    echo "=== research $p/$x"
    t1=$(task1_of "$p" "$x")
    (cd "$WS" && OUT="research/$p/$x" bash "$KIT/pi/run_research.sh" "$APP/$p" "$x" ${t1:+"$t1"}) < /dev/null || echo "FAILED research $p/$x (continuing)"
    sleep "${PI_PAUSE:-30}"
  done
}

do_task1() {   # one batch over the whole export; scenario fields per flow = what its branches decide on
  [ -n "${EXPORT:-}" ] && [ -f "$EXPORT" ] || { echo "task1 needs EXPORT=<Splunk CSV of the domain> (DOMAIN_RUN.md)"; return 2; }
  [ -n "$BATCH" ] || { echo "batch_task1.py not found (vdi-osb-migration/bin)"; return 2; }
  mkdir -p "$WS/task1"
  { echo "flow,domain,dims"
    flows | while read -r p x; do
      r="$WS/research/$p/$x/research.json"
      d=$([ -s "$r" ] && "$PY" -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')).get('scenario_dims') or []; print(';'.join(['hdr_resource'] + ['body:' + x.lstrip('/') for x in d]) if d else '')" "$r")
      echo "$p/$x,$(basename "$APP"),$d"
    done; } > "$WS/task1/flows.csv"
  case "$EXPORT" in *.masked.csv) am=--already-masked;; *) am=;; esac
  mk=(); for k in ${MASK_JSON_KEYS:-}; do mk+=(--mask-json-key "$k"); done      # extra fields to mask, space separated
  "$PY" "$BATCH" "$EXPORT" -o "$WS/task1" --flows "$WS/task1/flows.csv" $am "${mk[@]}" || {
    echo "some flows need a look: $WS/task1/SUMMARY.md"
    [ -f "$WS/task1/events.masked.csv.report.json" ] && "$PY" -c "import json,sys; r=json.load(open(sys.argv[1], encoding='utf-8'))['residue_check']; [print('   residue:', w) for w in r['where']]" "$WS/task1/events.masked.csv.report.json"
    echo "   fix: MASK_JSON_KEYS='<field> <field>' on the same line, then rerun task1 (arabic-script = Arabic text in a field not masked by name)"; }
}

do_scaffold() {
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; [ -s "$r/research.json" ] || continue
    t1=$(task1_of "$p" "$x")
    "$PY" "$SK/scaffold_camelk.py" "$r" -o "$WS/modules/$p/$x" --project "$p" ${t1:+--parity "$t1/fixtures/parity"} \
      || echo "FAILED scaffold $p/$x (continuing)"
  done
}

do_tests() {
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; [ -s "$r/research.json" ] || continue
    echo "=== tests $p/$x"
    t1=$(task1_of "$p" "$x")
    OSB_SRC="$APP/$p" bash "$KIT/pi/run_tests.sh" "$r" "$WS/modules/$p/$x" "$p" ${t1:+"$t1"} < /dev/null | grep -E "rate limit|^\{" || echo "INCOMPLETE tests $p/$x (continuing)"
    sleep "${PI_PAUSE:-30}"
  done
  "$PY" "$SK/test_matrix.py" --domain "$WS/modules" -o "$WS/domain" > /dev/null || true
}

do_build() {
  flows | while read -r p x; do
    m="$WS/modules/$p/$x"; [ -f "$m/FLOW_CARD.md" ] || continue
    grep -qiE '^Status:[[:space:]]*(approved|poc-run)' "$m/FLOW_CARD.md" || [ "${POC:-0}" = 1 ] || { echo "skip $p/$x (card not approved; POC=1 for a proof-of-concept build)"; continue; }
    if [ -f "$m/GATES.json" ] && "$PY" -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}).get('ok') else 1)" "$m/GATES.json"; then echo "skip $p/$x (tests green)"; continue; fi
    echo "=== build $p/$x"
    t1=$(task1_of "$p" "$x")
    OSB_SRC="$APP/$p" bash "$KIT/pi/run_camelk.sh" "$WS/research/$p/$x" "$m" "$p" ${t1:+"$t1"} < /dev/null || echo "NOT GREEN $p/$x (continuing)"
    sleep "${PI_PAUSE:-30}"
  done
}

do_matrix() {   # mutation check on every green module (MUTATE=0 skips it), then the matrices
  flows | while read -r p x; do
    m="$WS/modules/$p/$x"; [ -f "$m/.scaffold.json" ] || continue
    if [ "${MUTATE:-1}" = 1 ] && [ -f "$m/GATES.json" ] && "$PY" -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}).get('ok') else 1)" "$m/GATES.json" && [ ! -f "$m/MUTATION.json" ]; then
      echo "=== mutations $p/$x"; "$PY" "$SK/mutate_route.py" "$m" --mvn "mvn -B -q ${MVN_ARGS:-}" || echo "MUTATION SURVIVED $p/$x: tests too weak (see $m/MUTATION.json)"
    fi
  done
  "$PY" "$SK/test_matrix.py" --domain "$WS/modules" -o "$WS/domain"
}

# pi runs are slow and cost tokens: show the selection, and require ALL=1 for more than 10 flows
case "$STAGE" in research|tests|build|auto|functional)
  n=$(flows | wc -l | tr -d ' ')
  echo "selected: $n proxies (PROJECTS='${PROJECTS:-<all>}')"
  if [ "$n" -gt 10 ] && [ "${ALL:-0}" != 1 ] && [ -z "${BATCH_NO:-}" ]; then
    echo "more than 10 proxies for a pi stage: set PROJECTS='a-prj|b-prj' on the SAME line, or ALL=1 to run them all"; exit 2
  fi;;
esac

case "$STAGE" in
  list) flows | tee "$WS/domain/flows.txt" | awk '{print} END{print NR " proxies"}'
        projects > "$WS/domain/projects.txt"
        echo "$(wc -l < "$WS/domain/projects.txt" | tr -d ' ') projects -> domain/projects.txt, domain/flows.txt" ;;
  batches) np=$(BATCH_NO= projects | wc -l | tr -d ' '); nb=$(( (np + ${BATCH_SIZE:-10} - 1) / ${BATCH_SIZE:-10} ))
        echo "$np projects = $nb batches of ${BATCH_SIZE:-10} projects. Run them one after the other:"
        for b in $(seq 1 "$nb"); do echo "  BATCH_NO=$b bash $KIT/pi/run_domain.sh functional    # $(BATCH_NO=$b projects | paste -sd' ' - | cut -c1-90)"; done ;;
  coverage)
    [ -n "${SPLUNK_COVERAGE:-}" ] && [ -f "$SPLUNK_COVERAGE" ] || { echo "coverage needs SPLUNK_COVERAGE=<csv of the Splunk payload table>"; exit 2; }
    "$PY" "$KIT/skills/osb-to-camel/scripts/osb_inventory.py" "$APP" -o "$WS/domain/inventory" > /dev/null
    "$PY" "$(dirname "$BATCH")/domain_coverage.py" "$WS/domain/inventory" "$SPLUNK_COVERAGE" -o "$WS/domain/COVERAGE.md" ;;
  research) do_research; status ;;
  task1) do_task1; status ;;
  tests) do_tests; status ;;
  scaffold) do_scaffold; status ;;
  build) do_build; status ;;
  matrix) do_matrix; status ;;
  auto) do_research; do_task1; do_tests; status
        echo "functional test packs: modules/<project>/<proxy>/src/test + TEST_MATRIX.md; domain catalogue: domain/TEST_MATRIX.md" ;;
  report) status > /dev/null; "$PY" "$SK/domain_report.py" "$WS" ;;
  functional) do_research; do_task1; do_tests; do_build; do_matrix; status > /dev/null; "$PY" "$SK/domain_report.py" "$WS" ;;
  status) status ;;
  *) echo "unknown stage: $STAGE"; exit 2 ;;
esac
KIT_EOF_PI_RUN_DOMAIN_SH
mkdir -p "$(dirname "pi/run_tests.sh")"
cat > 'pi/run_tests.sh' <<'KIT_EOF_PI_RUN_TESTS_SH'
#!/usr/bin/env bash
# Functional test creation for ONE proxy, no route needed: research pack + Splunk cases -> generated tests and mocks
# -> synthetic inputs for scenarios Splunk cannot supply (pi tester) -> frozen test pack + catalogue.
#
# Usage: pi/run_tests.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]
# Env:   OSB_SRC (OSB project folder: the tester reads the message schema there), OSB_PI_MODEL, PI_THINKING, KIT, PYTHON
# Result: <module>/src/test/** (FlowParityTest + flow-test.json + real and synthetic case folders, frozen),
#         <module>/TEST_MATRIX.md (catalogue: every scenario, its inputs and expected outputs). Exit 1 if a scenario has no case.
set -euo pipefail
[ -f "${OSB_KIT_ENV:-$HOME/.osb-kit.env}" ] && . "${OSB_KIT_ENV:-$HOME/.osb-kit.env}"   # local client settings, never in Git
RES=${1:?usage: run_tests.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]}
MOD=${2:?module dir}
PRJ=${3:?osb project name}
TASK1=${4:-}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$KIT/pi/pi_call.sh"
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
SK=$(for d in "$KIT/skills/osb-camelk-route" "$KIT/.pi/skills/osb-camelk-route"; do [ -d "$d" ] && echo "$d" && break; done)
[ -n "$SK" ] || { echo "skill osb-camelk-route not found under $KIT"; exit 1; }
[ -s "$RES/research.json" ] || { echo "missing $RES/research.json: run pi/run_research.sh first"; exit 1; }

echo "== 1 generated tests + mocks (script)"
"$PY" "$SK/scripts/scaffold_camelk.py" "$RES" -o "$MOD" --project "$PRJ" ${TASK1:+--parity "$TASK1/fixtures/parity"}

echo "== 2 synthetic inputs where Splunk has none (pi tester)"
LOG="$MOD/.agent-logs"; mkdir -p "$LOG"
"$PY" "$SK/scripts/check_camelk.py" "$MOD" --no-surefire > /dev/null || true
UNCOV=$("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1]))['gates']['K9_scenarios_covered']['uncovered']))" "$MOD/GATES.json")
if [ "$UNCOV" != 0 ]; then
  PT=(pi --print --no-session --thinking "${PI_THINKING:-high}" --tools "read,bash,write" --append-system-prompt "$KIT/agents/tester-camelk.md")
  [ -n "${OSB_PI_MODEL:-}" ] && PT+=(--model "$OSB_PI_MODEL")
  pi_call "$LOG/tester.out" "$LOG/tester.err" "${PT[@]}" "Module: $MOD. Research: $RES/RESEARCH.md. ${OSB_SRC:+OSB source (read only, for the message schema): $OSB_SRC.} Write synthetic case folders for the $UNCOV scenario_mapping rows of $MOD/src/test/resources/flow-test.json that have no case yet (check: $PY $SK/scripts/check_camelk.py $MOD --no-surefire, gate K9). Fake values only. Write nothing outside $MOD/src/test/resources/parity." || true
else
  echo "   every scenario already has a real Splunk case"
fi

echo "== 3 freeze + catalogue"
"$PY" "$SK/scripts/scaffold_camelk.py" "$RES" -o "$MOD" --project "$PRJ" --freeze-synthetic
"$PY" "$SK/scripts/check_camelk.py" "$MOD" --no-surefire > /dev/null || true
"$PY" "$SK/scripts/test_matrix.py" "$MOD" > /dev/null || true
"$PY" - "$MOD" <<'PY'
import json, sys
from pathlib import Path
m = Path(sys.argv[1]); par = m / "src/test/resources/parity"
real = sum(1 for p in par.glob("*/*/*/input.payload") if "-synthetic" not in p.parts[-4])
syn = sum(1 for p in par.glob("*-synthetic/*/*/input.payload"))
g = json.loads((m / "GATES.json").read_text())["gates"]["K9_scenarios_covered"]
cfg = json.loads((m / "src/test/resources/flow-test.json").read_text())
print(json.dumps({"scenarios": len(cfg["scenario_mapping"]), "real_cases": real, "synthetic_cases": syn,
                  "uncovered": g["uncovered"], "outputs": sorted(cfg["outputs"]), "catalogue": str(m / "TEST_MATRIX.md")}))
sys.exit(0 if g["ok"] else 1)
PY
KIT_EOF_PI_RUN_TESTS_SH
mkdir -p "$(dirname "pi/pi_call.sh")"
cat > 'pi/pi_call.sh' <<'KIT_EOF_PI_PI_CALL_SH'
#!/usr/bin/env bash
# Sourced by the pi runners. pi_call <out-file> <err-file> <pi args...>
# Runs pi; when the model endpoint answers 429 / rate limit / overloaded, waits and retries with a growing pause.
# Env: PI_RETRIES (default 5), PI_BACKOFF (first pause in seconds, default 60, doubled each time, max 15 min).
pi_call() {
  local out=$1 err=$2; shift 2
  local n=0 wait=${PI_BACKOFF:-60}
  while :; do
    "$@" > "$out" 2> "$err" && return 0
    if grep -qiE '(^|[^0-9])429([^0-9]|$)|too many requests|rate.?limit|overloaded|503 service unavailable' "$err" 2>/dev/null \
       && [ "$n" -lt "${PI_RETRIES:-5}" ]; then
      n=$((n + 1))
      echo "   model endpoint busy (rate limit), waiting ${wait}s, retry $n/${PI_RETRIES:-5}"
      sleep "$wait"
      wait=$((wait * 2)); [ "$wait" -gt 900 ] && wait=900
      continue
    fi
    return 1
  done
}
KIT_EOF_PI_PI_CALL_SH
mkdir -p "$(dirname "pi/run_research.sh")"
cat > 'pi/run_research.sh' <<'KIT_EOF_PI_RUN_RESEARCH_SH'
#!/usr/bin/env bash
# Research pack for ONE proxy on the pi coding agent: facts (script) -> questionnaire (pi) -> share check (script).
# The OSB source never leaves the machine; only research/<proxy>/ is shared, and only after the check passes.
#
# Usage: pi/run_research.sh <osb-project-dir> <proxy> [task1-dir]
# Env:   OUT (default research/<proxy>; run_domain.sh uses research/<project>/<proxy>), OSB_PI_MODEL (model pattern for
#        `pi --model`), PI_THINKING (default high), KIT, PYTHON
set -euo pipefail
[ -f "${OSB_KIT_ENV:-$HOME/.osb-kit.env}" ] && . "${OSB_KIT_ENV:-$HOME/.osb-kit.env}"   # local client settings, never in Git
PROJECT=${1:?usage: run_research.sh <osb-project-dir> <proxy> [task1-dir]}
PROXY=${2:?proxy name}
TASK1=${3:-}
case "$PROJECT" in *\\*|[A-Za-z]:*) command -v cygpath >/dev/null && PROJECT=$(cygpath -u "$PROJECT");; esac   # Windows path (quoted) -> /e/...
case "$PROXY" in */*|*\\*) echo "2nd argument must be the proxy name (e.g. sample-adjustment), not a path. usage: run_research.sh <osb-project-dir> <proxy> [task1-dir]"; exit 2;; esac
[ -e "$PROJECT" ] || { echo "OSB project not found: $PROJECT  (Git Bash: write /e/folder/project, not E:\\folder\\project)"; exit 2; }
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$KIT/pi/pi_call.sh"
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
OUT=${OUT:-research/$PROXY}
LOG="$OUT/agent-logs"
skill_dir() { if [ -d "$KIT/skills/$1" ]; then echo "$KIT/skills/$1"; elif [ -d "$KIT/.pi/skills/$1" ]; then echo "$KIT/.pi/skills/$1"; fi; }
SK=$(skill_dir osb-research); [ -n "$SK" ] || { echo "skill osb-research not found under $KIT"; exit 1; }
mkdir -p "$LOG"

echo "== 1 facts"
"$PY" "$SK/scripts/research_pack.py" "$PROJECT" "$PROXY" -o "$OUT" ${TASK1:+--scenarios "$TASK1/traces/scenarios.json"}

SHA=$(command -v sha1sum || command -v shasum)
fp() { find "$1" -type f -print0 | sort -z | xargs -0 "$SHA" 2>/dev/null | "$SHA" | cut -c1-16; }
before=$(fp "$PROJECT")

echo "== 2 questionnaire (pi)"
PI=(pi --print --no-session --thinking "${PI_THINKING:-high}" --skill "$SK" --tools "read,bash,write"
    --append-system-prompt "$KIT/agents/researcher.md")
[ -n "${OSB_PI_MODEL:-}" ] && PI+=(--model "$OSB_PI_MODEL")
pi_call "$LOG/research.out" "$LOG/research.err" "${PI[@]}" "Use skill osb-research. OSB export: $PROJECT. Proxy: $PROXY. Today is $(date +%F). facts.json and SOURCES.txt are already in $OUT (step 1 done). Do steps 2-5: read the sources, answer every question of references/questions.md into $OUT/RESEARCH.md (assets/RESEARCH_TEMPLATE.md) and $OUT/research.json (assets/research.schema.json), run '$PY $SK/scripts/research_check.py $OUT' until it prints PASS. Write nothing outside $OUT." || true
for try in 2; do   # pi sometimes ends without writing the files: one more attempt, logs kept per attempt
  [ -s "$OUT/RESEARCH.md" ] && [ -s "$OUT/research.json" ] && break
  echo "   pi wrote no answer files, attempt $try (see $LOG/research.err)"
  cp "$LOG/research.err" "$LOG/research.attempt1.err" 2>/dev/null || true
  pi_call "$LOG/research.out" "$LOG/research.err" "${PI[@]}" "Use skill osb-research. A previous attempt ended without writing RESEARCH.md and research.json: write both files. OSB export: $PROJECT. Proxy: $PROXY. Today is $(date +%F). facts.json and SOURCES.txt are already in $OUT (step 1 done). Do steps 2-5: read the sources, answer every question of references/questions.md into $OUT/RESEARCH.md (assets/RESEARCH_TEMPLATE.md) and $OUT/research.json (assets/research.schema.json), run '$PY $SK/scripts/research_check.py $OUT' until it prints PASS. Write nothing outside $OUT." || true
done

[ "$(fp "$PROJECT")" = "$before" ] || { echo "VIOLATION: the OSB export was changed during research"; exit 1; }

echo "== 3 share check"
for f in RESEARCH.md research.json; do [ -s "$OUT/$f" ] || { echo "missing $OUT/$f (see $LOG/research.err)"; exit 1; }; done
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); m=[k for k in ('proxy','entry','branches','outputs','transforms','backends','errors','logs','open_questions') if k not in d]; sys.exit('research.json misses: '+', '.join(m) if m else 0)" "$OUT/research.json"
rm -rf "$OUT.agent-logs"; mv "$LOG" "$OUT.agent-logs"     # agent logs may quote source: they stay on the machine, outside the shared folder
"$PY" "$SK/scripts/research_check.py" "$OUT" || { echo "NOT shareable yet: fix the lines above (logs: $OUT.agent-logs)"; exit 1; }
echo "share: $OUT/RESEARCH.md research.json facts.json SHARE_CHECK.json"
KIT_EOF_PI_RUN_RESEARCH_SH
mkdir -p "$(dirname "pi/preflight.sh")"
cat > 'pi/preflight.sh' <<'KIT_EOF_PI_PREFLIGHT_SH'
#!/usr/bin/env bash
# Preflight for the client VDI: checks everything the kit needs before the first run.
# Runs in Git Bash (Windows), WSL or Linux. Read-only: installs nothing, changes nothing.
# Usage: pi/preflight.sh [model-endpoint-url]
set -u
[ -f "${OSB_KIT_ENV:-$HOME/.osb-kit.env}" ] && . "${OSB_KIT_ENV:-$HOME/.osb-kit.env}"   # local client settings, never in Git
ok=0; warn=0; fail=0
pass() { printf '  [ OK ] %s\n' "$1"; ok=$((ok+1)); }
wrn()  { printf '  [WARN] %s\n' "$1"; warn=$((warn+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # $1 >= $2

echo "OS: $(uname -s 2>/dev/null) $(uname -r 2>/dev/null)"

echo "Agent"
if command -v node >/dev/null; then
  v=$(node -v | tr -d v); ver_ge "$v" 22.19.0 && pass "node $v" || bad "node $v < 22.19 (pi requirement)"
else bad "node not found (pi needs Node.js 22.19+)"; fi
if command -v pi >/dev/null; then pass "pi $(pi --version 2>/dev/null | head -1)"; else bad "pi not found"; fi
[ -n "${OSB_PI_MODEL:-}" ] && pass "OSB_PI_MODEL=$OSB_PI_MODEL" || wrn "OSB_PI_MODEL unset: pi uses its default model"
for f in "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json" "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/auth.json"; do
  [ -f "$f" ] && pass "found $f" || wrn "no $f (needed for a custom endpoint or stored login)"
done
[ "${PI_OFFLINE:-}" ] && pass "PI_OFFLINE set (no catalog/network calls)" || wrn "PI_OFFLINE unset: pi may call pi.dev (catalog, version check)"
[ "${PI_TELEMETRY:-}" = "0" ] && pass "PI_TELEMETRY=0" || wrn "PI_TELEMETRY not 0"
if [ -n "${1:-}" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo 000)
  [ "$code" != "000" ] && pass "model endpoint reachable ($1 → HTTP $code)" || bad "model endpoint not reachable: $1"
fi

echo "Shell tools"
command -v bash >/dev/null && pass "bash $(bash --version | head -1 | awk '{print $4}')" || bad "bash missing (Git for Windows provides it)"
command -v sha1sum >/dev/null || command -v shasum >/dev/null && pass "sha1sum/shasum" || bad "no sha1sum/shasum"
PY=$(command -v python3 || command -v python || command -v py)
if [ -n "$PY" ]; then v=$("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])'); ver_ge "$v" 3.10 && pass "python $v ($PY)" || bad "python $v < 3.10"
else bad "python not found"; fi
command -v git >/dev/null && pass "git" || wrn "git missing (lane checks still work, CI guard needs git)"

echo "Build and test"
if command -v java >/dev/null; then
  v=$(java -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/'); [ "$v" -ge 21 ] 2>/dev/null && pass "java $v" || bad "java $v < 21"
else bad "java not found (JDK 21)"; fi
if command -v mvn >/dev/null; then pass "maven $(mvn -v 2>/dev/null | head -1 | awk '{print $3}')"
  [ -f "$HOME/.m2/settings.xml" ] && pass "~/.m2/settings.xml present (mirror/proxy)" || wrn "no ~/.m2/settings.xml: Maven will try Maven Central directly"
else bad "maven not found"; fi
if docker info >/dev/null 2>&1; then pass "docker"; elif podman info >/dev/null 2>&1; then pass "podman"
else printf '  [INFO] no Docker/Podman: not needed (functional tests use mocks; Artemis tests run later on the Dev environment)\n'; fi

echo "Kit layout (run from the migration repository root)"
for p in AGENTS.md agents/analyst.md tools/verify_flow.sh pi/run_flow.sh; do [ -e "$p" ] && pass "$p" || bad "$p missing"; done
sk=0; for d in .pi/skills "$HOME/.pi/agent/skills" .agents/skills skills; do [ -f "$d/osb-to-camel/SKILL.md" ] && sk=1; done
[ $sk = 1 ] && pass "skill osb-to-camel discoverable" || bad "skill osb-to-camel not in .pi/skills, ~/.pi/agent/skills or .agents/skills"
sr=0; for d in .pi/skills "$HOME/.pi/agent/skills" .agents/skills skills; do [ -f "$d/osb-research/SKILL.md" ] && sr=1; done
[ $sr = 1 ] && pass "skill osb-research discoverable" || bad "skill osb-research not found (needed for research packs: pi/run_research.sh)"
# Maven build of Camel K modules: Maven 3.6.3+ on Java 17+ (VDI default is Maven 3.5.3 on JDK 1.7)
if command -v mvn >/dev/null; then
  mv=$(mvn -v 2>/dev/null | tr -d '\033' | sed -n 's/.*Apache Maven \([0-9.]*\).*/\1/p' | head -1)
  jv=$(mvn -v 2>/dev/null | sed -n 's/^Java version: \([0-9]*\).*/\1/p' | head -1); [ "$jv" = 1 ] && jv=$(mvn -v | sed -n 's/^Java version: 1\.\([0-9]*\).*/\1/p')
  printf '%s\n3.6.3\n' "$mv" | sort -V -C 2>/dev/null && bad "Maven $mv too old for the test plugins (need 3.6.3+: Maven 3.9.9 from Nexus, see DOMAIN_RUN.md)" || pass "Maven $mv"
  [ "${jv:-0}" -ge 17 ] 2>/dev/null && pass "Maven runs on Java $jv" || bad "Maven runs on Java ${jv:-?} (need 17+: export JAVA_HOME to the JDK 21 folder)"
fi
sc=0; for d in .pi/skills "$HOME/.pi/agent/skills" .agents/skills skills; do [ -f "$d/osb-camelk-route/SKILL.md" ] && sc=1; done
[ $sc = 1 ] && pass "skill osb-camelk-route discoverable" || bad "skill osb-camelk-route not found (needed for pi/run_camelk.sh, pi/run_domain.sh)"
# pi skips a SKILL.md whose front matter is not valid YAML, without an error: check the usual traps
for f in .pi/skills/*/SKILL.md "$HOME/.pi/agent/skills"/*/SKILL.md .agents/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  issue=$(awk 'NR==1 && $0!="---"{print "no front matter"; exit} NR>1 && $0=="---"{exit}
               NR>1 && /^[A-Za-z_-]+: /{v=$0; sub(/^[A-Za-z_-]+: /,"",v);
                 if (v ~ /^["\x27]/) next;
                 if (index(v,": ")) {print "unquoted \": \" in " $1; exit}
                 if (index(v," #")) {print "unquoted \" #\" in " $1; exit}
                 if (length(v)>1024 && $1=="description:") {print "description over 1024 characters"; exit}}' "$f")
  [ -z "$issue" ] && pass "front matter valid: $f" || bad "pi will skip $f: $issue"
done
# /osb-* commands: pi reads prompt templates from .pi/prompts (project, after trust) or ~/.pi/agent/prompts
pd=""; for d in .pi/prompts "$HOME/.pi/agent/prompts"; do
  m=0; for n in osb-analyse osb-implement osb-test osb-verify osb-review; do [ -f "$d/$n.md" ] || m=$((m+1)); done
  [ $m -eq 0 ] && { pd=$d; break; }
done
if [ -n "$pd" ]; then pass "/osb-* commands found in $pd"
  [ "$pd" = .pi/prompts ] && printf '  [INFO] .pi/ loads only for a trusted project: trust it at the first pi start, or run pi --approve\n'
else bad "/osb-* commands missing: run  mkdir -p .pi/prompts && cp pi/prompts/*.md .pi/prompts/  (pi/prompts is the kit copy, pi does not read it)"; fi
[ -d osb-src ] && [ -n "$(ls -A osb-src 2>/dev/null)" ] && pass "osb-src/ has content" || wrn "osb-src/ empty: put the OSB export there"

echo; echo "Result: $ok ok, $warn warnings, $fail failures"
[ $fail -eq 0 ]
KIT_EOF_PI_PREFLIGHT_SH
mkdir -p "$(dirname "AGENTS.md")"
cat > 'AGENTS.md' <<'KIT_EOF_AGENTS_MD'
# AGENTS.md: OSB → Camel migration repository (client programme)

Every AI agent working in this repository follows these rules. Role prompts in `agents/` add duties per phase.

## What this repository is

Camel K integrations (YAML DSL) that replace Oracle Service Bus flows: one module per OSB proxy under
`modules/<project>/<proxy>/` (route `*.camel.yaml` + helper beans + L1 tests). Source of truth for behaviour = the OSB export under `osb-src/` (read-only).

## Workflow (never skip a step)

1. **Check first:** search this repository for the proxy name, its queues/topics/URLs and XQuery file names. If a
   route already exists, compare and report; do not generate a second one.
2. **Research** with skill `osb-research` → `research/<project>/<proxy>/` (shareable pack, check PASS).
3. **Card + tests** with skill `osb-camelk-route` Step 1 → `modules/<project>/<proxy>/FLOW_CARD.md` + generated tests.
4. **Stop for approval.** No code for a card without `Status: approved` and an approver name.
5. **Implement and test** with `osb-camelk-route` Steps 3–5 (route, error tests, stubs).
6. **Verify:** `check_camelk.py modules/<project>/<proxy>` must print PASS (K1–K8).
7. **Record:** `modules/<project>/<proxy>/MIGRATION_NOTES.md` with the four sections: Original OSB behaviour / Camel
   implementation / Behavioural differences / Items requiring human validation.

## Hard rules

- Inputs are files from `osb-src/`. Never build code from screenshots, chat text or memory of "how OSB usually works".
- Runtime (decision 2026-10-14): **Camel K, routes in YAML DSL** (`*.camel.yaml`), Camel 4.18.4 = Camel Quarkus 3.33.3
  (`camel.runtime-version=3.33.3`), small Java helper beans next to the YAML, tests with `camel-test-main-junit5` +
  mock endpoints. Pattern: `pilot/sample-adjustment`, skill `osb-camelk-route`. Older Spring Boot templates in
  `osb-to-camel/assets` are reference only.
- Messaging: Red Hat AMQ Broker, AMQP 1.0 on port 5672, `camel-amqp` (Qpid JMS) with a failover URI. Destinations
  exist only through the Git register; never rely on auto-create. A WebLogic durable topic subscription becomes a
  named subscription queue with a broker-side filter, consumed by FQQN `<address>::<subscription>`.
- JMS: local transacted sessions; duplicate-ID header on every send; consumers idempotent.
- Every endpoint, queue name, timeout and retry value is a `{{placeholder}}`; no host names, ports or credentials in
  code, tests or `application.yml`. Credentials come from Vault at runtime.
- Keep original XQuery/XSLT files and their behaviour (quirks included) unless the card approves a change. Never
  rewrite a working transform into Java "because it is cleaner".
- Logging: stdout, correlation id in every line, no full payloads above DEBUG, mask personal data (SIN, national ID).
- Component options: Camel MCP if connected, else `skills/osb-to-camel/references/versions.md` + Camel docs for that
  version. Do not guess options.
- **Test oracle:** expected outputs come from OSB (recordings, the original transform run on Saxon, the OSB test
  console). Never generate an expected file by running the new Camel code.
- Never delete, skip or weaken a test to get green. A skipped test needs a reason in the record.
- Never claim equivalence. Report gate results and test evidence; humans decide.

## Commands

| Purpose | Command |
|---|---|
| Research pack (source stays, knowledge travels) | `pi/run_research.sh osb-src/<project> <proxy> [task1-dir]` → `research/<proxy>/` (shared only after `research_check.py` PASS) |
| All proxies of one OSB application | `pi/run_domain.sh <osb-app-dir> <stage>` (stages: list, research, scaffold, build, status) → `domain/STATUS.md` |
| Functional tests only (no route) | `pi/run_tests.sh research/<project>/<proxy> modules/<project>/<proxy> <project> [task1-dir]` |
| Research pack → Camel K module + tests | `pi/run_camelk.sh research/<project>/<proxy> modules/<project>/<proxy> <project> [task1-dir]` (stops until the card is approved) |
| Gates of a Camel K module | `python3 skills/osb-camelk-route/scripts/check_camelk.py modules/<project>/<proxy>` (K1-K8) |
| Inventory an export | `python3 skills/osb-to-camel/scripts/osb_inventory.py osb-src/<project> -o migration/osb-inventory` |
| Scaffold a card | `python3 skills/osb-to-camel/scripts/scaffold_flow.py migration/osb-inventory/flows/<flow>.json -o migration/<flow>/` |
| Build + tests | `mvn -q -f <module>/pom.xml verify` |
| All gates | `tools/verify_flow.sh <module> <flow>` |

## Definition of done (per flow)

Card approved · gates K1–K8 PASS in `GATES.json` · `MIGRATION_NOTES.md` written · reviewer report with no open BLOCKER ·
human sign-off · shadow run passed (TESTING.md L6) before cut-over.
KIT_EOF_AGENTS_MD
mkdir -p "$(dirname ".pi/prompts/osb-camelk.md")"
cat > '.pi/prompts/osb-camelk.md' <<'KIT_EOF__PI_PROMPTS_OSB_CAMELK_MD'
---
description: "Approved flow card + research pack -> Camel K YAML route + tests, until the gates pass"
argument-hint: "<module-dir> <research-dir>"
---
Act as the implementer defined in agents/implementer-camelk.md and follow AGENTS.md.
Use skill osb-camelk-route on module $1 (approved card $1/FLOW_CARD.md) with research pack $2.
Do steps 3-6 of the skill until check_camelk.py prints PASS, then give the five-line report.
KIT_EOF__PI_PROMPTS_OSB_CAMELK_MD
mkdir -p "$(dirname ".pi/skills/osb-research/references/questions.md")"
cat > '.pi/skills/osb-research/references/questions.md' <<'KIT_EOF__PI_SKILLS_OSB_RESEARCH_REFERENCES_QUESTIONS_MD'
# Research questionnaire (one proxy)

Answer every question. Evidence column: file (relative path) + stage/action name. `UNKNOWN` + open question if the
source does not say. No code, no hosts, no data (see SKILL.md rules).

| # | Question | Answer as |
|---|---|---|
| Q1 | **Entry.** Transport, destination name, queue or topic, durable subscription and its name, message selector (verbatim, it is configuration), message type (text/bytes/XML/JSON), encoding, XA, response required, concurrency/dispatch policy | table |
| Q2 | **Message format.** What arrives (JSON or XML; root element or top-level keys), is there an nXSD/JSON-to-XML translation (which one, is the file in the export), what `$body` contains after it | short text + field list |
| Q3 | **Flow overview.** The pipeline in order: stage → action type → what it does in one sentence. Include route nodes, branches, publish, service callouts, Java callouts, reply/resume | numbered list |
| Q4 | **Branches.** For each branch/if-then: condition in plain words, the condition expression (one line), which values lead to which path, what happens on each path, default path | table per branch |
| Q5 | **Scenario mapping.** Branches decide on payload fields: list those fields in `scenario_dims` (JSON path such as `data.hasPartnerEngagement`, or the element name). Then give one `scenario_mapping` row per combination of their values with the outputs reached, as `k=v|k!=v` (k = last path segment; `k!=true` also covers a missing field; first matching row wins; outputs = business service names, `[]` = consumed, nothing sent). A flow without branches has one row with scenario `*` (every message). Never answer "depends on the message": that is what the row must spell out. Then say which `log_scenarios` in `facts.json` show those fields; if none do, write `rerun task 1 with SCENARIO_DIMS=...,body:<path>` in open questions | table |
| Q6 | **Outputs.** Request-response proxies (HTTP, local, SOAP): the answer to the caller is an output named `reply` (use it in branches and scenario_mapping). Name each other output after the business service that writes it (the same name in branches, scenario_mapping and backends). Every destination the flow writes to (business service → queue/topic/HTTP path/operation): on which path, which body (built by which transform), which JMS properties / transport headers / HTTP headers are set and from where | table |
| Q7 | **Transforms.** For each XQuery/XSLT/assign/replace that builds a message: purpose, inputs (external params), output root, field mapping `source path → target path → rule` (copy, constant, format, lookup, condition), fn-bea functions used, constants | table per transform |
| Q8 | **Backends.** Each business service / service callout: type, operation, when it is called, request built from, how the response is used, retry count/interval, timeout, load balancing, result caching, what happens on fault | table |
| Q9 | **Errors.** Each error handler scope (stage, pipeline, service): what it catches, what it logs, where the message goes (error queue, reply, resume, re-raise), headers/fields set (errorCode, errorMessage, traceId ...), redelivery/retry behaviour of the transport | table |
| Q10 | **Logging.** Say explicitly when a Log action logs the OUTGOING body (e.g. "... for BS x to be posted ... ::$body"): that logged body is OSB's own output and becomes the expected result of the tests. Each Log action: stage, level, the message template with placeholders (e.g. `Request Received to Project {project} :: for PS {proxy} ... TraceID - {uuid} ::{body}`), what `{...}` are | table |
| Q11 | **Dependencies.** Shared resources from other projects, DVM lookups (name, columns used), Java callouts (class, method, what for), customisation/env properties used (names only), alerts, reporting, throttling, SLA | table |
| Q12 | **Open questions.** Everything UNKNOWN, ambiguous or missing from the export, each with why it matters for the migration | numbered list |
KIT_EOF__PI_SKILLS_OSB_RESEARCH_REFERENCES_QUESTIONS_MD
mkdir -p "$(dirname ".pi/skills/osb-research/assets/RESEARCH_TEMPLATE.md")"
cat > '.pi/skills/osb-research/assets/RESEARCH_TEMPLATE.md' <<'KIT_EOF__PI_SKILLS_OSB_RESEARCH_ASSETS_RESEARCH_TEMPLATE_MD'
# Research — <proxy>

| | |
|---|---|
| **Proxy** | <proxy> |
| **Project** | <project> |
| **Export version** | <branch / tag / commit or export date> |
| **Researched by / on** | pi osb-research / <date> |
| **Tier (facts.json)** | <tier> |
| **Check** | see SHARE_CHECK.json |

## Q1 Entry
| Item | Value | Evidence |
|---|---|---|

## Q2 Message format

## Q3 Flow overview
1.

## Q4 Branches
### Branch <name>
| Path | Condition (plain) | Expression | Actions | Evidence |
|---|---|---|---|---|

## Q5 Scenario mapping
Fields the branches decide on (`scenario_dims`): ...

| Scenario (k=v / k!=v) | Outputs (business services, or none) | Branch / path | Log scenarios showing it | Evidence |
|---|---|---|---|---|

## Q6 Outputs
| Business service | Destination | Path / branch | Body built by | Headers / properties set (name ← source) | Evidence |
|---|---|---|---|---|---|

## Q7 Transforms
### <transform>
Purpose: … Inputs: … Output root: … fn-bea: …
| Source path | Target path | Rule | Evidence |
|---|---|---|---|

## Q8 Backends
| Service | Type / operation | Called when | Request from | Response used for | Retry / timeout | On fault | Evidence |
|---|---|---|---|---|---|---|---|

## Q9 Errors
| Scope | Catches | Logs | Goes to | Headers / fields set | Redelivery | Evidence |
|---|---|---|---|---|---|---|

## Q10 Logging
| Stage | Level | Template | Placeholders | Evidence |
|---|---|---|---|---|

## Q11 Dependencies
| Kind | Name | Used for | In export? | Evidence |
|---|---|---|---|---|

## Q12 Open questions
1.
KIT_EOF__PI_SKILLS_OSB_RESEARCH_ASSETS_RESEARCH_TEMPLATE_MD
mkdir -p "$(dirname ".pi/skills/osb-research/assets/research.schema.json")"
cat > '.pi/skills/osb-research/assets/research.schema.json' <<'KIT_EOF__PI_SKILLS_OSB_RESEARCH_ASSETS_RESEARCH_SCHEMA_JSON'
{
  "$comment": "Machine-readable twin of RESEARCH.md. Same content, no code, no hosts, no data.",
  "type": "object",
  "required": [
    "proxy",
    "entry",
    "branches",
    "outputs",
    "transforms",
    "backends",
    "errors",
    "logs",
    "open_questions"
  ],
  "properties": {
    "proxy": {
      "type": "string"
    },
    "project": {
      "type": "string"
    },
    "export_version": {
      "type": "string"
    },
    "entry": {
      "type": "object",
      "properties": {
        "transport": {
          "type": "string"
        },
        "destination": {
          "type": "string"
        },
        "is_topic": {
          "type": "boolean"
        },
        "durable_subscription": {
          "type": "string"
        },
        "selector": {
          "type": "string"
        },
        "message_type": {
          "type": "string"
        },
        "payload_format": {
          "enum": [
            "json",
            "xml",
            "text",
            "binary",
            "UNKNOWN"
          ]
        },
        "nxsd": {
          "type": "string"
        }
      }
    },
    "branches": {
      "type": "array",
      "items": {
        "type": "object",
        "required": [
          "name",
          "paths"
        ],
        "properties": {
          "name": {
            "type": "string"
          },
          "stage": {
            "type": "string"
          },
          "paths": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "label": {
                  "type": "string"
                },
                "condition_plain": {
                  "type": "string"
                },
                "condition_expr": {
                  "type": "string"
                },
                "actions": {
                  "type": "array",
                  "items": {
                    "type": "string"
                  }
                },
                "outputs": {
                  "type": "array",
                  "items": {
                    "type": "string"
                  }
                }
              }
            }
          }
        }
      }
    },
    "scenario_mapping": {
      "type": "array",
      "items": {
        "type": "object",
        "required": [
          "scenario",
          "outputs"
        ],
        "properties": {
          "scenario": {
            "type": "string",
            "description": "k=v|k!=v over scenario dims (last path segment as k); first matching row wins; 'k!=true' also matches a missing field"
          },
          "outputs": {
            "type": "array",
            "items": {
              "type": "string"
            },
            "description": "business service names the message reaches; [] = consumed, nothing sent"
          },
          "branch": {
            "type": "string"
          },
          "path": {
            "type": "string"
          }
        }
      }
    },
    "outputs": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "name": {
            "type": "string"
          },
          "destination": {
            "type": "string"
          },
          "on_path": {
            "type": "string"
          },
          "body_from": {
            "type": "string"
          },
          "headers": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "name": {
                  "type": "string"
                },
                "source": {
                  "type": "string"
                }
              }
            }
          },
          "business_service": {
            "type": "string"
          }
        }
      }
    },
    "transforms": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "name": {
            "type": "string"
          },
          "purpose": {
            "type": "string"
          },
          "inputs": {
            "type": "array",
            "items": {
              "type": "string"
            }
          },
          "output_root": {
            "type": "string"
          },
          "fn_bea": {
            "type": "array",
            "items": {
              "type": "string"
            }
          },
          "mappings": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "from": {
                  "type": "string"
                },
                "to": {
                  "type": "string"
                },
                "rule": {
                  "type": "string"
                }
              }
            }
          }
        }
      }
    },
    "backends": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "name": {
            "type": "string"
          },
          "type": {
            "type": "string"
          },
          "operation": {
            "type": "string"
          },
          "called_when": {
            "type": "string"
          },
          "request_from": {
            "type": "string"
          },
          "response_use": {
            "type": "string"
          },
          "retry": {
            "type": "string"
          },
          "timeout": {
            "type": "string"
          },
          "on_fault": {
            "type": "string"
          }
        }
      }
    },
    "errors": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "scope": {
            "type": "string"
          },
          "catches": {
            "type": "string"
          },
          "logs": {
            "type": "string"
          },
          "goes_to": {
            "type": "string"
          },
          "headers": {
            "type": "array",
            "items": {
              "type": "string"
            }
          },
          "redelivery": {
            "type": "string"
          }
        }
      }
    },
    "logs": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "stage": {
            "type": "string"
          },
          "level": {
            "type": "string"
          },
          "template": {
            "type": "string"
          }
        }
      }
    },
    "dependencies": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "kind": {
            "type": "string"
          },
          "name": {
            "type": "string"
          },
          "used_for": {
            "type": "string"
          },
          "in_export": {
            "type": "boolean"
          }
        }
      }
    },
    "open_questions": {
      "type": "array",
      "items": {
        "type": "string"
      }
    },
    "scenario_dims": {
      "type": "array",
      "items": {
        "type": "string"
      },
      "description": "JSON paths (data.x) or XML element names of the payload fields the branches decide on; task 1 is rerun with SCENARIO_DIMS=...,body:<path> so the log scenarios carry them"
    }
  }
}
KIT_EOF__PI_SKILLS_OSB_RESEARCH_ASSETS_RESEARCH_SCHEMA_JSON
chmod +x .pi/skills/osb-camelk-route/scripts/*.py pi/*.sh 2>/dev/null || true
echo "installed: 23 files (skill osb-camelk-route + domain runner)"
