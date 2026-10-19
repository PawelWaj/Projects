#!/usr/bin/env bash
# @@PROJECT@@ on a local Artemis with Camel JBang (no pom). Needs: Java 21, Maven with access to the Maven repository
# (MVN_ARGS="-s <settings.xml>"; JBang and Camel come from there when not installed), an unzipped and running Artemis
# (ARTEMIS_HOME) for run/send/stat, python for "send". See RUN_LOCAL.md.
#   bash run-local.sh test                          the tests of every flow (jbang test/*Test.java), no broker
#   bash run-local.sh run                           start the routes (camel run), Ctrl+C stops them
#   bash run-local.sh send <proxy> <case folder>    send one case (input.payload + headers.json) as the OSB caller would
#   bash run-local.sh stat                          message counts of every queue on the broker
set -u
cd "$(dirname "$0")"
CAMEL_VERSION="${CAMEL_VERSION:-@@CAMEL@@}"
# JBang: installed, else ../Common-setup/jbang.sh (the JBang jar through Maven/Nexus, no internet needed)
jb() { if command -v jbang > /dev/null; then jbang "$@"; else bash ../Common-setup/jbang.sh "$@"; fi; }
# Camel CLI: installed, else Camel JBang straight from its Maven artifact (no GitHub catalog)
camelcli() { if command -v camel > /dev/null; then camel "$@"; else jb --main main.CamelJBang "org.apache.camel:camel-jbang-main:$CAMEL_VERSION" "$@"; fi; }
SEND_PY=$(cat <<'PYEOF'
import json, re, sys
v = sys.argv[1].split("=", 1)[1]
kind = re.search(r"destinationType=(\w+)", v).group(1)
dest = re.search(r"destination=([^&]+)", v).group(1)
sel = (re.search(r"selector=RAW\((.*)\)$", v) or [None, ""])[1]
h = json.load(open(sys.argv[2], encoding="utf-8")) if sys.argv[2] and __import__("os").path.isfile(sys.argv[2]) else {}
# properties the selector needs but the case lacks (OSB does not log them): the first value the selector names
for name in dict.fromkeys(re.findall(r"(\w+)\s*=\s*'", sel)):
    if name not in h:
        vals = re.findall(rf"\b{name}\s*=\s*'([^']*)'", sel)
        if vals:
            h[name] = vals[0]
print(f"{kind}://{dest}", json.dumps([{"type": "string", "key": k, "value": str(x)} for k, x in h.items()]).replace(" ", ""))
PYEOF
)
wp() { if command -v cygpath > /dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
art() { : "${ARTEMIS_HOME:?export ARTEMIS_HOME=<unzipped apache-artemis folder>}"; : "${BROKER_PASSWORD:?export BROKER_PASSWORD=<broker password>}"
  "${JAVA_HOME:+$JAVA_HOME/bin/}java" -cp "$(wp "$ARTEMIS_HOME/lib/artemis-boot.jar")" -Dartemis.home="$(wp "$ARTEMIS_HOME")" \
    org.apache.activemq.artemis.boot.Artemis "$@" --user "${BROKER_USER:-artemis}" --password "$BROKER_PASSWORD" --url "${BROKER_URL:-tcp://localhost:61616}"; }
case "${1:-}" in
  test)
    rc=0; for t in test/*Test.java; do echo "== $t"; jb "$t" || rc=1; done; exit $rc ;;
  run)
    : "${BROKER_PASSWORD:?export BROKER_PASSWORD=<broker password>}"
    export BROKER_USER="${BROKER_USER:-artemis}" BROKER_URL="${BROKER_URL:-tcp://localhost:61616}" OSB_FILES_DIR="$(wp "$(pwd)")"
    camelcli run @@ROUTE@@ application.properties local.properties ../Common-setup/OsbNxsd.java ../Common-setup/OsbXQuery.java \
      --local-kamelet-dir=../Common-setup --camel-version="$CAMEL_VERSION" ;;
  send)
    x=${2:?proxy}; c=${3:?case folder with input.payload and headers.json}
    line=$(grep -E "^$x\.flow\.input=" local.properties | tr -d '\r'); [ -n "$line" ] || { echo "unknown proxy $x"; exit 2; }
    PY=$(command -v python3 || command -v python)
    out=$("$PY" -c "$SEND_PY" "$line" "$c/headers.json") || exit 2
    dest=${out%% *}; props=${out#* }
    art producer --protocol CORE --destination "$dest" --message-count 1 --message "$(cat "$c/input.payload")" --properties "$props" 2>&1 \
      | grep -E "Produced|rror|xception" | head -3 ;;
  stat)
    art queue stat --maxRows 500 --maxColumnSize -1 2>&1 | grep -E "^\|" ;;
  *) sed -n '2,8p' "$0" ;;
esac
