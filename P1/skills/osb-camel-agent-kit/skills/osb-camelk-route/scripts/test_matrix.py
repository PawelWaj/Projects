#!/usr/bin/env python3
"""Test matrix: what was tested, with which inputs, and the result, per flow and for a whole domain. Stdlib only.

    test_matrix.py modules/<project>/<proxy>            -> <module>/TEST_MATRIX.md + test-matrix.csv
    test_matrix.py --domain modules -o domain           -> domain/TEST_MATRIX.md + test-matrix.csv (one row per flow)

Per flow it joins: flow-test.json (expected outputs per scenario, from the research pack), the case folders
(SCENARIO.txt: which real masked messages were used), the surefire XML reports (display name "route <case>" /
"body <case>" per message), GATES.json (K1-K8) and MUTATION.json (route mutations the tests caught). Rows:
  P<n>  one per scenario seen in the logs: messages in the export, cases tested, expected outputs, passed/failed
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
                return ", ".join("out-" + o for o in m["outputs"]) or "nothing sent"
        return "NOT MAPPED"

    rows, used = [], set()
    for i, (key, cases) in enumerate(sorted(by_scenario.items(), key=lambda kv: -counts.get(kv[0], len(kv[1]))), 1):
        rel = [c.relative_to(parity).as_posix() for c in cases]
        st = [res.get(f"FlowParityTest::reachesTheSameOutputAsOsb(String, Path) route {r}") for r in rel]
        body = [res.get(f"FlowParityTest::bodyEqualsOriginalXQueryResult(String, Path) body {r}") for r in rel]
        used.update(f"FlowParityTest::reachesTheSameOutputAsOsb(String, Path) route {r}" for r in rel)
        used.update(f"FlowParityTest::bodyEqualsOriginalXQueryResult(String, Path) body {r}" for r in rel)
        scen = "|".join(p for p in key.split("|")[2:])
        rows.append({"id": f"P{i:02d}", "kind": "parity (real masked messages)", "what": scen or key,
                     "inputs": f"{len(cases)} of {counts.get(key, '?')} in export", "expected": expected(key),
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
    p = [r for r in rows if r["id"].startswith("P")]
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
