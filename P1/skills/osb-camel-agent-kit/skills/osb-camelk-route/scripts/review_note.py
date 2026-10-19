#!/usr/bin/env python3
"""Draft review handover note for flat delivery projects, with the numbers and the review points the kit can detect
filled in. Stdlib only. The author edits it (open points from people, name, channel) before sending.

    review_note.py <delivery/<app>> --projects 'a-prj|b-prj' [--modules <ws>/modules] [-o REVIEW_HANDOVER_DRAFT.md]

Reads per flat project: target/surefire-reports (mock tests), src/docs/<proxy>/E2E_ARTEMIS.txt (broker run of
e2e_local.sh), src/docs/<proxy>/GATES.json, the route file and the Java files; per module (optional): research.json
open questions. Detects: failing tests, failing gates other than K1, extra Java classes the agent added (and whether
the route uses them), route comments that call a draft card approved, cases the subscription selector filters,
selector properties the cases lack (filled in the broker run), queues that differ in the broker run."""
import argparse
import datetime
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def jbang_results(project: Path) -> dict | None:
    """test/RESULTS.txt of the no-pom layout (run-local.sh test): 'PASS/FAIL name' lines and 'N tests, M failed'."""
    f = project / "test/RESULTS.txt"
    if not f.is_file():
        return None
    t = f.read_text(encoding="utf-8", errors="replace")
    tot = [tuple(map(int, m)) for m in re.findall(r"^(\d+) tests, (\d+) failed", t, re.M)]
    failed = [ln[5:200] for ln in t.splitlines() if ln.startswith("FAIL ")]
    return {"ran": bool(tot), "tests": sum(a for a, _ in tot), "failures": sum(b for _, b in tot), "errors": 0, "skipped": 0,
            "failed": failed}


def surefire(project: Path) -> dict:
    t = f = e = s = 0
    failed = []
    for x in sorted((project / "target/surefire-reports").glob("TEST-*.xml")):
        r = ET.parse(x).getroot()
        t += int(r.get("tests", 0)); f += int(r.get("failures", 0)); e += int(r.get("errors", 0)); s += int(r.get("skipped", 0))
        for tc in r.iter("testcase"):
            bad = tc.find("failure") if tc.find("failure") is not None else tc.find("error")
            if bad is not None:
                msg = ((bad.get("message") or "").strip().splitlines() or [""])[0]
                failed.append(f"{tc.get('name', '')[:90]}: {msg[:160]}")
    return {"ran": t > 0, "tests": t, "failures": f, "errors": e, "skipped": s, "failed": failed}


def e2e(text: str) -> dict:
    if not text:
        return {}
    out = {"result": "", "inputs": [], "rows": [], "filtered": [], "filled": set()}
    for ln in text.splitlines():
        if ln.startswith("RESULT:"):
            out["result"] = ln[7:].strip()
        m = re.match(r"input of (\S+): subscription queue (\S+): (\d+) expected past the selector, (\S+) arrived", ln)
        if m:
            out["inputs"].append(m.groups())
        m = re.match(r"(\S+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(OK|DIFF)$", ln.strip())
        if m:
            out["rows"].append(m.groups())
        m = re.match(r"\s+(\S+) (\S+) -> expect \(filtered by the subscription selector\)", ln)
        if m:
            out["filtered"].append((m.group(1), m.group(2)))
        m = re.search(r"\(\+(.*?) for the selector\)", ln)
        if m:
            out["filled"].update(x.strip() for x in m.group(1).split(", ") if "=" in x)
    return out


def extra_classes(project: Path, flow: str) -> list[tuple[str, bool]]:
    route = "\n".join(p.read_text(encoding="utf-8") for p in project.glob("*-route.yaml"))
    props = (project / "application.properties").read_text(encoding="utf-8") if (project / "application.properties").is_file() else ""
    out = []
    for j in sorted(project.glob(f"{flow}*.java")):
        n = j.stem
        if n == f"{flow}Transformer" or n.endswith("Test") or "Test" in n:
            continue
        used = n in route or n in props or any(n in o.read_text(encoding="utf-8") for o in project.glob("*.java")
                                               if o != j and "Test" not in o.stem)        # used by production code only
        out.append((n, used))
    return out


def camel(proxy: str) -> str:
    return "".join(p[:1].upper() + p[1:] for p in re.split(r"[^A-Za-z0-9]+", proxy) if p)


def docs_dir(project: Path) -> Path:
    return project / "docs" if (project / "docs").is_dir() else project / "src/docs"


def flows_of(project: Path) -> list[str]:
    d = docs_dir(project)
    return sorted(x.name for x in d.iterdir() if x.is_dir()) if d.is_dir() else []


def project_section(project: Path, modules: Path | None) -> tuple[list[str], list[str]]:
    """(paragraphs about the project, review points)."""
    st = jbang_results(project) or surefire(project)
    flows = flows_of(project)
    route = "\n".join(p.read_text(encoding="utf-8") for p in project.glob("*-route.yaml"))
    text, points = [], []
    if not st["ran"]:
        text.append(f"For {project.name} the mock tests did not run (build error), see target/ of the project.")
        points.append(f"{project.name}: the mock tests did not compile or run; fix before sending.")
    else:
        text.append(f"For {project.name} the mock tests ran {st['tests']} tests with {st['failures'] + st['errors']} failing "
                    f"and {st['skipped']} skipped.")
        for fl in st["failed"][:5]:
            points.append(f"{project.name}: failing test {fl}")
    for flow in flows:
        docs = docs_dir(project) / flow
        ev = e2e((docs / "E2E_ARTEMIS.txt").read_text(encoding="utf-8", errors="replace") if (docs / "E2E_ARTEMIS.txt").is_file() else "")
        br = docs / "BROKER_RUN.txt"
        if br.is_file():
            t = br.read_text(encoding="utf-8", errors="replace")
            sent = len(re.findall(r"^send ", t, re.M))
            routed = re.findall(r"^\s*(\d+) (Sending to \S+|Error captured)", t, re.M)
            text.append(f"On the local Artemis (camel run with the Artemis kamelets) I sent {sent} case(s) of {flow}; the route log shows "
                        + (", ".join(f"{n} x {w.replace('Sending to ', 'sent to ')}" for n, w in routed) or "nothing routed")
                        + f". The queue counts are in docs/{flow}/BROKER_RUN.txt.")
            if "Error captured" in t:
                points.append(f"{flow}: in the broker run some messages went to the error queue, see the route log in BROKER_RUN.txt.")
            bc = docs / "BODY_CHAIN.md"
            if bc.is_file():
                todo = [ln[2:] for ln in bc.read_text(encoding="utf-8").splitlines() if ln.startswith("- ") and ln != "- nothing"]
                points += [f"{flow}: {x}" for x in todo]
            continue
        if not ev:
            text.append(f"The broker test for {flow} has not been run (no src/docs/{flow}/E2E_ARTEMIS.txt).")
            points.append(f"{flow}: broker test missing (e2e_local.sh).")
        else:
            past = [i for i in ev["inputs"] if i[0] == flow]
            rows = [r for r in ev["rows"] if r[0] == flow]
            s = f"On the local Artemis, for {flow}"
            if past:
                s += f" {past[0][3]} of {past[0][2]} messages got through the selector"
            s += "; " + ", ".join(f"{r[3]} of {r[2]} arrived on {r[1]}" for r in rows) + f". Result: {ev['result'] or 'no result line'}."
            text.append(s)
            for r in rows:
                if r[4] == "DIFF":
                    points.append(f"{flow}: broker run, {r[1]} expected {r[2]} but {r[3]} arrived.")
            filt = [c for f_, c in ev["filtered"] if f_ == flow]
            if filt:
                points.append(f"{flow}: the subscription selector filters test cases taken from the logs for this proxy "
                              f"({', '.join(filt)}). Either the selector in the export is outdated or those cases do not belong here.")
            if ev["filled"]:
                props_ = sorted({x.split("=", 1)[0] for x in ev["filled"]})
                points.append(f"{flow}: some test cases lack {', '.join(props_)}, which the selector needs (OSB does not log "
                              f"it); the broker test set {', '.join(sorted(ev['filled']))}. Please confirm these values are realistic.")
        g = docs / "GATES.json"
        if g.is_file():
            gates = json.loads(g.read_text(encoding="utf-8")).get("gates", {})
            bad = [k for k, v in gates.items() if not v.get("ok") and k != "K1_card_approved"]
            if bad:
                points.append(f"{flow}: gates not passed: {', '.join(bad)}.")
            if not gates.get("K1_card_approved", {}).get("ok") and re.search(r"approved FLOW_CARD", route, re.I):
                points.append(f"{flow}: the route comments call the flow card approved, but it is a draft until this review.")
        for n, used in extra_classes(project, camel(flow)):
            points.append(f"{flow}: the agent added {n}.java; " + ("the route or another class uses it, please review it."
                                                                  if used else "nothing refers to it, remove it."))
        if modules:
            for r in (modules.parent / "research").glob(f"*/{flow}/research.json"):
                oq = json.loads(r.read_text(encoding="utf-8")).get("open_questions") or []
                if oq:
                    points.append(f"{flow}: {len(oq)} open question(s) from the research pack (RESEARCH.md).")
    return text, points


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("app", type=Path)
    ap.add_argument("--projects", default=".*")
    ap.add_argument("--modules", type=Path)
    ap.add_argument("-o", "--out", type=Path)
    a = ap.parse_args()
    projects = [p for p in sorted(a.app.iterdir()) if p.is_dir() and p.name != "Common-setup" and re.fullmatch(a.projects, p.name)]
    if not projects:
        print(f"no delivery projects matching '{a.projects}' in {a.app}")
        return 2
    flows = [(p.name, f) for p in projects for f in flows_of(p)]
    today = datetime.date.today().isoformat()
    paras, points = [], []
    for p in projects:
        t, pt = project_section(p, a.modules)
        paras += t
        points += pt
    names = " and ".join(f"{p} (proxy {f})" for p, f in flows)
    lines = [
        "<!-- DRAFT written by review_note.py. Check every sentence, add what only people know, then send. -->",
        "", "Hi all,", "",
        f"I am handing over {len(flows)} flow(s) from {a.app.name} for review: {names}. The routes are generated from the OSB "
        "export (pipeline, XQuery and nXSD files), and I tested them against frozen test cases taken from the Splunk logs (masked) and against a "
        "local Artemis broker. The flow cards are drafts, I would like this review to approve them or tell me what to change.", "",
        f"The archive is {a.app.name}_review_{today}.tgz. There is no pom: each OSB project folder has the route file "
        "<domain>-route.yaml (the Camel K integration), application.properties with the endpoints (OSB JNDI names, broker from "
        "BROKER_URL, BROKER_USER and BROKER_PASSWORD), local.properties for a local Artemis, transformations/ with OSB's own "
        ".xqy and nXSD files unchanged, test/ with one test file per flow, and docs/<proxy>/ with the flow card, BODY_CHAIN.md "
        "and the broker run. Common-setup holds the two Artemis kamelets (core JMS; the source opens the durable subscription "
        "with the OSB selector) and the two shared Java helpers with //DEPS (nXSD JSON to XML, and the XQuery engine).", "",
        "What the route does to the body is not written by hand or by the agent: it is read from each OSB pipeline "
        "(docs/<proxy>/BODY_CHAIN.md) and runs OSB's own files, so a flow that sends XML after its XQuery sends the same XML, "
        "and the error queue gets the original message as OSB's $request.", "",
        "bash run-local.sh test runs the tests with jbang and needs no broker and no connection factory: every endpoint is "
        "replaced by direct:/mock:. They check that every case reaches exactly the queue OSB used and no other, the original "
        "message and the error headers on the error queue, no transport headers on the business queues, well-formed XML where "
        "OSB sends XML, and equality with OSB's real output where an expected-output.xml exists. bash run-local.sh run starts "
        "the routes with camel run against a local Artemis; send and stat are described in RUN_LOCAL.md.", "",
        *[p + "\n" for p in paras],
        "Not tested yet: deployment with the Camel K operator, the production mapping of the JNDI names to broker addresses, "
        "the subscription queue on the real broker, load, broker failover, redelivery after a real broker outage, TLS and "
        "credentials from the vault, the real consumers of the output queues, and a side by side run with OSB.", "",
    ]
    if points:
        lines += ["There are a few things I need your view on:", ""] + [f"- {x}" for x in points] + [""]
    lines += [
        "From the review I would like a check of the route logic against the OSB proxies (stages, branches, error handler), "
        "your answers on the points above, approval of the flow cards in docs/<proxy>/FLOW_CARD.md or a list of changes, "
        "and your opinion on the layout.", "",
        "The test cases are masked log data and the docs contain the original XQuery logic, so please keep the archive on the "
        "client's systems.", "", "Thanks,", "<name>", ""]
    out = a.out or a.app / "REVIEW_HANDOVER_DRAFT.md"
    out.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print(json.dumps({"note": str(out), "flows": len(flows), "review_points": len(points)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
