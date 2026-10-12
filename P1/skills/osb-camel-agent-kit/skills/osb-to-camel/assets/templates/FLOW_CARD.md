# Flow card: {{proxy_ref}}

| | |
|---|---|
| **OSB project / folder** | {{project}} |
| **Proxy service** | `{{proxy_ref}}` ({{proxy_path}}) |
| **Pipeline** | `{{pipeline_ref}}` ({{pipeline_path}}) |
| **Triage** | {{tier}} (score {{score}}): {{reasons}} |
| **Target** | Camel {{camel_version}} on Spring Boot {{spring_boot_version}}, Java DSL, module `{{module}}`, package `{{package}}` |
| **Status** | draft / approved / implemented / tested / recorded |
| **Owner of the approval** | |

## 1. Contract (must not change)

| Item | Value | Source |
|---|---|---|
| Inbound transport | {{proxy_transport}} | proxy `endpointConfig/provider-id` |
| Inbound URI (kept for the Apigee route rule) | {{proxy_uris}} | proxy `URI` |
| Binding | {{binding}}, SOAP 1.2 = {{soap12}} | proxy `binding` |
| WSDL / port | {{wsdl}} | proxy `binding/wsdl` |
| Operations | {{operations}} | pipeline operational branch, WSDL |
| Security on the inbound | {{inbound_security}} | proxy provider-specific, WS-policy |
| JMS topic subscription (if `is-queue=false`) | durable / distribution / selector from the inbound transport row | proxy `inbound-properties`; target = named subscription queue + broker filter, consumed by FQQN (transport mapping) |
| Camel inbound endpoint | | decided here |

## 2. Pipeline walk (one row per OSB action, in execution order)

| # | Pipeline / stage | OSB action | What it does (from the XML) | Proposed Camel step | Decision / deviation reason |
|---|---|---|---|---|---|
{{action_rows}}

Error handlers in scope: {{error_handler_scopes}}

## 3. Context variables

| OSB variable | Set by | Read by | Camel: header / property / body | Note |
|---|---|---|---|---|
{{variable_rows}}

## 4. Backends (business services)

| Business service | Transport / binding | URI(s) | Timeout | Retries (count / interval / app errors) | Service account | Camel endpoint | Config keys |
|---|---|---|---|---|---|---|---|
{{backend_rows}}

## 5. Transforms

| Resource | Kind | Lines | XQuery version | `fn-bea:` used | External params | Plan (keep + shim / keep / rewrite because) |
|---|---|---|---|---|---|---|
{{transform_rows}}

## 6. Error handling

| Scope | OSB handler | Actions in the handler | Camel construct | Fault shape returned |
|---|---|---|---|---|
{{error_rows}}

## 7. Non-functional and platform items

| Item | OSB value | Target decision | Owner if open |
|---|---|---|---|
| Retries / timeouts | see §4 | | |
| Throttling | {{throttling}} | | |
| Result caching | {{result_caching}} | | |
| Transactions (JMS) | {{transactional}} | | |
| WS-Security policies | {{ws_policies}} | | |
| Alert destinations | {{alert_destinations}} | | |
| Personal data in log expressions | | | |
| Correlation header | | | |

## 8. Test matrix (every row becomes a test)

| ID | Type | Scenario | Input fixture | Expected from | Mocks |
|---|---|---|---|---|---|
{{test_rows}}

## 9. Open items

| ID | Item | Why it blocks or not | Owner |
|---|---|---|---|
{{open_items}}

## 10. Approval

- [ ] Mapping decisions reviewed against the pipeline XML (not only the inventory)
- [ ] Contract unchanged (WSDL, port, SOAPAction, URI path)
- [ ] Every backend has config keys and a mock plan
- [ ] Every transform has a golden plan
- [ ] Every open item has an owner
- Approved by: ______ on ______
