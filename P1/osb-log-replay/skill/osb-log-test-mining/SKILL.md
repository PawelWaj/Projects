---
name: osb-log-test-mining
description: Build test cases for migrated OSB flows from production OSB logs. Reads the Log actions in the OSB pipeline source to derive log signatures, generates Splunk searches, rebuilds traces and scenarios from exported events with personal-data masking, writes fixtures with provenance, and replays them end to end against the Camel flow on a mock broker. Use when asked to test an OSB-to-Camel migration with real traffic, to mine Splunk or WebLogic logs for test cases, or to set up a replay or mock environment for a migrated flow.
---

# OSB log test mining

Tools live in `osb-log-replay/tools/` (stdlib Python; the replay runner needs `stomp.py`). Method and pitfalls:
`osb-log-replay/docs/WORKFLOW.md`. Read it before step 2.

## Steps

1. **Signatures from source**: `python3 tools/osb_log_signatures.py <osb-export> -o work/signatures.json`.
   Report: number of signatures per flow, log levels (debug lines are often off in production), signatures without a
   correlation field, ambiguous splits. These limit everything after; say so before searching.
2. **Splunk searches**: `python3 tools/spl_from_signatures.py work/signatures.json --index <idx> --sourcetype <st> -o work/queries.spl`.
   Ask the user for index and sourcetype. Ask them to run one trace search in Splunk and confirm that a multi-line
   payload arrives as one event.
3. **Export**: the user exports `_raw` + `_time` (CSV from the UI, or `tools/splunk_export.py` with `SPLUNK_TOKEN` in the
   environment). Never ask for the token in chat; never write it to a file.
4. **Traces and scenarios**: `python3 tools/osb_log_traces.py work/signatures.json <events> -o work/traces [--dims ...]`.
   Read `coverage.json` and explain: signatures never seen, traces without payload, events without correlation.
   Present `scenarios.json` by frequency.
5. **Fixtures**: `python3 tools/fixtures_from_traces.py work/traces/traces.jsonl replay-config.json -o work/fixtures`.
   Copy `work/fixtures/parity` and `golden/MANIFEST.csv` into the Camel module's `src/test/resources`.
6. **Golden outputs**: run the ORIGINAL XQuery/XSLT on each `input.payload` (osb-to-camel skill, golden test) and save
   `expected-output.xml` next to it with manifest source `original-transform`.
7. **Unit tests**: the tester role of the agent kit writes route tests from the flow card, using these fixtures as
   inputs (template `templates/java/RecordedCasesRouteTest.java`; level 2: `RecordedCasesBrokerIT.java`). They are the
   base layer and must pass before replay. How to mock at each level: `docs/MOCKING_RUNBOOK.md`.
8. **E2E replay**: fill `replay-config.json` with the flow's target broker names and the proxy selector; then
   `cd mock && docker compose up -d && ./setup_broker.sh`; start the flow (`--profile sut`); run
   `docker compose --profile replay run --rm replay`. Report `work/report/junit.xml`.

## Rules

- Expected values come from OSB evidence (logs, recorded messages, the original transform), never from the new code.
- Mask personal data at extraction with the data owner's key (`MASK_KEY` env var; `--unkeyed` only for synthetic samples), delete the raw export (`--delete-input`), run `tools/mask_residue_check.py` (must report 0 findings) and have a named reviewer check a sample before fixtures leave the secure environment.
- Negative cases for the JMS selector come from the proxy configuration (`negative_cases`), because OSB never logs a
  message its selector rejected.
- A scenario without a payload is reported, not invented. Propose the options in WORKFLOW.md ("When logs are not enough").
