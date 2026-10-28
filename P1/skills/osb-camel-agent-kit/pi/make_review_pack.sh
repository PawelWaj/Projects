#!/usr/bin/env bash
# One review package per flow: research -> card -> the module (standard Maven layout, runnable as is) -> results, with
# a reviewer checklist. Stays on the client machine (it contains the original XQuery and masked test data).
#
# Usage (in the workspace):  bash <kit>/pi/make_review_pack.sh <project> <proxy> [reference-route-dir]
# Env: ROUTE_AUTHOR (default "pi agent (osb-camelk-route)"): who wrote the route, shown in README_REVIEW.md
#   reference-route-dir  optional: another route for the same flow (e.g. the hand-written pilot) -> compared against
#                        the SAME frozen tests with compare_codegen.py
# Result: review/<project>-<proxy>/ + review/<project>-<proxy>.tgz   (agent logs and build output are left out)
#   1-research/   RESEARCH.md, research.json, facts.json, SHARE_CHECK.json
#   2-card/       FLOW_CARD.md
#   module/       pom.xml, src/main (route, properties, beans), src/test (frozen tests, cases, stubs), env/,
#                 MIGRATION_NOTES.md, .scaffold.json  ->  `mvn test` and the broker scripts work in this folder
#   3-tests/      TESTS.md (every test by level L1-L6 with its result) + DEV_TEST_PLAN.md (D0-D5, to fill on Dev)
#   4-acceptance/ LOCAL_ACCEPTANCE.md/.json, SMOKE.json/.txt (the route run with Camel JBang)
#   5-results/    TEST_MATRIX.md, GATES.json, MUTATION.json, surefire summaries
#   6-deploy/     camel-k/ (integration.yaml, DEPLOY.md, CHECK.json) as handed to Argo CD
#   7-compare/    (optional) generated route vs reference route on the same tests
set -uo pipefail
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
MVN_ARGS=${MVN_ARGS//\~/$HOME}   # "~" inside a variable is not expanded by the shell
P=${1:?usage: make_review_pack.sh <project> <proxy> [reference-route-dir]}
X=${2:?proxy}
REF=${3:-}
WS=${WS:-.}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
R="$WS/research/$P/$X"; M="$WS/modules/$P/$X"; O="$WS/review/$P-$X"
[ -s "$R/research.json" ] || { echo "no research pack in $R: run run_domain.sh research first"; exit 2; }
[ -d "$M" ] || { echo "no module in $M: run run_domain.sh tests (and build) first"; exit 2; }
rm -rf "$O"; mkdir -p "$O"/{1-research,2-card,module,3-tests,4-acceptance,5-results,6-deploy}
cp "$R"/RESEARCH.md "$R"/research.json "$R"/facts.json "$R"/SHARE_CHECK.json "$O/1-research/" 2>/dev/null
cp "$M/FLOW_CARD.md" "$O/2-card/" 2>/dev/null
for f in pom.xml FLOW_CARD.md MIGRATION_NOTES.md .scaffold.json .gitignore; do [ -f "$M/$f" ] && cp "$M/$f" "$O/module/"; done
for d in src env; do [ -d "$M/$d" ] && cp -r "$M/$d" "$O/module/"; done
cp "$M/GATES.json" "$M/MUTATION.json" "$M/TEST_MATRIX.md" "$M/test-matrix.csv" "$O/5-results/" 2>/dev/null
[ -d "$M/target/surefire-reports" ] && cp "$M"/target/surefire-reports/*.txt "$O/5-results/" 2>/dev/null
cp "$M/LOCAL_ACCEPTANCE.md" "$M/LOCAL_ACCEPTANCE.json" "$M/SMOKE.json" "$M/SMOKE.txt" "$O/4-acceptance/" 2>/dev/null
[ -d "$M/camel-k" ] && cp -r "$M/camel-k" "$O/6-deploy/"
"$PY" "$KIT/skills/osb-camelk-route/scripts/flow_tests_report.py" "$M" -o "$O/3-tests" >/dev/null || echo "   tests report not written"
if [ -n "$REF" ] && [ -d "$REF" ]; then
  echo "== comparing the generated route with $REF on the same frozen tests"
  "$PY" "$(cd "$KIT/../../vdi-osb-migration/bin" 2>/dev/null && pwd || echo "$KIT/bin")/compare_codegen.py" "$M" \
    --candidate generated="$M/src/main" --candidate reference="$REF" --mvn "mvn -B -q ${MVN_ARGS:-}" -o "$O/7-compare" >/dev/null 2>&1 \
    && rm -rf "$O"/7-compare/generated "$O"/7-compare/reference || echo "   comparison failed: see $O/7-compare"
fi
"$PY" - "$O" "$P" "$X" "$M" "${ROUTE_AUTHOR:-pi agent (osb-camelk-route)}" <<'PY'
import json, sys, re
from pathlib import Path
o, p, x, m, author = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4]), sys.argv[5]
load = lambda f: json.loads(f.read_text(encoding="utf-8")) if f.is_file() else {}
g = load(m / "GATES.json"); mu = load(m / "MUTATION.json"); res = load(o / "1-research/research.json")
cfg = load(m / "src/test/resources/flow-test.json")
cases = [c for c in (m / "src/test/resources/parity").glob("**/input.payload")] if (m / "src/test/resources/parity").is_dir() else []
real = sum("-synthetic" not in c.as_posix() for c in cases)
card = (m / "FLOW_CARD.md").read_text(encoding="utf-8") if (m / "FLOW_CARD.md").is_file() else ""
st = (re.search(r"^Status:\s*(.+)$", card, re.M) or [None, "-"])[1]
k8 = g.get("gates", {}).get("K8_tests_green", {})
routes = sorted(p_.name for p_ in (m / "src/main/resources/routes").glob("*.yaml")) if (m / "src/main/resources/routes").is_dir() else []
lines = [f"# Review package: {p} / {x}", "",
         "Everything below stays on the client machine. Read in this order:", "",
         "| # | Where | What to check |", "|---|---|---|",
         "| 1 | `1-research/RESEARCH.md` | what the OSB flow does (entry, branches, outputs, errors, logs) with evidence; open questions |",
         "| 2 | `2-card/FLOW_CARD.md` | the behaviour the code must implement; status of the approval |",
         f"| 3 | `module/src/main/resources/routes/` | **the Camel route, written by: {author}** (YAML DSL); helper beans in `module/src/main/java`; `application.properties` = production descriptor (OSB names, selector, connection from the environment); `MIGRATION_NOTES.md` |",
         "| 4 | `3-tests/TESTS.md` | **all tests by level**: L1 functional, L2 error paths, L3 mutations, L4 gates, L5 runtime run, L6 deploy file, each with its result; test code in `module/src/test/` |",
         "| 5 | `3-tests/DEV_TEST_PLAN.md` | the tests still to run on Dev / E2E (deploy, functional per scenario, errors, security, side by side with OSB, non-functional) |",
         "| 6 | `4-acceptance/`, `5-results/` | local acceptance result, Camel JBang run, TEST_MATRIX.md, GATES.json (K1-K13), MUTATION.json, surefire summaries |",
         "| 7 | `6-deploy/camel-k/` | integration.yaml + DEPLOY.md as handed to Argo CD |",
         "| 8 | `7-compare/COMPARISON.md` | (if present) generated route vs reference route on the same tests |", "",
         "Run it yourself: `cd module && mvn -B -s <team settings.xml> test` (JDK 21, Maven 3.9); against a local Artemis:",
         "`broker/LOCAL_BROKER_TEST.md` of the kit (`env/local.properties` is in the module).", "",
         "## Summary", "",
         f"- Route written by: **{author}**",
         f"- Card status: **{st}**",
         f"- Route files: {', '.join(routes) or 'none (not built yet)'}",
         f"- Scenarios: {len(cfg.get('scenario_mapping') or [])}; test messages: {real} real (masked Splunk), {len(cases) - real} synthetic",
         f"- Outputs mocked: {', '.join(k for k in (cfg.get('outputs') or {}))}",
         f"- Tests: {k8.get('tests', '-')} run, {k8.get('failures', '-')} failed, {k8.get('errors', '-')} errors, {k8.get('skipped', '-')} skipped",
         f"- Gates: {g.get('result', 'not run')}" + ("; failing: " + ", ".join(k for k, v in g.get('gates', {}).items() if not v.get('ok')) if g else ""),
         f"- Mutations caught: {mu.get('killed', '-')}/{mu.get('total', '-')}",
         f"- Open questions in the research: {len(res.get('open_questions') or [])}", "",
         "## Reviewer checklist", "",
         "- [ ] Every branch, output, retry and error header of the card is in the route, nothing that is not on the card",
         "- [ ] One send per destination (a JMS business service that writes an output IS that output)",
         "- [ ] OSB log lines kept with the same text and logName (the tests do not check log text)",
         "- [ ] Original XQuery/XSLT used unchanged (not rewritten)",
         "- [ ] Body forwarded unchanged where OSB forwards it; routing fields are exchange properties, not headers",
         "- [ ] Endpoints only as properties with the OSB names; connection only as {{env:...}}; no hosts, ports, secrets",
         "- [ ] Error message: errorCode / errorMessage / debugInfo (osbStage) / correlation id as on the card",
         "- [ ] Helper beans small and readable; YAML DSL idiomatic for Camel 4.18",
         "- [ ] Differences to OSB listed in MIGRATION_NOTES.md and acceptable",
         "- [ ] Open questions answered or accepted before the card is approved", "",
         "Reviewer: ____________  Date: ________  Result: approve / changes needed"]
(o / "README_REVIEW.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
print("\n".join(lines[18:28]))
PY
(cd "$WS/review" && tar -czf "$P-$X.tgz" "$P-$X")
echo "review package: $O  (+ $WS/review/$P-$X.tgz). Keep it on the client machine."
