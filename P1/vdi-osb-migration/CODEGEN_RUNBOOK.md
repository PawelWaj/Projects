# Runbook: OSB → Camel K code generation with skill `osb-camelk-route`, and a fair comparison with another skill

Skill: [`P1/skills/osb-camel-agent-kit/skills/osb-camelk-route`](../skills/osb-camel-agent-kit/skills/osb-camelk-route/SKILL.md)
(scripts, templates, [YAML patterns](../skills/osb-camel-agent-kit/skills/osb-camelk-route/references/yaml-patterns.md)).
Reference result: [`P1/pilot/sample-adjustment`](../pilot/sample-adjustment/README.md).
Everything runs on the VDI (Git Bash). Scope here: **generating the route code**. How the tests are created:
[HOW_IT_WORKS.md](HOW_IT_WORKS.md), [DOMAIN_RUN.md](DOMAIN_RUN.md).

## 1 What the skill generates, from what

| Input (must exist first) | Made by |
|---|---|
| `research/<project>/<proxy>/research.json` + `RESEARCH.md` | `pi/run_research.sh` (pi reads the OSB source) |
| frozen test pack `modules/<project>/<proxy>/src/test/**` | `pi/run_tests.sh` (generated tests, real + synthetic cases) |
| `modules/<project>/<proxy>/FLOW_CARD.md` with `Status: approved`, `Approver:`, `Date:` | a person |

| Output (code) | What |
|---|---|
| `src/main/resources/routes/<proxy>.camel.yaml` | the Camel K route, YAML DSL, Camel 4.18.4 (= Camel K runtime 3.33.3) |
| `src/main/java/**` | small helper beans (e.g. `OsbJson`: lenient parse, branch fields as headers) |
| `src/main/resources/application.properties` | endpoints as properties, no hosts or credentials |
| `src/test/java/**/FlowErrorTest.java`, `src/test/resources/stubs/*` | error tests and backend stubs written with the route |
| `MIGRATION_NOTES.md` | differences to OSB that could not be avoided |

## 2 Generate the code for one flow

```
export JAVA_HOME="/c/Program Files/Eclipse Adoptium/jdk-21.0.11.10-hotspot"
export PATH="/e/Pawel/apache-maven-3.9.9/bin:$JAVA_HOME/bin:$PATH"; hash -r
export PI_OFFLINE=1 PI_TELEMETRY=0 MVN_ARGS='-s ~/.m2/settings.xml'
KIT=/e/Pawel/Projects-main/P1/skills/osb-camel-agent-kit
cd /e/Pawel/work
P=sample-transform-prj; X=sample-transform                       # project / proxy
# card approved? then:
OSB_SRC=/e/osb-application/$P bash $KIT/pi/run_camelk.sh research/$P/$X modules/$P/$X $P
```
What happens: (1) test pack refreshed, synthetic cases only where missing; (2) stops with exit 3 if the card is not
approved; (3) **pi implementer** (role `agents/implementer-camelk.md`, skill `osb-camelk-route`) fills the route
skeleton, copies the original XQuery/XSLT/XSD from `OSB_SRC` into the module, writes FlowErrorTest and stubs, runs
`mvn test` and the gates until they pass; (4) `mvn test` + `check_camelk.py` again, independently of pi.
Logs: `modules/$P/$X/.agent-logs/` (stay on the VDI). Rate limits are retried automatically (`PI_PAUSE`, `PI_BACKOFF`).

Then prove the tests bite and write the evidence:
```
python $KIT/skills/osb-camelk-route/scripts/mutate_route.py modules/$P/$X --mvn "mvn -B -q $MVN_ARGS"
python $KIT/skills/osb-camelk-route/scripts/test_matrix.py modules/$P/$X
```
Many flows: `PROJECTS='a-prj|b-prj' bash $KIT/pi/run_domain.sh <app> build`, then `… matrix`.

Interactive alternative (same rules): start `pi` in `$KIT`, then `/osb-camelk modules/$P/$X research/$P/$X`.

### Gates the generated code must pass (`check_camelk.py`)

K1 card approved · K2 no `TODO(flow-card)` left · K3 every branch/output/backend id present · K4 no hosts, ports,
credentials · K5 generated tests and frozen cases unchanged, nothing disabled · K6 stub per used backend reply ·
K7 error test per error scope · K8 `mvn test` green · K9 every scenario has a case. Plus the mutation check
(every deliberate defect must fail a test) and the review list in section 4.

## 3 Compare with another code-generation skill

**Principle:** both skills generate code for the **same flows from the same inputs**, and both are judged by the
**same frozen test pack**, which neither of them wrote or may change. Then the numbers are comparable.

### 3.1 Set-up (once per flow)

1. Pick 3 flows of different kinds, e.g. `sample-adjustment` (branches, retries, error queue),
   `sample-transform` (XQuery transform; expected body = what OSB logged), one HTTP request/reply flow.
2. Build the test pack first: `run_domain.sh <app> auto` (or `run_tests.sh` per flow) and approve the cards.
3. Give both skills the same inputs: the OSB source of the project and/or `RESEARCH.md` + `FLOW_CARD.md`. Record which
   inputs each skill used, the model, and the start/end time.
4. Do not show either skill the test pack's case folders (they are the exam). The test classes may be read.

### 3.2 Generate

- **Ours:** section 2 (`run_camelk.sh`), output in `modules/<p>/<x>/src/main/**`.
- **Colleague's skill:** its own command; copy its output (routes `*.yaml` or Java `RouteBuilder` classes, helper
  beans, `application.properties`) into `compare-input/<x>/colleague/`.
- Endpoint contract the tests use: input `{{flow.input}}`, outputs `{{out.<business-service>}}`, backends
  `{{backend.<name>}}` (names in `src/test/resources/flow-test.json`). If the other skill uses its own URIs, write an
  endpoint map instead of changing its code, e.g. `compare-input/<x>/colleague.map`:
  ```
  amqp:queue:jndi.outboundQueue = {{out.sample-transform}}
  amqp:topic:jndi.sampleTopic = {{flow.input}}
  ```

### 3.3 Run the comparison

```
mkdir -p compare-input/$X/ours && cp modules/$P/$X/src/main/resources/routes/*.yaml compare-input/$X/ours/ \
  && cp -r modules/$P/$X/src/main/java compare-input/$X/ours/ 2>/dev/null
python /e/Pawel/Projects-main/P1/vdi-osb-migration/bin/compare_codegen.py modules/$P/$X \
  --candidate ours=compare-input/$X/ours \
  --candidate colleague=compare-input/$X/colleague,map=compare-input/$X/colleague.map \
  --mvn "mvn -B -q $MVN_ARGS" --mutate -o compare/$X
cat compare/$X/COMPARISON.md
```
Each candidate runs in its own copy of the module (`compare/$X/<name>/`, with `mvn.log`, `GATES.json`,
`TEST_MATRIX.md`); the test pack is identical for all. YAML and Java DSL routes are both supported.

### 3.4 Scoring

| Criterion | Measured by | Weight |
|---|---|---|
| Behaves like OSB | parity tests failed (`failed`), scenarios passed (`scenarios_pass`), body checks | decisive |
| Error handling like OSB | `error_tests_failed` (error queue, headers, retries, invalid input) | decisive |
| Tests bite on this code | `mutations_caught` (n/n expected) | high |
| Safe and complete | gates K2, K4–K9 (`gates_K2_K9`) | high |
| Review list (section 4) | a reviewer, per item yes/no | medium |
| Size and readability | `route_lines`, `java_lines`, reviewer note | low |
| Effort | wall time, model calls, manual fixes needed to reach green | medium |

Decide per flow, then over the 3 flows. A skill that needs manual fixes is scored on the first run and on the fixed run.

## 4 Review list for generated code (both skills)

- [ ] OSB log lines kept with the same text and logName `oracle.osb.logging.pipeline` (tests do not check log text)
- [ ] original XQuery/XSLT files used unchanged, not rewritten in Java or YAML
- [ ] every branch, output, retry and error header from the card present; nothing that is not on the card
- [ ] body forwarded unchanged where OSB forwards it
- [ ] endpoints and values only as properties; no hosts, ports or secrets
- [ ] YAML DSL for Camel K (or a stated reason for Java DSL); helper beans small and tested
- [ ] differences to OSB written in MIGRATION_NOTES.md

## 5 What to send back (no code, no data)

`compare/<x>/COMPARISON.md` per flow, the review list per candidate, and the times. Not the modules or the routes:
they contain the original XQuery and stay on the VDI.
