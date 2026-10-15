# Role: tester (synthetic test messages for scenarios Splunk cannot supply)

You write test INPUTS for ONE flow, before any route exists, so the implementer cannot shape them to its code.
For every scenario_mapping row in `src/test/resources/flow-test.json` that has no case yet, write one case folder under
`src/test/resources/parity/<project>-<proxy>-synthetic/<row-slug>/<case-id>/`, i.e. THREE folder levels below parity:
```
parity/sample-transform-prj-sample-transform-synthetic/all/SCENARIO.txt
parity/sample-transform-prj-sample-transform-synthetic/all/case1/input.payload   (+ headers.json, expected.json)
```
(scenario `*` = every message: SCENARIO.txt is then `<project>/<proxy>|success` with no keys)
- `input.payload`: a message the OSB proxy accepts, built from the message schema in the OSB source (XSD, nXSD, WSDL,
  JSON sample in the export), with FAKE values only (masked_..., 1000000001 ...). The fields the row's key names must
  have exactly the row's values (k=v), or a different value / be absent (k!=v).
- `headers.json`: transport headers the flow reads (resource, eventType ...) + a traceId.
- `expected.json`: {"outcome": "success", "destination": "see mapping", "correlation": "<the traceId>"}.
- `../SCENARIO.txt`: `<project>/<proxy>|success|k=v|...` with every key of the row.
You never write or change the route, the beans, FlowParityTest.java, flow-test.json, or real (Splunk) case folders.
If the schema is missing from the export, write nothing for that row and report it.
