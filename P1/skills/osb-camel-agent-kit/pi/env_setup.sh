#!/usr/bin/env bash
# Local test environment of a fresh (or reset) VDI: check it, or install what is missing. Git Bash, macOS, Linux.
# Run it in the workspace (e.g. /e/Pawel/work) after `vdi_session.sh setup <osb-app-folder>` wrote ./.osb-kit.env.
#   bash <kit>/pi/env_setup.sh check     read-only: one OK/FAIL line per item, exit 1 when something is missing
#   bash <kit>/pi/env_setup.sh install   Artemis (through Maven/Nexus) + broker instance + start, the JBang jar + a `jbang`
#                                        launcher in ~/bin, Camel/JUnit dependencies fetched once by a smoke test, then check
# Needs on the machine: JDK 21, Maven 3.9 with the client settings.xml (Nexus), Python 3.10+. Nothing from the internet.
# Env: ARTEMIS_PASSWORD (per session, never in a file), MVN_ARGS (-s <settings.xml>), CAMEL_VERSION, PI_PING=1 (also asks
#      the model for "OK" through pi).
set -u
CMD=${1:-check}
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
MVN_ARGS=${MVN_ARGS//\~/$HOME}
CAMEL_VERSION=${CAMEL_VERSION:-$(sed -n 's/^CAMEL_VERSION = "\(.*\)"/\1/p' "$KIT/skills/osb-camelk-route/scripts/assemble_jbang.py" | head -1)}
JBANG_SH="$KIT/skills/osb-camelk-route/assets/templates/package/tools/jbang.sh"
TPL="$KIT/skills/osb-camelk-route/assets/templates/FlowJBangTest.java.tpl"
SMOKE="${WS:-$(pwd)}/.env-smoke"
JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"
ok=0; fail=0
pass() { printf '  [ OK ] %s\n' "$1"; ok=$((ok+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
info() { printf '  [INFO] %s\n' "$1"; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # $1 >= $2
settings_file() { printf '%s\n' ${MVN_ARGS:-} | awk 'p {print; exit} $0 == "-s" || $0 == "--settings" {p=1}'; }
jbang_ver() { jbang --version 2>&1 | grep -v 'Picked up' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | tail -1; }   # JBang prints it on stderr
local_repo() { mvn -B -q ${MVN_ARGS:-} org.apache.maven.plugins:maven-help-plugin:3.5.1:evaluate \
  -Dexpression=settings.localRepository -DforceStdout 2>/dev/null | tr -d '\r' | tail -1; }

check() {
  echo "Base"
  [ -f ./.osb-kit.env ] && pass "workspace settings ./.osb-kit.env" || bad "no ./.osb-kit.env here: bash $KIT/pi/vdi_session.sh setup <osb-app-folder>"
  [ -f "$KIT/pi/vdi_session.sh" ] && pass "kit: $KIT" || bad "kit not found: KIT=$KIT"
  PY=$(command -v python3 || command -v python || command -v py)
  if [ -n "$PY" ]; then v=$("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])'); ver_ge "$v" 3.10 && pass "python $v" || bad "python $v < 3.10"
  else bad "python not found"; fi
  command -v curl > /dev/null && pass "curl" || bad "curl missing (broker check)"
  if "$JAVA" -version > /dev/null 2>&1; then
    jv=$("$JAVA" -version 2>&1 | grep -v 'Picked up' | head -1 | sed -E 's/.*"([0-9]+).*/\1/'); [ "$jv" -ge 21 ] 2>/dev/null && pass "java $jv (${JAVA_HOME:-PATH})" || bad "java $jv < 21: JAVA_HOME in .osb-kit.env"
  else bad "java not found: JAVA_HOME in .osb-kit.env (JDK 21)"; fi

  echo "Maven / Nexus"
  if command -v mvn > /dev/null; then
    mv=$(mvn -v 2>/dev/null | tr -d '\033' | sed -n 's/.*Apache Maven \([0-9.]*\).*/\1/p' | head -1)
    ver_ge "${mv:-0}" 3.6.3 && pass "maven $mv" || bad "maven ${mv:-?} < 3.6.3 (Maven 3.9 from Nexus, PATH in .osb-kit.env)"
    s=$(settings_file); s=${s:-$HOME/.m2/settings.xml}
    [ -f "$s" ] && pass "settings $s" || bad "no Maven settings at $s (MVN_ARGS=-s <file>)"
    [ -f "$s" ] && { grep -q '<mirror>' "$s" && pass "settings has a <mirror> (Nexus)" || info "settings has no <mirror>: Maven goes to the repositories it names"; }
    # JBang reads only ~/.m2/settings.xml: the same mirror must be there
    if [ "$s" != "$HOME/.m2/settings.xml" ]; then
      cmp -s "$s" "$HOME/.m2/settings.xml" && pass "~/.m2/settings.xml = $s (JBang uses it)" \
        || bad "JBang reads ~/.m2/settings.xml, which differs from $s: cp \"$s\" ~/.m2/settings.xml"
    fi
    mvn -B -q ${MVN_ARGS:-} org.apache.maven.plugins:maven-dependency-plugin:3.8.1:get -Dartifact=junit:junit:4.13.2 \
      -Dtransitive=false > /dev/null 2>&1 && pass "Nexus answers (junit:junit:4.13.2 resolved)" || bad "Maven cannot resolve from Nexus: proxy/credentials in settings.xml"
  else bad "mvn not on PATH (PATH in .osb-kit.env)"; fi

  echo "JBang"
  if command -v jbang > /dev/null; then
    jv=$(jbang_ver); [ -n "$jv" ] && pass "jbang $jv ($(command -v jbang))" || bad "jbang on PATH but does not start"
  else bad "jbang not on PATH: bash $KIT/pi/env_setup.sh install"; fi
  repo=$(local_repo)
  if [ -n "$repo" ] && [ -d "$repo/org/apache/camel/camel-core-engine/$CAMEL_VERSION" ]; then pass "Camel $CAMEL_VERSION in $repo"
  else bad "Camel $CAMEL_VERSION not fetched yet (install runs the smoke test that fetches it)"; fi
  [ -d "${repo:-/x}/org/apache/camel/camel-jbang-main/$CAMEL_VERSION" ] && pass "Camel JBang $CAMEL_VERSION (camel run)" \
    || bad "Camel JBang $CAMEL_VERSION not fetched yet (install)"
  [ -f "$SMOKE/SMOKE.txt" ] && grep -q '1 tests, 0 failed' "$SMOKE/SMOKE.txt" && pass "JBang smoke test passed ($(cut -c1-10 "$SMOKE/SMOKE.ts" 2>/dev/null))" \
    || bad "JBang smoke test not passed yet (install)"

  echo "Artemis"
  . "$KIT/broker/lib.sh" 2>/dev/null
  [ -f "${ARTEMIS_HOME:-/x}/lib/artemis-boot.jar" ] && pass "distribution $ARTEMIS_HOME" || bad "no Artemis distribution (install)"
  [ -f "${ARTEMIS_BROKER:-/x}/etc/broker.xml" ] && pass "instance $ARTEMIS_BROKER" || bad "no broker instance (install)"
  if console_up; then pass "broker running: console $ARTEMIS_CONSOLE"
    if [ -n "${ARTEMIS_PASSWORD:-}" ]; then
      artemis queue stat --user "$ARTEMIS_USER" --password "$ARTEMIS_PASSWORD" --url "$ARTEMIS_URL" > /dev/null 2>&1 \
        && pass "login $ARTEMIS_USER works" || bad "broker refuses the login: ARTEMIS_PASSWORD is not the one of the instance"
    else info "export ARTEMIS_PASSWORD to check the login"; fi
  else bad "broker not running: bash $KIT/broker/artemis_setup.sh start"; fi

  echo "Agent (research and the skills path only)"
  command -v pi > /dev/null && pass "pi $(pi --version 2>/dev/null | head -1)" || info "pi not on PATH (task1, scripts path and local tests run without it)"
  [ -n "${OSB_PI_MODEL:-}" ] && pass "OSB_PI_MODEL=$OSB_PI_MODEL" || info "OSB_PI_MODEL unset"
  if [ "${PI_PING:-0}" = 1 ] && command -v pi > /dev/null; then
    r=$(echo 'Reply with the single word OK' | pi --print --no-session ${OSB_PI_MODEL:+--model "$OSB_PI_MODEL"} < /dev/null 2>&1 | tail -1)
    case "$r" in *OK*) pass "model answers";; *) bad "model did not answer OK (models.json baseUrl/id, OSB_PI_MODEL)";; esac
  fi

  echo; echo "Result: $ok ok, $fail failed"
  [ "$fail" -eq 0 ]
}

install_jbang() {
  echo "=== JBang"
  mkdir -p "$HOME/bin"
  sed 's|^# JBang without an installer|# installed by env_setup.sh. JBang without an installer|' "$JBANG_SH" > "$HOME/bin/jbang" && chmod +x "$HOME/bin/jbang"
  case ":$PATH:" in *":$HOME/bin:"*) ;; *) export PATH="$HOME/bin:$PATH"
    grep -q 'jbang launcher (env_setup.sh)' ./.osb-kit.env 2>/dev/null || echo 'export PATH="$HOME/bin:$PATH"   # jbang launcher (env_setup.sh)' >> ./.osb-kit.env;; esac
  [ -n "$(jbang_ver)" ] && echo "jbang $(jbang_ver): $HOME/bin/jbang" || { echo "jbang does not start: see above"; return 1; }
}

smoke_test() {   # the same //DEPS as the generated tests: fetches Camel, Saxon, JUnit once and proves JBang can resolve them
  echo "=== JBang smoke test (Camel $CAMEL_VERSION, first run fetches the dependencies, a few minutes)"
  mkdir -p "$SMOKE"
  { sed -n '1,/^\/\/SOURCES/p' "$TPL" | grep -v '^//SOURCES' | sed "s/@@CAMEL@@/$CAMEL_VERSION/"
    cat <<'JAVA'

import org.apache.camel.builder.RouteBuilder;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.impl.DefaultCamelContext;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertTrue;

public class EnvSmokeTest {
    @Test
    void camelRoutesAMessage() throws Exception {
        try (var camel = new DefaultCamelContext()) {
            camel.addRoutes(new RouteBuilder() { public void configure() { from("direct:in").to("mock:out"); } });
            camel.start();
            MockEndpoint out = camel.getEndpoint("mock:out", MockEndpoint.class);
            out.expectedBodiesReceived("ping");
            camel.createProducerTemplate().sendBody("direct:in", "ping");
            out.assertIsSatisfied();
            assertTrue(net.sf.saxon.Version.getProductVersion().length() > 0);
        }
    }

    public static void main(String... args) {
        var request = org.junit.platform.launcher.core.LauncherDiscoveryRequestBuilder.request()
            .selectors(org.junit.platform.engine.discovery.DiscoverySelectors.selectClass(EnvSmokeTest.class)).build();
        var summary = new org.junit.platform.launcher.listeners.SummaryGeneratingListener();
        org.junit.platform.launcher.core.LauncherFactory.create().execute(request, summary);
        var s = summary.getSummary();
        s.getFailures().forEach(f -> System.out.println("FAIL " + f.getException()));
        System.out.printf("%d tests, %d failed%n", s.getTestsFoundCount(), s.getTotalFailureCount());
        System.exit(s.getTotalFailureCount() == 0 && s.getTestsFoundCount() > 0 ? 0 : 1);
    }
}
JAVA
  } > "$SMOKE/EnvSmokeTest.java"
  (cd "$SMOKE" && jbang EnvSmokeTest.java 2>&1 | grep -vE '^\[jbang\] (Resolving|Building)' | tail -5 | tee SMOKE.txt)
  grep -q '1 tests, 0 failed' "$SMOKE/SMOKE.txt" && date '+%F %T' > "$SMOKE/SMOKE.ts" \
    || { echo "smoke test failed: JBang cannot resolve or run Camel (check ~/.m2/settings.xml mirror)"; return 1; }
  echo "=== Camel JBang $CAMEL_VERSION (camel run of the routes)"
  jbang --main main.CamelJBang "org.apache.camel:camel-jbang-main:$CAMEL_VERSION" version 2>&1 | tail -2
}

install_artemis() {
  echo "=== Artemis"
  : "${ARTEMIS_PASSWORD:?export ARTEMIS_PASSWORD=<choose one> first (per session, never in a file)}"
  bash "$KIT/broker/artemis_setup.sh" install || return 1
  . ./.osb-kit.env
  bash "$KIT/broker/artemis_setup.sh" create && bash "$KIT/broker/artemis_setup.sh" start
}

case "$CMD" in
  check) check ;;
  install)
    [ -f ./.osb-kit.env ] || { echo "run it in the workspace after: bash $KIT/pi/vdi_session.sh setup <osb-app-folder>"; exit 2; }
    [ -f "$HOME/.m2/settings.xml" ] || { s=$(settings_file); [ -n "$s" ] && [ -f "$s" ] && mkdir -p "$HOME/.m2" && cp "$s" "$HOME/.m2/settings.xml" \
      && echo "copied $s to ~/.m2/settings.xml (JBang reads only that file)"; }
    install_artemis || exit 1
    install_jbang && smoke_test
    echo; echo "=== check"; . ./.osb-kit.env; check ;;
  *) echo "usage: env_setup.sh check | install"; exit 2 ;;
esac
