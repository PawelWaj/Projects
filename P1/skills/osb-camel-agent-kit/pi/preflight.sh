#!/usr/bin/env bash
# Preflight for the client VDI: checks everything the kit needs before the first run.
# Runs in Git Bash (Windows), WSL or Linux. Read-only: installs nothing, changes nothing.
# Usage: pi/preflight.sh [model-endpoint-url]
set -u
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done   # local settings, never in Git
ok=0; warn=0; fail=0
pass() { printf '  [ OK ] %s\n' "$1"; ok=$((ok+1)); }
wrn()  { printf '  [WARN] %s\n' "$1"; warn=$((warn+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # $1 >= $2

echo "OS: $(uname -s 2>/dev/null) $(uname -r 2>/dev/null)"

echo "Agent (only research and the skills path need it; task1, the scripts path and the local tests run without pi)"
if command -v node >/dev/null; then
  v=$(node -v | tr -d v); ver_ge "$v" 22.19.0 && pass "node $v" || wrn "node $v < 22.19 (pi requirement)"
else wrn "node not found (pi needs Node.js 22.19+)"; fi
if command -v pi >/dev/null; then pass "pi $(pi --version 2>/dev/null | head -1)"; else wrn "pi not found (npm install -g --ignore-scripts @earendil-works/pi-coding-agent)"; fi
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
pass "pi calls stop after PI_TIMEOUT (default 1800 s): $(command -v timeout >/dev/null && echo 'timeout' || echo 'own watchdog, no timeout command needed')"

echo "Build and test"
if command -v java >/dev/null; then
  v=$(java -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/'); [ "$v" -ge 21 ] 2>/dev/null && pass "java $v" || bad "java $v < 21"
else bad "java not found (JDK 21)"; fi
if command -v mvn >/dev/null; then pass "maven $(mvn -v 2>/dev/null | head -1 | awk '{print $3}')"
  [ -f "$HOME/.m2/settings.xml" ] && pass "~/.m2/settings.xml present (mirror/proxy)" || wrn "no ~/.m2/settings.xml: Maven will try Maven Central directly"
else bad "maven not found"; fi
if docker info >/dev/null 2>&1; then pass "docker"; elif podman info >/dev/null 2>&1; then pass "podman"
else printf '  [INFO] no Docker/Podman: not needed (tests use mocks; the local Artemis runs as a plain Java process)\n'; fi

echo "Kit and workspace"
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
for p in pi/run_domain.sh pi/vdi_session.sh skills/osb-research/SKILL.md skills/osb-camelk-route/SKILL.md broker/artemis_setup.sh; do
  [ -f "$KIT/$p" ] && pass "kit: $p" || bad "kit: $p missing in KIT=$KIT (unzip the whole repository, set KIT in .osb-kit.env)"
done
kv=$(cd "$KIT/../.." 2>/dev/null && git log --oneline -1 2>/dev/null); printf '  [INFO] kit version: %s\n' "${kv:-ZIP download, $(ls -l "$KIT/pi/run_domain.sh" 2>/dev/null | awk '{print $6, $7}')}"
# Maven build of Camel K modules: Maven 3.6.3+ on Java 17+ (VDI default is Maven 3.5.3 on JDK 1.7)
if command -v mvn >/dev/null; then
  mv=$(mvn -v 2>/dev/null | tr -d '\033' | sed -n 's/.*Apache Maven \([0-9.]*\).*/\1/p' | head -1)
  jv=$(mvn -v 2>/dev/null | sed -n 's/^Java version: \([0-9]*\).*/\1/p' | head -1); [ "$jv" = 1 ] && jv=$(mvn -v | sed -n 's/^Java version: 1\.\([0-9]*\).*/\1/p')
  printf '%s\n3.6.3\n' "$mv" | sort -V -C 2>/dev/null && bad "Maven $mv too old for the test plugins (need 3.6.3+: Maven 3.9.9 from Nexus)" || pass "Maven $mv"
  [ "${jv:-0}" -ge 17 ] 2>/dev/null && pass "Maven runs on Java $jv" || bad "Maven runs on Java ${jv:-?} (need 17+: export JAVA_HOME to the JDK 21 folder)"
fi
# pi skips a SKILL.md whose front matter is not valid YAML, without an error: check the usual traps
for f in "$KIT"/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  issue=$(awk 'NR==1 && $0!="---"{print "no front matter"; exit} NR>1 && $0=="---"{exit}
               NR>1 && /^[A-Za-z_-]+: /{v=$0; sub(/^[A-Za-z_-]+: /,"",v);
                 if (v ~ /^["\x27]/) next;
                 if (index(v,": ")) {print "unquoted \": \" in " $1; exit}
                 if (index(v," #")) {print "unquoted \" #\" in " $1; exit}
                 if (length(v)>1024 && $1=="description:") {print "description over 1024 characters"; exit}}' "$f")
  [ -z "$issue" ] && pass "front matter valid: ${f#$KIT/}" || bad "pi will skip $f: $issue"
done
if [ -n "${APP:-}" ] && [ -d "$APP" ]; then
  n=$(ls -d "$APP"/*-prj 2>/dev/null | wc -l | tr -d ' '); [ "$n" -gt 0 ] && pass "APP=$APP ($n *-prj projects)" || wrn "APP=$APP has no *-prj folder"
else bad "APP not set or not a folder: the OSB application folder (vdi_session.sh setup <folder>)"; fi

echo "Local tests (JBang + local Artemis)"
command -v jbang >/dev/null && pass "jbang installed" || printf '  [INFO] jbang not installed: the delivery fetches the JBang jar through Maven (tools/jbang.sh)\n'
if [ -f "${ARTEMIS_HOME:-}/lib/artemis-boot.jar" ]; then pass "Artemis: $ARTEMIS_HOME"
else printf '  [INFO] no Artemis yet: bash $KIT/broker/artemis_setup.sh install  (fetches apache-artemis via Maven/Nexus), then setup\n'; fi
[ -n "${MVN_ARGS:-}" ] && pass "MVN_ARGS=$MVN_ARGS (mvn, JBang jar, camel run use it)" || wrn "MVN_ARGS empty: Maven uses ~/.m2/settings.xml"

echo; echo "Result: $ok ok, $warn warnings, $fail failures"
[ $fail -eq 0 ]
