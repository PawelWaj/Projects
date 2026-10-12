# One-time flow: from Splunk logs to test cases (pilot)

![one-time flow](osb_log_replay_p3.png)

One engineer runs this once, for one OSB project, to learn what the logs contain and to produce the first test cases.
No CI, no Docker needed. You need:
- Python 3;
- read access to Splunk (UI is enough);
- the OSB project files.

```bash
cd osb-log-replay
mkdir -p work
cp -r <path-to>/<project>-prj osb-src/          # the same OSB files the estimate was counted from
```

## Step 1. Read the logging from the OSB source

```bash
python3 tools/osb_log_signatures.py osb-src -o work/signatures.json
```

Open `work/signatures.json` and answer these four questions before going to Splunk:

| Question | Where to look |
|---|---|
| Which lines does the flow write? | one entry per Log action: `stage`, `pipeline_type` (request / response / error) |
| Which line carries the message (`body`)? At which level? | `roles.payload`, `level`; **debug is usually off in production** |
| Which field ties the lines of one message together? | `roles.correlation` (e.g. `uuId`, `traceId`) |
| Any warnings? | `warnings`: no correlation field, ambiguous split, weak anchor |

## Step 2. Make the Splunk searches

```bash
python3 tools/spl_from_signatures.py work/signatures.json --index <index> --sourcetype <sourcetype> -o work/queries.spl
```

The index and sourcetype of the OSB servers' logs come from whoever owns Splunk. `queries.spl` contains, per flow:
- an **EXPORT** search, to export;
- a **TRACES** search, to look at;
- one search per log line, to check field extraction.

## Step 3. Run the EXPORT search in the Splunk UI

1. Paste the **EXPORT** search for the flow and set the time range to 7–30 days (include a month end if the flow is
   business-cycle dependent).
2. Check three things before exporting:
   - **Lines found?** If not: wrong index or sourcetype, or the flow did not run in that period.
   - **Is the payload line there** (the Log action with `body` from step 1)? If not, see "No payload lines" below.
   - **One event per log line?** Open an event whose message spans several lines: it must be one event, not several.
     If it is split, ask the Splunk owner to fix event breaking for these sources, or ask for the raw WebLogic log
     files (step 4 reads them too).
3. Optional: run the **TRACES** search to see the lines grouped per message.
4. Export: **Export → CSV**. The file must contain the `_time` and `_raw` columns. Save it as `work/events.csv`.

**No payload lines?** In production the debug Log action is usually not written. Options, cheapest first:
- enable debug logging for this proxy in a test environment with production-like traffic and export from there;
- use the Report action or message tracing if they are already enabled for the service;
- or accept the gap: you still get scenarios and frequencies from the other lines, and inputs must come from
  elsewhere (OSB test console).

## Step 4. Analyse

```bash
python3 tools/osb_log_traces.py work/signatures.json work/events.csv -o work/traces
```

What it does:
- removes the WebLogic header from each line;
- matches the lines to the signatures;
- masks personal data with the data owner's key (`MASK_KEY`): names (incl. Arabic/English variants), addresses/remarks, birth dates (shifted, age band kept), e-mails, phone numbers, identity numbers, IBANs, in JSON and XML; the same value always gives the same mask with the same key; the raw input is deleted afterwards (`--delete-input`) and `tools/mask_residue_check.py` must report 0 findings before the fixtures leave the secure environment;
- groups the lines into one trace per message and classifies the traces.

Read:
- `work/traces/coverage.json`:
  - lines matched vs. read;
  - traces without payload;
  - Log actions never seen in the period.
- `work/traces/scenarios.json`: scenarios by frequency, in the form `flow | success or error | header values | errorCode`.

## Step 5. Decide

- **Compare the scenarios with the flow card's test matrix.** A scenario in the logs but not on the card is a missing
  test; a card row never seen in the logs needs a reason (rare branch, or dead code).
- **Pick what to test:** the top scenarios (most of the traffic) plus every error code.
- **Write down the gaps:** no payload, never-seen lines. Each gap gets an owner or a decision.

## Step 6. Produce the test cases

Fill `replay-config.json` for the flow: the output queues per outcome, and the error headers OSB sets. Then:

```bash
python3 tools/fixtures_from_traces.py work/traces/traces.jsonl replay-config.json -o work/fixtures --per-scenario 3
```

Result: `work/fixtures/parity/<flow>/<scenario>/<trace>/` with `input.payload`, `headers.json` and `expected.json`, plus
`work/fixtures/golden/MANIFEST.csv` (every file marked as recorded from OSB).

Then, with the agent kit in pi:
1. **Golden output for each test case:** run the **original** XQuery of the flow on each `input.payload` (the
   osb-to-camel skill's golden test) and save the result as `expected-output.xml` next to it. The logs do not contain
   the output; the original transform is the reference.
2. **Unit tests:** copy `work/fixtures/parity` and `golden/MANIFEST.csv` into the Camel module's `src/test/resources`,
   then run `/osb-test`. The tester writes the unit tests with these recorded inputs.
3. **Optional, end-to-end:** if Docker is available, replay the test cases on the mock architecture (`README.md`,
   "E2E replay").

Shortcut for steps 1, 2, 4 and 6 in one go, once you have `events.csv`:

```bash
SPLUNK_INDEX=<index> SPLUNK_SOURCETYPE=<sourcetype> ./run_offline.sh osb-src work/events.csv work
```

## What to send back after the pilot

- `coverage.json` and `scenarios.json`;
- the list of gaps and the decisions taken;
- the number of test cases produced per scenario;
- whether the payload line was available, and in which environment.

That decides whether the method scales to the other flows as it is, or needs debug logging switched on first.
