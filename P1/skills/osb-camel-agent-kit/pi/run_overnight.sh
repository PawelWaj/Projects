#!/usr/bin/env bash
# Unattended run: works through a domain stage in small steps, pauses when the model quota is used up, tries again,
# and stops at a deadline. Start it, go home, read the log and the report in the morning.
#
# Usage (in the workspace, .osb-kit.env loaded, MASK_KEY exported):
#   bash <kit>/pi/run_overnight.sh <stage> [hours]          e.g.  POC=1 PROJECTS='a-prj' bash .../run_overnight.sh functional 10
# Env: QUOTA_SLEEP (seconds to wait after the endpoint refused everything, default 1800), MAX_ROUNDS (default 12),
#      plus the run_domain.sh env.
# Every round runs `run_domain.sh <stage>`; finished flows are skipped, so each round only does what is left.
# Log: domain/overnight.log. At the end: domain/FUNCTIONAL_TEST_REPORT.md and domain/TIME_PROJECTION.md.
set -u
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
MVN_ARGS=${MVN_ARGS//\~/$HOME}   # "~" inside a variable is not expanded by the shell
STAGE=${1:?usage: run_overnight.sh <stage> [hours]}
HOURS=${2:-10}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
WS=${WS:-.}
LOG="$WS/domain/overnight.log"; mkdir -p "$WS/domain"
end=$(( $(date +%s) + HOURS * 3600 ))
round=0
echo "$(date '+%F %T') start: stage=$STAGE hours=$HOURS PROJECTS='${PROJECTS:-<all>}' BATCH_NO='${BATCH_NO:-}'" | tee -a "$LOG"
while [ "$(date +%s)" -lt "$end" ] && [ "$round" -lt "${MAX_ROUNDS:-12}" ]; do
  round=$((round + 1))
  echo "$(date '+%F %T') round $round" | tee -a "$LOG"
  # one tiny call first: on this endpoint a short call before a long run helped (login/token refresh or limit window)
  timeout 120 pi --print --no-session ${OSB_PI_MODEL:+--model "$OSB_PI_MODEL"} "Reply with the word OK" >> "$LOG" 2>&1 < /dev/null \
    || echo "$(date '+%F %T') warm-up call failed" >> "$LOG"
  ALL=${ALL:-1} bash "$KIT/pi/run_domain.sh" "$STAGE" "$WS" >> "$LOG" 2>&1 < /dev/null
  rc=$?
  tail -1 "$LOG"
  if [ "$rc" = 75 ] || tail -40 "$LOG" | grep -q "^STOP: the model endpoint"; then
    echo "$(date '+%F %T') quota used up: sleeping ${QUOTA_SLEEP:-1800}s" | tee -a "$LOG"
    sleep "${QUOTA_SLEEP:-1800}"; continue
  fi
  # nothing left to do when a round no longer starts any pi step
  if ! tail -n 200 "$LOG" | sed -n "/round $round\$/,\$p" | grep -qE "^=== (research|tests|build)"; then
    echo "$(date '+%F %T') nothing left for stage $STAGE: done" | tee -a "$LOG"; break
  fi
done
bash "$KIT/pi/run_domain.sh" report "$WS" >> "$LOG" 2>&1 < /dev/null
bash "$KIT/pi/run_domain.sh" time "$WS" >> "$LOG" 2>&1 < /dev/null
echo "$(date '+%F %T') finished after $round round(s); see domain/FUNCTIONAL_TEST_REPORT.md" | tee -a "$LOG"
