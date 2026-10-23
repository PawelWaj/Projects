#!/usr/bin/env bash
# A local Apache ActiveMQ Artemis for the L2 run of a flow (broker/LOCAL_BROKER_TEST.md). Git Bash on Windows, macOS, Linux.
#   bash <kit>/broker/artemis_setup.sh setup [<unzipped apache-artemis folder>]
#                                                 # unzipped by hand: remembers the folder in .osb-kit.env, creates the instance, starts it
#   bash <kit>/broker/artemis_setup.sh install    # or: unpack ARTEMIS_ZIP next to the workspace (skipped when ARTEMIS_HOME exists);
#                                                 # without ARTEMIS_ZIP the distribution comes through Maven (Nexus):
#                                                 # org.apache.activemq:apache-artemis:$ARTEMIS_VERSION:zip:bin (default 2.44.0)
#   bash <kit>/broker/artemis_setup.sh create     # one broker instance in ARTEMIS_BROKER: user ARTEMIS_USER, password ARTEMIS_PASSWORD,
#                                                 # login required, ports 61616 (core, CLI) / 5672 (AMQP, the routes) / 8161 (console)
#   bash <kit>/broker/artemis_setup.sh start|stop|status
# Env: see lib.sh. JAVA_HOME must be the JDK the routes use as well (JDK 21): the same Java on both sides.
set -u
. "$(dirname "$0")/lib.sh"
CMD=${1:-status}
case "$CMD" in
  setup)
    [ -n "${2:-}" ] && ARTEMIS_HOME=${2%/}
    [ -n "$ARTEMIS_HOME" ] && [ -f "$ARTEMIS_HOME/lib/artemis-boot.jar" ] \
      || { echo "give the unzipped folder (it contains bin/ and lib/artemis-boot.jar):  artemis_setup.sh setup /e/<path>/apache-artemis-<version>"; exit 2; }
    need_password
    echo "Artemis: $ARTEMIS_HOME ($(ls "$ARTEMIS_HOME/lib" | grep -oE 'artemis-server-[0-9.]+' | head -1 | sed 's/artemis-server-//; s/\.$//'))"
    remember ARTEMIS_HOME "$ARTEMIS_HOME"; remember ARTEMIS_BROKER "$ARTEMIS_BROKER"
    "$0" create && "$0" start;;
  install)
    if [ -n "$ARTEMIS_HOME" ] && [ -f "$ARTEMIS_HOME/lib/artemis-boot.jar" ]; then echo "already installed: $ARTEMIS_HOME"; exit 0; fi
    dest=$(cd "$WS/.." && pwd)
    if [ -z "${ARTEMIS_ZIP:-}" ] || [ ! -f "$ARTEMIS_ZIP" ]; then           # no download at hand: the Maven repository has it
      v=${ARTEMIS_VERSION:-2.44.0}
      echo "fetching apache-artemis-$v-bin.zip through Maven (MVN_ARGS=${MVN_ARGS:-<default settings>}) ..."
      mvn -B -q ${MVN_ARGS:-} org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy \
        -Dartifact="org.apache.activemq:apache-artemis:$v:zip:bin" -DoutputDirectory="$(wpath "$dest")" \
        || { echo "could not fetch it: check MVN_ARGS / Nexus, or set ARTEMIS_ZIP=<apache-artemis-$v-bin.zip>"; exit 2; }
      ARTEMIS_ZIP="$dest/apache-artemis-$v-bin.zip"
    fi
    echo "unpacking $(basename "$ARTEMIS_ZIP") into $dest ..."
    (cd "$dest" && tar -xf "$ARTEMIS_ZIP")                     # tar reads zip files (Git Bash, macOS, Linux); unzip is not always there
    home=$(ls -d "$dest"/apache-artemis-* 2>/dev/null | head -1)
    [ -f "$home/lib/artemis-boot.jar" ] || { echo "unpack failed: no apache-artemis-*/lib/artemis-boot.jar under $dest"; exit 1; }
    echo "installed: $home"; remember ARTEMIS_HOME "$home";;
  create)
    need_home; need_password
    [ -n "${ARTEMIS_HOME:-}" ] && export ARTEMIS_HOME ARTEMIS_BROKER
    [ -f "$ARTEMIS_BROKER/etc/broker.xml" ] && { echo "instance exists: $ARTEMIS_BROKER (delete it to recreate)"; exit 0; }
    artemis create --user "$ARTEMIS_USER" --password "$ARTEMIS_PASSWORD" --require-login --name local-broker --silent --no-autotune \
      --host localhost "$(wpath "$ARTEMIS_BROKER")" | grep -vE '^\s*$' | tail -3
    [ -f "$ARTEMIS_BROKER/etc/broker.xml" ] && echo "instance created: $ARTEMIS_BROKER (user $ARTEMIS_USER)" || { echo "create failed"; exit 1; };;
  start)
    [ -f "$ARTEMIS_BROKER/etc/broker.xml" ] || { echo "no instance in $ARTEMIS_BROKER: artemis_setup.sh create"; exit 2; }
    if console_up; then echo "already running: $ARTEMIS_CONSOLE"; exit 0; fi
    if [ "$WIN" = 1 ]; then cmd //c start "" "$(wpath "$ARTEMIS_BROKER/bin/artemis.cmd")" run    # its own window; close it = stop
    else nohup "$ARTEMIS_BROKER/bin/artemis" run > "$ARTEMIS_BROKER/log/console.out" 2>&1 & fi   # artemis-service fails on macOS
    for i in $(seq 1 60); do console_up && { echo "broker up after ${i}s: console $ARTEMIS_CONSOLE (user $ARTEMIS_USER), AMQP :$ARTEMIS_AMQP_PORT, core $ARTEMIS_URL"; exit 0; }; sleep 1; done
    echo "broker did not answer within 60s: see $ARTEMIS_BROKER/log/artemis.log"; exit 1;;
  stop)
    if [ "$WIN" = 1 ]; then cmd //c "$(wpath "$ARTEMIS_BROKER/bin/artemis.cmd")" stop; else "$ARTEMIS_BROKER/bin/artemis" stop | tail -1; fi;;
  status)
    echo "ARTEMIS_HOME=$ARTEMIS_HOME"; echo "ARTEMIS_BROKER=$ARTEMIS_BROKER"
    "$JAVA" -version 2>&1 | head -1
    if console_up; then echo "running: console $ARTEMIS_CONSOLE, AMQP :$ARTEMIS_AMQP_PORT, core $ARTEMIS_URL"; else echo "not running (artemis_setup.sh start)"; fi;;
  *) echo "usage: artemis_setup.sh setup [<folder>] | install | create | start | stop | status"; exit 2;;
esac
