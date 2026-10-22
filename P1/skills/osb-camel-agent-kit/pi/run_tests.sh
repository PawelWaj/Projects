#!/usr/bin/env bash
# Functional test creation for ONE proxy, no route needed: research pack + Splunk cases -> generated tests and mocks
# -> synthetic inputs for scenarios Splunk cannot supply (pi tester) -> frozen test pack + catalogue.
#
# Usage: pi/run_tests.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]
# Env:   OSB_SRC (OSB project folder: the tester reads the message schema there), OSB_PI_MODEL, KIT, PYTHON,
#        PI_TESTER=0 (skip the synthetic messages, e.g. when the model quota is short), PI_TESTER_THINKING (default low)
# Result: <module>/src/test/** (FlowParityTest + flow-test.json + real and synthetic case folders, frozen),
#         <module>/TEST_MATRIX.md (catalogue: every scenario, its inputs and expected outputs). Exit 1 if a scenario has no case.
set -euo pipefail
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done   # local settings, never in Git
MVN_ARGS=${MVN_ARGS//\~/$HOME}   # "~" inside a variable is not expanded by the shell
RES=${1:?usage: run_tests.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]}
MOD=${2:?module dir}
PRJ=${3:?osb project name}
TASK1=${4:-}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$KIT/pi/pi_call.sh"
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
SK=$(for d in "$KIT/skills/osb-camelk-route" "$KIT/.pi/skills/osb-camelk-route"; do [ -d "$d" ] && echo "$d" && break; done)
[ -n "$SK" ] || { echo "skill osb-camelk-route not found under $KIT"; exit 1; }
[ -s "$RES/research.json" ] || { echo "missing $RES/research.json: run pi/run_research.sh first"; exit 1; }

echo "== 1 generated tests + mocks (script)"
"$PY" "$SK/scripts/scaffold_camelk.py" "$RES" -o "$MOD" --project "$PRJ" ${TASK1:+--parity "$TASK1/fixtures/parity"} ${REFRESH:+--refresh "$REFRESH"}

echo "== 2 synthetic inputs where Splunk has none (script from the schema first, pi tester only for the rest)"
LOG="$MOD/.agent-logs"; mkdir -p "$LOG"
"$PY" "$SK/scripts/check_camelk.py" "$MOD" --no-surefire > /dev/null || true
UNCOV=$("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1]))['gates']['K9_scenarios_covered']['uncovered']))" "$MOD/GATES.json")
if [ "$UNCOV" != 0 ] && [ -n "${OSB_SRC:-}" ] && [ -d "$OSB_SRC" ]; then
  # first without an AI: fake-value messages built from the flow's schema (no model calls, no quota)
  "$PY" "$SK/scripts/synth_from_schema.py" "$MOD" "$OSB_SRC" --research "$RES/research.json" || true
  "$PY" "$SK/scripts/check_camelk.py" "$MOD" --no-surefire > /dev/null || true
  UNCOV=$("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1]))['gates']['K9_scenarios_covered']['uncovered']))" "$MOD/GATES.json")
fi
if [ "$UNCOV" != 0 ] && [ "${PI_TESTER:-1}" = 0 ]; then
  echo "   PI_TESTER=0: $UNCOV scenario(s) stay without a test case (gate K9 shows them)"
elif [ "$UNCOV" != 0 ]; then
  PT=(pi --print --no-session --thinking "${PI_TESTER_THINKING:-low}" --tools "read,bash,write" --append-system-prompt "$KIT/agents/tester-camelk.md")
  [ -n "${OSB_PI_MODEL:-}" ] && PT+=(--model "$OSB_PI_MODEL")
  REPLY_TASK=""
  if "$PY" -c "import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if 'reply' in c.get('outputs',{}) and c.get('backends') else 1)" "$MOD/src/test/resources/flow-test.json"; then
    # request/reply with HTTP calls: the reply body must be tested (gate K12), so the case needs the backend's answer and
    # the reply OSB would build from it
    REPLY_TASK=" This flow answers the caller and calls backend(s) $("$PY" -c "import json,sys; print(', '.join(json.load(open(sys.argv[1]))['backends']))" "$MOD/src/test/resources/flow-test.json"). For each backend write $MOD/src/test/resources/stubs/<backend>.json: the backend's answer with FAKE values, ONLY fields that research.json names (transforms[].mappings[].from, backends[].response_use); include at least one record that matches every filter the transforms use (e.g. a status the reply selects) and one that does not. For each case write expected-output.json next to input.payload: the reply as research.json transforms build it from that stub, field by field (apply every rule: renames, date reformat, value mapping). Gate K12 checks it."
  fi
  pi_call "$LOG/tester.out" "$LOG/tester.err" "${PT[@]}" "Module: $MOD. Research: $RES/RESEARCH.md and $RES/research.json. ${OSB_SRC:+OSB source (read only, for the message schema): $OSB_SRC.} Write synthetic case folders for the $UNCOV scenario_mapping rows of $MOD/src/test/resources/flow-test.json that have no case yet (check: $PY $SK/scripts/check_camelk.py $MOD --no-surefire, gates K9 and K12). Fake values only.$REPLY_TASK Write nothing outside $MOD/src/test/resources/parity and $MOD/src/test/resources/stubs." || true
else
  echo "   every scenario already has a real Splunk case"
fi

echo "== 3 freeze + catalogue"
"$PY" "$SK/scripts/scaffold_camelk.py" "$RES" -o "$MOD" --project "$PRJ" --freeze-synthetic
"$PY" "$SK/scripts/check_camelk.py" "$MOD" --no-surefire > /dev/null || true
"$PY" "$SK/scripts/test_matrix.py" "$MOD" > /dev/null || true
"$PY" - "$MOD" <<'PY'
import json, sys
from pathlib import Path
m = Path(sys.argv[1]); par = m / "src/test/resources/parity"
real = sum(1 for p in par.glob("*/*/*/input.payload") if "-synthetic" not in p.parts[-4])
syn = sum(1 for p in par.glob("*-synthetic/*/*/input.payload"))
g = json.loads((m / "GATES.json").read_text())["gates"]["K9_scenarios_covered"]
cfg = json.loads((m / "src/test/resources/flow-test.json").read_text())
print(json.dumps({"scenarios": len(cfg["scenario_mapping"]), "real_cases": real, "synthetic_cases": syn,
                  "uncovered": g["uncovered"], "outputs": sorted(cfg["outputs"]), "catalogue": str(m / "TEST_MATRIX.md")}))
sys.exit(0 if g["ok"] else 1)
PY
