#!/usr/bin/env bash
# Local acceptance: the end solution tested on this machine, the gate before Dev. No POC exceptions.
#   bash <kit>/pi/local_acceptance.sh '<a-prj|b-prj>'          (in the workspace; .osb-kit.env is read)
# Per work module of the project(s), in order; the first FAIL stops that module (log path printed):
#   1 card     FLOW_CARD.md approved (Status/Approver, no open question), card hash refrozen
#   2 tests    Maven tests + gates K1-K12 (verify_module.py): failures 0, errors 0, every gate ok incl. K1
#   3 mutate   every mutation caught (mutate_route.py), or the reason written in MUTATION_ACCEPTED.md
#   4 run      the route run as Camel K runs it, with Camel JBang (no Maven build of the module):
#              HTTP flows: smoke_http.py --engine jbang (stub backend, every case over HTTP, forced 500)
#              JMS flows:  ENGINE=jbang broker/e2e_local.sh on the local Artemis (one case per scenario, queue counts)
#   5 manifest camel-k/integration.yaml generated and checked (check_manifest.py): structure, sources identical,
#              secrets only as references, ready or only per-environment values open
#   6 review   review package (make_review_pack.sh), newer than everything above
# Output: <module>/LOCAL_ACCEPTANCE.md + .json, last line "LOCAL ACCEPTANCE: PASS|FAIL <module>". Exit 0 only when
# every module passed. Needs: ARTEMIS_PASSWORD exported (JMS flows), the broker running, jbang/Camel via Nexus.
set -u
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
P=${1:?usage: local_acceptance.sh '<a-prj|b-prj>'}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
WS=${WS:-$(pwd)}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
SK="$KIT/skills/osb-camelk-route/scripts"
MVN_ARGS=${MVN_ARGS//\~/$HOME}
export VERIFY_MVN="mvn -B -q ${MVN_ARGS:-}"
KV=$(cd "$KIT/../.." 2>/dev/null && git log --oneline -1 2>/dev/null | cut -c1-7)
KV=${KV:-zip}
all=0; n=0

json_get() { "$PY" -c "import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
v=d
for k in sys.argv[2].split('.'): v=v.get(k) if isinstance(v,dict) else None
print(v)" "$1" "$2"; }

accept_module() {   # $1 project  $2 proxy
  local p=$1 x=$2 m="$WS/modules/$1/$2" log t0 rc res=() status=PASS failed=""
  log="$WS/domain/acceptance/$p-$x"; mkdir -p "$log"   # not under target/: mvn clean would remove it
  add() { res+=("$1|$2|$3|$4"); printf '  %-9s %-4s %4ss  %s\n' "$1" "$2" "$3" "$4"; }   # step ok secs detail
  fail() { add "$1" FAIL "$2" "$3"; status=FAIL; failed=$1; }
  echo "=== local acceptance $p/$x (kit $KV)"

  # 1 card
  t0=$SECONDS
  if grep -qiE '^Status:[[:space:]]*approved[[:space:]]*$' "$m/FLOW_CARD.md" && grep -qE '^Approver:[[:space:]]*[^[:space:]]' "$m/FLOW_CARD.md" \
     && ! grep -q '^- \[ \]' "$m/FLOW_CARD.md"; then
    "$PY" -c "import hashlib,json,sys; p=sys.argv[1]; d=json.load(open(p)); d['card_sha256']=hashlib.sha256(open(sys.argv[2],'rb').read()).hexdigest(); json.dump(d,open(p,'w'),indent=2)" "$m/.scaffold.json" "$m/FLOW_CARD.md"
    add card ok $((SECONDS - t0)) "approved by $(sed -n 's/^Approver:[[:space:]]*//p' "$m/FLOW_CARD.md" | head -1), card hash refrozen"
  else
    fail card $((SECONDS - t0)) "not approved or open questions left: python $SK/card_answers.py $m"
  fi

  # 2 tests + gates
  if [ "$status" = PASS ]; then
    t0=$SECONDS
    "$PY" "$SK/verify_module.py" "$m" > "$log/2-tests.txt" 2>&1; rc=$?
    line=$(grep -m1 -E '^tests [0-9]+' "$log/2-tests.txt")
    bad=$("$PY" -c "import json,sys; g=json.load(open(sys.argv[1]))['gates']; print(','.join(k.split('_')[0] for k,v in g.items() if not v.get('ok')))" "$m/GATES.json" 2>/dev/null)
    if [ "$rc" = 0 ] && [ -z "$bad" ] && echo "$line" | grep -qE 'failures 0, errors 0'; then add tests ok $((SECONDS - t0)) "${line}; gates K1-K12 ok"
    else fail tests $((SECONDS - t0)) "${line:-no test run}; gates failed: ${bad:-?} (log $log/2-tests.txt)"; fi
  fi

  # 3 mutations
  if [ "$status" = PASS ]; then
    t0=$SECONDS
    "$PY" "$SK/mutate_route.py" "$m" --mvn "mvn -B -q ${MVN_ARGS:-}" > "$log/3-mutations.txt" 2>&1; rc=$?
    line=$(grep -m1 -E 'mutations caught' "$log/3-mutations.txt")
    if [ "$rc" = 0 ]; then add mutate ok $((SECONDS - t0)) "${line:-all caught}"
    elif "$PY" -c "import json,sys,pathlib
s=[z['what'] for z in json.load(open(sys.argv[1])).get('mutations',[]) if not z.get('killed')]
a=pathlib.Path(sys.argv[2]); t=a.read_text(encoding='utf-8') if a.is_file() else ''
sys.exit(0 if s and all(x in t for x in s) else 1)" "$m/MUTATION.json" "$m/MUTATION_ACCEPTED.md" 2>/dev/null; then
      add mutate ok $((SECONDS - t0)) "${line}; every survivor named with its reason in MUTATION_ACCEPTED.md"
    else fail mutate $((SECONDS - t0)) "${line:-mutation check did not run}: strengthen the scenario, or name each survivor with its reason in $m/MUTATION_ACCEPTED.md (log $log/3-mutations.txt)"; fi
  fi

  # 4 run with Camel JBang
  if [ "$status" = PASS ]; then
    t0=$SECONDS
    if grep -q '^flow.input=platform-http:' "$m/src/main/resources/application.properties"; then
      "$PY" "$SK/smoke_http.py" "$m" --engine jbang > "$log/4-run.txt" 2>&1; rc=$?
      line=$(grep -E '^smoke:' "$log/4-run.txt" | tail -1)
      kind="HTTP, Camel JBang"
    else
      if [ -z "${ARTEMIS_PASSWORD:-}" ]; then rc=9; line="export ARTEMIS_PASSWORD first (JMS flow on the local Artemis)"
      else
        ENGINE=jbang bash "$KIT/broker/e2e_local.sh" "$m" > "$log/4-run.txt" 2>&1; rc=$?
        line="$(grep -E '^RESULT|differ|all .* OK' "$log/4-run.txt" | tail -1) ($(json_get "$m/target/e2e-result.json" cases) cases)"
      fi
      kind="JMS on the local Artemis, Camel JBang"
    fi
    if [ "$rc" = 0 ]; then add run ok $((SECONDS - t0)) "$kind: $line"
    else fail run $((SECONDS - t0)) "$kind: ${line:-did not run} (log $log/4-run.txt)"; fi
  fi

  # 5 manifest
  if [ "$status" = PASS ]; then
    t0=$SECONDS
    "$PY" "$SK/camelk_manifests.py" "$m" > "$log/5-manifest.txt" 2>&1
    "$PY" "$SK/check_manifest.py" "$m" >> "$log/5-manifest.txt" 2>&1; rc=$?
    line=$(grep -E '^(ok  |FAIL) ready' "$log/5-manifest.txt" | sed 's/^ok   ready: //; s/^FAIL ready: //')
    if [ "$rc" = 0 ]; then add manifest ok $((SECONDS - t0)) "integration.yaml checked; $line"
    else fail manifest $((SECONDS - t0)) "$(grep -m1 '^FAIL' "$log/5-manifest.txt") (log $log/5-manifest.txt)"; fi
  fi

  # 6 review package
  if [ "$status" = PASS ]; then
    t0=$SECONDS
    bash "$KIT/pi/make_review_pack.sh" "$p" "$x" > "$log/6-review.txt" 2>&1; rc=$?
    tgz="$WS/review/$p-$x.tgz"
    if [ "$rc" = 0 ] && [ -f "$tgz" ] && [ "$tgz" -nt "$m/GATES.json" ]; then add review ok $((SECONDS - t0)) "review/$p-$x.tgz"
    else fail review $((SECONDS - t0)) "review package not written (log $log/6-review.txt)"; fi
  fi

  "$PY" - "$m" "$status" "$KV" "${failed:-}" "${res[@]}" <<'PYEOF'
import json, sys, datetime
m, status, kv, failed, rows = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
steps = [dict(zip(("step", "ok", "seconds", "detail"), r.split("|", 3))) for r in rows]
d = {"module": m, "result": status, "failed_step": failed or None, "kit": kv, "engine": "camel-jbang",
     "date": datetime.datetime.now().isoformat(timespec="seconds"), "steps": steps}
open(f"{m}/LOCAL_ACCEPTANCE.json", "w", encoding="utf-8").write(json.dumps(d, indent=2))
L = [f"# Local acceptance: {status}", "", f"Module `{m}`, kit {kv}, {d['date']}, route run with Camel JBang (as on Camel K).", "",
     "| Step | Result | Seconds | Detail |", "|---|---|---|---|"]
L += [f"| {s['step']} | {s['ok']} | {s['seconds']} | {s['detail']} |" for s in steps]
open(f"{m}/LOCAL_ACCEPTANCE.md", "w", encoding="utf-8").write("\n".join(L) + "\n")
PYEOF
  echo "LOCAL ACCEPTANCE: $status $p/$x"
  [ "$status" = PASS ]
}

while read -r p x; do
  [ -f "$WS/modules/$p/$x/.scaffold.json" ] || { echo "skip $p/$x (no work module yet: run flows first)"; continue; }
  n=$((n + 1))
  accept_module "$p" "$x" || all=1
done < <(for d in "$WS"/modules/*/*/; do d=${d%/}; x=${d##*/}; p=${d%/*}; p=${p##*/}; echo "$p $x"; done | grep -E "^($P) ")
[ "$n" -gt 0 ] || { echo "no work module under $WS/modules matches '$P'"; exit 2; }
exit $all
