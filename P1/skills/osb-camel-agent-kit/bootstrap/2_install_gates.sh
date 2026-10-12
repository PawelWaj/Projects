#!/usr/bin/env bash
# Paste into the migration workspace root on the VDI and run: bash 2_install_gates.sh
# Gate tools: verify_flow.sh (G1-G8, G10), check_matrix, check_oracle, golden_runner, mutate_transforms, compare_shadow, pom plugins, Jenkins stages.
set -euo pipefail
mkdir -p "$(dirname "tools/verify_flow.sh")"
cat > 'tools/verify_flow.sh' <<'KIT_EOF_TOOLS_VERIFY_FLOW_SH'
#!/usr/bin/env bash
# Gates G1-G8 + G10 for one migrated OSB flow. Writes migration/<flow>/verify-report.json.
# Usage: tools/verify_flow.sh <module-dir> <flow> [card-path]
# Env:   SKIP_G8=1 to skip the (slow) mutation gate during local loops; CI never sets it.
set -uo pipefail

MODULE=${1:?usage: verify_flow.sh <module-dir> <flow> [card-path]}
FLOW=${2:?usage: verify_flow.sh <module-dir> <flow> [card-path]}
CARD=${3:-migration/$FLOW/FLOW_CARD.md}
TOOLS=$(cd "$(dirname "$0")" && pwd)
# "$PY" on Linux/macOS, python or py on Windows Git Bash
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
OUT_DIR="migration/$FLOW"
REPORT="$OUT_DIR/verify-report.json"
RESULTS=$(mktemp)
mkdir -p "$OUT_DIR"
trap 'rm -f "$RESULTS"' EXIT

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULTS"; echo "  $1 $2  $3"; }
mvnq() { mvn -q -B -f "$MODULE/pom.xml" "$@"; }

echo "Verifying flow '$FLOW' in $MODULE"

# G1 build
if mvnq -DskipTests package > "$OUT_DIR/g1-build.log" 2>&1; then record G1 PASS "build"; else record G1 FAIL "see g1-build.log"; fi

# G2 Camel endpoint validation (camel-report-maven-plugin must be in the pom, see tools/pom-build-plugins.xml)
if mvnq camel-report:validate > "$OUT_DIR/g2-validate.log" 2>&1; then record G2 PASS "endpoint URIs valid"
else record G2 FAIL "see g2-validate.log"; fi

# G3 repository rules
PATTERN='jms://|t3://|\.example\.ins|amqps?://[A-Za-z0-9]|(password|passwd|secret)[[:space:]]*[:=][[:space:]]*[^$[:space:]{]|camel-k|kind:[[:space:]]*(Integration|Kamelet)\b'
HITS=$(grep -RInE "$PATTERN" "$MODULE/src" --include='*.java' --include='*.yaml' --include='*.yml' --include='*.properties' --include='*.xml' 2>/dev/null | grep -v '/src/test/resources/golden/' | grep -v '/src/test/resources/parity/' || true)
if [ -z "$HITS" ]; then record G3 PASS "no hosts, secrets or Camel K"
else printf '%s\n' "$HITS" > "$OUT_DIR/g3-hits.txt"; record G3 FAIL "$(printf '%s\n' "$HITS" | wc -l | tr -d ' ') hits, see g3-hits.txt"; fi

# G4 + G5 one mvn verify run (surefire = unit/route/golden/contract, failsafe = *IT with Testcontainers)
CONTAINER_RT=""
if docker info > /dev/null 2>&1; then CONTAINER_RT=docker; elif podman info > /dev/null 2>&1; then CONTAINER_RT=podman; fi
mvnq verify > "$OUT_DIR/g45-verify.log" 2>&1
read -r UT_TESTS UT_FAIL UT_SKIP < <("$PY" - "$MODULE/target/surefire-reports" <<'PY'
import sys, glob, xml.etree.ElementTree as ET
t=f=s=0
for p in glob.glob(sys.argv[1] + "/TEST-*.xml"):
    r=ET.parse(p).getroot(); t+=int(r.get("tests",0)); f+=int(r.get("failures",0))+int(r.get("errors",0)); s+=int(r.get("skipped",0))
print(t, f, s)
PY
)
SKIP_OK=0; grep -q '^## Skipped tests' "$OUT_DIR/MIGRATION_RECORD.md" 2>/dev/null && SKIP_OK=1
if [ "${UT_TESTS:-0}" -eq 0 ]; then record G4 FAIL "no surefire tests ran"
elif [ "$UT_FAIL" -gt 0 ]; then record G4 FAIL "$UT_FAIL failing of $UT_TESTS"
elif [ "$UT_SKIP" -gt 0 ] && [ "$SKIP_OK" -eq 0 ]; then record G4 FAIL "$UT_SKIP skipped without '## Skipped tests' in the record"
else record G4 PASS "$UT_TESTS tests, $UT_SKIP skipped"; fi

if [ -z "$CONTAINER_RT" ]; then record G5 NOT_RUN "no Docker/Podman: integration tests not run (not green)"
else
  read -r IT_TESTS IT_FAIL IT_SKIP < <("$PY" - "$MODULE/target/failsafe-reports" <<'PY'
import sys, glob, xml.etree.ElementTree as ET
t=f=k=0
for p in glob.glob(sys.argv[1] + "/TEST-*.xml"):
    r=ET.parse(p).getroot(); t+=int(r.get("tests",0)); f+=int(r.get("failures",0))+int(r.get("errors",0)); k+=int(r.get("skipped",0))
print(t, f, k)
PY
)
  if [ "${IT_TESTS:-0}" -eq 0 ]; then record G5 FAIL "no *IT tests ran ($CONTAINER_RT)"
  elif [ "${IT_SKIP:-0}" -ge "$IT_TESTS" ]; then record G5 NOT_RUN "all $IT_TESTS ITs skipped: Testcontainers could not reach $CONTAINER_RT (never counted green)"
  elif [ "$IT_FAIL" -gt 0 ]; then record G5 FAIL "$IT_FAIL failing of $IT_TESTS"
  else record G5 PASS "$((IT_TESTS - ${IT_SKIP:-0})) integration tests, ${IT_SKIP:-0} skipped ($CONTAINER_RT)"; fi
fi

# G6 matrix coverage
G6=$("$PY" "$TOOLS/check_matrix.py" "$CARD" "$MODULE/src/test/java" 2>&1); RC=$?
echo "$G6" > "$OUT_DIR/g6-matrix.json"
[ $RC -eq 0 ] && record G6 PASS "every matrix row has a test" || record G6 FAIL "see g6-matrix.json"

# G7 oracle provenance
G7=$("$PY" "$TOOLS/check_oracle.py" "$MODULE/src/test/resources" 2>&1); RC=$?
echo "$G7" > "$OUT_DIR/g7-oracle.json"
[ $RC -eq 0 ] && record G7 PASS "all fixtures from OSB" || record G7 FAIL "see g7-oracle.json"

# G10 oracle lock: golden outputs produced by the deterministic runner (tools/golden_runner.py) BEFORE the route, unchanged since
if find "$MODULE/src/main/resources" \( -name '*.xq*' -o -name '*.xsl*' \) -print -quit 2>/dev/null | grep -q .; then
  if [ -f "$MODULE/src/test/resources/golden/ORACLE.lock" ]; then
    G10=$("$PY" "$TOOLS/golden_runner.py" check "$MODULE/src/test/resources" 2>&1); RC=$?
    echo "$G10" > "$OUT_DIR/g10-oracle-lock.json"
    [ $RC -eq 0 ] && record G10 PASS "golden outputs match ORACLE.lock" || record G10 FAIL "see g10-oracle-lock.json"
  else record G10 FAIL "module has transforms but no golden/ORACLE.lock: run tools/golden_runner.py before the route"; fi
else record G10 NOT_APPLICABLE "no XQuery/XSLT in the module"; fi

# G8 transform mutation
if [ "${SKIP_G8:-0}" = "1" ]; then record G8 NOT_RUN "skipped by SKIP_G8 (local loop only)"
else
  G8=$("$PY" "$TOOLS/mutate_transforms.py" "$MODULE" 2>&1); RC=$?
  echo "$G8" > "$OUT_DIR/g8-mutation.json"
  [ $RC -eq 0 ] && record G8 PASS "all transform mutants killed" || record G8 FAIL "see g8-mutation.json"
fi

"$PY" - "$RESULTS" "$REPORT" "$FLOW" "$MODULE" <<'PY'
import sys, json, datetime
rows=[l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
gates=[{"gate":g,"status":s,"detail":d} for g,s,d in rows]
green=all(x["status"] in ("PASS","NOT_APPLICABLE") for x in gates)   # NOT_RUN and FAIL are never green
json.dump({"flow":sys.argv[3],"module":sys.argv[4],"date":datetime.datetime.now().isoformat(timespec="seconds"),
           "all_green":green,"gates":gates}, open(sys.argv[2],"w"), indent=2)
print(("ALL GATES GREEN" if green else "NOT GREEN") + f" -> {sys.argv[2]}")
sys.exit(0 if green else 1)
PY
KIT_EOF_TOOLS_VERIFY_FLOW_SH
mkdir -p "$(dirname "tools/check_matrix.py")"
cat > 'tools/check_matrix.py' <<'KIT_EOF_TOOLS_CHECK_MATRIX_PY'
#!/usr/bin/env python3
"""G6: every test-matrix row (T1..Tn) of the flow card has at least one test that names it.

A test "names" a row when the ID appears as a whole token in the test sources, e.g. @DisplayName("T3 filter ...")
or a method t3_filterRejectsCreated(). T1 does not match T10.
Exit 0 = all rows covered, 1 = rows missing, 2 = usage / input error.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROW_ID = re.compile(r"^\|\s*(T\d+)\s*\|", re.MULTILINE)


def matrix_ids(card: Path) -> list[str]:
    text = card.read_text(encoding="utf-8")
    match = re.search(r"^##\s*8\..*?$(.*?)(^##\s|\Z)", text, re.MULTILINE | re.DOTALL)
    section = match.group(1) if match else text
    return sorted(set(ROW_ID.findall(section)), key=lambda s: int(s[1:]))


def covered(test_text: str, row: str) -> bool:
    num = row[1:]
    return re.search(rf"(?<![A-Za-z0-9])[Tt]{num}(?![0-9])", test_text) is not None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("card", type=Path)
    ap.add_argument("test_dir", type=Path, help="e.g. <module>/src/test/java")
    args = ap.parse_args()
    if not args.card.is_file() or not args.test_dir.is_dir():
        print(json.dumps({"gate": "G6", "status": "ERROR", "detail": "card or test dir not found"}))
        return 2
    ids = matrix_ids(args.card)
    if not ids:
        print(json.dumps({"gate": "G6", "status": "FAIL", "detail": "no T-rows found in card section 8"}))
        return 1
    sources = "\n".join(p.read_text(encoding="utf-8", errors="replace")
                        for p in args.test_dir.rglob("*") if p.suffix in {".java", ".kt", ".groovy", ".yaml", ".yml"})
    missing = [r for r in ids if not covered(sources, r)]
    status = "PASS" if not missing else "FAIL"
    print(json.dumps({"gate": "G6", "status": status, "rows": len(ids), "missing": missing}))
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_TOOLS_CHECK_MATRIX_PY
mkdir -p "$(dirname "tools/check_oracle.py")"
cat > 'tools/check_oracle.py' <<'KIT_EOF_TOOLS_CHECK_ORACLE_PY'
#!/usr/bin/env python3
"""G7: every expected-output fixture comes from OSB, not from the generated Camel code.

Checks every file under <resources>/golden and <resources>/parity against <resources>/golden/MANIFEST.csv
(columns: file,source,flow,captured_by,date[,sha256,key_id,source_ref,reason,approved_by]; file relative to <resources>).
Sources card-rule and source-derived (not observed in OSB) need reason and approved_by.
Exit 0 = clean, 1 = violations, 2 = usage / input error.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

ALLOWED = {"osb-recording", "original-transform", "osb-test-console", "card-rule", "source-derived"}
NEEDS_APPROVAL = {"card-rule", "source-derived"}        # not observed in OSB: a reason and a named approver are mandatory
FIXTURE_DIRS = ("golden", "parity")
IGNORED = {"MANIFEST.csv", "ignore-fields.txt", "README.md", ".gitkeep"}


def load_manifest(path: Path) -> dict[str, dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as fh:
        return {row["file"].strip(): row for row in csv.DictReader(fh)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("resources", type=Path, help="e.g. <module>/src/test/resources")
    args = ap.parse_args()
    manifest_path = args.resources / "golden" / "MANIFEST.csv"
    fixtures = [p for d in FIXTURE_DIRS if (args.resources / d).is_dir()
                for p in (args.resources / d).rglob("*") if p.is_file() and p.name not in IGNORED]
    if not fixtures:
        print(json.dumps({"gate": "G7", "status": "FAIL", "detail": "no golden/parity fixtures found"}))
        return 1
    if not manifest_path.is_file():
        print(json.dumps({"gate": "G7", "status": "FAIL", "detail": "golden/MANIFEST.csv missing"}))
        return 1
    try:
        manifest = load_manifest(manifest_path)
    except (KeyError, csv.Error) as exc:
        print(json.dumps({"gate": "G7", "status": "ERROR", "detail": f"bad manifest: {exc}"}))
        return 2
    unlisted, bad_source = [], []
    for p in fixtures:
        rel = p.relative_to(args.resources).as_posix()
        row = manifest.get(rel)
        if row is None:
            unlisted.append(rel)
        elif row.get("source", "").strip() not in ALLOWED:
            bad_source.append(f"{rel} ({row.get('source', '').strip() or 'empty'})")
        elif row.get("source", "").strip() in NEEDS_APPROVAL and not (
                (row.get("reason") or "").strip() and (row.get("approved_by") or "").strip()):
            bad_source.append(f"{rel} ({row['source'].strip()}: reason and approved_by required)")
    ok = not unlisted and not bad_source
    print(json.dumps({"gate": "G7", "status": "PASS" if ok else "FAIL", "fixtures": len(fixtures),
                      "unlisted": unlisted, "bad_source": bad_source, "allowed_sources": sorted(ALLOWED)}))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_TOOLS_CHECK_ORACLE_PY
mkdir -p "$(dirname "tools/compare_shadow.py")"
cat > 'tools/compare_shadow.py' <<'KIT_EOF_TOOLS_COMPARE_SHADOW_PY'
#!/usr/bin/env python3
"""L6 shadow comparison: pair OSB and Camel output messages by a correlation key and diff them.

Each message is a file <name>.xml or <name>.json with an optional <name>.headers.json ({"header": "value"}).
The key is taken from the headers first, else from the first XML element / JSON field whose local name equals --key.
Elements or fields whose name is in --ignore are removed before the comparison (XML: canonical C14N 2.0; JSON: sorted
keys); headers listed in --ignore are dropped too. Duplicate keys on either side are reported (a message delivered
twice). Body differences name the first differing path. Exit 0 = no differences and no unmatched messages,
1 = differences, 2 = usage error.
"""
from __future__ import annotations

import argparse
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def strip(elem: ET.Element, ignore: set[str]) -> None:
    for child in list(elem):
        if local(child.tag) in ignore:
            elem.remove(child)
        else:
            strip(child, ignore)


def strip_json(obj, ignore: set[str]):
    if isinstance(obj, dict):
        return {k: strip_json(v, ignore) for k, v in obj.items() if k not in ignore}
    if isinstance(obj, list):
        return [strip_json(v, ignore) for v in obj]
    return obj


def find_json_key(obj, key: str):
    if isinstance(obj, dict):
        if key in obj and isinstance(obj[key], (str, int)):
            return str(obj[key])
        for v in obj.values():
            r = find_json_key(v, key)
            if r:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = find_json_key(v, key)
            if r:
                return r
    return None


def first_diff_path(a, b, path="$") -> str:
    """First differing path of two parsed JSON values ("$" root)."""
    if type(a) is not type(b):
        return path
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                return f"{path}.{k}"
            d = first_diff_path(a[k], b[k], f"{path}.{k}")
            if d:
                return d
        return ""
    if isinstance(a, list):
        if len(a) != len(b):
            return f"{path}[len {len(a)} vs {len(b)}]"
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_diff_path(x, y, f"{path}[{i}]")
            if d:
                return d
        return ""
    return path if a != b else ""


def load(dir_: Path, key: str, ignore: set[str]) -> tuple[dict[str, tuple[str, dict, object]], list[str], list[str]]:
    """Returns {key: (canonical body text, headers, parsed json or None)}, unreadable, duplicate keys."""
    msgs, errors, dups = {}, [], []
    files = [f for f in sorted(dir_.iterdir()) if f.suffix in (".xml", ".json") and not f.name.endswith(".headers.json")]
    for f in files:
        hdr_file = f.with_name(f.stem + ".headers.json")
        headers = json.loads(hdr_file.read_text(encoding="utf-8")) if hdr_file.is_file() else {}
        parsed = None
        try:
            if f.suffix == ".json":
                parsed = strip_json(json.loads(f.read_text(encoding="utf-8")), ignore)
                k = headers.get(key) or find_json_key(parsed, key)
                canon = json.dumps(parsed, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            else:
                root = ET.fromstring(f.read_bytes())
                k = headers.get(key) or next((e.text for e in root.iter() if local(e.tag) == key and e.text), None)
                strip(root, ignore)
                canon = ET.canonicalize(ET.tostring(root, encoding="unicode"), strip_text=True)
        except (ET.ParseError, json.JSONDecodeError) as exc:
            errors.append(f"{f.name}: {exc}")
            continue
        if not k:
            errors.append(f"{f.name}: no key '{key}'")
            continue
        if k in msgs:
            dups.append(k)
            continue
        msgs[k] = (canon, {h: v for h, v in headers.items() if h not in ignore}, parsed)
    return msgs, errors, dups


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--osb", type=Path, required=True)
    ap.add_argument("--camel", type=Path, required=True)
    ap.add_argument("--key", default="correlationId")
    ap.add_argument("--ignore", default="", help="comma-separated element/header local names")
    ap.add_argument("-o", "--out", type=Path)
    args = ap.parse_args()
    if not args.osb.is_dir() or not args.camel.is_dir():
        print("both --osb and --camel must be directories", file=sys.stderr)
        return 2
    ignore = {s.strip() for s in args.ignore.split(",") if s.strip()}
    osb, osb_err, osb_dup = load(args.osb, args.key, ignore)
    cam, cam_err, cam_dup = load(args.camel, args.key, ignore)
    equal, body_diff, header_diff = [], [], []
    for k in sorted(set(osb) & set(cam)):
        (ob, oh, oj), (cb, ch, cj) = osb[k], cam[k]
        if ob != cb:
            body_diff.append({"key": k, "path": first_diff_path(oj, cj) if oj is not None and cj is not None else "xml body"})
        if oh != ch:
            header_diff.append({"key": k, "osb": oh, "camel": ch})
        if ob == cb and oh == ch:
            equal.append(k)
    report = {"matched_equal": len(equal), "body_diff": body_diff, "header_diff": header_diff,
              "osb_only": sorted(set(osb) - set(cam)), "camel_only": sorted(set(cam) - set(osb)),
              "duplicate_keys": {"osb": sorted(osb_dup), "camel": sorted(cam_dup)},
              "unreadable": osb_err + cam_err, "ignored": sorted(ignore)}
    clean = not (body_diff or header_diff or report["osb_only"] or report["camel_only"] or report["unreadable"]
                 or osb_dup or cam_dup)
    report["status"] = "PASS" if clean else "FAIL"
    text = json.dumps(report, indent=2)
    if args.out:
        args.out.write_text(text, encoding="utf-8")
    print(text)
    return 0 if clean else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_TOOLS_COMPARE_SHADOW_PY
mkdir -p "$(dirname "tools/golden_runner.py")"
cat > 'tools/golden_runner.py' <<'KIT_EOF_TOOLS_GOLDEN_RUNNER_PY'
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
KIT_EOF_TOOLS_GOLDEN_RUNNER_PY
mkdir -p "$(dirname "tools/mutate_transforms.py")"
cat > 'tools/mutate_transforms.py' <<'KIT_EOF_TOOLS_MUTATE_TRANSFORMS_PY'
#!/usr/bin/env python3
"""G8: break each transform on purpose; the golden tests must fail for every mutant.

Mutants (one at a time, original restored after each run, even on error or Ctrl-C):
  XQuery: the content of an element constructor  >{ expr }<  becomes  >{"__MUTANT__"}<
  XSLT:   the select of an <xsl:value-of select="..."/> becomes  select="'__MUTANT__'"
Up to --per-file mutants per transform. A mutant "survives" when the test command exits 0.
Exit 0 = all mutants killed, 1 = survivors or no mutants, 2 = usage error.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

XQ_SITE = re.compile(r">\{([^{}]+)\}<")
XSL_SITE = re.compile(r"(<xsl:value-of\s+select=)\"([^\"]+)\"")


def mutants(text: str, suffix: str, limit: int) -> list[str]:
    out = []
    if suffix in {".xqy", ".xq", ".xquery"}:
        for m in list(XQ_SITE.finditer(text))[:limit]:
            out.append(text[:m.start()] + '>{"__MUTANT__"}<' + text[m.end():])
    elif suffix in {".xsl", ".xslt"}:
        for m in list(XSL_SITE.finditer(text))[:limit]:
            out.append(text[:m.start()] + m.group(1) + "\"'__MUTANT__'\"" + text[m.end():])
    return out


def run_tests(cmd: list[str], cwd: Path, timeout: int) -> bool:
    """True when the tests pass (mutant survived)."""
    try:
        res = subprocess.run(cmd, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False
    return res.returncode == 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("module", type=Path)
    ap.add_argument("--per-file", type=int, default=3)
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--test-cmd", default="mvn -q -Dtest=*GoldenTest*,*RouteTest* -Dsurefire.failIfNoSpecifiedTests=false test")
    args = ap.parse_args()
    main_res = args.module / "src" / "main" / "resources"
    if not main_res.is_dir():
        print(json.dumps({"gate": "G8", "status": "ERROR", "detail": f"{main_res} not found"}))
        return 2
    cmd = args.test_cmd.split()
    cmd[0] = shutil.which(cmd[0]) or cmd[0]  # resolves mvn.cmd on Windows
    results = []
    for f in sorted(p for p in main_res.rglob("*") if p.suffix in {".xqy", ".xq", ".xquery", ".xsl", ".xslt"}):
        original = f.read_text(encoding="utf-8")
        backup = f.with_suffix(f.suffix + ".g8bak")
        shutil.copy2(f, backup)
        try:
            for i, mutant in enumerate(mutants(original, f.suffix, args.per_file), 1):
                f.write_text(mutant, encoding="utf-8")
                survived = run_tests(cmd, args.module, args.timeout)
                results.append({"file": f.relative_to(args.module).as_posix(), "mutant": i,
                                "result": "SURVIVED" if survived else "KILLED"})
        finally:
            shutil.move(backup, f)
    survivors = [r for r in results if r["result"] == "SURVIVED"]
    status = "PASS" if results and not survivors else "FAIL"
    detail = "no mutable transform sites found" if not results else ""
    print(json.dumps({"gate": "G8", "status": status, "mutants": len(results), "survivors": survivors,
                      "detail": detail}))
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_TOOLS_MUTATE_TRANSFORMS_PY
mkdir -p "$(dirname "tools/pom-build-plugins.xml")"
cat > 'tools/pom-build-plugins.xml' <<'KIT_EOF_TOOLS_POM_BUILD_PLUGINS_XML'
<!-- Build plugins the gates rely on. Merge into <build><plugins> of each flow module (or the parent pom).
     Versions are properties: pin them in the parent pom to the programme's approved versions. -->
<plugins>
  <!-- G4: unit, route, golden, contract tests (*Test) -->
  <plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-surefire-plugin</artifactId>
    <version>${surefire.version}</version>
    <configuration>
      <excludes><exclude>**/*IT.java</exclude></excludes>
    </configuration>
  </plugin>

  <!-- G5: integration tests (*IT) with Testcontainers AMQ Broker -->
  <plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-failsafe-plugin</artifactId>
    <version>${surefire.version}</version>
    <executions>
      <execution><goals><goal>integration-test</goal><goal>verify</goal></goals></execution>
    </executions>
  </plugin>

  <!-- G2: validates every Camel endpoint URI and option against the Camel catalog of this version -->
  <plugin>
    <groupId>org.apache.camel</groupId>
    <artifactId>camel-report-maven-plugin</artifactId>
    <version>${camel.version}</version>
    <configuration>
      <failOnError>true</failOnError>
      <includeTest>false</includeTest>
      <ignoreUnknownComponent>false</ignoreUnknownComponent>
    </configuration>
  </plugin>

  <!-- Optional G8b: mutation testing of Java processors -->
  <plugin>
    <groupId>org.pitest</groupId>
    <artifactId>pitest-maven</artifactId>
    <version>${pitest.version}</version>
    <dependencies>
      <dependency>
        <groupId>org.pitest</groupId>
        <artifactId>pitest-junit5-plugin</artifactId>
        <version>${pitest.junit5.version}</version>
      </dependency>
    </dependencies>
    <configuration>
      <targetClasses><param>${integration.base.package}.*</param>  <!-- base package: OPEN, set in the parent pom --></targetClasses>
      <mutationThreshold>70</mutationThreshold>
    </configuration>
  </plugin>
</plugins>
KIT_EOF_TOOLS_POM_BUILD_PLUGINS_XML
mkdir -p "$(dirname "ci/Jenkinsfile.groovy")"
cat > 'ci/Jenkinsfile.groovy' <<'KIT_EOF_CI_JENKINSFILE_GROOVY'
// Stages to add to the migration repository's Jenkins pipeline. One run per changed flow module.
// Parameters: FLOW (flow name), MODULE (module dir), TARGET (target branch, default main),
//             IMPLEMENTER_ID (git author e-mail used by the implementer agent).
pipeline {
  agent { label 'maven-docker' }          // Java 21, Maven 3.9, Python 3, Docker or Podman for Testcontainers
  parameters {
    string(name: 'FLOW', description: 'OSB flow name, e.g. order-event')
    string(name: 'MODULE', description: 'Maven module directory of the flow')
    string(name: 'TARGET', defaultValue: 'main')
    string(name: 'IMPLEMENTER_ID', defaultValue: 'implementer-agent@ci.local')
  }
  stages {
    stage('guard') {
      // Independence rule: the implementer identity may not touch tests, fixtures or the manifest.
      steps {
        sh '''
          set -eu
          git fetch -q origin "$TARGET"
          BAD=""
          for c in $(git rev-list "origin/$TARGET..HEAD"); do
            if [ "$(git show -s --format=%ae "$c")" = "$IMPLEMENTER_ID" ]; then
              F=$(git show --name-only --format= "$c" | grep -E '/src/test/|/golden/|/parity/|MANIFEST\\.csv' || true)
              [ -n "$F" ] && BAD="$BAD $c"
            fi
          done
          if [ -n "$BAD" ]; then echo "Implementer commits touch test paths:$BAD"; exit 1; fi
        '''
      }
    }
    stage('approved card') {
      steps {
        sh 'grep -Eq "^\\| \\*\\*Status\\*\\* \\| approved" "migration/$FLOW/FLOW_CARD.md" || { echo "card not approved"; exit 1; }'
      }
    }
    stage('gates G1-G8') {
      steps { sh 'tools/verify_flow.sh "$MODULE" "$FLOW"' }
    }
  }
  post {
    always {
      archiveArtifacts artifacts: "migration/${params.FLOW}/**, ${params.MODULE}/target/*-reports/**", allowEmptyArchive: true
      junit testResults: "${params.MODULE}/target/*-reports/TEST-*.xml", allowEmptyResults: true
    }
  }
}
KIT_EOF_CI_JENKINSFILE_GROOVY
chmod +x tools/*.sh tools/*.py 2>/dev/null || true
echo "installed: 8 files (gate tools)"
