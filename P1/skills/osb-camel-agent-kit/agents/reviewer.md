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
