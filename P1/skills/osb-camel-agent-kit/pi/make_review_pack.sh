#!/usr/bin/env bash
# One review package per flow: research -> card -> generated Camel K code -> tests -> results, with a reviewer checklist.
# Stays on the client machine (it contains the original XQuery and masked test data).
#
# Usage (in the workspace):  bash <kit>/pi/make_review_pack.sh <project> <proxy> [reference-route-dir]
# Env: ROUTE_AUTHOR (default "pi agent (osb-camelk-route)"): who wrote the route, shown in README_REVIEW.md
#   reference-route-dir  optional: another route for the same flow (e.g. the hand-written pilot) -> compared against
#                        the SAME frozen tests with compare_codegen.py
# Result: review/<project>-<proxy>/ + review/<project>-<proxy>.tgz   (agent logs and build output are left out)
set -uo pipefail
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
P=${1:?usage: make_review_pack.sh <project> <proxy> [reference-route-dir]}
X=${2:?proxy}
REF=${3:-}
WS=${WS:-.}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
R="$WS/research/$P/$X"; M="$WS/modules/$P/$X"; O="$WS/review/$P-$X"
[ -s "$R/research.json" ] || { echo "no research pack in $R: run run_domain.sh research first"; exit 2; }
[ -d "$M" ] || { echo "no module in $M: run run_domain.sh tests (and build) first"; exit 2; }
rm -rf "$O"; mkdir -p "$O"/{1-research,2-card,3-code,4-tests,5-results}
cp "$R"/RESEARCH.md "$R"/research.json "$R"/facts.json "$R"/SHARE_CHECK.json "$O/1-research/" 2>/dev/null
cp "$M/FLOW_CARD.md" "$O/2-card/" 2>/dev/null
[ -d "$M/src/main" ] && cp -r "$M/src/main" "$O/3-code/"
cp "$M/MIGRATION_NOTES.md" "$M/pom.xml" "$O/3-code/" 2>/dev/null
[ -d "$M/src/test" ] && cp -r "$M/src/test" "$O/4-tests/"
cp "$M/GATES.json" "$M/MUTATION.json" "$M/TEST_MATRIX.md" "$M/test-matrix.csv" "$O/5-results/" 2>/dev/null
[ -d "$M/target/surefire-reports" ] && cp "$M"/target/surefire-reports/*.txt "$O/5-results/" 2>/dev/null
if [ -n "$REF" ] && [ -d "$REF" ]; then
  echo "== comparing the generated route with $REF on the same frozen tests"
  "$PY" "$(cd "$KIT/../../vdi-osb-migration/bin" 2>/dev/null && pwd || echo "$KIT/bin")/compare_codegen.py" "$M" \
    --candidate generated="$M/src/main" --candidate reference="$REF" --mvn "mvn -B -q ${MVN_ARGS:-}" -o "$O/6-compare" >/dev/null 2>&1 \
    && rm -rf "$O"/6-compare/generated "$O"/6-compare/reference || echo "   comparison failed: see $O/6-compare"
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
         "| # | Folder | What to check |", "|---|---|---|",
         "| 1 | `1-research/RESEARCH.md` | what the OSB flow does (entry, branches, outputs, errors, logs) with evidence; open questions |",
         "| 2 | `2-card/FLOW_CARD.md` | the behaviour the code must implement; status of the approval |",
         f"| 3 | `3-code/main/resources/routes/` | **the Camel K route, written by: {author}** (YAML DSL), helper beans in `3-code/main/java`, endpoints in `application.properties`, `MIGRATION_NOTES.md` |",
         "| 4 | `4-tests/` | generated tests (FlowParityTest, frozen), FlowErrorTest, expected outputs (`flow-test.json`), test messages (`resources/parity`, masked / synthetic), stubs |",
         "| 5 | `5-results/` | TEST_MATRIX.md, GATES.json (K1-K9), MUTATION.json, surefire summaries |",
         "| 6 | `6-compare/COMPARISON.md` | (if present) generated route vs reference route on the same tests |", "",
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
         "- [ ] OSB log lines kept with the same text and logName (the tests do not check log text)",
         "- [ ] Original XQuery/XSLT used unchanged (not rewritten)",
         "- [ ] Body forwarded unchanged where OSB forwards it",
         "- [ ] Endpoints only as properties; no hosts, ports, secrets",
         "- [ ] Helper beans small and readable; YAML DSL idiomatic for Camel 4.18",
         "- [ ] Differences to OSB listed in MIGRATION_NOTES.md and acceptable",
         "- [ ] Open questions answered or accepted before the card is approved", "",
         "Reviewer: ____________  Date: ________  Result: approve / changes needed"]
(o / "README_REVIEW.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
print("\n".join(lines[14:24]))
PY
(cd "$WS/review" && tar -czf "$P-$X.tgz" "$P-$X")
echo "review package: $O  (+ $WS/review/$P-$X.tgz). Keep it on the client machine."
