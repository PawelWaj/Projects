# OSB transport → Camel component, and the programme constraints that decide it

The inventory reports `transport` (`provider-id`), `inbound`, `uris`, `binding`, `soap12`, `wsdl`, the outbound
properties (retry, timeout, load balancing) and the provider-specific properties per service. This table turns them
into a component choice and configuration keys. Component names must exist in the Camel version pinned in
`versions.md`; the artifact column is the Spring Boot starter.

## Inbound (proxy services)

| OSB transport + binding | Camel component | Artifact | Configuration keys (per proxy) | Note |
|---|---|---|---|---|
| `http` + SOAP (WSDL) | `cxf` (`cxf:bean:` endpoint, `dataFormat=PAYLOAD`, `wsdlURL=classpath:osb/<project>/<wsdl>`, `serviceName`, `portName`) | `camel-cxf-soap-starter` | `osb.proxy.<Name>.path` (= the OSB URI, kept so the Apigee route rule can switch per flow) | SOAP 1.1 vs 1.2 from the binding `isSoap12`; WSDL and port exactly as in the proxy. The contract does not change |
| `http` + XML / any XML / REST | `platform-http` (`platform-http:/<path>`) or `rest()` DSL | `camel-platform-http-starter` | `osb.proxy.<Name>.path` | OSB "any XML" proxies accept whatever came; keep that (no schema binding) unless the pipeline validates |
| `http` + `wadl` (REST proxy, 12c) | `rest()` DSL with the WADL's resources as `get/post` verbs | `camel-rest-starter`, `camel-platform-http-starter` | same | WADL methods map one-to-one |
| `ws` (WS-RM) | `cxf` with WS-RM features | `camel-cxf-soap-starter` + CXF WS-RM | | Rare. Mark complex; WS-RM across the gateway needs the security owner |
| `jms` (queue/topic consumer) | `amqp` (Qpid JMS, AMQP 1.0, port 5672) on this programme; `jms` with the broker's JMS client elsewhere | `camel-amqp-starter` | `osb.proxy.<Name>.destination`, `.concurrentConsumers`, `.transacted` | OSB JMS proxies are often XA/transactional with the outbound publish; decide `transacted()` on the card and test rollback |
| `sb` / `local` (proxy-to-proxy) | `direct:` (same module) or `seda:` | core | | A `local` proxy is a sub-route, not a service: fold it into the calling flow's module unless several flows call it |
| `file`, `ftp`, `sftp` | `file`, `ftp`, `sftp` | `camel-file`, `camel-ftp` | poll interval, path, move/delete, read lock | On OpenShift a `file` proxy needs a volume; the record names the PVC or the SFTP alternative |
| `email` | `mail` (`imap`/`pop3`) | `camel-mail` | | Mark complex |
| `mq` (IBM MQ) | `jms` with the IBM MQ client | `camel-jms` + IBM MQ allclient | | Not on this programme's target list; record |
| `jca` (DB adapter, AQ adapter, apps adapter) | DB: `sql`/`jdbc` with the same statement; AQ: `jms` via the AQ JMS library during coexistence, the target broker after the messaging cut | `camel-sql`, `camel-jdbc` | `osb.jca.<Name>.datasource` | JCA DB polling adapters have a "logical delete" or sequence strategy in the `.jca` file; reproduce it, do not approximate |
| `tuxedo`, `ejb`, `flow` (split-join inbound) | Case by case | | | Complex |

## Outbound (business services)

| OSB transport + binding | Camel endpoint | Artifact | Configuration keys (per business service `<Name>`) | Note |
|---|---|---|---|---|
| `http` + SOAP | `cxf:bean:<Name>Endpoint` (`dataFormat=PAYLOAD`, `wsdlURL`, `portName`, `address={{osb.business.<Name>.url}}`) | `camel-cxf-soap-starter` | `osb.business.<Name>.url`, `.timeout` (s → ms for `receiveTimeout`), `.retry-count`, `.retry-interval`, `.username`/`.password` (Vault) | `http:timeout` is the OSB response timeout in seconds; CXF `receiveTimeout` is milliseconds |
| `http` + XML / REST | `http:{{osb.business.<Name>.url}}` or `rest` producer | `camel-http-starter` | same | `request-method` from the provider-specific properties |
| `jms` **topic, durable subscription** (`is-queue=false`, `durable-subscription=true`, `topic-messages-distribution`, `message-selector`) | Named durable subscription queue on the multicast address, created by the Git register with the selector as its broker-side `filter`; the route consumes the FQQN `amqp:queue:<address>::<subscription>` | `camel-amqp-starter` | `osb.proxy.<Name>.subscription-fqqn`, `.concurrentConsumers`, `.transacted` | `OneCopyPerApplication` = one shared subscription for all replicas, which the FQQN queue gives without clientId handling. Keep the selector text verbatim (JMS selector syntax = Artemis filter syntax) and test both sides of it against a real broker. Never let OSB and Camel consume the same subscription at once |
| `jms` (producer) | `amqp:queue:<dest>` / `amqp:topic:<dest>` (`exchangePattern=InOnly` when `response-required=false`) | `camel-amqp-starter` | `osb.business.<Name>.destination`, `.response-required`, `.message-type` | The OSB URI `jms://host:port/<connFactory>/<destination>` names a WebLogic JNDI destination; the target destination on the new broker must exist, the messaging migration owns that (record it, do not create it) |
| `sb` (another proxy) | `direct:` | core | | |
| `file`/`ftp`/`sftp`/`email`/`mq`/`jca` | As inbound | | | |
| `dsp`, `tuxedo`, `ejb`, `ws` | Case by case | | | Complex |

## Retry, timeout and load-balancing settings

| OSB setting | Camel | Rule |
|---|---|---|
| `retry-count` N, `retry-interval` S (seconds), `retry-application-errors` | `onException(<transport exceptions>).maximumRedeliveries(N).redeliveryDelay(S*1000).useOriginalMessage()` scoped to the endpoint segment | With `retry-application-errors=false` (the common value) retry only on transport exceptions (`ConnectException`, `SocketTimeoutException`, CXF `Fault` with HTTP transport cause), never on SOAP faults or HTTP 5xx bodies. `useOriginalMessage()` because the body was transformed before the call |
| `timeout` | `receiveTimeout` (CXF) / `socketTimeout` (http) in ms | Keep the number; convert the unit |
| URI list + `load-balancing-algorithm` | Single OpenShift Service or external DNS name | Record the original list and algorithm; do not implement client-side balancing |
| `service-account` (static) | Basic auth from `{{osb.business.<Name>.username}}` / `{{...password}}` delivered by Vault | Never in Git, never in the URI |
| `service-account` (pass-through) | Propagate the inbound `Authorization` header | Only if the security design keeps end-to-end basic auth; usually it does not (JWT at the gateway): record |

## Programme constraints that override the generic choice

These come from the programme decisions of record (references/programme-rules.md); apply them unless the user says the skill runs elsewhere.

- **Camel on Spring Boot, Java DSL, inside the domain's Spring Boot services' namespaces.** No Camel K, no Quarkus,
  no separate integration platform, no operator (`ENV_PROMOTION_LLD.md` §2–§3). A migrated OSB project becomes a module
  deployed with its owning domain, or a small Spring Boot service of its own when flows serve several domains.
- **Messaging is Red Hat AMQ Broker (Artemis) over AMQP 5672**: `camel-amqp` with Qpid JMS, not the Core protocol
  client. Destinations are created by the messaging migration, not by the route.
- **Apigee stays in front.** The OSB proxy path is kept so the cutover is one Apigee target change per flow (roadmap
  bridge B2). The route does not validate JWTs itself unless the API security design says that service needs the user
  context; mTLS is the mesh's job.
- **Secrets from Vault through the Agent Injector** as properties files on an in-memory volume; the configuration keys
  above are read from there. No `Secret` objects, no credentials in `application.yml`.
- **Logs to stdout as ECS JSON**; no file appenders.
- **No new platform components** for the migration: no Coherence replacement cluster for result caching, no SNMP/email
  alert gateway. Each such OSB feature is recorded with the owner who decides whether it is dropped or rebuilt.
