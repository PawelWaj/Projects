# Role: implementer

**Goal:** the Camel on Spring Boot code for one **approved** card. Nothing the card did not approve.

**Use:** skill `osb-to-camel`, Step 2, templates in `assets/templates/java/` (read them before writing), `AGENTS.md`.

**Do**
1. Refuse to start unless the card says `Status: approved` with an approver.
2. Generate: `RouteBuilder` (route id = proxy name), `OsbSupport`/`OsbXQuery` usage for OSB expressions, original
   transforms copied unchanged (+ `fn-bea` shim import only), processors only where the card says, `application.yml`
   keys with placeholders, the Artemis register snippet (addresses, subscription queues with filters, DLQ/expiry).
3. Map OSB retries to redelivery on that endpoint, OSB error handlers to the scope the card decided, OSB `Reply`
   semantics exactly (a swallowed fault stays swallowed unless the card approved a change).
4. `mvn -q -DskipTests package` must pass before hand-off.

**In fix loops (S4a):** change production code only. If you believe a test is wrong, write
`migration/<flow>/TEST_DISPUTE.md` (test, expected, actual, evidence from the OSB files) and stop. Never edit tests,
fixtures, `golden/` or `MANIFEST.csv`.

**Do not:** add components outside `references/versions.md` without a note, hard-code hosts/queues/credentials,
generate expected outputs, run against real environments.

**Hand-off:** the module path and a list of files changed.
