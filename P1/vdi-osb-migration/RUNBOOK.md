# VDI runbook: one OSB flow from source + Splunk log to a verified Camel module, with the pi agent

Inputs you always have: the **OSB project source** (sbconfig export unzipped, or the JDeveloper project folder) and a
**Splunk CSV** of the flow's log lines (`_time,_raw`). Everything below runs on the VDI; nothing unmasked leaves it.
Deterministic steps run as scripts; the agent (pi) only does the four role steps, each in a fresh process.

```
OSB source ──► 1 inventory + card ──► 2 log signatures + Splunk queries
Splunk CSV ──► 3 traces (keyed masking, residue check) ──► 4 replay-config draft + fixtures ──► 5 golden oracle (ORACLE.lock)
           ──► 6 pi analyst → GATE A (you approve the card) ──► 7 pi tester → implementer → gates G1-G10 → reviewer → GATE B
```

## Map: how the parts fit together

**Two kinds of directories.** The repository holds code only; the workspace holds the data of each flow. Nothing from
the workspace goes into the public repository.

```
REPOSITORY  ~/Projects/P1  (git pull; or paste-installed into the workspace root with bootstrap 1-7)
├── skills/osb-camel-agent-kit/     the agent kit
│   ├── agents/*.md                 role prompts: analyst, tester, implementer, reviewer
│   ├── pi/run_flow.sh, pi/prompts  pi runner (one process per role) and the /osb-* commands
│   ├── tools/                      gates: verify_flow.sh (G1-G10), check_matrix, check_oracle, golden_runner, mutate_transforms, compare_shadow
│   ├── skills/osb-to-camel/        the skill: scripts/osb_inventory.py + scaffold_flow.py, references (mapping tables),
│   │                               assets/templates (route, tests, interface mocks, fn-bea shim)
│   └── bootstrap/1..7_install_*.sh paste-install for a VDI without file transfer
├── osb-log-replay/                 Splunk logs -> masked test cases: tools/ (signatures, queries, traces, fixtures, residue check,
│                                   replay runner), mock/ (Artemis + WireMock compose stack for L3), docs/
└── vdi-osb-migration/              THIS workflow: bin/start_flow.sh (calls the two above in order), preflight, replay-config generator

WORKSPACE  ~/work/osb-migration  (one per engineer; run every command from here)
├── osb-src/<project>/              INPUT 1: the OSB export (sbconfig.jar unzipped, or the JDeveloper project)
├── work/<flow>/                    INPUT 2 + derived: events.csv (Splunk CSV), signatures.json, queries.spl, traces/, fixtures/
├── migration/osb-inventory/        INVENTORY.md, flows/<project>__...__<flow>.json       (step 1)
├── migration/<flow>/               FLOW_CARD.md, test-matrix.json, verify-report.json, REVIEW.md, MIGRATION_RECORD.md, agent-logs/
├── modules/<flow>/                 OUTPUT: the Camel module. src/test first (tests + resources/parity, golden/MANIFEST.csv,
│                                   golden/ORACLE.lock, fixtures/<flow>/backend stubs), src/main after
└── replay-config.json              target broker names per flow (only for the L3 replay)
```

**The process, with what each step reads and writes**

| # | Step | Tool (repository) | Reads | Writes (workspace) | Mock involved |
|---|---|---|---|---|---|
| 1 | Inventory + flow card | `skill/scripts/osb_inventory.py`, `scaffold_flow.py` | `osb-src/<project>` | `migration/osb-inventory/`, `migration/<flow>/FLOW_CARD.md`, `test-matrix.json` | none; the card lists every interface that will be mocked |
| 2 | Log signatures + Splunk searches | `osb-log-replay/tools/osb_log_signatures.py`, `spl_from_signatures.py` | the Log actions in `osb-src` | `work/<flow>/signatures.json`, `queries.spl` | none |
| 3 | Traces, keyed masking, residue check | `osb_log_traces.py`, `mask_residue_check.py` | `work/<flow>/events.csv` + `MASK_KEY` | `work/<flow>/traces/` | none (raw CSV deleted afterwards) |
| 4 | Replay-config draft + fixtures | `vdi/bin/replay_config_from_inventory.py`, `fixtures_from_traces.py` | `flows/<flow>.json`, `traces.jsonl` | `replay-config.json`, `modules/<flow>/src/test/resources/parity/**` (input.payload, headers.json, expected.json), `golden/MANIFEST.csv` | the recorded inputs every mock level replays |
| 5 | Golden oracle | `kit/tools/golden_runner.py` + the skill's `fn-bea-shim.xqy` | the ORIGINAL `.xqy`/`.xsl` from `osb-src`, `parity/**/input.payload` | `parity/**/expected-output.xml`, `golden/ORACLE.lock` | none: this is the reference the mocks are judged against |
| 6 | pi analyst → gate A | `kit/pi/run_flow.sh` (role analyst) | export, inventory | `FLOW_CARD.md` completed; **you approve it** | — |
| 7a | pi tester | role tester + `skill/assets/templates/java/*Test*.java` | the approved card, `parity/**`, `.bix`/WSDL | `modules/<flow>/src/test/**`: route test (**L1 mocks**), golden test, contract test (**WireMock**), broker IT (**Testcontainers**), recorded-cases test; WireMock stubs under `src/test/resources/fixtures/<flow>/backend/` | **the mocks are written here, before any route exists** |
| 7b | pi implementer | role implementer + `skill/assets/templates/java/OsbRouteTemplate.java` | the card, the tests | `modules/<flow>/src/main/**` | the route must satisfy the mocks |
| 7c | gates | `kit/tools/verify_flow.sh` | module | `migration/<flow>/verify-report.json` | G4 runs L1 (Maven only), G5 runs L2 (containers), G10 checks the oracle lock |
| 7d | pi reviewer → gate B | role reviewer | everything above | `REVIEW.md`, `MIGRATION_RECORD.md`; **a second engineer signs** | — |
| 8 | Optional end-to-end replay (L3) | `osb-log-replay/mock/docker-compose.yml`, `replay_runner.py` | `replay-config.json`, `parity/**`, the built image | `work/report/` | **the whole environment is a mock**: Artemis + WireMock + the image |

**Where the mocks live, by level**

| Level | What is real | What stands in | Where it is | Needs |
|---|---|---|---|---|
| L1 unit (gate G4) | the Camel route and its transforms | input `direct:in`, outputs `mock:success`/`mock:error`, backends `mock:backend` (AdviceWith) | `modules/<flow>/src/test/java/*RouteTest.java`, `*GoldenTest.java`, `RecordedCasesRouteTest` | Maven only |
| L2 component (gate G5) | route + a real Artemis + a real WireMock, both as throwaway containers | backend replies, faults, delays (WireMock stubs); the selector as a broker-side filter | `*BackendContractTest.java`, `*IT.java`; stubs in `src/test/resources/fixtures/<flow>/backend/`, replies from the response-stage log or the WSDL | Docker or Podman |
| L3 replay (gate G9, optional) | the built image, as deployed | Artemis + WireMock + the replay runner | `osb-log-replay/mock/`, `replay-config.json` | Docker Compose + the image |
| Other interfaces (DB, DVM, Java callout, file/SFTP, email, security) | — | templates `DatabaseMockTestTemplate`, `DvmLookup`, `JavaCalloutMockTestTemplate`, `FileSftpMockTestTemplate`, `EmailMockTestTemplate`, `SecurityMockTestTemplate` | `skill/assets/templates/java/`, support files in `assets/templates/mocks/` | per template |

**So "start testing" means:** after step 7a the tests exist and fail (no route); after 7b `mvn -q -f modules/<flow>/pom.xml verify`
runs L1 + L2 against the mocks; `tools/verify_flow.sh modules/<flow> <flow>` turns that into the gate report. Nothing
outside the workspace is contacted at any point.

## 0. One-time setup

| Git checkout | Paste install (no file transfer) |
|---|---|
| `git clone git@github.com:PawelWaj/Projects.git ~/Projects && cd ~/Projects/P1` then work in a workspace folder, e.g. `mkdir -p ~/work/osb-migration && cd ~/work/osb-migration`; scripts find the kit and tools in the repo automatically (`KIT`, `REPLAY` can override) | In the workspace root paste and run `bootstrap/1_…7_install_*.sh` from `skills/osb-camel-agent-kit/bootstrap/` in order; the kit lands in the workspace root, the skills in `.pi/skills`, the log tools in `log-replay/`, this workflow in `bin/` |

Then:

```bash
bash bin/preflight_vdi.sh          # 0 blocking gaps expected; WARN lines tell you which gate they affect
pi --approve                       # trust the project once so .pi/prompts and .pi/skills are loaded; "/" must list /osb-*
export MASK_KEY='<key from the data owner>'      # only when you process a Splunk CSV; never write it to a file
export SPLUNK_INDEX=<index> SPLUNK_SOURCETYPE=<sourcetype>   # optional, used in the generated searches
```

Needed on the VDI: Python 3, JDK 21, Maven with the internal mirror, Docker or Podman (otherwise gate G5 and the L3
replay report NOT_RUN), pi with the gateway, a Saxon-HE jar in `~/.m2` (`mvn dependency:get -Dartifact=net.sf.saxon:Saxon-HE:12.9`).

## 0a. Anonymise the Splunk export first (before anything else touches it)

Needs only the CSV and the key; no OSB source. Everything after this step works on the masked file.

```bash
export MASK_KEY='<key from the data owner>'          # never written to a file
python3 ~/Projects/P1/osb-log-replay/tools/anonymize_logs.py work/<flow>/events.csv -o work/<flow>/events.masked.csv
#  -> work/<flow>/events.masked.csv            same columns, personal values replaced
#  -> work/<flow>/events.masked.csv.report.json  counts, key id, residue result, key inventory (no values)
```

1. The command must end with `residue findings 0` (exit 0). Otherwise it lists `file:line: check` (never a value).
2. Open the report's `key_inventory`. Every key with `masked: false` that could identify a person (a short ID, a name,
   a date, an address, free text) is added and the command rerun:
   `--mask-json-key <exactKey>` or `--mask-key-pattern '<regex>'`. Numbers with 9+ digits are always masked.
3. The data owner's reviewer checks a sample of `events.masked.csv` and signs off.
4. Delete the raw file: rerun with `--delete-input` or `rm work/<flow>/events.csv`.
5. Use the masked file from now on: `bin/start_flow.sh … work/<flow>/events.masked.csv`. It sees the report next to it
   and does not mask a second time (`--already-masked`).

## 1. Run a flow

```bash
# A. without logs yet: inventory, card, signatures and the Splunk searches to hand to the Splunk owner
bin/start_flow.sh osb-src/<project> <proxy-name> modules/<proxy-name>
#    -> migration/osb-inventory/, migration/<flow>/FLOW_CARD.md (draft), work/<flow>/queries.spl

# B. with the Splunk CSV: masked test cases, fixtures, golden oracle, then the agent steps up to gate A
export MASK_KEY='…'
bin/start_flow.sh osb-src/<project> <proxy-name> modules/<proxy-name> work/<flow>/events.csv [--transform <orig.xqy>]

# C. approve the card: set "| **Status** | approved" + your name in migration/<flow>/FLOW_CARD.md, then
bin/start_flow.sh osb-src/<project> <proxy-name> modules/<proxy-name> --from pi-test
#    -> tests first (fail for the right reason), route, gates with up to 3 fix loops, review -> gate B (you)
```

`--from <step>` resumes at `inventory | signatures | traces | fixtures | golden | pi | pi-test`.
`DELETE_INPUT=1` removes the raw CSV after masking (do this on the VDI once the residue check is clean).

## 2. What each step produces and what you check

| Step | Output | Check before going on |
|---|---|---|
| 1 inventory + card | `migration/osb-inventory/INVENTORY.md`, `flows/*.json`; `migration/<flow>/FLOW_CARD.md`, `test-matrix.json` | "Referenced but missing from the export" list is empty or each item is requested from the OSB owner |
| 2 signatures | `work/<flow>/signatures.json`, `queries.spl` | The EXPORT search names the right project; run the coverage search first (counts per resource/name) |
| 3 traces | `work/<flow>/traces/{traces.jsonl,scenarios.json,coverage.json}` | `events_matched > 0`; `masking.keyed: true`; residue check `0 findings`; every branch of the card has a scenario, or note "no traffic in window" |
| 4 fixtures | `replay-config.json` (flow entry drafted, `_todo` items), `modules/<flow>/src/test/resources/parity/…`, `golden/MANIFEST.csv` (sha256, key_id) | Resolve the `_todo` items (target broker names, error headers) before any L3 replay; the manifest source of every file is `osb-recording` |
| 5 golden oracle | `parity/**/expected-output.xml`, `golden/ORACLE.lock`, manifest rows `original-transform` | `oracle-blocked` entries (JSON input before nXSD, unshimmed fn-bea function, unbound variable) go to the OSB Test Console, source `osb-test-console`; **never hand-write an expected file** |
| 6 analyst | `FLOW_CARD.md` completed, status draft | You read it against the OSB console/export and approve it (gate A) |
| 7 tester → implementer → verify → reviewer | `src/test` (before `src/main`), `src/main`, `migration/<flow>/verify-report.json` (G1–G10), `REVIEW.md`, `MIGRATION_RECORD.md` | All gates PASS or NOT_APPLICABLE; NOT_RUN (no Docker) is not green: run `tools/verify_flow.sh` on Jenkins; no BLOCKER in the review; a second engineer signs gate B |

## 3. Masking (step 3) in one minute

- The key: generated and held by the data owner, exported as `MASK_KEY` at run time only. Same key → same masked
  value across flows and extracts (reusable test data); different key → different values; no key → not reversible.
- What is masked: JSON fields and XML elements whose name matches the personal-data rules (names incl. Arabic/English
  variants, address/remarks/notes, birth dates, e-mail/phone/mobile, NIN/iqama/passport/national id/social insurance
  no/IBAN/account), plus digit runs of 9+, e-mails and Saudi IBANs in free text. Names → `masked_<hex>`, identifiers →
  same length, birth dates → shifted ≤183 days, e-mails → `@example.invalid`.
- Add a field the rules miss: `--mask-json-key <exact>` or `--mask-key-pattern '<regex>'` on `osb_log_traces.py`
  (the orchestrator passes extra args through `EXTRA_MASK_ARGS`, see `bin/start_flow.sh`), rerun `--from traces`.
- `log-replay/tools/mask_residue_check.py <dir>` prints file, line and check name only, never a value; it must report
  `0 findings` before anything leaves the VDI. Digit identifiers cannot be judged by the scan: the reviewer's sample
  covers them.

## 4. Gates (tools/verify_flow.sh)

G1 build · G2 endpoint URIs · G3 no hosts/secrets · G4 unit/route/golden/contract tests · G5 container tests
(NOT_RUN without Docker, never green) · G6 every test-matrix row has a test · G7 every expected file has an OSB
source (`osb-recording`, `original-transform`, `osb-test-console`; `card-rule` and `source-derived` need reason +
approver) · G8 mutation of transforms · G10 golden outputs unchanged since the runner (`ORACLE.lock`).

## 5. If something stops

| Symptom | Do |
|---|---|
| `flow '<name>' not in migration/osb-inventory/flows` | Use the proxy service name as in the export (`ls migration/osb-inventory/flows`) |
| `no event matched a signature` | Wrong project or CSV; check one raw line is ODL and contains the project/pipeline name |
| residue check finding | Add the reported key with `--mask-json-key`/`--mask-key-pattern`, rerun `--from traces` |
| `more than one (or no) transform in the flow` | Pass `--transform <the XQuery/XSLT that builds the outbound body>` (named on the card) |
| `oracle-blocked` | JSON/nXSD input or unshimmed function: OSB Test Console run, store the file with source `osb-test-console` + reason + approver in MANIFEST |
| `STOP: FLOW_CARD.md is not approved` | Gate A: review, set Status approved + your name, rerun `--from pi-test` |
| `VIOLATION: implementer changed src/test` | The agent broke its lane; restart `--from pi-test` with a fresh tester |
| G5 NOT_RUN | No container runtime for Testcontainers: run `tools/verify_flow.sh modules/<flow> <flow>` on a Jenkins agent with Docker |
| G10 FAIL | An `expected-output.xml` changed after the runner (or was never locked): rerun `tools/golden_runner.py run …`, never edit by hand |
| pi does not list `/osb-*` | `cp pi/prompts/*.md .pi/prompts/` (git layout: `<kit>/pi/prompts`), then `/reload`; trust the project |

## 6. Definition of done per flow

- [ ] Card approved by a named engineer (gate A); every matrix row has a recorded case or a `source-derived` one with reason + approver.
- [ ] Residue check 0 findings; masked sample reviewed by the data owner's reviewer; raw CSV deleted.
- [ ] `verify-report.json`: all gates PASS/NOT_APPLICABLE; G5 run with Docker somewhere; G10 PASS.
- [ ] Review without BLOCKER; gate B signed by a second engineer; `MIGRATION_RECORD.md` lists deviations and the delivery-semantics delta.
- [ ] Time per step noted in `TRIAL_RESULTS_TEMPLATE.csv`.
