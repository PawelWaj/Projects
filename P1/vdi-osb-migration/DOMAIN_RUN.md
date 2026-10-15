# One OSB application, all its flows: research → card → Camel K route → green tests

An OSB application (e.g. `osb-application`) holds many projects (`*-prj`), each with one or more proxies.
`pi/run_domain.sh` runs the per-flow steps for every proxy, keeps going when one fails, and keeps a status table.
Everything runs on the VDI. What may leave it: `research/<project>/<proxy>/{RESEARCH.md,research.json,facts.json,SHARE_CHECK.json}`
and `domain/STATUS.md`. Never: the OSB source, `modules/` (it holds the original XQuery and the masked cases), agent logs.

```
KIT=$P1/skills/osb-camel-agent-kit        # or the workspace where the bootstrap scripts were pasted
APP=/e/osb-application       # Git Bash path: /e/..., not E:\...
cd /e/Pawel/work                          # workspace: research/, modules/, domain/ are created here
```

## Local settings, not in Git

Client-specific values (application folder, Splunk index and sourcetype, Maven settings, pi settings) live only on the
machine: copy `pi/osb-kit.env.example` to `~/.osb-kit.env` and fill it in; every runner reads it (values on the command
line win). The repo stays generic. Before a commit, `tools/check_no_client_names.sh --install` adds a hook that blocks
names listed in the local `~/.osb-kit-denylist` (one regex per line, also never in Git).

## Before the first build: Java 21, Maven 3.6.3+, the client Nexus (found on the pilot VDI, 2026-10-15)

The VDI has no internet, a system Maven 3.5.3 and `JAVA_HOME` on JDK 1.7 (kept for OSB/JDeveloper). Per Git Bash window
(or once in `~/.bashrc`):
```
export JAVA_HOME="/c/Program Files/Eclipse Adoptium/jdk-21.0.11.10-hotspot"     # JDK 21 is installed; Maven reads JAVA_HOME, not PATH
export PATH="/e/Pawel/apache-maven-3.9.9/bin:$JAVA_HOME/bin:$PATH"; hash -r
mvn -v                                                                            # Apache Maven 3.9.x, Java 21
```
Maven 3.9.9 comes from the client Nexus (`<nexus>/repository/maven-public/org/apache/maven/apache-maven/3.9.9/apache-maven-3.9.9-bin.zip`,
unzip to `E:\Pawel\`). `~/.m2/settings.xml` = the team's file with the Nexus mirror (`mirrorOf *`); remove its
`<localRepository>` line or point it at your own user. Never commit it. Run Maven with `-s ~/.m2/settings.xml`.

| Message | Cause |
|---|---|
| `Connect to repo.maven.apache.org ... timed out` | no settings.xml with the Nexus mirror (or Maven reads another file: use `-s`, add `-U` once) |
| `try-with-resources is not supported in -source 1.5` | old pom; update (compiler plugin pinned since c122237) |
| `Unsupported major.minor version 52.0` | Maven runs on Java 7: set `JAVA_HOME` to JDK 21 |
| `requires Maven version 3.6.3` / plugin API errors | Maven 3.5.3 on the PATH: put Maven 3.9.9 first, `hash -r` |

| Stage | Command | Who | Result |
|---|---|---|---|
| 0 list | `bash $KIT/pi/run_domain.sh $APP list` | script | every project/proxy found; check the count |
| 0b coverage | `SPLUNK_COVERAGE=<payload table.csv> … coverage` | script | `domain/COVERAGE.md`: per proxy A = real Splunk messages, B = logged without payload, C = not in Splunk; by transport (jms / http / jca) |
| 1 research | `… research` | pi (researcher) | `research/<project>/<proxy>/` per proxy, share check PASS; packs that passed are skipped on rerun |
| 2 task1 | `EXPORT=<domain export.csv> MASK_KEY=… … task1` | script | Splunk test messages per proxy, split by the fields its branches use (`scenario_dims` from step 1) → `task1/flows/<project>-<proxy>/` + `task1/SUMMARY.md` |
| 3 tests | `… tests` | script + pi (tester) | **the functional test pack per flow, no route needed**: generated tests + mocks, real masked Splunk messages, synthetic messages from the schema where Splunk has none, frozen; `TEST_MATRIX.md` catalogue per flow and `domain/TEST_MATRIX.md` (`scaffold` = same without the tester) |
| 4 approve | open each `FLOW_CARD.md`, compare with `RESEARCH.md`, settle the open questions, set `Status: approved`, `Approver:`, `Date:` | **human** | only approved cards are built |
| 5 build | `MVN_ARGS='-s ~/.m2/settings.xml' … build` | pi (implementer) | route implemented, error tests + stubs, `mvn test`, gates K1–K8 → `GATES.json` |
| 6 matrix | `… matrix` | script | route broken on purpose per green flow (`MUTATION.json`), `TEST_MATRIX.md` per flow + `domain/TEST_MATRIX.md` |
| auto | `… auto` | pi + scripts | 1 + 2 + 3 in one go: the functional test pack for every flow. Steps 4–6 (routes) are the next part |
| status | `… status` | script | `domain/STATUS.md`: research / open questions / test cases / card / gates / tests per proxy |

Domain export for step 2 (Splunk, CSV, Unlimited), all projects of the application:
```
index=<e2e_index> sourcetype="<osb_sourcetype>" earliest=-28d@d "oracle.osb.logging.pipeline" ("::{" OR "::<")
| dedup _raw | rex "for PS (?<proxy>\S+)" | dedup 500 proxy | sort 0 _time | table _time _raw
```
Flows that log no payload (groups B and C) get **synthetic** test messages: in `build`, before the route is written, the pi
tester writes one fake-value message per scenario from the message schema; they are frozen like the generated tests
(gate K5) and every scenario must have a case (gate K9). The matrix lists them as S rows, the real ones as P rows.
Request-response proxies (HTTP) are tested on their reply to the caller as well as on the queues.

Payload table for 0b (Splunk, export as CSV): `index=<e2e_index> sourcetype="<osb_sourcetype>" earliest=-28d "oracle.osb.logging.pipeline"
| rex "Project (?<project>\S+) :: for PS (?<proxy>\S+)" | eval payload=case(match(_raw, "::\s*\{"), "json", match(_raw, "::\s*<"), "xml", true(), "none") | stats count by project, proxy, payload`
What was tested and how: [HOW_IT_WORKS.md](HOW_IT_WORKS.md).

Unattended: `bash $KIT/pi/run_overnight.sh <stage> [hours]` repeats the stage in rounds (finished flows skipped), sleeps when the quota is used up, makes one tiny warm-up call per round and stops at the deadline; log in `domain/overnight.log`. What the endpoint allows: `python $KIT/pi/rate_limit_probe.py` (one tiny call, prints only the rate-limit headers).

Rate limit: the model endpoint answers `429 Too Many Requests` when calls come too fast. The runners wait and retry
(`PI_RETRIES`, default 5; `PI_BACKOFF`, first pause 60 s, doubled) and pause between flows (`PI_PAUSE`, default 30 s;
raise it, e.g. `PI_PAUSE=120`, if 429s keep coming). A pi stage with more than 10 proxies needs `ALL=1`.

Options: `PROJECTS='beneficiary|cancel-'` limits the run to matching project names (start with 2–3 projects).
`TASK1_ROOT=/e/Pawel` uses `/e/Pawel/<proxy>/task1` (the masked Splunk cases) for research and as test inputs.
`MVN_ARGS='-s <client settings.xml>'` for the Nexus mirror. One flow only: `pi/run_research.sh`, `pi/run_camelk.sh`.

## What the gates mean (check_camelk.py)

K1 card approved · K2 no `TODO(flow-card)` left in the route · K3 every branch/output id present · K4 no hosts, ports,
credentials · K5 generated tests unchanged, nothing disabled · K6 a stub per backend whose response is used ·
K7 at least one error test per error scope · K8 `mvn test` green (skipped = expected outputs from the original XQuery
still pending).

## The tests come from the logs, so the logs must carry the branch fields

The generated parity test reads each case's scenario (from task 1) and expects exactly the outputs that
`scenario_mapping` gives for it. If the branches decide on payload fields, task 1 must use those fields as scenario
dims, or no case can be mapped. `research.json` → `scenario_dims` names them. Pilot example:

```
export SCENARIO_DIMS='hdr_resource,body:data.businessTransaction,body:data.hasPartnerEngagement,body:data.hasMainEngagement'
$P1/vdi-osb-migration/bin/task1_log_only.sh events.csv task1      # same MASK_KEY as before
```

## Pilot `sample-adjustment`: what the research showed, what the card must settle

Route: request log → JSON check → two independent checks: `hasPartnerEngagement='true'` → partner queue,
`hasMainEngagement='true'` → main queue (retry 3 × 10 s); none → consumed, nothing sent; any fault → error queue with
the original body and errorCode / errorMessage / debugInfo / traceId. Reference implementation:
`P1/pilot/sample-adjustment`: **2026-10-15 on the VDI with the real masked E2E cases: 254 tests, 0 failures** (124 skipped = no golden body for this flow); 4 route mutations all caught.

Open points for the card (answer on the VDI, send back counts or yes/no only):
1. **Both flags true: one queue or two?** If the two calls are `route` actions in a route node, OSB sends to the first
   only; if they are `publish` actions (or routes in a stage), both fire. Run and send the output (element names only):
   ```
   grep -o '<[A-Za-z0-9]*:\(route-node\|stage\|route\|publish\|ifThenElse\)\b' /e/osb-application/sample-change-prj/Pipeline/sample-adjustment.pipeline | sort | uniq -c
   ```
   And from task 1 rerun with the flag dims: how many messages have both flags true.
2. **errorCode values.** OSB writes its fault code (e.g. a `BEA-...` / `OSB-...` code); Camel writes the exception
   type. Does the error-queue consumer depend on the code? If yes, list the codes it handles.
3. **JSON with text after the closing brace** (3 messages in the export): does OSB's nXSD accept it or send it to the
   error queue? Look up those 3 traceIds in the error queue / error log. The route accepts them today.
4. **Subscription name and queue names on Artemis:** the JNDI names (`jndi.…`) are placeholders until the queue
   register gives the Artemis addresses; the selector becomes the broker filter (L2 test).
