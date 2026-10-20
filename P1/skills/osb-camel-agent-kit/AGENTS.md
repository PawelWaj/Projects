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
5. **Generate the delivery** with `osb-camelk-route` ("Delivery": `pi/run_domain.sh delivery|review`); implement by hand
   (`osb-camelk-route` Steps 3–5) only for flows BODY_CHAIN.md marks as not generated.
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
