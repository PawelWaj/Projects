#!/usr/bin/env bash
# Sourced by the pi runners. pi_call <out-file> <err-file> <pi args...>
# Runs pi; when the model endpoint answers 429 / rate limit / overloaded, waits and retries with a growing pause.
# Env: PI_RETRIES (default 5), PI_BACKOFF (first pause in seconds, default 60, doubled each time, max 15 min).
# Exit 75 when the endpoint still refuses after all retries (quota used up): the runners stop instead of moving on.
# PI_TIMEOUT (seconds, default 1800): a single pi run that takes longer is killed (a hanging call never returns);
# exit 124 = timed out.
pi_call() {   # every FLOW_CARD.md is a person's decision: pi may read it, any change it makes is undone
  local guard c b rc
  guard=$(mktemp -d 2>/dev/null || { mkdir -p "${TMPDIR:-/tmp}/picards.$$" && echo "${TMPDIR:-/tmp}/picards.$$"; })
  for c in "${WS:-.}"/modules/*/*/FLOW_CARD.md; do [ -f "$c" ] && cp "$c" "$guard/$(printf '%s' "$c" | tr '/: ' '___')"; done
  _pi_call_inner "$@"; rc=$?
  for c in "${WS:-.}"/modules/*/*/FLOW_CARD.md; do
    b="$guard/$(printf '%s' "$c" | tr '/: ' '___')"
    if [ -f "$b" ] && ! cmp -s "$b" "$c"; then
      cp "$b" "$c"; echo "   pi changed $c: change undone (only a person edits a flow card)"
      [ -n "${WS:-}" ] && echo "$(date '+%F %T') card restored: $c" >> "$WS/domain/card-guard.log" 2>/dev/null
    fi
  done
  rm -rf "${guard:?}"
  return $rc
}

_pi_call_inner() {
  local out=$1 err=$2; shift 2
  local n=0 wait=${PI_BACKOFF:-60}
  while :; do
    if command -v timeout >/dev/null 2>&1; then
      timeout --kill-after=30 "${PI_TIMEOUT:-1800}" "$@" > "$out" 2> "$err"
      local rc=$?
      [ $rc = 0 ] && return 0
      if [ $rc = 124 ] || [ $rc = 137 ]; then
        echo "   pi did not finish within ${PI_TIMEOUT:-1800}s (hanging call), stopped it"; return 124
      fi
    else   # no `timeout` (macOS): a watchdog kills the run after PI_TIMEOUT
      "$@" > "$out" 2> "$err" & local pid=$!
      rm -f "$err.timeout"
      ( sleep "${PI_TIMEOUT:-1800}"; kill -0 "$pid" 2>/dev/null || exit 0; touch "$err.timeout"; kill -TERM "$pid" 2>/dev/null
        sleep 30; kill -KILL "$pid" 2>/dev/null ) &
      local dog=$!
      wait "$pid"; local rc=$?
      kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
      [ $rc = 0 ] && return 0
      if [ -f "$err.timeout" ]; then
        rm -f "$err.timeout"; echo "   pi did not finish within ${PI_TIMEOUT:-1800}s (hanging call), stopped it"; return 124
      fi
    fi
    if grep -qiE '(^|[^0-9])429([^0-9]|$)|too many requests|rate.?limit|overloaded|503 service unavailable' "$err" 2>/dev/null \
       && [ "$n" -lt "${PI_RETRIES:-5}" ]; then
      n=$((n + 1))
      echo "   model endpoint busy (rate limit), waiting ${wait}s, retry $n/${PI_RETRIES:-5}"
      sleep "$wait"
      [ -n "${PI_WAIT_FILE:-}" ] && echo "$wait" >> "$PI_WAIT_FILE"     # rate-limit waiting, measured separately
      wait=$((wait * 2)); [ "$wait" -gt 900 ] && wait=900
      continue
    fi
    if grep -qiE '(^|[^0-9])429([^0-9]|$)|too many requests|rate.?limit|overloaded' "$err" 2>/dev/null; then
      echo "   model endpoint still refuses after ${PI_RETRIES:-5} retries: quota used up? stopping (exit 75)"
      return 75
    fi
    return 1
  done
}
