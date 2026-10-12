# OSB pipeline action → Camel step

How to read this: the OSB column is the action's local XML name as the inventory reports it. "Camel (Java DSL)" is the
default proposal the scaffold writes on the flow card. "Trap" is the detail that produces a behavioural difference if
ignored; most of them are not visible in the OSB console and only exist in the XML.

Vocabulary of the message context, used throughout: OSB's `$body` is the **content of the SOAP Body** (for SOAP
services) or the whole payload (for XML/any services); `$header` is the SOAP Header; `$inbound`/`$outbound` are the
transport and service metadata; `$fault` exists only in error handlers. In Camel the message body is the whole payload
the component delivered; with `camel-cxf` in `PAYLOAD` mode it is the SOAP Body content, which is the closest match and
the reason the templates use that mode. See `osb-expression-mapping.md` for the variable mapping.

## Message processing actions

| OSB action | What it does | Camel (Java DSL) | Trap |
|---|---|---|---|
| `assign` (varName, expr) | Evaluates XQuery/XPath into a named context variable | `.setProperty("<varName>", OsbXQuery.of(<expr>).ns(NS).asNode())` for XML values, `.asString()` for scalars (expression mapping §5). Properties, never headers, unless the value must cross a wire | OSB variables are document fragments; an `assign` of `$body/ns:x/text()` yields a text node, not a string. Type the Camel expression explicitly (`String.class`) or the next XQuery sees a different node kind |
| `replace` (varName, contents-only="true") | Replaces the **children** of the selected node | `.process(OsbXQuery.of(<expr>).ns(NS).replaceBodyContentsOnly())` when the variable is `body` (`replaceBody()` for contents-only=false); for a sub-node, an XSLT/XQuery that rebuilds the parent with new children | `contents-only="true"` keeps the wrapper element; `"false"` replaces the node itself. Getting this wrong changes the root element the next step sees and every downstream XPath breaks silently |
| `replace` with `xqueryTransform` resource | Runs a stored `.xqy` with named parameters | `.process(OsbXQuery.resource("osb/<project>/Transform/<Name>.xqy").ns(NS).param(<osbParam>, <property>[, <path>])...replaceBodyContentsOnly())` (expression mapping §5) | Parameters are bound by name; OSB passes node sequences, Camel passes whatever the header holds. Bind `Document`/`Node` objects for element parameters, not strings |
| `replace` with `xsltTransform` | Runs a stored `.xsl` | `.to("xslt-saxon:classpath:osb/<project>/<Name>.xsl")`; XSLT parameters from headers (`transformerFactory` defaults suffice) | The `input` of the OSB XSLT is often `$fault` or a variable, not `$body`. Set the body to that variable first, then transform, then restore |
| `insert` (location, where=before/after/first-child/last-child) | Inserts a fragment relative to an XPath | An XQuery/XSLT that rebuilds the parent, or a small `Processor` using DOM. Prefer XQuery: it stays declarative and testable with the golden test | Four `where` modes; `first-child` and `last-child` are the common ones. Write the XQuery per mode, do not approximate |
| `delete` (location) | Removes nodes | XSLT identity template with an empty template for the path, or XQuery `copy-modify` is not in 3.1 core: use XSLT | Deleting `$body` children versus the variable itself (same `contents-only` logic) |
| `rename` (location, localname/namespace) | Renames an element | XSLT identity template with a renaming template | Namespace renames usually also need the prefix fixed in the children; test with the golden test, not by eye |
| `javaCallout` (archive, class, method, params) | Calls a static Java method from an uploaded jar | `.bean(<Class>, "<method>")` with the parameters bound from headers/properties; port the class into the module if its source exists | Without the jar's source the method cannot be reproduced. Generate the bean with the exact signature and a failing `TODO` test; block the flow's done-state |
| `mflTransform` | Binary/flat-file ↔ XML via MFL | `bindy` (fixed-length/CSV) or `flatpack`, or a custom `DataFormat`; the MFL file is the spec | Padding, justification and code pages are in the MFL. Golden tests with real sample files are mandatory; there is no shim |
| `nXSDTransform` / `nxsdTranslation` | Native XSD (JCA-style) translation, Native-To-XML or XML-To-Native | JSON nXSD (`nxsd:version="JSON"`, appinfo `NXSDSAMPLE`/`USEHEADER`): a small processor that reads the JSON with Jackson and writes the target element in the nXSD namespace and element order; delimited/fixed-length: `camel-bindy` or a hand parser. Then keep the downstream XQuery unchanged | As MFL; golden test = OSB's own nXSD output for recorded native inputs (OSB test console), never the processor's output. Empty/missing JSON fields: replicate OSB (usually empty elements) |
| `validate` (schema, schemaElement, location, resultVar) | Validates a node against an XSD element | `.to("validator:classpath:osb/<project>/<Schema>.xsd")`; set the body to the `location` node first if it is not the body | OSB `validate` can write a boolean into `resultVar` instead of raising. Mirror that: `doTry/doCatch(ValidationException)` setting a property when the pipeline branches on the result |
| `javaScript` (12c JavaScript action: script over `$body`/variables, JSON-friendly) | Runs a script in the pipeline | `.process()` with a small Java class, or Camel's `js` language (`camel-javascript`) only if the team accepts GraalJS at runtime | Scripts often mutate several variables and build JSON; port to Java and prove with a golden test on the inputs the script saw |
| `routingOptions` (12c Routing Options: URI, QoS exactly-once, mode, retry, priority overrides on an outbound) | Overrides the business service settings for that call | `setHeader(Exchange.HTTP_URI)`/`toD` for the URI override; `transacted()`/InOnly for QoS; endpoint options for retries | An override hidden inside a route or publish action beats the business service's configuration; the card must show the effective values |
| `transportHeaders` (header-set=inbound-response / outbound-request, copy-all, header name/value) | Sets or copies transport headers | `.setHeader("<name>", ...)` / `.removeHeaders("*", <keep>)`; `copy-all=true` → propagate the inbound headers (Camel does by default) | Camel propagates **all** headers by default; OSB only when `copy-all`. With `copy-all=false`, strip inbound headers before the outbound call (`removeHeaders("*", "SOAPAction", "Content-Type", "X-Correlation-Id")`) or the backend receives client headers it never saw before |

## Communication actions

| OSB action | What it does | Camel (Java DSL) | Trap |
|---|---|---|---|
| `route` (service, operation, outbound/response transform) | Terminal request-response call to a business service; the response becomes the proxy response | `.process(OsbBodyWrapper.unwrap()).to("<backend-endpoint>").process(OsbBodyWrapper.rewrap())` as the last step of the request path; the response pipeline continues after it | A route node is terminal: nothing in the request pipeline runs after it, and the response pipeline runs on the way back. In Camel that is simply the steps after `.to()`. The `outboundTransform`/`responseTransform` inside the route node are ordinary replace actions: map them |
| `routeTable` (cases on an expression) | Routes to different services by a value | `.choice().when(xpath/xquery).to(...).otherwise()...` | One `when` per case; the `default` case is `otherwise`. The test matrix needs one input per case |
| `dynamicRoute` (service ref computed) | Target computed at runtime from a variable | `.toD("${exchangeProperty.target}")` or `recipientList` | The computed target in OSB is a **service reference**, not a URL. Build a lookup property → endpoint map and fail fast on an unknown key |
| `wsCallout` (service, operation, request/response bodies, headers) | Synchronous call in the middle of a pipeline, result into variables | Save the wrapped body to a property, set the body to the request variable (bare, no wrapper), `.to(endpoint)`, move the response into the named property, restore the wrapped body (template `_ActionId-4`); or `.enrich()` with an aggregation strategy doing the same | The callout does not replace `$body`; it fills `response/body` variable. The naïve `.to()` overwrites the body. Always restore |
| `publish` (service, outbound transform) | One-way send; errors do not stop the pipeline unless quality-of-service is exactly-once | `.wireTap("<backend-endpoint>")` with a copy, applying the outbound transform in the tap route; `ExchangePattern.InOnly` | `publish` inside a request pipeline is asynchronous "best effort" in OSB unless `qualityOfService=exactly-once`. Check the business service: a JMS publish with `response-required=false` is InOnly; an HTTP publish still waits for the HTTP response but ignores it. Transactions: OSB publish to JMS joins the inbound transaction when the proxy is transactional (JMS in → JMS out). Record whether the proxy is transactional before choosing a `transacted()` route |
| `publishTable` / `dynamicPublish` | As `routeTable` / `dynamicRoute`, one-way | `choice` + `wireTap` / `toD` InOnly | As above |

## Flow control actions

| OSB action | What it does | Camel (Java DSL) | Trap |
|---|---|---|---|
| `ifThenElse` (case condition, actions; default) | Conditional execution inside a stage | `.choice().when(OsbXQuery.of(<condition>).ns(NS).asPredicate()).…endChoice().otherwise()…end()` | OSB conditions are XQuery booleans over variables; copy them verbatim into the helper with the pipeline's `userNsDecl` list. A missing namespace declaration makes the condition silently false |
| `forEach` (variable, value, index/count vars, body) | Iterates over a node sequence, actions per item, mutating the context | `.split(xpath(...)).aggregationStrategy(...)...end()` when the result is rebuilt; a `Processor` when the loop mutates several variables | OSB `forEach` mutates variables in place and can change the iterated document. Camel `split` works on copies. If the loop writes back into `$body`, rebuild the document in an XQuery instead of a loop |
| `reply` (isErrorReply) | Ends processing and returns the current `$body`; with `isErrorReply` returns a fault | `.stop()` after setting the body; for the error case set a SOAP fault (CXF: throw `SoapFault` or set the `CamelCxfMessage` fault body) | A `reply` inside the **request** pipeline short-circuits the route node: the backend is never called. In Camel the `.stop()` must come before the `.to()`. Easy to miss when a reply sits inside an `ifThenElse` |
| `reply` with `isError=false` **inside an error handler** | Ends the flow as a success: the fault is swallowed; for a JMS proxy the message is acknowledged and never redelivered | `onException(...).handled(true)` with the handler's actions, no rethrow; for a transacted JMS route the error-queue send and the acknowledgement commit together | Common OSB pattern "log, route to an error queue, reply success". Do not turn it into a redelivery or a DLQ policy unless the card approves the change; the error-queue headers built in the handler are part of the contract |
| `skip` | Skips the rest of the current pipeline (request or response) | `.stop()` scoped to the sub-route of that pipeline (use `direct:` sub-routes per pipeline, so `stop()` ends only that part) | Not the same as `reply`: `skip` in the request pipeline still routes |
| `Error` / raise error (errCode, message) | Raises a fault handled by the nearest error handler | `.throwException(new OsbFaultException("<errCode>", "<message>"))` with a small exception type carrying code and reason | The error code is contractual: downstream handlers and callers test it. Keep the exact string |
| `resume` | In an error handler: continue the pipeline as if no error | `onException(...).handled(true).continued(true)` | Resume returns to the step after the failing one, not to the start. Camel's `continued(true)` does the same |
| Error handler on **stage** | Catches errors from that stage's actions | `doTry()...doCatch(Exception.class)` around the stage's steps, or a `direct:` sub-route per stage with its own `onException` | Scope order: stage → route node → pipeline → service. The nearest handler wins; an unhandled error propagates outward. Put each handler at the equivalent Camel scope, never all at the route level |
| Error handler on **route node** | Catches errors from the backend call | `onException` on the backend's endpoint segment, or `doTry` around the `.to()` | This is where retries live too: OSB retries at the business service, then the route-node handler sees the final failure |
| Error handler on **pipeline** (request or response) | Catches anything in that pipeline | `onException` in the `direct:` sub-route for that pipeline | |
| Error handler on **service** (`router errorHandler`) | Catches everything else, usually maps `$fault` to a SOAP fault and replies | Route-level `onException(Exception.class)` that runs the error pipeline's actions and replies | `$fault` carries `errorCode`, `reason`, `details`, `location` (node, pipeline, stage, error-handler, path) and `java-exception`. 12c codes are `OSB-38xxxx` (380000–380999 transport, 382000–382499 pipeline runtime, 382500–382999 pipeline actions, 386000–386999 WS-Security); 11g exports still say `BEA-`. The templates' `OsbFaultProcessor` sets headers with the same fields so the original fault XSLT can run on them |

## Reporting actions

| OSB action | Camel (Java DSL) | Trap |
|---|---|---|
| `log` (logLevel, expr) | `.log(LoggingLevel.<LEVEL>, "<logger>", "${...}")`; an OSB XQuery log expression is evaluated into a property with `OsbXQuery...asString()` first, then logged | OSB log levels: debug/info/warning/error. Personal data in log expressions is common in OSB flows and forbidden on the target (ECS JSON to Splunk): review every log expression on the card |
| `alert` (destination, severity, expr) | `.log(WARN, "ALERT <destination> <severity>: ...")` plus a Micrometer counter `osb.alert{destination,severity}`; no SNMP/email destination is reproduced | Alert destinations (email, SNMP, JMS) are platform concerns the programme does not carry over; the record lists each destination for the monitoring owner |
| `report` (key/value) | `.log(INFO, ...)` with the key as a structured field | OSB reporting wrote to a database for the console's search; the equivalent is a searchable log field, not a table |

## Node-level constructs (outside stages)

| OSB construct | Camel | Trap |
|---|---|---|
| Operational branch (`branch-node type="operation"`) | One route per operation; the inbound route dispatches on the operation (`CamelCxf` operation name header for CXF, `SOAPAction` otherwise) with `choice` | A branch with no pipeline pair and no route node is a valid "do nothing" operation: generate a route that returns an empty response, and a test that proves it |
| Conditional branch (`branch-node type="condition"`, variable + cases) | `choice` on the variable | Cases are compared as strings; `xs:string` the value |
| Pipeline pair (request + response) | The steps before and after the backend `.to()`; or two `direct:` sub-routes | |
| Split-join (`.flow`) | `split` + `aggregate` or `multicast().parallelProcessing()` | Split-joins are separate artefacts with their own semantics (parallel invokes, scoped variables). Treat every split-join as `complex` and design it on its own card |

## Settings that are not actions but change behaviour

| OSB setting | Where | Camel |
|---|---|---|
| `retry-count`, `retry-interval`, `retry-application-errors` | Business service | `onException(ConnectException/SocketTimeoutException).maximumRedeliveries(n).redeliveryDelay(ms)` scoped to that endpoint; `retry-application-errors=false` → do not retry on HTTP 5xx/SOAP faults, only on transport failures |
| `timeout` (`http:timeout`, seconds) | Business service | `?connectTimeout=…&receiveTimeout=…` on the CXF/HTTP endpoint (milliseconds) |
| `load-balancing-algorithm`, multiple URIs | Business service | On OpenShift one Service name replaces the URI list; record the original list, do not implement client-side balancing |
| `service-account` | Business service / proxy | Credentials from Vault-delivered properties; basic auth on the endpoint, never in the URI |
| `throttling` | Proxy/business service | `throttle()` with the same maximum concurrency, or leave it to the gateway and say so |
| `result-caching` | Business service | A cache (`caffeine-cache`) with the same key expression and TTL, or drop with a reason; it is usually a performance workaround |
| `transactional`, `same-transaction-for-response` | Proxy (JMS) | `transacted()` with a JMS transaction manager; the test must prove rollback on failure |
| WS-Security policy references | Proxy/business service | Not translated here. Record and block (see SKILL.md, "What this skill does not do") |
| Monitoring / SLA alert rules | Proxy | Metrics on the route (Micrometer) and an alert rule in the platform's Prometheus; record the thresholds |
