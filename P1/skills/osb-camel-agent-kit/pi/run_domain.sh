#!/usr/bin/env bash
# One OSB application (domain) with many projects and proxies: run the per-flow steps for all of them, keep going when
# one flow fails, and keep a status table. Safe to rerun: finished steps are skipped.
#
# Usage: pi/run_domain.sh <osb-app-dir> <stage> [workspace]
#   osb-app-dir  e.g. /e/contributor-agreement-mb-app (the folder holding the *-prj projects)
#   stage        list      projects and proxies found (no agent)
#                research  research pack per proxy -> <ws>/research/<project>/<proxy>/   (skips packs that PASS)
#                scaffold  module + FLOW_CARD.md per researched proxy -> <ws>/modules/<project>/<proxy>/
#                build     implement + test + gates for every proxy whose card is approved
#                status    only rewrite <ws>/domain/STATUS.md + status.csv
#   workspace    default: current folder
# Env: PROJECTS (regex on project names, e.g. 'beneficiary|cancel-'), TASK1_ROOT (folder with <proxy>/task1 from the
#      Splunk step), plus the env of run_research.sh / run_camelk.sh (OSB_PI_MODEL, MVN_ARGS, ...).
set -uo pipefail
APP=${1:?usage: run_domain.sh <osb-app-dir> <list|research|scaffold|build|status> [workspace]}
STAGE=${2:?stage}
WS=${3:-.}
case "$APP" in *\\*|[A-Za-z]:*) command -v cygpath >/dev/null && APP=$(cygpath -u "$APP");; esac
[ -d "$APP" ] || { echo "OSB application folder not found: $APP (Git Bash: /e/folder, not E:\\folder)"; exit 2; }
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
FILTER=${PROJECTS:-.}
mkdir -p "$WS/domain"

flows() {   # "<project> <proxy>" for every proxy file (12c .proxy, sbconfig .ProxyService) in every project folder
  for prj in "$APP"/*/; do
    p=$(basename "$prj"); case "$p" in .*) continue;; esac
    echo "$p" | grep -Eq "$FILTER" || continue
    find "$prj" -type f \( -name '*.proxy' -o -name '*.ProxyService' \) | sort | while read -r f; do
      n=$(basename "$f"); echo "$p ${n%.*}"
    done
  done
}

status() {
  local csv="$WS/domain/status.csv" md="$WS/domain/STATUS.md"
  echo "project,proxy,research,card,gates,tests" > "$csv"
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; m="$WS/modules/$p/$x"
    rs=-; [ -f "$r/SHARE_CHECK.json" ] && { grep -q '"pass": true' "$r/SHARE_CHECK.json" && rs=PASS || rs=FAIL; }
    cs=-; [ -f "$m/FLOW_CARD.md" ] && { grep -qiE '^Status:[[:space:]]*approved' "$m/FLOW_CARD.md" && cs=approved || cs=draft; }
    gs=-; ts=-; if [ -f "$m/GATES.json" ]; then grep -q '"result": "PASS"' "$m/GATES.json" && gs=PASS || gs=FAIL
      ts=$("$PY" -c "import json,sys; g=json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}); print(f\"{g.get('tests','-')}/{g.get('failures','-')}F/{g.get('skipped','-')}S\")" "$m/GATES.json"); fi
    echo "$p,$x,$rs,$cs,$gs,$ts" >> "$csv"
  done
  { echo "# Domain status: $(basename "$APP")"; echo; echo "Generated $(date '+%F %H:%M'). research = pack check, card = FLOW_CARD.md, gates = check_camelk.py, tests = run/failed/skipped."; echo
    echo "| Project | Proxy | Research | Card | Gates | Tests |"; echo "|---|---|---|---|---|---|"
    tail -n +2 "$csv" | awk -F, '{printf "| %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6}'
    echo; tail -n +2 "$csv" | awk -F, '{n++; if($3=="PASS")r++; if($4=="approved")c++; if($5=="PASS")g++} END{printf "%d proxies: %d researched, %d cards approved, %d green\n",n,r,c,g}'
  } > "$md"
  tail -1 "$md"
}

case "$STAGE" in
  list) flows | awk '{print} END{print NR " proxies"}' ;;
  research)
    flows | while read -r p x; do
      out="$WS/research/$p/$x"
      if [ -f "$out/SHARE_CHECK.json" ] && grep -q '"pass": true' "$out/SHARE_CHECK.json"; then echo "skip $p/$x (PASS)"; continue; fi
      echo "=== research $p/$x"
      t1="${TASK1_ROOT:+$TASK1_ROOT/$x/task1}"; [ -n "$t1" ] && [ ! -d "$t1" ] && t1=""
      (cd "$WS" && OUT="research/$p/$x" bash "$KIT/pi/run_research.sh" "$APP/$p" "$x" ${t1:+"$t1"}) < /dev/null || echo "FAILED research $p/$x (continuing)"
    done; status ;;
  scaffold)
    flows | while read -r p x; do
      r="$WS/research/$p/$x"; [ -s "$r/research.json" ] || continue
      "$PY" "$KIT/skills/osb-camelk-route/scripts/scaffold_camelk.py" "$r" -o "$WS/modules/$p/$x" --project "$p" \
        ${TASK1_ROOT:+--parity "$TASK1_ROOT/$x/task1/fixtures/parity"} || echo "FAILED scaffold $p/$x (continuing)"
    done; status ;;
  build)
    flows | while read -r p x; do
      m="$WS/modules/$p/$x"; [ -f "$m/FLOW_CARD.md" ] || continue
      grep -qiE '^Status:[[:space:]]*approved' "$m/FLOW_CARD.md" || { echo "skip $p/$x (card not approved)"; continue; }
      if [ -f "$m/GATES.json" ] && grep -q '"result": "PASS"' "$m/GATES.json"; then echo "skip $p/$x (gates PASS)"; continue; fi
      echo "=== build $p/$x"
      t1="${TASK1_ROOT:+$TASK1_ROOT/$x/task1}"; [ -n "$t1" ] && [ ! -d "$t1" ] && t1=""
      OSB_SRC="$APP/$p" bash "$KIT/pi/run_camelk.sh" "$WS/research/$p/$x" "$m" "$p" ${t1:+"$t1"} < /dev/null || echo "NOT GREEN $p/$x (continuing)"
    done; status ;;
  status) status ;;
  *) echo "unknown stage: $STAGE"; exit 2 ;;
esac
