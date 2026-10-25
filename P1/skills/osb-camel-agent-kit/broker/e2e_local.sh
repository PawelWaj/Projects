#!/usr/bin/env bash
# The whole local broker test in ONE window: queues -> route started in the background -> one case per scenario of
# every flow + one unreadable message per flow -> output queues compared with what the tests expect -> route stopped.
#   bash <kit>/broker/e2e_local.sh <module | flat project folder> [--flow <proxy>]
# Route log: <folder>/target/e2e-route.log (kept for the evidence). Exit 0 = every output queue got what was expected.
set -u
. "$(dirname "$0")/lib.sh"
M=${1:?usage: e2e_local.sh <module | flat project folder> [--flow <proxy>]}
shift
FLOW_ARGS=("$@")
need_module "$M"; need_home; need_password
mkdir -p "$M/target"
LOG="$M/target/e2e-route.log"; PLAN="$M/target/e2e-plan.tsv"; B="$M/target/e2e-before.txt"; A="$M/target/e2e-after.txt"
flat=0; [ -f "$M/src/env/local.properties" ] && [ ! -f "$M/env/local.properties" ] && flat=1

echo "== 1 queues"
bash "$KIT/broker/artemis_prepare.sh" "$M" | tail -3
"$PY" "$KIT/broker/e2e_check.py" plan "$M" ${FLOW_ARGS[@]+"${FLOW_ARGS[@]}"} > "$PLAN"
[ -s "$PLAN" ] || { echo "no test cases found under $M/src/test/resources"; exit 2; }
artemis_client queue stat --maxRows 500 --maxColumnSize -1 > "$B" 2>&1

echo "== 2 route (background, log: $LOG)"
bash "$KIT/broker/run_local.sh" "$M" > "$LOG" 2>&1 &
PID=$!
stop() {
  if [ -r "/proc/$PID/winpid" ]; then taskkill //F //T //PID "$(cat /proc/$PID/winpid)" > /dev/null 2>&1   # Windows: whole tree (mvn + java)
  else pkill -P "$PID" 2> /dev/null; kill "$PID" 2> /dev/null; fi
}
trap stop EXIT
for i in $(seq 1 90); do
  grep -qE "Apache Camel .* started" "$LOG" && break
  if ! kill -0 "$PID" 2> /dev/null || grep -qE "BUILD FAILURE|Failed to start" "$LOG"; then
    echo "route did not start; last lines of the log:"; grep -E "ERROR|Caused by|BUILD" "$LOG" | head -15; exit 1
  fi
  sleep 2
done
grep -qE "Apache Camel .* started" "$LOG" || { echo "route not started after 180 s (see $LOG)"; exit 1; }
grep -E "Apache Camel .* started" "$LOG" | tail -1 | sed 's/^.*Apache/   Apache/'

echo "== 3 send"
n=0
while IFS=$'\t' read -r flow case outs; do
  fa=(); [ "$flat" = 1 ] && fa=(--flow "$flow")
  r=$(bash "$KIT/broker/send_case.sh" "$M" ${fa[@]+"${fa[@]}"} --fill-selector "$case" 2>&1 | tail -1)
  echo "   $flow $(basename "$(dirname "$case")") -> expect ${outs:-nothing}: ${r%% with properties*}"
  n=$((n + 1))
done < <(tr -d '\r' < "$PLAN")
for flow in $(cut -f1 "$PLAN" | sort -u); do
  fa=(); [ "$flat" = 1 ] && fa=(--flow "$flow")
  first=$(grep "^$flow	" "$PLAN" | grep -v "(filtered" | head -1 | cut -f2)
  bash "$KIT/broker/send_case.sh" "$M" ${fa[@]+"${fa[@]}"} --fill-selector --raw 'not json at all' --headers "$(cat "$first/headers.json")" > /dev/null 2>&1
  echo "   $flow unreadable message -> expect error queue"
done
echo "   $n case(s) + 1 unreadable message per flow; waiting for the route ..."
sleep 8

echo "== 4 result"
artemis_client queue stat --maxRows 500 --maxColumnSize -1 > "$A" 2>&1
"$PY" "$KIT/broker/e2e_check.py" report "$M" "$PLAN" "$B" "$A" 1
rc=$?
errs=$(grep -cE "ERROR|Exception" "$LOG")
echo "route log: $LOG ($errs ERROR/Exception lines; the unreadable messages cause some on purpose)"
# machine-readable result for pipeline_state.py (skill osb-migration-run): ok, case count, when
printf '{"ok": %s, "cases": %s, "route_errors": %s, "ts": "%s"}\n' "$([ "$rc" = 0 ] && echo true || echo false)" "$n" "$errs" "$(date '+%F %T')" > "$M/target/e2e-result.json"
exit $rc
