#!/usr/bin/env bash
# Research pack -> Camel K module for ONE proxy: functional tests (pi/run_tests.sh) -> approval gate -> implement (pi)
# -> mvn test -> gates.
#
# Usage: pi/run_camelk.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]
#   research-dir   research/<project>/<proxy> with research.json (+ facts.json), check PASS
#   module-dir     modules/<project>/<proxy> (created on the first run)
#   task1-dir      its fixtures/parity/* are copied into the module as test inputs (masked; .gitignore keeps them out of Git)
# Env: OSB_SRC (OSB project folder: the implementer may copy original XQuery/XSLT/XSD into the module), MVN_ARGS
#      (e.g. "-s ~/.m2/client-settings.xml"), OSB_PI_MODEL, PI_THINKING (default high), KIT, PYTHON
# Exit: 0 gates PASS, 3 card not approved yet (expected after the first run), 1 anything else.
set -euo pipefail
[ -f "${OSB_KIT_ENV:-$HOME/.osb-kit.env}" ] && . "${OSB_KIT_ENV:-$HOME/.osb-kit.env}"   # local client settings, never in Git
RES=${1:?usage: run_camelk.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]}
MOD=${2:?module dir}
PRJ=${3:?osb project name}
TASK1=${4:-}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$KIT/pi/pi_call.sh"
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
skill_dir() { if [ -d "$KIT/skills/$1" ]; then echo "$KIT/skills/$1"; elif [ -d "$KIT/.pi/skills/$1" ]; then echo "$KIT/.pi/skills/$1"; fi; }
SK=$(skill_dir osb-camelk-route); [ -n "$SK" ] || { echo "skill osb-camelk-route not found under $KIT"; exit 1; }
[ -s "$RES/research.json" ] || { echo "missing $RES/research.json: run pi/run_research.sh first"; exit 1; }
if [ -f "$RES/SHARE_CHECK.json" ] && ! grep -q '"pass": true' "$RES/SHARE_CHECK.json"; then echo "research pack did not pass its check: $RES/SHARE_CHECK.json"; exit 1; fi

echo "== 1 functional tests: generated tests + mocks, synthetic inputs, frozen (pi/run_tests.sh)"
bash "$KIT/pi/run_tests.sh" "$RES" "$MOD" "$PRJ" ${TASK1:+"$TASK1"} || echo "some scenarios have no test case yet (gate K9 will fail)"

echo "== 2 approval"
if [ "${POC:-0}" = 1 ] && ! grep -qiE '^Status:[[:space:]]*approved' "$MOD/FLOW_CARD.md"; then
  # proof-of-concept run without a sign-off: build anyway, mark the card, gate K1 stays FAIL
  sed -i.bak 's/^Status:.*/Status: poc-run (NOT approved)/' "$MOD/FLOW_CARD.md" && rm -f "$MOD/FLOW_CARD.md.bak"
  echo "   POC=1: card not approved, built for the proof of concept only (gate K1 stays FAIL)"
elif ! grep -qiE '^Status:[[:space:]]*approved[[:space:]]*$' "$MOD/FLOW_CARD.md" || ! grep -qE '^Approver:[[:space:]]*[^[:space:]]' "$MOD/FLOW_CARD.md"; then
  echo "card not approved: review $MOD/FLOW_CARD.md against $RES/RESEARCH.md, set 'Status: approved' + Approver + Date, rerun"
  exit 3
fi

LOG="$MOD/.agent-logs"; mkdir -p "$LOG"
echo "== 3 implement (pi)"
PI=(pi --print --no-session --thinking "${PI_THINKING:-high}" --skill "$SK" --tools "read,bash,edit,write"
    --append-system-prompt "$KIT/agents/implementer-camelk.md")
[ -n "${OSB_PI_MODEL:-}" ] && PI+=(--model "$OSB_PI_MODEL")
pi_call "$LOG/implement.out" "$LOG/implement.err" "${PI[@]}" "Use skill osb-camelk-route. Module: $MOD. Approved card: $MOD/FLOW_CARD.md. Research: $RES/RESEARCH.md and $RES/research.json. ${OSB_SRC:+OSB source (read only): $OSB_SRC.} Do steps 3-6 of the skill: fill every TODO(flow-card) in the route, write FlowErrorTest (one test per error scope at least) and the backend stubs, run 'mvn -B ${MVN_ARGS:-} -f $MOD/pom.xml test' and '$PY $SK/scripts/check_camelk.py $MOD' until it prints PASS. Never edit FlowParityTest.java or flow-test.json. Write nothing outside $MOD." || true

echo "== 4 verify"
mvn -B -q ${MVN_ARGS:-} -f "$MOD/pom.xml" test > "$LOG/mvn.out" 2>&1 || true
grep -h "Tests run:" "$LOG/mvn.out" | tail -1 || true
"$PY" "$SK/scripts/check_camelk.py" "$MOD"
