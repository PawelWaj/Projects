#!/usr/bin/env python3
"""Step 5: replay recorded OSB traffic against the Camel flow under test, through the mock architecture.

For every fixture written by fixtures_from_traces.py: publish input.payload with headers.json to the flow's input
address (so the broker-side subscription filter is exercised too), wait for the message that carries the same
correlation id on one of the flow's output destinations, and check:
  - it arrived on the destination of the expected outcome (success queue or error queue);
  - the headers listed in expected.json are present (error path: errorCode, errorMessage, traceId, ...);
  - if expected-output.xml exists next to the fixture (produced by the ORIGINAL XQuery, golden test), the body equals it
    after XML canonicalisation.
Negative cases from replay-config.json (messages the subscription filter must drop) expect NO output within the timeout.
They come from the proxy configuration, not from the logs: OSB never logs a message its selector rejected.

Writes a JSON report and a JUnit XML file (for Jenkins). Broker access is STOMP through stomp.py (pip install stomp.py);
the Broker class is the only network code, so the logic is unit-tested with a fake broker.

Usage: replay_runner.py replay-config.json fixtures/ [-o report/] [--flow <flow>] [--no-negative]
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import re
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape


def slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-").lower()[:80]


class StompBroker:
    """Artemis via STOMP. destination-type tells Artemis whether a name is an anycast queue or a multicast address."""

    def __init__(self, host: str, port: int, user: str, password: str):
        import stomp  # imported here so the rest of the module works without it
        self._inbox: queue.Queue = queue.Queue()
        outer = self

        class _Listener(stomp.ConnectionListener):
            def on_message(self, frame):
                outer._inbox.put((frame.headers.get("destination", ""), dict(frame.headers), frame.body))

        self.conn = stomp.Connection([(host, port)])
        self.conn.set_listener("replay", _Listener())
        self.conn.connect(user, password, wait=True)
        self._sub = 0

    def subscribe(self, destination: str, dtype: str) -> None:
        self._sub += 1
        self.conn.subscribe(destination=destination, id=str(self._sub), ack="auto",
                            headers={"destination-type": dtype.upper(), "subscription-type": dtype.upper()})

    def send(self, destination: str, dtype: str, body: str, headers: dict) -> None:
        self.conn.send(destination=destination, body=body,
                       headers={**headers, "destination-type": dtype.upper(), "persistent": "true"})

    def receive(self, timeout: float):
        try:
            return self._inbox.get(timeout=timeout)
        except queue.Empty:
            return None

    def close(self) -> None:
        self.conn.disconnect()


def canonical(xml_text: str) -> str:
    return ET.canonicalize(xml_text.strip(), strip_text=True)


def find_fixtures(root: Path, flow: str) -> list[Path]:
    base = root / "parity" / slug(flow)
    return sorted(p.parent for p in base.rglob("input.payload")) if base.is_dir() else []


def wait_for(broker, corr: str, corr_header: str, timeout: float, seen: list) -> tuple | None:
    """Return the first message carrying the correlation id (header or body); keep others for later fixtures."""
    for i, msg in enumerate(seen):
        if msg[1].get(corr_header) == corr or corr in (msg[2] or ""):
            return seen.pop(i)
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = broker.receive(max(0.1, deadline - time.time()))
        if msg is None:
            break
        if msg[1].get(corr_header) == corr or corr in (msg[2] or ""):
            return msg
        seen.append(msg)
    return None


def run_flow(broker, flow: str, fc: dict, fixtures: list[Path], negative: bool) -> list[dict]:
    corr_header = fc.get("correlation_header", "traceId")
    inp = fc["input"]
    timeout = float(fc.get("timeout_s", 15))
    dest_by_name = {o["destination"]: outcome for outcome, o in fc["outputs"].items()}
    for o in fc["outputs"].values():
        broker.subscribe(o["destination"], o.get("type", "anycast"))
    results, backlog = [], []
    for fx in fixtures:
        exp = json.loads((fx / "expected.json").read_text(encoding="utf-8"))
        headers = json.loads((fx / "headers.json").read_text(encoding="utf-8"))
        body = (fx / "input.payload").read_text(encoding="utf-8")
        corr = headers.get(corr_header) or exp["correlation"]
        t0 = time.time()
        broker.send(inp["address"], inp.get("type", "multicast"), body, headers)
        msg = wait_for(broker, corr, corr_header, timeout, backlog)
        r = {"flow": flow, "case": f"{fx.parent.name}/{fx.name}", "expected_outcome": exp["outcome"], "problems": []}
        if msg is None:
            r["problems"].append(f"no output within {timeout:.0f}s")
        else:
            dest = msg[0].split("::")[0].split("/")[-1]
            got = dest_by_name.get(dest, f"unexpected destination {dest}")
            r["actual_outcome"] = got
            if got != exp["outcome"]:
                r["problems"].append(f"outcome {got}, expected {exp['outcome']}")
            missing = [h for h in exp.get("expected_headers", []) if h not in msg[1]]
            if missing:
                r["problems"].append("missing headers: " + ", ".join(missing))
            golden = fx / "expected-output.xml"
            if golden.exists() and got == "success":
                try:
                    if canonical(msg[2]) != canonical(golden.read_text(encoding="utf-8")):
                        r["problems"].append("body differs from expected-output.xml (original transform)")
                except ET.ParseError as exc:
                    r["problems"].append(f"body is not XML: {exc}")
        r["seconds"] = round(time.time() - t0, 2)
        r["status"] = "PASS" if not r["problems"] else "FAIL"
        results.append(r)
    if negative:
        for case in fc.get("negative_cases", []):
            corr = f"negative-{uuid.uuid4()}"
            headers = {**case["headers"], corr_header: corr}
            broker.send(inp["address"], inp.get("type", "multicast"), "{}", headers)
            msg = wait_for(broker, corr, corr_header, min(timeout, 5.0), backlog)
            results.append({"flow": flow, "case": "negative: " + case["name"], "expected_outcome": "dropped by filter",
                            "problems": [] if msg is None else [f"message was delivered to {msg[0]}"],
                            "status": "PASS" if msg is None else "FAIL"})
    return results


def junit(results: list[dict]) -> str:
    fails = sum(1 for r in results if r["status"] == "FAIL")
    cases = []
    for r in results:
        name = escape(r["case"], {'"': "&quot;"})
        inner = "" if r["status"] == "PASS" else f'<failure message="{escape("; ".join(r["problems"]), {chr(34): "&quot;"})}"/>'
        cases.append(f'  <testcase classname="{escape(r["flow"])}" name="{name}" time="{r.get("seconds", 0)}">{inner}</testcase>')
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="osb-log-replay" tests="{len(results)}" failures="{fails}">\n'
            + "\n".join(cases) + "\n</testsuite>\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("config", type=Path)
    ap.add_argument("fixtures", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=Path("replay-report"))
    ap.add_argument("--flow")
    ap.add_argument("--no-negative", action="store_true")
    args = ap.parse_args()
    cfg = json.loads(args.config.read_text(encoding="utf-8"))
    b = cfg["broker"]
    broker = StompBroker(os.environ.get("BROKER_HOST", b["host"]), int(os.environ.get("BROKER_STOMP_PORT", b["stomp_port"])),
                         b["user"], os.environ.get(b.get("password_env", "ARTEMIS_PASSWORD"), ""))
    results = []
    try:
        for flow, fc in cfg["flows"].items():
            if args.flow and flow != args.flow:
                continue
            fx = find_fixtures(args.fixtures, flow)
            print(f"{flow}: {len(fx)} fixtures")
            results += run_flow(broker, flow, fc, fx, not args.no_negative)
    finally:
        broker.close()
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "report.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    (args.out / "junit.xml").write_text(junit(results), encoding="utf-8")
    fails = [r for r in results if r["status"] == "FAIL"]
    for r in fails:
        print("FAIL", r["case"], "|", "; ".join(r["problems"]))
    print(f"{len(results) - len(fails)}/{len(results)} passed -> {args.out}")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
