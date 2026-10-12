#!/usr/bin/env bash
# Offline pipeline (no Splunk, no broker): source -> signatures -> SPL -> traces -> scenarios -> fixtures.
# Usage: ./run_offline.sh [osb-export-dir] [events-file] [out-dir]
# Defaults run the synthetic sample. With real data: ./run_offline.sh osb-src/my-project events.jsonl work
set -euo pipefail
cd "$(dirname "$0")"
SRC=${1:-samples}; EVENTS=${2:-samples/osb-weblogic-sample.log}; OUT=${3:-work}
PY=${PYTHON:-$(command -v python3 || command -v python)}
mkdir -p "$OUT"
"$PY" tools/osb_log_signatures.py "$SRC" -o "$OUT/signatures.json"
"$PY" tools/spl_from_signatures.py "$OUT/signatures.json" --index "${SPLUNK_INDEX:-osb}" --sourcetype "${SPLUNK_SOURCETYPE:-weblogic}" -o "$OUT/queries.spl"
"$PY" tools/osb_log_traces.py "$OUT/signatures.json" "$EVENTS" -o "$OUT/traces"
rm -rf "$OUT/fixtures"
"$PY" tools/fixtures_from_traces.py "$OUT/traces/traces.jsonl" replay-config.json -o "$OUT/fixtures"
echo "Scenarios by frequency:"
"$PY" -c "import json,sys; [print(f\"  {s['share']:5.1f} %  {s['count']:4d}  payload {s['with_payload']:3d}  {s['scenario']}\") for s in json.load(open(sys.argv[1]))]" "$OUT/traces/scenarios.json"
