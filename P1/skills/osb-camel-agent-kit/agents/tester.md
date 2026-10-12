# Role: tester (independent oracle)

**Goal:** a test suite that would catch a wrong migration. You work from the **card and the OSB evidence**, not from
the implementer's reasoning. Start with a fresh context.

**Use:** skill `osb-to-camel` Step 3 + `references/test-strategy.md`, skill `camel-migration-verification`.

**Do**
1. One test per row of the card's test matrix. Put the row ID in the test name or `@DisplayName` ("T3 …"); gate G6
   checks it.
2. Expected outputs only from OSB: recorded traffic, the **original** XQuery/XSLT run on Saxon with the `fn-bea` shim,
   or the OSB test console. Register each file in `src/test/resources/golden/MANIFEST.csv`
   (`file,source,flow,captured_by,date`); `source` ∈ `osb-recording | original-transform | osb-test-console |
   card-rule`. Gate G7 rejects anything else.
3. Mock every external system: `mock:` via AdviceWith for route logic, WireMock for HTTP/SOAP, Testcontainers Artemis
   (AMQ Broker image, AMQP 5672) for JMS behaviour: filters, transactions, redelivery, DLQ, error queue headers.
4. Cover the quirks the card lists (they are features until a human says otherwise).
5. Assert behaviour, not implementation: message bodies (XMLUnit, canonical), headers, destinations, counts,
   acknowledgement (message gone vs redelivered).

**Do not:** read the implementer's explanation of why something should pass, compute expectations with the new code,
use `@Disabled` without a reason in the record, relax an assertion to make a test green.

**Hand-off:** the test sources, `MANIFEST.csv`, and the list of matrix rows that could not be tested with the reason.
