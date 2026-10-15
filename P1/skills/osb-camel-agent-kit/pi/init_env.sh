#!/usr/bin/env bash
# Writes ./.osb-kit.env for this workspace with what it can find on the machine, so nobody types paths again.
# Usage (in the workspace, e.g. /e/Pawel/work):  bash <kit>/pi/init_env.sh <osb-application-folder>
# The file is client-specific: it stays here, .gitignore keeps it out of Git. Edit it afterwards if a value is wrong.
set -u
APP_DIR=${1:?usage: init_env.sh <osb-application-folder>}
case "$APP_DIR" in *\\*|[A-Za-z]:*) command -v cygpath >/dev/null && APP_DIR=$(cygpath -u "$APP_DIR");; esac
[ -d "$APP_DIR" ] || { echo "not a folder: $APP_DIR"; exit 2; }
KIT_DIR=$(cd "$(dirname "$0")/.." && pwd)
pick() { for d in "$@"; do [ -d "$d" ] && { echo "$d"; return; }; done; }
JDK=$(pick /c/Program\ Files/Eclipse\ Adoptium/jdk-21* /c/Program\ Files/Java/jdk-21* /c/Program\ Files/Microsoft/jdk-21* "${JAVA_HOME:-/nonexistent}")
MVN=$(pick /e/Pawel/apache-maven-3.9* "$HOME"/apache-maven-3.9* /c/apache-maven-3.9* "$(dirname "$(dirname "$(command -v mvn 2>/dev/null || echo /x/x/x)")")")
first() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return; }; done; }
cat > .osb-kit.env <<ENV
# written by init_env.sh on $(date +%F); local only (.gitignore). Command-line values win over these defaults.
export KIT="\${KIT:-$KIT_DIR}"
export APP="\${APP:-$APP_DIR}"
export WS="\${WS:-$(pwd)}"
export JAVA_HOME="\${JAVA_HOME_21:-$JDK}"
export PATH="$MVN/bin:\$JAVA_HOME/bin:\$PATH"
export MVN_ARGS="\${MVN_ARGS:--s $HOME/.m2/settings.xml}"
export PI_OFFLINE="\${PI_OFFLINE:-1}" PI_TELEMETRY="\${PI_TELEMETRY:-0}" PI_PAUSE="\${PI_PAUSE:-60}"
export EXPORT="\${EXPORT:-$(first "$(pwd)/domain-export.csv")}"
export SPLUNK_COVERAGE="\${SPLUNK_COVERAGE:-$(first "$(pwd)/splunk-payload.csv")}"
export MASK_JSON_KEYS="\${MASK_JSON_KEYS:-reason}"
export POC="\${POC:-1}"
export BATCH_SIZE="\${BATCH_SIZE:-10}"
# MASK_KEY is NOT stored here: export it per session (key from the data owner)
ENV
echo "written $(pwd)/.osb-kit.env"
grep -E '^export (KIT|APP|WS|JAVA_HOME|EXPORT|SPLUNK_COVERAGE)=' .osb-kit.env | sed 's/^export /  /'
[ -n "$JDK" ] || echo "  WARNING: no JDK 21 found: edit JAVA_HOME in .osb-kit.env"
[ -n "$MVN" ] || echo "  WARNING: no Maven 3.9 found: edit PATH in .osb-kit.env"
