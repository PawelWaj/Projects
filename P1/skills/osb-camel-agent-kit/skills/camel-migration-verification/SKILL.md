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
