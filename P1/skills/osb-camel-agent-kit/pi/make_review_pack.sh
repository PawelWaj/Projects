#!/usr/bin/env bash
# One review package per flow: research -> card -> the module (standard Maven layout, runnable as is) -> results, with
# a reviewer checklist. Stays on the client machine (it contains the original XQuery and masked test data).
#
# Usage (in the workspace):  bash <kit>/pi/make_review_pack.sh <project> <proxy> [reference-route-dir]
# Env: ROUTE_AUTHOR (default "pi agent (osb-camelk-route)"): who wrote the route, shown in README_REVIEW.md
#   reference-route-dir  optional: another route for the same flow (e.g. the hand-written pilot) -> compared against
#                        the SAME frozen tests with compare_codegen.py
# Result: review/<project>-<proxy>/ + review/<project>-<proxy>.tgz (reviewer) + review/<project>-<proxy>-dev.tgz (deploy + Dev tests)   (agent logs and build output are left out)
#   1-research/   RESEARCH.md, research.json, facts.json, SHARE_CHECK.json
#   2-card/       FLOW_CARD.md
#   module/       pom.xml, src/main (route, properties, beans), src/test (frozen tests, cases, stubs), env/,
#                 MIGRATION_NOTES.md, .scaffold.json  ->  `mvn test` and the broker scripts work in this folder
#   3-tests/      TESTS.md (every test by level L1-L6 with its result), RUN_TESTS.md, DEV_TEST_PLAN.md (D0-D5, to fill
#                 on Dev) + a reading copy of the tests: 1-functional/ (test, expected outputs, cases), 2-error-paths/,
#                 3-runtime/, stubs/
#   4-acceptance/ LOCAL_ACCEPTANCE.md/.json, SMOKE.json/.txt (the route run with Camel JBang)
#   5-results/    TEST_MATRIX.md, GATES.json, MUTATION.json, surefire summaries
#   6-deploy/     camel-k/ (integration.yaml, DEPLOY.md, CHECK.json) as handed to Argo CD
#   7-dev-tests/  dev_check.sh (D0) + dev_test.py (D1-D4, against the deployed route, OSB side by side), dev-cases/
#   8-compare/    (optional) generated route vs reference route on the same tests
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
rm -rf "$O"; mkdir -p "$O"/{1-research,2-card,module,3-tests,4-acceptance,5-results,6-deploy,7-dev-tests}
cp "$R"/RESEARCH.md "$R"/research.json "$R"/facts.json "$R"/SHARE_CHECK.json "$O/1-research/" 2>/dev/null
cp "$M/FLOW_CARD.md" "$O/2-card/" 2>/dev/null
for f in pom.xml FLOW_CARD.md MIGRATION_NOTES.md .scaffold.json .gitignore; do [ -f "$M/$f" ] && cp "$M/$f" "$O/module/"; done
for d in src env; do [ -d "$M/$d" ] && cp -r "$M/$d" "$O/module/"; done
cp "$M/GATES.json" "$M/MUTATION.json" "$M/TEST_MATRIX.md" "$M/test-matrix.csv" "$O/5-results/" 2>/dev/null
[ -d "$M/target/surefire-reports" ] && cp "$M"/target/surefire-reports/*.txt "$O/5-results/" 2>/dev/null
cp "$M/LOCAL_ACCEPTANCE.md" "$M/LOCAL_ACCEPTANCE.json" "$M/SMOKE.json" "$M/SMOKE.txt" "$O/4-acceptance/" 2>/dev/null
[ -d "$M/camel-k" ] && cp -r "$M/camel-k" "$O/6-deploy/"
"$PY" "$KIT/skills/osb-camelk-route/scripts/flow_tests_report.py" "$M" -o "$O/3-tests" >/dev/null || echo "   tests report not written"
# the tests themselves, by level, so the reviewer reviews them too (a copy: the runnable original stays in module/)
T="$O/3-tests"; mkdir -p "$T"/{1-functional,2-error-paths,3-runtime,stubs}
find "$M/src/test/java" -name 'FlowParityTest.java' -exec cp {} "$T/1-functional/" \; 2>/dev/null
cp "$M/src/test/resources/flow-test.json" "$T/1-functional/" 2>/dev/null
[ -d "$M/src/test/resources/parity" ] && cp -r "$M/src/test/resources/parity" "$T/1-functional/cases"
find "$M/src/test/java" -name 'FlowErrorTest.java' -exec cp {} "$T/2-error-paths/" \; 2>/dev/null
find "$M/src/test/java" -name 'FlowJBangTest.java' -exec cp {} "$T/3-runtime/" \; 2>/dev/null
cp "$M/SMOKE.txt" "$M/SMOKE.json" "$T/3-runtime/" 2>/dev/null
[ -d "$M/src/test/resources/stubs" ] && cp -r "$M/src/test/resources/stubs/." "$T/stubs/"
# Dev tests: the same cases against the deployed route (and OSB side by side), run after the Argo CD sync
DT="$O/7-dev-tests"; mkdir -p "$DT"
cp "$KIT/skills/osb-camelk-route/assets/dev-tests/dev_test.py" "$KIT/skills/osb-camelk-route/assets/dev-tests/dev_check.sh" "$DT/"
cp "$M/src/test/resources/flow-test.json" "$DT/" 2>/dev/null
[ -d "$M/src/test/resources/parity" ] && cp -r "$M/src/test/resources/parity" "$DT/dev-cases"
cp "$T/DEV_TEST_PLAN.md" "$DT/" 2>/dev/null
ENTRY=$(sed -n 's/^flow.input=platform-http://p' "$M/src/main/resources/application.properties" 2>/dev/null | head -1)
INAME=$(sed -n '/^kind: Integration/,/^---/{s/^  name: *//p;}' "$M/camel-k/integration.yaml" 2>/dev/null | head -1)
cat > "$DT/README_DEV_TESTS.md" <<DEV
# Dev tests: $P / $X

Run after Argo CD has synced \`integration.yaml\` to Dev. Needs Python 3 and, for step 1, \`oc\` logged in to the Dev
namespace. Every result is names, statuses and counts only; the cases are masked or synthetic and stay on client machines.

| Step | Command | Plan IDs |
|---|---|---|
| 1 deployment | \`bash dev_check.sh <namespace> ${INAME:-<integration>} ${INAME:-<integration>}-env\` | D0.1-D0.4, D3.1 |
| 2 functional + errors | \`python dev_test.py --url https://<dev host>${ENTRY:-<entry path>}\` | D1, D2, D3 |
| 3 side by side with OSB | \`python dev_test.py --url https://<dev host>${ENTRY:-<entry path>} --osb-url https://<osb host>/<proxy path>\` | D4 |
| 4 by hand | D2.3 (OSB's real error body), D3.2 (log text), D5 (E2E/UAT) in \`DEV_TEST_PLAN.md\` | |

Results: \`results/DEV_CHECK.md\`, \`results/DEV_TEST_RESULT.md\` (+ .json). Copy the results into the Result column of
\`DEV_TEST_PLAN.md\`.

Test data. \`dev-cases/<scenario>/<case>/\` holds the cases of the local tests (\`input.payload\`, \`headers.json\`,
\`expected.json\`, \`expected-output.json\`). Masked values do not exist in the Dev backend, so for step 2 replace each
\`input.payload\` with a record the backend team confirms in Dev (same scenario), or add new case folders. On Dev the
reply is checked by SHAPE (same key paths and types as \`expected-output.json\`), not by value. Step 3 checks values:
OSB and the route get the same request and must answer the same.

Credentials. If the Dev gateway needs a token, export it and pass the variable name, never the value:
\`export DEV_TOKEN=...; python dev_test.py ... --header-env Authorization=DEV_TOKEN\`. Self-signed Dev TLS: \`--insecure\`.
DEV

cat > "$T/RUN_TESTS.md" <<RUN
# How to run the tests of $P / $X

The files in this folder are a COPY for reading. To run or change a test, use \`module/\` (tests are frozen: gate K5
fails if a generated test or expected output is edited; change the card or the research and regenerate instead).

| Level | Files here | Run (on the client machine, in the workspace) | Pass when |
|---|---|---|---|
| 1 functional | \`1-functional/FlowParityTest.java\`, \`flow-test.json\` (expected outputs per scenario), \`cases/<scenario>/<case>/\` (input.payload, headers.json, expected.json, expected-output.*) | \`cd module && mvn -B -s <settings.xml> test -Dtest=FlowParityTest\` | 0 failures, 0 errors |
| 2 error paths | \`2-error-paths/FlowErrorTest.java\` | \`cd module && mvn -B -s <settings.xml> test -Dtest=FlowErrorTest\` | 0 failures, 0 errors |
| 3 runtime | \`3-runtime/SMOKE.txt\` (last run) | \`python \$KIT/skills/osb-camelk-route/scripts/smoke_http.py module --engine jbang\` (HTTP flows) or \`ENGINE=jbang bash \$KIT/broker/e2e_local.sh module\` (JMS flows) | every case PASS, error case ok |
| test strength | \`../5-results/MUTATION.json\` | \`python \$KIT/skills/osb-camelk-route/scripts/mutate_route.py module --mvn "mvn -B -q -s <settings.xml>"\` | every mutation caught |
| gates | \`../5-results/GATES.json\` | \`python \$KIT/skills/osb-camelk-route/scripts/verify_module.py module\` | every gate ok |

Backend stubs used by levels 1 and 3: \`stubs/\`. Results of the last run: \`TESTS.md\`. Still to run on Dev: \`DEV_TEST_PLAN.md\`.
Test messages are masked (real) or synthetic; they stay on the client machine.
RUN
if [ -n "$REF" ] && [ -d "$REF" ]; then
  echo "== comparing the generated route with $REF on the same frozen tests"
  "$PY" "$(cd "$KIT/../../vdi-osb-migration/bin" 2>/dev/null && pwd || echo "$KIT/bin")/compare_codegen.py" "$M" \
    --candidate generated="$M/src/main" --candidate reference="$REF" --mvn "mvn -B -q ${MVN_ARGS:-}" -o "$O/8-compare" >/dev/null 2>&1 \
    && rm -rf "$O"/8-compare/generated "$O"/8-compare/reference || echo "   comparison failed: see $O/8-compare"
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
acc = load(m / "LOCAL_ACCEPTANCE.json")
bad = []
if not k8 or int(k8.get("failures") or 0) or int(k8.get("errors") or 0): bad.append("tests not green")
if g.get("result") != "PASS": bad.append("gates not PASS")
if mu and mu.get("killed") != mu.get("total") and not (m / "MUTATION_ACCEPTED.md").is_file(): bad.append("mutations survived")
if acc.get("result") != "PASS": bad.append("local acceptance " + str(acc.get("result") or "not run"))
banner = ("**READY FOR REVIEW**: tests green, gates PASS, mutations caught, local acceptance PASS." if not bad else
          "**NOT READY FOR REVIEW: " + "; ".join(bad) + ".** Fix and rebuild the package before handing it over.")
lines = [f"# Review package: {p} / {x}", "", banner, "",
         "Everything below stays on the client machine. Read in this order:", "",
         "| # | Where | What to check |", "|---|---|---|",
         "| 1 | `1-research/RESEARCH.md` | what the OSB flow does (entry, branches, outputs, errors, logs) with evidence; open questions |",
         "| 2 | `2-card/FLOW_CARD.md` | the behaviour the code must implement; status of the approval |",
         f"| 3 | `module/src/main/resources/routes/` | **the Camel route, written by: {author}** (YAML DSL); helper beans in `module/src/main/java`; `application.properties` = production descriptor (OSB names, selector, connection from the environment); `MIGRATION_NOTES.md` |",
         "| 4 | `3-tests/` | **the tests to review**: `TESTS.md` (results by level), `RUN_TESTS.md` (how to run), `1-functional/` (test, expected outputs, cases), `2-error-paths/`, `3-runtime/`, `stubs/`. **all tests by level**: L1 functional, L2 error paths, L3 mutations, L4 gates, L5 runtime run, L6 deploy file, each with its result; test code in `module/src/test/` |",
         "| 5 | `3-tests/DEV_TEST_PLAN.md` | the tests still to run on Dev / E2E (deploy, functional per scenario, errors, security, side by side with OSB, non-functional) |",
         "| 6 | `4-acceptance/`, `5-results/` | local acceptance result, Camel JBang run, TEST_MATRIX.md, GATES.json (K1-K13), MUTATION.json, surefire summaries |",
         "| 7 | `6-deploy/camel-k/` | integration.yaml + DEPLOY.md as handed to Argo CD |",
         "| 8 | `7-dev-tests/README_DEV_TESTS.md` | the tests to run against Dev after deployment: dev_check.sh (deployment), dev_test.py (functional, errors, security, OSB side by side) |",
         "| 9 | `8-compare/COMPARISON.md` | (if present) generated route vs reference route on the same tests |", "",
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
print(banner); print("\n".join(lines[20:30]))
PY
(cd "$WS/review" && tar -czf "$P-$X.tgz" "$P-$X")
# Dev handover: what the deployer and the Dev tester need, nothing else (deploy files + Dev tests + results so far)
H="$WS/review/$P-$X-dev"; rm -rf "$H"; mkdir -p "$H"
cp -r "$O/6-deploy/camel-k" "$H/" 2>/dev/null; cp -r "$O/7-dev-tests" "$H/dev-tests"; cp "$O/3-tests/TESTS.md" "$H/" 2>/dev/null
(cd "$WS/review" && tar -czf "$P-$X-dev.tgz" "$P-$X-dev" && rm -rf "$P-$X-dev")
echo "dev handover:   $WS/review/$P-$X-dev.tgz  (camel-k/ + dev-tests/ + TESTS.md)"
echo "review package: $O  (+ $WS/review/$P-$X.tgz). Keep it on the client machine."
