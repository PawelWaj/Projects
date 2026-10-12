# Programme rules for generated Camel code (template)

Fill this file once per client programme before Step 2. Each rule names the programme document it comes from; when a
rule and a generic mapping table disagree, this file wins. Mark undecided items OPEN: the skill never invents the value,
it puts an open item on the flow card. The rows below are the decisions every programme has to make; the example
column shows a typical choice, not a default.

## Runtime and packaging

| Decision | Example | Your programme | Source |
|---|---|---|---|
| Camel runtime | Camel on Spring Boot inside the owning domain's service; no Camel K, no operators | | |
| Module per OSB project | per domain, or a shared integration service for cross-domain flows | OPEN | |
| Base image | a vendor JRE image pinned by digest, non-root UID | | |
| Deployment | Helm or plain manifests through GitOps; environment chain Dev → E2E → UAT → PROD | | |
| Configuration | every endpoint, destination, timeout and retry is a per-environment property | | |

## Logging, metrics, diagnostics

| Decision | Example | Your programme | Source |
|---|---|---|---|
| Log target | stdout as JSON (for example ECS), never a file inside the container | | |
| Correlation id | the header the OSB pipeline used, carried in MDC | | |
| Personal data | no payloads above DEBUG; masking rules for national identifiers | | |
| Metrics | Micrometer + actuator endpoint; OSB alert actions become a WARN marker + counter | | |

## Secrets and identity

| Decision | Example | Your programme | Source |
|---|---|---|---|
| Secret delivery | a secret manager injecting files at runtime; nothing secret in Git or properties | | |
| Token issuer and m2m auth | one identity provider; JWT for user context, mTLS for service-to-service | | |
| WS-Security policies and service accounts | recorded, not translated; flow blocked until security decides | | |

## Messaging

| Decision | Example | Your programme | Source |
|---|---|---|---|
| Broker and protocol | ActiveMQ Artemis / AMQ Broker over AMQP 1.0 (Qpid JMS) with a failover URI | | |
| Destination management | created only through a Git register; auto-create off | | |
| Destination names | from the register | OPEN | |
| Dead-letter / expiry | every anycast address has both | | |
| Durable topic subscription | named subscription queue with a broker-side filter, consumed by FQQN | | |
| Delivery guarantees | duplicate-ID header on producers, idempotent consumers, local transactions | | |
| Multi-site | which site consumes a queue (never both at once) | | |

## Calls to and from the flow

| Decision | Example | Your programme | Source |
|---|---|---|---|
| Inbound cut-over | per-proxy route rule on the API gateway; callers unchanged | | |
| Outbound calls | service names through the mesh sidecar; host per environment | | |
| Coexistence bridges | JMS bridge while queues are still on the legacy broker | | |
| Dependencies (rules engine, content store, workflow engine) | endpoint switch per flow | OPEN | |
