# Sourced by the broker/ scripts: settings, the Artemis CLI (via java, so the same command line works in Git Bash on
# Windows and on macOS/Linux, with no cmd.exe quoting of filters or JSON), small helpers.
# Env (.osb-kit.env): ARTEMIS_HOME (unzipped apache-artemis-<v>), ARTEMIS_BROKER (the instance directory),
#   ARTEMIS_ZIP (the download, for `artemis_setup.sh install`), ARTEMIS_USER (default artemis), ARTEMIS_URL
#   (CLI connection, default tcp://localhost:61616), ARTEMIS_CONSOLE (default http://localhost:8161).
#   ARTEMIS_PASSWORD is exported per session, never written to a file.
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
MVN_ARGS=${MVN_ARGS//\~/$HOME}
KIT=${KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
WS=${WS:-.}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WIN=1;; *) WIN=0;; esac
wpath() { if [ "$WIN" = 1 ]; then cygpath -w "$1"; else printf '%s' "$1"; fi; }   # a path as java.exe wants it
JAVA=${JAVA_HOME:+$JAVA_HOME/bin/java}; JAVA=${JAVA:-java}
ARTEMIS_HOME=${ARTEMIS_HOME:-$(ls -d "$WS"/../apache-artemis-* "$HOME"/apache-artemis-* 2>/dev/null | head -1)}
ARTEMIS_BROKER=${ARTEMIS_BROKER:-$HOME/artemis-broker}
ARTEMIS_USER=${ARTEMIS_USER:-artemis}
ARTEMIS_URL=${ARTEMIS_URL:-tcp://localhost:61616}
ARTEMIS_CONSOLE=${ARTEMIS_CONSOLE:-http://localhost:8161}
ARTEMIS_AMQP_PORT=${ARTEMIS_AMQP_PORT:-5672}

need_home() { [ -n "$ARTEMIS_HOME" ] && [ -f "$ARTEMIS_HOME/lib/artemis-boot.jar" ] \
  || { echo "ARTEMIS_HOME not set or no lib/artemis-boot.jar in it: bash $KIT/broker/artemis_setup.sh install"; exit 2; }; }
need_password() { [ -n "${ARTEMIS_PASSWORD:-}" ] || { echo "export ARTEMIS_PASSWORD='<the broker password>' first (per session, never in a file)"; exit 2; }; }
need_module() { [ -f "$1/env/local.properties" ] \
  || { echo "no $1/env/local.properties: python \$KIT/skills/osb-camelk-route/scripts/scaffold_camelk.py <research> -o $1 --project <p> --refresh env"; exit 2; }; }

# the Artemis CLI of the distribution: artemis <command...>   (queue create|stat, producer, consumer, create, ...)
artemis() { need_home; "$JAVA" -classpath "$(wpath "$ARTEMIS_HOME/lib/artemis-boot.jar")" -Dartemis.home="$(wpath "$ARTEMIS_HOME")" \
  org.apache.activemq.artemis.boot.Artemis "$@"; }
# the same with the connection of this session
artemis_client() { need_password; artemis "$@" --user "$ARTEMIS_USER" --password "$ARTEMIS_PASSWORD" --url "$ARTEMIS_URL"; }
# key=value lines of <module>/env/local.properties (no comments, no blank lines)
module_props() { grep -vE '^[[:space:]]*(#|$)' "$1/env/local.properties"; }
console_up() { curl -s -o /dev/null -w '%{http_code}' "$ARTEMIS_CONSOLE/" 2>/dev/null | grep -qE '^(200|30[0-9]|401)$'; }
