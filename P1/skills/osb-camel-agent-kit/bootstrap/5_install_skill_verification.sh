#!/usr/bin/env bash
# Paste into the migration workspace root on the VDI and run: bash 5_install_skill_verification.sh
# Skill camel-migration-verification under .pi/skills/.
set -euo pipefail
mkdir -p "$(dirname ".pi/skills/camel-migration-verification/SKILL.md")"
cat > '.pi/skills/camel-migration-verification/SKILL.md' <<'KIT_EOF__PI_SKILLS_CAMEL_MIGRATION_VERIFICATION_SKILL_MD'
---
name: camel-migration-verification
description: Verify Camel on Spring Boot code generated from Oracle Service Bus flows - run the gates (build, Camel endpoint validation, repository rules, unit/route/golden/contract tests, Testcontainers Artemis integration tests, test-matrix coverage, oracle provenance, transform mutation), capture OSB expected outputs, run the E2E shadow comparison and write the evidence pack. Use after code or tests were generated for an OSB flow, when asked whether a migrated flow is correct, how to test it, or before signing a migration record.
---

# Verifying a migrated OSB flow

Generated code is accepted on **evidence from scripts**, never on an agent's statement. The oracle is OSB.

## Inputs

- The Maven module of the flow and the approved `migration/<flow>/FLOW_CARD.md` (its §8 test matrix, IDs T1..Tn).
- Expected outputs from OSB under `src/test/resources/golden/` and `parity/`, each listed in
  `src/test/resources/golden/MANIFEST.csv` (`file,source,flow,captured_by,date`).
- Docker or Podman for Testcontainers. If neither is available, G5 is **NOT RUN**, and NOT RUN is not green.

## Step 1: run the gates

```bash
tools/verify_flow.sh <module-dir> <flow> [card-path]
```

Writes `migration/<flow>/verify-report.json` and prints a table.

| Gate | Check |
|---|---|
| G1 | build (`mvn -DskipTests package`) |
| G2 | Camel endpoint URIs and options valid for this Camel version (`camel-report:validate`) |
| G3 | repository rules: no literal hosts/ports/OSB URIs, no credentials, no Camel K / Kamelet CRDs |
| G4 | unit, route, golden, contract tests green; skipped tests only if the record lists them |
| G5 | `*IT` integration tests with Testcontainers AMQ Broker (AMQP 5672) green |
| G6 | every matrix row T1..Tn of the card has a test (`tools/check_matrix.py`) |
| G7 | every expected file comes from OSB (`tools/check_oracle.py`) |
| G8 | every transform mutant is killed by the tests (`tools/mutate_transforms.py`) |

## Step 2: interpret a red gate

| Red gate | Usual cause | Who fixes |
|---|---|---|
| G1, G2, G3 | generated code | implementer |
| G4/G5 failing assertion | behaviour differs from OSB, or the test is wrong | implementer first; dispute via `TEST_DISPUTE.md`, decided by a fresh tester or a human |
| G6 | matrix row without a test | tester |
| G7 | expected file produced by Camel or undocumented | tester recaptures from OSB |
| G8 survivor | the golden test does not compare the mutated part (ignore list too wide, assertion too weak) | tester |

Never fix a red gate by deleting, skipping or weakening a test, or by widening the XMLUnit ignore list without a card
decision.

## Step 3: capture expected outputs (when fixtures are missing)

Per `references/testing-levels.md` §4: run the original `.xqy`/`.xsl` from `osb-src/` on Saxon with the `fn-bea` shim;
export OSB test console or message tracing results; mask personal data deterministically; register every file in
`MANIFEST.csv` with its source.

## Step 4: shadow run in E2E (before cut-over)

Per `references/testing-levels.md` §5: second subscription with the same filter, shadow destinations, capture of the
OSB output, then:

```bash
python3 tools/compare_shadow.py --osb <osb-dump-dir> --camel <camel-dump-dir> --key correlationId \
        [--ignore timestamp,creationTime] -o migration/<flow>/shadow-report.json
```

Exit criterion: zero unexplained differences over the agreed window, error-path messages included.

## Step 5: evidence pack

In `migration/<flow>/`: `verify-report.json`, `shadow-report.json` (when run), surefire/failsafe reports, `REVIEW.md`,
`MIGRATION_RECORD.md`. The record cites gate names and test IDs as evidence and never states "equivalent".
KIT_EOF__PI_SKILLS_CAMEL_MIGRATION_VERIFICATION_SKILL_MD
mkdir -p "$(dirname ".pi/skills/camel-migration-verification/references/testing-levels.md")"
cat > '.pi/skills/camel-migration-verification/references/testing-levels.md' <<'KIT_EOF__PI_SKILLS_CAMEL_MIGRATION_VERIFICATION_REFERENCES_TESTING_LEVELS_MD'
# Testing generated Camel code: levels L0–L7, gates G1–G8

AI-generated code needs **AI-independent proof**. Three principles carry everything below:

1. **The oracle is OSB, not Camel.** Expected outputs come from OSB recordings, from the original XQuery/XSLT run on
   Saxon, or from the OSB test console. Never from running the generated code.
2. **The tests must be able to fail.** Each transform is deliberately broken (mutation); a suite that stays green
   against a mutant is not evidence.
3. **Gates are scripts, not opinions.** `tools/verify_flow.sh` produces `verify-report.json`; an agent's statement that
   "tests pass" is not accepted without it.

## 1. Levels

| Level | What | Where it runs | Tooling | Proves |
|---|---|---|---|---|
| **L0 Static** | compile, Camel endpoint URI validation, repository rules | build agent | `mvn package`, `camel-report:validate`, `verify_flow.sh` G3 | code builds; every endpoint URI and option exists in this Camel version; no hosts, secrets, Camel K |
| **L1 Route logic** | each branch, selector outcome, error path, header mapping | build agent | `@CamelSpringBootTest`, `AdviceWith`, `MockEndpoint` | the pipeline's logic, backends replaced by mocks |
| **L2 Transform golden** | each XQuery/XSLT / native-to-XML step | build agent | Saxon + `fn-bea` shim, XMLUnit (canonical, ignore list) | output equals what OSB produced for the same input, quirks included |
| **L3 Messaging integration** | real broker behaviour | build agent with Docker/Podman | Testcontainers, AMQ Broker image, AMQP 5672, register snippet loaded | filters, durable subscription via FQQN, transacted consume+send, redelivery count/interval, error queue headers, duplicate-ID |
| **L4 Backend contract** | what leaves for HTTP/SOAP backends, timeouts, retries | build agent | WireMock (SOAPAction + XPath matching, delays, faults) | requests in the expected shape; retry/timeout as the business service was configured |
| **L5 Parity replay** | recorded OSB traffic replayed | build agent | recorded pairs under `src/test/resources/parity/<flow>/`, WireMock replays backends | real messages give the same output |
| **L6 Shadow run** | Camel runs next to OSB on live E2E traffic, output diverted | E2E | second subscription + shadow destinations + `tools/compare_shadow.py` | no differences on real traffic over an agreed window |
| **L7 Cut-over and rollback** | switch one flow, prove rollback | UAT then PROD window | runbook per flow | the switch and the way back both work |

L0–L5 run on every commit (gates). L6–L7 run once per flow before cut-over.

## 2. Gates (`tools/verify_flow.sh <module> <flow>`)

| Gate | Check | Fails when |
|---|---|---|
| G1 | `mvn -DskipTests package` | compile error |
| G2 | `mvn camel-report:validate` (plugin in `tools/pom-build-plugins.xml`) | unknown component, option or bad URI |
| G3 | static rules | literal host/port, `jms://`/`t3://` URIs, password-like values, `camel-k`/`Integration` CRDs, missing placeholders |
| G4 | `mvn verify`: unit, route, golden, contract tests (surefire) | any failure; any skipped test not listed in the record's "Skipped tests" section |
| G5 | integration tests `*IT` with Testcontainers (failsafe) | failure, or Docker unavailable (reported as NOT RUN, which is not green) |
| G6 | `tools/check_matrix.py`: every test-matrix ID T1..Tn on the card appears in a test name | missing row |
| G7 | `tools/check_oracle.py`: every file under `golden/` and `parity/` is in `MANIFEST.csv` with an OSB source | unlisted file or `source` not from OSB |
| G8 | `tools/mutate_transforms.py`: each transform mutated, golden tests re-run | a mutant survives (tests stay green) |

Optional G8b: PIT mutation testing (`pitest-maven`) on Java processors, threshold set per programme (start 70 %).

## 3. Independence rules for an agentic setup

- The **tester** works from the card and OSB evidence in a fresh context; it never sees the implementer's chat.
- The **implementer** cannot edit `src/test/**`, `golden/`, `parity/`, `MANIFEST.csv`; disputes go to
  `TEST_DISPUTE.md` and a fresh tester (or a human) decides.
- The **reviewer** is read-only and writes findings with file:line.
- CI enforces the file rule: a commit by the implementer identity touching test paths fails the build
  (`ci/Jenkinsfile.groovy`, stage `guard`).
- Humans approve the card before code (gate A) and sign the record after gates (gate B). Sample 1 in 5 flows for a full
  human code review during the first batch; lower the rate once reviewer findings stay MINOR.

## 4. Where the expected outputs come from

| Source | How to capture | Used by |
|---|---|---|
| Original transform | run the `.xqy`/`.xsl` from `osb-src/` on Saxon with the shim, input from the card's fixtures | L2 |
| OSB test console | per proxy/pipeline, save request + outbound message | L2, L5 |
| OSB message tracing / report action | enable tracing in E2E for the flow, export, mask personal data | L5 |
| Recording at the broker | non-exclusive divert copying the OSB output queue (when it is already on AMQ Broker) | L5, L6 |
| Card rule | a behaviour written on the approved card (for example "empty body to error queue") | L1, L3 |

Mask personal data at capture (SIN, national ID, names) with a deterministic mask so that pairs stay consistent.

## 5. Shadow run (L6), example `order-event`

1. Register a second subscription on the topic address with the **same filter**: `order-event-shadow`.
2. Deploy the Camel module in E2E with overrides: consume `<topic>::order-event-shadow`, send to
   `shadow.InboundOrderEventQueue` and `shadow.orderEventErrorQueue`. Nothing downstream reads shadow queues.
3. Capture OSB's real output (divert copy or tracing) into `compare.osb.*`.
4. `tools/compare_shadow.py --osb <dir|queue dump> --camel <dir|queue dump> --key correlationId` pairs messages by the
   correlation id (`uuId`/`traceId`) and diffs canonical XML plus headers.
5. Exit criteria: agreed window (for example 5 business days or N messages, per flow), **0 unexplained differences**,
   error-path messages compared as well. Differences explained by an approved card deviation go to the record.
6. Remove the shadow subscription before cut-over (an idle durable subscription keeps growing).

## 6. Cut-over and rollback (L7), per flow

- Cut-over: stop the OSB proxy's consumption (disable the proxy), start the Camel route on the production
  subscription. For HTTP/SOAP proxies: switch the Apigee target (roadmap bridge B2).
- Rollback: the reverse; the OSB proxy stays deployed and disabled until the soak period ends.
- Never run OSB and Camel on the **same** subscription at the same time (messages would split between them).
KIT_EOF__PI_SKILLS_CAMEL_MIGRATION_VERIFICATION_REFERENCES_TESTING_LEVELS_MD
echo "installed: 2 files (skill camel-migration-verification)"
