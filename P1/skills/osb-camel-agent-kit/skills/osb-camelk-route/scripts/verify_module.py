#!/usr/bin/env python3
"""mvn test + gates for ONE module, with a SHORT answer: what an agent needs to fix, nothing else. Stdlib only.

    verify_module.py modules/<project>/<proxy> [--mvn "mvn -B -q -s ~/.m2/settings.xml"] [--max 8]

Why: an agent re-sends its whole conversation with every model call. The full Maven output (Camel logs of every test)
is hundreds of KB; once it is in the conversation it is paid for on every later call, which is what exhausts the model
endpoint's token quota. This script writes the full output to target/verify-mvn.log and prints at most ~30 lines:
totals, the failing tests (name + first line of the message, cut at 200 characters), the failing gates.
Exit 0 = tests green and gates PASS except K1 (approval is a person's step), 1 = something to fix, 2 = could not run."""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def win_path(arg: str) -> str:
    """Git Bash path (/c/Users/x) -> Windows path (c:/Users/x) when running natively on Windows; else unchanged."""
    return re.sub(r"^/([a-zA-Z])/", r"\1:/", arg) if os.name == "nt" else arg


SCALAR_KEYS = ("message", "uri", "logName", "loggingLevel", "beanType", "method", "id")


def yaml_lint(text: str) -> list[str]:
    """Structure mistakes models make in Camel YAML routes that make the WHOLE route fail to load (every test errors
    with one cryptic line). Line-based, no YAML library: a scalar key left empty with a block below it
    (`message:` + `simple: "..."`), and `steps:` next to `from:` instead of under it."""
    out, lines = [], text.splitlines()
    ind = lambda s: len(s) - len(s.lstrip(" "))  # noqa: E731
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.startswith("#") or not s:
            continue
        m = re.match(r"^-?\s*(\w+):\s*$", s)
        if m and m.group(1) in SCALAR_KEYS:
            nxt = next((x for x in lines[i + 1:] if x.strip() and not x.strip().startswith("#")), "")
            if ind(nxt) > ind(ln):
                out.append(f"line {i + 1}: '{m.group(1)}:' must be a plain value on the same line "
                           f"(e.g. {m.group(1)}: \"...${{body}}\"), not a block with '{nxt.strip().split(':')[0]}:' below")
        if s == "steps:":
            prev = next((x for x in reversed(lines[:i]) if x.strip() and not x.strip().startswith("#")), "")
            frm = next((x for x in reversed(lines[:i]) if x.strip() == "from:"), None)
            if frm is not None and ind(frm) == ind(ln) and not prev.strip().startswith("- "):
                out.append(f"line {i + 1}: route 'steps:' belongs UNDER 'from:' (indent it below from:)")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--mvn", default=os.environ.get("VERIFY_MVN", "mvn -B -q " + os.environ.get("MVN_ARGS", "")))
    ap.add_argument("--max", type=int, default=8, help="failing tests listed")
    a = ap.parse_args()
    mod = a.module
    args = [win_path(os.path.expanduser(x)) for x in shlex.split(a.mvn)]
    exe = shutil.which(args[0]) or shutil.which(args[0] + ".cmd")
    if not exe:
        print(f"cannot find {args[0]} on PATH")
        return 2
    lint = [f"{p.name} {x}" for p in sorted((mod / "src/main/resources/routes").glob("*.yaml")) for x in yaml_lint(p.read_text(encoding="utf-8"))]
    if lint:                            # the route would not load: every test errors; say where, before a Maven run
        print(f"ROUTE YAML STRUCTURE ({len(lint)}): fix these lines first, the route cannot load")
        for x in lint[:a.max]:
            print("  " + x)
        print("FIX NEEDED")
        return 1
    rep = mod / "target/surefire-reports"
    if rep.is_dir():
        for f in rep.glob("TEST-*.xml"):
            f.unlink()
    (mod / "target").mkdir(exist_ok=True)
    log = mod / "target/verify-mvn.log"
    env = dict(os.environ)
    if os.name == "nt" and env.get("JAVA_HOME"):
        env["JAVA_HOME"] = win_path(env["JAVA_HOME"])          # mvn.cmd needs C:/..., Git Bash exports /c/...
    r = subprocess.run([exe] + args[1:] + ["-f", str(mod / "pom.xml"), "clean", "test"], capture_output=True, text=True,
                       errors="replace", env=env)
    log.write_text(r.stdout + r.stderr, encoding="utf-8")
    t = f = e = s = 0
    fails = []
    for x in sorted(rep.glob("TEST-*.xml")) if rep.is_dir() else []:
        root = ET.parse(x).getroot()
        t += int(root.get("tests", 0)); f += int(root.get("failures", 0)); e += int(root.get("errors", 0)); s += int(root.get("skipped", 0))
        for tc in root.iter("testcase"):
            bad = tc.find("failure") if tc.find("failure") is not None else tc.find("error")
            if bad is not None:
                msg = (bad.get("message") or bad.get("type") or "").strip().splitlines()
                fails.append(f"{tc.get('classname', '').split('.')[-1]}.{tc.get('name')}: {(msg[0] if msg else '')[:200]}")
    if t == 0:
        out = [re.sub(r"\x1b\[[0-9;]*m", "", ln).strip() for ln in (r.stdout + r.stderr).splitlines()]
        lines = [ln for ln in out if re.search(r"ERROR|[Ee]rror:|Caused by|cannot find|does not exist|not defined", ln)]
        lines = lines or [ln for ln in out if ln][-15:]        # never an empty answer: the agent needs a reason
        print(f"BUILD/COMPILE FAILED (no test ran, maven exit {r.returncode}). First errors:")
        for ln in lines[:15] or ["(maven printed nothing: is mvn 3.9 / JAVA_HOME right? run the same mvn by hand)"]:
            print("  " + ln[:220])
        print(f"full output: {log}")
        return 1
    print(f"tests {t}, failures {f}, errors {e}, skipped {s}")
    for x in fails[: a.max]:
        print("  FAIL " + x)
    if len(fails) > a.max:
        print(f"  ... {len(fails) - a.max} more (full output: {log})")
    g = subprocess.run([sys.executable, str(Path(__file__).with_name("check_camelk.py")), str(mod)], capture_output=True, text=True)
    gates = json.loads((mod / "GATES.json").read_text(encoding="utf-8"))["gates"] if (mod / "GATES.json").is_file() else {}
    bad_gates = {k: v for k, v in gates.items() if not v.get("ok") and k != "K1_card_approved"}
    for k, v in bad_gates.items():
        print(f"  GATE {k} " + json.dumps({x: y for x, y in v.items() if x != "ok"})[:220])
    ok = f == 0 and e == 0 and not bad_gates
    print("PASS (K1 = approval, a person's step)" if ok else "FIX NEEDED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
