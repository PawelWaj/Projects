#!/usr/bin/env python3
"""Test catalogue for one flow, built from the task-1 output (no values from the payloads are written).

    test_catalog.py <task1-dir> [--negative-resource "<resource>"]... [--fanout-peer <proxy>]... [-o TEST_CATALOG.md]

Reads <task1>/traces/scenarios.json, <task1>/fixtures/parity/**, <task1>/replay-config.json and the anonymise report,
checks every test case folder (payload parses, headers carry the correlation id, expected.json complete) and writes:
  TEST_CATALOG.md / test-catalog.csv   one row per test case: id, group, what it proves, input, mocks, expected,
                                       level (L1 Camel mocks / L2 Artemis+WireMock / L3 replay), status
  negative-cases.json                  selector cases ready to merge into replay-config.json once the filter is known
Groups: P parity per logged scenario (real inputs), S selector incl. negatives, F fan-out, E error paths, D delivery.
Stdlib only."""
import argparse
import csv
import json
import re
import sys
from pathlib import Path

LENIENT = json.JSONDecoder(strict=False)


def check_case(case: Path, corr_header: str) -> list[str]:
    problems = []
    for name in ("input.payload", "headers.json", "expected.json"):
        if not (case / name).is_file():
            problems.append(f"missing {name}")
    if problems:
        return problems
    body = (case / "input.payload").read_text(encoding="utf-8").strip()
    if body.startswith("{"):
        try:
            LENIENT.raw_decode(body)
        except ValueError as e:
            problems.append(f"payload does not parse ({getattr(e, 'msg', e)})")
    elif not body.startswith("<"):
        problems.append("payload is neither JSON nor XML")
    headers = json.loads((case / "headers.json").read_text(encoding="utf-8"))
    if not headers.get(corr_header):
        problems.append(f"headers.json without {corr_header}")
    exp = json.loads((case / "expected.json").read_text(encoding="utf-8"))
    for k in ("outcome", "destination", "correlation"):
        if not exp.get(k):
            problems.append(f"expected.json without {k}")
    return problems


def scenario_label(key: str) -> dict:
    parts = key.split("|")
    return {"outcome": parts[1] if len(parts) > 1 else "?",
            **{p.split("=", 1)[0]: p.split("=", 1)[1] for p in parts[2:] if "=" in p}}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("task1", type=Path)
    ap.add_argument("--negative-resource", action="append", default=[], help="resource on the same topic the flow must NOT take")
    ap.add_argument("--fanout-peer", action="append", default=[], help="other proxy that receives the same events")
    ap.add_argument("-o", "--out", type=Path)
    a = ap.parse_args()
    t = a.task1
    scenarios = json.loads((t / "traces/scenarios.json").read_text(encoding="utf-8"))
    cfg = json.loads((t / "replay-config.json").read_text(encoding="utf-8"))
    flow, fc = next(iter(cfg["flows"].items()))
    corr = fc.get("correlation_header", "traceId")
    report = t / "events.masked.csv.report.json"
    payloads = json.loads(report.read_text(encoding="utf-8")).get("payloads", {}) if report.is_file() else {}

    folders = {}
    for sc in sorted((t / "fixtures/parity").glob("*/*/SCENARIO.txt")):
        folders[sc.read_text(encoding="utf-8").strip()] = sc.parent
    rows, broken = [], []
    total = sum(s["count"] for s in scenarios) or 1
    for i, s in enumerate(scenarios, 1):
        lab = scenario_label(s["scenario"])
        folder = folders.get(s["scenario"])
        cases = sorted(p for p in folder.iterdir() if p.is_dir()) if folder else []
        bad = {c.name: check_case(c, corr) for c in cases}
        broken += [f"{folder.name}/{n}: {'; '.join(p)}" for n, p in bad.items() if p]
        golden = all((c / "expected-output.xml").exists() for c in cases) and cases
        what = ", ".join(f"{k}={v}" for k, v in lab.items() if k != "outcome")
        rows.append({"id": f"P{i:02d}", "group": "parity", "proves": f"same result as OSB for {what}",
                     "input": f"{len(cases)} real masked messages ({s['count']} in export, {s['count'] / total:.1%})"
                              + (f" in fixtures/parity/*/{folder.name}" if folder else " (no folder: no payload)"),
                     "mocks": "backends of the flow (from the OSB source)",
                     "expected": f"{lab['outcome']} -> {fc['outputs'][lab['outcome']]['destination']}; body = original XQuery",
                     "level": "L1, L3", "status": "ready" if golden else "inputs ready; expected body after task 2"})
    first_resource = next((scenario_label(s["scenario"]).get("hdr_resource") for s in scenarios), "?")
    rows.append({"id": "S01", "group": "selector", "proves": f"messages for resource '{first_resource}' are consumed",
                 "input": "any P case", "mocks": "-", "expected": "consumed", "level": "L1, L2",
                 "status": "ready (filter itself after task 2)"})
    negatives = []
    for j, r in enumerate(a.negative_resource, 2):
        negatives.append({"name": f"resource '{r}' is filtered out", "headers": {"resource": r}})
        rows.append({"id": f"S{j:02d}", "group": "selector", "proves": f"resource '{r}' is NOT consumed",
                     "input": "headers only (negative-cases.json)", "mocks": "-", "expected": "dropped by the subscription filter",
                     "level": "L2, L3", "status": "needs the selector from task 2"})
    for j, peer in enumerate(a.fanout_peer, 1):
        rows.append({"id": f"F{j:02d}", "group": "fan-out", "proves": f"the same event still reaches '{peer}'",
                     "input": "any P case", "mocks": f"second subscription standing in for {peer}",
                     "expected": "both subscriptions receive one copy", "level": "L2", "status": "ready for L2"})
    trailing = payloads.get("after_masking", {}).get("json-trailing", 0) + payloads.get("after_masking", {}).get("unparsed", 0)
    errors = [
        ("E01", "invalid JSON is routed like OSB routes it", "synthetic broken payload", "error path per OSB error handler"),
        ("E02", f"payloads with text after the JSON ({trailing} in export) are handled like OSB",
         "real masked messages (json-trailing)", "same as OSB: accepted or error"),
        ("E03", "backend timeout", "any P case", "retries / error queue per OSB (.bix + error handler)"),
        ("E04", "backend fault / HTTP 5xx", "any P case", "error queue with errorCode, errorMessage, traceId"),
        ("E05", "message without businessTransaction", "P case with businessTransaction=none, if present", "same as OSB"),
    ]
    for eid, proves, inp, exp in errors:
        rows.append({"id": eid, "group": "error", "proves": proves, "input": inp, "mocks": "WireMock fault / delay",
                     "expected": exp, "level": "L1, L2", "status": "needs the error handler from task 2"})
    rows.append({"id": "D01", "group": "delivery", "proves": "the same message twice gives the same result, once",
                 "input": "any P case sent twice", "mocks": "-", "expected": "per OSB (no dedup known)", "level": "L2",
                 "status": "ready for L2"})

    out = a.out or t / "TEST_CATALOG.md"
    cols = ["id", "group", "proves", "input", "mocks", "expected", "level", "status"]
    with (out.with_name("test-catalog.csv")).open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    (out.with_name("negative-cases.json")).write_text(json.dumps(negatives, indent=2, ensure_ascii=False), encoding="utf-8")
    md = [f"# Test catalogue — {flow}", "",
          f"{len(rows)} test cases: {sum(r['group'] == 'parity' for r in rows)} parity from the logs, the rest from the flow's "
          "contract. Levels: L1 Camel test with mock endpoints (Maven only), L2 real Artemis + WireMock in containers, "
          "L3 replay of the built integration.", "",
          "| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    md += ["| " + " | ".join(re.sub(r"\|", "/", str(r[c])) for c in cols) + " |" for r in rows]
    md += ["", f"Case folders checked: {sum(1 for _ in (t / 'fixtures/parity').glob('*/*/*/expected.json'))}, "
               f"problems: {len(broken)}"] + [f"- {b}" for b in broken[:30]]
    out.write_text("\n".join(md) + "\n", encoding="utf-8")
    print(json.dumps({"flow": flow, "test_cases": len(rows), "parity": sum(r["group"] == "parity" for r in rows),
                      "case_folders_with_problems": len(broken), "out": str(out)}))
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
