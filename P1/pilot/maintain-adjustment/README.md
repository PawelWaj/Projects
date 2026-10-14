# Pilot proof — maintain-adjustment on Camel K (YAML DSL), Camel 4.18

OSB project `beneficiary-engagement-change-prj`, proxy `maintain-adjustment`, topic `contributorAgreementTopic`.
Decisions 2026-10-14: Camel **4.18** (Camel K runtime pinned with `camel.runtime-version=3.33.3` = Camel Quarkus 3.33.3
= Camel **4.18.4**), YAML route + small Java helper beans, start before the operator approval.

| File | What |
|---|---|
| `src/main/resources/routes/maintain-adjustment.camel.yaml` | the Camel K route. **Stand-in logic** until task 2: only what the logs prove (input topic, lenient JSON like OSB, the OSB log line, success/error routing). The block between `BEGIN/END flow logic` is replaced from the approved flow card |
| `src/main/java/.../OsbJson.java` | helper bean: accepts payloads the way OSB does (raw control characters, text after the JSON — both found in the E2E export) and lifts `businessTransaction` / `approvedOrRejected` into headers |
| `src/main/resources/application.properties` | production endpoints (stand-in names; Camel K: `traits.camel.properties`) |
| `src/test/java/.../MaintainAdjustmentParityTest.java` | **L1 test**: YAML route + Camel mock endpoints, one test per case folder |
| `src/test/resources/parity/**` | case folders in the task-1 format. **In the repo: synthetic** (from the bundled sample). On the VDI: the real masked ones |

## What the tests prove

| Test | Proves | Today |
|---|---|---|
| `sameOutcomeAndCorrelationAsOsb` (one per case) | the message reaches the same destination as in OSB (success/error) and keeps its `traceId` | runs |
| `bodyEqualsOriginalXQueryResult` (one per case) | the output body equals the original OSB XQuery result (`expected-output.json`, task 2) | skipped with reason "expected output pending" |
| `invalidPayloadGoesToErrorWithCode` | unreadable message → error destination with `errorCode`, `errorMessage`, `traceId` | runs |
| `payloadsOsbAcceptsAreAccepted` | the two payload quirks seen in the E2E export are accepted | runs |
| `caseFoldersArePresent` | the suite never passes empty | runs |

Checked 2026-10-14 on synthetic cases: 23 tests, 0 failures, 10 skipped (bodies pending). Breaking the route on purpose
(success → error) makes 11 tests fail, so the tests do exercise the YAML route.

## Run it on the VDI with the REAL masked cases

Needs JDK 21 and Maven with the GOSI Nexus mirror (Camel 4.18.4, JUnit 5.12, Jackson from the mirror).
```
P1=/e/Pawel/Projects-git/P1                         # or the ZIP folder
cd $P1/pilot/maintain-adjustment
rm -rf src/test/resources/parity
cp -r /e/Pawel/maintain-adjustment/task1/fixtures/parity src/test/resources/parity     # real masked cases from task 1
mvn -B test
```
Expected: `Tests run: N, Failures: 0`, where N = 3 + 2 × the number of cases, and the skipped tests are the bodies pending from task 2.
Send back: the `Tests run` line, and `target/surefire-reports/*.txt` if anything fails. Never send the case folders.
After the run, put the synthetic folders back (`git checkout -- src/test/resources/parity`), and don't commit real cases.

## Next (in this order)
1. Task 2 with the OSB source → flow card, selector, backends, error handler, `expected-output.*` per case.
2. pi implementer replaces the stand-in block; `bodyEqualsOriginalXQueryResult` then runs for every case.
3. L2 (Artemis + WireMock containers: selector negatives S02–S06, fan-out F01) and L3 replay, if Docker or Podman is available.
4. Camel K: `kamel run src/main/resources/routes/maintain-adjustment.camel.yaml` with the runtime pinned to 3.33.3 and
   the helper jar as a dependency. Not yet tried on a cluster; it needs the operator approval.
