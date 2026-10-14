# From Splunk logs to test cases — end to end, one flow

Pilot: project `beneficiary-engagement-change-prj`, proxy `maintain-adjustment`, topic `contributorAgreementTopic`.
Other flows: replace the three names. Everything below runs on the VDI. Never send CSVs, payloads or screenshots of them; only the files listed in step 6.

| Where | What you need |
|---|---|
| Splunk | read access to `ameen_e2e` (E2E) — `ameen_ann_e2e` (Dev) runs other code, don't use it for test data |
| VDI | Python 3, Git, this repo at `~/Projects` (`git clone git@github.com:PawelWaj/Projects.git ~/Projects`, later `git pull`) |
| Optional | Docker or Podman for the replay (step 5) |

Folders used below: `~/work/osb-migration/work/maintain-adjustment/`.

---

## Step 1 — check the flow in Splunk (counts only, 5 minutes)

Paste each block as ONE search. Time picker does not matter: `earliest=` inside the search wins.

**1a. The flow logs payloads, and how many**
```
index=ameen_e2e sourcetype="gosi:ameen:osb:log" earliest=-28d "beneficiary-engagement-change-prj"
| rex "for PS (?<proxy>\S+)"
| eval payload=case(match(_raw, "::\s*\{"), "json", match(_raw, "::\s*<"), "xml", true(), "none")
| stats count by proxy, payload
```
Expect `maintain-adjustment | json | ~800`. If `payload=none`: this flow logs no payload → stop, ask for OSB message tracing.

**1b. Events are complete (not cut by Splunk)**
```
index=ameen_e2e sourcetype="gosi:ameen:osb:log" earliest=-28d "beneficiary-engagement-change-prj" "::{"
| eval size=len(_raw), complete=if(match(_raw, "\}\s*$"), "yes", "no")
| stats count max(size) as max_bytes by complete
```
All `complete=yes` and `max_bytes` well below 10000. Otherwise ask the Splunk admin for the sourcetype's `TRUNCATE`.

**1c. Scenarios (what the tests must cover)**
```
index=ameen_e2e sourcetype="gosi:ameen:osb:log" earliest=-28d "beneficiary-engagement-change-prj" "::{"
| dedup _raw
| rex "::(?<payload>\{.*)$"
| spath input=payload path=data.businessTransaction output=business_transaction
| spath input=payload path=data.approvedOrRejected output=decision
| stats count by business_transaction, decision
| sort - count
```
Keep this table: it is the scenario list; step 4 must show the same scenarios.

**1d. Duplicate lines**
```
index=ameen_e2e sourcetype="gosi:ameen:osb:log" earliest=-7d "for PS maintain-adjustment"
| rex "TraceID - (?<trace>[0-9a-fA-F-]{36})"
| eval rawhash=md5(_raw)
| stats count as lines dc(rawhash) as distinct_raw dc(source) as sources by trace
| where lines>1
| stats count by distinct_raw, sources
```
`distinct_raw=1` = the same line stored twice (the export removes it with `dedup _raw`). `distinct_raw=2` = OSB processed the message twice: tell Paweł (redelivery = error-path test).

---

## Step 2 — export (contains personal data: VDI only)

```
index=ameen_e2e sourcetype="gosi:ameen:osb:log" earliest=-28d@d "beneficiary-engagement-change-prj" ("::{" OR "::<")
| dedup _raw
| sort 0 _time
| table _time _raw
```
1. Run it, then **Export** (arrow icon) → format **CSV** → number of results **Unlimited** → file name `events.csv`.
2. Move it to `~/work/osb-migration/work/maintain-adjustment/events.csv`.
3. Check: the first line is `"_time","_raw"`, and the row count matches 1a (minus duplicates).
   ```
   head -c 300 ~/work/osb-migration/work/maintain-adjustment/events.csv; echo
   python3 -c "import csv,sys; csv.field_size_limit(2**31-1); print(sum(1 for _ in csv.DictReader(open(sys.argv[1], encoding='utf-8-sig'))), 'events')" ~/work/osb-migration/work/maintain-adjustment/events.csv
   ```
   If the CSV is too big for the export: run step 2 per week (`earliest=-28d@d latest=-21d@d`, …) and combine (`tail -n +2` for files 2–4).

---

## Step 3 — anonymise and build the test cases (one command)

```
cd ~/work/osb-migration
export MASK_KEY='<key>'     # trial: any value; real runs: the key from the GOSI data owner, never in a file
export SCENARIO_DIMS='hdr_resource,body:data.businessTransaction,body:data.approvedOrRejected'
export PER_SCENARIO=5       # real inputs kept per scenario
~/Projects/P1/vdi-osb-migration/bin/task1_log_only.sh work/maintain-adjustment/events.csv work/maintain-adjustment/task1
```

What it prints, in order:

| Output line | Meaning | Must be |
|---|---|---|
| `== 1 anonymise … residue findings 0` | names, IDs, birth dates, passport numbers masked; same value → same mask everywhere | `residue findings 0` |
| `== 2 signature … matches_in_file N/N` | the log pattern learnt from the first line | N/N (all lines match) |
| `== 3 traces … K scenarios` | one trace per message, grouped by resource × businessTransaction × decision | K = rows of 1c |
| `== 4 … fixtures written` + `0 findings` | test cases written; second residue check on the test files | `0 findings` |
| `Scenarios:` list | count per scenario | same as 1c |

---

## Step 4 — check the result

```
cd ~/work/osb-migration/work/maintain-adjustment/task1
python3 -c "import json; r=json.load(open('events.masked.csv.report.json')); print('residue', r['residue_check']['findings']); [print(k, v) for k, v in sorted(r['key_inventory'].items()) if not v.get('masked')]"
ls fixtures/parity/*/
```
1. `residue 0`.
2. The printed list = JSON fields NOT masked by name. Numbers with 9+ digits are masked anyway, whatever the field. Any other field that could identify a person (name, short ID, date, address, free text)? Add it and rerun step 3:
   ```
   export EXTRA_MASK_ARGS='--mask-json-key <field1> --mask-json-key <field2>'
   ```
3. One folder per scenario under `fixtures/parity/<flow>/`, each with up to 5 cases: `input.payload` (masked JSON), `headers.json`, `expected.json`.
4. Open ONE `input.payload`: names must read `masked_…`, numbers must differ from the real ones you saw in Splunk.
5. Then delete the raw export: `rm ../events.csv` (rerun from Splunk if ever needed).

---

## Step 5 — replay through the mocks (optional, needs Docker/Podman)

```
~/Projects/P1/vdi-osb-migration/bin/task1_log_only.sh work/maintain-adjustment/events.csv work/maintain-adjustment/task1 --replay
```
Starts Artemis + WireMock + a stand-in flow, sends every case, writes `task1/report/report.json` (PASS/FAIL per case). This proves the mock environment and the test cases, not the migration: the stand-in only forwards valid JSON.
Stop afterwards: `cd ~/Projects/P1/osb-log-replay/mock && docker compose down -v`.

---

## Step 6 — send back (no data inside these files)

- table 1a, 1c, 1d (counts)
- `task1/events.masked.csv.report.json` (incl. its `payloads` block: how many payloads are strict JSON, before and after masking)
- `task1/traces/scenarios.json`
- `task1/report/report.json` (if step 5 ran)
- fields you added to the masking
- any error message

---

## Step 7 — with the OSB source (Task 2, next)

Test inputs alone are not a test: the expected output and the mocks come from the OSB code.
1. OSB project `beneficiary-engagement-change-prj` from the OSB repository, **the version deployed in E2E**, into `~/work/osb-migration/osb-src/beneficiary-engagement-change-prj/`.
2. `bash ~/Projects/P1/vdi-osb-migration/bin/preflight_vdi.sh`
3. Same `MASK_KEY` and `SCENARIO_DIMS` exported, then:
   ```
   ~/Projects/P1/vdi-osb-migration/bin/start_flow.sh osb-src/beneficiary-engagement-change-prj maintain-adjustment modules/maintain-adjustment work/maintain-adjustment/task1/events.masked.csv
   ```
   Gives the flow card (selector, branches, backends, error handler), the real replay config, and the expected outputs from the original XQuery. Stops at "card not approved": don't approve yet (templates are being switched to Camel K YAML).

What the logs cannot give (known for this flow): backend responses and error cases — only REQUEST lines are logged. Those come from the OSB source (WSDL/XSD, error handler) until GOSI enables message tracing in E2E.

---

## If something stops

| Message | Do |
|---|---|
| `export MASK_KEY=<key> first` | `export MASK_KEY=…` |
| `residue found` | open `events.masked.csv.report.json`, add the listed field with `--mask-json-key`, rerun |
| `matches_in_file` 1/N, no `body` in `groups` | payload not recognised: update the repo (fixed 2026-10-14); then send the `payloads` block of the report |
| `matches_in_file` below N/N (but more than 1) | lines of another format in the export; send the count, try `EXAMPLE_LINE=2` |
| warning `payload is json-lenient` / `json-trailing` / `unparsed` | OSB logged JSON that is not strictly valid (raw tabs/newlines, text after `}`, or cut off). Tests still build; send the `payloads` block of the report: Camel's JSON parser must be configured to accept the same input |
| `cannot derive the flow id` | `FLOW=beneficiary-engagement-change-prj/maintain-adjustment` before the command |
| 1 scenario only | `SCENARIO_DIMS` not exported in this shell |
| `_csv.Error: field larger than field limit` | old repo version: `git pull`, or download the ZIP again (fixed 2026-10-14) |
| Docker errors in step 5 | skip step 5; replay can run on a Jenkins agent with Docker |
