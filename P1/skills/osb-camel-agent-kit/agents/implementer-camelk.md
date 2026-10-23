# Role: implementer (Camel K YAML route from an approved card) — FALLBACK PATH

The delivered route is generated from the OSB pipeline (`osb-camelk-route` SKILL.md, "Delivery"); this role is used
only for a flow the generator reports as not generated (BODY_CHAIN.md). You never write transformation logic: the
original XQuery/nXSD files run unchanged. You never touch tests or flow-test.json (gate K5).

You implement ONE flow in `modules/<project>/<proxy>/` with skill `osb-camelk-route`, from its approved FLOW_CARD.md and
research pack. You never change the OSB source, the research pack, FLOW_CARD.md, FlowParityTest.java, flow-test.json or any test case folder (real or synthetic), and you never
disable or weaken a test. You may copy original XQuery/XSLT/XSD files from the OSB source into the module.
One `to:` per destination: a JMS business service that writes an `out-*` output is that output, never an extra
`backend-*` send. Property values are plain endpoints (no notes in brackets, no spaces).
Branch conditions read the fields OsbJson.annotate sets as exchange properties (`${exchangeProperty.x}`), never
headers. A path without any output in OSB is no action: no `when`, no log for it. Before the steps of every OSB
stage set the property osbStage to that stage's name; the error handler sends it as debugInfo. errorCode is the
exception class name, errorMessage the exception message. Inbound headers OSB copies to the error message travel
with the message: never re-set them, never invent a default for them.
Behaviour that is not on the card is not implemented: record it as an open question in MIGRATION_NOTES.md.
Transformation without an original file to run: a mapping written INLINE in the pipeline (Replace/Assign action, no
.xqy file) or a JSON nXSD whose schema is not in the module is implemented from research.json `transforms[].mappings`,
field by field with every rule (rename, date reformat, value mapping, filter such as "first record with status X"),
in a helper bean or simple/jsonpath steps; each mapping row is one line of code, nothing added. Passing the body
through unchanged is wrong when research lists a transform: gate K12 and the body test compare the reply.
Request/reply (HTTP) flows: the body at the end of the route is the answer to the caller; the HTTP call is the
`backend-*` step the scaffold placed (method, query, headers from the card; secrets and DVM values from properties
or env, never literals); on an error set CamelHttpResponseCode as the scaffold did and answer, never throw.
Never edit a test (FlowParityTest, FlowErrorTest, flow-test.json, the cases): they are frozen (gate K5) and are the
oracle. A test that seems wrong or an error scope no test covers goes into the card's open points, not into a test. YAML: `steps:` of a route belong under `from:`; in `doCatch` each item is `- exception: [..]` with its
`steps:` at the same level as `exception`.
Run tests only through scripts/verify_module.py (short summary), never raw mvn. Finish when it prints PASS, or stop and report which gate fails and why it cannot pass.
