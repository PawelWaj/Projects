#!/usr/bin/env bash
# Sends one test case (or a raw text) to the input of a flow on the local broker: see send_case.py.
#   bash <kit>/broker/send_case.sh <module> <case-dir> [--count n]
#   bash <kit>/broker/send_case.sh <module> --raw 'not json at all' [--headers '{"traceId":"t-1"}']
set -u
. "$(dirname "$0")/lib.sh"
M=${1:?usage: send_case.sh <module> <case-dir> | --raw <text>}
need_module "$M"; need_home; need_password
export JAVA ARTEMIS_HOME ARTEMIS_URL ARTEMIS_USER ARTEMIS_PASSWORD WIN
"$PY" "$KIT/broker/send_case.py" "$@"
