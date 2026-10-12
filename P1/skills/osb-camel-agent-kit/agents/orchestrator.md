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
