#!/usr/bin/env bash
# Paste into the migration workspace root on the VDI and run: bash 1_install_agents.sh
# Agent layer: AGENTS.md, role prompts, pi runner, /osb-* prompt templates (kit + .pi/prompts). Existing files are overwritten.
set -euo pipefail
mkdir -p "$(dirname "AGENTS.md")"
cat > 'AGENTS.md' <<'KIT_EOF_AGENTS_MD'
# AGENTS.md: OSB → Camel migration repository (client programme)

Every AI agent working in this repository follows these rules. Role prompts in `agents/` add duties per phase.

## What this repository is

Camel K integrations (YAML DSL) that replace Oracle Service Bus flows: one module per OSB proxy under
`modules/<project>/<proxy>/` (route `*.camel.yaml` + helper beans + L1 tests). Source of truth for behaviour = the OSB export under `osb-src/` (read-only).

## Workflow (never skip a step)

1. **Check first:** search this repository for the proxy name, its queues/topics/URLs and XQuery file names. If a
   route already exists, compare and report; do not generate a second one.
2. **Research** with skill `osb-research` → `research/<project>/<proxy>/` (shareable pack, check PASS).
3. **Card + tests** with skill `osb-camelk-route` Step 1 → `modules/<project>/<proxy>/FLOW_CARD.md` + generated tests.
4. **Stop for approval.** No code for a card without `Status: approved` and an approver name.
5. **Implement and test** with `osb-camelk-route` Steps 3–5 (route, error tests, stubs).
6. **Verify:** `check_camelk.py modules/<project>/<proxy>` must print PASS (K1–K8).
7. **Record:** `modules/<project>/<proxy>/MIGRATION_NOTES.md` with the four sections: Original OSB behaviour / Camel
   implementation / Behavioural differences / Items requiring human validation.

## Hard rules

- Inputs are files from `osb-src/`. Never build code from screenshots, chat text or memory of "how OSB usually works".
- Runtime (decision 2026-10-14): **Camel K, routes in YAML DSL** (`*.camel.yaml`), Camel 4.18.4 = Camel Quarkus 3.33.3
  (`camel.runtime-version=3.33.3`), small Java helper beans next to the YAML, tests with `camel-test-main-junit5` +
  mock endpoints. Pattern: `pilot/sample-adjustment`, skill `osb-camelk-route`. Older Spring Boot templates in
  `osb-to-camel/assets` are reference only.
- Messaging: Red Hat AMQ Broker, AMQP 1.0 on port 5672, `camel-amqp` (Qpid JMS) with a failover URI. Destinations
  exist only through the Git register; never rely on auto-create. A WebLogic durable topic subscription becomes a
  named subscription queue with a broker-side filter, consumed by FQQN `<address>::<subscription>`.
- JMS: local transacted sessions; duplicate-ID header on every send; consumers idempotent.
- Every endpoint, queue name, timeout and retry value is a `{{placeholder}}`; no host names, ports or credentials in
  code, tests or `application.yml`. Credentials come from Vault at runtime.
- Keep original XQuery/XSLT files and their behaviour (quirks included) unless the card approves a change. Never
  rewrite a working transform into Java "because it is cleaner".
- Logging: stdout, correlation id in every line, no full payloads above DEBUG, mask personal data (SIN, national ID).
- Component options: Camel MCP if connected, else `skills/osb-to-camel/references/versions.md` + Camel docs for that
  version. Do not guess options.
- **Test oracle:** expected outputs come from OSB (recordings, the original transform run on Saxon, the OSB test
  console). Never generate an expected file by running the new Camel code.
- Never delete, skip or weaken a test to get green. A skipped test needs a reason in the record.
- Never claim equivalence. Report gate results and test evidence; humans decide.

## Commands

| Purpose | Command |
|---|---|
| Research pack (source stays, knowledge travels) | `pi/run_research.sh osb-src/<project> <proxy> [task1-dir]` → `research/<proxy>/` (shared only after `research_check.py` PASS) |
| All proxies of one OSB application | `pi/run_domain.sh <osb-app-dir> <stage>` (stages: list, research, scaffold, build, status) → `domain/STATUS.md` |
| Functional tests only (no route) | `pi/run_tests.sh research/<project>/<proxy> modules/<project>/<proxy> <project> [task1-dir]` |
| Research pack → Camel K module + tests | `pi/run_camelk.sh research/<project>/<proxy> modules/<project>/<proxy> <project> [task1-dir]` (stops until the card is approved) |
| Gates of a Camel K module | `python3 skills/osb-camelk-route/scripts/check_camelk.py modules/<project>/<proxy>` (K1-K8) |
| Inventory an export | `python3 skills/osb-to-camel/scripts/osb_inventory.py osb-src/<project> -o migration/osb-inventory` |
| Scaffold a card | `python3 skills/osb-to-camel/scripts/scaffold_flow.py migration/osb-inventory/flows/<flow>.json -o migration/<flow>/` |
| Build + tests | `mvn -q -f <module>/pom.xml verify` |
| All gates | `tools/verify_flow.sh <module> <flow>` |

## Definition of done (per flow)

Card approved · gates K1–K8 PASS in `GATES.json` · `MIGRATION_NOTES.md` written · reviewer report with no open BLOCKER ·
human sign-off · shadow run passed (TESTING.md L6) before cut-over.
KIT_EOF_AGENTS_MD
mkdir -p "$(dirname "README.md")"
cat > 'README.md' <<'KIT_EOF_README_MD'
# OSB → Camel agent kit (vendor-neutral)

**First time? Start with `TRIAL_GUIDE.md`** (install, the three trial stages, what to measure) and record results in `TRIAL_RESULTS_TEMPLATE.csv`.

A portable package to run the OSB-to-Camel migration on **the customer's AI agent system**, whatever it is. It uses
only open conventions:

| Piece | Format | Works with |
|---|---|---|
| `AGENTS.md` | plain markdown repo instructions | any agent that reads `AGENTS.md` or accepts a system prompt |
| `skills/*/SKILL.md` | open Agent Skills format (YAML front matter + markdown + scripts/references/assets) | agent systems that load skills; otherwise paste `SKILL.md` as context |
| `agents/*.md` | role prompts (plain markdown, no tool names) | any orchestrator: one agent per role, or one agent switching roles |
| `tools/*` | bash + Python 3, no AI | the **gates**: deterministic, runnable by CI, by a human, or by the agent |
| `ci/Jenkinsfile.groovy` | Jenkins stages | the same gates in the pipeline |

The AI does the repetitive work (reading XML, writing cards, code and tests). **The gates decide** whether the result
is acceptable. Nothing the agent says counts as evidence; only gate output does.

## The agentic pipeline

```
 OSB export ──► [1 ANALYST] ──► flow card ──► HUMAN APPROVAL ──► [2 IMPLEMENTER] ──► Camel module
   (files)        inventory,                     (gate A)            route, transforms,     │
                  triage, card                                       config, register       │
                                                                                            ▼
                 golden fixtures from OSB ──► [3 TESTER] ──► test suite  (writes tests from the CARD and the
                 (recordings, original                                    OSB fixtures, never from the code)
                  transform output)                                         │
                                                                            ▼
                                     tools/verify_flow.sh  ── gates G1..G8 ──► verify-report.json
                                                                            │  red → back to IMPLEMENTER (max 3 loops)
                                                                            ▼
                                     [4 REVIEWER] ──► MIGRATION_RECORD.md (evidence only) ──► HUMAN SIGN-OFF (gate B)
                                                                            │
                                                                            ▼
                                     E2E shadow run (TESTING.md L6) ──► cut-over per flow
```

`agents/orchestrator.md` describes the state machine, the hand-off files and the loop limits.

## Install on the customer system

On **pi** (pi.dev) follow `pi/PI_SETUP.md`; on the **client VDI** start with `pi/VDI_RUNBOOK.md` and `pi/preflight.sh`. Any other agent system:

1. Copy `skills/osb-to-camel/` and `skills/camel-migration-verification/` to wherever the agent system loads skills.
   If it cannot load skills, give the agent the `SKILL.md` text plus the folder on disk (scripts and references are
   read on demand).
2. Put `AGENTS.md` at the root of the **migration repository** (the Maven project that receives the Camel modules).
3. Create one agent per role from `agents/` (or one agent and switch prompts per phase). The tester and the reviewer
   must not share context with the implementer: independent oracle, see `TESTING.md` §3.
4. Copy `tools/` into the repository; add `ci/Jenkinsfile.groovy` stages to the pipeline.
5. Optional: connect a Camel MCP server if the platform has one; the skills fall back to pinned docs
   (`skills/osb-to-camel/references/versions.md`).

Requirements on the runner: Java 21, Maven 3.9, Python 3.10+, Docker or Podman for Testcontainers (Artemis), network
access to the Maven repository mirror. No access to production systems or credentials.

## Validate the agent system itself before the whole estate

Run the kit on a **calibration set** of 3 to 5 flows already migrated by hand (or reviewed line by line), one per tier.
Score per flow: card completeness, gates G1–G8 green, mutation score, reviewer findings, human minutes spent. Only
when the calibration flows pass without human code edits does batch mode start. `skills/osb-to-camel/evals/` holds
the skill's own eval cases.

## Files

| Path | Purpose |
|---|---|
| `AGENTS.md` | rules for every agent working in the migration repository |
| `agents/orchestrator.md` | phases, hand-offs, loop limits, stop conditions |
| `agents/analyst.md`, `implementer.md`, `tester.md`, `reviewer.md` | role prompts |
| `skills/osb-to-camel/` | knowledge + scripts: inventory, triage, card scaffold, mapping tables, templates |
| `skills/camel-migration-verification/` | how to test after generation; gate definitions; evidence pack |
| `tools/verify_flow.sh` | runs gates G1–G8 for one flow, writes `verify-report.json` |
| `tools/check_matrix.py` | G6: every test-matrix row of the card has a test |
| `tools/check_oracle.py` | G7: every golden fixture comes from OSB, not from Camel |
| `tools/mutate_transforms.py` | G8: deliberately breaks each transform; the tests must fail |
| `tools/pom-build-plugins.xml` | Maven plugins the gates rely on |
| `ci/Jenkinsfile.groovy` | the gates as pipeline stages |
| `pi/VDI_RUNBOOK.md` | client VDI: what to request, offline install, customer model endpoint, run, data hygiene |
| `pi/preflight.sh` | read-only check of node/pi/java/maven/python/docker/kit layout on the VDI |
| `pi/PI_SETUP.md` | install and run on the pi coding agent (interactive and agentic) |
| `pi/run_flow.sh` | agentic mode on pi: one fresh `pi -p` process per role, lane checks, gates, fix loops |
| `pi/prompts/*.md` | pi prompt templates `/osb-analyse`, `/osb-implement`, `/osb-test`, `/osb-verify`, `/osb-review`. Kit copy only: pi reads them from `.pi/prompts/` (trusted project) or `~/.pi/agent/prompts/`; the bootstrap copies them, preflight checks |
| `docs/OSB_Camel_Agent_Workflow.drawio` (+ PNG per page) | workflow diagram: page 1 agentic run on pi, page 2 inside the skills |
| `TESTING.md` | the test levels L0–L7 after generation, including shadow run and cut-over |
KIT_EOF_README_MD
mkdir -p "$(dirname "TESTING.md")"
cat > 'TESTING.md' <<'KIT_EOF_TESTING_MD'
# Testing generated Camel code: levels L0–L7, gates G1–G8

AI-generated code needs **AI-independent proof**. Three principles carry everything below:

1. **The oracle is OSB, not Camel.** Expected outputs come from OSB recordings, from the original XQuery/XSLT run on
   Saxon, or from the OSB test console. Never from running the generated code.
2. **The tests must be able to fail.** Each transform is deliberately broken (mutation); a suite that stays green
   against a mutant is not evidence.
3. **Gates are scripts, not opinions.** `tools/verify_flow.sh` produces `verify-report.json`; an agent's statement that
   "tests pass" is not accepted without it.

## 1. Levels

| Level | What | Where it runs | Tooling | Proves |
|---|---|---|---|---|
| **L0 Static** | compile, Camel endpoint URI validation, repository rules | build agent | `mvn package`, `camel-report:validate`, `verify_flow.sh` G3 | code builds; every endpoint URI and option exists in this Camel version; no hosts, secrets, Camel K |
| **L1 Route logic** | each branch, selector outcome, error path, header mapping | build agent | `@CamelSpringBootTest`, `AdviceWith`, `MockEndpoint` | the pipeline's logic, backends replaced by mocks |
| **L2 Transform golden** | each XQuery/XSLT / native-to-XML step | build agent | Saxon + `fn-bea` shim, XMLUnit (canonical, ignore list) | output equals what OSB produced for the same input, quirks included |
| **L3 Messaging integration** | real broker behaviour | build agent with Docker/Podman | Testcontainers, AMQ Broker image, AMQP 5672, register snippet loaded | filters, durable subscription via FQQN, transacted consume+send, redelivery count/interval, error queue headers, duplicate-ID |
| **L4 Backend contract** | what leaves for HTTP/SOAP backends, timeouts, retries | build agent | WireMock (SOAPAction + XPath matching, delays, faults) | requests in the expected shape; retry/timeout as the business service was configured |
| **L5 Parity replay** | recorded OSB traffic replayed | build agent | recorded pairs under `src/test/resources/parity/<flow>/`, WireMock replays backends | real messages give the same output |
| **L6 Shadow run** | Camel runs next to OSB on live E2E traffic, output diverted | E2E | second subscription + shadow destinations + `tools/compare_shadow.py` | no differences on real traffic over an agreed window |
| **L7 Cut-over and rollback** | switch one flow, prove rollback | UAT then PROD window | runbook per flow | the switch and the way back both work |

L0–L5 run on every commit (gates). L6–L7 run once per flow before cut-over.

## 2. Gates (`tools/verify_flow.sh <module> <flow>`)

| Gate | Check | Fails when |
|---|---|---|
| G1 | `mvn -DskipTests package` | compile error |
| G2 | `mvn camel-report:validate` (plugin in `tools/pom-build-plugins.xml`) | unknown component, option or bad URI |
| G3 | static rules | literal host/port, `jms://`/`t3://` URIs, password-like values, `camel-k`/`Integration` CRDs, missing placeholders |
| G4 | `mvn verify`: unit, route, golden, contract tests (surefire) | any failure; any skipped test not listed in the record's "Skipped tests" section |
| G5 | integration tests `*IT` with Testcontainers (failsafe) | failure, or Docker unavailable (reported as NOT RUN, which is not green) |
| G6 | `tools/check_matrix.py`: every test-matrix ID T1..Tn on the card appears in a test name | missing row |
| G7 | `tools/check_oracle.py`: every file under `golden/` and `parity/` is in `MANIFEST.csv` with an OSB source | unlisted file or `source` not from OSB |
| G8 | `tools/mutate_transforms.py`: each transform mutated, golden tests re-run | a mutant survives (tests stay green) |

Optional G8b: PIT mutation testing (`pitest-maven`) on Java processors, threshold set per programme (start 70 %).

## 3. Independence rules for an agentic setup

- The **tester** works from the card and OSB evidence in a fresh context; it never sees the implementer's chat.
- The **implementer** cannot edit `src/test/**`, `golden/`, `parity/`, `MANIFEST.csv`; disputes go to
  `TEST_DISPUTE.md` and a fresh tester (or a human) decides.
- The **reviewer** is read-only and writes findings with file:line.
- CI enforces the file rule: a commit by the implementer identity touching test paths fails the build
  (`ci/Jenkinsfile.groovy`, stage `guard`).
- Humans approve the card before code (gate A) and sign the record after gates (gate B). Sample 1 in 5 flows for a full
  human code review during the first batch; lower the rate once reviewer findings stay MINOR.

## 4. Where the expected outputs come from

| Source | How to capture | Used by |
|---|---|---|
| Original transform | run the `.xqy`/`.xsl` from `osb-src/` on Saxon with the shim, input from the card's fixtures | L2 |
| OSB test console | per proxy/pipeline, save request + outbound message | L2, L5 |
| OSB message tracing / report action | enable tracing in E2E for the flow, export, mask personal data | L5 |
| Recording at the broker | non-exclusive divert copying the OSB output queue (when it is already on AMQ Broker) | L5, L6 |
| Card rule | a behaviour written on the approved card (for example "empty body to error queue") | L1, L3 |

Mask personal data at capture (SIN, national ID, names) with a deterministic mask so that pairs stay consistent.

## 5. Shadow run (L6), example `order-event`

1. Register a second subscription on the topic address with the **same filter**: `order-event-shadow`.
2. Deploy the Camel module in E2E with overrides: consume `<topic>::order-event-shadow`, send to
   `shadow.InboundOrderEventQueue` and `shadow.orderEventErrorQueue`. Nothing downstream reads shadow queues.
3. Capture OSB's real output (divert copy or tracing) into `compare.osb.*`.
4. `tools/compare_shadow.py --osb <dir|queue dump> --camel <dir|queue dump> --key correlationId` pairs messages by the
   correlation id (`uuId`/`traceId`) and diffs canonical XML plus headers.
5. Exit criteria: agreed window (for example 5 business days or N messages, per flow), **0 unexplained differences**,
   error-path messages compared as well. Differences explained by an approved card deviation go to the record.
6. Remove the shadow subscription before cut-over (an idle durable subscription keeps growing).

## 6. Cut-over and rollback (L7), per flow

- Cut-over: stop the OSB proxy's consumption (disable the proxy), start the Camel route on the production
  subscription. For HTTP/SOAP proxies: switch the Apigee target (roadmap bridge B2).
- Rollback: the reverse; the OSB proxy stays deployed and disabled until the soak period ends.
- Never run OSB and Camel on the **same** subscription at the same time (messages would split between them).
KIT_EOF_TESTING_MD
mkdir -p "$(dirname "TRIAL_GUIDE.md")"
cat > 'TRIAL_GUIDE.md' <<'KIT_EOF_TRIAL_GUIDE_MD'
# OSB → Camel kit: trial guide (first run on the client VDI)

**Goal of the trial:** prove on real client OSB files that the kit can (1) inventory and triage flows automatically,
(2) produce a usable flow card, and (3) generate Camel code and tests that pass the gates. Measure human time per step,
because that number replaces the 1/2/3 PD per flow in the estimate.

**Who:** one engineer on the client VDI where pi is installed. **Time:** stage 1 about 1 hour; stage 2 about half a
day per flow; stage 3 runs mostly unattended.

## 0. What the solution is (two minutes)

| Piece | What it does |
|---|---|
| Skill `osb-to-camel` | Reads an OSB export, lists every flow with its complexity, writes a design card per flow, then generates the Camel on Spring Boot route, transforms, config and tests |
| Skill `camel-migration-verification` | Defines the gates G1–G8 that decide whether generated code is acceptable |
| Agents (4 roles) | analyst → implementer → tester → reviewer; each is a role prompt run in its own fresh pi session |
| `/osb-*` commands | start each role inside pi, step by step |
| `pi/run_flow.sh` | runs the four roles automatically, with the gates between them |
| `tools/` | deterministic scripts, no AI: inventory, gates, comparisons |

Diagram: `docs/OSB_Camel_Agent_Workflow_p1.png` (workflow) and `_p2.png` (inside the skills).

```
OSB files ─► ANALYST ─► flow card ─► YOU APPROVE ─► IMPLEMENTER ─► TESTER ─► GATES G1–G8 ─► REVIEWER ─► record
                                                        ▲                          │ red (max 3×)
                                                        └──────── fix loop ────────┘
```

## 1. Install (once, about 15 minutes)

Prerequisites on the VDI: pi working with the client's model, Git Bash or WSL, Python 3.10+, JDK 21, Maven 3.9 with the
internal mirror in `~/.m2/settings.xml`. Docker/Podman is optional (without it gate G5 shows NOT_RUN).

```bash
mkdir -p ~/work/osb-migration && cd ~/work/osb-migration
git init
```

**Option A, if you can copy the zip to the VDI:**

```bash
unzip /path/osb-camel-agent-kit.zip
cp -r osb-camel-agent-kit/{AGENTS.md,agents,tools,pi} .
mkdir -p .pi/skills .pi/prompts osb-src modules migration
cp -r osb-camel-agent-kit/skills/* .pi/skills/
cp osb-camel-agent-kit/pi/prompts/*.md .pi/prompts/
chmod +x pi/*.sh tools/*.sh tools/*.py
```

**Option B, copy-paste only:** for each of `bootstrap/1_…sh` to `5_…sh`, in order:
`cat > 1_install_agents.sh`, paste the content, press Ctrl-D, then run `bash 1_install_agents.sh`. Each script must end
with `installed: N files`. If that line is missing, the paste was cut off: paste again.
Then `mkdir -p osb-src modules migration`.

**Check:**

```bash
pi/preflight.sh                  # fix every FAIL; WARN on Docker is acceptable for the trial
pi                               # trust the project when asked (or: pi --approve); type / to see the /osb-* commands
```

The pi startup header must list `AGENTS.md`, skills `osb-to-camel` and `camel-migration-verification`, and prompts
`/osb-analyse`, `/osb-implement`, `/osb-test`, `/osb-verify`, `/osb-review`. Exit pi (`Ctrl-C` twice or `/quit`).

**Put the OSB files in place:** copy the OSB project folders (or the unzipped `sbconfig.jar`) to `osb-src/`, for
example `osb-src/order-event-prj/`. Use the same files the effort sheet was counted from.

## 2. Stage 1: inventory and triage (no AI, about 1 hour)

```bash
python3 .pi/skills/osb-to-camel/scripts/osb_inventory.py osb-src -o migration/osb-inventory
#   on Windows Git Bash use: python  (or py) instead of python3
```

Open `migration/osb-inventory/INVENTORY.md`.

**Check and record:**
1. The number of flows found vs the 450+ in the effort sheet.
2. The split by tier (complex / medium / simple) vs 70 / 60 / 320.
3. "Unknown actions" and "referenced but missing from the export": send these to us. They are gaps in the skill or in
   the export.
4. Pick **4 flows for stage 2**: the estimators' POC flow, plus one simple, one medium and one complex
   (`order-event` first if it is in the export).

## 3. Stage 2: one flow, step by step inside pi (about half a day per flow)

Start `pi` in `~/work/osb-migration` and run, replacing names and paths:

| Step | Type in pi | What you do | Record |
|---|---|---|---|
| 1 Analyse | `/osb-analyse osb-src/order-event-prj order-event` | Read `migration/order-event/FLOW_CARD.md` against the OSB files. Correct it if needed. When it is right, set the line to `\| **Status** \| approved by <name> \|` | minutes to review; number of corrections |
| 2 Implement | `/osb-implement order-event modules/order-event` | Let it build until `mvn package` passes | minutes; did it finish on its own? |
| 3 New session | `/new` | The tester must not see the implementer's reasoning | |
| 4 Test | `/osb-test order-event modules/order-event osb-src/order-event-prj` | Provide sample OSB messages if you have them (input + OSB output) | minutes; missing samples |
| 5 Verify | `/osb-verify modules/order-event order-event` | Read the gate table | which gates are red |
| 6 Fix | ask the implementer to fix red gates (production code only), then repeat step 5; at most 3 rounds | | rounds; minutes |
| 7 New session + review | `/new` then `/osb-review order-event modules/order-event osb-src/order-event-prj` | Read `REVIEW.md` and `MIGRATION_RECORD.md` | BLOCKER count |
| 8 Your judgement | Read the generated route next to the OSB pipeline | Would you accept this code in a review? What did you have to change by hand? | hand edits; verdict |

## 4. Stage 3: the same flow type, agentic (unattended between approvals)

For a flow of a tier that went well in stage 2:

```bash
export OSB_PI_MODEL=<model-id>                # the client model, as listed in pi /model
pi/run_flow.sh osb-src/<project> <flow> modules/<flow>
#   stops after the card: review and approve migration/<flow>/FLOW_CARD.md, then
pi/run_flow.sh osb-src/<project> <flow> modules/<flow> --from implement
```

Progress logs are in `migration/<flow>/agent-logs/`; the result is in `migration/<flow>/` (`verify-report.json`,
`REVIEW.md`, `MIGRATION_RECORD.md`). The script stops by itself if:
- the card is not approved;
- a role edits outside its lane;
- the gates are still red after 3 fix loops;
- the reviewer reports a BLOCKER.

## 5. Measure and send back

Fill `TRIAL_RESULTS_TEMPLATE.csv`, one row per flow and step, and send it with:

- `migration/osb-inventory/INVENTORY.md` and `inventory.json`;
- for each trial flow: `FLOW_CARD.md`, `verify-report.json`, `REVIEW.md`, and the `agent-logs/` folder of stage 3;
- a short note: what was good, what was wrong, what you changed by hand, and what blocked you.

Do not send real personal data: mask sample messages first.

## 6. Known limits (so they do not surprise you)

- Generated code has not yet been compiled on a real client flow. This trial is the first time, so expect fixes in the
  skill. Report every failure; that is the point of the trial.
- Without Docker on the VDI, gate G5 (Artemis integration tests) is NOT_RUN, so the overall result shows NOT GREEN.
  Judge the other gates.
- Gate G7 needs expected outputs from OSB (test console or recorded messages). Without samples, the golden tests cannot
  be proven.
- The Java base package, the Spring Boot module per OSB project and the Artemis names are not decided yet. Use
  placeholders and note them in the card.
- Sending OSB source to the model endpoint must be approved for the VDI. Check before stage 2.
KIT_EOF_TRIAL_GUIDE_MD
mkdir -p "$(dirname "TRIAL_RESULTS_TEMPLATE.csv")"
cat > 'TRIAL_RESULTS_TEMPLATE.csv' <<'KIT_EOF_TRIAL_RESULTS_TEMPLATE_CSV'
flow,tier_kit,tier_estimate_sheet,stage,step,minutes_human,minutes_wall_clock,model_runs,corrections_by_hand,gates_red_after_step,fix_loops,blockers,verdict_ok_yes_no,notes
order-event,complex,,2,1 analyse (card review),,,,,,,,,example row: replace with real values
order-event,complex,,2,2 implement,,,,,,,,,
order-event,complex,,2,4 test,,,,,,,,,
order-event,complex,,2,5 verify,,,,,G4 G7,,,,
order-event,complex,,2,6 fix,,,,,,,,,
order-event,complex,,2,7 review,,,,,,,,,
order-event,complex,,2,8 own judgement,,,,,,,,,
KIT_EOF_TRIAL_RESULTS_TEMPLATE_CSV
mkdir -p "$(dirname "agents/analyst.md")"
cat > 'agents/analyst.md' <<'KIT_EOF_AGENTS_ANALYST_MD'
# Role: analyst

**Goal:** a complete, sourced flow card for one OSB flow. No code.

**Use:** skill `osb-to-camel`, Steps 0 and 1. Read `references/osb-action-mapping.md`, `osb-transport-mapping.md`,
`osb-expression-mapping.md`, `triage-rules.md` as the card needs them.

**Do**
1. Run the inventory once per project; read `INVENTORY.md` fully.
2. Scaffold the card, then complete it from the real `.proxy`, `.pipeline`, `.bix`/`.biz`, `.xqy`, `.xsl`, `.xsd`,
   `.wsdl`, `.jca`, `.mfl` files. One row per pipeline action, in execution order, with the file and XPath it came from.
3. Fill: contract, context variables, backends with retries/timeouts, transforms with `fn-bea:` use, error handlers
   (what they send, whether they swallow the fault), transactions, selectors, durable subscriptions, logging of
   personal data, test matrix (one row per operation, branch, error path, transform, backend; IDs T1..Tn).
4. Name every behaviour that cannot map 1:1 and every quirk the migration must preserve (it goes to the parity tests).
5. Open items: one owner each. Blocking items are marked BLOCKING.

**Do not:** propose improvements to the contract, guess missing files, write Java.

**Hand-off:** `migration/<flow>/FLOW_CARD.md`, status `draft`, plus a 5-line summary for the human reviewer.
KIT_EOF_AGENTS_ANALYST_MD
mkdir -p "$(dirname "agents/implementer-camelk.md")"
cat > 'agents/implementer-camelk.md' <<'KIT_EOF_AGENTS_IMPLEMENTER_CAMELK_MD'
# Role: implementer (Camel K YAML route from an approved card)

You implement ONE flow in `modules/<project>/<proxy>/` with skill `osb-camelk-route`, from its approved FLOW_CARD.md and
research pack. You never change the OSB source, the research pack, FlowParityTest.java, flow-test.json or any test case folder (real or synthetic), and you never
disable or weaken a test. You may copy original XQuery/XSLT/XSD files from the OSB source into the module.
Behaviour that is not on the card is not implemented: record it as an open question in MIGRATION_NOTES.md.
Finish only when check_camelk.py prints PASS, or stop and report which gate fails and why it cannot pass.
KIT_EOF_AGENTS_IMPLEMENTER_CAMELK_MD
mkdir -p "$(dirname "agents/implementer.md")"
cat > 'agents/implementer.md' <<'KIT_EOF_AGENTS_IMPLEMENTER_MD'
# Role: implementer

**Goal:** the Camel on Spring Boot code for one **approved** card. Nothing the card did not approve.

**Use:** skill `osb-to-camel`, Step 2, templates in `assets/templates/java/` (read them before writing), `AGENTS.md`.

**Do**
1. Refuse to start unless the card says `Status: approved` with an approver.
2. Generate: `RouteBuilder` (route id = proxy name), `OsbSupport`/`OsbXQuery` usage for OSB expressions, original
   transforms copied unchanged (+ `fn-bea` shim import only), processors only where the card says, `application.yml`
   keys with placeholders, the Artemis register snippet (addresses, subscription queues with filters, DLQ/expiry).
3. Map OSB retries to redelivery on that endpoint, OSB error handlers to the scope the card decided, OSB `Reply`
   semantics exactly (a swallowed fault stays swallowed unless the card approved a change).
4. `mvn -q -DskipTests package` must pass before hand-off.

**In fix loops (S4a):** change production code only. If you believe a test is wrong, write
`migration/<flow>/TEST_DISPUTE.md` (test, expected, actual, evidence from the OSB files) and stop. Never edit tests,
fixtures, `golden/` or `MANIFEST.csv`.

**Do not:** add components outside `references/versions.md` without a note, hard-code hosts/queues/credentials,
generate expected outputs, run against real environments.

**Hand-off:** the module path and a list of files changed.
KIT_EOF_AGENTS_IMPLEMENTER_MD
mkdir -p "$(dirname "agents/orchestrator.md")"
cat > 'agents/orchestrator.md' <<'KIT_EOF_AGENTS_ORCHESTRATOR_MD'
# Orchestrator: phases, hand-offs, loops

You coordinate the migration of one OSB flow (or one batch) through four roles. You do not write cards, code or tests
yourself. You start each role with its prompt from `agents/`, pass only the hand-off files listed below, read the
gate output, and decide the next state. Repository rules: `AGENTS.md`.

## State machine (per flow)

| State | Role | Input files | Output files | Exit when | Next |
|---|---|---|---|---|---|
| S0 NEW | analyst | `osb-src/<project>/` | `migration/osb-inventory/`, `migration/<flow>/FLOW_CARD.md` | card written, open items listed | S1 |
| S1 CARD_REVIEW | **human** | card | card with `Status: approved` + approver | approved / changes requested | S2 / S0 |
| S2 IMPLEMENT | implementer | approved card, `osb-src/`, skill templates | `<module>/src/main/**`, `register/` snippet | `mvn -DskipTests package` passes | S3 |
| S3 TEST | tester | approved card, `osb-src/`, golden fixtures, **not** the implementer's chat | `<module>/src/test/**`, `golden/MANIFEST.csv` | tests written for every matrix row | S4 |
| S4 VERIFY | tools (no AI) | module | `migration/<flow>/verify-report.json` | all gates green | S5 |
| S4a FIX | implementer | verify report, failing test output | code changes only | re-run S4 | S4 |
| S5 REVIEW | reviewer | card, code, tests, verify report | `REVIEW.md`, `MIGRATION_RECORD.md` | no BLOCKER | S6 |
| S6 SIGN_OFF | **human** | record, review, report | signed record | signed | S7 |
| S7 SHADOW | platform + tester | E2E deployment | shadow comparison report (TESTING.md L6) | diff rate 0 over the agreed window | DONE |

## Loop limits and stop conditions

- S4 ↔ S4a: at most **3** fix loops. Then stop the flow, status `BLOCKED`, attach the last report.
- The implementer may change **production code only** in S4a. If a test looks wrong, it writes the argument into
  `migration/<flow>/TEST_DISPUTE.md`; the tester (fresh context) decides; a human breaks ties.
- Batch mode: stop the batch after 3 consecutive flows with an unknown OSB action, a missing resource or a shim gap.
  The mapping tables need an entry first.
- Any request to touch `osb-src/`, credentials, production endpoints or another flow's module: refuse and report.

## Status file

Keep `migration/STATUS.md`: one row per flow with state, tier, loop count, gates summary, blocking items, owner.
KIT_EOF_AGENTS_ORCHESTRATOR_MD
mkdir -p "$(dirname "agents/researcher.md")"
cat > 'agents/researcher.md' <<'KIT_EOF_AGENTS_RESEARCHER_MD'
# Role: researcher (OSB research pack)

You research ONE OSB proxy from its source and write a research pack that will leave the client network.
Follow skill `osb-research` exactly. You never change the OSB export or any module: you only write into
`research/<proxy>/`. You never paste code, hosts, credentials or data into the pack; you describe and give evidence.
If the source does not answer a question, write UNKNOWN and add an open question; never guess.
Finish only when `research_check.py` prints PASS, then give the five-line report.
KIT_EOF_AGENTS_RESEARCHER_MD
mkdir -p "$(dirname "agents/reviewer.md")"
cat > 'agents/reviewer.md' <<'KIT_EOF_AGENTS_REVIEWER_MD'
# Role: reviewer (evidence only, read-only)

**Goal:** an honest review and the migration record. You do not change code or tests.

**Inputs:** approved card, module code, tests, `verify-report.json`, `golden/MANIFEST.csv`, the OSB files.

**Check**
1. Every pipeline action on the card maps to a Camel step (action id → class/line). Missing = BLOCKER.
2. Contract unchanged: inbound transport, URI path, WSDL/namespaces, selector, subscription semantics.
3. Error behaviour: same destinations, headers, swallowed vs propagated, retry counts and intervals.
4. Transactions and acknowledgement match the card's decision; deviations are listed as deliberate.
5. Tests: every matrix row present (G6), oracle provenance clean (G7), mutation check killed every mutant (G8), no
   skipped test without a reason.
6. Rules in `AGENTS.md`: placeholders, no secrets, no Camel K/operators, logging of personal data.

**Severity:** BLOCKER (wrong behaviour or missing evidence) · MAJOR (rule broken, behaviour plausibly fine) ·
MINOR (style, naming).

**Write**
- `migration/<flow>/REVIEW.md`: findings with severity and file:line.
- `migration/<flow>/MIGRATION_RECORD.md` from the skill template, with the four sections: **Original OSB behaviour /
  Camel implementation / Behavioural differences / Items requiring human validation**. Use the words "evidence shows"
  with a gate or test name; never "equivalent".
KIT_EOF_AGENTS_REVIEWER_MD
mkdir -p "$(dirname "agents/tester-camelk.md")"
cat > 'agents/tester-camelk.md' <<'KIT_EOF_AGENTS_TESTER_CAMELK_MD'
# Role: tester (synthetic test messages for scenarios Splunk cannot supply)

You write test INPUTS for ONE flow, before any route exists, so the implementer cannot shape them to its code.
For every scenario_mapping row in `src/test/resources/flow-test.json` that has no case yet, write one case folder under
`src/test/resources/parity/<project>-<proxy>-synthetic/<row-slug>/<case-id>/`, i.e. THREE folder levels below parity:
```
parity/sample-transform-prj-sample-transform-synthetic/all/SCENARIO.txt
parity/sample-transform-prj-sample-transform-synthetic/all/case1/input.payload   (+ headers.json, expected.json)
```
(scenario `*` = every message: SCENARIO.txt is then `<project>/<proxy>|success` with no keys)
- `input.payload`: a message the OSB proxy accepts, built from the message schema in the OSB source (XSD, nXSD, WSDL,
  JSON sample in the export), with FAKE values only (masked_..., 1000000001 ...). The fields the row's key names must
  have exactly the row's values (k=v), or a different value / be absent (k!=v).
- `headers.json`: transport headers the flow reads (resource, eventType ...) + a traceId.
- `expected.json`: {"outcome": "success", "destination": "see mapping", "correlation": "<the traceId>"}.
- `../SCENARIO.txt`: `<project>/<proxy>|success|k=v|...` with every key of the row.
You never write or change the route, the beans, FlowParityTest.java, flow-test.json, or real (Splunk) case folders.
If the schema is missing from the export, write nothing for that row and report it.
KIT_EOF_AGENTS_TESTER_CAMELK_MD
mkdir -p "$(dirname "agents/tester.md")"
cat > 'agents/tester.md' <<'KIT_EOF_AGENTS_TESTER_MD'
# Role: tester (independent oracle)

**Goal:** a test suite that would catch a wrong migration. You work from the **card and the OSB evidence**, not from
the implementer's reasoning. Start with a fresh context.

**Use:** skill `osb-to-camel` Step 3 + `references/test-strategy.md`, skill `camel-migration-verification`.

**Do**
1. One test per row of the card's test matrix. Put the row ID in the test name or `@DisplayName` ("T3 …"); gate G6
   checks it.
2. Expected outputs only from OSB: recorded traffic, the **original** XQuery/XSLT run on Saxon with the `fn-bea` shim,
   or the OSB test console. Register each file in `src/test/resources/golden/MANIFEST.csv`
   (`file,source,flow,captured_by,date`); `source` ∈ `osb-recording | original-transform | osb-test-console |
   card-rule`. Gate G7 rejects anything else.
3. Mock every external system: `mock:` via AdviceWith for route logic, WireMock for HTTP/SOAP, Testcontainers Artemis
   (AMQ Broker image, AMQP 5672) for JMS behaviour: filters, transactions, redelivery, DLQ, error queue headers.
4. Cover the quirks the card lists (they are features until a human says otherwise).
5. Assert behaviour, not implementation: message bodies (XMLUnit, canonical), headers, destinations, counts,
   acknowledgement (message gone vs redelivered).

**Do not:** read the implementer's explanation of why something should pass, compute expectations with the new code,
use `@Disabled` without a reason in the record, relax an assertion to make a test green.

**Hand-off:** the test sources, `MANIFEST.csv`, and the list of matrix rows that could not be tested with the reason.
KIT_EOF_AGENTS_TESTER_MD
mkdir -p "$(dirname "pi/init_env.sh")"
cat > 'pi/init_env.sh' <<'KIT_EOF_PI_INIT_ENV_SH'
#!/usr/bin/env bash
# Writes ./.osb-kit.env for this workspace with what it can find on the machine, so nobody types paths again.
# Usage (in the workspace, e.g. /e/Pawel/work):  bash <kit>/pi/init_env.sh <osb-application-folder>
# The file is client-specific: it stays here, .gitignore keeps it out of Git. Edit it afterwards if a value is wrong.
set -u
APP_DIR=${1:?usage: init_env.sh <osb-application-folder>}
case "$APP_DIR" in *\\*|[A-Za-z]:*) command -v cygpath >/dev/null && APP_DIR=$(cygpath -u "$APP_DIR");; esac
[ -d "$APP_DIR" ] || { echo "not a folder: $APP_DIR"; exit 2; }
KIT_DIR=$(cd "$(dirname "$0")/.." && pwd)
pick() { for d in "$@"; do [ -d "$d" ] && { echo "$d"; return; }; done; }
JDK=$(pick /c/Program\ Files/Eclipse\ Adoptium/jdk-21* /c/Program\ Files/Java/jdk-21* /c/Program\ Files/Microsoft/jdk-21* "${JAVA_HOME:-/nonexistent}")
MVN=$(pick /e/Pawel/apache-maven-3.9* "$HOME"/apache-maven-3.9* /c/apache-maven-3.9* "$(dirname "$(dirname "$(command -v mvn 2>/dev/null || echo /x/x/x)")")")
first() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return; }; done; }
cat > .osb-kit.env <<ENV
# written by init_env.sh on $(date +%F); local only (.gitignore). Command-line values win over these defaults.
export KIT="\${KIT:-$KIT_DIR}"
export APP="\${APP:-$APP_DIR}"
export WS="\${WS:-$(pwd)}"
export JAVA_HOME="\${JAVA_HOME_21:-$JDK}"
export PATH="$MVN/bin:\$JAVA_HOME/bin:\$PATH"
export MVN_ARGS="\${MVN_ARGS:--s $HOME/.m2/settings.xml}"
export PI_OFFLINE="\${PI_OFFLINE:-1}" PI_TELEMETRY="\${PI_TELEMETRY:-0}" PI_PAUSE="\${PI_PAUSE:-60}"
export EXPORT="\${EXPORT:-$(first "$(pwd)/domain-export.csv")}"
export SPLUNK_COVERAGE="\${SPLUNK_COVERAGE:-$(first "$(pwd)/splunk-payload.csv")}"
export MASK_JSON_KEYS="\${MASK_JSON_KEYS:-reason}"
export POC="\${POC:-1}"
export BATCH_SIZE="\${BATCH_SIZE:-10}"
# MASK_KEY is NOT stored here: export it per session (key from the data owner)
ENV
echo "written $(pwd)/.osb-kit.env"
grep -E '^export (KIT|APP|WS|JAVA_HOME|EXPORT|SPLUNK_COVERAGE)=' .osb-kit.env | sed 's/^export /  /'
[ -n "$JDK" ] || echo "  WARNING: no JDK 21 found: edit JAVA_HOME in .osb-kit.env"
[ -n "$MVN" ] || echo "  WARNING: no Maven 3.9 found: edit PATH in .osb-kit.env"
KIT_EOF_PI_INIT_ENV_SH
mkdir -p "$(dirname "pi/make_review_pack.sh")"
cat > 'pi/make_review_pack.sh' <<'KIT_EOF_PI_MAKE_REVIEW_PACK_SH'
#!/usr/bin/env bash
# One review package per flow: research -> card -> generated Camel K code -> tests -> results, with a reviewer checklist.
# Stays on the client machine (it contains the original XQuery and masked test data).
#
# Usage (in the workspace):  bash <kit>/pi/make_review_pack.sh <project> <proxy> [reference-route-dir]
# Env: ROUTE_AUTHOR (default "pi agent (osb-camelk-route)"): who wrote the route, shown in README_REVIEW.md
#   reference-route-dir  optional: another route for the same flow (e.g. the hand-written pilot) -> compared against
#                        the SAME frozen tests with compare_codegen.py
# Result: review/<project>-<proxy>/ + review/<project>-<proxy>.tgz   (agent logs and build output are left out)
set -uo pipefail
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
P=${1:?usage: make_review_pack.sh <project> <proxy> [reference-route-dir]}
X=${2:?proxy}
REF=${3:-}
WS=${WS:-.}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
R="$WS/research/$P/$X"; M="$WS/modules/$P/$X"; O="$WS/review/$P-$X"
[ -s "$R/research.json" ] || { echo "no research pack in $R: run run_domain.sh research first"; exit 2; }
[ -d "$M" ] || { echo "no module in $M: run run_domain.sh tests (and build) first"; exit 2; }
rm -rf "$O"; mkdir -p "$O"/{1-research,2-card,3-code,4-tests,5-results}
cp "$R"/RESEARCH.md "$R"/research.json "$R"/facts.json "$R"/SHARE_CHECK.json "$O/1-research/" 2>/dev/null
cp "$M/FLOW_CARD.md" "$O/2-card/" 2>/dev/null
[ -d "$M/src/main" ] && cp -r "$M/src/main" "$O/3-code/"
cp "$M/MIGRATION_NOTES.md" "$M/pom.xml" "$O/3-code/" 2>/dev/null
[ -d "$M/src/test" ] && cp -r "$M/src/test" "$O/4-tests/"
cp "$M/GATES.json" "$M/MUTATION.json" "$M/TEST_MATRIX.md" "$M/test-matrix.csv" "$O/5-results/" 2>/dev/null
[ -d "$M/target/surefire-reports" ] && cp "$M"/target/surefire-reports/*.txt "$O/5-results/" 2>/dev/null
if [ -n "$REF" ] && [ -d "$REF" ]; then
  echo "== comparing the generated route with $REF on the same frozen tests"
  "$PY" "$(cd "$KIT/../../vdi-osb-migration/bin" 2>/dev/null && pwd || echo "$KIT/bin")/compare_codegen.py" "$M" \
    --candidate generated="$M/src/main" --candidate reference="$REF" --mvn "mvn -B -q ${MVN_ARGS:-}" -o "$O/6-compare" >/dev/null 2>&1 \
    && rm -rf "$O"/6-compare/generated "$O"/6-compare/reference || echo "   comparison failed: see $O/6-compare"
fi
"$PY" - "$O" "$P" "$X" "$M" "${ROUTE_AUTHOR:-pi agent (osb-camelk-route)}" <<'PY'
import json, sys, re
from pathlib import Path
o, p, x, m, author = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4]), sys.argv[5]
load = lambda f: json.loads(f.read_text(encoding="utf-8")) if f.is_file() else {}
g = load(m / "GATES.json"); mu = load(m / "MUTATION.json"); res = load(o / "1-research/research.json")
cfg = load(m / "src/test/resources/flow-test.json")
cases = [c for c in (m / "src/test/resources/parity").glob("**/input.payload")] if (m / "src/test/resources/parity").is_dir() else []
real = sum("-synthetic" not in c.as_posix() for c in cases)
card = (m / "FLOW_CARD.md").read_text(encoding="utf-8") if (m / "FLOW_CARD.md").is_file() else ""
st = (re.search(r"^Status:\s*(.+)$", card, re.M) or [None, "-"])[1]
k8 = g.get("gates", {}).get("K8_tests_green", {})
routes = sorted(p_.name for p_ in (m / "src/main/resources/routes").glob("*.yaml")) if (m / "src/main/resources/routes").is_dir() else []
lines = [f"# Review package: {p} / {x}", "",
         "Everything below stays on the client machine. Read in this order:", "",
         "| # | Folder | What to check |", "|---|---|---|",
         "| 1 | `1-research/RESEARCH.md` | what the OSB flow does (entry, branches, outputs, errors, logs) with evidence; open questions |",
         "| 2 | `2-card/FLOW_CARD.md` | the behaviour the code must implement; status of the approval |",
         f"| 3 | `3-code/main/resources/routes/` | **the Camel K route, written by: {author}** (YAML DSL), helper beans in `3-code/main/java`, endpoints in `application.properties`, `MIGRATION_NOTES.md` |",
         "| 4 | `4-tests/` | generated tests (FlowParityTest, frozen), FlowErrorTest, expected outputs (`flow-test.json`), test messages (`resources/parity`, masked / synthetic), stubs |",
         "| 5 | `5-results/` | TEST_MATRIX.md, GATES.json (K1-K9), MUTATION.json, surefire summaries |",
         "| 6 | `6-compare/COMPARISON.md` | (if present) generated route vs reference route on the same tests |", "",
         "## Summary", "",
         f"- Route written by: **{author}**",
         f"- Card status: **{st}**",
         f"- Route files: {', '.join(routes) or 'none (not built yet)'}",
         f"- Scenarios: {len(cfg.get('scenario_mapping') or [])}; test messages: {real} real (masked Splunk), {len(cases) - real} synthetic",
         f"- Outputs mocked: {', '.join(k for k in (cfg.get('outputs') or {}))}",
         f"- Tests: {k8.get('tests', '-')} run, {k8.get('failures', '-')} failed, {k8.get('errors', '-')} errors, {k8.get('skipped', '-')} skipped",
         f"- Gates: {g.get('result', 'not run')}" + ("; failing: " + ", ".join(k for k, v in g.get('gates', {}).items() if not v.get('ok')) if g else ""),
         f"- Mutations caught: {mu.get('killed', '-')}/{mu.get('total', '-')}",
         f"- Open questions in the research: {len(res.get('open_questions') or [])}", "",
         "## Reviewer checklist", "",
         "- [ ] Every branch, output, retry and error header of the card is in the route, nothing that is not on the card",
         "- [ ] OSB log lines kept with the same text and logName (the tests do not check log text)",
         "- [ ] Original XQuery/XSLT used unchanged (not rewritten)",
         "- [ ] Body forwarded unchanged where OSB forwards it",
         "- [ ] Endpoints only as properties; no hosts, ports, secrets",
         "- [ ] Helper beans small and readable; YAML DSL idiomatic for Camel 4.18",
         "- [ ] Differences to OSB listed in MIGRATION_NOTES.md and acceptable",
         "- [ ] Open questions answered or accepted before the card is approved", "",
         "Reviewer: ____________  Date: ________  Result: approve / changes needed"]
(o / "README_REVIEW.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
print("\n".join(lines[14:24]))
PY
(cd "$WS/review" && tar -czf "$P-$X.tgz" "$P-$X")
echo "review package: $O  (+ $WS/review/$P-$X.tgz). Keep it on the client machine."
KIT_EOF_PI_MAKE_REVIEW_PACK_SH
mkdir -p "$(dirname "pi/pi_call.sh")"
cat > 'pi/pi_call.sh' <<'KIT_EOF_PI_PI_CALL_SH'
#!/usr/bin/env bash
# Sourced by the pi runners. pi_call <out-file> <err-file> <pi args...>
# Runs pi; when the model endpoint answers 429 / rate limit / overloaded, waits and retries with a growing pause.
# Env: PI_RETRIES (default 5), PI_BACKOFF (first pause in seconds, default 60, doubled each time, max 15 min).
# Exit 75 when the endpoint still refuses after all retries (quota used up): the runners stop instead of moving on.
# PI_TIMEOUT (seconds, default 1800): a single pi run that takes longer is killed (a hanging call never returns);
# exit 124 = timed out.
pi_call() {
  local out=$1 err=$2; shift 2
  local n=0 wait=${PI_BACKOFF:-60}
  while :; do
    if command -v timeout >/dev/null 2>&1; then
      timeout --kill-after=30 "${PI_TIMEOUT:-1800}" "$@" > "$out" 2> "$err"
      local rc=$?
      [ $rc = 0 ] && return 0
      if [ $rc = 124 ] || [ $rc = 137 ]; then
        echo "   pi did not finish within ${PI_TIMEOUT:-1800}s (hanging call), stopped it"; return 124
      fi
    else
      "$@" > "$out" 2> "$err" && return 0
    fi
    if grep -qiE '(^|[^0-9])429([^0-9]|$)|too many requests|rate.?limit|overloaded|503 service unavailable' "$err" 2>/dev/null \
       && [ "$n" -lt "${PI_RETRIES:-5}" ]; then
      n=$((n + 1))
      echo "   model endpoint busy (rate limit), waiting ${wait}s, retry $n/${PI_RETRIES:-5}"
      sleep "$wait"
      [ -n "${PI_WAIT_FILE:-}" ] && echo "$wait" >> "$PI_WAIT_FILE"     # rate-limit waiting, measured separately
      wait=$((wait * 2)); [ "$wait" -gt 900 ] && wait=900
      continue
    fi
    if grep -qiE '(^|[^0-9])429([^0-9]|$)|too many requests|rate.?limit|overloaded' "$err" 2>/dev/null; then
      echo "   model endpoint still refuses after ${PI_RETRIES:-5} retries: quota used up? stopping (exit 75)"
      return 75
    fi
    return 1
  done
}
KIT_EOF_PI_PI_CALL_SH
mkdir -p "$(dirname "pi/preflight.sh")"
cat > 'pi/preflight.sh' <<'KIT_EOF_PI_PREFLIGHT_SH'
#!/usr/bin/env bash
# Preflight for the client VDI: checks everything the kit needs before the first run.
# Runs in Git Bash (Windows), WSL or Linux. Read-only: installs nothing, changes nothing.
# Usage: pi/preflight.sh [model-endpoint-url]
set -u
[ -f "${OSB_KIT_ENV:-$HOME/.osb-kit.env}" ] && . "${OSB_KIT_ENV:-$HOME/.osb-kit.env}"   # local client settings, never in Git
ok=0; warn=0; fail=0
pass() { printf '  [ OK ] %s\n' "$1"; ok=$((ok+1)); }
wrn()  { printf '  [WARN] %s\n' "$1"; warn=$((warn+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # $1 >= $2

echo "OS: $(uname -s 2>/dev/null) $(uname -r 2>/dev/null)"

echo "Agent"
if command -v node >/dev/null; then
  v=$(node -v | tr -d v); ver_ge "$v" 22.19.0 && pass "node $v" || bad "node $v < 22.19 (pi requirement)"
else bad "node not found (pi needs Node.js 22.19+)"; fi
if command -v pi >/dev/null; then pass "pi $(pi --version 2>/dev/null | head -1)"; else bad "pi not found"; fi
[ -n "${OSB_PI_MODEL:-}" ] && pass "OSB_PI_MODEL=$OSB_PI_MODEL" || wrn "OSB_PI_MODEL unset: pi uses its default model"
for f in "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json" "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/auth.json"; do
  [ -f "$f" ] && pass "found $f" || wrn "no $f (needed for a custom endpoint or stored login)"
done
[ "${PI_OFFLINE:-}" ] && pass "PI_OFFLINE set (no catalog/network calls)" || wrn "PI_OFFLINE unset: pi may call pi.dev (catalog, version check)"
[ "${PI_TELEMETRY:-}" = "0" ] && pass "PI_TELEMETRY=0" || wrn "PI_TELEMETRY not 0"
if [ -n "${1:-}" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo 000)
  [ "$code" != "000" ] && pass "model endpoint reachable ($1 → HTTP $code)" || bad "model endpoint not reachable: $1"
fi

echo "Shell tools"
command -v bash >/dev/null && pass "bash $(bash --version | head -1 | awk '{print $4}')" || bad "bash missing (Git for Windows provides it)"
command -v sha1sum >/dev/null || command -v shasum >/dev/null && pass "sha1sum/shasum" || bad "no sha1sum/shasum"
PY=$(command -v python3 || command -v python || command -v py)
if [ -n "$PY" ]; then v=$("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])'); ver_ge "$v" 3.10 && pass "python $v ($PY)" || bad "python $v < 3.10"
else bad "python not found"; fi
command -v git >/dev/null && pass "git" || wrn "git missing (lane checks still work, CI guard needs git)"
command -v timeout >/dev/null && pass "timeout (a hanging pi call is stopped after PI_TIMEOUT, default 1800 s)" || wrn "no 'timeout' command: a hanging pi call is not stopped automatically"

echo "Build and test"
if command -v java >/dev/null; then
  v=$(java -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/'); [ "$v" -ge 21 ] 2>/dev/null && pass "java $v" || bad "java $v < 21"
else bad "java not found (JDK 21)"; fi
if command -v mvn >/dev/null; then pass "maven $(mvn -v 2>/dev/null | head -1 | awk '{print $3}')"
  [ -f "$HOME/.m2/settings.xml" ] && pass "~/.m2/settings.xml present (mirror/proxy)" || wrn "no ~/.m2/settings.xml: Maven will try Maven Central directly"
else bad "maven not found"; fi
if docker info >/dev/null 2>&1; then pass "docker"; elif podman info >/dev/null 2>&1; then pass "podman"
else printf '  [INFO] no Docker/Podman: not needed (functional tests use mocks; Artemis tests run later on the Dev environment)\n'; fi

echo "Kit layout (run from the migration repository root)"
for p in AGENTS.md agents/analyst.md tools/verify_flow.sh pi/run_flow.sh; do [ -e "$p" ] && pass "$p" || bad "$p missing"; done
sk=0; for d in .pi/skills "$HOME/.pi/agent/skills" .agents/skills skills; do [ -f "$d/osb-to-camel/SKILL.md" ] && sk=1; done
[ $sk = 1 ] && pass "skill osb-to-camel discoverable" || bad "skill osb-to-camel not in .pi/skills, ~/.pi/agent/skills or .agents/skills"
sr=0; for d in .pi/skills "$HOME/.pi/agent/skills" .agents/skills skills; do [ -f "$d/osb-research/SKILL.md" ] && sr=1; done
[ $sr = 1 ] && pass "skill osb-research discoverable" || bad "skill osb-research not found (needed for research packs: pi/run_research.sh)"
# Maven build of Camel K modules: Maven 3.6.3+ on Java 17+ (VDI default is Maven 3.5.3 on JDK 1.7)
if command -v mvn >/dev/null; then
  mv=$(mvn -v 2>/dev/null | tr -d '\033' | sed -n 's/.*Apache Maven \([0-9.]*\).*/\1/p' | head -1)
  jv=$(mvn -v 2>/dev/null | sed -n 's/^Java version: \([0-9]*\).*/\1/p' | head -1); [ "$jv" = 1 ] && jv=$(mvn -v | sed -n 's/^Java version: 1\.\([0-9]*\).*/\1/p')
  printf '%s\n3.6.3\n' "$mv" | sort -V -C 2>/dev/null && bad "Maven $mv too old for the test plugins (need 3.6.3+: Maven 3.9.9 from Nexus, see DOMAIN_RUN.md)" || pass "Maven $mv"
  [ "${jv:-0}" -ge 17 ] 2>/dev/null && pass "Maven runs on Java $jv" || bad "Maven runs on Java ${jv:-?} (need 17+: export JAVA_HOME to the JDK 21 folder)"
fi
sc=0; for d in .pi/skills "$HOME/.pi/agent/skills" .agents/skills skills; do [ -f "$d/osb-camelk-route/SKILL.md" ] && sc=1; done
[ $sc = 1 ] && pass "skill osb-camelk-route discoverable" || bad "skill osb-camelk-route not found (needed for pi/run_camelk.sh, pi/run_domain.sh)"
# pi skips a SKILL.md whose front matter is not valid YAML, without an error: check the usual traps
for f in .pi/skills/*/SKILL.md "$HOME/.pi/agent/skills"/*/SKILL.md .agents/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  issue=$(awk 'NR==1 && $0!="---"{print "no front matter"; exit} NR>1 && $0=="---"{exit}
               NR>1 && /^[A-Za-z_-]+: /{v=$0; sub(/^[A-Za-z_-]+: /,"",v);
                 if (v ~ /^["\x27]/) next;
                 if (index(v,": ")) {print "unquoted \": \" in " $1; exit}
                 if (index(v," #")) {print "unquoted \" #\" in " $1; exit}
                 if (length(v)>1024 && $1=="description:") {print "description over 1024 characters"; exit}}' "$f")
  [ -z "$issue" ] && pass "front matter valid: $f" || bad "pi will skip $f: $issue"
done
# /osb-* commands: pi reads prompt templates from .pi/prompts (project, after trust) or ~/.pi/agent/prompts
pd=""; for d in .pi/prompts "$HOME/.pi/agent/prompts"; do
  m=0; for n in osb-analyse osb-implement osb-test osb-verify osb-review; do [ -f "$d/$n.md" ] || m=$((m+1)); done
  [ $m -eq 0 ] && { pd=$d; break; }
done
if [ -n "$pd" ]; then pass "/osb-* commands found in $pd"
  [ "$pd" = .pi/prompts ] && printf '  [INFO] .pi/ loads only for a trusted project: trust it at the first pi start, or run pi --approve\n'
else bad "/osb-* commands missing: run  mkdir -p .pi/prompts && cp pi/prompts/*.md .pi/prompts/  (pi/prompts is the kit copy, pi does not read it)"; fi
[ -d osb-src ] && [ -n "$(ls -A osb-src 2>/dev/null)" ] && pass "osb-src/ has content" || wrn "osb-src/ empty: put the OSB export there"

echo; echo "Result: $ok ok, $warn warnings, $fail failures"
[ $fail -eq 0 ]
KIT_EOF_PI_PREFLIGHT_SH
mkdir -p "$(dirname "pi/run_camelk.sh")"
cat > 'pi/run_camelk.sh' <<'KIT_EOF_PI_RUN_CAMELK_SH'
#!/usr/bin/env bash
# Research pack -> Camel K module for ONE proxy: functional tests (pi/run_tests.sh) -> approval gate -> implement (pi)
# -> mvn test -> gates.
#
# Usage: pi/run_camelk.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]
#   research-dir   research/<project>/<proxy> with research.json (+ facts.json), check PASS
#   module-dir     modules/<project>/<proxy> (created on the first run)
#   task1-dir      its fixtures/parity/* are copied into the module as test inputs (masked; .gitignore keeps them out of Git)
# Env: OSB_SRC (OSB project folder: the implementer may copy original XQuery/XSLT/XSD into the module), MVN_ARGS
#      (e.g. "-s ~/.m2/client-settings.xml"), OSB_PI_MODEL, PI_THINKING (default high), KIT, PYTHON
# Exit: 0 gates PASS, 3 card not approved yet (expected after the first run), 1 anything else.
set -euo pipefail
[ -f "${OSB_KIT_ENV:-$HOME/.osb-kit.env}" ] && . "${OSB_KIT_ENV:-$HOME/.osb-kit.env}"   # local client settings, never in Git
RES=${1:?usage: run_camelk.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]}
MOD=${2:?module dir}
PRJ=${3:?osb project name}
TASK1=${4:-}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$KIT/pi/pi_call.sh"
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
skill_dir() { if [ -d "$KIT/skills/$1" ]; then echo "$KIT/skills/$1"; elif [ -d "$KIT/.pi/skills/$1" ]; then echo "$KIT/.pi/skills/$1"; fi; }
SK=$(skill_dir osb-camelk-route); [ -n "$SK" ] || { echo "skill osb-camelk-route not found under $KIT"; exit 1; }
[ -s "$RES/research.json" ] || { echo "missing $RES/research.json: run pi/run_research.sh first"; exit 1; }
if [ -f "$RES/SHARE_CHECK.json" ] && ! grep -q '"pass": true' "$RES/SHARE_CHECK.json"; then echo "research pack did not pass its check: $RES/SHARE_CHECK.json"; exit 1; fi

echo "== 1 functional tests: generated tests + mocks, synthetic inputs, frozen (pi/run_tests.sh)"
bash "$KIT/pi/run_tests.sh" "$RES" "$MOD" "$PRJ" ${TASK1:+"$TASK1"} || echo "some scenarios have no test case yet (gate K9 will fail)"

echo "== 2 approval"
if [ "${POC:-0}" = 1 ] && ! grep -qiE '^Status:[[:space:]]*approved' "$MOD/FLOW_CARD.md"; then
  # proof-of-concept run without a sign-off: build anyway, mark the card, gate K1 stays FAIL
  sed -i.bak 's/^Status:.*/Status: poc-run (NOT approved)/' "$MOD/FLOW_CARD.md" && rm -f "$MOD/FLOW_CARD.md.bak"
  echo "   POC=1: card not approved, built for the proof of concept only (gate K1 stays FAIL)"
elif ! grep -qiE '^Status:[[:space:]]*approved[[:space:]]*$' "$MOD/FLOW_CARD.md" || ! grep -qE '^Approver:[[:space:]]*[^[:space:]]' "$MOD/FLOW_CARD.md"; then
  echo "card not approved: review $MOD/FLOW_CARD.md against $RES/RESEARCH.md, set 'Status: approved' + Approver + Date, rerun"
  exit 3
fi

LOG="$MOD/.agent-logs"; mkdir -p "$LOG"
echo "== 3 implement (pi)"
PI=(pi --print --no-session --thinking "${PI_THINKING:-high}" --skill "$SK" --tools "read,bash,edit,write"
    --append-system-prompt "$KIT/agents/implementer-camelk.md")
[ -n "${OSB_PI_MODEL:-}" ] && PI+=(--model "$OSB_PI_MODEL")
pi_call "$LOG/implement.out" "$LOG/implement.err" "${PI[@]}" "Use skill osb-camelk-route. Module: $MOD. Approved card: $MOD/FLOW_CARD.md. Research: $RES/RESEARCH.md and $RES/research.json. ${OSB_SRC:+OSB source (read only): $OSB_SRC.} Do steps 3-6 of the skill: fill every TODO(flow-card) in the route, write FlowErrorTest (one test per error scope at least) and the backend stubs, run 'mvn -B ${MVN_ARGS:-} -f $MOD/pom.xml test' and '$PY $SK/scripts/check_camelk.py $MOD' until it prints PASS. Never edit FlowParityTest.java or flow-test.json. Write nothing outside $MOD." || true

echo "== 4 verify"
mvn -B -q ${MVN_ARGS:-} -f "$MOD/pom.xml" test > "$LOG/mvn.out" 2>&1 || true
grep -h "Tests run:" "$LOG/mvn.out" | tail -1 || true
"$PY" "$SK/scripts/check_camelk.py" "$MOD"
KIT_EOF_PI_RUN_CAMELK_SH
mkdir -p "$(dirname "pi/run_domain.sh")"
cat > 'pi/run_domain.sh' <<'KIT_EOF_PI_RUN_DOMAIN_SH'
#!/usr/bin/env bash
# One OSB application (domain) with many projects and proxies: run the per-flow steps for all of them, keep going when
# one flow fails, and keep a status table. Safe to rerun: finished steps are skipped.
#
# Usage: pi/run_domain.sh <osb-app-dir> <stage> [workspace]
#   osb-app-dir  e.g. /e/osb-application (the folder holding the *-prj projects)
# Short form with APP in .osb-kit.env: run_domain.sh <stage> [workspace]
# BATCH_NO=n (with BATCH_SIZE, default 10): the n-th slice of the project list, no names to type; 'batches' lists them.
#   stage        list      projects and proxies found (no agent) -> domain/projects.txt, domain/flows.txt
#                batches   how many batches of BATCH_SIZE projects, with the command for each
#                coverage  which proxies get real Splunk test messages and which synthetic ones (needs SPLUNK_COVERAGE =
#                          CSV of the Splunk "stats count by project, proxy, payload" table) -> domain/COVERAGE.md
#                research  research pack per proxy -> <ws>/research/<project>/<proxy>/   (skips packs that PASS)
#                task1     Splunk test cases for every researched proxy, split by the fields its branches use
#                          (research scenario_dims) -> <ws>/task1/flows/<project>-<proxy>/   (needs EXPORT, MASK_KEY)
#                tests     FUNCTIONAL TESTS per researched proxy (no route needed): generated tests + mocks, real Splunk
#                          cases, synthetic cases from the schema where Splunk has none (pi tester), frozen, catalogue
#                          -> <ws>/modules/<project>/<proxy>/src/test/** + TEST_MATRIX.md
#                scaffold  same module without the tester step
#                build     implement + test + gates for every proxy whose card is approved
#                matrix    mutation check (route broken on purpose) + test matrix per flow and for the domain
#                functional  the whole proof: research -> task1 -> tests -> build -> matrix -> report
#                          (build needs approved cards, or POC=1 for a proof-of-concept run: cards marked, K1 FAIL)
#                estimate  model load per flow (calls, tokens, minutes) from the OSB source size + measured times
#                          (domain/timings.csv); quota via PI_RPM / PI_TPM -> domain/PI_LOAD_ESTIMATE.md
#                time      MEASURED time per pi step (work vs rate-limit waiting) and the projection for TOTAL_FLOWS
#                          (default 450) -> domain/TIME_PROJECTION.md
#                report    domain/FUNCTIONAL_TEST_REPORT.md: inputs, expected outputs, mocks, results, mutations per flow
#                auto      research -> task1 -> tests: the functional test pack for every flow, then stops
#                          (routes: approve the cards, then build and matrix)
#                status    only rewrite <ws>/domain/STATUS.md + status.csv
#   workspace    default: current folder
# PROJECTS matches whole project names: 'a-prj|b-.*' (regex, anchored).
# Env: PI_PAUSE (seconds between two flows in a pi stage, default 30: keeps under the model's rate limit),
#      PI_RETRIES / PI_BACKOFF (retries after a 429, see pi_call.sh),
#      PROJECTS (regex on project names, e.g. 'beneficiary|cancel-'), EXPORT (one Splunk CSV export with all flows of
#      the domain, raw or *.masked.csv), MASK_KEY, MVN_ARGS (e.g. "-s ~/.m2/settings.xml"), MUTATE=0 to skip mutations,
#      MASK_JSON_KEYS ('fieldA fieldB': extra JSON/XML fields to mask in task1, when the residue check finds one),
#      plus the env of run_research.sh / run_camelk.sh (OSB_PI_MODEL, ...).
set -uo pipefail
# local client settings, never in Git: $OSB_KIT_ENV, else ./.osb-kit.env, else ~/.osb-kit.env
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
STAGES='list|batches|coverage|estimate|time|research|task1|tests|scaffold|build|matrix|report|functional|auto|status'
if echo "${1:-}" | grep -Eqx "($STAGES)"; then         # short form: run_domain.sh <stage> [workspace], APP from the env file
  STAGE=$1; WS=${2:-${WS:-.}}; APP=${APP:?set APP in .osb-kit.env or use: run_domain.sh <osb-app-dir> <stage>}
else
  APP=${1:?usage: run_domain.sh [<osb-app-dir>] <stage> [workspace]   stages: $STAGES}
  STAGE=${2:?stage}
  WS=${3:-${WS:-.}}
fi
case "$APP" in *\\*|[A-Za-z]:*) command -v cygpath >/dev/null && APP=$(cygpath -u "$APP");; esac
[ -d "$APP" ] || { echo "OSB application folder not found: $APP (Git Bash: /e/folder, not E:\\folder)"; exit 2; }
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
FILTER=${PROJECTS:-.*}
mkdir -p "$WS/domain"
SK="$KIT/skills/osb-camelk-route/scripts"; [ -d "$SK" ] || SK="$KIT/.pi/skills/osb-camelk-route/scripts"
BATCH=$(for d in "$KIT/../../vdi-osb-migration/bin" "$KIT/bin"; do [ -f "$d/batch_task1.py" ] && echo "$d/batch_task1.py" && break; done)
t1dir() { local d="$WS/task1/flows/$(echo "$1-$2" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//;s/-$//' | tr 'A-Z' 'a-z' | cut -c1-80)"; [ -d "$d/fixtures/parity" ] && echo "$d"; }

timed() {   # timed <project> <proxy> <stage> <command...>: run it, append the duration to domain/timings.csv
  local p=$1 x=$2 st=$3 t0 rc w; shift 3; t0=$(date +%s)
  export PI_WAIT_FILE="$WS/domain/.wait.$$"; : > "$PI_WAIT_FILE"
  "$@"; rc=$?
  w=$(awk '{s+=$1} END{print s+0}' "$PI_WAIT_FILE"); rm -f "$PI_WAIT_FILE"; unset PI_WAIT_FILE
  [ -f "$WS/domain/timings.csv" ] || echo "project,proxy,stage,seconds,waited,exit" > "$WS/domain/timings.csv"
  echo "$p,$x,$st,$(( $(date +%s) - t0 )),$w,$rc" >> "$WS/domain/timings.csv"
  return $rc
}

projects() {   # project folders (sorted), after PROJECTS; BATCH_NO=n keeps the n-th slice of BATCH_SIZE (default 10)
  local all
  all=$(for prj in "$APP"/*/; do p=$(basename "$prj"); [ "${p#.}" != "$p" ] && continue
        echo "$p" | grep -Eqx "($FILTER)" && find "$prj" -type f \( -name '*.proxy' -o -name '*.ProxyService' \) | grep -q . && echo "$p"; done)
  if [ -n "${BATCH_NO:-}" ]; then
    echo "$all" | awk -v n="$BATCH_NO" -v s="${BATCH_SIZE:-10}" 'NR > (n-1)*s && NR <= n*s'
  else echo "$all"; fi
}

flows() {   # "<project> <proxy>" for every proxy file (12c .proxy, sbconfig .ProxyService) in the selected projects
  for p in $(projects); do
    prj="$APP/$p/"
    find "$prj" -type f \( -name '*.proxy' -o -name '*.ProxyService' \) | sort | while read -r f; do
      n=$(basename "$f"); echo "$p ${n%.*}"
    done
  done
}

status() {
  local csv="$WS/domain/status.csv" md="$WS/domain/STATUS.md"
  echo "project,proxy,research,open_questions,test_cases,card,gates,tests" > "$csv"
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; m="$WS/modules/$p/$x"
    rs=-; [ -f "$r/SHARE_CHECK.json" ] && { grep -q '"pass": true' "$r/SHARE_CHECK.json" && rs=PASS || rs=FAIL; }
    oq=-; [ -s "$r/research.json" ] && oq=$("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1], encoding='utf-8')).get('open_questions') or []))" "$r/research.json")
    tc=-; [ -d "$m/src/test/resources/parity" ] && tc=$(find "$m/src/test/resources/parity" -name input.payload | wc -l | tr -d ' ')
    cs=-; [ -f "$m/FLOW_CARD.md" ] && { grep -qiE '^Status:[[:space:]]*approved' "$m/FLOW_CARD.md" && cs=approved || cs=draft; }
    gs=-; ts=-; if [ -f "$m/GATES.json" ]; then grep -q '"result": "PASS"' "$m/GATES.json" && gs=PASS || gs=FAIL
      ts=$("$PY" -c "import json,sys; g=json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}); print(f\"{g.get('tests','-')}/{g.get('failures','-')}F/{g.get('skipped','-')}S\")" "$m/GATES.json"); fi
    echo "$p,$x,$rs,$oq,$tc,$cs,$gs,$ts" >> "$csv"
  done
  { echo "# Domain status: $(basename "$APP")"; echo; echo "Generated $(date '+%F %H:%M'). research = pack check, card = FLOW_CARD.md, gates = check_camelk.py, tests = run/failed/skipped."; echo
    echo "| Project | Proxy | Research | Open questions | Test cases | Card | Gates | Tests |"; echo "|---|---|---|---|---|---|---|---|"
    tail -n +2 "$csv" | awk -F, '{printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6,$7,$8}'
    echo; tail -n +2 "$csv" | awk -F, '{n++; if($3=="PASS")r++; if($5!="-")t++; if($6=="approved")c++; if($7=="PASS")g++} END{printf "%d proxies: %d researched, %d with Splunk test cases, %d cards approved, %d green\n",n,r,t,c,g}'
  } > "$md"
  tail -1 "$md"
}

task1_of() {   # task-1 folder of a proxy: domain batch first, then TASK1_ROOT/<proxy>/task1
  local t; t=$(t1dir "$1" "$2"); [ -z "$t" ] && [ -n "${TASK1_ROOT:-}" ] && [ -d "$TASK1_ROOT/$2/task1" ] && t="$TASK1_ROOT/$2/task1"; echo "$t"
}

do_research() {
  flows | while read -r p x; do
    out="$WS/research/$p/$x"
    if [ -f "$out/SHARE_CHECK.json" ] && grep -q '"pass": true' "$out/SHARE_CHECK.json"; then echo "skip $p/$x (PASS)"; continue; fi
    echo "=== research $p/$x"
    t1=$(task1_of "$p" "$x")
    timed "$p" "$x" research bash -c 'cd "$1" && OUT="research/$2/$3" bash "$4/pi/run_research.sh" "$5/$2" "$3" ${6:+"$6"}' _ "$WS" "$p" "$x" "$KIT" "$APP" "$t1" < /dev/null
    rc=$?
    [ "$rc" = 75 ] && { echo "STOP: the model endpoint refuses every call (quota). Rerun later: finished flows are skipped."; return 75; }
    [ "$rc" = 0 ] || echo "FAILED research $p/$x (continuing)"
    sleep "${PI_PAUSE:-30}"
  done
}

do_task1() {   # one batch over the whole export; scenario fields per flow = what its branches decide on
  [ -n "${EXPORT:-}" ] && [ -f "$EXPORT" ] || { echo "task1 needs EXPORT=<Splunk CSV of the domain> (DOMAIN_RUN.md)"; return 2; }
  [ -n "$BATCH" ] || { echo "batch_task1.py not found (vdi-osb-migration/bin)"; return 2; }
  mkdir -p "$WS/task1"
  { echo "flow,domain,dims"
    flows | while read -r p x; do
      r="$WS/research/$p/$x/research.json"
      d=$([ -s "$r" ] && "$PY" -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')).get('scenario_dims') or []; print(';'.join(['hdr_resource'] + ['body:' + x.lstrip('/') for x in d]) if d else '')" "$r")
      echo "$p/$x,$(basename "$APP"),$d"
    done; } > "$WS/task1/flows.csv"
  case "$EXPORT" in *.masked.csv) am=--already-masked;; *) am=;; esac
  mk=(); for k in ${MASK_JSON_KEYS:-}; do mk+=(--mask-json-key "$k"); done      # extra fields to mask, space separated
  "$PY" "$BATCH" "$EXPORT" -o "$WS/task1" --flows "$WS/task1/flows.csv" $am "${mk[@]}" || {
    echo "some flows need a look: $WS/task1/SUMMARY.md"
    [ -f "$WS/task1/events.masked.csv.report.json" ] && "$PY" -c "import json,sys; r=json.load(open(sys.argv[1], encoding='utf-8'))['residue_check']; [print('   residue:', w) for w in r['where']]" "$WS/task1/events.masked.csv.report.json"
    echo "   fix: MASK_JSON_KEYS='<field> <field>' on the same line, then rerun task1 (arabic-script = Arabic text in a field not masked by name)"; }
}

do_scaffold() {
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; [ -s "$r/research.json" ] || continue
    t1=$(task1_of "$p" "$x")
    "$PY" "$SK/scaffold_camelk.py" "$r" -o "$WS/modules/$p/$x" --project "$p" ${t1:+--parity "$t1/fixtures/parity"} \
      || echo "FAILED scaffold $p/$x (continuing)"
  done
}

do_tests() {
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; [ -s "$r/research.json" ] || continue
    echo "=== tests $p/$x"
    t1=$(task1_of "$p" "$x")
    OSB_SRC="$APP/$p" timed "$p" "$x" tests bash "$KIT/pi/run_tests.sh" "$r" "$WS/modules/$p/$x" "$p" ${t1:+"$t1"} < /dev/null | grep -E "rate limit|^\{" || echo "INCOMPLETE tests $p/$x (continuing)"
    sleep "${PI_PAUSE:-30}"
  done
  "$PY" "$SK/test_matrix.py" --domain "$WS/modules" -o "$WS/domain" > /dev/null || true
}

do_build() {
  flows | while read -r p x; do
    m="$WS/modules/$p/$x"; [ -f "$m/FLOW_CARD.md" ] || continue
    grep -qiE '^Status:[[:space:]]*(approved|poc-run)' "$m/FLOW_CARD.md" || [ "${POC:-0}" = 1 ] || { echo "skip $p/$x (card not approved; POC=1 for a proof-of-concept build)"; continue; }
    if [ -f "$m/GATES.json" ] && "$PY" -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}).get('ok') else 1)" "$m/GATES.json"; then echo "skip $p/$x (tests green)"; continue; fi
    echo "=== build $p/$x"
    t1=$(task1_of "$p" "$x")
    OSB_SRC="$APP/$p" timed "$p" "$x" build bash "$KIT/pi/run_camelk.sh" "$WS/research/$p/$x" "$m" "$p" ${t1:+"$t1"} < /dev/null || echo "NOT GREEN $p/$x (continuing)"
    sleep "${PI_PAUSE:-30}"
  done
}

do_matrix() {   # mutation check on every green module (MUTATE=0 skips it), then the matrices
  flows | while read -r p x; do
    m="$WS/modules/$p/$x"; [ -f "$m/.scaffold.json" ] || continue
    if [ "${MUTATE:-1}" = 1 ] && [ -f "$m/GATES.json" ] && "$PY" -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}).get('ok') else 1)" "$m/GATES.json" && [ ! -f "$m/MUTATION.json" ]; then
      echo "=== mutations $p/$x"; "$PY" "$SK/mutate_route.py" "$m" --mvn "mvn -B -q ${MVN_ARGS:-}" || echo "MUTATION SURVIVED $p/$x: tests too weak (see $m/MUTATION.json)"
    fi
  done
  "$PY" "$SK/test_matrix.py" --domain "$WS/modules" -o "$WS/domain"
}

# pi runs are slow and cost tokens: show the selection, and require ALL=1 for more than 10 flows
case "$STAGE" in research|tests|build|auto|functional)
  n=$(flows | wc -l | tr -d ' ')
  echo "selected: $n proxies (PROJECTS='${PROJECTS:-<all>}')"
  if [ "$n" -gt 10 ] && [ "${ALL:-0}" != 1 ] && [ -z "${BATCH_NO:-}" ]; then
    echo "more than 10 proxies for a pi stage: set PROJECTS='a-prj|b-prj' on the SAME line, or ALL=1 to run them all"; exit 2
  fi;;
esac

case "$STAGE" in
  list) flows | tee "$WS/domain/flows.txt" | awk '{print} END{print NR " proxies"}'
        projects > "$WS/domain/projects.txt"
        echo "$(wc -l < "$WS/domain/projects.txt" | tr -d ' ') projects -> domain/projects.txt, domain/flows.txt" ;;
  batches) np=$(BATCH_NO= projects | wc -l | tr -d ' '); nb=$(( (np + ${BATCH_SIZE:-10} - 1) / ${BATCH_SIZE:-10} ))
        echo "$np projects = $nb batches of ${BATCH_SIZE:-10} projects. Run them one after the other:"
        for b in $(seq 1 "$nb"); do echo "  BATCH_NO=$b bash $KIT/pi/run_domain.sh functional    # $(BATCH_NO=$b projects | paste -sd' ' - | cut -c1-90)"; done ;;
  coverage)
    [ -n "${SPLUNK_COVERAGE:-}" ] && [ -f "$SPLUNK_COVERAGE" ] || { echo "coverage needs SPLUNK_COVERAGE=<csv of the Splunk payload table>"; exit 2; }
    "$PY" "$KIT/skills/osb-to-camel/scripts/osb_inventory.py" "$APP" -o "$WS/domain/inventory" > /dev/null
    "$PY" "$(dirname "$BATCH")/domain_coverage.py" "$WS/domain/inventory" "$SPLUNK_COVERAGE" -o "$WS/domain/COVERAGE.md" ;;
  research) do_research; rc=$?; status; exit $rc ;;
  task1) do_task1; status ;;
  tests) do_tests; status ;;
  scaffold) do_scaffold; status ;;
  build) do_build; status ;;
  matrix) do_matrix; status ;;
  auto) do_research; do_task1; do_tests; status
        echo "functional test packs: modules/<project>/<proxy>/src/test + TEST_MATRIX.md; domain catalogue: domain/TEST_MATRIX.md" ;;
  estimate)
    [ -d "$WS/domain/inventory/flows" ] || "$PY" "$KIT/skills/osb-to-camel/scripts/osb_inventory.py" "$APP" -o "$WS/domain/inventory" > /dev/null
    "$PY" "$(dirname "$BATCH")/estimate_pi_load.py" "$WS/domain/inventory" "$APP" --coverage "$WS/domain/coverage.csv" \
      --timings "$WS/domain/timings.csv" --rpm "${PI_RPM:-20}" --tpm "${PI_TPM:-200000}" -o "$WS/domain/PI_LOAD_ESTIMATE.md" ;;
  time) "$PY" "$(dirname "$BATCH")/time_projection.py" "$WS/domain/timings.csv" --flows "${TOTAL_FLOWS:-450}" \
          --coverage "$WS/domain/coverage.csv" -o "$WS/domain/TIME_PROJECTION.md" ;;
  report) status > /dev/null; "$PY" "$SK/domain_report.py" "$WS" ;;
  functional) do_research || { status > /dev/null; exit 75; }; do_task1; do_tests; do_build; do_matrix; status > /dev/null; "$PY" "$SK/domain_report.py" "$WS" ;;
  status) status ;;
  *) echo "unknown stage: $STAGE"; exit 2 ;;
esac
KIT_EOF_PI_RUN_DOMAIN_SH
mkdir -p "$(dirname "pi/run_flow.sh")"
cat > 'pi/run_flow.sh' <<'KIT_EOF_PI_RUN_FLOW_SH'
#!/usr/bin/env bash
# Agentic run of one OSB flow on the pi coding agent (https://pi.dev).
# Pi has no sub-agents, so each role is a separate `pi -p --no-session` process: a fresh context per role is exactly
# the independence the tester and reviewer need. Deterministic checks sit between the roles.
#
# Usage: pi/run_flow.sh <osb-project-dir> <flow> <module-dir> [--from analyse|test|implement|verify|review]
# Order: analyse -> gate A (human) -> TEST (fresh context, no src/main yet) -> implement -> verify (fix loops) -> review
# Env:   OSB_PI_MODEL (model pattern for `pi --model`; not PI_MODEL, which pi itself sets), PI_THINKING (default high),
#        MAX_FIX_LOOPS (default 3), KIT (default: the directory above this script)
set -euo pipefail

PROJECT=${1:?usage: run_flow.sh <osb-project-dir> <flow> <module-dir> [--from phase]}
FLOW=${2:?flow name}
MODULE=${3:?module dir}
FROM=analyse
[ "${4:-}" = "--from" ] && FROM=${5:?phase}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
OUT="migration/$FLOW"
LOG="$OUT/agent-logs"
MAX_FIX_LOOPS=${MAX_FIX_LOOPS:-3}
mkdir -p "$LOG"

# skills: git layout (<kit>/skills/<name>) or paste-installed workspace (<kit>/.pi/skills/<name>)
skill_dir() { if [ -d "$KIT/skills/$1" ]; then echo "$KIT/skills/$1"; elif [ -d "$KIT/.pi/skills/$1" ]; then echo "$KIT/.pi/skills/$1"; fi; }
PI_BASE=(pi --print --no-session --thinking "${PI_THINKING:-high}")
for sk in osb-to-camel camel-migration-verification; do d=$(skill_dir "$sk"); [ -n "$d" ] && PI_BASE+=(--skill "$d"); done
[ -n "${OSB_PI_MODEL:-}" ] && PI_BASE+=(--model "$OSB_PI_MODEL")

# role <name> <tools> <prompt>: one fresh pi process with the role prompt appended to the system prompt
role() {
  local name=$1 tools=$2 prompt=$3 stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  echo ">> $name" >&2
  "${PI_BASE[@]}" --tools "$tools" --append-system-prompt "$KIT/agents/$name.md" "$prompt" \
    > "$LOG/$stamp-$name.out" 2> "$LOG/$stamp-$name.err"
  echo "$LOG/$stamp-$name.out"
}

# fingerprint of a directory tree (detects edits outside a role's lane; works without git)
# sha1sum on Git Bash/Linux, shasum on macOS
SHA=$(command -v sha1sum || command -v shasum)
fp() { [ -d "$1" ] && find "$1" -type f -print0 | sort -z | xargs -0 "$SHA" 2>/dev/null | "$SHA" | cut -c1-16 || echo none; }

approved() { grep -Eq '^\| \*\*Status\*\* \| *approved' "$OUT/FLOW_CARD.md" 2>/dev/null; }

phase_reached() { case "$FROM" in analyse) return 0;; test) [ "$1" != analyse ];; implement) [[ "$1" =~ ^(implement|verify|review)$ ]];;
                  verify) [[ "$1" =~ ^(verify|review)$ ]];; review) [ "$1" = review ];; esac; }

# ---------------------------------------------------------------- S0 analyse
if phase_reached analyse; then
  role analyst "read,bash,edit,write" \
    "Use skill osb-to-camel Steps 0 and 1. OSB export: $PROJECT. Flow: $FLOW. Run the inventory into migration/osb-inventory, scaffold and complete $OUT/FLOW_CARD.md from the real OSB files. Status draft. End with a 5-line summary and the BLOCKING open items." > /dev/null
  [ -f "$OUT/FLOW_CARD.md" ] || { echo "analyst wrote no card"; exit 1; }
fi

# ---------------------------------------------------------------- S1 human gate A
if ! approved; then
  echo "STOP: $OUT/FLOW_CARD.md is not approved. A human sets '| **Status** | approved' plus the approver, then:"
  echo "      pi/run_flow.sh $PROJECT $FLOW $MODULE --from test"
  exit 0
fi

TESTS_FP() { fp "$MODULE/src/test"; }
MAIN_FP()  { fp "$MODULE/src/main"; }

# ---------------------------------------------------------------- S2 test (tests first: fresh context, no route exists yet)
if phase_reached test; then
  before=$(MAIN_FP)
  role tester "read,bash,edit,write" \
    "Write the test suite for flow $FLOW from the approved card $OUT/FLOW_CARD.md and the OSB evidence in $PROJECT, following skill osb-to-camel Step 3 and skill camel-migration-verification. There is NO route yet: tests go to $MODULE/src/test and must compile against the class and endpoint names the card fixes (run 'mvn -q -f $MODULE/pom.xml test-compile'); they are expected to FAIL for the right reason until the route exists. Recorded cases: if $MODULE/src/test/resources/parity exists, one parameterised test per case; expected-output.xml files there come from the golden runner and must not be regenerated. Register every expected file you add in $MODULE/src/test/resources/golden/MANIFEST.csv with its source (osb-recording | original-transform | osb-test-console | card-rule | source-derived; the last two need reason and approved_by). Do not create or edit $MODULE/src/main. Report honestly." > /dev/null
  [ "$(MAIN_FP)" = "$before" ] || { echo "VIOLATION: tester changed $MODULE/src/main"; exit 1; }
fi

# ---------------------------------------------------------------- S3 implement (makes the existing tests pass)
if phase_reached implement; then
  before=$(TESTS_FP)
  role implementer "read,bash,edit,write" \
    "Implement the approved card $OUT/FLOW_CARD.md with skill osb-to-camel Step 2 into Maven module $MODULE. OSB sources: $PROJECT. The tests under $MODULE/src/test already exist and define the contract: make 'mvn -q -f $MODULE/pom.xml verify' pass. Do not create, edit or delete anything under $MODULE/src/test or $OUT/FLOW_CARD.md; if a test is wrong, write $OUT/TEST_DISPUTE.md with evidence from the OSB files and stop." > /dev/null
  [ "$(TESTS_FP)" = "$before" ] || { echo "VIOLATION: implementer changed $MODULE/src/test"; exit 1; }
  [ -f "$OUT/TEST_DISPUTE.md" ] && { echo "STOP: test dispute raised, a fresh tester or a human decides ($OUT/TEST_DISPUTE.md)"; exit 1; }
fi

# ---------------------------------------------------------------- S4 verify + fix loop
if phase_reached verify; then
  loop=0
  until "$KIT/tools/verify_flow.sh" "$MODULE" "$FLOW"; do
    loop=$((loop + 1))
    if [ "$loop" -gt "$MAX_FIX_LOOPS" ]; then
      echo "BLOCKED after $MAX_FIX_LOOPS fix loops; see $OUT/verify-report.json"; exit 1
    fi
    before=$(TESTS_FP)
    role implementer "read,bash,edit,write" \
      "Fix loop $loop for flow $FLOW. Read $OUT/verify-report.json and the logs next to it. Change production code under $MODULE/src/main only. If a test is wrong, write $OUT/TEST_DISPUTE.md with evidence from the OSB files and stop." > /dev/null
    [ "$(TESTS_FP)" = "$before" ] || { echo "VIOLATION: implementer changed tests in fix loop $loop"; exit 1; }
    [ -f "$OUT/TEST_DISPUTE.md" ] && { echo "STOP: test dispute raised, a fresh tester or a human decides ($OUT/TEST_DISPUTE.md)"; exit 1; }
  done
fi

# ---------------------------------------------------------------- S5 review (read-only tools; the script writes the files)
if phase_reached review; then
  out=$(role reviewer "read,grep,find,ls" \
    "Review flow $FLOW: card $OUT/FLOW_CARD.md, module $MODULE, gates $OUT/verify-report.json, OSB sources $PROJECT. Print REVIEW.md content, then a line containing only =====RECORD=====, then MIGRATION_RECORD.md content.")
  awk '/^=====RECORD=====$/{exit} {print}' "$out" > "$OUT/REVIEW.md"
  awk 'f{print} /^=====RECORD=====$/{f=1}' "$out" > "$OUT/MIGRATION_RECORD.md"
  [ -s "$OUT/MIGRATION_RECORD.md" ] || echo "WARNING: reviewer output had no record section; see $out"
  if grep -q "BLOCKER" "$OUT/REVIEW.md"; then echo "Review has BLOCKER findings: $OUT/REVIEW.md"; exit 1; fi
fi

echo "DONE for $FLOW: gates green, review without BLOCKER. Next: human sign-off (gate B), then the UAT shadow run (TESTING.md L6)."
KIT_EOF_PI_RUN_FLOW_SH
mkdir -p "$(dirname "pi/run_research.sh")"
cat > 'pi/run_research.sh' <<'KIT_EOF_PI_RUN_RESEARCH_SH'
#!/usr/bin/env bash
# Research pack for ONE proxy on the pi coding agent: facts (script) -> questionnaire (pi) -> share check (script).
# The OSB source never leaves the machine; only research/<proxy>/ is shared, and only after the check passes.
#
# Usage: pi/run_research.sh <osb-project-dir> <proxy> [task1-dir]
# Env:   OUT (default research/<proxy>; run_domain.sh uses research/<project>/<proxy>), OSB_PI_MODEL (model pattern for
#        `pi --model`), PI_THINKING (default high), KIT, PYTHON
set -euo pipefail
[ -f "${OSB_KIT_ENV:-$HOME/.osb-kit.env}" ] && . "${OSB_KIT_ENV:-$HOME/.osb-kit.env}"   # local client settings, never in Git
PROJECT=${1:?usage: run_research.sh <osb-project-dir> <proxy> [task1-dir]}
PROXY=${2:?proxy name}
TASK1=${3:-}
case "$PROJECT" in *\\*|[A-Za-z]:*) command -v cygpath >/dev/null && PROJECT=$(cygpath -u "$PROJECT");; esac   # Windows path (quoted) -> /e/...
case "$PROXY" in */*|*\\*) echo "2nd argument must be the proxy name (e.g. sample-adjustment), not a path. usage: run_research.sh <osb-project-dir> <proxy> [task1-dir]"; exit 2;; esac
[ -e "$PROJECT" ] || { echo "OSB project not found: $PROJECT  (Git Bash: write /e/folder/project, not E:\\folder\\project)"; exit 2; }
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$KIT/pi/pi_call.sh"
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
OUT=${OUT:-research/$PROXY}
LOG="$OUT/agent-logs"
skill_dir() { if [ -d "$KIT/skills/$1" ]; then echo "$KIT/skills/$1"; elif [ -d "$KIT/.pi/skills/$1" ]; then echo "$KIT/.pi/skills/$1"; fi; }
SK=$(skill_dir osb-research); [ -n "$SK" ] || { echo "skill osb-research not found under $KIT"; exit 1; }
mkdir -p "$LOG"

echo "== 1 facts"
"$PY" "$SK/scripts/research_pack.py" "$PROJECT" "$PROXY" -o "$OUT" ${TASK1:+--scenarios "$TASK1/traces/scenarios.json"}

SHA=$(command -v sha1sum || command -v shasum)
fp() { find "$1" -type f -print0 | sort -z | xargs -0 "$SHA" 2>/dev/null | "$SHA" | cut -c1-16; }
before=$(fp "$PROJECT")

# all source files of this proxy in ONE file, so pi reads them with one call instead of one call per file (rate limit);
# it lies next to (not inside) the shareable folder and is deleted after the research
BUNDLE="$OUT.sources.txt"
while IFS= read -r f; do [ -n "$f" ] && [ -f "$PROJECT/$f" ] && { printf '\n===== FILE: %s =====\n' "$f"; cat "$PROJECT/$f"; }; done < "$OUT/SOURCES.txt" > "$BUNDLE"
trap 'rm -f "$BUNDLE"' EXIT

echo "== 2 questionnaire (pi)"
PI=(pi --print --no-session --thinking "${PI_THINKING:-high}" --skill "$SK" --tools "read,bash,write"
    --append-system-prompt "$KIT/agents/researcher.md")
[ -n "${OSB_PI_MODEL:-}" ] && PI+=(--model "$OSB_PI_MODEL")
rc=0; pi_call "$LOG/research.out" "$LOG/research.err" "${PI[@]}" "Use skill osb-research. OSB export: $PROJECT. Proxy: $PROXY. Today is $(date +%F). facts.json and SOURCES.txt are already in $OUT (step 1 done). All files of SOURCES.txt are concatenated in $BUNDLE: read that ONE file first (one read instead of one per file); open other files only for references it does not contain. Do steps 2-5: read the sources, answer every question of references/questions.md into $OUT/RESEARCH.md (assets/RESEARCH_TEMPLATE.md) and $OUT/research.json (assets/research.schema.json), run '$PY $SK/scripts/research_check.py $OUT' until it prints PASS. Write nothing outside $OUT." || rc=$?
[ "$rc" = 75 ] && exit 75
for try in 2; do   # pi sometimes ends without writing the files: one more attempt, logs kept per attempt
  [ -s "$OUT/RESEARCH.md" ] && [ -s "$OUT/research.json" ] && break
  echo "   pi wrote no answer files, attempt $try (see $LOG/research.err)"
  cp "$LOG/research.err" "$LOG/research.attempt1.err" 2>/dev/null || true
  pi_call "$LOG/research.out" "$LOG/research.err" "${PI[@]}" "Use skill osb-research. A previous attempt ended without writing RESEARCH.md and research.json: write both files. OSB export: $PROJECT. Proxy: $PROXY. Today is $(date +%F). facts.json and SOURCES.txt are already in $OUT (step 1 done). All files of SOURCES.txt are concatenated in $BUNDLE: read that ONE file first (one read instead of one per file); open other files only for references it does not contain. Do steps 2-5: read the sources, answer every question of references/questions.md into $OUT/RESEARCH.md (assets/RESEARCH_TEMPLATE.md) and $OUT/research.json (assets/research.schema.json), run '$PY $SK/scripts/research_check.py $OUT' until it prints PASS. Write nothing outside $OUT." || true
done

[ "$(fp "$PROJECT")" = "$before" ] || { echo "VIOLATION: the OSB export was changed during research"; exit 1; }

echo "== 3 share check"
for f in RESEARCH.md research.json; do [ -s "$OUT/$f" ] || { echo "missing $OUT/$f (see $LOG/research.err)"; exit 1; }; done
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); m=[k for k in ('proxy','entry','branches','outputs','transforms','backends','errors','logs','open_questions') if k not in d]; sys.exit('research.json misses: '+', '.join(m) if m else 0)" "$OUT/research.json"
rm -rf "$OUT.agent-logs"; mv "$LOG" "$OUT.agent-logs"     # agent logs may quote source: they stay on the machine, outside the shared folder
"$PY" "$SK/scripts/research_check.py" "$OUT" || { echo "NOT shareable yet: fix the lines above (logs: $OUT.agent-logs)"; exit 1; }
echo "share: $OUT/RESEARCH.md research.json facts.json SHARE_CHECK.json"
KIT_EOF_PI_RUN_RESEARCH_SH
mkdir -p "$(dirname "pi/run_tests.sh")"
cat > 'pi/run_tests.sh' <<'KIT_EOF_PI_RUN_TESTS_SH'
#!/usr/bin/env bash
# Functional test creation for ONE proxy, no route needed: research pack + Splunk cases -> generated tests and mocks
# -> synthetic inputs for scenarios Splunk cannot supply (pi tester) -> frozen test pack + catalogue.
#
# Usage: pi/run_tests.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]
# Env:   OSB_SRC (OSB project folder: the tester reads the message schema there), OSB_PI_MODEL, KIT, PYTHON,
#        PI_TESTER=0 (skip the synthetic messages, e.g. when the model quota is short), PI_TESTER_THINKING (default low)
# Result: <module>/src/test/** (FlowParityTest + flow-test.json + real and synthetic case folders, frozen),
#         <module>/TEST_MATRIX.md (catalogue: every scenario, its inputs and expected outputs). Exit 1 if a scenario has no case.
set -euo pipefail
[ -f "${OSB_KIT_ENV:-$HOME/.osb-kit.env}" ] && . "${OSB_KIT_ENV:-$HOME/.osb-kit.env}"   # local client settings, never in Git
RES=${1:?usage: run_tests.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]}
MOD=${2:?module dir}
PRJ=${3:?osb project name}
TASK1=${4:-}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$KIT/pi/pi_call.sh"
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
SK=$(for d in "$KIT/skills/osb-camelk-route" "$KIT/.pi/skills/osb-camelk-route"; do [ -d "$d" ] && echo "$d" && break; done)
[ -n "$SK" ] || { echo "skill osb-camelk-route not found under $KIT"; exit 1; }
[ -s "$RES/research.json" ] || { echo "missing $RES/research.json: run pi/run_research.sh first"; exit 1; }

echo "== 1 generated tests + mocks (script)"
"$PY" "$SK/scripts/scaffold_camelk.py" "$RES" -o "$MOD" --project "$PRJ" ${TASK1:+--parity "$TASK1/fixtures/parity"}

echo "== 2 synthetic inputs where Splunk has none (script from the schema first, pi tester only for the rest)"
LOG="$MOD/.agent-logs"; mkdir -p "$LOG"
"$PY" "$SK/scripts/check_camelk.py" "$MOD" --no-surefire > /dev/null || true
UNCOV=$("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1]))['gates']['K9_scenarios_covered']['uncovered']))" "$MOD/GATES.json")
if [ "$UNCOV" != 0 ] && [ -n "${OSB_SRC:-}" ] && [ -d "$OSB_SRC" ]; then
  # first without an AI: fake-value messages built from the flow's schema (no model calls, no quota)
  "$PY" "$SK/scripts/synth_from_schema.py" "$MOD" "$OSB_SRC" --research "$RES/research.json" || true
  "$PY" "$SK/scripts/check_camelk.py" "$MOD" --no-surefire > /dev/null || true
  UNCOV=$("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1]))['gates']['K9_scenarios_covered']['uncovered']))" "$MOD/GATES.json")
fi
if [ "$UNCOV" != 0 ] && [ "${PI_TESTER:-1}" = 0 ]; then
  echo "   PI_TESTER=0: $UNCOV scenario(s) stay without a test case (gate K9 shows them)"
elif [ "$UNCOV" != 0 ]; then
  PT=(pi --print --no-session --thinking "${PI_TESTER_THINKING:-low}" --tools "read,bash,write" --append-system-prompt "$KIT/agents/tester-camelk.md")
  [ -n "${OSB_PI_MODEL:-}" ] && PT+=(--model "$OSB_PI_MODEL")
  pi_call "$LOG/tester.out" "$LOG/tester.err" "${PT[@]}" "Module: $MOD. Research: $RES/RESEARCH.md. ${OSB_SRC:+OSB source (read only, for the message schema): $OSB_SRC.} Write synthetic case folders for the $UNCOV scenario_mapping rows of $MOD/src/test/resources/flow-test.json that have no case yet (check: $PY $SK/scripts/check_camelk.py $MOD --no-surefire, gate K9). Fake values only. Write nothing outside $MOD/src/test/resources/parity." || true
else
  echo "   every scenario already has a real Splunk case"
fi

echo "== 3 freeze + catalogue"
"$PY" "$SK/scripts/scaffold_camelk.py" "$RES" -o "$MOD" --project "$PRJ" --freeze-synthetic
"$PY" "$SK/scripts/check_camelk.py" "$MOD" --no-surefire > /dev/null || true
"$PY" "$SK/scripts/test_matrix.py" "$MOD" > /dev/null || true
"$PY" - "$MOD" <<'PY'
import json, sys
from pathlib import Path
m = Path(sys.argv[1]); par = m / "src/test/resources/parity"
real = sum(1 for p in par.glob("*/*/*/input.payload") if "-synthetic" not in p.parts[-4])
syn = sum(1 for p in par.glob("*-synthetic/*/*/input.payload"))
g = json.loads((m / "GATES.json").read_text())["gates"]["K9_scenarios_covered"]
cfg = json.loads((m / "src/test/resources/flow-test.json").read_text())
print(json.dumps({"scenarios": len(cfg["scenario_mapping"]), "real_cases": real, "synthetic_cases": syn,
                  "uncovered": g["uncovered"], "outputs": sorted(cfg["outputs"]), "catalogue": str(m / "TEST_MATRIX.md")}))
sys.exit(0 if g["ok"] else 1)
PY
KIT_EOF_PI_RUN_TESTS_SH
mkdir -p "$(dirname "pi/PI_SETUP.md")"
cat > 'pi/PI_SETUP.md' <<'KIT_EOF_PI_PI_SETUP_MD'
# Running the kit on the pi coding agent

Checked against pi's own documentation on 2026-10-06 (earendil-works/pi: `docs/skills.md`, `cli.md`,
`prompt-templates.md`, `configuration.md`, `cli-integration.md`). Pi implements the Agent Skills specification, loads
`AGENTS.md` from the working directory and its parents, and has **no built-in sub-agents** ("skips features like
sub-agents and plan mode"). The agentic mode below is therefore one fresh pi process per role, driven by a script.

## 1. Install (runner machine or container)

- Node.js 22.19 or newer, then `curl -fsSL https://pi.dev/install.sh | sh`
  (or `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`).
- Model access: `/login` inside pi for a built-in provider, or the customer's own endpoint configured as a pi provider
  (see pi `docs/providers.md`). Check with `pi auth check --provider <name>`.
- For the gates: Java 21, Maven 3.9, Python 3.10+, Docker or Podman.
- Run pi in a **disposable container or VM** with the repository checked out and no production credentials: pi's
  default tools include `bash`, `edit` and `write`.

## 2. Put the files where pi finds them

| Kit file | Location in the migration repository |
|---|---|
| `AGENTS.md` | repository root (pi loads it from the working directory and its parents; no trust needed) |
| `skills/osb-to-camel/`, `skills/camel-migration-verification/` | `.pi/skills/` (project) or `~/.pi/agent/skills/` (user); `.agents/skills/` also works |
| `pi/prompts/*.md` | `.pi/prompts/` (project) or `~/.pi/agent/prompts/` |
| `agents/`, `tools/`, `pi/run_flow.sh` | repository root, as in the kit |

Project `.pi/` content loads only after project trust: answer the trust prompt once, or pass `-a` / `--approve` for a
single run. `pi/run_flow.sh` passes the skills explicitly with `--skill`, so it works without trust.

Check: start `pi` in the repository; the startup header lists `AGENTS.md`, the two skills and the prompt templates.
`/skill:osb-to-camel` must resolve.

## 3. Interactive use (one engineer, step by step)

```text
/osb-analyse osb-src/order-event-prj order-event     # card, then a human approves it
/osb-implement order-event modules/order-event
/new                                                   # fresh session: the tester must not see the implementer
/osb-test order-event modules/order-event osb-src/order-event-prj
/osb-verify modules/order-event order-event
/new
/osb-review order-event modules/order-event osb-src/order-event-prj
```

You can also force a skill directly: `/skill:osb-to-camel inventory osb-src/order-event-prj`.

## 4. Agentic mode (unattended between the two human gates)

```bash
export OSB_PI_MODEL="<model pattern for pi --model>"     # optional; pi's default model otherwise
pi/run_flow.sh osb-src/order-event-prj order-event modules/order-event
#   -> analyst writes the card, the script STOPS at gate A
#   human approves the card (| **Status** | approved ... + name)
pi/run_flow.sh osb-src/order-event-prj order-event modules/order-event --from implement
#   -> implementer -> tester (fresh process) -> gates G1-G8 -> up to 3 fix loops -> reviewer (read-only tools)
```

What the script enforces outside the model:

| Rule | How |
|---|---|
| Fresh context per role | `pi --print --no-session`, one process per role, role prompt via `--append-system-prompt agents/<role>.md` |
| Implementer never edits tests | fingerprint of `src/test` before/after each implementer run; any change = VIOLATION, stop |
| Tester never edits production code | fingerprint of `src/main` before/after |
| Reviewer cannot write | `--tools read,grep,find,ls`; the script writes `REVIEW.md` and `MIGRATION_RECORD.md` from its output |
| Acceptance is not the model's opinion | `tools/verify_flow.sh` gates G1-G8 |
| Bounded effort | `MAX_FIX_LOOPS` (default 3), then BLOCKED |
| Audit trail | every role's stdout/stderr under `migration/<flow>/agent-logs/` |

For a structured audit log use `--mode json` instead of `--print` in `PI_BASE` (JSONL events per run). For a service
that drives pi programmatically, pi's RPC mode or TypeScript SDK replace the shell script; the roles and gates stay the
same.

## 5. Batch

Loop over the flows of a tier with the same script; keep `migration/STATUS.md`. Stop the batch after three flows in a row
end in BLOCKED for the same reason: fix the skill's mapping tables first, then continue.
KIT_EOF_PI_PI_SETUP_MD
mkdir -p "$(dirname "pi/VDI_RUNBOOK.md")"
cat > 'pi/VDI_RUNBOOK.md' <<'KIT_EOF_PI_VDI_RUNBOOK_MD'
# Running the kit on the client VDI

For a locked-down client VDI: possibly Windows, no admin rights, a corporate proxy, an internal Maven/npm mirror, the
customer's own model endpoint, maybe no Docker. Pi facts below are from pi's docs (`windows.md`, `models.md`,
`environment-variables.md`, checked 2026-10-06).

## 0. Ask the VDI owner first (one mail)

| Need | Why | If refused |
|---|---|---|
| Node.js 22.19+ and permission to install the npm package `@earendil-works/pi-coding-agent` (from the internal npm mirror) | pi itself | no agent: the deterministic tools and gates still run |
| Git for Windows (Git Bash) or WSL | pi's `bash` tool on Windows, and the kit scripts | WSL alone also works |
| JDK 21, Maven 3.9, Python 3.10+ | build, gates, inventory | none: required |
| Maven `settings.xml` pointing at the internal mirror (Nexus/Artifactory) | dependencies, Camel, Testcontainers | none: required |
| Model endpoint URL + key (OpenAI-, Anthropic- or Google-compatible) and that sending OSB source to it is approved | the agent's model | no agent |
| Docker/Podman on the VDI | gate G5 (Artemis in Testcontainers) | run G5 on the Jenkins agent only |
| A file-transfer path for `osb-camel-agent-kit.zip` and the OSB export | getting files in | none |

## 1. Copy in and lay out (Git Bash or WSL)

```bash
mkdir -p ~/work/osb-migration && cd ~/work/osb-migration
git init
unzip /path/to/osb-camel-agent-kit.zip
cp -r osb-camel-agent-kit/{AGENTS.md,agents,tools,pi} .
mkdir -p .pi/skills .pi/prompts osb-src modules migration
cp -r osb-camel-agent-kit/skills/* .pi/skills/
cp osb-camel-agent-kit/pi/prompts/*.md .pi/prompts/
chmod +x pi/*.sh tools/*.sh tools/*.py
unzip /path/to/order-event-prj.zip -d osb-src/        # the OSB export
```

## 2. Install pi without leaving the network

```bash
npm config set registry https://<internal-npm-mirror>/   # or the proxy settings the VDI owner gives you
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
pi --version
```

Keep pi quiet towards the internet (government client):

```bash
export PI_OFFLINE=1            # no automatic network activity, no catalog refresh
export PI_SKIP_VERSION_CHECK=1 # no pi.dev version request
export PI_TELEMETRY=0
```

On native Windows pi uses Git Bash for its `bash` tool. Check inside pi with `!printf 'Bash is working\n'`. If Git Bash
is in a non-standard place, set `"shellPath"` in `~/.pi/agent/settings.json` (double the backslashes).

## 3. Point pi at the customer's model endpoint

`~/.pi/agent/models.json` (example for an OpenAI-compatible gateway; use the API type the endpoint actually speaks):

```json
{
  "providers": {
    "client-gateway": {
      "baseUrl": "https://<customer-llm-gateway>/v1",
      "api": "openai-completions",
      "apiKey": "$CLIENT_LLM_API_KEY",
      "models": [ { "id": "<model-id>" } ]
    }
  }
}
```

```bash
export CLIENT_LLM_API_KEY=...            # from the customer's secret store, never in a file in the repo
export OSB_PI_MODEL="<model-id>"       # used by pi/run_flow.sh (not PI_MODEL: pi sets that itself)
pi                                     # trust the project once (or pi --approve: .pi/prompts and .pi/skills load only when trusted), then /model should list <model-id>
```

## 4. Preflight

```bash
pi/preflight.sh https://<customer-llm-gateway>/v1
```

Fix every FAIL. A WARN on Docker means gate G5 runs only on the Jenkins agent.

## 5. Run

Smoke test without the model (deterministic step only):

```bash
python .pi/skills/osb-to-camel/scripts/osb_inventory.py osb-src/order-event-prj -o migration/osb-inventory
```

Interactive (inside pi):

```text
/osb-analyse osb-src/order-event-prj order-event
   (approve migration/order-event/FLOW_CARD.md)
/osb-implement order-event modules/order-event
/new
/osb-test order-event modules/order-event osb-src/order-event-prj
/osb-verify modules/order-event order-event
/new
/osb-review order-event modules/order-event osb-src/order-event-prj
```

Agentic (Git Bash/WSL terminal, not inside pi):

```bash
pi/run_flow.sh osb-src/order-event-prj order-event modules/order-event
#   approve the card, then:
pi/run_flow.sh osb-src/order-event-prj order-event modules/order-event --from implement
```

Without Docker on the VDI the gate report shows `G5 NOT_RUN`, so the run ends NOT GREEN by design. Push the branch;
the Jenkins job (`ci/Jenkinsfile.groovy`) runs all gates on an agent with Docker, and that report is the one that counts.

## 6. Data and session hygiene

- OSB sources, sample messages and generated code stay on the VDI and in the client Git; only the model endpoint
  receives prompt content, so its approval (step 0) is a prerequisite.
- Mask personal data in sample messages before they enter `src/test/resources` (TESTING.md §4).
- Agent logs (`migration/<flow>/agent-logs/`) contain prompts and outputs: keep them in the client repository, not on
  personal drives.
- `run_flow.sh` runs pi with `--no-session`, so no session files accumulate in `~/.pi/agent/sessions`.
KIT_EOF_PI_VDI_RUNBOOK_MD
mkdir -p "$(dirname "pi/prompts/osb-analyse.md")"
cat > 'pi/prompts/osb-analyse.md' <<'KIT_EOF_PI_PROMPTS_OSB_ANALYSE_MD'
---
description: OSB flow -> inventory + flow card (analyst role, no code)
argument-hint: "<osb-project-dir> <flow>"
---
Act as the analyst defined in agents/analyst.md and follow AGENTS.md.
Use skill osb-to-camel Steps 0 and 1 on the OSB export $1 for flow $2.
Write migration/$2/FLOW_CARD.md with Status draft, then stop and list the BLOCKING open items.
KIT_EOF_PI_PROMPTS_OSB_ANALYSE_MD
mkdir -p "$(dirname "pi/prompts/osb-camelk.md")"
cat > 'pi/prompts/osb-camelk.md' <<'KIT_EOF_PI_PROMPTS_OSB_CAMELK_MD'
---
description: "Approved flow card + research pack -> Camel K YAML route + tests, until the gates pass"
argument-hint: "<module-dir> <research-dir>"
---
Act as the implementer defined in agents/implementer-camelk.md and follow AGENTS.md.
Use skill osb-camelk-route on module $1 (approved card $1/FLOW_CARD.md) with research pack $2.
Do steps 3-6 of the skill until check_camelk.py prints PASS, then give the five-line report.
KIT_EOF_PI_PROMPTS_OSB_CAMELK_MD
mkdir -p "$(dirname "pi/prompts/osb-implement.md")"
cat > 'pi/prompts/osb-implement.md' <<'KIT_EOF_PI_PROMPTS_OSB_IMPLEMENT_MD'
---
description: Approved flow card -> Camel on Spring Boot code (implementer role)
argument-hint: "<flow> <module-dir>"
---
Act as the implementer defined in agents/implementer.md and follow AGENTS.md.
Refuse unless migration/$1/FLOW_CARD.md says Status approved with an approver.
Implement it with skill osb-to-camel Step 2 into Maven module $2. Never touch $2/src/test.
Finish when `mvn -q -DskipTests -f $2/pom.xml package` passes.
KIT_EOF_PI_PROMPTS_OSB_IMPLEMENT_MD
mkdir -p "$(dirname "pi/prompts/osb-research.md")"
cat > 'pi/prompts/osb-research.md' <<'KIT_EOF_PI_PROMPTS_OSB_RESEARCH_MD'
---
description: "OSB proxy -> shareable research pack (no code, no hosts, no data)"
argument-hint: "<osb-project-dir> <proxy> [task1-dir]"
---
Act as the researcher defined in agents/researcher.md and follow AGENTS.md.
Use skill osb-research on the OSB export $1 for proxy $2 (scenarios from $3/traces/scenarios.json if given).
Write research/$2/RESEARCH.md and research/$2/research.json, run the share check until it passes, then give the five-line report.
KIT_EOF_PI_PROMPTS_OSB_RESEARCH_MD
mkdir -p "$(dirname "pi/prompts/osb-review.md")"
cat > 'pi/prompts/osb-review.md' <<'KIT_EOF_PI_PROMPTS_OSB_REVIEW_MD'
---
description: Evidence-only review + migration record (reviewer role; start a NEW session first)
argument-hint: "<flow> <module-dir> <osb-project-dir>"
---
Act as the reviewer defined in agents/reviewer.md. Do not edit code or tests.
Review flow $1 (card migration/$1/FLOW_CARD.md, module $2, gates migration/$1/verify-report.json, OSB sources $3)
and write migration/$1/REVIEW.md and migration/$1/MIGRATION_RECORD.md with the four sections.
KIT_EOF_PI_PROMPTS_OSB_REVIEW_MD
mkdir -p "$(dirname "pi/prompts/osb-test.md")"
cat > 'pi/prompts/osb-test.md' <<'KIT_EOF_PI_PROMPTS_OSB_TEST_MD'
---
description: Flow card + OSB evidence -> test suite (tester role; start a NEW session first)
argument-hint: "<flow> <module-dir> <osb-project-dir>"
---
Act as the tester defined in agents/tester.md and follow AGENTS.md. You have not seen the implementation reasoning.
Write the tests for flow $1 from migration/$1/FLOW_CARD.md and the OSB evidence in $3, with skill osb-to-camel Step 3
and skill camel-migration-verification. One test per matrix row (T-ID in the name). Expected files only from OSB,
listed in $2/src/test/resources/golden/MANIFEST.csv. Do not edit $2/src/main. Run `mvn -q -f $2/pom.xml verify`.
KIT_EOF_PI_PROMPTS_OSB_TEST_MD
mkdir -p "$(dirname "pi/prompts/osb-verify.md")"
cat > 'pi/prompts/osb-verify.md' <<'KIT_EOF_PI_PROMPTS_OSB_VERIFY_MD'
---
description: Run gates G1-G8 for a flow and explain the result
argument-hint: "<module-dir> <flow>"
---
Run `tools/verify_flow.sh $1 $2` and show migration/$2/verify-report.json as a table.
For each red gate, name the owner role per skill camel-migration-verification Step 2. Do not fix anything.
KIT_EOF_PI_PROMPTS_OSB_VERIFY_MD
mkdir -p "$(dirname ".pi/prompts/osb-analyse.md")"
cat > '.pi/prompts/osb-analyse.md' <<'KIT_EOF__PI_PROMPTS_OSB_ANALYSE_MD'
---
description: OSB flow -> inventory + flow card (analyst role, no code)
argument-hint: "<osb-project-dir> <flow>"
---
Act as the analyst defined in agents/analyst.md and follow AGENTS.md.
Use skill osb-to-camel Steps 0 and 1 on the OSB export $1 for flow $2.
Write migration/$2/FLOW_CARD.md with Status draft, then stop and list the BLOCKING open items.
KIT_EOF__PI_PROMPTS_OSB_ANALYSE_MD
mkdir -p "$(dirname ".pi/prompts/osb-camelk.md")"
cat > '.pi/prompts/osb-camelk.md' <<'KIT_EOF__PI_PROMPTS_OSB_CAMELK_MD'
---
description: "Approved flow card + research pack -> Camel K YAML route + tests, until the gates pass"
argument-hint: "<module-dir> <research-dir>"
---
Act as the implementer defined in agents/implementer-camelk.md and follow AGENTS.md.
Use skill osb-camelk-route on module $1 (approved card $1/FLOW_CARD.md) with research pack $2.
Do steps 3-6 of the skill until check_camelk.py prints PASS, then give the five-line report.
KIT_EOF__PI_PROMPTS_OSB_CAMELK_MD
mkdir -p "$(dirname ".pi/prompts/osb-implement.md")"
cat > '.pi/prompts/osb-implement.md' <<'KIT_EOF__PI_PROMPTS_OSB_IMPLEMENT_MD'
---
description: Approved flow card -> Camel on Spring Boot code (implementer role)
argument-hint: "<flow> <module-dir>"
---
Act as the implementer defined in agents/implementer.md and follow AGENTS.md.
Refuse unless migration/$1/FLOW_CARD.md says Status approved with an approver.
Implement it with skill osb-to-camel Step 2 into Maven module $2. Never touch $2/src/test.
Finish when `mvn -q -DskipTests -f $2/pom.xml package` passes.
KIT_EOF__PI_PROMPTS_OSB_IMPLEMENT_MD
mkdir -p "$(dirname ".pi/prompts/osb-research.md")"
cat > '.pi/prompts/osb-research.md' <<'KIT_EOF__PI_PROMPTS_OSB_RESEARCH_MD'
---
description: "OSB proxy -> shareable research pack (no code, no hosts, no data)"
argument-hint: "<osb-project-dir> <proxy> [task1-dir]"
---
Act as the researcher defined in agents/researcher.md and follow AGENTS.md.
Use skill osb-research on the OSB export $1 for proxy $2 (scenarios from $3/traces/scenarios.json if given).
Write research/$2/RESEARCH.md and research/$2/research.json, run the share check until it passes, then give the five-line report.
KIT_EOF__PI_PROMPTS_OSB_RESEARCH_MD
mkdir -p "$(dirname ".pi/prompts/osb-review.md")"
cat > '.pi/prompts/osb-review.md' <<'KIT_EOF__PI_PROMPTS_OSB_REVIEW_MD'
---
description: Evidence-only review + migration record (reviewer role; start a NEW session first)
argument-hint: "<flow> <module-dir> <osb-project-dir>"
---
Act as the reviewer defined in agents/reviewer.md. Do not edit code or tests.
Review flow $1 (card migration/$1/FLOW_CARD.md, module $2, gates migration/$1/verify-report.json, OSB sources $3)
and write migration/$1/REVIEW.md and migration/$1/MIGRATION_RECORD.md with the four sections.
KIT_EOF__PI_PROMPTS_OSB_REVIEW_MD
mkdir -p "$(dirname ".pi/prompts/osb-test.md")"
cat > '.pi/prompts/osb-test.md' <<'KIT_EOF__PI_PROMPTS_OSB_TEST_MD'
---
description: Flow card + OSB evidence -> test suite (tester role; start a NEW session first)
argument-hint: "<flow> <module-dir> <osb-project-dir>"
---
Act as the tester defined in agents/tester.md and follow AGENTS.md. You have not seen the implementation reasoning.
Write the tests for flow $1 from migration/$1/FLOW_CARD.md and the OSB evidence in $3, with skill osb-to-camel Step 3
and skill camel-migration-verification. One test per matrix row (T-ID in the name). Expected files only from OSB,
listed in $2/src/test/resources/golden/MANIFEST.csv. Do not edit $2/src/main. Run `mvn -q -f $2/pom.xml verify`.
KIT_EOF__PI_PROMPTS_OSB_TEST_MD
mkdir -p "$(dirname ".pi/prompts/osb-verify.md")"
cat > '.pi/prompts/osb-verify.md' <<'KIT_EOF__PI_PROMPTS_OSB_VERIFY_MD'
---
description: Run gates G1-G8 for a flow and explain the result
argument-hint: "<module-dir> <flow>"
---
Run `tools/verify_flow.sh $1 $2` and show migration/$2/verify-report.json as a table.
For each red gate, name the owner role per skill camel-migration-verification Step 2. Do not fix anything.
KIT_EOF__PI_PROMPTS_OSB_VERIFY_MD
chmod +x pi/*.sh 2>/dev/null || true
echo "commands /osb-* installed in .pi/prompts: start pi in this folder and trust the project (or pi --approve)"
echo "installed: 38 files (agent layer)"
