#!/usr/bin/env bash
# One OSB application (domain) with many projects and proxies: run the per-flow steps for all of them, keep going when
# one flow fails, and keep a status table. Safe to rerun: finished steps are skipped.
#
# Usage: pi/run_domain.sh <osb-app-dir> <stage> [workspace]
#   osb-app-dir  e.g. /e/osb-application (the folder holding the *-prj projects)
# Short form with APP in .osb-kit.env: run_domain.sh <stage> [workspace]
# BATCH_NO=n (with BATCH_SIZE, default 10): the n-th slice of the project list, no names to type; 'batches' lists them.
#   stage        list      projects and proxies found (no agent) -> domain/projects.txt, domain/flows.txt
#                batches   how many batches of BATCH_SIZE projects, with the command for each
#                coverage  which proxies get real Splunk test messages and which synthetic ones (needs SPLUNK_COVERAGE =
#                          CSV of the Splunk "stats count by project, proxy, payload" table) -> domain/COVERAGE.md
#                research  research pack per proxy -> <ws>/research/<project>/<proxy>/   (skips packs that PASS)
#                task1     Splunk test cases for every researched proxy, split by the fields its branches use
#                          (research scenario_dims) -> <ws>/task1/flows/<project>-<proxy>/   (needs EXPORT, MASK_KEY)
#                tests     FUNCTIONAL TESTS per researched proxy (no route needed): generated tests + mocks, real Splunk
#                          cases, synthetic cases from the schema where Splunk has none (pi tester), frozen, catalogue
#                          -> <ws>/modules/<project>/<proxy>/src/test/** + TEST_MATRIX.md
#                scaffold  same module without the tester step
#                build     implement + test + gates for every proxy whose card is approved
#                matrix    mutation check (route broken on purpose) + test matrix per flow and for the domain
#                functional  the whole proof: research -> task1 -> tests -> build -> matrix -> report
#                          (build needs approved cards, or POC=1 for a proof-of-concept run: cards marked, K1 FAIL)
#                estimate  model load per flow (calls, tokens, minutes) from the OSB source size + measured times
#                          (domain/timings.csv); quota via PI_RPM / PI_TPM -> domain/PI_LOAD_ESTIMATE.md
#                time      MEASURED time per pi step (work vs rate-limit waiting) and the projection for TOTAL_FLOWS
#                          (default 450) -> domain/TIME_PROJECTION.md
#                report    domain/FUNCTIONAL_TEST_REPORT.md: inputs, expected outputs, mocks, results, mutations per flow
#                flat      delivery/<app>/: Common-setup kamelets + per project ONE <domain>-route.yaml, <Flow>Transformer.java,
#                          <Flow>TransformerTest.java (assemble_flat.py; also the last step of functional)
#                auto      research -> task1 -> tests: the functional test pack for every flow, then stops
#                          (routes: approve the cards, then build and matrix)
#                status    only rewrite <ws>/domain/STATUS.md + status.csv
#   workspace    default: current folder
# PROJECTS matches whole project names: 'a-prj|b-.*' (regex, anchored).
# Env: PI_PAUSE (seconds between two flows in a pi stage, default 30: keeps under the model's rate limit),
#      PI_RETRIES / PI_BACKOFF (retries after a 429, see pi_call.sh),
#      PROJECTS (regex on project names, e.g. 'beneficiary|cancel-'), EXPORT (one Splunk CSV export with all flows of
#      the domain, raw or *.masked.csv), MASK_KEY, MVN_ARGS (e.g. "-s ~/.m2/settings.xml"), MUTATE=0 to skip mutations,
#      MASK_JSON_KEYS ('fieldA fieldB': extra JSON/XML fields to mask in task1, when the residue check finds one),
#      plus the env of run_research.sh / run_camelk.sh (OSB_PI_MODEL, ...).
set -uo pipefail
# local client settings, never in Git: $OSB_KIT_ENV, else ./.osb-kit.env, else ~/.osb-kit.env
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
MVN_ARGS=${MVN_ARGS//\~/$HOME}   # "~" inside a variable is not expanded by the shell
STAGES='list|batches|coverage|estimate|time|research|task1|tests|scaffold|build|matrix|report|functional|auto|status'
if echo "${1:-}" | grep -Eqx "($STAGES)"; then         # short form: run_domain.sh <stage> [workspace], APP from the env file
  STAGE=$1; WS=${2:-${WS:-.}}; APP=${APP:?set APP in .osb-kit.env or use: run_domain.sh <osb-app-dir> <stage>}
else
  APP=${1:?usage: run_domain.sh [<osb-app-dir>] <stage> [workspace]   stages: $STAGES}
  STAGE=${2:?stage}
  WS=${3:-${WS:-.}}
fi
case "$APP" in *\\*|[A-Za-z]:*) command -v cygpath >/dev/null && APP=$(cygpath -u "$APP");; esac
[ -d "$APP" ] || { echo "OSB application folder not found: $APP (Git Bash: /e/folder, not E:\\folder)"; exit 2; }
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
FILTER=${PROJECTS:-.*}
mkdir -p "$WS/domain"
SK="$KIT/skills/osb-camelk-route/scripts"; [ -d "$SK" ] || SK="$KIT/.pi/skills/osb-camelk-route/scripts"
BATCH=$(for d in "$KIT/../../vdi-osb-migration/bin" "$KIT/bin"; do [ -f "$d/batch_task1.py" ] && echo "$d/batch_task1.py" && break; done)
t1dir() { local d="$WS/task1/flows/$(echo "$1-$2" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//;s/-$//' | tr 'A-Z' 'a-z' | cut -c1-80)"; [ -d "$d/fixtures/parity" ] && echo "$d"; }

timed() {   # timed <project> <proxy> <stage> <command...>: run it, append the duration to domain/timings.csv
  local p=$1 x=$2 st=$3 t0 rc w; shift 3; t0=$(date +%s)
  export PI_WAIT_FILE="$WS/domain/.wait.$$"; : > "$PI_WAIT_FILE"
  "$@"; rc=$?
  w=$(awk '{s+=$1} END{print s+0}' "$PI_WAIT_FILE"); rm -f "$PI_WAIT_FILE"; unset PI_WAIT_FILE
  [ -f "$WS/domain/timings.csv" ] || echo "project,proxy,stage,seconds,waited,exit" > "$WS/domain/timings.csv"
  echo "$p,$x,$st,$(( $(date +%s) - t0 )),$w,$rc" >> "$WS/domain/timings.csv"
  return $rc
}

projects() {   # project folders (sorted), after PROJECTS; BATCH_NO=n keeps the n-th slice of BATCH_SIZE (default 10)
  local all
  all=$(for prj in "$APP"/*/; do p=$(basename "$prj"); [ "${p#.}" != "$p" ] && continue
        echo "$p" | grep -Eqx "($FILTER)" && find "$prj" -type f \( -name '*.proxy' -o -name '*.ProxyService' \) | grep -q . && echo "$p"; done)
  if [ -n "${BATCH_NO:-}" ]; then
    echo "$all" | awk -v n="$BATCH_NO" -v s="${BATCH_SIZE:-10}" 'NR > (n-1)*s && NR <= n*s'
  else echo "$all"; fi
}

flows() {   # "<project> <proxy>" for every proxy file (12c .proxy, sbconfig .ProxyService) in the selected projects
  for p in $(projects); do
    prj="$APP/$p/"
    find "$prj" -type f \( -name '*.proxy' -o -name '*.ProxyService' \) | sort | while read -r f; do
      n=$(basename "$f"); echo "$p ${n%.*}"
    done
  done
}

status() {
  local csv="$WS/domain/status.csv" md="$WS/domain/STATUS.md"
  echo "project,proxy,research,open_questions,test_cases,card,gates,tests" > "$csv"
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; m="$WS/modules/$p/$x"
    rs=-; [ -f "$r/SHARE_CHECK.json" ] && { grep -q '"pass": true' "$r/SHARE_CHECK.json" && rs=PASS || rs=FAIL; }
    oq=-; [ -s "$r/research.json" ] && oq=$("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1], encoding='utf-8')).get('open_questions') or []))" "$r/research.json")
    tc=-; [ -d "$m/src/test/resources/parity" ] && tc=$(find "$m/src/test/resources/parity" -name input.payload | wc -l | tr -d ' ')
    cs=-; [ -f "$m/FLOW_CARD.md" ] && { grep -qiE '^Status:[[:space:]]*approved' "$m/FLOW_CARD.md" && cs=approved || cs=draft; }
    gs=-; ts=-; if [ -f "$m/GATES.json" ]; then grep -q '"result": "PASS"' "$m/GATES.json" && gs=PASS || gs=FAIL
      ts=$("$PY" -c "import json,sys; g=json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}); print(f\"{g.get('tests','-')}/{g.get('failures','-')}F/{g.get('skipped','-')}S\")" "$m/GATES.json"); fi
    echo "$p,$x,$rs,$oq,$tc,$cs,$gs,$ts" >> "$csv"
  done
  { echo "# Domain status: $(basename "$APP")"; echo; echo "Generated $(date '+%F %H:%M'). research = pack check, card = FLOW_CARD.md, gates = check_camelk.py, tests = run/failed/skipped."; echo
    echo "| Project | Proxy | Research | Open questions | Test cases | Card | Gates | Tests |"; echo "|---|---|---|---|---|---|---|---|"
    tail -n +2 "$csv" | awk -F, '{printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6,$7,$8}'
    echo; tail -n +2 "$csv" | awk -F, '{n++; if($3=="PASS")r++; if($5!="-")t++; if($6=="approved")c++; if($7=="PASS")g++} END{printf "%d proxies: %d researched, %d with Splunk test cases, %d cards approved, %d green\n",n,r,t,c,g}'
  } > "$md"
  tail -1 "$md"
}

task1_of() {   # task-1 folder of a proxy: domain batch first, then TASK1_ROOT/<proxy>/task1
  local t; t=$(t1dir "$1" "$2"); [ -z "$t" ] && [ -n "${TASK1_ROOT:-}" ] && [ -d "$TASK1_ROOT/$2/task1" ] && t="$TASK1_ROOT/$2/task1"; echo "$t"
}

do_research() {
  flows | while read -r p x; do
    out="$WS/research/$p/$x"
    if [ -f "$out/SHARE_CHECK.json" ] && grep -q '"pass": true' "$out/SHARE_CHECK.json"; then echo "skip $p/$x (PASS)"; continue; fi
    echo "=== research $p/$x"
    t1=$(task1_of "$p" "$x")
    timed "$p" "$x" research bash -c 'cd "$1" && OUT="research/$2/$3" bash "$4/pi/run_research.sh" "$5/$2" "$3" ${6:+"$6"}' _ "$WS" "$p" "$x" "$KIT" "$APP" "$t1" < /dev/null
    rc=$?
    [ "$rc" = 75 ] && { echo "STOP: the model endpoint refuses every call (quota). Rerun later: finished flows are skipped."; return 75; }
    [ "$rc" = 0 ] || echo "FAILED research $p/$x (continuing)"
    sleep "${PI_PAUSE:-30}"
  done
}

do_task1() {   # one batch over the whole export; scenario fields per flow = what its branches decide on
  [ -n "${EXPORT:-}" ] && [ -f "$EXPORT" ] || { echo "task1 needs EXPORT=<Splunk CSV of the domain> (DOMAIN_RUN.md)"; return 2; }
  [ -n "$BATCH" ] || { echo "batch_task1.py not found (vdi-osb-migration/bin)"; return 2; }
  mkdir -p "$WS/task1"
  { echo "flow,domain,dims"
    flows | while read -r p x; do
      r="$WS/research/$p/$x/research.json"
      d=$([ -s "$r" ] && "$PY" -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')).get('scenario_dims') or []; print(';'.join(['hdr_resource'] + ['body:' + x.lstrip('/') for x in d]) if d else '')" "$r")
      echo "$p/$x,$(basename "$APP"),$d"
    done; } > "$WS/task1/flows.csv"
  case "$EXPORT" in *.masked.csv) am=--already-masked;; *) am=;; esac
  mk=(); for k in ${MASK_JSON_KEYS:-}; do mk+=(--mask-json-key "$k"); done      # extra fields to mask, space separated
  "$PY" "$BATCH" "$EXPORT" -o "$WS/task1" --flows "$WS/task1/flows.csv" $am "${mk[@]}" || {
    echo "some flows need a look: $WS/task1/SUMMARY.md"
    [ -f "$WS/task1/events.masked.csv.report.json" ] && "$PY" -c "import json,sys; r=json.load(open(sys.argv[1], encoding='utf-8'))['residue_check']; [print('   residue:', w) for w in r['where']]" "$WS/task1/events.masked.csv.report.json"
    echo "   fix: MASK_JSON_KEYS='<field> <field>' on the same line, then rerun task1 (arabic-script = Arabic text in a field not masked by name)"; }
}

do_scaffold() {
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; [ -s "$r/research.json" ] || continue
    t1=$(task1_of "$p" "$x")
    "$PY" "$SK/scaffold_camelk.py" "$r" -o "$WS/modules/$p/$x" --project "$p" ${t1:+--parity "$t1/fixtures/parity"} \
      || echo "FAILED scaffold $p/$x (continuing)"
  done
}

do_tests() {
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; [ -s "$r/research.json" ] || continue
    echo "=== tests $p/$x"
    t1=$(task1_of "$p" "$x")
    OSB_SRC="$APP/$p" timed "$p" "$x" tests bash "$KIT/pi/run_tests.sh" "$r" "$WS/modules/$p/$x" "$p" ${t1:+"$t1"} < /dev/null | grep -E "rate limit|^\{" || echo "INCOMPLETE tests $p/$x (continuing)"
    sleep "${PI_PAUSE:-30}"
  done
  "$PY" "$SK/test_matrix.py" --domain "$WS/modules" -o "$WS/domain" > /dev/null || true
}

do_build() {
  flows | while read -r p x; do
    m="$WS/modules/$p/$x"; [ -f "$m/FLOW_CARD.md" ] || continue
    grep -qiE '^Status:[[:space:]]*(approved|poc-run)' "$m/FLOW_CARD.md" || [ "${POC:-0}" = 1 ] || { echo "skip $p/$x (card not approved; POC=1 for a proof-of-concept build)"; continue; }
    if [ -f "$m/GATES.json" ] && "$PY" -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}).get('ok') else 1)" "$m/GATES.json"; then echo "skip $p/$x (tests green)"; continue; fi
    echo "=== build $p/$x"
    t1=$(task1_of "$p" "$x")
    OSB_SRC="$APP/$p" timed "$p" "$x" build bash "$KIT/pi/run_camelk.sh" "$WS/research/$p/$x" "$m" "$p" ${t1:+"$t1"} < /dev/null || echo "NOT GREEN $p/$x (continuing)"
    sleep "${PI_PAUSE:-30}"
  done
}

do_matrix() {   # mutation check on every green module (MUTATE=0 skips it), then the matrices
  flows | while read -r p x; do
    m="$WS/modules/$p/$x"; [ -f "$m/.scaffold.json" ] || continue
    if [ "${MUTATE:-1}" = 1 ] && [ -f "$m/GATES.json" ] && "$PY" -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}).get('ok') else 1)" "$m/GATES.json" && [ ! -f "$m/MUTATION.json" ]; then
      echo "=== mutations $p/$x"; "$PY" "$SK/mutate_route.py" "$m" --mvn "mvn -B -q ${MVN_ARGS:-}"
      case $? in 0) ;; 1) echo "MUTATION SURVIVED $p/$x: tests too weak (see $m/MUTATION.json)";;
                 *) echo "MUTATION CHECK DID NOT RUN for $p/$x (message above)";; esac
    fi
  done
  "$PY" "$SK/test_matrix.py" --domain "$WS/modules" -o "$WS/domain"
}

# pi runs are slow and cost tokens: show the selection, and require ALL=1 for more than 10 flows
case "$STAGE" in research|tests|build|auto|functional)
  n=$(flows | wc -l | tr -d ' ')
  echo "selected: $n proxies (PROJECTS='${PROJECTS:-<all>}')"
  if [ "$n" -gt 10 ] && [ "${ALL:-0}" != 1 ] && [ -z "${BATCH_NO:-}" ]; then
    echo "more than 10 proxies for a pi stage: set PROJECTS='a-prj|b-prj' on the SAME line, or ALL=1 to run them all"; exit 2
  fi;;
esac

case "$STAGE" in
  list) flows | tee "$WS/domain/flows.txt" | awk '{print} END{print NR " proxies"}'
        projects > "$WS/domain/projects.txt"
        echo "$(wc -l < "$WS/domain/projects.txt" | tr -d ' ') projects -> domain/projects.txt, domain/flows.txt" ;;
  batches) np=$(BATCH_NO= projects | wc -l | tr -d ' '); nb=$(( (np + ${BATCH_SIZE:-10} - 1) / ${BATCH_SIZE:-10} ))
        echo "$np projects = $nb batches of ${BATCH_SIZE:-10} projects. Run them one after the other:"
        for b in $(seq 1 "$nb"); do echo "  BATCH_NO=$b bash $KIT/pi/run_domain.sh functional    # $(BATCH_NO=$b projects | paste -sd' ' - | cut -c1-90)"; done ;;
  coverage)
    [ -n "${SPLUNK_COVERAGE:-}" ] && [ -f "$SPLUNK_COVERAGE" ] || { echo "coverage needs SPLUNK_COVERAGE=<csv of the Splunk payload table>"; exit 2; }
    "$PY" "$KIT/skills/osb-to-camel/scripts/osb_inventory.py" "$APP" -o "$WS/domain/inventory" > /dev/null
    "$PY" "$(dirname "$BATCH")/domain_coverage.py" "$WS/domain/inventory" "$SPLUNK_COVERAGE" -o "$WS/domain/COVERAGE.md" ;;
  research) do_research; rc=$?; status; exit $rc ;;
  task1) do_task1; status ;;
  tests) do_tests; status ;;
  scaffold) do_scaffold; status ;;
  build) do_build; status ;;
  matrix) do_matrix; status ;;
  auto) do_research; do_task1; do_tests; status
        echo "functional test packs: modules/<project>/<proxy>/src/test + TEST_MATRIX.md; domain catalogue: domain/TEST_MATRIX.md" ;;
  estimate)
    [ -d "$WS/domain/inventory/flows" ] || "$PY" "$KIT/skills/osb-to-camel/scripts/osb_inventory.py" "$APP" -o "$WS/domain/inventory" > /dev/null
    "$PY" "$(dirname "$BATCH")/estimate_pi_load.py" "$WS/domain/inventory" "$APP" --coverage "$WS/domain/coverage.csv" \
      --timings "$WS/domain/timings.csv" --rpm "${PI_RPM:-20}" --tpm "${PI_TPM:-200000}" -o "$WS/domain/PI_LOAD_ESTIMATE.md" ;;
  time) "$PY" "$(dirname "$BATCH")/time_projection.py" "$WS/domain/timings.csv" --flows "${TOTAL_FLOWS:-450}" \
          --coverage "$WS/domain/coverage.csv" -o "$WS/domain/TIME_PROJECTION.md" ;;
  report) status > /dev/null; "$PY" "$SK/domain_report.py" "$WS" ;;
  flat) "$PY" "$SK/assemble_flat.py" "$WS" --app "$(basename "${APP:-osb-app}")" ${PROJECTS:+--projects "$PROJECTS"} ;;
  functional) do_research || { status > /dev/null; exit 75; }; do_task1; do_tests; do_build; do_matrix; status > /dev/null; "$PY" "$SK/domain_report.py" "$WS"
              "$PY" "$SK/assemble_flat.py" "$WS" --app "$(basename "${APP:-osb-app}")" ${PROJECTS:+--projects "$PROJECTS"} ;;
  status) status ;;
  *) echo "unknown stage: $STAGE"; exit 2 ;;
esac
