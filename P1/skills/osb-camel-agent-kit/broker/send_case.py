#!/usr/bin/env python3
"""Sends ONE test case of a module to the local broker the way the OSB caller would: body = input.payload, message
properties = headers.json (strings). Destination = the address of flow.input in env/local.properties (topic:// for a
subscription queue, queue:// otherwise). Uses the Artemis CLI producer over AMQP. Stdlib only.

    send_case.py <module> <case-dir> [--count 1]
    send_case.py <module> --raw 'not json at all' [--headers '{"traceId":"t-1"}']     # an error case by hand

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


def destination(module: Path) -> str:
    for ln in (module / "env/local.properties").read_text(encoding="utf-8").splitlines():
        if ln.startswith("flow.input="):
            v = ln.split("=", 1)[1].strip()
            m = re.match(r"amqp:(queue|topic):([^?]+)", v)
            if not m:
                sys.exit(f"flow.input is not an amqp endpoint: {v}")
            name = m.group(2)
            if "::" in name:
                return "topic://" + name.split("::", 1)[0]
            return ("topic://" if m.group(1) == "topic" else "queue://") + name
    sys.exit("no flow.input in env/local.properties")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("case", type=Path, nargs="?")
    ap.add_argument("--raw", help="send this text instead of a case (error tests)")
    ap.add_argument("--headers", help="JSON object of message properties for --raw")
    ap.add_argument("--count", type=int, default=1)
    a = ap.parse_args()
    if a.raw is not None:
        body, headers = a.raw, json.loads(a.headers or "{}")
    elif a.case and (a.case / "input.payload").is_file():
        body = (a.case / "input.payload").read_text(encoding="utf-8").rstrip("\n")
        hf = a.case / "headers.json"
        headers = json.loads(hf.read_text(encoding="utf-8")) if hf.is_file() else {}
    else:
        sys.exit("give a case folder with input.payload, or --raw")
    props = [{"type": "string", "key": k, "value": str(v)} for k, v in headers.items() if isinstance(v, (str, int, float, bool))]
    home, pw = os.environ.get("ARTEMIS_HOME", ""), os.environ.get("ARTEMIS_PASSWORD", "")
    if not home or not pw:
        sys.exit("ARTEMIS_HOME / ARTEMIS_PASSWORD missing (run through send_case.sh)")
    dest = destination(a.module)
    cmd = [os.environ.get("JAVA", "java"), "-classpath", wpath(str(Path(home) / "lib/artemis-boot.jar")), "-Dartemis.home=" + wpath(home),
           "org.apache.activemq.artemis.boot.Artemis", "producer", "--protocol", "AMQP", "--destination", dest,
           "--message", body, "--properties", json.dumps(props), "--message-count", str(a.count),
           "--user", os.environ.get("ARTEMIS_USER", "artemis"), "--password", pw, "--url", os.environ.get("ARTEMIS_URL", "tcp://localhost:61616")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode or "Elapsed time" not in r.stdout + r.stderr:
        print((r.stdout + r.stderr).strip()[-600:])
        return 1
    print(f"sent {a.count} message(s) to {dest} with properties {[p['key'] for p in props]} ({len(body)} chars)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
