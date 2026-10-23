#!/usr/bin/env bash
# One script for a working session on the client VDI (also after the VDI was restored or rebuilt): settings, model
# pacer, local broker, then whole projects from research to the review archive. Run it in the workspace (e.g.
# /e/Pawel/work) in Git Bash.
#
#   bash <kit>/pi/vdi_session.sh setup <osb-app-folder>   once per (new) machine: .osb-kit.env + preflight check
#   bash <kit>/pi/vdi_session.sh start                    pacer (pi -> 127.0.0.1:8765 -> model platform) + broker
#   bash <kit>/pi/vdi_session.sh status                   what is running, kit version, settings
#   bash <kit>/pi/vdi_session.sh flows 'a-prj|b-prj'      research (pi) -> task1 (needs EXPORT) -> review archive
#   bash <kit>/pi/vdi_session.sh review 'a-prj|b-prj'     only the delivery part (no pi): delivery, tests, broker, archive
#   bash <kit>/pi/vdi_session.sh deploy 'a-prj|b-prj'     camel-k/integration.yaml per flow + oc dry run; APPLY=1 applies
#     settings: CAMELK_NAMESPACE (required), CAMELK_BROKER_URL, CAMELK_ENV_FILE (KEY=VALUE, local file), DEPLOY_FROM=
#     scripts|skills (default: scripts when a delivery exists, else the skills module)
#   bash <kit>/pi/vdi_session.sh stop [--broker]          routes stopped, pi back to the platform, pacer stopped
#   PACER=0 before start/flows: no pacer, pi talks to the model directly (an endpoint without a rate limit)
#   GEN=scripts|skills|both before flows/review: who builds route + tests after research (default scripts)
#     scripts  route generated from the OSB pipeline, tests from Splunk cases + schema (no model)  -> delivery/ + archive
#     skills   pi writes the route (osb-camelk-route + implementer-camelk) into modules/, frozen tests, mvn, gates
#     both     the two side by side + one comparison line per flow
#
# Secrets are never written to a file: ARTEMIS_PASSWORD and MASK_KEY are asked for when they are not exported.
# Logs: domain/pacer.log (one line per model call), domain/session-<date>.log (everything a flows/review run printed).
set -u
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
WS=$(pwd)
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
PACER_PORT=${PACER_PORT:-8765}
mkdir -p "$WS/domain"
LOG="$WS/domain/session-$(date +%F).log"

ask() {   # ask <VAR> <prompt>: read a secret into VAR unless it is exported already
  if [ -z "${!1:-}" ]; then read -r -s -p "$2: " v; echo; export "$1=$v"; fi
}
pacer_up() { "$PY" -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(('127.0.0.1', $PACER_PORT)) == 0 else 1)"; }
pi_on_pacer() { grep -q "127.0.0.1:$PACER_PORT" "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json" 2> /dev/null; }
broker_up() { [ -n "${ARTEMIS_PASSWORD:-}" ] && bash "$KIT/broker/artemis_setup.sh" status 2> /dev/null | grep -q "^running"; }

start_pacer() {
  if pacer_up; then echo "pacer: already running on 127.0.0.1:$PACER_PORT"; else
    echo "pacer: starting (log $WS/domain/pacer.log)"
    pi_on_pacer || "$PY" "$KIT/pi/llm_pacer.py" pi-on --port "$PACER_PORT"
    nohup "$PY" "$KIT/pi/llm_pacer.py" --port "$PACER_PORT" >> "$WS/domain/pacer.log" 2>&1 &
    echo $! > "$WS/domain/pacer.pid"
    for i in $(seq 1 20); do pacer_up && break; sleep 1; done
    pacer_up && echo "pacer: up (gap ${PACER_GAP:-4}s, retries on 429)" || { echo "pacer: did not start, see domain/pacer.log"; tail -5 "$WS/domain/pacer.log"; return 1; }
  fi
  pi_on_pacer || "$PY" "$KIT/pi/llm_pacer.py" pi-on --port "$PACER_PORT"
  echo "pi: models.json -> pacer"
}

use_model_directly() {   # PACER=0: pi -> model platform, no pacer in between
  pi_on_pacer && "$PY" "$KIT/pi/llm_pacer.py" pi-off
  echo "pi: talks to the model directly (PACER=0, no pacer)"
}
model_link() { if [ "${PACER:-1}" = 0 ]; then use_model_directly; else pacer_up && pi_on_pacer || start_pacer; fi; }

GEN=${GEN:-scripts}
gen_stage() {   # $1 = projects, $2 = REVIEW_TESTS for the scripts path
  case "$GEN" in
    scripts) PI_TESTER=${PI_TESTER:-0} REVIEW_TESTS=${2:-1} PROJECTS="$1" bash "$KIT/pi/run_domain.sh" review ;;
    skills)  skills_build "$1" ;;
    both)    PI_TESTER=${PI_TESTER:-0} REVIEW_TESTS=${2:-1} PROJECTS="$1" bash "$KIT/pi/run_domain.sh" review
             skills_build "$1"; compare_gen "$1" ;;
    *) echo "GEN must be scripts, skills or both (got '$GEN')"; return 2 ;;
  esac
}
skills_build() {   # pi writes the route; tests stay frozen, it may not edit them (gates K5/K1)
  echo "=== GEN=skills: pi writes the route into modules/ (skill osb-camelk-route, role implementer-camelk), then mvn + gates"
  PI_TESTER=${PI_TESTER:-1} POC=1 PROJECTS="$1" bash "$KIT/pi/run_domain.sh" build
  PROJECTS="$1" bash "$KIT/pi/run_domain.sh" matrix
}
compare_gen() {   # one line per flow: scripts delivery tests vs skills module gates
  echo "=== scripts vs skills"
  PROJECTS="$1" bash "$KIT/pi/run_domain.sh" list 2>/dev/null | awk 'NF==2 && $2 != "proxies"' | while read -r p x; do
    s=$(grep -hoE "[0-9]+ tests, [0-9]+ failed" "$WS"/delivery/*/"$p"/test/RESULTS.txt 2>/dev/null | tail -1)
    g="$WS/modules/$p/$x"
    k=$([ -f "$g/GATES.json" ] && "$PY" -c "import json,os,sys; g=json.load(open(sys.argv[1]))['gates']; bad=[k.split('_')[0] for k,v in g.items() if not v.get('ok')]; m=os.path.join(os.path.dirname(sys.argv[1]),'MUTATION.json'); print(('tests green' if g.get('K8_tests_green',{}).get('ok') else 'tests NOT green') + ', gates failed: ' + (','.join(bad) or 'none') + (', mutation checked' if os.path.exists(m) else ''))" "$g/GATES.json" || echo "no module")
    printf '%-50s scripts: %-22s skills: %s\n' "$p/$x" "${s:-no result}" "$k"
  done
  echo "(skills: K1 fails by design in this comparison: the flow card is built as POC, not approved by a person)"
}

start_broker() {
  if [ ! -f "${ARTEMIS_HOME:-}/lib/artemis-boot.jar" ]; then      # fresh VDI: the distribution comes through Maven (Nexus)
    bash "$KIT/broker/artemis_setup.sh" install || { echo "broker: no Artemis (ARTEMIS_ZIP=<zip> or fix MVN_ARGS)"; return 1; }
    . ./.osb-kit.env
  fi
  ask ARTEMIS_PASSWORD "Artemis password (user ${ARTEMIS_USER:-artemis})"
  if broker_up; then echo "broker: already running"; return 0; fi
  [ -f "${ARTEMIS_BROKER:-x}/etc/broker.xml" ] || bash "$KIT/broker/artemis_setup.sh" create
  bash "$KIT/broker/artemis_setup.sh" start
}

case "${1:-}" in
  setup)
    APPDIR=${2:?usage: vdi_session.sh setup <osb-application-folder>}
    [ -f ./.osb-kit.env ] && echo "keeping ./.osb-kit.env (delete it to regenerate)" || bash "$KIT/pi/init_env.sh" "$APPDIR"
    . ./.osb-kit.env
    bash "$KIT/pi/preflight.sh"
    echo; echo "next: bash $KIT/pi/vdi_session.sh start" ;;

  start)
    echo "kit: $KIT ($(cd "$KIT/../.." 2>/dev/null && git log --oneline -1 2>/dev/null || ls -l --time-style=+%F "$KIT/pi/run_domain.sh" | awk '{print "downloaded " $6}'))"
    "${JAVA_HOME:+$JAVA_HOME/bin/}java" -version 2>&1 | grep -v "Picked up" | head -1
    mvn -v 2> /dev/null | head -1 || echo "mvn not on PATH: check .osb-kit.env"
    command -v pi > /dev/null && echo "pi: $(pi --version 2>/dev/null | head -1) model ${OSB_PI_MODEL:-<pi default>}" || echo "pi: NOT on PATH"
    model_link
    start_broker
    echo; echo "ready. Projects: bash $KIT/pi/vdi_session.sh flows 'a-prj|b-prj'   (export EXPORT=<Splunk CSV> and MASK_KEY for task1)" ;;

  status)
    echo "workspace $WS · APP=${APP:-<unset>} · kit $KIT"
    pacer_up && echo "pacer: running on :$PACER_PORT" || echo "pacer: not running"
    pi_on_pacer && echo "pi: talks to the pacer" || echo "pi: talks to the platform directly"
    echo "GEN=$GEN (route + tests by scripts | skills | both)"
    [ -n "${ARTEMIS_PASSWORD:-}" ] && bash "$KIT/broker/artemis_setup.sh" status | tail -1 || echo "broker: (export ARTEMIS_PASSWORD to check)"
    [ -f domain/STATUS.md ] && tail -1 domain/STATUS.md ;;

  flows)
    P=${2:?usage: vdi_session.sh flows 'a-prj|b-prj'}
    model_link || exit 1
    ask ARTEMIS_PASSWORD "Artemis password (user ${ARTEMIS_USER:-artemis})"
    broker_up || start_broker || echo "broker not running: the review stage skips the broker test"
    {
      echo "=== $(date '+%F %T') flows $P"
      PROJECTS="$P" bash "$KIT/pi/run_domain.sh" research
      if [ -n "${EXPORT:-}" ] && [ -f "$EXPORT" ]; then
        ask MASK_KEY "MASK_KEY (from the data owner)"
        PROJECTS="$P" bash "$KIT/pi/run_domain.sh" task1
        echo "--- check task1/SUMMARY.md (CHECK lines = wrong scenario field in research.json) before trusting the tests"
        grep -E "CHECK|FAIL" "$WS/task1/SUMMARY.md" 2> /dev/null | head -10
      else
        echo "--- task1 skipped: no EXPORT (Splunk CSV); existing test cases are used"
      fi
      for pipe in $(PROJECTS="$P" bash "$KIT/pi/run_domain.sh" list 2>/dev/null | awk 'NF==2 && $2 != "proxies" {print $1 "/" $2}'); do
        f=$(find "$APP/${pipe%%/*}" -name "${pipe##*/}.pipeline" | head -1)
        [ -n "$f" ] && "$PY" "$KIT/skills/osb-camelk-route/scripts/body_chain.py" "$f" --summary
      done
      echo "--- route + tests: GEN=$GEN"
      gen_stage "$P" 1
    } 2>&1 | tee -a "$LOG" ;;

  review)
    P=${2:?usage: vdi_session.sh review 'a-prj|b-prj'}
    ask ARTEMIS_PASSWORD "Artemis password (user ${ARTEMIS_USER:-artemis})"
    broker_up || start_broker || echo "broker not running: the review stage skips the broker test"
    [ "$GEN" = scripts ] || model_link || exit 1
    gen_stage "$P" 0 2>&1 | tee -a "$LOG" ;;

  deploy)
    P=${2:?usage: vdi_session.sh deploy 'a-prj|b-prj'   (CAMELK_NAMESPACE=<dev namespace>, APPLY=1 to apply)}
    : "${CAMELK_NAMESPACE:?export CAMELK_NAMESPACE=<dev namespace> (and CAMELK_BROKER_URL, CAMELK_ENV_FILE)}"
    command -v oc > /dev/null && OC=1 || { OC=0; echo "oc not on PATH: manifests only, no dry run / apply"; }
    PROJECTS="$P" bash "$KIT/pi/run_domain.sh" list 2>/dev/null | awk 'NF==2 && $2 != "proxies"' | while read -r p x; do
      d=$(ls -d "$WS"/delivery/*/"$p" 2>/dev/null | head -1); m="$WS/modules/$p/$x"
      src=$([ "${DEPLOY_FROM:-}" = skills ] || [ -z "$d" ] && echo "$m" || echo "$d")
      [ -d "$src" ] || { echo "$p/$x: nothing built yet (run flows or review first)"; continue; }
      echo "=== $p/$x from $src"
      "$PY" "$KIT/skills/osb-camelk-route/scripts/camelk_manifests.py" "$src" --namespace "$CAMELK_NAMESPACE" || continue
      f="$src/camel-k/integration.yaml"
      grep -q '"ready": true' "$src/camel-k/CHECK.json" || { echo "   NOT READY: fill the open values (CHANGE-ME), see $src/camel-k/DEPLOY.md"; continue; }
      [ "$OC" = 1 ] || continue
      oc apply -n "$CAMELK_NAMESPACE" --dry-run=server -f "$f" || { echo "   dry run refused: fix before applying"; continue; }
      for s in $("$PY" -c "import json,sys; print(' '.join(json.load(open(sys.argv[1]))['secrets']))" "$src/camel-k/CHECK.json"); do
        oc get secret "$s" -n "$CAMELK_NAMESPACE" > /dev/null 2>&1 || echo "   MISSING Secret $s: create it first (DEPLOY.md)"
      done
      if [ "${APPLY:-0}" = 1 ]; then oc apply -n "$CAMELK_NAMESPACE" -f "$f" && echo "   applied: oc get integration -n $CAMELK_NAMESPACE -w"
      else echo "   dry run OK. Apply with: APPLY=1 bash $KIT/pi/vdi_session.sh deploy '$p'"; fi
    done 2>&1 | tee -a "$LOG" ;;

  stop)
    D=$(ls -d "$WS"/delivery/*/ 2>/dev/null | head -1)
    [ -n "$D" ] && [ -f "$D/run.sh" ] && (cd "$D" && bash run.sh stop)
    pi_on_pacer && "$PY" "$KIT/pi/llm_pacer.py" pi-off
    if [ -f "$WS/domain/pacer.pid" ]; then kill "$(cat "$WS/domain/pacer.pid")" 2> /dev/null; rm -f "$WS/domain/pacer.pid"; fi
    pacer_up && echo "pacer still listening on :$PACER_PORT (close its window)" || echo "pacer: stopped"
    if [ "${2:-}" = "--broker" ]; then ask ARTEMIS_PASSWORD "Artemis password"; bash "$KIT/broker/artemis_setup.sh" stop; fi ;;

  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2 ;;
esac
