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
