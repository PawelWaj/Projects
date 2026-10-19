#!/usr/bin/env bash
# Everything for the flows in this folder. Settings: set-env.sh (edit once). Steps: README.md.
#   bash run.sh test   [project]     tests of every flow (or one project): no broker needed
#   bash run.sh setup-broker         create and start a local Artemis (once; needs ARTEMIS_HOME, BROKER_PASSWORD)
#   bash run.sh e2e    [project]     every flow against the running Artemis: send the cases, count the queues
#   bash run.sh status               Java, Maven, JBang and broker check
#   bash run.sh stop                 stop running routes of this folder
set -u
cd "$(dirname "$0")"
[ -f set-env.sh ] && . ./set-env.sh
projects() { if [ -n "${1:-}" ]; then echo "$1"; else for d in */; do [ -f "$d/run-local.sh" ] && echo "${d%/}"; done; fi; }
case "${1:-}" in
  test)
    rc=0
    for p in $(projects "${2:-}"); do
      echo "== $p"; (cd "$p" && bash run-local.sh test > test/RESULTS.txt 2>&1); grep -E "^FAIL|tests, [0-9]+ failed" "$p/test/RESULTS.txt" || { echo "   did not run: see $p/test/RESULTS.txt"; tail -5 "$p/test/RESULTS.txt"; rc=1; }
      grep -qE "tests, 0 failed" "$p/test/RESULTS.txt" || rc=1
    done; exit $rc ;;
  setup-broker) exec bash tools/artemis.sh setup ;;
  e2e)
    rc=0; for p in $(projects "${2:-}"); do bash tools/e2e.sh "$p" || rc=1; done; exit $rc ;;
  status)
    "${JAVA_HOME:+$JAVA_HOME/bin/}java" -version 2>&1 | grep -v "Picked up" | head -1
    mvn -v 2>/dev/null | head -1 || echo "mvn not on PATH (needed only when JBang is not installed)"
    command -v jbang > /dev/null && echo "jbang: installed" || echo "jbang: not installed -> tools/jbang.sh (via Maven)"
    bash tools/artemis.sh status ;;
  stop) for p in $(projects); do (cd "$p" && bash run-local.sh stop 2>&1 | grep -E "Shutting down"); done ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
