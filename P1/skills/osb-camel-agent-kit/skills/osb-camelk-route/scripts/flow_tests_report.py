#!/usr/bin/env python3
"""Tests report of one flow: every test that ran before Dev, by level, and the plan for the tests that need Dev.

    flow_tests_report.py modules/<project>/<proxy> -o <out dir>      -> <out>/TESTS.md + <out>/DEV_TEST_PLAN.md

TESTS.md levels (what already ran on the client machine):
  L1 functional   FlowParityTest: every masked / synthetic case reaches the output OSB used, same body, same backend call
  L2 error paths  FlowErrorTest: unreadable payload, backend fault, backend HTTP 500 -> OSB's error answer
  L3 test strength  route mutations the tests caught (MUTATION.json)
  L4 code gates   K1-K13 (GATES.json)
  L5 runtime      the route run as Camel K runs it, with Camel JBang: HTTP smoke (SMOKE.json) or JMS on the local Artemis
  L6 deploy file  camel-k/integration.yaml checked (camel-k/CHECK.json)
DEV_TEST_PLAN.md: the tests that cannot run locally (D0 deploy, D1 functional per scenario on Dev, D2 errors, D3 security
and logs, D4 side by side with OSB, D5 non-functional), with an empty Result column to fill in.
Reads surefire XML, flow-test.json, the case folder names and the result JSON files. Never reads or prints message
values: only test names, folder names, scenario keys, statuses and counts. Stdlib only."""
from __future__ import annotations

import argparse
import json
import xml.etree.ElementTree as ET
from pathlib import Path

WHAT = {   # test method -> what it proves, in one line
    "caseFoldersArePresent": "the test data is in place (at least one case per scenario folder)",
    "reachesTheSameOutputAsOsb": "the case ends at the same output as OSB (reply / queue), with the expected fields",
    "backendRequestsAsOsb": "the backend is called with OSB's method, path, query and headers",
    "correlationIdIsGeneratedWhenMissing": "a request without a correlation id still gets one, as in OSB",
    "bodyEqualsOriginalXQueryResult": "the body equals what OSB's own XQuery produces for this case",
    "unreadablePayloadGoesToTheErrorOutput": "a payload that cannot be read goes to OSB's error output",
    "unreadablePayloadTakesTheErrorPath": "unreadable payload -> error answer with errorCode / errorMessage / debugInfo",
    "backendFaultTakesTheErrorPath": "backend throws -> the same error answer as OSB",
    "backendHttpErrorTakesTheErrorPath": "backend answers HTTP 500 -> the same error answer as OSB",
    "flowTestConfigIsReadable": "the frozen expectations (flow-test.json) are readable",
}
LEVEL = {"FlowParityTest": "L1", "FlowErrorTest": "L2", "FlowJBangTest": "L5"}


def load(p: Path, default):
    try:
        return json.loads(p.read_text(encoding="utf-8")) if p.is_file() else default
    except (OSError, json.JSONDecodeError):
        return default


def surefire(mod: Path) -> list[dict]:
    rows = []
    for rep in sorted((mod / "target/surefire-reports").glob("TEST-*.xml")):
        try:
            root = ET.parse(rep).getroot()
        except ET.ParseError:
            continue
        for tc in root.iter("testcase"):
            cls = tc.get("classname", "").split(".")[-1]
            name = tc.get("name", "")
            method = name.split("(")[0].split("[")[0].strip()
            st = "FAIL" if tc.find("failure") is not None or tc.find("error") is not None else \
                 "skip" if tc.find("skipped") is not None else "pass"
            rows.append({"class": cls, "name": name, "method": method, "status": st, "level": LEVEL.get(cls, "L1")})
    return rows


def describe(row: dict) -> str:
    for k, v in WHAT.items():
        if k in row["name"] or k == row["method"]:
            return v
    return ""


def cases(mod: Path) -> list[tuple[str, int, int]]:
    """scenario folder -> (real cases, synthetic cases); folder names only."""
    root = mod / "src/test/resources/parity"
    out: dict[str, list[int]] = {}
    for f in root.glob("**/input.payload") if root.is_dir() else []:
        rel = f.parent.relative_to(root).parts
        scen = rel[0] if rel else "?"
        syn = "-synthetic" in f.as_posix()
        out.setdefault(scen, [0, 0])[1 if syn else 0] += 1
    return [(k, v[0], v[1]) for k, v in sorted(out.items())]


def count(rows, level):
    sel = [r for r in rows if r["level"] == level]
    f = sum(r["status"] == "FAIL" for r in sel)
    s = sum(r["status"] == "skip" for r in sel)
    return (f"{len(sel)} run, {f} failed, {s} skipped" if sel else "not run"), (f == 0 and bool(sel))


def tests_md(mod: Path, proj: str, proxy: str) -> str:
    rows = surefire(mod)
    cfg = load(mod / "src/test/resources/flow-test.json", {})
    gates = load(mod / "GATES.json", {})
    mut = load(mod / "MUTATION.json", {})
    smoke = load(mod / "SMOKE.json", {})
    e2e = load(mod / "target/e2e-result.json", {})
    chk = load(mod / "camel-k/CHECK.json", {})
    acc = load(mod / "LOCAL_ACCEPTANCE.json", {})
    http = bool(cfg.get("error_http_status")) or "reply" in (cfg.get("outputs") or {})

    l1, ok1 = count(rows, "L1")
    l2, ok2 = count(rows, "L2")
    g = gates.get("gates", {})
    l4 = f"{sum(bool(v.get('ok')) for v in g.values())}/{len(g)} gates ok" if g else "not run"
    l3 = f"{mut.get('killed', '-')}/{mut.get('total', '-')} mutations caught" if mut else "not run"
    if http:
        sc = smoke.get("cases") or []
        ec = smoke.get("error_case") or {}
        l5 = (f"{len(sc)} cases over HTTP, {sum(bool(c.get('problem')) for c in sc)} failed; backend 500 -> "
              f"{ec.get('status', '-')} ({'ok' if ec.get('ok') else 'FAIL'}); engine {smoke.get('engine', '-')}") if smoke else "not run"
        ok5 = bool(smoke.get("ok"))
    else:
        l5 = f"{e2e.get('cases', '-')} cases on the local Artemis" if e2e else "not run"
        ok5 = bool(e2e) and not e2e.get("failed")
    l6 = ("ready for review (per-environment values open)" if chk.get("for_review") else
          "ready" if chk.get("ready") else "checked, values open") if chk else "not generated"

    L = [f"# Tests: {proj} / {proxy}", "",
         "What was tested before Dev, on the client machine. Names and counts only: the test messages are masked and stay on the VDI.",
         f"Local acceptance: **{acc.get('result', 'not run')}**" + (f" ({acc.get('date')}, kit {acc.get('kit')})" if acc else ""), "",
         "## Summary by level", "",
         "| Level | What it proves | How it runs | Where | Result |", "|---|---|---|---|---|",
         f"| L1 functional | every case ends where OSB sent it, same fields, same backend call | Maven, route in-process, backends mocked | `module/src/test/java/**/FlowParityTest.java`, cases in `module/src/test/resources/parity/` | {l1} |",
         f"| L2 error paths | bad input and backend failures give OSB's error answer | Maven, mocks throw / answer 500 | `module/src/test/java/**/FlowErrorTest.java` | {l2} |",
         f"| L3 test strength | the tests fail when the route is broken on purpose | `mutate_route.py`, one change per run | `5-results/MUTATION.json` | {l3} |",
         f"| L4 code gates | route rules: no hosts/secrets, OSB names, safe logs and errors (K1-K13) | `verify_module.py` | `5-results/GATES.json` | {l4} |",
         f"| L5 runtime | the route really runs as Camel K runs it, called from outside | Camel JBang, stub backend{' over HTTP' if http else ', local Artemis'} | `4-acceptance/` | {l5} |",
         f"| L6 deploy file | integration.yaml structure, sources identical, secrets only as references | `check_manifest.py` | `6-deploy/` | {l6} |",
         "", "Not tested yet, needs Dev or OSB side by side: see `DEV_TEST_PLAN.md`.", ""]

    L += ["## L1 and L2: every test method", "", "| Level | Test | What it proves | Result |", "|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: (r["level"], r["class"], r["name"])):
        L.append(f"| {r['level']} | `{r['class']}` {r['name']} | {describe(r)} | {r['status']} |")
    if not rows:
        L.append("| - | no surefire reports (run the tests first) | | |")

    L += ["", "## Test data per scenario", "", "| Scenario folder | Real cases (masked Splunk) | Synthetic cases | Expected outputs |",
          "|---|---|---|---|"]
    exp = {str(x.get("scenario")): ", ".join(map(str, x.get("outputs") or [])) for x in cfg.get("scenario_mapping") or []}
    for scen, real, syn in cases(mod):
        key = scen.replace("-synthetic", "")
        L.append(f"| {scen} | {real} | {syn} | {exp.get(key, exp.get(scen, ''))} |")

    if mut:
        L += ["", "## L3: mutations", "", "| Change made to the route | Caught by a test |", "|---|---|"]
        L += [f"| {m_.get('what')} | {'yes' if m_.get('killed') else 'NO'} |" for m_ in mut.get("mutations", [])]
    if g:
        L += ["", "## L4: gates", "", "| Gate | Result |", "|---|---|"]
        L += [f"| {k} | {'ok' if v.get('ok') else 'FAIL'} |" for k, v in g.items()]
    if http and smoke:
        L += ["", "## L5: runtime run (Camel JBang)", "", "| Case | HTTP status | Result |", "|---|---|---|"]
        L += [f"| {c.get('case')} | {c.get('status')} | {'FAIL: ' + c['problem'] if c.get('problem') else 'pass'} |" for c in smoke.get("cases", [])]
        ec = smoke.get("error_case") or {}
        if ec:
            L.append(f"| backend forced to 500 | {ec.get('status')} (expected {ec.get('expected')}) | {'pass' if ec.get('ok') else 'FAIL'} |")
    return "\n".join(L) + "\n"


def dev_plan(mod: Path, proj: str, proxy: str) -> str:
    cfg = load(mod / "src/test/resources/flow-test.json", {})
    http = bool(cfg.get("error_http_status")) or "reply" in (cfg.get("outputs") or {})
    err = cfg.get("error_http_status", "-")
    backends = ", ".join(f"{k} ({v.get('type') or '?'})" for k, v in (cfg.get("backends") or {}).items()) or "none"
    scen = [x for x in cfg.get("scenario_mapping") or []]
    row = lambda i, what, how, ok: f"| {i} | {what} | {how} | {ok} | |"
    L = [f"# Dev test plan: {proj} / {proxy}", "",
         "The tests the client machine cannot run: a real cluster, a real backend, OSB answering the same request.",
         "Fill in Result (pass / fail + date + who). Record names, statuses and counts only, never message values.", "",
         f"Entry: {'HTTP request/reply' if http else 'JMS'}. Backends: {backends}. OSB error status: {err}.", "",
         "| # | Test | How | Pass when | Result |", "|---|---|---|---|---|",
         "| **D0** | **Deployment** | | | |",
         row("D0.1", "Integration builds and runs", "`oc get integration <name> -w`", "phase Running, no restarts"),
         row("D0.2", "Secret and config present", "`oc describe secret <name>-env` (key names and sizes only)", "all keys present, no CHANGE-ME left"),
         row("D0.3", "Backend reachable from the pod", "first real call, `oc logs`", "no PKIX / timeout / DNS error (internal CA, egress)"),
         "| **D1** | **Functional on Dev (one test record per scenario, from the backend team)** | | | |"]
    for i, x in enumerate(scen, 1):
        L.append(row(f"D1.{i}", "every request (one scenario)" if x.get("scenario") in ("*", "", None) else f"scenario `{x.get('scenario')}`", "send the Dev test record for this scenario",
                     f"ends at {', '.join(map(str, x.get('outputs') or []))}, fields filled as in L1"))
    if not scen:
        L.append(row("D1.1", "main scenario", "send a Dev test record", "same result as in L1"))
    L += ["| **D2** | **Errors on Dev** | | | |",
          row("D2.1", "unreadable payload", "send a body that is not " + str(cfg.get("payload_format", "json")),
              f"{'HTTP ' + str(err) if http else 'error queue'} with errorCode / errorMessage / debugInfo"),
          row("D2.2", "backend down or 4xx/5xx", "point one test at a wrong host, or ask for a failing record",
              f"{'HTTP ' + str(err) if http else 'error queue'}, error text without URL or query"),
          row("D2.3", "same error body as OSB", "compare with OSB's real error answer (isError body vs headers only)", "same shape, or the difference written in MIGRATION_NOTES.md"),
          "| **D3** | **Security and logs** | | | |",
          row("D3.1", "no secrets in logs", "`oc logs` during D1-D2, search for the secret names", "no API key / request id / source id values"),
          row("D3.2", "log lines as OSB", "compare log text and logName", "same text, correlation id on every line"),
          row("D3.3", "no backend headers leak to the caller" if http else "no transport headers on business queues", "`curl -v` / browse the queue", "only the expected headers"),
          "| **D4** | **Side by side with OSB (the proof)** | | | |",
          row("D4.1", "same requests to OSB and to the route", "20-50 records the backend team confirms in this environment", "replies identical except generated fields (traceId, timestamps)"),
          row("D4.2", "every difference explained", "list each differing key name", "bug fixed, or a written decision"),
          "| **D5** | **Non-functional (E2E / UAT)** | | | |",
          row("D5.1", "timeouts and retries as OSB", "slow backend (stub or test record)", "same timeout and retry count as the OSB business service"),
          row("D5.2", "latency at production rate", "small k6 run, OSB vs route", "p95 not worse than OSB"),
          row("D5.3", "restart and rollout", "delete the pod during traffic", "callers see a retryable error, no hang"),
          row("D5.4", "logs reach Splunk", "search the Dev/E2E index for the flow", "lines present with the correlation id"),
          "", "Order: D0 -> D1 -> D2 -> D3 on Dev; D4 on Dev or E2E; D5 on E2E/UAT before the switch. Sign-off after D4 and D5."]
    return "\n".join(L) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("module", type=Path)
    ap.add_argument("-o", "--out", type=Path, required=True)
    a = ap.parse_args()
    mod = a.module
    proxy, proj = mod.name, mod.parent.name
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / "TESTS.md").write_text(tests_md(mod, proj, proxy), encoding="utf-8")
    (a.out / "DEV_TEST_PLAN.md").write_text(dev_plan(mod, proj, proxy), encoding="utf-8")
    print(f"test catalogue: {a.out / 'TESTS.md'}, {a.out / 'DEV_TEST_PLAN.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
