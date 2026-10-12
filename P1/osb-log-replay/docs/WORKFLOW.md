# From OSB logs to tests: the method

The goal: test cases for each migrated Camel flow that come from what OSB really processed in production, not from what
someone thinks it processed. Logs are the evidence; the OSB source tells you how to read them.

```
 OSB source ──► 1 log signatures ──► 2 Splunk searches ──► 3 traces + scenarios ──► 4 fixtures ──► 5 tests
 (.pipeline)     what each Log        anchors + rex           group by correlation     per scenario,     unit (agent) ·
                 action writes                                 id, classify, mask       MANIFEST          golden (original
                                                                                                          XQuery) · e2e replay
```

## 1. Read the logging contract from the source first

Start in the OSB export, not in Splunk. Every **Log action** in a pipeline is an XQuery expression, almost always an
`fn:concat` of fixed text and variables:

```xquery
fn:concat("Request Received to Project order-event-prj :: ... TraceID - ", $uuId, " ::", $body)
```

`tools/osb_log_signatures.py` turns each one into a **signature**:
- **a regex** with one named group per variable part;
- **the longest fixed text** as the search anchor;
- **the role of each group:**

| Group comes from | Name | Role |
|---|---|---|
| `$uuId`, `$traceId`, `$messageID` … | `uuId` | correlation id: groups lines into one trace |
| `$inbound/.../user-header[@name="resource"]/@value` | `hdr_resource` | JMS/transport header: becomes a test header and a scenario dimension |
| `$body` | `body` | the request payload: becomes the test input |
| `$body//*:referenceNo/text()` | `body_referenceNo` | business key: helps pick and check cases |
| `$fault` / `fn-bea:serialize($fault)` | `fault` | error path: fault code and reason |

What the source tells you before you search anything:

- **Which lines can exist at all.**
  - A flow with no Log action that writes the correlation id cannot be traced.
  - A flow that never logs `$body` gives you no inputs.
- **Log levels.** A `debug` Log action only writes if the OSB logging level for that service allows it. In production
  it usually does not, and the payload line is very often the debug one. The extractor warns about this.
- **Where the line is written.**
  - OSB Log actions go to the WebLogic server log (and its diagnostic log): one event per action, with the OSB text
    after the WebLogic header.
  - Other OSB sources exist; check which ones are switched on:
    - **Report actions** go to the reporting data stream (JMS reporting provider, reporting tables) and often hold the full message with report keys.
    - **Pipeline alerts** go to alert destinations.
    - **Message tracing** writes full messages when enabled on a service.
- **What is never logged.** The message OSB sends to the backend or queue is usually not logged, and neither is a
  message rejected by the proxy's JMS selector (it never reaches the pipeline). The first needs another oracle; the
  second needs tests from the proxy configuration.

## 2. Find the lines in Splunk

`tools/spl_from_signatures.py` writes:
- one search per signature: anchor plus `rex` with the same fields;
- one **trace search** per flow that groups all its lines by correlation id.

Before trusting a search:

- **Ask the Splunk owner for the index and sourcetype** of the OSB servers' logs. They are rarely the defaults.
- **Check event breaking.** WebLogic events start with `####<` and can span many lines (pretty-printed payloads). If
  the sourcetype breaks on newlines, a payload arrives as many events and `rex` sees only the first line. Look at one
  event with a multi-line body before exporting.
- **Check truncation.** Long events are cut at the sourcetype's truncation limit; a truncated payload is not a valid
  test input. The trace builder keeps such inputs, but they fail when parsed: look at `has_payload`, and treat
  unparseable bodies as an extraction problem, not a test case.
- **Pick a time range that covers a business cycle** (month end, batch days), not just the last hour.
- **Export only `_raw` and `_time`**, via `tools/splunk_export.py` (REST, token from the environment) or a CSV
  export from the UI.

## 3. Rebuild traces and scenarios

`tools/osb_log_traces.py`:
1. takes the OSB text out of its envelope. Two formats: the classic WebLogic server log (`####<…> <BEA-000000> <…>`) and the
   OSB 12c **ODL** diagnostic log (`[time] [server] [LEVEL] … [ecid: …] [FlowId: …]  [stage, pipeline, REQUEST] text`). From ODL
   it also keeps the `ecid`, which ties all lines of one OSB request together, used when the text has no trace id;
2. matches the signatures (the most specific match wins);
3. **masks personal data deterministically**, including JSON fields with names, birth dates and identity numbers (add
   client-specific fields with `--mask-json-key`): the same input gives the same masked value, so masked keys still join
   across lines;
4. groups by correlation id and classifies each trace:
   - **outcome:** `error` if any error-pipeline line exists, else `success`;
   - **branch:** header values such as `resource` and `eventType`, or any `--dims`;
   - **fault code** (`BEA-38xxxx` and friends) for errors.

Read `coverage.json` before going further:

| Field | Meaning | Action |
|---|---|---|
| `signatures_never_seen` | Log actions with no line in the time range | Wrong index/time range, level filtered, or a branch that never runs; ask before writing tests for it |
| `traces_without_payload` | Traces where the payload line is missing | Usually debug logging off; see "When logs are not enough" |
| `events_without_correlation` | Matched lines with no correlation value | The pipeline assigns the id after this log action; fix by reading the stage order |
| `events_unmatched` | Lines from other sources | Normal; a high count with few matches means the anchors are wrong |

`scenarios.json` lists scenarios by frequency. The top few usually cover most of the traffic; the rare ones (error
codes, unusual branches) are where migrations break.

## 4. Write fixtures

`tools/fixtures_from_traces.py` takes up to N traces per scenario (with a payload) and writes `input.payload`,
`headers.json` and `expected.json`. Every file is registered in `golden/MANIFEST.csv` with source `osb-recording`,
the provenance gate G7 of the agent kit accepts.

`expected.json` holds what the logs prove: the outcome, the destination of that outcome, the fault code, the headers
the error path must carry, and the business keys. It does **not** hold the output body, because OSB rarely logs it.

## 5. Build the tests in three layers

| Layer | From | Proves | Runs |
|---|---|---|---|
| **Unit** (the base, written by the agent's tester role) | the flow card's test matrix, the fixture inputs | every branch and error path of the route with all backends mocked | every build |
| **Golden** | fixture inputs run through the **original** XQuery/XSLT (Saxon + fn-bea shim) | the migrated transform produces what OSB produced, quirks included | every build |
| **E2E replay** | fixtures, against the mock architecture | broker filter, routing, error queue headers, end-to-end shape with the real Camel flow | per change of the flow |

Then the shadow run in a real environment (see the agent kit's TESTING.md) closes the loop on live traffic.

The oracle rule: an expected value comes from OSB (logs, recorded messages, the original transform), never from
running the new Camel code.

## The mock architecture (E2E replay)

```
 replay_runner ──publish──► Artemis: orderEventsTopic ──filter──► order-event-sub ──► Camel flow under test ──► InboundOrderEventQueue
      ▲                                (multicast)                 (durable, FQQN)       (Camel K or Spring Boot) └──► orderEventErrorQueue
      └──────────────────────────── waits for the same correlation id on the output queues ◄──────────────────────┘
                                                        WireMock: HTTP/SOAP backends the flow calls
```

- `mock/setup_broker.sh` creates the broker objects from `replay-config.json`:
  - the input address;
  - the subscription queue, with **the proxy's JMS selector as its broker-side filter**;
  - the output queues.

  The filter is part of what is tested.
- The flow under test runs from its own image (`SUT_IMAGE`) against the mock broker and WireMock.
- Negative cases (messages the selector must drop) come from `replay-config.json`, because OSB never logged them.
- `sut-stub` is a forwarding stub that proves the harness before the real flow exists.

## When logs are not enough

| Gap | Option, cheapest first |
|---|---|
| Payload line is debug and off in production | Enable debug logging for the specific services in a test environment with production-like traffic; or use the Report action / message tracing if already enabled |
| Output body not logged | Golden tests with the original XQuery (preferred); a non-exclusive copy (divert) of the OSB output queue during the shadow run |
| Payloads truncated or split | Fix the sourcetype's event breaking for these sources, or read the WebLogic log files directly (the trace builder reads raw logs) |
| No correlation id in the log text | Add it to the first Log action in a test environment, or correlate by business key (`body_*` fields) with a time window |
| Personal data | Mask at extraction (the trace builder does), review a sample before fixtures leave the secure environment |
