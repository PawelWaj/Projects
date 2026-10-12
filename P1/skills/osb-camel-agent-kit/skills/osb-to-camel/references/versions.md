# Default versions and artifacts (verified 2026-10-05; re-verify before pinning in a build)

The skill proposes these defaults when the target repository does not pin its own. A team's existing BOM always
wins; record the difference on the flow card.

## Runtime

| Item | Default | Why | Source |
|---|---|---|---|
| Apache Camel | **4.18.x LTS** | The last LTS line on Spring Boot 3 (`camel-4.18.0/parent/pom.xml` pins `spring-boot-version` 3.5.10). Camel 4.22 LTS pins Spring Boot 4.1.0; moving there is a Spring Boot 4 decision for the whole programme, not for a migration module | https://camel.apache.org/releases/ ; raw `parent/pom.xml` of tags `camel-4.18.0` and `camel-4.22.0` |
| Spring Boot | **3.5.x** (as pinned by the Camel BOM) | Match the Camel line; the base image is `ubi9/openjdk-21-runtime` (programme decision) | `camel-spring-boot-bom` |
| Java | 21 | Base image decision | `BASE_IMAGE_DECISION.md` |
| Saxon | Saxon-HE **12.9** (transitive via `camel-saxon` 4.18.0) | XQuery 3.1 / XSLT 3.0; runs OSB's XQuery 1.0 scripts | `camel-saxon-4.18.0.pom` on Maven Central |

## Camel starters used by the templates (`org.apache.camel.springboot`)

`camel-spring-boot-starter`, `camel-cxf-soap-starter` (SOAP in/out, `cxf:` endpoints), `camel-platform-http-starter`
(REST/any-XML inbound), `camel-http-starter` (REST outbound), `camel-saxon-starter` (`xquery:` component and
language), `camel-xslt-saxon-starter`, `camel-validator-starter`, `camel-amqp-starter` (Qpid JMS, AMQP 1.0 to Red Hat
AMQ Broker on 5672), `camel-micrometer-starter`. Optional per card: `camel-sql-starter` (JCA DB adapters),
`camel-file-starter`/`camel-ftp-starter`, `camel-mail-starter`, `camel-caffeine-starter` (result caching),
`camel-javascript` (only if a 12c JavaScript action is kept as script).

## Test stack

| Item | Artifact | Version verified | Note |
|---|---|---|---|
| Camel Spring test support | `org.apache.camel:camel-test-spring-junit5` | Camel version | `@CamelSpringBootTest`, `@UseAdviceWith`, `@MockEndpoints`, `@MockEndpointsAndSkip`; `AdviceWith.adviceWith(context, routeId, builder)` with `replaceFromWith`, `weaveById`, `mockEndpointsAndSkip` |
| WireMock | `org.wiremock:wiremock-standalone` | 3.11.0 stable (a 4.0.0 beta exists; stay on 3.x) | SOAP matching with `matchingXPath` and namespace bindings; recording via `startRecording`/`snapshot` |
| Testcontainers (Artemis) | `org.testcontainers:testcontainers-activemq` (new id; legacy `org.testcontainers:activemq`) + `junit-jupiter` | Testcontainers BOM | `org.testcontainers.activemq.ArtemisContainer` |
| Testcontainers (Oracle, for JCA DB flows) | `org.testcontainers:testcontainers-oracle-free` | Testcontainers BOM | image `gvenzl/oracle-free:slim-faststart` |
| XMLUnit | `org.xmlunit:xmlunit-core`, `org.xmlunit:xmlunit-assertj3` | 2.11.0 core / 2.13.0 assertj3 seen; use one matching pair | `isSimilarTo`, `ignoreWhitespace`, node filters for the ignore list |
| H2 (simple DB lookups without Docker) | `com.h2database:h2` | 2.5.252 (Maven Central release, checked 2026-10-11) | `MODE=Oracle`; only plain SELECT/INSERT; procedures, sequences, MERGE, polling need the Oracle container |
| GreenMail (email transport) | `com.icegreen:greenmail-junit5` | 2.1.14 (checked 2026-10-11) | 2.1.x line = Jakarta Mail (Spring Boot 3); `GreenMailExtension`, `ServerSetupTest.SMTP_IMAP` |
| Nimbus JOSE + JWT (security mocks) | `com.nimbusds:nimbus-jose-jwt` | 10.10 (checked 2026-10-11) | Test-only RSA keys and signed JWTs; JWKS served by WireMock. Spring Security may already bring a version: use the BOM's |
| SFTP server (file transport) | image `atmoz/sftp:alpine` via `GenericContainer` | pin a digest in the mirror | No test dependency beyond Testcontainers |
| Testcontainers line | `testcontainers-oracle-free` 2.0.5 is the latest release; 1.x id was `oracle-free` (1.21.4) | checked 2026-10-11 | Follow whatever Testcontainers BOM the team pins; artifact ids changed in 2.x (`testcontainers-<module>`) |
| Local runs | Camel JBang (`camel run`, `--runtime=spring-boot`) | current | For trying a route before the module exists |

## Things to verify on the pinned version before generating code

- The templates evaluate OSB expressions with Saxon s9api directly (`OsbXQuery`), so no `camel-saxon` language
  binding convention is relied on; `camel-saxon-starter` stays for the `xquery:`/`xslt-saxon:` components and Saxon itself.
- The exact `AdviceWithRouteBuilder` method set on the pinned Camel (the templates use `replaceFromWith`,
  `mockEndpointsAndSkip`, `weaveById`).
- CXF `PAYLOAD` data format behaviour for SOAP 1.2 proxies.

## Precedents worth knowing

- `apache/camel-upgrade-recipes` (OpenRewrite): Camel's own position is that automated migration "assists manual
  migration" rather than replacing it; this skill takes the same posture (deterministic inventory and scaffolding,
  judgement on the card, generation from the approved card).
- camel-kit: see `camel-kit-integration.md`.
