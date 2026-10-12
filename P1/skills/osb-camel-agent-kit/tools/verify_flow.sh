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
