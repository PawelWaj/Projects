#!/usr/bin/env bash
# Research pack -> Camel K module for ONE proxy: scaffold (script) -> approval gate -> synthetic inputs where Splunk has
# none (pi tester) -> implement (pi) -> mvn test -> gates.
#
# Usage: pi/run_camelk.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]
#   research-dir   research/<project>/<proxy> with research.json (+ facts.json), check PASS
#   module-dir     modules/<project>/<proxy> (created on the first run)
#   task1-dir      its fixtures/parity/* are copied into the module as test inputs (masked; .gitignore keeps them out of Git)
# Env: OSB_SRC (OSB project folder: the implementer may copy original XQuery/XSLT/XSD into the module), MVN_ARGS
#      (e.g. "-s ~/.m2/gosi-settings.xml"), OSB_PI_MODEL, PI_THINKING (default high), KIT, PYTHON
# Exit: 0 gates PASS, 3 card not approved yet (expected after the first run), 1 anything else.
set -euo pipefail
RES=${1:?usage: run_camelk.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]}
MOD=${2:?module dir}
PRJ=${3:?osb project name}
TASK1=${4:-}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
skill_dir() { if [ -d "$KIT/skills/$1" ]; then echo "$KIT/skills/$1"; elif [ -d "$KIT/.pi/skills/$1" ]; then echo "$KIT/.pi/skills/$1"; fi; }
SK=$(skill_dir osb-camelk-route); [ -n "$SK" ] || { echo "skill osb-camelk-route not found under $KIT"; exit 1; }
[ -s "$RES/research.json" ] || { echo "missing $RES/research.json: run pi/run_research.sh first"; exit 1; }
if [ -f "$RES/SHARE_CHECK.json" ] && ! grep -q '"pass": true' "$RES/SHARE_CHECK.json"; then echo "research pack did not pass its check: $RES/SHARE_CHECK.json"; exit 1; fi

echo "== 1 scaffold"
"$PY" "$SK/scripts/scaffold_camelk.py" "$RES" -o "$MOD" --project "$PRJ" ${TASK1:+--parity "$TASK1/fixtures/parity"}

echo "== 2 approval"
if ! grep -qiE '^Status:[[:space:]]*approved[[:space:]]*$' "$MOD/FLOW_CARD.md" || ! grep -qE '^Approver:[[:space:]]*[^[:space:]]' "$MOD/FLOW_CARD.md"; then
  echo "card not approved: review $MOD/FLOW_CARD.md against $RES/RESEARCH.md, set 'Status: approved' + Approver + Date, rerun"
  exit 3
fi

LOG="$MOD/.agent-logs"; mkdir -p "$LOG"
echo "== 3 test inputs: scenarios without a real Splunk message get synthetic ones (pi tester, before the route)"
"$PY" "$SK/scripts/check_camelk.py" "$MOD" --no-surefire > /dev/null || true
UNCOV=$("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1]))['gates']['K9_scenarios_covered']['uncovered']))" "$MOD/GATES.json")
if [ "$UNCOV" != 0 ]; then
  PT=(pi --print --no-session --thinking "${PI_THINKING:-high}" --tools "read,bash,write" --append-system-prompt "$KIT/agents/tester-camelk.md")
  [ -n "${OSB_PI_MODEL:-}" ] && PT+=(--model "$OSB_PI_MODEL")
  "${PT[@]}" "Module: $MOD. Research: $RES/RESEARCH.md. ${OSB_SRC:+OSB source (read only, for the message schema): $OSB_SRC.} Write synthetic case folders for the $UNCOV scenario_mapping rows of $MOD/src/test/resources/flow-test.json that have no case yet (check: $PY $SK/scripts/check_camelk.py $MOD --no-surefire, gate K9). Fake values only. Write nothing outside $MOD/src/test/resources/parity." \
    > "$LOG/tester.out" 2> "$LOG/tester.err" || true
fi
"$PY" "$SK/scripts/scaffold_camelk.py" "$RES" -o "$MOD" --project "$PRJ" --freeze-synthetic

echo "== 4 implement (pi)"
PI=(pi --print --no-session --thinking "${PI_THINKING:-high}" --skill "$SK" --tools "read,bash,edit,write"
    --append-system-prompt "$KIT/agents/implementer-camelk.md")
[ -n "${OSB_PI_MODEL:-}" ] && PI+=(--model "$OSB_PI_MODEL")
"${PI[@]}" "Use skill osb-camelk-route. Module: $MOD. Approved card: $MOD/FLOW_CARD.md. Research: $RES/RESEARCH.md and $RES/research.json. ${OSB_SRC:+OSB source (read only): $OSB_SRC.} Do steps 3-6 of the skill: fill every TODO(flow-card) in the route, write FlowErrorTest (one test per error scope at least) and the backend stubs, run 'mvn -B ${MVN_ARGS:-} -f $MOD/pom.xml test' and '$PY $SK/scripts/check_camelk.py $MOD' until it prints PASS. Never edit FlowParityTest.java or flow-test.json. Write nothing outside $MOD." \
  > "$LOG/implement.out" 2> "$LOG/implement.err" || true

echo "== 5 verify"
mvn -B -q ${MVN_ARGS:-} -f "$MOD/pom.xml" test > "$LOG/mvn.out" 2>&1 || true
grep -h "Tests run:" "$LOG/mvn.out" | tail -1 || true
"$PY" "$SK/scripts/check_camelk.py" "$MOD"
