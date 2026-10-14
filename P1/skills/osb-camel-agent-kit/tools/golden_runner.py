#!/usr/bin/env python3
"""Golden runner: the ORACLE for transformations, produced deterministically BEFORE any route code exists.

    golden_runner.py run   <resources> --transform <orig.xqy|orig.xsl> [--shim fn-bea-shim.xqy] [--saxon Saxon-HE.jar]
                           [--flow <flow>] [--param name=file ...] [--captured-by <who>]
    golden_runner.py check <resources>

`run` executes the ORIGINAL OSB XQuery/XSLT (Saxon command line) on every parity/<flow>/**/input.payload that is XML,
writes expected-output.xml next to it, registers the file in golden/MANIFEST.csv (source original-transform, sha256)
and writes golden/ORACLE.lock with the sha256 of input, transform, shim and output per case. Inputs that are not XML
(JSON before an nXSD translation), transforms that need fn-bea functions the shim does not provide, or external
variables that cannot be bound are recorded as `oracle-blocked` (status in the lock, exit code 3): the fallback is
the OSB Test Console (source osb-test-console), never a hand-written file.

`check` (gate G10) recomputes the hashes and fails on any change: an expected-output.xml edited by hand or produced
by the migrated code no longer matches the lock. No Java needed for check.

Binding: every external variable of the query is bound with Saxon's `+name=file` (document node); `$body` defaults to
the input itself. Queries that use `fn-bea:` get the shim module imported into a temporary copy (the ORIGINAL file is
what the lock hashes). The current date/time is fixed per case to the recorded event time when headers.json carries
`eventTime` (ISO) so date-dependent transforms are reproducible. Stdlib only; Saxon-HE from --saxon, $SAXON_JAR or
~/.m2 (net/sf/saxon/Saxon-HE)."""
import argparse
import csv
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))

FN_BEA_NS = "http://www.bea.com/xquery/xquery-functions"
LOCK = "ORACLE.lock"
MANIFEST_COLS = ["file", "source", "flow", "captured_by", "date", "sha256", "key_id", "source_ref", "reason", "approved_by"]


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def find_saxon(explicit: str | None) -> Path | None:
    cands = [Path(x) for x in [explicit or "", os.environ.get("SAXON_JAR", "")] if x]
    m2 = Path.home() / ".m2" / "repository" / "net" / "sf" / "saxon" / "Saxon-HE"
    if m2.is_dir():
        cands += sorted(m2.glob("*/Saxon-HE-*.jar"), key=lambda p: [int(x) if x.isdigit() else x for x in re.split(r"[.-]", p.parent.name)])[::-1]
    return next((c for c in cands if c.is_file()), None)


def externals(query: str) -> list[str]:
    return re.findall(r"declare\s+variable\s+\$([\w.-]+)[^;]*?\bexternal\s*;", query)


def prepare_query(orig: Path, shim: Path | None, tmp: Path, bindings: dict[str, Path] | None = None) -> Path:
    """Per-case copy of the original: externals bound to files become `declare variable $x := doc("file")/*;`
    (OSB binds elements, Saxon's +param binds document nodes), and the fn-bea shim is imported when fn-bea: is used.
    The ORIGINAL file is never modified; the lock hashes the original."""
    text = orig.read_text(encoding="utf-8")
    for name, path in (bindings or {}).items():
        text, n = re.subn(r"declare\s+variable\s+\$" + re.escape(name) + r"\b[^;]*?\bexternal\s*;",
                          f'declare variable ${name} := doc("{path.resolve().as_uri()}")/*;', text, count=1)
    if "fn-bea:" in text and shim:
        text = re.sub(r"declare\s+namespace\s+fn-bea\s*=\s*\"[^\"]*\"\s*;", "", text)
        imp = f'import module namespace fn-bea = "{FN_BEA_NS}" at "{shim.resolve().as_uri()}";\n'
        m = re.match(r"\s*xquery\s+version\s+\"[^\"]*\"\s*(encoding\s+\"[^\"]*\"\s*)?;", text)
        text = (text[:m.end()] + "\n" + imp + text[m.end():]) if m else imp + text
    tmp.mkdir(parents=True, exist_ok=True)
    out = tmp / orig.name
    out.write_text(text, encoding="utf-8")
    return out


def classpath(saxon: Path) -> str:
    """Saxon-HE 12 needs org.xmlresolver (xmlresolver + xmlresolver-data) on the classpath; taken from ~/.m2 or $SAXON_CP."""
    extra = [Path(x) for x in os.environ.get("SAXON_CP", "").split(os.pathsep) if x]
    m2 = Path.home() / ".m2" / "repository" / "org" / "xmlresolver" / "xmlresolver"
    if m2.is_dir():
        extra += sorted(m2.glob("*/xmlresolver-*.jar"))[-2:]
    return os.pathsep.join(str(p) for p in [saxon, *extra] if p.is_file())


def run_saxon(saxon: Path, transform: Path, inp: Path, out: Path, params: dict[str, Path], now: str | None) -> tuple[int, str]:
    cp = classpath(saxon)
    if transform.suffix.lower() in (".xsl", ".xslt"):
        cmd = ["java", "-cp", cp, "net.sf.saxon.Transform", f"-s:{inp}", f"-xsl:{transform}", f"-o:{out}"]
    else:   # externals are already bound inside the prepared copy (prepare_query); nothing passed with +param
        cmd = ["java", "-cp", cp, "net.sf.saxon.Query", f"-q:{transform}", f"-o:{out}", "!indent=yes"]
    if now:
        cmd.append(f"-now:{now}")
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, (r.stderr or r.stdout)[-800:]


def load_manifest(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    with path.open(encoding="utf-8", newline="") as fh:
        return [dict(r) for r in csv.DictReader(fh)]


def write_manifest(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=MANIFEST_COLS, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({c: r.get(c, "") for c in MANIFEST_COLS})


def cmd_run(a) -> int:
    res: Path = a.resources
    transform: Path = a.transform
    shim = a.shim if a.shim and a.shim.is_file() else None
    saxon = find_saxon(a.saxon)
    if not saxon:
        print(json.dumps({"status": "ERROR", "detail": "Saxon-HE jar not found: pass --saxon, set SAXON_JAR, or run "
                          "'mvn dependency:get -Dartifact=net.sf.saxon:Saxon-HE:12.9' through the mirror"}))
        return 2
    cases = sorted(res.glob(f"parity/{a.flow or '*'}/**/input.payload"))
    if not cases:
        print(json.dumps({"status": "ERROR", "detail": f"no parity/<flow>/**/input.payload under {res}"}))
        return 2
    query_text = transform.read_text(encoding="utf-8") if transform.suffix.lower() not in (".xsl", ".xslt") else ""
    ext = externals(query_text)
    fixed = {k: Path(v) for k, v in (p.split("=", 1) for p in a.param)}
    entries, blocked, ok = [], 0, 0
    lock = {"generated": datetime.datetime.now().isoformat(timespec="seconds"), "saxon": saxon.name,
            "transform": transform.name, "transform_sha256": sha(transform), "shim_sha256": sha(shim) if shim else None,
            "entries": entries}
    rows = [r for r in load_manifest(res / "golden" / "MANIFEST.csv")]
    today = datetime.date.today().isoformat()
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for inp in cases:
            rel_in = inp.relative_to(res).as_posix()
            out = inp.with_name("expected-output.xml")
            entry = {"input": rel_in, "input_sha256": sha(inp), "output": out.relative_to(res).as_posix()}
            text = inp.read_text(encoding="utf-8", errors="replace").lstrip()
            if not text.startswith("<"):
                entry.update(status="oracle-blocked", reason="input is not XML (JSON/native before nXSD): use the OSB Test Console (source osb-test-console)")
                blocked += 1
                entries.append(entry)
                continue
            params = {name: fixed.get(name, inp) if name == "body" or name in fixed else None for name in ext}
            missing = [n for n, v in params.items() if v is None]
            if missing:
                entry.update(status="oracle-blocked", reason=f"external variables not bound: {missing} (pass --param name=file)")
                blocked += 1
                entries.append(entry)
                continue
            now = None
            hdr = inp.with_name("headers.json")
            if hdr.is_file():
                try:
                    now = json.loads(hdr.read_text(encoding="utf-8")).get("eventTime")
                except json.JSONDecodeError:
                    now = None
            bound = {k: v for k, v in params.items() if v}
            q = prepare_query(transform, shim, tmp / inp.parent.name, bound) if query_text else transform
            rc, msg = run_saxon(saxon, q, inp, out, bound, now)
            if rc != 0 or not out.is_file():
                reason = "fn-bea function not in the shim" if "fn-bea" in msg else "Saxon error"
                entry.update(status="oracle-blocked", reason=f"{reason}: {msg.strip()[:300]}")
                blocked += 1
                entries.append(entry)
                continue
            entry.update(status="ok", output_sha256=sha(out))
            ok += 1
            entries.append(entry)
            rel_out = out.relative_to(res).as_posix()
            rows = [r for r in rows if r.get("file") != rel_out]
            rows.append({"file": rel_out, "source": "original-transform", "flow": a.flow or rel_in.split("/")[1],
                         "captured_by": a.captured_by, "date": today, "sha256": entry["output_sha256"],
                         "source_ref": f"{transform.name}@{lock['transform_sha256'][:12]}"})
    (res / "golden").mkdir(parents=True, exist_ok=True)
    (res / "golden" / LOCK).write_text(json.dumps(lock, indent=2), encoding="utf-8")
    write_manifest(res / "golden" / "MANIFEST.csv", rows)
    print(json.dumps({"status": "OK" if not blocked else "PARTIAL", "ok": ok, "oracle_blocked": blocked,
                      "lock": (res / "golden" / LOCK).as_posix()}))
    return 0 if ok and not blocked else (3 if blocked else 1)


def cmd_check(a) -> int:
    res: Path = a.resources
    lock_path = res / "golden" / LOCK
    if not lock_path.is_file():
        print(json.dumps({"gate": "G10", "status": "FAIL", "detail": "golden/ORACLE.lock missing"}))
        return 1
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    mismatches, blocked = [], []
    for e in lock["entries"]:
        inp, out = res / e["input"], res / e.get("output", "")
        if e.get("status") != "ok":
            blocked.append(e["input"])
            continue
        if not inp.is_file() or sha(inp) != e["input_sha256"]:
            mismatches.append(f"{e['input']}: input changed or missing")
        if not out.is_file() or sha(out) != e["output_sha256"]:
            mismatches.append(f"{e['output']}: expected output changed or missing (regenerate with golden_runner.py run)")
    unlocked = [p.relative_to(res).as_posix() for p in res.glob("parity/**/expected-output.xml")
                if p.relative_to(res).as_posix() not in {e.get("output") for e in lock["entries"]}]
    ok = not mismatches and not unlocked
    print(json.dumps({"gate": "G10", "status": "PASS" if ok else "FAIL", "entries": len(lock["entries"]),
                      "oracle_blocked": blocked, "mismatches": mismatches,
                      "expected_outputs_not_in_lock": unlocked, "transform": lock.get("transform")}))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("resources", type=Path)
    r.add_argument("--transform", type=Path, required=True)
    r.add_argument("--shim", type=Path)
    r.add_argument("--saxon")
    r.add_argument("--flow")
    r.add_argument("--param", action="append", default=[], help="name=file for external variables other than $body")
    r.add_argument("--captured-by", default=os.environ.get("USER", "golden-runner"))
    c = sub.add_parser("check")
    c.add_argument("resources", type=Path)
    a = ap.parse_args()
    return cmd_run(a) if a.cmd == "run" else cmd_check(a)


if __name__ == "__main__":
    sys.exit(main())
