#!/usr/bin/env bash
# TASK 1: from a Splunk export alone (no OSB source, no Camel code) to masked test cases, replayed through the mock
# environment against a stand-in flow. Proves the data chain and the mocks before any migration work.
#
#   bin/task1_log_only.sh <events.csv> [work-dir] [--replay]
#
#   1 anonymise (MASK_KEY)           -> <work>/events.masked.csv + .report.json   (raw CSV untouched; delete it yourself)
#   2 signature from the example line -> <work>/signatures.json                    (stands in for the OSB source)
#   3 traces + scenarios              -> <work>/traces/
#   4 replay-config draft + fixtures  -> <work>/replay-config.json, <work>/fixtures/parity/**
#   5 --replay: Artemis + WireMock + stub flow in Docker Compose, replay every case -> <work>/report/report.json
# Env: MASK_KEY (required), REPLAY (osb-log-replay root), EXAMPLE_LINE (which event is the example, default 1),
#      FLOW (<project>/<proxy> if the line does not name them), SUCCESS_QUEUE / ERROR_QUEUE (stand-in output names),
#      EXTRA_MASK_ARGS (e.g. "--mask-json-key establishmentNameArb"),
#      SCENARIO_DIMS (split scenarios by payload fields, e.g. hdr_resource,body:data.businessTransaction), PER_SCENARIO (default 3).
set -euo pipefail
EVENTS=${1:?usage: task1_log_only.sh <events.csv> [work-dir] [--replay]}
WORK=${2:-work/task1}; [ "${2:-}" = "--replay" ] && WORK=work/task1
DO_REPLAY=0; for a in "$@"; do [ "$a" = "--replay" ] && DO_REPLAY=1; done
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
REPLAY=${REPLAY:-$([ -d "$REPO/osb-log-replay" ] && echo "$REPO/osb-log-replay" || echo "$(pwd)/log-replay")}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
T="$REPLAY/tools"; mkdir -p "$WORK"
[ -n "${MASK_KEY:-}" ] || { echo "export MASK_KEY=<key> first (real key from the data owner; any value for a private trial)"; exit 1; }

echo "== 1 anonymise"
"$PY" "$T/anonymize_logs.py" "$EVENTS" -o "$WORK/events.masked.csv" ${EXTRA_MASK_ARGS:-} || { echo "residue found: see $WORK/events.masked.csv.report.json, add --mask-json-key and rerun"; exit 1; }

echo "== 2 signature from example line ${EXAMPLE_LINE:-1}"
"$PY" "$T/signature_from_example.py" "$WORK/events.masked.csv" -o "$WORK/signatures.json" --line "${EXAMPLE_LINE:-1}" ${FLOW:+--flow "$FLOW"}

echo "== 3 traces"
"$PY" "$T/osb_log_traces.py" "$WORK/signatures.json" "$WORK/events.masked.csv" -o "$WORK/traces" --already-masked ${SCENARIO_DIMS:+--dims "$SCENARIO_DIMS"}

echo "== 4 replay-config draft + fixtures"
"$PY" - "$WORK/signatures.json" "$WORK/events.masked.csv" "$WORK/replay-config.json" <<'PY'
import csv, io, json, re, sys
sig = json.load(open(sys.argv[1]))["signatures"][0]
text = open(sys.argv[2], encoding="utf-8").read()
raw = next(r["_raw"] for r in csv.DictReader(io.StringIO(text, newline="")))
m = re.search(r"from\s+JMS\s+(\S+)", raw)
address = m.group(1) if m else "input-address"
flow = sig["flow"]; slug = re.sub(r"[^A-Za-z0-9]+", "-", flow.split("/")[-1]).strip("-")
import os
cfg = {"_comment": "TASK 1 draft: stand-in names for the mock environment; the real names come from the OSB export (task 2).",
       "broker": {"host": "localhost", "stomp_port": 61613, "user": "artemis", "password_env": "ARTEMIS_PASSWORD"},
       "flows": {flow: {
           "input": {"address": address, "type": "multicast" if "topic" in address.lower() else "anycast",
                     "subscription": f"{slug}-sub", "filter": ""},
           "correlation_header": "traceId",
           "outputs": {"success": {"destination": os.environ.get("SUCCESS_QUEUE", f"{slug}-success"), "type": "anycast"},
                       "error": {"destination": os.environ.get("ERROR_QUEUE", f"{slug}-error"), "type": "anycast",
                                 "expect_headers": ["errorCode", "errorMessage", "traceId"]}},
           "negative_cases": [], "timeout_s": 15,
           "_todo": ["selector (filter), output queue names and error headers come from the OSB export in task 2"]}}}
json.dump(cfg, open(sys.argv[3], "w"), indent=2)
print(f"flow {flow}: input {address}, outputs {cfg['flows'][flow]['outputs']['success']['destination']} / {cfg['flows'][flow]['outputs']['error']['destination']}")
PY
rm -rf "$WORK/fixtures"
"$PY" "$T/fixtures_from_traces.py" "$WORK/traces/traces.jsonl" "$WORK/replay-config.json" -o "$WORK/fixtures" --per-scenario "${PER_SCENARIO:-3}"
"$PY" "$T/mask_residue_check.py" "$WORK/fixtures" | tail -1
echo "Scenarios:"; "$PY" -c "import json,sys; [print(f\"  {s['count']:4d}  payload {s['with_payload']:3d}  {s['scenario']}\") for s in json.load(open(sys.argv[1]))]" "$WORK/traces/scenarios.json"

if [ "$DO_REPLAY" = 1 ]; then
  echo "== 5 replay through the mock environment (stand-in flow)"
  ABS=$(cd "$WORK" && pwd); RW="$REPLAY/work/task1"; rm -rf "$RW"; mkdir -p "$RW"
  cp -r "$ABS/fixtures" "$RW/fixtures"; cp "$ABS/replay-config.json" "$RW/replay-config.json"
  cd "$REPLAY/mock"
  [ -f .env ] || printf 'ARTEMIS_PASSWORD=%s\n' "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)" > .env
  export REPLAY_CONFIG=../work/task1/replay-config.json REPLAY_CONFIG_IN_WORK=work/task1/replay-config.json \
         FIXTURES_DIR=work/task1/fixtures REPORT_DIR=work/task1/report
  docker compose up -d artemis wiremock && ./setup_broker.sh
  docker compose --profile selftest up -d sut-stub
  docker compose --profile replay run --rm replay || true
  docker compose --profile selftest down >/dev/null 2>&1 || true
  cp -r "$REPLAY/work/task1/report" "$ABS/report" 2>/dev/null || true
  echo "report: $ABS/report/report.json (stop the stack: cd $REPLAY/mock && docker compose down -v)"
fi
echo "done: $WORK"
