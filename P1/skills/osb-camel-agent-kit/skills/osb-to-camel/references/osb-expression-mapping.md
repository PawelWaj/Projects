# XQuery, XPath, XSLT and the message context: what to keep, what to change

The guiding rule: **keep the transforms, change the glue.** OSB transforms are XQuery 1.0 and XSLT 1.0. Saxon (via
`camel-saxon` for XQuery and `camel-xslt-saxon` for XSLT) executes XQuery 3.1 and XSLT 3.0, both backward compatible
with the 1.0 scripts except for the points below. Every transform is copied verbatim, edited only where this file
says, and proven by a golden test that runs the original and the migrated version side by side.

## 1. The `$body` root rule

In OSB, for a SOAP proxy, `$body` is the `soap:Body` element: `$body/ns:getContributorRequest` addresses the operation
element **inside** the Body. For an XML/any-XML proxy, `$body` is the payload wrapped in an OSB `Body` element.

| Target inbound component | What the Camel body is | Edit to the XQuery/XPath |
|---|---|---|
| `cxf` in `PAYLOAD` data format (default in the templates) | The content of the SOAP Body as a list of elements; for XQuery the templates bind the first element as `$body` **wrapped in a synthetic `<Body>`** so that `$body/ns:x` still works | None. This is why the templates wrap: zero edits to hundreds of queries beats editing every path |
| `cxf` in `MESSAGE`/`RAW` mode | The whole SOAP envelope | Paths need `/soap:Envelope/soap:Body/` prefixes. Avoid this mode for migrated flows |
| `platform-http` / `rest` (XML payload) | The payload root element | Wrap in `<Body>` the same way (the template's `OsbContext` processor does it) or change `$body/ns:x` to `/ns:x`. Prefer wrapping, for the same reason |
| `amqp`/`jms` text message | The text payload, parsed | Same as `platform-http` |

The wrapper is applied by `OsbBodyWrapper` in the templates, and it follows OSB's boundaries exactly: `wrap()` once at
the inbound (it also captures the transport headers as `osb.inbound.*` properties), **`unwrap()` before every outbound
call** (route node, service callout, publish), so a backend never sees the wrapper, `rewrap()` after a request-response
call so the response pipeline sees the backend response as `$body`, and `unwrap()` at the reply. A callout's request is
a pipeline variable, sent bare; its response is stored as a variable, not as `$body`. Forgetting the unwrap before a
backend call is the single most likely defect in a hand-written route; the template puts the two processors around
every `.to()`.

## 2. Context variables → Camel

| OSB | Meaning | Camel | Note |
|---|---|---|---|
| `$body` | SOAP Body content / payload | Message body (wrapped, see §1) | |
| `$header` | SOAP Header element | `CamelCxfMessage` headers in CXF; otherwise a property `osb.header` holding the parsed header element | WS-Addressing and security headers live here; if a pipeline reads them, note it on the card |
| `$inbound/ctx:transport/ctx:request/tp:headers/http:<Name>` | Inbound HTTP header | Camel header `<Name>` | Camel keeps the original case; OSB XQuery used the element name |
| `$inbound/ctx:transport/ctx:request/tp:user-metadata` | Transport metadata | Headers with the component's names (`CamelHttpUri`, `CamelHttpMethod`, …) | |
| `$inbound/ctx:service/ctx:operation`, `$operation` | WSDL operation | `operationName` header (CXF) or `SOAPAction` | |
| `$inbound/ctx:transport/ctx:uri`, `ctx:mode` | Inbound URI and request/response mode | `CamelHttpPath`, exchange pattern | |
| `$outbound/ctx:transport/ctx:request/tp:headers/...` | Outbound headers set by `transportHeaders` | `.setHeader(...)` before the `.to()` | Remember the `copy-all` trap in the action mapping |
| `$outbound/ctx:transport/ctx:response/...` | Backend response metadata | `CamelHttpResponseCode` and headers after the `.to()` | |
| `$fault/ctx:errorCode`, `ctx:reason`, `ctx:details`, `ctx:location` (`node`, `pipeline`, `stage`, `error-handler`, `path`), `ctx:java-exception` | Error context, populated only in error handlers | Headers `osb.fault.*` set by the templates' `OsbFaultProcessor` from the caught exception; the original fault XSLT runs on a synthetic `<ctx:fault>` element built from them | Keeps the original error XSLTs runnable. Codes are `OSB-38xxxx` in 12c (`BEA-` in 11g): transport 380000–380999, pipeline runtime 382000–382499, pipeline actions 382500–382999, WS-Security 386000–386999; the processor maps exception types to the nearest range, user-raised codes pass through unchanged |
| `$attachments` | MIME attachments | CXF attachments / `AttachmentMessage` | Rare; mark complex |
| user variables (`assign varName`) | Pipeline-scoped | Exchange properties of the same name | Properties, not headers: they must not leak onto the wire |
| `$messageID` | Unique id | `${exchangeId}` | In the parity ignore list |

## 3. XQuery 1.0 → Saxon XQuery 3.1: what actually breaks

| Construct | Status | Action |
|---|---|---|
| Core XQuery 1.0 (FLWOR, constructors, `fn:*` 1.0 functions) | Runs unchanged | Nothing |
| `xquery version "1.0";` prolog | Accepted by Saxon | Leave as is (Saxon treats it as 3.1) |
| `(:: OracleAnnotationVersion ... ::)` and `(:: pragma ... ::)` comments | Comments | Leave |
| `declare namespace`, `declare variable $x external` | Supported | Bind externals from headers/properties, see §5 |
| `fn-bea:*` functions | **Do not exist in Saxon** | Rewrite per §4, or import the shim module |
| `fn:doc("...")` to OSB resources (`doc("ContributorIntegration/XSD/...")`) | Resolves against the OSB config, not a file system | Replace with a classpath URI and a `URIResolver`, or inline the lookup table as a module variable; the golden test will show if semantics changed |
| Collations, `fn:string-join` on mixed sequences, implicit timezone | Minor differences possible | Covered by the golden test; fix per finding |
| XQuery Update (`insert node`, `replace value of`) | Not in Saxon-HE | Rewrite as a constructor expression (rare in OSB, which did updates with Insert/Replace actions instead) |
| Oracle-specific type coercions (`xs:date` from `yyyy-MM-dd` strings) | Standard | Nothing; `fn-bea` date formatting is the issue, not the types |

## 4. `fn-bea:` replacement table

The shim module `assets/templates/xquery/fn-bea-shim.xqy` implements the common functions in XQuery 3.1 under the
same namespace URI (`http://www.bea.com/xquery/xquery-functions`), so that **the original query runs unchanged** in the
golden test and in production, with one added line: `import module namespace fn-bea = "http://www.bea.com/xquery/xquery-functions" at "fn-bea-shim.xqy";`.
Prefer the import over rewriting. Rewrite only when the shim cannot express the function (SQL, credentials).

| `fn-bea:` function | Shim / replacement | Note |
|---|---|---|
| `date-to-string-with-format(fmt, date)`, `dateTime-to-string-with-format(fmt, dateTime)`, `time-to-string-with-format` | Shim: Java-style pattern → `fn:format-date`/`format-dateTime` picture string translation for the common patterns (`yyyy`, `MM`, `dd`, `HH`, `mm`, `ss`, `SSS`, literal quotes) | Patterns outside the table raise an error in the shim rather than guessing; add the pattern to the shim when found |
| `date-from-string-with-format(fmt, str)`, `dateTime-from-string-with-format` | Shim: parse the common patterns into `xs:date`/`xs:dateTime` | Same policy |
| `trim(str)`, `trim-left`, `trim-right` | `normalize-space` is **not** equivalent (it collapses inner spaces); shim uses `replace()` with anchored patterns | |
| `uuid()` | Shim: `random-number-generator()` based or, better, bind a header `osb.uuid` generated by Camel and read it | In the parity ignore list either way |
| `inlinedXML(str)` | `fn:parse-xml(str)` (3.1) | |
| `serialize(node)` | `fn:serialize(node)` (3.1) | Output method differences possible; golden test |
| `lookupBasicCredentials(ref)` | **Not shimmed.** Credentials come from Vault properties; the route sets the header, the query reads an external variable | Record on the card |
| `execute-sql(datasource, rowElement, sql, params)` | **Not shimmed.** Replace the enrichment with a `sql:` endpoint step before the transform and pass the result as an external variable | Appears in enrichment flows; mark the flow `complex` |
| `generate-guid()` | As `uuid()` | |
| `format-number(...)` variants | `fn:format-number` (3.1) with picture translation | |
| `fn-bea:isUserInGroup`, `fn-bea:isUserInRole` | **Not shimmed.** Authorization moved to the gateway/mesh; record and block | |
| `fn-bea:format-base64Binary`, `fn-bea:decode-xml`, `fn-bea:encode-xml` | Shim or `fn:` equivalents | |

Any `fn-bea:` function not in this table: stop, add a row (shim or "not shimmed, because"), then continue. The
inventory lists every function used in the export, so the table is complete for the estate after the first pass.

## 5. Running OSB expressions: one helper, OSB semantics, zero edits

Camel's own `xquery` language binds the message as the context item and exposes headers as `$in.headers.<name>`
(Camel XQuery language documentation); it knows nothing about `$body`, `$memberResp` or `$inbound`. So an OSB
expression pasted into `.xquery("$body/ns:x")` fails with an undeclared variable. The templates therefore run **every
OSB expression, inline or stored, through `OsbXQuery`** (Saxon s9api, in `OsbSupport.java`):

- `OsbXQuery.of("<inline OSB expression>").ns(NS)` for `assign`, `replace` with inline XQuery, `ifThenElse` and
  `routeTable` conditions, `log`/`alert` expressions, `transportHeaders` values. It declares every `$name` the
  expression references as an external variable and binds it at evaluation time: `$body` to the wrapped document,
  `$inbound` to a `ctx:inbound/ctx:transport/ctx:request/tp:headers/http:<Name>` element built from the captured
  headers, `$fault` to the `<ctx:fault>` element the fault processor built, `$operation` to the operation name, and
  any other `$name` to the exchange property of that name (DOM nodes for elements, atomics for strings/numbers).
  Adapters: `.asString()` / `.asNode()` (Camel `Expression`), `.asPredicate()` (Camel `Predicate`),
  `.replaceBodyContentsOnly()` / `.replaceBody()` (Camel `Processor`, the two Replace modes).
- `OsbXQuery.resource("osb/<project>/Transform/<Name>.xqy").ns(NS).param(<osbParam>, <property>[, <path>])` for
  `xqueryTransform` resources: the stored query keeps its own `declare variable $x external;` lines and each parameter
  is bound by its OSB name from the exchange property; the optional path is the OSB `<con1:path>` (`$memberResp/mem:...`)
  evaluated inside the property.
- `NS` is the pipeline's `userNsDecl` list (the inventory reports it per pipeline) plus the OSB context namespaces.

Expressions you write yourself (new routing logic, test helpers) may use Camel's `xquery()`/`xpath()` freely; copied
OSB expressions never, so that the golden tests and the card's action-to-code map stay literal.

## 6. XPath in conditions and locations

Most OSB conditions are XPath-compatible one-liners; they still go through `OsbXQuery` (§5) for the variable binding.
Always carry the pipeline's namespace declarations into `ns(...)`; a missing declaration does not error, it makes the
condition false.

## 7. XSLT 1.0 → Saxon XSLT 3.0

Runs unchanged. Watch: `xsl:output method="xml" indent="yes"` adds whitespace Camel then sends to the backend (normalize
in the golden comparison, keep in production only if the original did); EXSLT extensions (`exslt:node-set`) are
supported by Saxon; Oracle `oraxsl:` extensions are not (rare in OSB, common in SOA Suite).

## 8. What never to do

- Do not re-implement a working XQuery in Java "for performance" during migration. Equivalence first; profile later.
- Do not hand-write the expected output of a golden test. The original transform produces it.
- Do not change element order, whitespace handling or namespace prefixes in constructors "to clean them up"; backends
  with schema validation or XPath-based routing see the difference.
