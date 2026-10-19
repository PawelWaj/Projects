# From OSB project to review archive: the sequence that works

The proven path for one or a few OSB projects, from the Splunk export to the archive that goes to the reviewers.
Everything runs on the client machine (VDI), in Git Bash, in the workspace. Settings come from `.osb-kit.env`
(`pi/osb-kit.env.example`); `MASK_KEY` and `ARTEMIS_PASSWORD` are typed per session, never written to a file.
Background for each step: `DOMAIN_RUN.md` (stages), `FUNCTIONAL_TESTING.md` (tests), `../skills/osb-camel-agent-kit/broker/LOCAL_BROKER_TEST.md` (broker).

```
cd /e/Pawel/work && . ./.osb-kit.env
export MASK_KEY='<from the data owner>' ARTEMIS_PASSWORD='<broker password>'
P='a-prj|b-prj'                     # the projects that go to review together (regex on whole names)
```

## Session in one script (also after the VDI was restored)

```
cd /e/Pawel/work
bash <kit>/pi/vdi_session.sh setup <osb-application-folder>   # new/restored machine: .osb-kit.env + preflight
bash <kit>/pi/vdi_session.sh start                            # pacer for pi (rate limit) + local Artemis
export EXPORT=<Splunk CSV>                                    # only when new projects need test cases (task1)
bash <kit>/pi/vdi_session.sh flows 'a-prj|b-prj'              # research -> task1 -> body chain -> review archive
bash <kit>/pi/vdi_session.sh review 'a-prj|b-prj'             # later: delivery + tests + broker + archive, no pi
bash <kit>/pi/vdi_session.sh status | stop [--broker]
```
Passwords (Artemis, MASK_KEY) are asked for, never stored. Logs: `domain/pacer.log`, `domain/session-<date>.log`.
The steps below are what the script runs; use them one by one when something needs a closer look.

## 0 Once per session

| Check | Command | Good |
|---|---|---|
| kit is the latest | `cd $KIT && git log --oneline -1` (or the date of the unzipped download) | the commit you expect |
| Java and Maven | `mvn -v` | Maven 3.9.x, Java 21 |
| broker runs | `bash $KIT/broker/artemis_setup.sh status` | running; else `... start` |
| model platform | pacer window running (`python $KIT/pi/llm_pacer.py`) and `pi-on` done, if the platform rate-limits | `pacer on http://127.0.0.1:8765` |

A new kit download goes into a NEW folder (rename the old one first); point `KIT` in `.osb-kit.env` at it.

## 1 Splunk export of the projects

```
index=$SPLUNK_INDEX sourcetype=$SPLUNK_SOURCETYPE earliest=-90d@d "oracle.osb.logging.pipeline"
  ("a-prj" OR "b-prj") ("::{" OR "::<")
| dedup _raw | rex "for PS (?<proxy>\S+)" | dedup 500 proxy keepempty=true | sort 0 _time | table _time _raw
```
Export as CSV to the workspace (e.g. `export.csv`). Zero events: check the project name, a longer period, and other
sourcetypes (`| stats count by sourcetype` without the sourcetype filter); without logs the flow is tested with
synthetic cases only.

## 2 Research (pi) and test cases

```
PROJECTS=$P bash $KIT/pi/run_domain.sh research
EXPORT=export.csv PROJECTS=$P bash $KIT/pi/run_domain.sh task1
```
Check before going on:
- `task1/SUMMARY.md`: a flow marked CHECK with "scenario field X found in none of N messages" means research named the
  wrong field. Fix `scenario_dims` in `research/<project>/<proxy>/research.json` (a message header is `header.<name>`,
  a payload field anywhere is `//<name>`), then rerun task1.
- residue warnings: add the field to `MASK_JSON_KEYS` and rerun task1.

## 2b Check what OSB does to the body (per flow, no agent)

```
python $KIT/skills/osb-camelk-route/scripts/body_chain.py "$APP/<project>/<...>/<proxy>.pipeline" --summary
```
Every route line shows the format the queue gets and the chain, e.g.
`route -> <bs>: format=xml chain: nxsd(Native-To-XML <schema>) -> xquery(<xqy>)`; error routes `format=native`.
`unknown_tags` or `format=unknown` = an OSB construct the generator does not know yet: stop and report it. The
delivery runs exactly this chain with OSB's own files; the agent writes no transformation code.

## 3 Everything else in one command

```
PROJECTS=$P bash $KIT/pi/run_domain.sh review
```
The stage prints one short block per step; the details go to `domain/review-<date>.log`.

| Step | What it does | Read it like this |
|---|---|---|
| 1 tests | regenerates the frozen scenario table and the masked cases per flow | `"unmapped_log_scenarios": 0` and `"uncovered": []`; a `WARNING_unknown_outputs_in_scenario_mapping` line = fix research.json, rerun |
| 2-3 | (nothing: no pi build any more) | the route is generated from the OSB pipeline in step 4 |
| 4 delivery | `delivery/<app>/` WITHOUT a pom: route from the OSB pipeline (`body_chain.py`: nXSD + the flow's own .xqy, original body on the error path), Artemis kamelets, `transformations/`, `test/`, `run-local.sh` | `{"projects": n, "flows": m}`; read `docs/<proxy>/BODY_CHAIN.md`: format per queue and "Not generated / to check" |
| 5 tests | `jbang test/<Flow>Test.java` per project (no broker) | `N tests, 0 failed`; a FAIL line names the case and why. "did not run" = dependency or compile error, see `test/RESULTS.txt` |
| 6 broker | `run-local.sh run` (camel run, Artemis kamelets), one case per scenario, queue counts | the route log lines `Sending to <queue>` per case; `Error captured` = look at `test/broker-run.log` |
| 7 note | `REVIEW_HANDOVER_DRAFT.md` with numbers and detected review points | read every sentence |
| 8 archive | `delivery/<app>_review_<date>.tgz` | size in KB |

The reviewer needs only the archive, Java 21, JBang (or the `camel` CLI) and, for the broker run, an Artemis:
`bash run-local.sh test`, `bash run-local.sh run`, `bash run-local.sh send <proxy> <case>`, `bash run-local.sh stat` (RUN_LOCAL.md).

Rerun only what is needed: `REVIEW_TESTS=0` repeats steps 4 to 8 (a few minutes, no pi call).

## 4 Before sending

1. Copy `delivery/<app>/REVIEW_HANDOVER_DRAFT.md` to `REVIEW_HANDOVER.md` in the same folder and edit that copy: your
   name, the points only people know (questions to the client, decisions pending), remove what does not apply. Rerun
   step 3 with `REVIEW_TESTS=0`: the stage never overwrites `REVIEW_HANDOVER.md` and archives it instead
   of the draft (the draft is refreshed, so you can compare the numbers).
2. An extra class the note says nothing refers to: delete it in the module (`modules/<project>/<proxy>/src/main/java`),
   rerun with `REVIEW_TESTS=0`.
3. Send the archive only through the client's channel: it contains masked log data and the original XQuery logic.

## How the broker test works (step 6)

`run-local.sh run` starts the routes with `camel run`; the source kamelet connects to Artemis (core JMS) and creates
the shared durable subscription with the OSB selector as its filter. `run-local.sh send <proxy> <case>` publishes one
case to the topic like the OSB caller (body = input.payload, properties = headers.json, plus selector properties OSB
does not log, e.g. eventType, with the first allowed value). The broker copies it into every subscription whose filter
matches; the route transforms and sends to the output queue. Evidence: route log lines `Sending to <queue>`, queue
counts (`stat`), `test/BROKER_RUN.txt`. `run-local.sh stop` = `camel stop <name>` (works without PowerShell).

## Known traps (seen on the first two flows)

| Symptom | Cause | Fix |
|---|---|---|
| every case "scenario not mapped", values `?` | research wrote a header field as a payload path, or guessed the path | `scenario_dims`: `header.<name>` or `//<name>`; rerun task1 + tests |
| real cases expect 0 messages everywhere | research table names outputs that do not exist | resolved automatically for short names; otherwise fix the table |
| body differs only in time stamps / ids | OSB generates them | detected automatically (`generated_fields`); if one case lacks them in OSB's output, the route stamps where OSB does not: real difference, read the XQuery |
| old synthetic cases fail after a research change | cases written for an old table | removed automatically on the next `tests` |
| broker: route does not start, "Illegal character" | Windows line endings | fixed in the kit; take the latest download |
| broker: nothing arrives, 0 past the selector | the selector needs a property OSB does not log (e.g. eventType) | filled automatically with an allowed value, listed in the note |
| broker: a case "filtered by the subscription selector" | the selector excludes that resource | the case or the selector is wrong: a question for the review, not a route bug |
| `jbang` not installed, no internet | normal on the client machine | nothing to do: `Common-setup/jbang.sh` takes JBang from Maven/Nexus, Camel JBang from `camel-jbang-main`; an installed jbang/camel is used first |
| `could not open C:Users...jbang....args` | Windows argument-file path lost its backslashes | fixed in the kit (`JBANG_RUNTIME_SHELL=bash`); take the latest download |
| broker step: route started late, nothing routed, folder locked afterwards | first `camel run` downloads for minutes | the step waits up to 10 min and sends only after "started"; a leftover route: `bash run-local.sh stop` in that folder |
| broker step: subscription queue CONSUMER 1 but MESSAGES ADDED 0 | the message properties do not match the selector (wrong value, or spaces lost) | compare `test/resources/<proxy>/parity/**/headers.json` with `<proxy>.flow.input` in local.properties |
| old subscription queue from an earlier setup | a queue with the same name keeps its old filter | `artemis queue delete --name <proxy>` once; the route recreates it |
| tests green but the body is "the input" | the logged BS body was OSB's `$request`, not what OSB sent | the body now comes from `body_chain` + OSB's .xqy; golden only from `expected-output.xml` (OSB's real output) |
| pi call hangs 30 min / 429 | model platform limit | pacer (`llm_pacer.py`), smaller `PI_FIX_ROUNDS`, rerun later: finished flows are skipped |
