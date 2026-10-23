#!/usr/bin/env bash
# Artemis command line and a local broker, the same on Windows (Git Bash) and Linux/macOS. Reads ../set-env.sh.
#   bash tools/artemis.sh setup        Artemis from Maven/Nexus when ARTEMIS_HOME is not set (install), the local broker
#                                      instance in $ARTEMIS_BROKER (once), start it
#   bash tools/artemis.sh install      only the download: org.apache.activemq:apache-artemis:$ARTEMIS_VERSION:zip:bin via mvn
#   bash tools/artemis.sh start|stop|status
#   bash tools/artemis.sh cli <args>   any Artemis CLI command with the connection of set-env.sh
#                                      e.g. cli browser --destination queue://<queue> --message-count 1
set -u
cd "$(dirname "$0")/.."
[ -f set-env.sh ] && . ./set-env.sh
wp() { if command -v cygpath > /dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"
need_home() { [ -f "${ARTEMIS_HOME:-}/lib/artemis-boot.jar" ] || { echo "ARTEMIS_HOME is not an unzipped Artemis (lib/artemis-boot.jar missing): set it in set-env.sh"; exit 2; }; }
need_pw() { [ -n "${BROKER_PASSWORD:-}" ] || { echo "export BROKER_PASSWORD=<broker password> first"; exit 2; }; }
art() { need_home; "$JAVA" -cp "$(wp "$ARTEMIS_HOME/lib/artemis-boot.jar")" -Dartemis.home="$(wp "$ARTEMIS_HOME")" org.apache.activemq.artemis.boot.Artemis "$@"; }
up() {   # the broker port answers (fast; the Artemis CLI would retry for minutes when nothing listens)
  local hp=${BROKER_URL#*://}; hp=${hp%%\?*}; local h=${hp%%:*} p=${hp##*:}
  (exec 3<> "/dev/tcp/${h:-localhost}/${p:-61616}") 2> /dev/null
}
install() {   # the distribution through the Maven repository (Nexus): no internet, no manual download
  [ -f "${ARTEMIS_HOME:-}/lib/artemis-boot.jar" ] && return 0
  local v=${ARTEMIS_VERSION:-2.44.0} dest; dest=$(cd .. && pwd)
  local home="$dest/apache-artemis-$v"
  if [ ! -f "$home/lib/artemis-boot.jar" ]; then
    echo "fetching apache-artemis-$v-bin.zip through Maven ..."
    mvn -B -q ${MVN_ARGS:-} org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy -Dartifact="org.apache.activemq:apache-artemis:$v:zip:bin" \
      -DoutputDirectory="$(wp "$dest")" || { echo "could not fetch it: check MVN_ARGS / Nexus in set-env.sh"; exit 2; }
    (cd "$dest" && tar -xf "apache-artemis-$v-bin.zip") || { echo "unpack failed"; exit 1; }
  fi
  export ARTEMIS_HOME="$home"
  echo "Artemis: $ARTEMIS_HOME  (set ARTEMIS_HOME to it in set-env.sh to skip this step)"
}
case "${1:-}" in
  install) install ;;
  setup)
    install; need_home; need_pw
    if [ ! -f "$ARTEMIS_BROKER/etc/broker.xml" ]; then
      art create --user "$BROKER_USER" --password "$BROKER_PASSWORD" --require-login --name local-broker --silent --no-autotune \
        --host localhost "$(wp "$ARTEMIS_BROKER")" | tail -2
    fi
    exec bash "$0" start ;;
  start)
    [ -f "$ARTEMIS_BROKER/etc/broker.xml" ] || { echo "no broker instance in $ARTEMIS_BROKER: bash tools/artemis.sh setup"; exit 2; }
    need_pw; if up; then echo "broker already running ($BROKER_URL)"; exit 0; fi
    if command -v cygpath > /dev/null; then cmd //c start "" "$(wp "$ARTEMIS_BROKER/bin/artemis.cmd")" run     # own window: closing it stops the broker
    else nohup "$ARTEMIS_BROKER/bin/artemis" run > "$ARTEMIS_BROKER/log/console.out" 2>&1 & fi   # artemis-service fails on macOS
    for i in $(seq 1 60); do up && { echo "broker up after ${i}s ($BROKER_URL, user $BROKER_USER)"; exit 0; }; sleep 1; done
    echo "broker did not answer within 60 s: see $ARTEMIS_BROKER/log/artemis.log"; exit 1 ;;
  stop)
    if command -v cygpath > /dev/null; then cmd //c "$(wp "$ARTEMIS_BROKER/bin/artemis.cmd")" stop; else "$ARTEMIS_BROKER/bin/artemis" stop | tail -1; fi ;;
  status)
    echo "ARTEMIS_HOME=${ARTEMIS_HOME:-<not set>}  ARTEMIS_BROKER=$ARTEMIS_BROKER  BROKER_URL=$BROKER_URL"
    need_pw; if up; then echo "broker: running"; else echo "broker: not reachable"; fi ;;
  cli)
    shift; need_pw; art "$@" --user "$BROKER_USER" --password "$BROKER_PASSWORD" --url "$BROKER_URL" ;;
  *) sed -n '2,7p' "$0"; exit 2 ;;
esac
