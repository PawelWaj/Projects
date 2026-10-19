# Run @@PROJECT@@

No pom. The route is `@@ROUTE@@`, the shared kamelets and Java helpers are in `../Common-setup`, OSB's own
transformation files (.xqy, nXSD .xsd) in `transformations/`. Needs Java 21 and Maven with access to the Maven
repository (`export MVN_ARGS="-s <settings.xml>"` if Maven needs it): when JBang / the `camel` CLI are not installed,
`run-local.sh` takes both from there (`../Common-setup/jbang.sh`, Camel JBang @@CAMEL@@ from its Maven artifact), so no
internet is needed. Everything below runs in Git Bash in this folder.

## 1 Tests, no broker

```
bash run-local.sh test
```
(with JBang installed also `@@TESTS@@`). Each test file loads the route unchanged with every endpoint replaced by direct:/mock:,
so no broker and no connection factory are needed. Per case: the queue OSB used (and no other), the original message
on the error queue, no transport headers on the business queues, well-formed XML where OSB sends XML, and equality
with OSB's real output where `expected-output.xml` exists.

## 2 Against a local Artemis

```
export ARTEMIS_HOME=<unzipped apache-artemis folder> BROKER_PASSWORD=<broker password>   # BROKER_USER=artemis, BROKER_URL=tcp://localhost:61616
bash run-local.sh run      # starts the routes; the source kamelet creates the durable subscription with the OSB selector
```
Second window, same exports:
```
@@SENDS@@
bash run-local.sh stat     # MESSAGES ADDED per queue
```
`send` adds the properties the selector needs but the logged case lacks (OSB does not log them, e.g. eventType) with
the first value the selector allows. A case whose properties the selector excludes is dropped by the broker, as OSB's
subscription would drop it.

## What the route does to the message body

See `docs/<proxy>/BODY_CHAIN.md`: read from the OSB pipeline, per business service.
