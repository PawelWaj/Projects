#!/usr/bin/env bash
# The broker test of one project folder: start its routes (camel run), wait until Camel is up, send one test case per
# scenario like the OSB caller, count what arrived on each queue IN THIS RUN, stop the routes.
#   bash tools/e2e.sh <project folder>          (run.sh e2e does it for every project)
# Needs a running broker (bash tools/artemis.sh status) and BROKER_PASSWORD. Evidence: <project>/test/BROKER_RUN.txt,
# copied to <project>/docs/<proxy>/BROKER_RUN.txt; route log: <project>/test/broker-run.log.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P=${1:?usage: tools/e2e.sh <project folder>}
cd "$ROOT/$P" || exit 2
[ -n "${BROKER_PASSWORD:-}" ] || { echo "export BROKER_PASSWORD=<broker password> first"; exit 2; }
OUT=test/BROKER_RUN.txt
bash ../tools/artemis.sh status 2> /dev/null | grep -q "broker: running" \
  || { echo "$P: broker not reachable at ${BROKER_URL:-tcp://localhost:61616} (bash run.sh setup-broker / check BROKER_PASSWORD)"; exit 1; }
counts() {   # NAME and MESSAGES ADDED of every queue (artemis queue stat, column 5)
  bash run-local.sh stat 2>/dev/null | awk -F'|' 'NF > 6 && $2 !~ /NAME/ {gsub(/ /, "", $2); gsub(/ /, "", $6); print $2, $6}'
}
bash run-local.sh stop > /dev/null 2>&1
bash run-local.sh run > test/broker-run.log 2>&1 &
pid=$!
for i in $(seq 1 "${BROKER_START_WAIT:-300}"); do        # the first run downloads JBang/Camel through Maven (minutes)
  grep -qE "Apache Camel .* started" test/broker-run.log && break
  kill -0 "$pid" 2> /dev/null || break
  sleep 2
done
if ! grep -qE "Apache Camel .* started" test/broker-run.log; then
  { echo "# broker run $(date '+%F %T'): ROUTE DID NOT START, nothing sent"; tail -20 test/broker-run.log; } > "$OUT"
  echo "$P: ROUTE DID NOT START"; tail -5 test/broker-run.log | sed 's/^/   /'
  bash run-local.sh stop > /dev/null 2>&1; kill "$pid" 2> /dev/null; exit 1
fi
sleep 3                                                   # the source kamelet opens the durable subscription
counts > test/counts-before.txt
{
  echo "# broker run $(date '+%F %T'), project $P"
  echo "## sent (one real case per scenario; the broker drops what the OSB selector excludes)"
  for x in $(ls test/resources); do
    for c in $(find "test/resources/$x/parity" -name input.payload 2> /dev/null | xargs -n1 dirname | sort | awk -F/ '!seen[$(NF-1)]++'); do
      echo "$x $(basename "$(dirname "$c")"): $(bash run-local.sh send "$x" "$c" | grep -c Produced) message"
    done
  done
  sleep "${BROKER_SETTLE:-8}"
  counts > test/counts-after.txt
  echo "## arrived in this run (MESSAGES ADDED after - before)"
  awk 'NR == FNR {b[$1] = $2; next} {d = $2 - (($1 in b) ? b[$1] : 0); if (d > 0) printf "  %-45s +%d\n", $1, d}' test/counts-before.txt test/counts-after.txt
  others=$(for d in ../*/test/resources/*/; do x=$(basename "$d"); [ -d "test/resources/$x" ] || echo "$x"; done | sort -u)
  for o in $others; do       # a subscription of ANOTHER flow took messages of this run: its filter is not the OSB selector
    n=$(awk -v q="$o" 'NR == FNR {if ($1 == q) b = $2; next} $1 == q {print $2 - b + 0}' test/counts-before.txt test/counts-after.txt)
    [ "${n:-0}" -gt 0 ] 2> /dev/null && echo "WARNING: subscription $o (another flow) received $n message(s) of this run: its filter is not its OSB selector (an old queue?). Fix: bash tools/artemis.sh cli queue delete --name $o --removeConsumers"
  done
  echo "## route log"
  sed 's/\x1b\[[0-9;]*m//g' test/broker-run.log | grep -oE "(Request Received|Sending to [^ ]*|Error captured|No route)[^:]*" \
    | sed -E 's/ with TraceID.*//' | sort | uniq -c
} > "$OUT"
bash run-local.sh stop > /dev/null 2>&1; sleep 3; kill "$pid" 2> /dev/null
for x in $(ls docs 2> /dev/null); do cp "$OUT" "docs/$x/BROKER_RUN.txt"; done
echo "$P: $(grep -c ' message$' "$OUT") case(s) sent"
sed -n '/## arrived/,$p' "$OUT" | grep -vE "^## " | sed 's/^/   /'
if grep -q "^WARNING" "$OUT"; then exit 1; fi
