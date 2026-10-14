# All flows at once — from one Splunk export to test cases per flow

Same chain as [LOGS_END_TO_END.md](LOGS_END_TO_END.md), automated for every OSB flow in the export. Nothing to set per domain:
the log pattern, the scenario fields, the selector negatives and the fan-out partners are derived from the data.
VDI only; never send CSVs or payloads. Python 3.10+, works in Git Bash and PowerShell.

## 1 — which flows log payloads (Splunk, counts only)
```
index=ameen_e2e sourcetype="gosi:ameen:osb:log" earliest=-28d "oracle.osb.logging.pipeline"
| rex "Project (?<project>\S+) :: for PS (?<proxy>\S+)"
| eval payload=case(match(_raw, "::\s*\{"), "json", match(_raw, "::\s*<"), "xml", true(), "none")
| fillnull value="(other log text)" project proxy
| stats count by project, proxy, payload
| sort project, proxy
```
- `json` / `xml`: test inputs available.
- `none`: the flow logs no payload. Splunk gives scenarios and volumes only, so it needs OSB message tracing.
- `(other log text)`: a different Log text. The batch groups these by `[APP: …]`; check them in the summary.

## 2 — one export for all flows
Splunk UI (CSV, Unlimited). This keeps at most 500 messages per proxy, so the file stays manageable:
```
index=ameen_e2e sourcetype="gosi:ameen:osb:log" earliest=-28d@d "oracle.osb.logging.pipeline" ("::{" OR "::<")
| dedup _raw
| rex "for PS (?<proxy>\S+)"
| dedup 500 proxy
| sort 0 _time
| table _time _raw
```
`dedup 500 proxy` keeps the newest 500 per proxy, so rare scenarios older than those can be missed. For complete coverage drop that line and export per week. One domain only: add its project names, e.g. `("beneficiary-engagement-change-prj" OR "contributor-collection-prj")`.

Or, with a Splunk REST token (no UI export, same search):
```
export SPLUNK_TOKEN=<token>          # never in a file
python $P1/osb-log-replay/tools/splunk_export.py --url https://<splunk-host>:8089 --earliest -28d@d --latest now \
  --search '<the search above without the table line>' -o all.jsonl
```

## 3 — one command
```
export MASK_KEY='<key>'
python $P1/vdi-osb-migration/bin/batch_task1.py all.csv -o batch          # or all.jsonl
```
Per flow it prints `OK` / `CHECK` / `FAIL` with its scenarios and test cases. Output:

| File | What |
|---|---|
| `batch/SUMMARY.md`, `summary.csv` | one row per flow: events, lines matched, scenarios, test cases, residue, scenario fields, topic, problems |
| `batch/topics.json` | per flow: topic, resources it reads, selector negatives, fan-out partners (names only) |
| `batch/flows-found.csv` | template for step 4 |
| `batch/flows/<flow>/` | same layout as task 1: `fixtures/parity/**`, `TEST_CATALOG.md`, `dims.json`, `replay-config.json` |
| `batch/events.masked.csv.report.json` | masking report for the whole export (no values) |

## 4 — review and adjust (only where needed)
- **CHECK**: read the `problems` column. Typical causes: lines not matched (another log text), or a case folder problem.
- **Scenario fields**: `flows/<flow>/dims.json` shows the chosen fields and the candidates. A field is chosen when it is present in at least 90% of the messages, has 2–25 code-like values, is not masked, and business-code names come first. To change them:
  1. Copy `flows-found.csv` to `flows.csv`.
  2. Edit the `dims` column, e.g. `hdr_resource;body:data.businessTransaction;body:data.personType`.
  3. Rerun with `--flows flows.csv --already-masked`, using `batch/events.masked.csv` as input. This doesn't mask a second time.
- **Domains**: put the domain name in the `domain` column of `flows.csv` (default: the project name). `--flows` also limits the run to the listed flows.
- **Masking**: check `key_inventory` in the masking report; add a field with `--mask-json-key <field>` and rerun from step 3.

## 5 — send back (no data inside)
`SUMMARY.md`, `summary.csv`, `topics.json`, and `flows/*/TEST_CATALOG.md`.

Next per flow: Task 2 (OSB source → expected outputs, selector, backends), as in TASKS.md.
