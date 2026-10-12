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
