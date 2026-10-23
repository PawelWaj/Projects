# AI

AI-assisted engineering assets: agent skills, role prompts and the deterministic tooling around them.

> **On the VDI: start with [`vdi-osb-migration/START_HERE.md`](vdi-osb-migration/START_HERE.md)** (setup, Splunk CSV -> tests + Camel K route -> `integration.yaml` on Dev).

## Contents

| Path | What it is |
|---|---|
| [`skills/osb-camel-agent-kit/`](skills/osb-camel-agent-kit/) | Kit for migrating Oracle Service Bus (OSB 11g/12c) flows to Apache Camel on Spring Boot with an AI coding agent: two Agent Skills, role prompts, an agentic runner for the [pi](https://pi.dev) coding agent, and quality gates that run without AI |
| [`skills/osb-camel-agent-kit.zip`](skills/osb-camel-agent-kit.zip) | The same kit as one archive |
| [`osb-log-replay/`](osb-log-replay/) | Test cases from production OSB logs: log signatures from the pipeline source, Splunk searches, trace and scenario analysis with masking, fixtures, and an E2E replay harness on a mock broker (Artemis + WireMock) |
| [`skills/README.md`](skills/README.md) | Overview of the skills folder and a quick install |

## OSB to Camel agent kit at a glance

```
OSB export ─► ANALYST ─► flow card ─► HUMAN APPROVAL ─► IMPLEMENTER ─► TESTER ─► GATES G1-G8 ─► REVIEWER ─► record
                                                            ▲                         │ red (max 3x)
                                                            └──────── fix loop ───────┘
```

- **Skills** (open Agent Skills format, `SKILL.md`):
  - `osb-to-camel`: inventory and triage of an OSB export, a design card per flow, generation of the Camel route, transforms, configuration and a mocked test suite.
  - `camel-migration-verification`: how to verify generated code, the gates and the shadow run.
- **Agents:** analyst, implementer, tester and reviewer role prompts. Each role runs in a fresh context; the tester never sees the implementer's reasoning.
- **Gates:** `tools/verify_flow.sh` covers build, Camel endpoint validation, repository rules, unit and integration tests, test-matrix coverage, oracle provenance and transform mutation. Acceptance comes from script output, not from what the model says.
- **Runs on:**
  - pi, interactively (`/osb-analyse` … `/osb-review`) or unattended (`pi/run_flow.sh`);
  - any agent that reads `AGENTS.md` and Agent Skills.

Start with [`skills/osb-camel-agent-kit/README.md`](skills/osb-camel-agent-kit/README.md), then `TRIAL_GUIDE.md`.

## Quick install into a migration project

```bash
git clone https://github.com/PawelWaj/Projects (directory P1).git
cd <your-migration-repo>
cp -r ../AI/skills/osb-camel-agent-kit/{AGENTS.md,agents,tools,pi} .
mkdir -p .pi/skills .pi/prompts
cp -r ../AI/skills/osb-camel-agent-kit/skills/* .pi/skills/
cp ../AI/skills/osb-camel-agent-kit/pi/prompts/*.md .pi/prompts/
pi/preflight.sh
```

Before generating code for a real programme, fill `.pi/skills/osb-to-camel/references/programme-rules.md` with that
programme's decisions: runtime, logging, secrets, messaging, cut-over.

## Status

- **Inventory and triage scripts:** tested on the bundled synthetic OSB fixtures.
- **Code and test generation:** evaluated on a synthetic flow only. Validate on your own flows, starting with a small pilot, before relying on it.

## vdi-osb-migration/ — one entry point per flow on a locked-down VDI

`bin/start_flow.sh <osb-project> <flow> <module> [splunk.csv]` runs the whole chain: inventory and flow card, log
signatures and Splunk searches, keyed masking with a residue check, replay-config draft and fixtures, the golden oracle
(original XQuery/XSLT through Saxon, hashed in `ORACLE.lock`), then the pi agent roles (analyst, gate A, tester before
implementer, gates G1-G10, reviewer, gate B). `RUNBOOK.md` is the operator guide; `bin/build_bootstrap.py` regenerates
the seven paste-install scripts in `skills/osb-camel-agent-kit/bootstrap/` for a VDI without file transfer.
