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
