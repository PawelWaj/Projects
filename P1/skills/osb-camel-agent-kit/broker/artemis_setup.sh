#!/usr/bin/env bash
# A local Apache ActiveMQ Artemis for the L2 run of a flow (broker/LOCAL_BROKER_TEST.md). Git Bash on Windows, macOS, Linux.
#   bash <kit>/broker/artemis_setup.sh install    # unpack ARTEMIS_ZIP next to the workspace (skipped when ARTEMIS_HOME exists)
#   bash <kit>/broker/artemis_setup.sh create     # one broker instance in ARTEMIS_BROKER: user ARTEMIS_USER, password ARTEMIS_PASSWORD,
#                                                 # login required, ports 61616 (core, CLI) / 5672 (AMQP, the routes) / 8161 (console)
#   bash <kit>/broker/artemis_setup.sh start|stop|status
# Env: see lib.sh. JAVA_HOME must be the JDK the routes use as well (JDK 21): the same Java on both sides.
set -u
. "$(dirname "$0")/lib.sh"
CMD=${1:-status}
case "$CMD" in
  install)
    if [ -n "$ARTEMIS_HOME" ] && [ -f "$ARTEMIS_HOME/lib/artemis-boot.jar" ]; then echo "already installed: $ARTEMIS_HOME"; exit 0; fi
    [ -n "${ARTEMIS_ZIP:-}" ] && [ -f "$ARTEMIS_ZIP" ] || { echo "ARTEMIS_ZIP=<apache-artemis-<version>-bin.zip> (download from artemis.apache.org, or the team's share)"; exit 2; }
    dest=$(cd "$WS/.." && pwd)
    echo "unpacking $(basename "$ARTEMIS_ZIP") into $dest ..."
    (cd "$dest" && tar -xf "$ARTEMIS_ZIP")                     # tar reads zip files (Git Bash, macOS, Linux); unzip is not always there
    home=$(ls -d "$dest"/apache-artemis-* 2>/dev/null | head -1)
    [ -f "$home/lib/artemis-boot.jar" ] || { echo "unpack failed: no apache-artemis-*/lib/artemis-boot.jar under $dest"; exit 1; }
    echo "installed: $home"; echo "add to .osb-kit.env:  export ARTEMIS_HOME=\"$home\"";;
  create)
    need_home; need_password
    [ -f "$ARTEMIS_BROKER/etc/broker.xml" ] && { echo "instance exists: $ARTEMIS_BROKER (delete it to recreate)"; exit 0; }
    artemis create --user "$ARTEMIS_USER" --password "$ARTEMIS_PASSWORD" --require-login --name local-broker --silent --no-autotune \
      --host localhost "$(wpath "$ARTEMIS_BROKER")" | grep -vE '^\s*$' | tail -3
    [ -f "$ARTEMIS_BROKER/etc/broker.xml" ] && echo "instance created: $ARTEMIS_BROKER (user $ARTEMIS_USER)" || { echo "create failed"; exit 1; };;
  start)
    [ -f "$ARTEMIS_BROKER/etc/broker.xml" ] || { echo "no instance in $ARTEMIS_BROKER: artemis_setup.sh create"; exit 2; }
    if console_up; then echo "already running: $ARTEMIS_CONSOLE"; exit 0; fi
    if [ "$WIN" = 1 ]; then cmd //c start "" "$(wpath "$ARTEMIS_BROKER/bin/artemis.cmd")" run    # its own window; close it = stop
    else "$ARTEMIS_BROKER/bin/artemis-service" start | tail -1; fi
    for i in $(seq 1 60); do console_up && { echo "broker up after ${i}s: console $ARTEMIS_CONSOLE (user $ARTEMIS_USER), AMQP :$ARTEMIS_AMQP_PORT, core $ARTEMIS_URL"; exit 0; }; sleep 1; done
    echo "broker did not answer within 60s: see $ARTEMIS_BROKER/log/artemis.log"; exit 1;;
  stop)
    if [ "$WIN" = 1 ]; then cmd //c "$(wpath "$ARTEMIS_BROKER/bin/artemis.cmd")" stop; else "$ARTEMIS_BROKER/bin/artemis-service" stop | tail -1; fi;;
  status)
    echo "ARTEMIS_HOME=$ARTEMIS_HOME"; echo "ARTEMIS_BROKER=$ARTEMIS_BROKER"
    "$JAVA" -version 2>&1 | head -1
    if console_up; then echo "running: console $ARTEMIS_CONSOLE, AMQP :$ARTEMIS_AMQP_PORT, core $ARTEMIS_URL"; else echo "not running (artemis_setup.sh start)"; fi;;
  *) echo "usage: artemis_setup.sh install|create|start|stop|status"; exit 2;;
esac
