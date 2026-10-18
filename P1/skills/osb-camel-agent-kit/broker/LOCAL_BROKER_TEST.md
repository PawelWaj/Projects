# One flow against a local Artemis broker (L2)

The L1 tests (`mvn test`) replace every queue by a mock. This step runs the **same YAML route, unchanged,** on
Camel Main against an Apache ActiveMQ Artemis broker on the developer machine and feeds it the **same test messages**
(the masked cases of `src/test/resources/parity`). It proves what the mocks cannot: the broker connection, the durable
topic subscription consumed by FQQN `<address>::<subscription>`, the broker-side filter (the OSB message selector),
the outgoing queues and the error queue. It does not prove production names (JNDI → Artemis mapping is the
platform's), HA, or the downstream consumers.

Verified on macOS with Artemis 2.44.0, Camel 4.18.4, JDK 21 (18 Oct 2026); the scripts run the Artemis CLI through
`java` directly, so the same commands work in Git Bash on Windows (no `cmd.exe` quoting of filters).

## 1 Once per machine

```
# .osb-kit.env (init_env.sh writes the defaults): ARTEMIS_HOME, ARTEMIS_BROKER, ARTEMIS_ZIP, ARTEMIS_USER
cd /e/Pawel/work && . ./.osb-kit.env
export ARTEMIS_PASSWORD='<choose one>'             # per session, never in a file
export ARTEMIS_ZIP=/e/Pawel/apache-artemis-<version>-bin.zip   # the download (artemis.apache.org, or the team's share)
bash $KIT/broker/artemis_setup.sh install          # unpacks next to the workspace -> prints the ARTEMIS_HOME line for .osb-kit.env
bash $KIT/broker/artemis_setup.sh create           # instance in ARTEMIS_BROKER: login required, ports 61616 / 5672 / 8161
```
`JAVA_HOME` must be the JDK the routes use (JDK 21): the broker and the clients on the same Java.

## 2 Every session

```
cd /e/Pawel/work && . ./.osb-kit.env && export ARTEMIS_PASSWORD='<the one chosen>'
bash $KIT/broker/artemis_setup.sh start            # Windows: opens the broker in its own window; macOS/Linux: service
bash $KIT/broker/artemis_setup.sh status           # console http://localhost:8161 (user ARTEMIS_USER)
```

## 3 Per flow

```
M=modules/<project>/<proxy>
bash $KIT/broker/artemis_prepare.sh $M             # subscription queue (+ selector as filter), one queue per output
bash $KIT/broker/run_local.sh $M                   # window 1: the route on Camel Main, logs here, Ctrl+C stops it
bash $KIT/broker/send_case.sh $M $M/src/test/resources/parity/<flow>/<scenario>/case1      # window 2: one real case
bash $KIT/broker/send_case.sh $M --raw 'not json at all' --headers '{"traceId":"t-err-1"}'  # an error case
bash $KIT/broker/queues.sh $M                      # the evidence: counts per queue
```

What the scripts read:

| File | Written by | Content |
|---|---|---|
| `src/main/resources/application.properties` | scaffold (frozen with the flow) | production descriptor: endpoints with the OSB (JNDI) names, selector, broker connection as `{{env:BROKER_URL}}`, `BROKER_USER`, `BROKER_PASSWORD` (no values) |
| `env/local.properties` | scaffold (`--refresh env` for an older module) | the same endpoint keys for the local broker: `jndi.` prefix stripped; passed as `-D` by `run_local.sh` |
| `pom.xml` profile `run-local` | scaffold (`--refresh pom` for an older module) | `camel-amqp` + `exec:java` (Camel Main) |

`run_local.sh` sets `BROKER_URL=amqp://localhost:5672`, `BROKER_USER`, `BROKER_PASSWORD` from `ARTEMIS_*`; on a cluster
the pod gets the same three variables from the platform (Secret), for example a failover URL.

## 4 What to expect

`queues.sh` after one case that reaches two outputs and one error case:

| queue | CONSUMER COUNT | MESSAGE COUNT | MESSAGES ADDED |
|---|---|---|---|
| `<subscription>` on the topic address | 1 (the route) | 0 | 2 (a message the selector rejects is not added) |
| each output queue of the case | 0 | 1 | 1 |
| the error queue | 0 | 1 | 1 |

The route log (window 1) shows the OSB log lines with the same text as in Splunk. Message bodies and properties are
visible in the console (`http://localhost:8161`, Queues → queue → Browse).

## 5 Known points

- Names: the local addresses are the JNDI names without `jndi.` (an assumption written into `env/local.properties`);
  the real mapping per environment is the platform's and is an open question on every card.
- The subscription queue is created by `artemis_prepare.sh` here; on the platform it comes from the Git register
  (never auto-create), with the same filter. A JMS shared durable subscription (`amqp:topic:<address>?subscriptionDurable=true&subscriptionShared=true&subscriptionName=<s>`) would create the same queue name itself; both styles are documented in AGENTS.md, the FQQN form is the kit's default.
- `send_case.sh` sends the body as a JMS TextMessage over AMQP with the case headers as string properties; the OSB
  caller may set other JMS properties (`JMSType`, priorities), not reproduced here.
- Transport retries (business service retry-count/interval) and transactions are visible here for the first time:
  compare the error queue message with the card.
- `queues.sh --drain <queue>` empties a queue between runs.
