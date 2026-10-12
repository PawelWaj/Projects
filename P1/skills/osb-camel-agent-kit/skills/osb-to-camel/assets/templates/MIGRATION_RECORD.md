# Migration record: {{proxy_ref}}

| | |
|---|---|
| **Flow card** | `migration/{{flow}}/FLOW_CARD.md` (approved {{approved_on}} by {{approved_by}}) |
| **Module** | `{{module}}`, routes `{{route_class}}`, resources `src/main/resources/osb/{{project}}/` |
| **Tier** | {{tier}} (score {{score}}) |
| **State** | implemented / tests green / parity pending / ready for cutover |
| **Effort actually spent** (design / code / tests / review) | | 

## 1. Outcome in five lines

- What the flow does:
- What changed structurally (one route per operation, sub-routes, publish as wire tap, ...):
- What is identical by construction (WSDL, path, transforms kept, error codes):
- What is different and why (see §4):
- What is still open (see §6):

## 2. Action-to-code map

| OSB action id | Pipeline / stage / action | Camel location (`class:line` or route id + step) | Mapping reference |
|---|---|---|---|
{{action_code_rows}}

## 3. Test results

| Test ID (card §8) | Class and method | Result | Evidence |
|---|---|---|---|
{{test_result_rows}}

Suite command and summary: `mvn -q test` → {{tests_run}} run, {{tests_failed}} failed, {{tests_skipped}} skipped.

## 4. Deviations from the original behaviour

| # | Original behaviour | Target behaviour | Reason | Approved by |
|---|---|---|---|---|

## 5. Configuration keys and their sources

| Key | Example value (non-prod) | Source in OSB | Delivered by (Vault / overlay / default) |
|---|---|---|---|
{{config_rows}}

## 6. Open items

| ID | Item | Owner | Blocks cutover? |
|---|---|---|---|
{{open_items}}

## 7. Cutover note (proposal; the operational decision is taken elsewhere)

- Apigee route rule to switch: proxy `{{apigee_proxy}}` target from OSB `{{osb_uri}}` to the service route `{{camel_path}}`, per flow, canary share first.
- OSB proxy stays deployed and reachable until the soak period ends; rollback = revert the route rule.
- Destinations that must exist on the target broker before cutover: {{destinations}}.
- Backend credentials in Vault before cutover: {{credential_keys}}.
- Parity status at cutover: {{parity_status}}.

## 8. Evidence files

- Inventory: `osb-inventory/flows/{{flow}}.json`
- Card: `migration/{{flow}}/FLOW_CARD.md`
- Fixtures: `src/test/resources/fixtures/{{flow}}/`, `src/test/resources/parity/{{flow}}/`
- Original transforms kept for the golden tests: `src/test/resources/osb-original/{{project}}/`
- Test report: `target/surefire-reports/`
