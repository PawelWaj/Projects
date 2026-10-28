#!/usr/bin/env bash
# D0 deployment checks of a Camel K integration on the Dev cluster (needs `oc` logged in to the Dev namespace).
#   bash dev_check.sh <namespace> <integration> [secret]        e.g. bash dev_check.sh my-dev-namespace my-flow
# Prints names, phases, counts only. Secret VALUES are read into memory only to count how often they appear in the
# pod logs (must be 0); they are never printed or written. Writes results/DEV_CHECK.md. Exit 0 when every check passes.
set -u
NS=${1:?usage: dev_check.sh <namespace> <integration> [secret]}
I=${2:?integration name}
S=${3:-$I-env}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
OUT=${OUT:-results}; mkdir -p "$OUT"
rows=(); bad=0
add() { rows+=("| $1 | $2 | $3 | $4 |"); printf '%-4s %-5s %s: %s\n' "$1" "$2" "$3" "$4"; [ "$2" = ok ] || bad=1; }

phase=$(oc get integration "$I" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$phase" = Running ] && add D0.1 ok "integration phase" "$phase" || add D0.1 FAIL "integration phase" "${phase:-not found} (oc describe integration $I -n $NS)"

pods=$(oc get pods -n "$NS" -l "camel.apache.org/integration=$I" -o jsonpath='{range .items[*]}{.status.phase} {.status.containerStatuses[0].ready} {.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null)
ready=$(echo "$pods" | grep -c ' true ')
restarts=$(echo "$pods" | awk '{s+=$3} END {print s+0}')
[ "$ready" -ge 1 ] && [ "$restarts" -eq 0 ] && add D0.2 ok "pods ready, no restarts" "$ready ready, $restarts restarts" \
  || add D0.2 FAIL "pods ready, no restarts" "$ready ready, $restarts restarts (oc logs -l camel.apache.org/integration=$I -n $NS --previous)"

oc get secret "$S" -n "$NS" -o json > "$OUT/.s.json" 2>/dev/null || : > "$OUT/.s.json"
oc logs -n "$NS" -l "camel.apache.org/integration=$I" --tail=-1 > "$OUT/.logs.txt" 2>/dev/null || : > "$OUT/.logs.txt"
"$PY" - "$OUT/.s.json" "$OUT/.logs.txt" <<'PY' > "$OUT/.py.txt"
import base64, json, re, sys
try: data = json.load(open(sys.argv[1])).get("data") or {}
except Exception: data = {}
logs = open(sys.argv[2], encoding="utf-8", errors="replace").read()
vals = {k: base64.b64decode(v).decode("utf-8", "replace") for k, v in data.items()}
open_ = [k for k, v in vals.items() if not v.strip() or "CHANGE-ME" in v or v.startswith("<")]
hits = {k: logs.count(v) for k, v in vals.items() if len(v) >= 4}
errs = {n: len(re.findall(p, logs)) for n, p in (("PKIX/TLS", r"PKIX|SSLHandshake|certificate"), ("DNS/connect", r"UnknownHost|Connection refused|ConnectException"),
        ("timeout", r"SocketTimeout|timed out|ReadTimeout"))}
print("keys", len(vals), ",".join(sorted(vals)))
print("open", ",".join(open_))
print("leaks", sum(hits.values()), ",".join(f"{k}={n}" for k, n in hits.items() if n))
print("errs", ",".join(f"{k}={n}" for k, n in errs.items()))
print("lines", logs.count("\n"))
PY
rm -f "$OUT/.s.json" "$OUT/.logs.txt"
keys=$(sed -n 's/^keys //p' "$OUT/.py.txt"); open=$(sed -n 's/^open //p' "$OUT/.py.txt")
leaks=$(sed -n 's/^leaks //p' "$OUT/.py.txt"); errs=$(sed -n 's/^errs //p' "$OUT/.py.txt"); lines=$(sed -n 's/^lines //p' "$OUT/.py.txt")
rm -f "$OUT/.py.txt"
nkeys=${keys%% *}
[ "${nkeys:-0}" -ge 1 ] && [ -z "$open" ] && add D0.3 ok "secret $S keys set" "${keys#* }" \
  || add D0.3 FAIL "secret $S keys set" "keys: ${keys:-none}; empty or placeholder: ${open:-none}"
[ "${leaks%% *}" = 0 ] && add D3.1 ok "no secret value in the pod logs" "$lines log lines searched" \
  || add D3.1 FAIL "no secret value in the pod logs" "found: ${leaks#* } (counts per key name)"
echo "$errs" | grep -qE '=[1-9]' && add D0.4 FAIL "backend reachable (no TLS/DNS/timeout errors in logs)" "$errs" \
  || add D0.4 ok "backend reachable (no TLS/DNS/timeout errors in logs)" "$errs"

{ echo "# Dev deployment check: $([ $bad = 0 ] && echo PASS || echo FAIL)"; echo
  echo "Namespace $NS, integration $I, secret $S, $(date '+%Y-%m-%d %H:%M')."; echo
  echo "| ID | Result | Check | Detail |"; echo "|---|---|---|---|"; printf '%s\n' "${rows[@]}"; } > "$OUT/DEV_CHECK.md"
echo "dev check: $([ $bad = 0 ] && echo PASS || echo FAIL) -> $OUT/DEV_CHECK.md"
exit $bad
