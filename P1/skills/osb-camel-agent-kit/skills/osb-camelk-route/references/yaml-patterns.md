# OSB pipeline → Camel K YAML DSL (Camel 4.18), patterns proven on the pilot

All of these ran green in `pilot/maintain-adjustment` (Camel 4.18.4, `camel-test-main-junit5`). Anything else: check
the Camel 4.18 documentation of the component or EIP before writing it.

| OSB | Camel K YAML |
|---|---|
| `assign $uuId := header traceId or fn-bea:uuid()` | `- setHeader: {name: traceId, simple: "${header.traceId} ?: ${uuid(random)}"}` (`uuid(random)` = java UUID, 36 chars like fn-bea:uuid) |
| Log action | `- log: {loggingLevel: INFO, logName: oracle.osb.logging.pipeline, message: "<same literal text> ${header.x} ::${body}"}`; keep the position (OSB logs before nXSD) |
| nXSD JSON→XML used only for conditions | helper bean `OsbJson.annotate`: lenient parse (raw control characters, text after the JSON), sets condition fields as headers, **does not change the body** |
| `ifThenElse` with one case (no else) | `- choice: {id: branch-<x>, when: [{id: branch-<x>-<path>, simple: "${header.f} == 'true'", steps: [...]}]}`; no `otherwise` = nothing happens, like OSB |
| Two independent `ifThenElse` in one stage | two `choice` blocks one after the other (both can fire) |
| XPath `//*:f/text()='true'` | header from bean with path `//f` (first field of that name at any depth) or `a.b.f`; compare as text: JSON `true` and `"true"` both give `true` |
| Route/publish to a JMS business service | `- to: {id: out-<bs>, uri: "{{out.<bs>}}"}`; property `out.<bs>=amqp:queue:<name>` |
| Business service retry-count N, interval S | send through `direct:send-<bs>` in its own route with `routeConfigurationId` → `routeConfiguration` + `errorHandler.defaultErrorHandler.redeliveryPolicy {maximumRedeliveries: "{{retry.<bs>.count:N}}", redeliveryDelay: "{{retry.<bs>.delay:S000}}"}`; after the last retry the exception returns to the caller's `doCatch` |
| Pipeline error handler → error queue with headers | `doTry` around the flow, `doCatch: [{exception: [java.lang.Exception], steps: [log, setHeader errorCode/errorMessage/debugInfo, removeHeaders of internal headers, to out-<error-bs>]}]`; inbound headers (resource, eventType, traceId) travel with the message |
| Error queue gets `$requestDoc` (original body) | keep the body unchanged everywhere before the catch (the bean never replaces it) |
| `replace` with stored XQuery | `- to: "xquery:osb/<project>/<file>.xqy"` (camel-saxon), parameters as headers; fn-bea functions via the shim in skill osb-to-camel |
| XSLT | `- to: "xslt-saxon:osb/<project>/<file>.xsl"` |
| Durable topic subscription + selector | not in the route: subscription queue `<address>::<subscription>` with the selector as broker filter (Artemis config); `flow.input=amqp:queue:<address>::<subscription>`; selector tests are L2 |

Tests: `@CamelMainTest(properties = {"flow.input=direct:in", "out.x=mock:out-x", "retry.x.delay=0", ...})`,
`@Produce("direct:in") ProducerTemplate in`, mocks by `in.getCamelContext().getEndpoint("mock:out-x", MockEndpoint.class)`,
failures by `mock.whenAnyExchangeReceived(e -> { throw new IOException("down"); })`, retries by `getReceivedCounter()`.
