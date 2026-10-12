#!/usr/bin/env bash
# Agentic run of one OSB flow on the pi coding agent (https://pi.dev).
# Pi has no sub-agents, so each role is a separate `pi -p --no-session` process: a fresh context per role is exactly
# the independence the tester and reviewer need. Deterministic checks sit between the roles.
#
# Usage: pi/run_flow.sh <osb-project-dir> <flow> <module-dir> [--from analyse|test|implement|verify|review]
# Order: analyse -> gate A (human) -> TEST (fresh context, no src/main yet) -> implement -> verify (fix loops) -> review
# Env:   OSB_PI_MODEL (model pattern for `pi --model`; not PI_MODEL, which pi itself sets), PI_THINKING (default high),
#        MAX_FIX_LOOPS (default 3), KIT (default: the directory above this script)
set -euo pipefail

PROJECT=${1:?usage: run_flow.sh <osb-project-dir> <flow> <module-dir> [--from phase]}
FLOW=${2:?flow name}
MODULE=${3:?module dir}
FROM=analyse
[ "${4:-}" = "--from" ] && FROM=${5:?phase}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
OUT="migration/$FLOW"
LOG="$OUT/agent-logs"
MAX_FIX_LOOPS=${MAX_FIX_LOOPS:-3}
mkdir -p "$LOG"

# skills: git layout (<kit>/skills/<name>) or paste-installed workspace (<kit>/.pi/skills/<name>)
skill_dir() { if [ -d "$KIT/skills/$1" ]; then echo "$KIT/skills/$1"; elif [ -d "$KIT/.pi/skills/$1" ]; then echo "$KIT/.pi/skills/$1"; fi; }
PI_BASE=(pi --print --no-session --thinking "${PI_THINKING:-high}")
for sk in osb-to-camel camel-migration-verification; do d=$(skill_dir "$sk"); [ -n "$d" ] && PI_BASE+=(--skill "$d"); done
[ -n "${OSB_PI_MODEL:-}" ] && PI_BASE+=(--model "$OSB_PI_MODEL")

# role <name> <tools> <prompt>: one fresh pi process with the role prompt appended to the system prompt
role() {
  local name=$1 tools=$2 prompt=$3 stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  echo ">> $name" >&2
  "${PI_BASE[@]}" --tools "$tools" --append-system-prompt "$KIT/agents/$name.md" "$prompt" \
    > "$LOG/$stamp-$name.out" 2> "$LOG/$stamp-$name.err"
  echo "$LOG/$stamp-$name.out"
}

# fingerprint of a directory tree (detects edits outside a role's lane; works without git)
# sha1sum on Git Bash/Linux, shasum on macOS
SHA=$(command -v sha1sum || command -v shasum)
fp() { [ -d "$1" ] && find "$1" -type f -print0 | sort -z | xargs -0 "$SHA" 2>/dev/null | "$SHA" | cut -c1-16 || echo none; }

approved() { grep -Eq '^\| \*\*Status\*\* \| *approved' "$OUT/FLOW_CARD.md" 2>/dev/null; }

phase_reached() { case "$FROM" in analyse) return 0;; test) [ "$1" != analyse ];; implement) [[ "$1" =~ ^(implement|verify|review)$ ]];;
                  verify) [[ "$1" =~ ^(verify|review)$ ]];; review) [ "$1" = review ];; esac; }

# ---------------------------------------------------------------- S0 analyse
if phase_reached analyse; then
  role analyst "read,bash,edit,write" \
    "Use skill osb-to-camel Steps 0 and 1. OSB export: $PROJECT. Flow: $FLOW. Run the inventory into migration/osb-inventory, scaffold and complete $OUT/FLOW_CARD.md from the real OSB files. Status draft. End with a 5-line summary and the BLOCKING open items." > /dev/null
  [ -f "$OUT/FLOW_CARD.md" ] || { echo "analyst wrote no card"; exit 1; }
fi

# ---------------------------------------------------------------- S1 human gate A
if ! approved; then
  echo "STOP: $OUT/FLOW_CARD.md is not approved. A human sets '| **Status** | approved' plus the approver, then:"
  echo "      pi/run_flow.sh $PROJECT $FLOW $MODULE --from test"
  exit 0
fi

TESTS_FP() { fp "$MODULE/src/test"; }
MAIN_FP()  { fp "$MODULE/src/main"; }

# ---------------------------------------------------------------- S2 test (tests first: fresh context, no route exists yet)
if phase_reached test; then
  before=$(MAIN_FP)
  role tester "read,bash,edit,write" \
    "Write the test suite for flow $FLOW from the approved card $OUT/FLOW_CARD.md and the OSB evidence in $PROJECT, following skill osb-to-camel Step 3 and skill camel-migration-verification. There is NO route yet: tests go to $MODULE/src/test and must compile against the class and endpoint names the card fixes (run 'mvn -q -f $MODULE/pom.xml test-compile'); they are expected to FAIL for the right reason until the route exists. Recorded cases: if $MODULE/src/test/resources/parity exists, one parameterised test per case; expected-output.xml files there come from the golden runner and must not be regenerated. Register every expected file you add in $MODULE/src/test/resources/golden/MANIFEST.csv with its source (osb-recording | original-transform | osb-test-console | card-rule | source-derived; the last two need reason and approved_by). Do not create or edit $MODULE/src/main. Report honestly." > /dev/null
  [ "$(MAIN_FP)" = "$before" ] || { echo "VIOLATION: tester changed $MODULE/src/main"; exit 1; }
fi

# ---------------------------------------------------------------- S3 implement (makes the existing tests pass)
if phase_reached implement; then
  before=$(TESTS_FP)
  role implementer "read,bash,edit,write" \
    "Implement the approved card $OUT/FLOW_CARD.md with skill osb-to-camel Step 2 into Maven module $MODULE. OSB sources: $PROJECT. The tests under $MODULE/src/test already exist and define the contract: make 'mvn -q -f $MODULE/pom.xml verify' pass. Do not create, edit or delete anything under $MODULE/src/test or $OUT/FLOW_CARD.md; if a test is wrong, write $OUT/TEST_DISPUTE.md with evidence from the OSB files and stop." > /dev/null
  [ "$(TESTS_FP)" = "$before" ] || { echo "VIOLATION: implementer changed $MODULE/src/test"; exit 1; }
  [ -f "$OUT/TEST_DISPUTE.md" ] && { echo "STOP: test dispute raised, a fresh tester or a human decides ($OUT/TEST_DISPUTE.md)"; exit 1; }
fi

# ---------------------------------------------------------------- S4 verify + fix loop
if phase_reached verify; then
  loop=0
  until "$KIT/tools/verify_flow.sh" "$MODULE" "$FLOW"; do
    loop=$((loop + 1))
    if [ "$loop" -gt "$MAX_FIX_LOOPS" ]; then
      echo "BLOCKED after $MAX_FIX_LOOPS fix loops; see $OUT/verify-report.json"; exit 1
    fi
    before=$(TESTS_FP)
    role implementer "read,bash,edit,write" \
      "Fix loop $loop for flow $FLOW. Read $OUT/verify-report.json and the logs next to it. Change production code under $MODULE/src/main only. If a test is wrong, write $OUT/TEST_DISPUTE.md with evidence from the OSB files and stop." > /dev/null
    [ "$(TESTS_FP)" = "$before" ] || { echo "VIOLATION: implementer changed tests in fix loop $loop"; exit 1; }
    [ -f "$OUT/TEST_DISPUTE.md" ] && { echo "STOP: test dispute raised, a fresh tester or a human decides ($OUT/TEST_DISPUTE.md)"; exit 1; }
  done
fi

# ---------------------------------------------------------------- S5 review (read-only tools; the script writes the files)
if phase_reached review; then
  out=$(role reviewer "read,grep,find,ls" \
    "Review flow $FLOW: card $OUT/FLOW_CARD.md, module $MODULE, gates $OUT/verify-report.json, OSB sources $PROJECT. Print REVIEW.md content, then a line containing only =====RECORD=====, then MIGRATION_RECORD.md content.")
  awk '/^=====RECORD=====$/{exit} {print}' "$out" > "$OUT/REVIEW.md"
  awk 'f{print} /^=====RECORD=====$/{f=1}' "$out" > "$OUT/MIGRATION_RECORD.md"
  [ -s "$OUT/MIGRATION_RECORD.md" ] || echo "WARNING: reviewer output had no record section; see $out"
  if grep -q "BLOCKER" "$OUT/REVIEW.md"; then echo "Review has BLOCKER findings: $OUT/REVIEW.md"; exit 1; fi
fi

echo "DONE for $FLOW: gates green, review without BLOCKER. Next: human sign-off (gate B), then the UAT shadow run (TESTING.md L6)."
