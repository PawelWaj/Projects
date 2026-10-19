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
| pi call hangs 30 min / 429 | model platform limit | pacer (`llm_pacer.py`), smaller `PI_FIX_ROUNDS`, rerun later: finished flows are skipped |
