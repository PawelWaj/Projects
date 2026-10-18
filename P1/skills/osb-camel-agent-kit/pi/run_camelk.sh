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
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done   # local settings, never in Git
MVN_ARGS=${MVN_ARGS//\~/$HOME}   # "~" inside a variable is not expanded by the shell
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
# freeze the card as it is now (approved by a person, or marked poc-run): pi must not change it (gate K1 checks the hash)
"$PY" -c "import hashlib,json,sys; p=sys.argv[1]; m=json.load(open(p)); m['card_sha256']=hashlib.sha256(open(sys.argv[2],'rb').read()).hexdigest(); json.dump(m,open(p,'w'),indent=2)" "$MOD/.scaffold.json" "$MOD/FLOW_CARD.md"
echo "== 3 implement (pi), in small calls"
# Every pi call starts fresh (--no-session) and never sees raw Maven output: verify_module.py prints ~30 lines.
# An agent re-sends its whole conversation with every model request, so big tool output is paid for again and again;
# small calls with a short summary keep each request small (the endpoint's limit is per minute).
PI=(pi --print --no-session --thinking "${PI_THINKING:-high}" --skill "$SK" --tools "read,bash,edit,write"
    --append-system-prompt "$KIT/agents/implementer-camelk.md")
[ -n "${OSB_PI_MODEL:-}" ] && PI+=(--model "$OSB_PI_MODEL")
VERIFY="$PY $SK/scripts/verify_module.py $MOD"
RULES="Never run mvn directly: '$VERIFY' runs the tests and the gates and prints a short summary. Never edit FlowParityTest.java, flow-test.json, FLOW_CARD.md or any test case folder. Write nothing outside $MOD. Do not read target/ or the parity cases."
export VERIFY_MVN="mvn -B -q ${MVN_ARGS:-}"
pi_call "$LOG/implement.out" "$LOG/implement.err" "${PI[@]}" "Use skill osb-camelk-route. Module: $MOD. Approved card: $MOD/FLOW_CARD.md. Research: $RES/research.json (RESEARCH.md only if research.json is unclear). ${OSB_SRC:+OSB source (read only, only the files the card names): $OSB_SRC.} Do steps 3-5 of the skill: fill every TODO(flow-card) in the route, write FlowErrorTest (one test per error scope at least) and the backend stubs. Then run '$VERIFY' ONCE and stop: fixing is the next call. $RULES" || true
for round in $(seq 1 "${PI_FIX_ROUNDS:-3}"); do
  SUMMARY=$($VERIFY 2>&1) && { echo "   verify: PASS after $round call(s)"; break; }
  echo "   verify round $round: $(echo "$SUMMARY" | head -1)"
  sleep "${PI_PAUSE:-30}"
  pi_call "$LOG/fix-$round.out" "$LOG/fix-$round.err" "${PI[@]}" "Use skill osb-camelk-route. Module: $MOD (card $MOD/FLOW_CARD.md). The last verify printed:
$SUMMARY
Fix exactly these failures in the route, the helper beans, FlowErrorTest or the stubs: read only the files you change and the card. Then run '$VERIFY' once and stop. $RULES" || true
done

echo "== 4 verify"
mvn -B -q ${MVN_ARGS:-} -f "$MOD/pom.xml" test > "$LOG/mvn.out" 2>&1 || true
grep -h "Tests run:" "$LOG/mvn.out" | tail -1 || true
"$PY" "$SK/scripts/check_camelk.py" "$MOD"
