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
POC=1 PROJECTS=$P bash $KIT/pi/run_domain.sh review
```
`POC=1` builds routes from draft cards (proof of concept; gate K1 stays open until a reviewer approves the card).
The stage prints one short block per step; the details go to `domain/review-<date>.log`.

| Step | What it does | Read it like this |
|---|---|---|
| 1 tests | regenerates tests, mocks, cases, frozen | `"unmapped_log_scenarios": 0` and `"uncovered": []`; a `WARNING_unknown_outputs_in_scenario_mapping` line = the research table names an output that does not exist: fix research.json, rerun |
| 2 build | pi writes or fixes the route where tests are not green | `skip … (tests green)` is fine; `NOT GREEN` = look at step 3 |
| 3 verify | mock tests + gates per flow | `tests N, failures 0` = done. Failures: `verify_module.py <module> --max 15` shows them. "scenario not mapped" = research table, not the route. A failed gate K5 = pi edited the tests: rerun `tests`, never accept it |
| 4 flat | delivery/<app>/ in the agreed layout | `{"projects": n, "flows": m}` |
| 5 flat tests | `mvn test` in each delivery project | same numbers as step 3. `DID NOT COMPILE` stops the stage: fix, then rerun with `REVIEW_TESTS=0 REVIEW_BUILD=0` |
| 6 broker | `e2e_local.sh` per project on the local Artemis | `RESULT: every output queue got what the tests expect`. The `input of` line shows what got past the selector; 0 arrived = message properties do not match the selector |
| 7 note | `REVIEW_HANDOVER_DRAFT.md` with numbers and detected review points | read every sentence |
| 8 archive | `delivery/<app>_review_<date>.tgz` (no build output) | size in KB, not MB |

Rerun only what is needed: `REVIEW_TESTS=0 REVIEW_BUILD=0` repeats steps 3 to 8 without any pi call (a few minutes).

## 4 Before sending

1. Copy `delivery/<app>/REVIEW_HANDOVER_DRAFT.md` to `REVIEW_HANDOVER.md` in the same folder and edit that copy: your
   name, the points only people know (questions to the client, decisions pending), remove what does not apply. Rerun
   step 3 with `REVIEW_TESTS=0 REVIEW_BUILD=0`: the stage never overwrites `REVIEW_HANDOVER.md` and archives it instead
   of the draft (the draft is refreshed, so you can compare the numbers).
2. An extra class the note says nothing refers to: delete it in the module (`modules/<project>/<proxy>/src/main/java`),
   rerun with `REVIEW_TESTS=0 REVIEW_BUILD=0`.
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
