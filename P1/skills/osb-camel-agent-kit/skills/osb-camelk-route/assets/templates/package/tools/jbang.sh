#!/usr/bin/env bash
# JBang without an installer and without internet: the JBang jar comes from the Maven repository (Nexus) through the
# Maven you already use (MVN_ARGS="-s <settings.xml>"), then this script plays the role of the `jbang` launcher.
#   bash ../Common-setup/jbang.sh <same arguments as jbang>      e.g.  bash ../Common-setup/jbang.sh test/XTest.java
# Env: JBANG_VERSION (default 0.121.0), JBANG_JAR (a jar you already have), JAVA_HOME (Java 21), MVN_ARGS.
set -u
V="${JBANG_VERSION:-0.121.0}"
DIR="${JBANG_JAR_DIR:-$HOME/.jbang-jar}"           # copied here, whatever <localRepository> the Maven settings name
JAR="${JBANG_JAR:-$DIR/jbang-cli-$V-all.jar}"
JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"
wp() { if command -v cygpath > /dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
if [ ! -f "$JAR" ]; then
  echo "[jbang.sh] fetching dev.jbang:jbang-cli:$V (all) through Maven ..." >&2
  mkdir -p "$DIR"
  mvn -B -q ${MVN_ARGS:-} org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy -Dartifact="dev.jbang:jbang-cli:$V:jar:all" \
    -DoutputDirectory="$(wp "$DIR")" >&2 && [ -f "$JAR" ] \
    || { echo "[jbang.sh] could not fetch the JBang jar: check MVN_ARGS / Nexus, or set JBANG_JAR=<path of jbang-cli-$V-all.jar>" >&2; exit 2; }
fi
# JBang resolves the //DEPS of the tests and Camel itself with ~/.m2/settings.xml (its mirrors): keep the Nexus there
# the launcher protocol of JBang: exit code 255 = "run the command printed on stdout"; tell JBang the command is run
# by bash (as its own launcher script does), so Windows paths come out quoted for bash
export JBANG_RUNTIME_SHELL=bash
out=$("$JAVA" -jar "$(wp "$JAR")" "$@")
rc=$?
if [ "$rc" -eq 255 ]; then
  if command -v cygpath > /dev/null; then          # Windows: an unquoted @C:\...\x.args argument file -> forward slashes
    if [[ $out =~ @[A-Za-z]:[^\ \"\']+ ]]; then tok=${BASH_REMATCH[0]}; out=${out/"$tok"/"${tok//\\//}"}; fi
  fi
  eval "exec $out"
fi
[ -n "$out" ] && printf '%s\n' "$out"
exit "$rc"
