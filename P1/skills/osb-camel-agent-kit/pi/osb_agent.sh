#!/usr/bin/env bash
# One command per OSB project: the pi operator (skill osb-migration-run, role agents/operator-osb.md) reads the state of
# the run (pipeline_state.py), executes the one next kit command, reads the state again, and stops at the human gates.
# Splunk is the input (EXPORT=<csv> + MASK_KEY), everything else is driven from here. Run it in the workspace.
#   bash <kit>/pi/osb_agent.sh '<a-prj|b-prj>' [--max-rounds N] [--no-pi]
#     --max-rounds N   operator rounds before giving up (default 12); one round = one pi call that may run several steps
#     --no-pi          no operator model: this script runs the `next` commands itself (deterministic; research and the
#                      route still need pi inside flows/review, so without pi on PATH those stages stop as BLOCKED)
# Exported before: OSB_PI_MODEL (the operator and the inner research/implementer calls), ARTEMIS_PASSWORD (asked if
# missing), EXPORT + MASK_KEY when there is a Splunk export (MASK_KEY asked if missing). PACER=0 (default here): pi talks
# to the model directly; PACER=1 starts the pacer and the broker through vdi_session.sh start.
# AGENT_TIMEOUT (default 14400 s) bounds one operator round; the inner pi calls inherit it as PI_TIMEOUT.
# Exit: 0 handover reached, 3 a person must act (printed as HUMAN: …), 1 no progress twice or a command failed twice.
# Logs: domain/agent-run.log (every command's output), domain/agent-<date>.out/.err (the operator's own text).
set -u
P=${1:?usage: osb_agent.sh '<a-prj|b-prj>' [--max-rounds N] [--no-pi]}; shift
MAX=12; NOPI=0
while [ $# -gt 0 ]; do case "$1" in --max-rounds) MAX=$2; shift 2;; --no-pi) NOPI=1; shift;; *) echo "unknown option $1"; exit 2;; esac; done
WS=$(pwd)
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}; export KIT WS
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
MVN_ARGS=${MVN_ARGS:-}; export MVN_ARGS
. "$KIT/pi/pi_call.sh"
mkdir -p "$WS/domain"
STAMP=$(date +%F-%H%M); RUNLOG="$WS/domain/agent-run.log"; OUT="$WS/domain/agent-$STAMP.out"; ERR="$WS/domain/agent-$STAMP.err"
STATEPY="$KIT/skills/osb-migration-run/scripts/pipeline_state.py"
SK="$KIT/skills/osb-migration-run"
ask() { if [ -z "${!1:-}" ]; then read -r -s -p "$2: " v; echo; export "$1=$v"; fi; }   # secrets: exported, never in a file

echo "=== $(date '+%F %T') osb_agent $P (operator: $([ "$NOPI" = 1 ] && echo 'none, --no-pi' || echo "pi, model ${OSB_PI_MODEL:-<unset>}"))" | tee -a "$RUNLOG"
if [ "$NOPI" = 0 ]; then
  command -v pi > /dev/null || { echo "pi not on PATH: install it (pi/VDI_RUNBOOK.md section 3) or run with --no-pi"; exit 2; }
  : "${OSB_PI_MODEL:?export OSB_PI_MODEL=<model id> (the operator and the research/implementer calls use it)}"
  if [ "${PACER:-0}" = 0 ]; then
    grep -q "127.0.0.1:${PACER_PORT:-8765}" "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json" 2> /dev/null && "$PY" "$KIT/pi/llm_pacer.py" pi-off
    echo "pi: talks to the model directly (PACER=0)"
  else
    bash "$KIT/pi/vdi_session.sh" start || exit 1
  fi
fi
ask ARTEMIS_PASSWORD "Artemis password (user ${ARTEMIS_USER:-artemis})"
if [ -n "${EXPORT:-}" ] && [ -f "$EXPORT" ]; then ask MASK_KEY "MASK_KEY (from the data owner)"; fi

state() {   # prints the table, sets KIND STAGE FP TEXT
  "$PY" -I "$STATEPY" "$P" --json > "$WS/domain/agent-state.json" 2> "$WS/domain/agent-state.err" || [ $? = 3 ] || { cat "$WS/domain/agent-state.err"; exit 2; }
  "$PY" -I "$STATEPY" "$P" | tee -a "$RUNLOG"
  eval "$("$PY" -c 'import json,sys,shlex; d=json.load(open(sys.argv[1])); n=d["next"]; print("KIND=%s STAGE=%s FP=%s TEXT=%s" % (shlex.quote(n["kind"]), shlex.quote(n["stage"]), shlex.quote(d["fingerprint"]), shlex.quote(n["text"])))' "$WS/domain/agent-state.json")"
}

PROMPT="Project $P. Workspace: $WS (current folder). Use skill osb-migration-run: run pipeline_state.py first, then exactly its next command, then the state again; continue until the next human gate or the handover, then report as the skill says."
stall=0; last=""
for round in $(seq 1 "$MAX"); do
  echo "--- round $round $(date '+%T')" | tee -a "$RUNLOG"
  state
  case "$KIND" in
    human) echo "(do that, then run the same osb_agent.sh line again)"; exit 3 ;;
    done)  exit 0 ;;
  esac
  if [ "$FP" = "$last" ]; then stall=$((stall + 1)); else stall=0; fi
  if [ "$stall" -ge 2 ]; then
    echo "no progress after two rounds at stage $STAGE; last command: $TEXT" | tee -a "$RUNLOG"
    echo "--- last 30 lines of $RUNLOG"; tail -30 "$RUNLOG"; exit 1
  fi
  last=$FP
  if [ "$NOPI" = 1 ]; then
    case "$STAGE" in flows|review-fix|review-refreeze) command -v pi > /dev/null || { echo "HUMAN: stage $STAGE needs pi on PATH (research / implementer); install pi or run flows on a machine that has it"; exit 3; } ;; esac
    echo "run: $TEXT" | tee -a "$RUNLOG"
    bash -c "$TEXT" < /dev/null || echo "command returned $? (the state decides what it means)" | tee -a "$RUNLOG"
  else
    echo "operator: pi round $round (log $OUT)" | tee -a "$RUNLOG"
    PI_TIMEOUT="${AGENT_TIMEOUT:-14400}" pi_call "$OUT.$round" "$ERR.$round" \
      pi --print --no-session --thinking "${PI_THINKING:-medium}" --skill "$SK" --tools "read,bash,edit,write" \
         --append-system-prompt "$KIT/agents/operator-osb.md" --model "$OSB_PI_MODEL" "$PROMPT" < /dev/null
    rc=$?
    { echo "=== operator round $round (rc $rc)"; cat "$OUT.$round"; } >> "$OUT"; cat "$ERR.$round" >> "$ERR"; rm -f "$OUT.$round" "$ERR.$round"
    [ "$rc" = 75 ] && { echo "model endpoint refuses (quota): stopping"; exit 75; }
    echo "--- operator said (last 12 lines):"; tail -12 "$OUT"
  fi
done
echo "max rounds ($MAX) reached at stage $STAGE" | tee -a "$RUNLOG"; exit 1
