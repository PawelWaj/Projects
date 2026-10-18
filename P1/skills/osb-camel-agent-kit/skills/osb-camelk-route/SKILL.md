---
name: osb-camelk-route
description: "Turn one OSB proxy's research pack (research.json from osb-research) into a Camel K integration in YAML DSL with helper beans and L1 tests (Camel 4.18, mock endpoints, real masked log cases), then make it green against fixed gates. Use when asked to build, implement, generate or migrate a Camel K route from a research pack or FLOW_CARD.md, or when the user says osb-camelk-route."
---

# Research pack → Camel K route (YAML DSL) + tests

Input: `research/<project>/<proxy>/research.json` (the shareable pack, check PASS) and, on the client machine, the
masked task-1 cases. Output: `modules/<project>/<proxy>/`, a Maven test module around a `*.camel.yaml` route
(Camel 4.18.4 = Camel Quarkus 3.33.3, the Camel K runtime pin). Pattern: `pilot/sample-adjustment` in the repo.

## Rules

1. **Tests first and fixed.** `FlowParityTest.java` and `flow-test.json` are generated from research.json and are
   hash-checked (gate K5). Never edit them, never add `@Disabled`. If a test is wrong, the research is wrong: say so.
2. **The card decides.** Nothing is implemented before `FLOW_CARD.md` has `Status: approved` and an approver. Every
   behaviour in the route traces to a card section; anything not on the card is an open question, not code.
3. **Same behaviour as OSB, quirks included**: same outputs per scenario, body forwarded unchanged when OSB forwards it,
   same log line text under logName `oracle.osb.logging.pipeline`, same error headers, same retries.
   A difference you cannot avoid goes into `MIGRATION_NOTES.md` (what, why, who must accept it).
4. **No infrastructure in code.** Endpoints are `{{properties}}`; no hosts, ports, credentials (gate K4).
5. **Original transforms stay.** XQuery/XSLT/XSD files are copied from the OSB source into
   `src/main/resources/osb/` and run by `camel-saxon` / `camel-xslt-saxon`; never rewritten "because it is cleaner".
   They stay on the client machine with the module (client Git), never in a research pack.
6. Component options: check the Camel 4.18 docs; do not guess. Patterns proven on the pilot: `references/yaml-patterns.md`.

## Steps

1. **Scaffold (script):**
   `python <skill>/scripts/scaffold_camelk.py research/<project>/<proxy> -o modules/<project>/<proxy> --project <project> [--parity task1/fixtures/parity]`
   Writes the route skeleton (ids `branch-*`, `out-*`, `backend-*`; gaps marked `TODO(flow-card)`), properties,
   helper bean, generated tests, `FLOW_CARD.md` (draft). Route, properties and card are written once; tests always
   follow research.json.
2. **Approval (human):** a person checks the card against `RESEARCH.md`, resolves or accepts each open question, sets
   `Status: approved`, `Approver:`, `Date:`.
2b. **Test inputs where Splunk has none (pi tester, before the route):** every `scenario_mapping` row needs a case
   (gate K9). Rows without a real Splunk message get a synthetic case written by the tester role
   (`agents/tester-camelk.md`): fake values, built from the message schema in the OSB source, under
   `src/test/resources/parity/<project>-<proxy>-synthetic/`. Then
   `scaffold_camelk.py … --freeze-synthetic` records their hashes, so gate K5 also protects them from the implementer.
3. **Implement the route:** replace every `TODO(flow-card)` from the card. Keep the ids. Conditions read
   `${exchangeProperty.<field>}` (set by OsbJson.annotate), never headers; a path with no output in OSB gets no
   `when`; set the property `osbStage` before each OSB stage (debugInfo); errorCode = exception class name. Log templates become simple
   expressions with the same literal text. Conditions use the headers the helper bean sets (`${header.x}`).
4. **Error tests:** `src/test/java/<pkg>/FlowErrorTest.java`, at least one test per error scope on the card: invalid
   payload, each output/backend failing (mock `whenAnyExchangeReceived` throwing), retries counted
   (`getReceivedCounter()`), error headers and original body on the error output, generated traceId. Set retry delays
   to 0 through properties in the test, never by changing production defaults.
5. **Stubs:** one file per backend whose response is used: `src/test/resources/stubs/<backend>.json|xml|txt`,
   shape from research Q8, fake values only.
6. **Run until green:** `python <skill>/scripts/verify_module.py modules/<project>/<proxy>` (mvn test + gates, ~30
   lines; the full Maven log stays in target/verify-mvn.log: never read it whole, never run raw mvn). Gates:
   K1 card approved · K2 no TODO(flow-card) in src/main · K3 every route id present · K4 no infrastructure ·
   K5 generated tests and frozen synthetic cases untouched, nothing disabled · K6 stubs · K7 error tests ≥ error scopes ·
   K8 tests green · K9 every scenario_mapping row has a case · K10 every property value a plain endpoint (no notes,
   no spaces) and every `{{key}}` defined · K11 each destination once: a JMS business service that writes an `out-*`
   IS that output, so never add a `backend-<x>-bs` send next to `out-<x>` (production would get every message twice).
7. **Prove the tests bite:** `python <skill>/scripts/mutate_route.py modules/<project>/<proxy> --mvn "mvn -B -q -s ~/.m2/settings.xml"`
   breaks the route on purpose (conditions negated, outputs swapped or dropped, retries removed); every mutation must
   make a test fail. A survivor means a missing test: add it to FlowErrorTest, never weaken the route to pass.
8. **Matrix:** `python <skill>/scripts/test_matrix.py modules/<project>/<proxy>` → `TEST_MATRIX.md` (P scenarios with
   real messages, E error tests, K gates, M mutations).
8b. **Against a broker (L2):** `broker/LOCAL_BROKER_TEST.md`: the same route and the same cases on a local Artemis
   (`artemis_prepare.sh`, `run_local.sh`, `send_case.sh`, `queues.sh`); `env/local.properties` holds the local names.
   The route never changes for this: endpoints and the connection are properties (`{{env:BROKER_URL}}`, ...).
9. **Report** (five lines): proxy, gates result, tests run/failed/skipped (skipped = golden outputs pending),
   differences recorded in MIGRATION_NOTES.md, open questions left.

## What the generated parity test proves

Each case is sent to `direct:in` as request/reply. Request-response proxies (HTTP, local) have an output `reply`:
the answer to the caller, checked like a queue (present, no exception, body = golden where one exists).
Each real masked case is sent to `direct:in`. Its `SCENARIO.txt` is matched against `scenario_mapping` in research.json
(`k=v` equal, `k!=v` different or missing, first row wins) and must reach exactly those outputs, no others, with the
correlation header. Where `expected-output.json|xml` exists (the original XQuery run by golden_runner), the body must
be equal. Invalid JSON must reach the error output. The scenario fields the route branches on must be task-1
scenario dims (`SCENARIO_DIMS=...,body:<path>` from research `scenario_dims`), or the mapping cannot match.
