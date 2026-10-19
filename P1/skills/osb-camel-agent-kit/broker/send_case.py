#!/usr/bin/env python3
"""Sends ONE test case of a module to the local broker the way the OSB caller would: body = input.payload, message
properties = headers.json (strings). Destination = the address of flow.input in env/local.properties (topic:// for a
subscription queue, queue:// otherwise). Uses the Artemis CLI producer over AMQP. Stdlib only.

    send_case.py <module> <case-dir> [--count 1]
    send_case.py <module> --raw 'not json at all' [--headers '{"traceId":"t-1"}']     # an error case by hand
    send_case.py <flat project> --flow <proxy> <case-dir>                              # flat project: which flow

Env (exported by send_case.sh / lib.sh): JAVA, ARTEMIS_HOME, ARTEMIS_URL, ARTEMIS_USER, ARTEMIS_PASSWORD, WIN."""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def wpath(p: str) -> str:
    if os.environ.get("WIN") == "1":
        return subprocess.run(["cygpath", "-w", p], capture_output=True, text=True).stdout.strip()
    return p


def destination(module: Path, flow: str | None) -> str:
    f = module / "env/local.properties"
    f = f if f.is_file() else module / "src/env/local.properties"
    inputs = {}
    for ln in f.read_text(encoding="utf-8").splitlines():
        k, _, v = ln.partition("=")
        if k == "flow.input" or k.endswith(".flow.input"):
            inputs[k[: -len(".flow.input")] if k != "flow.input" else ""] = v.strip()
    if not inputs:
        sys.exit(f"no flow.input in {f}")
    if flow is None and len(inputs) > 1:
        sys.exit("this project has several flows: --flow " + " | --flow ".join(sorted(inputs)))
    v = inputs.get(flow or "", inputs.get(flow)) if flow else next(iter(inputs.values()))
    if v is None:
        sys.exit(f"no flow {flow}: " + ", ".join(sorted(inputs)))
    km = re.match(r"kamelet:osb-jms-source\?destination=(.+)$", v)
    v = "amqp:" + km.group(1) if km else v
    m = re.match(r"amqp:(queue|topic):([^?]+)", v)
    if not m:
        sys.exit(f"flow input is not an amqp endpoint: {v}")
    name = m.group(2)
    if "::" in name:
        return "topic://" + name.split("::", 1)[0]
    return ("topic://" if m.group(1) == "topic" else "queue://") + name


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("case", type=Path, nargs="?")
    ap.add_argument("--raw", help="send this text instead of a case (error tests)")
    ap.add_argument("--headers", help="JSON object of message properties for --raw")
    ap.add_argument("--count", type=int, default=1)
    ap.add_argument("--flow", help="flat project with several flows: the proxy whose input gets the message")
    ap.add_argument("--fill-selector", action="store_true",
                    help="add the properties the subscription selector needs but the case lacks (OSB does not log them)")
    a = ap.parse_args()
    if a.raw is not None:
        body, headers = a.raw, json.loads(a.headers or "{}")
    elif a.case and (a.case / "input.payload").is_file():
        body = (a.case / "input.payload").read_text(encoding="utf-8").rstrip("\n")
        hf = a.case / "headers.json"
        headers = json.loads(hf.read_text(encoding="utf-8")) if hf.is_file() else {}
    else:
        sys.exit("give a case folder with input.payload, or --raw")
    filled = {}
    if a.fill_selector:
        sys.path.insert(0, str(Path(__file__).parent))
        from e2e_check import fill_for_selector, selector_of
        filled = fill_for_selector(selector_of(a.module, a.flow or a.module.name), headers)
        headers = {**headers, **filled}
    props = [{"type": "string", "key": k, "value": str(v)} for k, v in headers.items() if isinstance(v, (str, int, float, bool))]
    home, pw = os.environ.get("ARTEMIS_HOME", ""), os.environ.get("ARTEMIS_PASSWORD", "")
    if not home or not pw:
        sys.exit("ARTEMIS_HOME / ARTEMIS_PASSWORD missing (run through send_case.sh)")
    dest = destination(a.module, a.flow)
    cmd = [os.environ.get("JAVA", "java"), "-classpath", wpath(str(Path(home) / "lib/artemis-boot.jar")), "-Dartemis.home=" + wpath(home),
           "org.apache.activemq.artemis.boot.Artemis", "producer", "--protocol", "AMQP", "--destination", dest,
           "--message", body, "--properties", json.dumps(props), "--message-count", str(a.count),
           "--user", os.environ.get("ARTEMIS_USER", "artemis"), "--password", pw, "--url", os.environ.get("ARTEMIS_URL", "tcp://localhost:61616")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode or "Elapsed time" not in r.stdout + r.stderr:
        print((r.stdout + r.stderr).strip()[-600:])
        return 1
    print(f"sent {a.count} message(s) to {dest}" + (f" (+{', '.join(f'{k}={v}' for k, v in filled.items())} for the selector)" if filled else "")
          + f" with properties {[p['key'] for p in props]} ({len(body)} chars)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
