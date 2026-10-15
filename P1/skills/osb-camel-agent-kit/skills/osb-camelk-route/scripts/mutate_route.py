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
Writes MUTATION.json (what, killed) next to the pom. Exit 1 if any mutation survived, 2 if the check could not run."""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


def win_path(arg: str) -> str:
    """Git Bash path (/c/Users/x) -> Windows path (c:/Users/x) when running natively on Windows; else unchanged."""
    return re.sub(r"^/([a-zA-Z])/", r"\1:/", arg) if os.name == "nt" else arg


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
    a.mvn = " ".join(shlex.quote(win_path(os.path.expanduser(x))) for x in shlex.split(a.mvn))   # ~ and /c/... paths
    first = shlex.split(a.mvn)[0]
    exe = shutil.which(first) or shutil.which(first + ".cmd")   # Windows: Maven is mvn.cmd, subprocess needs the full name
    if not exe:
        print(f"cannot find '{first}' on PATH (Maven 3.9 must be on PATH)")
        return 2
    a.mvn = " ".join([shlex.quote(exe)] + [shlex.quote(x) for x in shlex.split(a.mvn)[1:]])
    routes = sorted((a.module / "src/main/resources/routes").glob("*.camel.yaml"))
    if not routes:
        sys.exit("no *.camel.yaml route in the module")
    base = subprocess.run(shlex.split(a.mvn) + ["-f", str(a.module / "pom.xml"), "test"], capture_output=True, text=True)
    if base.returncode:
        print("tests are not green on the unchanged route: fix that first (mutation check needs a green baseline)")
        return 2
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
