# One OSB application, all its flows: research → card → Camel K route → green tests

An OSB application (e.g. `contributor-agreement-mb-app`) holds many projects (`*-prj`), each with one or more proxies.
`pi/run_domain.sh` runs the per-flow steps for every proxy, keeps going when one fails, and keeps a status table.
Everything runs on the VDI. What may leave it: `research/<project>/<proxy>/{RESEARCH.md,research.json,facts.json,SHARE_CHECK.json}`
and `domain/STATUS.md`. Never: the OSB source, `modules/` (it holds the original XQuery and the masked cases), agent logs.

```
KIT=$P1/skills/osb-camel-agent-kit        # or the workspace where the bootstrap scripts were pasted
APP=/e/contributor-agreement-mb-app       # Git Bash path: /e/..., not E:\...
cd /e/Pawel/work                          # workspace: research/, modules/, domain/ are created here
```

| Stage | Command | Who | Result |
|---|---|---|---|
| 0 list | `bash $KIT/pi/run_domain.sh $APP list` | script | every project/proxy found; check the count |
| 1 research | `bash $KIT/pi/run_domain.sh $APP research` | pi (researcher) | `research/<project>/<proxy>/` per proxy, share check PASS; packs that passed are skipped on rerun |
| 2 scaffold | `bash $KIT/pi/run_domain.sh $APP scaffold` | script | `modules/<project>/<proxy>/`: route skeleton, generated tests, `FLOW_CARD.md` (draft) |
| 3 approve | open each `FLOW_CARD.md`, compare with `RESEARCH.md`, settle the open questions, set `Status: approved`, `Approver:`, `Date:` | **human** | only approved cards are built |
| 4 build | `bash $KIT/pi/run_domain.sh $APP build` | pi (implementer) | route implemented, error tests + stubs, `mvn test`, gates K1–K8 → `GATES.json` |
| status | `bash $KIT/pi/run_domain.sh $APP status` | script | `domain/STATUS.md`: research / card / gates / tests per proxy |

Options: `PROJECTS='beneficiary|cancel-'` limits the run to matching project names (start with 2–3 projects).
`TASK1_ROOT=/e/Pawel` uses `/e/Pawel/<proxy>/task1` (the masked Splunk cases) for research and as test inputs.
`MVN_ARGS='-s <GOSI settings.xml>'` for the Nexus mirror. One flow only: `pi/run_research.sh`, `pi/run_camelk.sh`.

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
export SCENARIO_DIMS='hdr_resource,body:data.businessTransaction,body:data.hasPPAEngagement,body:data.hasGOSIEngagement'
$P1/vdi-osb-migration/bin/task1_log_only.sh events.csv task1      # same MASK_KEY as before
```

## Pilot `maintain-adjustment`: what the research showed, what the card must settle

Route: request log → JSON check → two independent checks: `hasPPAEngagement='true'` → PPA queue,
`hasGOSIEngagement='true'` → GOSI queue (retry 3 × 10 s); none → consumed, nothing sent; any fault → error queue with
the original body and errorCode / errorMessage / debugInfo / traceId. Reference implementation:
`P1/pilot/maintain-adjustment` (16 tests green on synthetic cases, 4 route mutations all caught).

Open points for the card (answer on the VDI, send back counts or yes/no only):
1. **Both flags true: one queue or two?** If the two calls are `route` actions in a route node, OSB sends to the first
   only; if they are `publish` actions (or routes in a stage), both fire. Run and send the output (element names only):
   ```
   grep -o '<[A-Za-z0-9]*:\(route-node\|stage\|route\|publish\|ifThenElse\)\b' /e/contributor-agreement-mb-app/beneficiary-engagement-change-prj/Pipeline/maintain-adjustment.pipeline | sort | uniq -c
   ```
   And from task 1 rerun with the flag dims: how many messages have both flags true.
2. **errorCode values.** OSB writes its fault code (e.g. a `BEA-...` / `OSB-...` code); Camel writes the exception
   type. Does the error-queue consumer depend on the code? If yes, list the codes it handles.
3. **JSON with text after the closing brace** (3 messages in the export): does OSB's nXSD accept it or send it to the
   error queue? Look up those 3 traceIds in the error queue / error log. The route accepts them today.
4. **Subscription name and queue names on Artemis:** the JNDI names (`jndi.…`) are placeholders until the queue
   register gives the Artemis addresses; the selector becomes the broker filter (L2 test).
