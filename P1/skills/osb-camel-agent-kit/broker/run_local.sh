#!/usr/bin/env bash
# Runs ONE flow's YAML route on Camel Main against the local broker: `mvn -Prun-local exec:java` with every line of
# <module>/env/local.properties passed as -D, so it overrides the endpoints of application.properties (JNDI names ->
# local addresses); the connection placeholders BROKER_* are set from ARTEMIS_*. Logs appear in this window; Ctrl+C stops the route. The L1 tests are not touched by this.
#   bash <kit>/broker/run_local.sh <module>
set -u
. "$(dirname "$0")/lib.sh"
M=${1:?usage: run_local.sh <module>}
need_module "$M"; need_password
export BROKER_URL="amqp://localhost:$ARTEMIS_AMQP_PORT" BROKER_USER="$ARTEMIS_USER" BROKER_PASSWORD="$ARTEMIS_PASSWORD"
args=()
while IFS= read -r line; do
  case $line in *.selector=*) continue;; esac              # the filter lives on the broker (artemis_prepare.sh), not in the route
  args+=("-D$line")
done < <(module_props "$M")
echo "route of $M against $ARTEMIS_URL (AMQP :$ARTEMIS_AMQP_PORT):"
printf '   %s\n' "${args[@]}" | grep -E '^   -D(flow\.input|out\.|backend\.)' | sed 's/^   -D/   /'
echo "starting (Ctrl+C stops it) ..."
# no -q: exec:java logs through Maven's own SLF4J, and quiet mode would hide every Camel log line
exec mvn -B ${MVN_ARGS:-} -f "$M/pom.xml" -Prun-local compile exec:java "${args[@]}"
