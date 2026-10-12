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
