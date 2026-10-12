#!/usr/bin/env bash
# One entry point per OSB flow on the VDI: OSB source export + Splunk log CSV in, verified Camel module out.
#
#   bin/start_flow.sh <osb-project-dir> <flow> <module-dir> [events.csv] [--transform <orig.xqy|xsl>] [--from <step>]
#
# Deterministic steps (no AI):  inventory -> card scaffold -> log signatures + Splunk queries -> traces (keyed masking,
# residue check) -> replay-config draft -> fixtures -> golden oracle (original transform, ORACLE.lock)
# Agent steps (pi, one fresh process per role): analyse -> GATE A (human approves the card) -> test -> implement
# -> verify (gates G1-G10, fix loops) -> review -> GATE B (human).
#
# Steps for --from: inventory | signatures | traces | fixtures | golden | pi | pi-test
# Env: MASK_KEY (required when events.csv is given), KIT (kit root: git layout <repo>/skills/osb-camel-agent-kit or the
#      paste-installed workspace), REPLAY (osb-log-replay root), SPLUNK_INDEX / SPLUNK_SOURCETYPE (for the generated
#      queries), PER_SCENARIO (default 3), OSB_PI_MODEL / PI_THINKING (passed to the kit runner), DELETE_INPUT=1 to
#      remove events.csv after masking, EXTRA_MASK_ARGS='--mask-json-key x --mask-key-pattern y' for extra personal fields.
set -euo pipefail

PROJECT=${1:?usage: start_flow.sh <osb-project-dir> <flow> <module-dir> [events.csv] [--transform f] [--from step]}
FLOW=${2:?flow name (proxy service name)}
MODULE=${3:?module dir}
shift 3
EVENTS=""; TRANSFORM=""; FROM=inventory
while [ $# -gt 0 ]; do
  case "$1" in
    --transform) TRANSFORM=${2:?}; shift 2;;
    --from) FROM=${2:?}; shift 2;;
    *) EVENTS=$1; shift;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WS=$(pwd)
KIT=${KIT:-$([ -d "$REPO/skills/osb-camel-agent-kit" ] && echo "$REPO/skills/osb-camel-agent-kit" || echo "$WS")}
REPLAY=${REPLAY:-$([ -d "$REPO/osb-log-replay" ] && echo "$REPO/osb-log-replay" || echo "$WS/log-replay")}
SKILL=$([ -d "$KIT/skills/osb-to-camel" ] && echo "$KIT/skills/osb-to-camel" || echo "$KIT/.pi/skills/osb-to-camel")
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
INV="migration/osb-inventory"; OUT="migration/$FLOW"; WORK="work/$FLOW"
mkdir -p "$OUT" "$WORK"
export KIT

step_reached() {  # steps in order; returns 0 when $1 is at or after $FROM
  local order="inventory signatures traces fixtures golden pi pi-test" seen=0 s
  for s in $order; do [ "$s" = "$FROM" ] && seen=1; [ "$s" = "$1" ] && { [ $seen -eq 1 ] && return 0 || return 1; }; done
  return 1
}
say() { printf '\n== %s\n' "$*"; }
need() { [ -e "$1" ] || { echo "missing: $1 ($2)"; exit 1; }; }

need "$SKILL/scripts/osb_inventory.py" "kit skill osb-to-camel"
need "$REPLAY/tools/osb_log_traces.py" "osb-log-replay tools (REPLAY=$REPLAY)"
need "$KIT/tools/golden_runner.py" "kit gate tools"

# ---------------------------------------------------------------- 1 inventory + card scaffold
if step_reached inventory; then
  say "1 inventory of $PROJECT"
  "$PY" "$SKILL/scripts/osb_inventory.py" "$PROJECT" -o "$INV"
  FLOW_JSON=$(ls "$INV"/flows/*__"$FLOW".json "$INV"/flows/*"$FLOW".json 2>/dev/null | head -1 || true)
  [ -n "$FLOW_JSON" ] || { echo "flow '$FLOW' not in $INV/flows (names: $(ls "$INV/flows" | tr '\n' ' '))"; exit 1; }
  if [ -f "$OUT/FLOW_CARD.md" ]; then echo "card exists, not re-scaffolded: $OUT/FLOW_CARD.md"
  else "$PY" "$SKILL/scripts/scaffold_flow.py" "$FLOW_JSON" -o "$OUT" --module "$(basename "$MODULE")"; fi
  echo "$FLOW_JSON" > "$WORK/flow.json.path"
fi
FLOW_JSON=$(cat "$WORK/flow.json.path" 2>/dev/null || ls "$INV"/flows/*"$FLOW".json | head -1)

# ---------------------------------------------------------------- 2 log signatures + Splunk queries
if step_reached signatures; then
  say "2 log signatures from the OSB Log actions"
  "$PY" "$REPLAY/tools/osb_log_signatures.py" "$PROJECT" -o "$WORK/signatures.json"
  "$PY" "$REPLAY/tools/spl_from_signatures.py" "$WORK/signatures.json" \
     --index "${SPLUNK_INDEX:-<osb_index>}" --sourcetype "${SPLUNK_SOURCETYPE:-<osb_sourcetype>}" -o "$WORK/queries.spl"
  echo "Splunk searches: $WORK/queries.spl (run the EXPORT search in Splunk, save CSV with _time,_raw)"
fi

# ---------------------------------------------------------------- 3 traces: keyed masking + residue check
if step_reached traces; then
  if [ -z "$EVENTS" ]; then
    say "3 no events.csv given: skipping traces/fixtures (run again with the Splunk CSV, --from traces)"
  else
    if [ -f "$EVENTS.report.json" ]; then
      say "3 traces from $EVENTS (already anonymised by anonymize_logs.py)"
      "$PY" "$REPLAY/tools/osb_log_traces.py" "$WORK/signatures.json" "$EVENTS" -o "$WORK/traces" --already-masked
    else
      say "3 traces from $EVENTS (masking key: ${MASK_KEY:+set}${MASK_KEY:-MISSING})"
      [ -n "${MASK_KEY:-}" ] || { echo "export MASK_KEY=<key held by the data owner> first (or anonymise first: tools/anonymize_logs.py)"; exit 1; }
      # shellcheck disable=SC2086
      "$PY" "$REPLAY/tools/osb_log_traces.py" "$WORK/signatures.json" "$EVENTS" -o "$WORK/traces" ${DELETE_INPUT:+--delete-input} ${EXTRA_MASK_ARGS:-}
    fi
    "$PY" "$REPLAY/tools/mask_residue_check.py" "$WORK/traces" || { echo "residue check failed: add --mask-json-key/--mask-key-pattern (see RUNBOOK) and rerun --from traces"; exit 1; }
    "$PY" - "$WORK/traces/coverage.json" <<'PY'
import json,sys; c=json.load(open(sys.argv[1]))
print(f"events {c['events_read']}, matched {c['events_matched']}, traces {c['traces']}, without payload {c.get('traces_without_payload')}, "
      f"never-seen signatures {len(c.get('signatures_never_seen',[]))}, masked values {c['masked_values']}, keyed {c['masking']['keyed']}")
assert c["events_matched"] > 0, "no event matched a signature: wrong project or CSV"
PY
  fi
fi

# ---------------------------------------------------------------- 4 replay-config draft + fixtures
if step_reached fixtures && [ -n "$EVENTS" -o -f "$WORK/traces/traces.jsonl" ]; then
  say "4 replay-config draft + fixtures"
  "$PY" "$HERE/replay_config_from_inventory.py" "$FLOW_JSON" -o "$WS/replay-config.json"
  echo "   check the _todo items in replay-config.json (target broker names, error headers) before the replay (L3)"
  "$PY" "$REPLAY/tools/fixtures_from_traces.py" "$WORK/traces/traces.jsonl" "$WS/replay-config.json" -o "$WORK/fixtures" --per-scenario "${PER_SCENARIO:-3}"
  mkdir -p "$MODULE/src/test/resources/golden"
  cp -r "$WORK/fixtures/parity" "$MODULE/src/test/resources/"
  cp "$WORK/fixtures/golden/MANIFEST.csv" "$MODULE/src/test/resources/golden/MANIFEST.csv"
  "$PY" "$REPLAY/tools/mask_residue_check.py" "$MODULE/src/test/resources" > /dev/null || { echo "residue in module resources"; exit 1; }
fi

# ---------------------------------------------------------------- 5 golden oracle (original transform, before any route)
if step_reached golden && [ -d "$MODULE/src/test/resources/parity" ]; then
  say "5 golden oracle"
  if [ -z "$TRANSFORM" ]; then
    TRANSFORM=$("$PY" - "$FLOW_JSON" "$PROJECT" <<'PY'
import json,sys,pathlib
d=json.load(open(sys.argv[1])); refs=d["pipeline"].get("xquery_refs",[])+d["pipeline"].get("xslt_refs",[])
root=pathlib.Path(sys.argv[2]); hits=[]
for r in refs:
    name=r.split("/")[-1]
    hits+=[p for p in root.rglob(name+".*") if p.suffix.lower() in (".xqy",".xquery",".xq",".xsl",".xslt")]
print(hits[0] if len(hits)==1 else "")
PY
)
  fi
  if [ -z "$TRANSFORM" ]; then
    echo "   more than one (or no) transform in the flow: pass --transform <the one that builds the outbound body> (see the card)"
  else
    "$PY" "$KIT/tools/golden_runner.py" run "$MODULE/src/test/resources" --transform "$TRANSFORM" \
       --shim "$SKILL/assets/templates/xquery/fn-bea-shim.xqy" --flow "$(basename "$(dirname "$(ls -d "$MODULE"/src/test/resources/parity/*/ | head -1)")")" || true
    echo "   oracle-blocked cases (if any) -> OSB Test Console, source osb-test-console; never a hand-written file"
  fi
fi

# ---------------------------------------------------------------- 6 agent steps
if step_reached pi; then
  say "6 pi: analyst writes the flow card, then GATE A"
  "$KIT/pi/run_flow.sh" "$PROJECT" "$FLOW" "$MODULE"
  echo "After approving $OUT/FLOW_CARD.md (Status approved + name): bin/start_flow.sh $PROJECT $FLOW $MODULE --from pi-test"
fi
if step_reached pi-test; then
  say "7 pi: tests first, then the route, gates, review"
  "$KIT/pi/run_flow.sh" "$PROJECT" "$FLOW" "$MODULE" --from test
fi
