# Pilot: maintain-adjustment on Camel K (YAML DSL), Camel 4.18

OSB project `beneficiary-engagement-change-prj`, proxy `maintain-adjustment`. Camel 4.18.4 = Camel Quarkus 3.33.3,
the Camel K runtime pin (`camel.runtime-version=3.33.3`). Built 2026-10-14 the way every flow will be built:
research pack (pi on the VDI, no source left the VDI) → `scaffold_camelk.py` → route implemented from the card → gates.
This module is the **reference implementation** for skill `osb-camelk-route`.

| File | What |
|---|---|
| `src/main/resources/routes/maintain-adjustment.camel.yaml` | the route: request log line as OSB, JSON check, `hasPPAEngagement='true'` → PPA queue, `hasGOSIEngagement='true'` → GOSI queue (retry 3 × 10 s), none → nothing sent, any fault → error queue with the original body and error headers |
| `src/main/java/.../OsbJson.java` | helper bean: parses like OSB accepts it, lifts the two flags into headers, never changes the body |
| `src/main/resources/application.properties` | endpoints; queue names are the OSB JNDI names until the Artemis queue register gives the addresses |
| `FLOW_CARD.md` | generated from the research pack; **draft** until a human approves it (4 open points: `vdi-osb-migration/DOMAIN_RUN.md`) |
| `src/test/java/.../FlowParityTest.java` + `flow-test.json` | **generated, do not edit**: every case reaches exactly the outputs its scenario maps to, keeps `traceId`; body = original XQuery result where one exists |
| `src/test/java/.../FlowErrorTest.java` | error handler: original body + errorCode/errorMessage/debugInfo/traceId/resource/eventType on the error queue, GOSI send retried 3×, PPA send not retried, generated traceId, body forwarded byte for byte |
| `src/test/resources/parity/**` | **synthetic** cases in the repo (fake values, all flag combinations incl. a missing flag). `.gitignore` keeps real cases out |

Checked 2026-10-14 on the synthetic cases: 16 tests, 0 failures, 5 skipped (bodies: no golden output for this flow,
it forwards the input unchanged). Four route mutations (wrong condition, no retry, header dropped, wrong queue) each
make tests fail. Gates (`check_camelk.py`) all PASS once the card is approved.

## Run on the VDI with the real masked cases

The cases must carry the flags as scenario dims (rerun task 1 with
`SCENARIO_DIMS='hdr_resource,body:data.businessTransaction,body:data.hasPPAEngagement,body:data.hasGOSIEngagement'`).
```
cd $P1/pilot/maintain-adjustment
cp -r /e/Pawel/maintain-adjustment/task1/fixtures/parity/* src/test/resources/parity/
mvn -B test        # JDK 21, Maven with the GOSI Nexus mirror
```
Send back the `Tests run` line (and `target/surefire-reports/*.txt` if anything fails). Never the case folders.

## Next
1. Approve the card after the 4 open points (DOMAIN_RUN.md).
2. L2: Artemis subscription queue with the selector as filter (negatives: other resource, other eventType), fan-out
   to `record-contribution` unaffected.
3. `kamel run` on a cluster once the operator is approved.
