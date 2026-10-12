---
name: osb-to-camel
description: Migrate Oracle Service Bus (OSB 11g/12c) flows to Apache Camel on Spring Boot, flow by flow, with a mocked JUnit test suite. Reads an OSB export (unzipped sbconfig.jar or JDeveloper OSB project with .proxy, .pipeline, .bix, .xqy, .xsl, .xsd and .wsdl files), inventories and triages flows, writes a design card per flow, then generates the RouteBuilder, adapted XQuery/XSLT, configuration keys and tests (AdviceWith route tests, WireMock backends, Testcontainers Artemis, golden tests against the original transform, parity replay). Use whenever OSB, Oracle Service Bus, sbconfig, proxy or business services, pipelines, XQuery flows or "ESB to Camel" are mentioned, including inventory, triage or estimation questions, even without the word migrate.
---

# OSB to Camel: migration factory for one flow or four hundred

An OSB flow is a proxy service (the contract and the inbound transport), a pipeline (stages of actions on a
message context), business services (the outbound endpoints) and transforms (XQuery, XSLT). Camel has an exact
counterpart for almost every piece, which is why this migration is repetitive, and why the repetitive part should be
done the same way every time. The skill fixes the order of work, the mapping tables and the test shape, so that the
450th flow is produced like the first and every flow arrives with its evidence.

Three things make an OSB migration go wrong, and the workflow is built around them:

1. **The behaviour lives in details nobody wrote down**: `contents-only` on a Replace, a `retry-count` on a business
   service, an error handler three scopes up, `$body` meaning the SOAP Body content rather than the envelope. The
   inventory script extracts them; the flow card forces a decision on each before code exists.
2. **XQuery is the real volume.** OSB queries are XQuery 1.0 with Oracle `fn-bea:` extensions. Saxon runs XQuery 3.1,
   which is a superset for everything except those extensions and a few `fn:doc`/collation habits. Keep the queries,
   rewrite only `fn-bea:`, and prove equivalence with golden tests run against the original query.
3. **Tests must not depend on the systems OSB talked to.** Every backend is a mock (WireMock for SOAP/REST, an Artemis
   container for JMS, in-memory for direct/local). The only "real" thing in a test is the route and the transform.

Design before code holds here as it does in camel-kit: a flow card is written and read before a route is generated.
When this skill runs inside camel-kit's pipeline, the card is the Phase 1/Phase 2 input and code generation belongs to
`camel-execute`; see `references/camel-kit-integration.md`. Standalone, the card is approved by the user (or by batch
decision for a tier) and the skill generates the code and the tests itself.

## Inputs you need, and what to do when they are missing

| Input | Why | If missing |
|---|---|---|
| The OSB export: a directory (unzipped `sbconfig.jar` or JDeveloper OSB project) or the `.jar`/`.zip` | Everything else derives from it | Stop. Ask for the export, or for read access to the OSB project repository. Never reconstruct a flow from a description |
| Target: Camel version, Spring Boot version, DSL (default Java DSL on Spring Boot), package base, repository layout | Generated code must match the team's build | Read `references/versions.md` for the defaults and say which defaults were applied |
| The Java callout jars' source, when the inventory lists `javaCallout` | A callout cannot be migrated from its class name | Generate a bean stub with the exact signature and a `TODO` that blocks the flow's done-state; list it as an open item |
| Recorded OSB traffic (request/response pairs from OSB message reporting, tracing, or the gateway logs), personal data masked | Parity replay, the strongest proof | Generate the replay test anyway, with the fixture directory empty and the test skipped-until-fixtures; say so in the record |
| WSDL/XSD for every SOAP proxy and business service | Contract tests and CXF endpoints | The inventory flags the missing reference; treat the flow as blocked, not as "any XML" |

## Workflow

### Step 0: inventory and triage (deterministic, run first, run once)

```bash
python3 <skill>/scripts/osb_inventory.py <export-dir-or-jar> -o osb-inventory
```

Read `osb-inventory/INVENTORY.md` end to end, then `osb-inventory/inventory.json` `summary`. The script resolves
proxy → pipeline → business services → transforms, counts every pipeline action, extracts transports, URIs, retries,
timeouts, service accounts, WS-policies, throttling, result caching, operational branches, error-handler scopes,
context variables, `fn-bea:` functions and external XQuery parameters, and scores each flow into `simple`, `medium`,
`complex` (`references/triage-rules.md` explains the score; it is uncalibrated until the first slice is measured).

Then establish, with the user, before any flow is touched:

- **Scope:** which flows (by name, by tier, by project folder, or all). Shared business services across flows are the
  natural grouping: one WireMock stub set and one configuration block serve every flow that calls the same backend.
- **Unknowns the report lists:** `unknown actions`, `NOT FOUND in export`, Java callouts without source, flows whose
  pipeline could not be resolved. Each is an open item on the affected flow card; none is silently skipped.
- **Target conventions:** confirm `references/versions.md` defaults or take the team's values; confirm the base package
  and where routes, resources and tests go (the templates assume one Maven module per OSB project folder, one
  `RouteBuilder` per proxy service).

If the inventory shows zero flows, the export is not what you think it is (wrong directory level, or an export of
resources only). Say so and stop.

### Step 1: flow card (design, no code)

For each flow in scope, scaffold the card and complete it:

```bash
python3 <skill>/scripts/scaffold_flow.py osb-inventory/flows/<flow>.json -o migration/<flow>/
```

The scaffold pre-fills `FLOW_CARD.md` from the inventory: contract and operations, the stage-by-stage action walk with
the proposed Camel step for each action (from `references/osb-action-mapping.md`), the backends with their proposed
components and configuration keys (from `references/osb-transport-mapping.md`), the transforms with their `fn-bea:`
functions and external parameters, the context variables, the error-handler scopes, and a test matrix with one row per
operation, per branch, per error path, per transform and per backend. It also lists the open questions it could not
answer from the export.

Your job on the card is judgement, not transcription:

- Read the actual pipeline XML and the transforms (paths are in the card). The script counts; it does not understand.
  Confirm each proposed mapping or replace it, and write one line of reason where you deviate.
- Decide the four things that decide the route's shape: SOAP 1.1 or 1.2 and document/literal from the binding; which
  context variables become headers, which become exchange properties (`references/osb-expression-mapping.md`,
  section "Context variables"); where each error handler scope lands (`onException` on the route, `doTry` around a
  stage, or a route-level `errorHandler`); and whether a publish is fire-and-forget (`response-required=false` →
  `InOnly` wire tap) or a callout in disguise.
- Record every behaviour the test suite must prove: branch conditions with the exact XQuery, retry and timeout values,
  fault shapes, header propagation.
- Mark anything you cannot settle from the export as an open item with an owner. Do not resolve it by assumption.

Present the card (or, in batch mode, the cards of a tier) and obtain approval before Step 2. For `simple` flows
approval can be a batch decision; for `complex` flows it should be per flow.

### Step 2: generate the Camel module

Generate from the approved card, using `assets/templates/java/` as the shape (read the template before writing; the
templates carry the conventions the team's reviewers will check):

- `RouteBuilder` per proxy service: route id = the OSB proxy name; one route per WSDL operation when the pipeline has an
  operational branch, dispatching from the inbound endpoint by operation; sub-routes (`direct:`) per OSB stage when a
  stage is reused or long; `routeId`/`description` on every route; `{{placeholders}}` for every endpoint, timeout and
  retry value, never literals.
- Inbound: `cxf:` endpoint with the original WSDL and port for SOAP proxies (the contract must not change: same WSDL,
  same `SOAPAction`, same namespaces), `platform-http`/`rest` for REST or any-XML proxies, `amqp:`/`jms:` for JMS
  proxies. Keep the OSB URI path as the Camel path so the Apigee route rule can switch per flow (`B2` in the
  programme roadmap: the cutover is an Apigee target change, not a client change).
- Transforms and expressions: copy each `.xqy`/`.xsl` into `src/main/resources/osb/<project>/...`, keep the file
  name, apply only the edits in `references/osb-expression-mapping.md` (the `fn-bea:` shim import). Run every OSB
  expression, inline or stored, through the `OsbXQuery` helper from the templates: it binds `$body`, `$inbound`,
  `$fault` and the pipeline variables by their OSB names, so expressions are pasted verbatim from the pipeline XML.
  Never paste an OSB expression into Camel's own `xquery()` language (it binds `$in.headers.*`, not `$body`), and never
  rewrite a working XQuery into Java "because it is cleaner"; equivalence is the goal, and the golden test proves it.
- `$body` boundaries: `wrap()` once at the inbound, `unwrap()` before **every** backend call, `rewrap()` after a
  request-response call, `unwrap()` at the reply (expression mapping §1). A backend must never receive the wrapper.
- Backends: one configuration block per business service (`osb.business.<Name>.url`, `.timeout`, `.retry-count`,
  `.retry-interval`), the component from the transport table, credentials as Vault-delivered properties never values.
  OSB `retry-count`/`retry-interval` become Camel redelivery on that endpoint's `onException`, not a global policy;
  `retry-application-errors=false` means retry only on transport failures.
- Error handling in the scope the card decided; an OSB `Reply with error` becomes a SOAP fault through CXF with the
  same fault shape the XSLT produced; `Resume` becomes `handled(true)` and continue.
- Logging to stdout through the application's logger (ECS JSON on this programme), with the correlation header the
  pipeline propagated; `alert` actions become a log line at WARN with a stable marker and a counter metric.

Do not generate anything the card did not approve; do not "improve" the contract; do not add components that are not
in `references/versions.md` without saying why.

### Step 3: generate the test suite (mocks everywhere)

Follow `references/test-strategy.md`. Every flow gets, from the templates in `assets/templates/java/`:

| Test | Proves | Mocked with |
|---|---|---|
| `<Flow>RouteTest` | Every operation, branch and error path of the pipeline, in isolation | `@CamelSpringBootTest`, `@UseAdviceWith`, `AdviceWith` replacing each backend endpoint with `mock:`; one `@Test` per test-matrix row |
| `<Transform>GoldenTest` | The adapted XQuery/XSLT produces what the original produced | The original query run by Saxon with the `fn-bea` shim module; XMLUnit comparison with an ignore list for timestamps |
| `<Flow>BackendContractTest` | Requests leave in the shape the backend expects; timeouts and retries behave as the business service was configured | WireMock stubs per business service (`SOAPAction` + XPath matching); a delayed stub to force the timeout and count retries |
| `<Flow>JmsPublishTest` | Publish is fire-and-forget, body and headers as the pipeline built them | Testcontainers `ArtemisContainer` (or embedded broker when Docker is unavailable, the test says which) |
| `<Flow>ParityReplayTest` | Recorded OSB request → identical response from Camel, with the backends replayed | Recorded pairs under `src/test/resources/parity/<flow>/`; WireMock replays the recorded backend exchanges; XMLUnit with `ignore-fields.txt` |

If the card lists a database, DVM/XRef lookup, Java callout, file/FTP/SFTP, email or module-level security, add the
matching interface-mock test as well (`references/test-strategy.md`, "Interface mocks beyond JMS and HTTP"): the
templates are `DatabaseMockTestTemplate`, `DvmLookup` + `LookupMockTestTemplate`, `JavaCalloutMockTestTemplate`,
`FileSftpMockTestTemplate`, `EmailMockTestTemplate`, `SecurityMockTestTemplate`, with support files in
`assets/templates/mocks/`.

Test inputs come from the WSDL/XSD (one valid message per operation, values traceable to the field name) and from the
branch conditions on the card (one input per side of every condition). Expected outputs for transforms are generated,
not hand-written: run the original transform. If Saxon cannot run an original query because of an `fn-bea:` function
the shim does not cover, that is a finding on the card, not a reason to hand-write the expectation.

Run the suite (`mvn -q test` in the module). A flow is not "migrated" with a red or skipped test unless the record says
why (missing parity fixtures, Java callout without source).

### Step 4: migration record and status

Write `migration/<flow>/MIGRATION_RECORD.md` from `assets/templates/MIGRATION_RECORD.md`: the action-to-code map
(OSB action id → Camel step), the test matrix with results, every deviation from the original behaviour with its
reason, the configuration keys and their sources, the open items with owners, and the cutover note (the Apigee route
rule to switch, the OSB proxy to leave deployed until the soak ends). Update `osb-inventory/STATUS.md` (flow, tier,
state, tests green/red, open items). The record is what the reviewer, the tester and the estimate reconciliation read;
write it for them.

### Batch mode

For a tier or a project folder: Step 0 once, Step 1 for all flows in the batch, one approval, Steps 2 to 4 per flow in
order of shared backends (flows sharing a business service share the WireMock stub set and the configuration block,
generate those once). Keep a running `STATUS.md`. Stop the batch and report when three flows in a row produce an
unknown action, a missing resource, or a shim gap: the mapping tables need an entry before more flows are produced.

## What this skill does not do

- It does not decide the cutover, the Apigee change or the OSB retirement; it produces the code, the tests and the
  record that make those decisions safe. Operational steps go into the record as proposals.
- It does not migrate Oracle JMS or AQ destinations; a business service on `jms://` becomes a Camel endpoint on the
  target broker and the record notes the destination that must exist there (the messaging migration owns the bridge).
- It does not translate WS-Security policies into mesh or gateway configuration; it records the policy references and
  marks the flow blocked until the security owner decides where that control lives.
- It does not estimate. The triage tier and the per-flow counts are inputs for whoever owns the estimate.

## References (read when the step needs them)

| File | Read when |
|---|---|
| `references/osb-action-mapping.md` | Step 1, every flow: pipeline action → Camel step, with the traps per action |
| `references/osb-transport-mapping.md` | Step 1 and 2: transport → component, configuration keys, programme constraints |
| `references/osb-expression-mapping.md` | Step 1 to 3: XQuery/XPath/XSLT handling, `fn-bea:` table, context variables, the `$body` root rule |
| `references/test-strategy.md` | Step 3: what each test proves, how fixtures are produced, what "mocked" means here |
| `references/triage-rules.md` | Step 0: how the score is built and how to recalibrate it after the first slice |
| `references/camel-kit-integration.md` | When camel-kit is installed in the target repository, or the user asks how this relates to `/camel-migrate` |
| `references/programme-rules.md` | Step 1 and 2 on the target platform: runtime, logging, Vault, messaging, coexistence bridges, open programme decisions. Wins over the generic tables |
| `references/versions.md` | Step 0 and 2: default versions and artifacts; update it when the team pins others |
| `assets/templates/` | Step 1 to 4: the card, the record, the Java templates, the Maven dependency fragment, the test properties |
