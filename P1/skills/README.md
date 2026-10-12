# skills

## osb-camel-agent-kit

A vendor-neutral kit for migrating Oracle Service Bus (OSB 11g/12c) flows to Apache Camel on Spring Boot with an AI
coding agent, flow by flow, with a generated test suite and deterministic quality gates.

| Path | What it is |
|---|---|
| `osb-camel-agent-kit/skills/osb-to-camel/` | Agent Skill: inventory and triage of an OSB export, a design card per flow, generation of the Camel route, transforms, configuration and tests |
| `osb-camel-agent-kit/skills/camel-migration-verification/` | Agent Skill: how to verify generated code (gates G1-G8, shadow run, evidence pack) |
| `osb-camel-agent-kit/agents/` | Role prompts: analyst, implementer, tester, reviewer, orchestrator |
| `osb-camel-agent-kit/pi/` | Running it on the pi coding agent: agentic runner `run_flow.sh`, prompt templates, setup, preflight |
| `osb-camel-agent-kit/tools/` | Deterministic gates and checks (no AI): `verify_flow.sh`, matrix, oracle, mutation, shadow comparison |
| `osb-camel-agent-kit/bootstrap/` | Five self-extracting scripts to install the kit by copy-paste where file transfer is not possible |
| `osb-camel-agent-kit.zip` | The same kit as one archive |

Start with `osb-camel-agent-kit/README.md`, then `TRIAL_GUIDE.md`. Before generating code for a real programme, fill
`skills/osb-to-camel/references/programme-rules.md` with that programme's decisions.

Quick install into a project (pi or any agent that reads Agent Skills and AGENTS.md):

```bash
git clone https://github.com/PawelWaj/Projects (directory P1).git
cp -r AI/skills/osb-camel-agent-kit/{AGENTS.md,agents,tools,pi} <your-migration-repo>/
mkdir -p <your-migration-repo>/.pi/skills <your-migration-repo>/.pi/prompts
cp -r AI/skills/osb-camel-agent-kit/skills/* <your-migration-repo>/.pi/skills/
cp AI/skills/osb-camel-agent-kit/pi/prompts/*.md <your-migration-repo>/.pi/prompts/
```

Status: the inventory and triage scripts are tested on the bundled fixtures (synthetic OSB exports). Code generation has
been evaluated on a synthetic flow only; validate on your own flows before relying on it.
