#!/usr/bin/env bash
# Preflight for the VDI workflow: what is present, what is missing, and which gate each gap affects. Never fails hard;
# prints a table and a count. Run from the migration workspace root.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd); WS=$(pwd)
KIT=${KIT:-$([ -d "$REPO/skills/osb-camel-agent-kit" ] && echo "$REPO/skills/osb-camel-agent-kit" || echo "$WS")}
REPLAY=${REPLAY:-$([ -d "$REPO/osb-log-replay" ] && echo "$REPO/osb-log-replay" || echo "$WS/log-replay")}
fail=0
row() { printf '  %-6s %-28s %s\n' "$1" "$2" "$3"; [ "$1" = "FAIL" ] && fail=$((fail+1)); }
has() { command -v "$1" >/dev/null 2>&1; }

echo "VDI preflight ($WS)"
has python3 || has python || has py; [ $? -eq 0 ] && row OK python "$(command -v python3 || command -v python || command -v py)" || row FAIL python "phases 1-5 need Python 3"
if has java; then v=$(java -version 2>&1 | head -1); case "$v" in *\"21*|*\"2[2-9]*) row OK "java" "$v";; *) row FAIL "java" "$v (JDK 21 needed for the Camel 4 module)";; esac; else row FAIL java "not on PATH (G1-G5)"; fi
has mvn && row OK maven "$(mvn -v 2>/dev/null | head -1)" || row FAIL maven "not on PATH (G1-G5)"
if has docker && docker info >/dev/null 2>&1; then row OK containers docker; elif has podman && podman info >/dev/null 2>&1; then row OK containers podman; else row WARN containers "none reachable: G5 and L3 replay NOT_RUN (run them on Jenkins)"; fi
has pi && row OK pi "$(pi --version 2>/dev/null | head -1)" || row FAIL pi "agent not on PATH (phases 6-7)"
[ -n "${MASK_KEY:-}" ] && row OK MASK_KEY "set (${#MASK_KEY} chars)" || row WARN MASK_KEY "not set: needed when a Splunk CSV is processed"
[ -f "$KIT/pi/run_flow.sh" ] && row OK kit "$KIT" || row FAIL kit "run_flow.sh not found (KIT=$KIT)"
S=$([ -d "$KIT/skills/osb-to-camel" ] && echo "$KIT/skills/osb-to-camel" || echo "$KIT/.pi/skills/osb-to-camel")
[ -f "$S/SKILL.md" ] && row OK skill "$S" || row FAIL skill "osb-to-camel not installed"
[ -f "$REPLAY/tools/osb_log_traces.py" ] && row OK log-replay "$REPLAY" || row FAIL log-replay "tools missing (REPLAY=$REPLAY)"
[ -f "$KIT/tools/golden_runner.py" ] && row OK golden-runner "$KIT/tools/golden_runner.py" || row FAIL golden-runner "missing (G10)"
j=$(ls ~/.m2/repository/net/sf/saxon/Saxon-HE/*/Saxon-HE-*.jar 2>/dev/null | tail -1); [ -n "${SAXON_JAR:-}" ] && j=$SAXON_JAR
[ -n "$j" ] && row OK saxon "$j" || row WARN saxon "no Saxon-HE jar: mvn dependency:get -Dartifact=net.sf.saxon:Saxon-HE:12.9 (golden oracle)"
ls .pi/prompts/osb-*.md >/dev/null 2>&1 && row OK pi-prompts ".pi/prompts/osb-*.md" || row WARN pi-prompts "copy $KIT/pi/prompts/*.md to .pi/prompts and trust the project (pi --approve)"
[ -f "$KIT/pi/preflight.sh" ] && { echo "  --- kit preflight"; bash "$KIT/pi/preflight.sh" 2>&1 | sed 's/^/  /' | tail -15; }
echo "$fail blocking gaps"
exit 0
