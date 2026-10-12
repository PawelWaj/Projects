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
