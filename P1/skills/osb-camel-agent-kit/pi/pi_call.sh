#!/usr/bin/env bash
# Sourced by the pi runners. pi_call <out-file> <err-file> <pi args...>
# Runs pi; when the model endpoint answers 429 / rate limit / overloaded, waits and retries with a growing pause.
# Env: PI_RETRIES (default 5), PI_BACKOFF (first pause in seconds, default 60, doubled each time, max 15 min).
pi_call() {
  local out=$1 err=$2; shift 2
  local n=0 wait=${PI_BACKOFF:-60}
  while :; do
    "$@" > "$out" 2> "$err" && return 0
    if grep -qiE '(^|[^0-9])429([^0-9]|$)|too many requests|rate.?limit|overloaded|503 service unavailable' "$err" 2>/dev/null \
       && [ "$n" -lt "${PI_RETRIES:-5}" ]; then
      n=$((n + 1))
      echo "   model endpoint busy (rate limit), waiting ${wait}s, retry $n/${PI_RETRIES:-5}"
      sleep "$wait"
      wait=$((wait * 2)); [ "$wait" -gt 900 ] && wait=900
      continue
    fi
    return 1
  done
}
