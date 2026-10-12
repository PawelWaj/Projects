#!/usr/bin/env bash
# Preflight for the client VDI: checks everything the kit needs before the first run.
# Runs in Git Bash (Windows), WSL or Linux. Read-only: installs nothing, changes nothing.
# Usage: pi/preflight.sh [model-endpoint-url]
set -u
ok=0; warn=0; fail=0
pass() { printf '  [ OK ] %s\n' "$1"; ok=$((ok+1)); }
wrn()  { printf '  [WARN] %s\n' "$1"; warn=$((warn+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # $1 >= $2

echo "OS: $(uname -s 2>/dev/null) $(uname -r 2>/dev/null)"

echo "Agent"
if command -v node >/dev/null; then
  v=$(node -v | tr -d v); ver_ge "$v" 22.19.0 && pass "node $v" || bad "node $v < 22.19 (pi requirement)"
else bad "node not found (pi needs Node.js 22.19+)"; fi
if command -v pi >/dev/null; then pass "pi $(pi --version 2>/dev/null | head -1)"; else bad "pi not found"; fi
[ -n "${OSB_PI_MODEL:-}" ] && pass "OSB_PI_MODEL=$OSB_PI_MODEL" || wrn "OSB_PI_MODEL unset: pi uses its default model"
for f in "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json" "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/auth.json"; do
  [ -f "$f" ] && pass "found $f" || wrn "no $f (needed for a custom endpoint or stored login)"
done
[ "${PI_OFFLINE:-}" ] && pass "PI_OFFLINE set (no catalog/network calls)" || wrn "PI_OFFLINE unset: pi may call pi.dev (catalog, version check)"
[ "${PI_TELEMETRY:-}" = "0" ] && pass "PI_TELEMETRY=0" || wrn "PI_TELEMETRY not 0"
if [ -n "${1:-}" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo 000)
  [ "$code" != "000" ] && pass "model endpoint reachable ($1 → HTTP $code)" || bad "model endpoint not reachable: $1"
fi

echo "Shell tools"
command -v bash >/dev/null && pass "bash $(bash --version | head -1 | awk '{print $4}')" || bad "bash missing (Git for Windows provides it)"
command -v sha1sum >/dev/null || command -v shasum >/dev/null && pass "sha1sum/shasum" || bad "no sha1sum/shasum"
PY=$(command -v python3 || command -v python || command -v py)
if [ -n "$PY" ]; then v=$("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])'); ver_ge "$v" 3.10 && pass "python $v ($PY)" || bad "python $v < 3.10"
else bad "python not found"; fi
command -v git >/dev/null && pass "git" || wrn "git missing (lane checks still work, CI guard needs git)"

echo "Build and test"
if command -v java >/dev/null; then
  v=$(java -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/'); [ "$v" -ge 21 ] 2>/dev/null && pass "java $v" || bad "java $v < 21"
else bad "java not found (JDK 21)"; fi
if command -v mvn >/dev/null; then pass "maven $(mvn -v 2>/dev/null | head -1 | awk '{print $3}')"
  [ -f "$HOME/.m2/settings.xml" ] && pass "~/.m2/settings.xml present (mirror/proxy)" || wrn "no ~/.m2/settings.xml: Maven will try Maven Central directly"
else bad "maven not found"; fi
if docker info >/dev/null 2>&1; then pass "docker"; elif podman info >/dev/null 2>&1; then pass "podman"
else wrn "no Docker/Podman: gate G5 (Testcontainers Artemis) will be NOT RUN here; run level-2 tests where Docker is available"; fi

echo "Kit layout (run from the migration repository root)"
for p in AGENTS.md agents/analyst.md tools/verify_flow.sh pi/run_flow.sh; do [ -e "$p" ] && pass "$p" || bad "$p missing"; done
sk=0; for d in .pi/skills "$HOME/.pi/agent/skills" .agents/skills; do [ -f "$d/osb-to-camel/SKILL.md" ] && sk=1; done
[ $sk = 1 ] && pass "skill osb-to-camel discoverable" || bad "skill osb-to-camel not in .pi/skills, ~/.pi/agent/skills or .agents/skills"
# pi skips a SKILL.md whose front matter is not valid YAML, without an error: check the usual traps
for f in .pi/skills/*/SKILL.md "$HOME/.pi/agent/skills"/*/SKILL.md .agents/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  issue=$(awk 'NR==1 && $0!="---"{print "no front matter"; exit} NR>1 && $0=="---"{exit}
               NR>1 && /^[A-Za-z_-]+: /{v=$0; sub(/^[A-Za-z_-]+: /,"",v);
                 if (v ~ /^["\x27]/) next;
                 if (index(v,": ")) {print "unquoted \": \" in " $1; exit}
                 if (index(v," #")) {print "unquoted \" #\" in " $1; exit}
                 if (length(v)>1024 && $1=="description:") {print "description over 1024 characters"; exit}}' "$f")
  [ -z "$issue" ] && pass "front matter valid: $f" || bad "pi will skip $f: $issue"
done
# /osb-* commands: pi reads prompt templates from .pi/prompts (project, after trust) or ~/.pi/agent/prompts
pd=""; for d in .pi/prompts "$HOME/.pi/agent/prompts"; do
  m=0; for n in osb-analyse osb-implement osb-test osb-verify osb-review; do [ -f "$d/$n.md" ] || m=$((m+1)); done
  [ $m -eq 0 ] && { pd=$d; break; }
done
if [ -n "$pd" ]; then pass "/osb-* commands found in $pd"
  [ "$pd" = .pi/prompts ] && printf '  [INFO] .pi/ loads only for a trusted project: trust it at the first pi start, or run pi --approve\n'
else bad "/osb-* commands missing: run  mkdir -p .pi/prompts && cp pi/prompts/*.md .pi/prompts/  (pi/prompts is the kit copy, pi does not read it)"; fi
[ -d osb-src ] && [ -n "$(ls -A osb-src 2>/dev/null)" ] && pass "osb-src/ has content" || wrn "osb-src/ empty: put the OSB export there"

echo; echo "Result: $ok ok, $warn warnings, $fail failures"
[ $fail -eq 0 ]
