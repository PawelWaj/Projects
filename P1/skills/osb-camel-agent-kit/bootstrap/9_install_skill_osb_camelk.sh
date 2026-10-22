#!/usr/bin/env bash
# Paste into the migration workspace root on the VDI and run: bash 9_install_skill_osb_camelk.sh
# Skill osb-camelk-route (research pack -> Camel K YAML module + tests + gates) under .pi/skills/ + implementer role + pi runners (one flow, whole domain).
set -euo pipefail
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/SKILL.md")"
cat > '.pi/skills/osb-camelk-route/SKILL.md' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SKILL_MD'
---
name: osb-camelk-route
description: "Turn one OSB proxy's research pack (research.json from osb-research) plus the OSB pipeline into a Camel K integration in YAML DSL with tests (Camel 4.18, mock endpoints, real masked log cases). The delivered route is GENERATED (body_chain.py reads what the pipeline does to the body, assemble_jbang.py writes the route that runs OSB's own XQuery/nXSD files, no pom, JBang tests); the agent-implemented work module is the fallback for flows the generator cannot build. Use when asked to build, implement, generate or migrate a Camel K route from a research pack, a pipeline or FLOW_CARD.md, or when the user says osb-camelk-route."
---

# Research pack + OSB pipeline → Camel K route (YAML DSL) + tests

Input: `research/<project>/<proxy>/research.json` (the shareable pack, check PASS), the OSB project in the export
(`.pipeline`, `.xqy`, nXSD `.xsd`) and, on the client machine, the masked task-1 cases.

## Two outputs, one source of truth

**Delivery (what goes to the client, current path, since 19 Oct 2026):** `delivery/<app>/<project>/`, no pom.
`scripts/body_chain.py <proxy>.pipeline --summary` reads from the pipeline what OSB does to the body on the way to
each business service (nXSD Native-To-XML, `assign` + `xqueryTransform` + `replace $body`, `$request` restored on
the error path) and the format each queue gets (`xml` | `native`). `scripts/assemble_jbang.py <ws> --osb-app <export>`
then writes per project one `<domain>-route.yaml` that runs that chain with OSB's own files copied unchanged into
`transformations/` (`Common-setup/OsbNxsd.java` = JSON→XML per the nXSD schema, `Common-setup/OsbXQuery.java` =
the `.xqy` on Saxon with `fn-bea:uuid`), the Artemis kamelets (core JMS, OSB selector + durable subscription inside
the kamelet), `test/<Flow>Test.java` run by `jbang` (endpoints replaced by direct:/mock:, no broker, no connection
factory), `run-local.sh`, `README.md`, `set-env.sh`, `run.sh`, `tools/`. Routing per message comes from the frozen
scenario table of the work module (`flow-test.json`), i.e. from research checked against every real case. No agent
writes transformation or route code on this path. Read `docs/<proxy>/BODY_CHAIN.md` ("Not generated / to check")
after every run: an `unknown_tags`, `format=unknown` or a TODO there means the generator does not know that OSB
construct yet; fix the generator or fall back to the work module for that flow, never patch the generated YAML.

**Work module (`modules/<project>/<proxy>/`, Maven, agent-implemented route):** where research, task-1 cases,
scenario table and gates live, and the fallback when the generator cannot build a flow (XML-To-Native, service
callouts, request-reply, `fn-bea` functions other than uuid). Steps 3–7 below are this path. Why it is no longer the
delivery: on the first two flows the agent invented fields and defaults, produced JSON where OSB sends XML and
edited tests to pass (caught by gate K5 and by the client reviewer). Pattern: `pilot/sample-adjustment` in the repo.

## Rules

1. **Tests first and fixed.** `FlowParityTest.java` and `flow-test.json` are generated from research.json and are
   hash-checked (gate K5). Never edit them, never add `@Disabled`. If a test is wrong, the research is wrong: say so.
2. **The card decides.** Nothing is implemented before `FLOW_CARD.md` has `Status: approved` and an approver. Every
   behaviour in the route traces to a card section; anything not on the card is an open question, not code.
3. **Same behaviour as OSB, quirks included**: same outputs per scenario, body forwarded unchanged when OSB forwards it,
   same log line text under logName `oracle.osb.logging.pipeline`, same error headers, same retries.
   A difference you cannot avoid goes into `MIGRATION_NOTES.md` (what, why, who must accept it).
4. **No infrastructure in code.** Endpoints are `{{properties}}`; no hosts, ports, credentials (gate K4).
5. **Original transforms stay.** XQuery/XSLT/XSD files are copied from the OSB source unchanged (delivery:
   `transformations/`, run by `OsbXQuery`/`OsbNxsd`; work module: `src/main/resources/osb/`, `camel-saxon`); never
   rewritten "because it is cleaner". They stay on the client machine, never in a research pack.
5b. **A logged body is OSB's output only when the pipeline leaves the body unchanged.** The business-service log line
   of a transforming flow logs `$request` again (inside a SOAP Body); comparing against it proves nothing. Golden
   `expected-output.xml` comes only from what OSB really sent (captured from the queues / message tracing).
6. Component options: check the Camel 4.18 docs; do not guess. Patterns proven on the pilot: `references/yaml-patterns.md`.

## Steps

1. **Scaffold (script):**
   `python <skill>/scripts/scaffold_camelk.py research/<project>/<proxy> -o modules/<project>/<proxy> --project <project> [--parity task1/fixtures/parity]`
   Writes the route skeleton (ids `branch-*`, `out-*`, `backend-*`; gaps marked `TODO(flow-card)`), properties,
   helper bean, generated tests, `FLOW_CARD.md` (draft). Route, properties and card are written once; tests always
   follow research.json.
2. **Approval (human):** a person checks the card against `RESEARCH.md`, resolves or accepts each open question, sets
   `Status: approved`, `Approver:`, `Date:`.
2b. **Test inputs where Splunk has none (pi tester, before the route):** every `scenario_mapping` row needs a case
   (gate K9). Rows without a real Splunk message get a synthetic case written by the tester role
   (`agents/tester-camelk.md`): fake values, built from the message schema in the OSB source, under
   `src/test/resources/parity/<project>-<proxy>-synthetic/`. Then
   `scaffold_camelk.py … --freeze-synthetic` records their hashes, so gate K5 also protects them from the implementer.
3. **Implement the route (work module / fallback only):** replace every `TODO(flow-card)` from the card. Keep the ids. Conditions read
   `${exchangeProperty.<field>}` (set by OsbJson.annotate), never headers; a path with no output in OSB gets no
   `when`; set the property `osbStage` before each OSB stage (debugInfo); errorCode = exception class name. Log templates become simple
   expressions with the same literal text. Conditions use the headers the helper bean sets (`${header.x}`).
3b. **Request/reply HTTP flows:** the scaffold makes the proxy a `platform-http` entry, each HTTP business service a
   `backend-*` call (mocked in tests, answering with its stub) and the end of the route the reply; on an error the
   route answers with `CamelHttpResponseCode` (from research) instead of sending to a queue. A mapping OSB writes
   inline in the pipeline (no .xqy file) or a JSON nXSD without its schema in the module is implemented from
   research.json `transforms[].mappings`, row by row (helper bean or jsonpath); never a pass-through when research
   lists a transform. Gate K12 requires an expected reply per case, so a pass-through fails.
4. **Error tests:** `src/test/java/<pkg>/FlowErrorTest.java` is generated as a compiling start (invalid payload,
   every backend failing): extend it, keep its helpers. At least one test per error scope on the card: invalid
   payload, each output/backend failing (mock `whenAnyExchangeReceived` throwing), retries counted
   (`getReceivedCounter()`), error headers and original body on the error output, generated traceId. Set retry delays
   to 0 through properties in the test, never by changing production defaults.
5. **Stubs:** one file per backend whose response is used: `src/test/resources/stubs/<backend>.json|xml|txt`,
   shape from research Q8, fake values only.
6. **Run until green:** `python <skill>/scripts/verify_module.py modules/<project>/<proxy>` (mvn test + gates, ~30
   lines; the full Maven log stays in target/verify-mvn.log: never read it whole, never run raw mvn). Gates:
   K1 card approved · K2 no TODO(flow-card) in src/main · K3 every route id present · K4 no infrastructure ·
   K5 generated tests and frozen synthetic cases untouched, nothing disabled · K6 stubs · K7 error tests ≥ error scopes ·
   K8 tests green · K9 every scenario_mapping row has a case · K10 every property value a plain endpoint (no notes,
   no spaces) and every `{{key}}` defined · K11 each destination once: a JMS business service that writes an `out-*`
   IS that output, so never add a `backend-<x>-bs` send next to `out-<x>` (production would get every message twice) ·
   K12 request/reply: every case that ends in the reply has `expected-output.json|xml`.
7. **Prove the tests bite:** `python <skill>/scripts/mutate_route.py modules/<project>/<proxy> --mvn "mvn -B -q -s ~/.m2/settings.xml"`
   breaks the route on purpose (conditions negated, outputs swapped or dropped, retries removed); every mutation must
   make a test fail. A survivor means a missing test: add it to FlowErrorTest, never weaken the route to pass.
8. **Matrix:** `python <skill>/scripts/test_matrix.py modules/<project>/<proxy>` → `TEST_MATRIX.md` (P scenarios with
   real messages, E error tests, K gates, M mutations).
8b. **Against a broker (L2):** a LOCAL Artemis on the client machine (never the client's E2E broker): delivery
   `bash run.sh e2e` (routes started with `camel run`, one real case per scenario sent as the OSB caller, per-queue
   deltas, `test/BROKER_RUN.txt`); work module `broker/e2e_local.sh`. Local queue names = JNDI names without `jndi.`
   (assumption until the platform mapping is decided). What it proves: selector + durable subscription, routing to the
   right queues, XML from the XQuery arrives. What it does not prove: byte equality with OSB, the real broker.
9. **Report** (five lines): proxy, gates result, tests run/failed/skipped (skipped = golden outputs pending),
   differences recorded in MIGRATION_NOTES.md, open questions left.

## What the generated parity test proves

Each case is sent to `direct:in` as request/reply. Request-response proxies (HTTP, local) have an output `reply`:
the answer to the caller, checked like a queue (present, no exception, body = golden where one exists).
Each real masked case is sent to `direct:in`. Its `SCENARIO.txt` is matched against `scenario_mapping` in research.json
(`k=v` equal, `k!=v` different or missing, first row wins) and must reach exactly those outputs, no others, with the
correlation header. Where `expected-output.json|xml` exists (the original XQuery run by golden_runner), the body must
be equal. Invalid JSON must reach the error output. The scenario fields the route branches on must be task-1
scenario dims (`SCENARIO_DIMS=...,body:<path>` from research `scenario_dims`), or the mapping cannot match.
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SKILL_MD
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/assemble_flat.py")"
cat > '.pi/skills/osb-camelk-route/scripts/assemble_flat.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_ASSEMBLE_FLAT_PY'
#!/usr/bin/env python3
"""Delivery layout: one FLAT folder per OSB project, all its flows in one route file, common kamelets shared. Stdlib only.

    assemble_flat.py <workspace> [-o <out>] [--app <name>] [--projects 'a-prj|b-prj']

From the finished per-proxy modules (<workspace>/modules/<project>/<proxy>/, where pi, the frozen tests and the gates
work) it writes:

  <out>/<app>/
    Common-setup/
      osb-jms-source.kamelet.yaml      consume a destination   (today AMQP 1.0 / Qpid JMS; core JMS = edit these two only)
      osb-jms-sink.kamelet.yaml        send to a destination
    <project>/
      <domain>-route.yaml              every flow of the project; <domain> = project name without -prj
      <Flow>Transformer.java           helper bean of each flow (was OsbJson), <Flow> = proxy name in CamelCase
      <Flow>TransformerTest.java       the frozen parity tests of the flow (was FlowParityTest)
      <Flow>TransformerErrorTest.java  the error tests of the flow (was FlowErrorTest)
      application.properties           endpoints per flow as <proxy>.<key> through the kamelets, OSB (JNDI) names
      pom.xml                          mvn test / mvn -Prun-local exec:java in this folder (flat source layout)
      src/test/resources/<proxy>/      flow-test.json, parity cases (masked), stubs
      src/env/local.properties         the same keys for a local broker (broker/run_local.sh <this folder>)
      src/docs/<proxy>/                FLOW_CARD.md, MIGRATION_NOTES.md, TEST_MATRIX.md, GATES.json
      RUN_LOCAL.md, run-local.sh       how to run it without the kit (mvn test; queues, run, send, stat on a local Artemis)

Every property placeholder of a flow gets the prefix <proxy>. (two flows of one project never share a key); every
test also sets the other flows' endpoints to direct:/mock:, because the one route file starts all routes. Prints
{"projects": n, "flows": n, "out": ...}. The per-proxy modules stay the source of truth: rerun after every build."""
import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_local_doc  # noqa: E402

KAMELET_LOCATION = "{{env:KAMELET_LOCATION:file:../Common-setup}}"
SOURCE_KAMELET = """apiVersion: camel.apache.org/v1
kind: Kamelet
metadata:
  name: osb-jms-source
  labels:
    camel.apache.org/kamelet.type: source
spec:
  definition:
    title: OSB JMS source
    description: |
      Consumes the destination an OSB proxy listened on. destination = queue:<name>, or for a durable topic
      subscription queue:<topic address>::<subscription> (FQQN). The broker connection is the amqp component of the
      application (BROKER_URL / BROKER_USER / BROKER_PASSWORD). Binding to core JMS (tcp://...:61616) = change the
      uri below to jms:{{destination}} and the connection factory in application.properties; the routes stay.
    required: [destination]
    type: object
    properties:
      destination:
        title: Destination
        type: string
  dependencies:
    - "camel:amqp"
    - "camel:kamelet"
  template:
    from:
      uri: "amqp:{{destination}}"
      steps:
        - to: "kamelet:sink"
"""
SINK_KAMELET = """apiVersion: camel.apache.org/v1
kind: Kamelet
metadata:
  name: osb-jms-sink
  labels:
    camel.apache.org/kamelet.type: sink
spec:
  definition:
    title: OSB JMS sink
    description: |
      Sends to the destination an OSB business service wrote to: destination = queue:<name> or topic:<name>. Body and
      headers unchanged. Same connection and the same binding note as osb-jms-source.
    required: [destination]
    type: object
    properties:
      destination:
        title: Destination
        type: string
  dependencies:
    - "camel:amqp"
    - "camel:kamelet"
  template:
    from:
      uri: "kamelet:source"
      steps:
        - to: "amqp:{{destination}}"
"""


def camel_case(s: str) -> str:
    return "".join(p[:1].upper() + p[1:] for p in re.split(r"[^A-Za-z0-9]+", s) if p)


def props_of(path: Path) -> list[tuple[str, str]]:
    out = []
    if path.is_file():
        for ln in path.read_text(encoding="utf-8").splitlines():
            if ln.strip() and not ln.lstrip().startswith(("#", "!")) and "=" in ln:
                k, v = ln.split("=", 1)
                out.append((k.strip(), v.strip()))
    return out


def prefix_placeholders(text: str, x: str) -> str:
    """{{key}} / {{key:default}} -> {{<x>.key...}}; {{env:...}} and {{sys:...}} stay."""
    return re.sub(r"\{\{(?!env:|sys:)([\w.-]+)", lambda m: "{{" + x + "." + m.group(1), text)


def unique_ids(text: str, x: str) -> str:
    """Node and route ids must be unique in one CamelContext: every id (and routeConfigurationId) gets the prefix <x>-
    unless it already starts with the proxy name."""
    def fix(m: re.Match) -> str:
        v = m.group(3)
        return m.group(0) if v == x or v.startswith(x + "-") else f"{m.group(1)}{m.group(2)}{x}-{v}{m.group(2)}"
    return re.sub(r"^(\s*(?:-\s+)?(?:id|routeConfigurationId):\s*)([\"']?)([\w.-]+)\2\s*$", fix, text, flags=re.M)


def via_kamelet(key: str, value: str) -> str:
    """amqp:queue:N / amqp:topic:N -> kamelet:osb-jms-source|sink?destination=queue:N (others unchanged)."""
    m = re.match(r"amqp:((?:queue|topic):.+)$", value)
    if not m:
        return value
    kind = "source" if key == "flow.input" else "sink"
    return f"kamelet:osb-jms-{kind}?destination={m.group(1)}"


def is_endpoint_key(k: str) -> bool:
    return k == "flow.input" or k.startswith(("out.", "backend."))


def test_props(test: str) -> list[str]:
    m = re.search(r"@CamelMainTest\(properties\s*=\s*\{(.*?)\}\)", test, re.S)
    return re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1)) if m else []


def flow_test_props(x: str, raw: list[str]) -> list[str]:
    out = []
    for p in raw:
        k, _, v = p.partition("=")
        if not k.startswith("camel."):
            k = f"{x}.{k}"
        v = v.replace("direct:in", f"direct:in-{x}") if v == "direct:in" else v
        v = re.sub(r"^mock:(out|backend)-", lambda m: f"mock:{x}-{m.group(1)}-", v)
        out.append(f"{k}={v}")
    return out


def rewrite_test(text: str, x: str, flow: str, pkg: str, all_props: list[str]) -> str:
    text = re.sub(r"^package\s+[\w.]+;", f"package {pkg};", text, count=1, flags=re.M)
    text = text.replace("FlowParityTest", f"{flow}TransformerTest").replace("FlowErrorTest", f"{flow}TransformerErrorTest")
    text = text.replace("OsbJson", f"{flow}Transformer")
    text = text.replace('"src/test/resources/', f'"src/test/resources/{x}/')
    text = text.replace('"direct:in"', f'"direct:in-{x}"')
    text = re.sub(r'"mock:(out|backend)-', lambda m: f'"mock:{x}-{m.group(1)}-', text)
    body = ", ".join(json.dumps(p) for p in all_props)
    return re.sub(r"@CamelMainTest\(properties\s*=\s*\{.*?\}\)", lambda _m: f"@CamelMainTest(properties = {{{body}}})", text,
                  count=1, flags=re.S)


def class_renames(m: Path, flow: str) -> tuple[set, dict]:
    """Every class of a flow module -> its flat name. Main: OsbJson -> <Flow>Transformer, X -> <Flow>X. Test: the two
    frozen tests -> <Flow>Transformer[Error]Test, helpers -> <Flow>X (with 'Test' in the name, so the flat pom compiles
    them with the tests). Returns (old packages, {old simple name: new simple name})."""
    pkgs, ren = set(), {}
    for part, test in (("src/main/java", False), ("src/test/java", True)):
        for j in (m / part).rglob("*.java"):
            pm = re.search(r"^package\s+([\w.]+);", j.read_text(encoding="utf-8"), re.M)
            if pm:
                pkgs.add(pm.group(1))
            st = j.stem
            if st == "OsbJson":
                new = f"{flow}Transformer"
            elif st in ("FlowParityTest", "FlowErrorTest"):
                new = f"{flow}Transformer{'Error' if st == 'FlowErrorTest' else ''}Test"
            else:
                new = st if st.startswith(flow) else flow + st
                if test and "Test" not in new:
                    new = f"{flow}Test{st}"
            ren[st] = new
    return pkgs, ren


def apply_renames(text: str, pkgs: set, ren: dict, pkg: str) -> str:
    for old in sorted(pkgs, key=len, reverse=True):
        text = re.sub(rf"\b{re.escape(old)}\b", pkg, text)
    if ren:
        rx = re.compile(r"\b(" + "|".join(re.escape(k) for k in sorted(ren, key=len, reverse=True)) + r")\b")
        text = rx.sub(lambda g: ren[g.group(1)], text)
    return text


def pom_for(project: str, short: str, modules: list[Path]) -> str:
    deps = set()
    for m in modules:
        pom = (m / "pom.xml").read_text(encoding="utf-8") if (m / "pom.xml").is_file() else ""
        deps |= set(re.findall(r"<artifactId>(camel-(?:saxon|xslt-saxon|xpath|jaxb|http|rest|sql|jdbc|ftp|sftp|file|mail))</artifactId>", pom))
    extra = "\n    ".join(f"<dependency><groupId>org.apache.camel</groupId><artifactId>{d}</artifactId></dependency>" for d in sorted(deps))
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!-- Flat delivery module of OSB project {project}: {short}-route.yaml + <Flow>Transformer.java + <Flow>TransformerTest.java
     in this folder (assembled by assemble_flat.py from the per-proxy modules). mvn test runs every flow's frozen tests;
     mvn -Prun-local exec:java runs the route file on Camel Main (broker/run_local.sh <this folder>). Kamelets come from
     ../Common-setup (KAMELET_LOCATION). camel.version = the programme's LTS pin; -Dcamel.version=<x> to try another. -->
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>osb.{re.sub(r'[^a-z0-9-]', '', project.lower())}</groupId>
  <artifactId>{short}</artifactId>
  <version>0.1.0-SNAPSHOT</version>
  <properties>
    <camel.version>4.18.4</camel.version>
    <junit.version>5.12.2</junit.version>
    <maven.compiler.release>21</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
  <dependencyManagement>
    <dependencies>
      <dependency><groupId>org.apache.camel</groupId><artifactId>camel-bom</artifactId><version>${{camel.version}}</version><type>pom</type><scope>import</scope></dependency>
      <dependency><groupId>org.junit</groupId><artifactId>junit-bom</artifactId><version>${{junit.version}}</version><type>pom</type><scope>import</scope></dependency>
    </dependencies>
  </dependencyManagement>
  <dependencies>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-main</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-yaml-dsl</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-direct</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-log</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-bean</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-jackson</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-kamelet</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-amqp</artifactId></dependency>
    {extra or "<!-- no transform dependencies -->"}
    <dependency><groupId>org.slf4j</groupId><artifactId>slf4j-simple</artifactId><version>2.0.17</version><scope>runtime</scope></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-test-main-junit5</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-mock</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter-params</artifactId><scope>test</scope></dependency>
  </dependencies>
  <build>
    <!-- flat layout: sources, tests and the route file sit in this folder -->
    <sourceDirectory>${{basedir}}</sourceDirectory>
    <testSourceDirectory>${{basedir}}</testSourceDirectory>
    <resources>
      <resource><directory>${{basedir}}</directory><includes><include>*-route.yaml</include><include>application.properties</include></includes></resource>
    </resources>
    <testResources>
      <testResource><directory>src/test/resources</directory></testResource>
    </testResources>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>3.13.0</version>
        <configuration><release>21</release></configuration>
        <executions>
          <execution><id>default-compile</id><configuration>
            <includes><include>*.java</include></includes><excludes><exclude>*Test*.java</exclude></excludes>
          </configuration></execution>
          <execution><id>default-testCompile</id><configuration>
            <testIncludes><testInclude>*Test*.java</testInclude></testIncludes>
          </configuration></execution>
        </executions>
      </plugin>
      <plugin><groupId>org.apache.maven.plugins</groupId><artifactId>maven-resources-plugin</artifactId><version>3.3.1</version></plugin>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-surefire-plugin</artifactId>
        <version>3.5.3</version>
        <configuration>
          <statelessTestsetReporter implementation="org.apache.maven.plugin.surefire.extensions.junit5.JUnit5Xml30StatelessReporter">
            <usePhrasedTestCaseMethodName>true</usePhrasedTestCaseMethodName>
          </statelessTestsetReporter>
        </configuration>
      </plugin>
    </plugins>
  </build>
  <profiles>
    <profile>
      <id>run-local</id>
      <build><plugins><plugin>
        <groupId>org.codehaus.mojo</groupId><artifactId>exec-maven-plugin</artifactId><version>3.5.0</version>
        <configuration><mainClass>org.apache.camel.main.Main</mainClass><classpathScope>runtime</classpathScope></configuration>
      </plugin></plugins></build>
    </profile>
  </profiles>
</project>
"""


def assemble(ws: Path, out: Path, app: str, rx: str | None) -> dict:
    root = out / app
    (root / "Common-setup").mkdir(parents=True, exist_ok=True)
    (root / "Common-setup/osb-jms-source.kamelet.yaml").write_text(SOURCE_KAMELET, encoding="utf-8")
    (root / "Common-setup/osb-jms-sink.kamelet.yaml").write_text(SINK_KAMELET, encoding="utf-8")
    n_proj = n_flow = 0
    for pdir in sorted(p for p in (ws / "modules").iterdir() if p.is_dir()):
        project = pdir.name
        if rx and not re.fullmatch(rx, project):
            continue
        mods = sorted(m for m in pdir.iterdir() if (m / ".scaffold.json").is_file() and list((m / "src/main/resources/routes").glob("*.yaml")))
        if not mods:
            continue
        short = re.sub(r"-prj$", "", project)
        pkg = "osb." + re.sub(r"[^a-z0-9]", "", project.lower())
        dst = root / project
        if dst.exists():
            shutil.rmtree(dst)
        dst.mkdir(parents=True)
        # every flow's test endpoints, for the tests of all flows (the one route file starts every route)
        own = {}
        for m in mods:
            pt = next(m.rglob("FlowParityTest.java"), None)
            own[m.name] = flow_test_props(m.name, test_props(pt.read_text(encoding="utf-8")) if pt else [])
        route_parts = [f"# {short}-route.yaml: every flow of OSB project {project} in one route file (assembled from the",
                       "# per-proxy modules by assemble_flat.py; edit there, not here). Endpoints are properties <proxy>.<key>",
                       "# (application.properties), sent through the common kamelets of ../Common-setup."]
        props = [f"# {project}: production descriptor of all flows. Endpoints with the OSB (JNDI) names through the common",
                 "# kamelets; the broker connection from the environment (BROKER_URL / BROKER_USER / BROKER_PASSWORD), no values.",
                 f"camel.main.name={short}", f"camel.main.routes-include-pattern=classpath:{short}-route.yaml",
                 f"camel.component.kamelet.location={KAMELET_LOCATION}"]
        broker = [f"{k}={v}" for k, v in props_of(mods[0] / "src/main/resources/application.properties") if k.startswith(("camel.beans.", "camel.component.amqp."))]
        props += broker
        local = ["# LOCAL broker run of all flows (broker/run_local.sh <this project folder>): every line is passed as -D.",
                 "# ASSUMPTION: local address = JNDI name without 'jndi.' (the platform's mapping is open)."]
        for m in mods:
            x, flow = m.name, camel_case(m.name)
            meta = json.loads((m / ".scaffold.json").read_text(encoding="utf-8"))
            pkgs, ren = class_renames(m, flow)
            for r in sorted((m / "src/main/resources/routes").glob("*.yaml")):
                t = unique_ids(prefix_placeholders(r.read_text(encoding="utf-8"), x), x)
                t = re.sub(r"beanType:\s*[\w.]+\.OsbJson\b", f"beanType: {pkg}.{flow}Transformer", t)
                t = apply_renames(t, pkgs, ren, pkg)
                route_parts += ["", f"# ======== flow {x} (proxy {meta.get('proxy', x)}) ========", t.rstrip("\n")]
            props += ["", f"# ---- flow {x}"]
            for k, v in props_of(m / "src/main/resources/application.properties"):
                if k.startswith("camel.beans.") and not k.startswith("camel.beans.amqpConnectionFactory"):
                    props.append(f"{k}={apply_renames(v, pkgs, ren, pkg)}")      # a flow's own bean (pi may add one)
                    continue
                if k.startswith("camel."):
                    continue
                props.append(f"{x}.{k}={via_kamelet(k, v) if is_endpoint_key(k) else apply_renames(v, pkgs, ren, pkg)}")
            for k, v in props_of(m / "env/local.properties"):
                if not k.startswith("camel."):
                    local.append(f"{x}.{k}={via_kamelet(k, v) if is_endpoint_key(k) else v}")
            for j in (m / "src/main/java").rglob("*.java"):
                t = re.sub(r"^package\s+[\w.]+;", f"package {pkg};", j.read_text(encoding="utf-8"), count=1, flags=re.M)
                (dst / f"{ren[j.stem]}.java").write_text(apply_renames(t, pkgs, ren, pkg), encoding="utf-8")
            all_props = own[x] + [p for y, ps in own.items() if y != x for p in ps]
            all_props += [f"{y}.flow.input=direct:in-{y}" for y in own if not any(p.startswith(f"{y}.flow.input=") for p in all_props)]
            for j in (m / "src/test/java").rglob("*.java"):
                t = rewrite_test(j.read_text(encoding="utf-8"), x, flow, pkg, all_props)
                (dst / f"{ren[j.stem]}.java").write_text(apply_renames(t, pkgs, ren, pkg), encoding="utf-8")
            tr = m / "src/test/resources"
            if tr.is_dir():
                shutil.copytree(tr, dst / "src/test/resources" / x)
                meta_inf = dst / "src/test/resources" / x / "META-INF"
                if meta_inf.is_dir():           # service files (e.g. a test context customizer) must sit at the classpath root
                    for f in sorted(p_ for p_ in meta_inf.rglob("*") if p_.is_file()):
                        tgt = dst / "src/test/resources/META-INF" / f.relative_to(meta_inf)
                        tgt.parent.mkdir(parents=True, exist_ok=True)
                        add = apply_renames(f.read_text(encoding="utf-8"), pkgs, ren, pkg)
                        tgt.write_text((tgt.read_text(encoding="utf-8") if tgt.is_file() else "") + add, encoding="utf-8")
                    shutil.rmtree(meta_inf)
                ft = dst / "src/test/resources" / x / "flow-test.json"
                if ft.is_file():
                    ft.write_text(re.sub(r'"mock:(out|backend)-', lambda mm: f'"mock:{x}-{mm.group(1)}-', ft.read_text(encoding="utf-8")),
                                  encoding="utf-8")
            docs = dst / "src/docs" / x
            docs.mkdir(parents=True, exist_ok=True)
            for f in ("FLOW_CARD.md", "MIGRATION_NOTES.md", "TEST_MATRIX.md", "GATES.json", "MUTATION.json"):
                if (m / f).is_file():
                    shutil.copy2(m / f, docs / f)
            n_flow += 1
        (dst / f"{short}-route.yaml").write_text("\n".join(route_parts) + "\n", encoding="utf-8")
        (dst / "application.properties").write_text("\n".join(props) + "\n", encoding="utf-8")
        (dst / "src/env").mkdir(parents=True, exist_ok=True)
        (dst / "src/env/local.properties").write_text("\n".join(local) + "\n", encoding="utf-8")
        (dst / "pom.xml").write_text(pom_for(project, short, mods), encoding="utf-8")
        run_local_doc.write(dst)          # RUN_LOCAL.md + run-local.sh: the reviewer runs it without the kit
        (dst / ".gitignore").write_text("target/\nsrc/test/resources/*/parity/\n.camel-jbang/\n", encoding="utf-8")
        n_proj += 1
    return {"projects": n_proj, "flows": n_flow, "out": str(root)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workspace", type=Path)
    ap.add_argument("-o", "--out", type=Path)
    ap.add_argument("--app", default=Path(os.environ.get("APP", "osb-app")).name)
    ap.add_argument("--projects", help="regex on whole project names")
    a = ap.parse_args()
    if not (a.workspace / "modules").is_dir():
        sys.exit(f"no {a.workspace}/modules")
    print(json.dumps(assemble(a.workspace, a.out or a.workspace / "delivery", a.app, a.projects)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_ASSEMBLE_FLAT_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/assemble_jbang.py")"
cat > '.pi/skills/osb-camelk-route/scripts/assemble_jbang.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_ASSEMBLE_JBANG_PY'
#!/usr/bin/env python3
"""Delivery layout WITHOUT a pom: Camel JBang / Camel K files, the route generated from the OSB pipeline. Stdlib only.

    assemble_jbang.py <workspace> --osb-app <OSB application folder> [-o <out>] [--app <name>] [--projects 'a|b']

Per OSB project (from the work modules <ws>/modules/<project>/<proxy>/ and the OSB export):

  <out>/<app>/
    Common-setup/
      osb-jms-source.kamelet.yaml    Artemis core JMS: queue, or topic + shared durable subscription + OSB selector
      osb-jms-sink.kamelet.yaml      Artemis core JMS, text message, persistent
      OsbNxsd.java, OsbXQuery.java   nXSD JSON->XML and the OSB XQuery engine (//DEPS, the same for every flow)
    <project>/
      <domain>-route.yaml            every flow of the project; the body chain per output is the OSB pipeline's
                                     (body_chain.py): nXSD translation, the flow's own .xqy files, original body
      transformations/               the .xqy and nXSD .xsd files copied unchanged from the OSB export
      application.properties         endpoints (OSB JNDI names) through the kamelets; broker from BROKER_URL/USER/PASSWORD
      local.properties               the same keys for a local Artemis (names without jndi.)
      run-local.sh, RUN_LOCAL.md     camel run against a local Artemis, send a case, queue counts
      test/<Flow>Test.java           tests, run with `jbang test/<Flow>Test.java` (JUnit via //DEPS, no pom, no broker)
      test/resources/<proxy>/        flow-test.json + the masked cases
      docs/<proxy>/                  FLOW_CARD.md, TEST_MATRIX.md, GATES.json, BODY_CHAIN.md
      camel-k/                       integration.yaml, configmaps.yaml, DEPLOY.md (camelk_manifests.py)

Routing comes from the frozen scenario table of the module (flow-test.json, checked against the Splunk cases);
transformations never come from an agent: what OSB does to the body is read from the pipeline and run with OSB's
own files. Prints {"projects": n, "flows": n, "out": ...}; per flow what could not be generated goes to BODY_CHAIN.md."""
from __future__ import annotations

import argparse
import json
import xml.etree.ElementTree as ET
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import body_chain  # noqa: E402
import camelk_manifests  # noqa: E402

TPL = HERE.parent / "assets/templates"
CAMEL_VERSION = "4.18.4"


def camel_case(s: str) -> str:
    return "".join(p[:1].upper() + p[1:] for p in re.split(r"[^A-Za-z0-9]+", s) if p)


def props_of(f: Path) -> dict:
    out = {}
    for ln in f.read_text(encoding="utf-8").splitlines() if f.is_file() else []:
        if ln.strip() and not ln.lstrip().startswith(("#", "!")) and "=" in ln:
            k, v = ln.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def jms_parts(v: str) -> tuple[str, str, str]:
    """(kind, destination, subscription) from an amqp:/jms:/kamelet value."""
    m = re.search(r"(?:destination=)?(?:amqp:|jms:)?(queue|topic):([^?&\s]+)", v)
    if not m:
        return "", "", ""
    kind, name = m.group(1), m.group(2)
    if "::" in name:
        return "topic", name.split("::", 1)[0], name.split("::", 1)[1]
    sub = re.search(r"(?:durableSubscriptionName|subscriptionName)=([^&\s]+)", v)
    return kind, name, sub.group(1) if sub else ""


def source_uri(v: str, selector: str) -> str:
    kind, dest, sub = jms_parts(v)
    if not dest:
        return v
    if kind == "topic" or sub:
        u = f"kamelet:osb-jms-source?destinationType=topic&destination={dest}"
        if sub:
            u += f"&durable=true&subscriptionName={sub}"
    else:
        u = f"kamelet:osb-jms-source?destinationType=queue&destination={dest}"
    return u + (f"&selector=RAW({selector})" if selector else "")


def sink_uri(v: str) -> str:
    kind, dest, _ = jms_parts(v)
    return f"kamelet:osb-jms-sink?destinationType={kind or 'queue'}&destination={dest}" if dest else v


def local_name(dest_uri: str) -> str:
    return re.sub(r"destination=jndi\.", "destination=", dest_uri)


def match_output(service: str, keys: list) -> str | None:
    """The flow-test output key a business service writes to (exact, else the shortest key containing it)."""
    if service in keys:
        return service
    hits = sorted((k for k in keys if re.search(rf"(^|-){re.escape(service)}(-|$)", k)), key=len)
    return hits[0] if hits else None


def condition(scenario: str, fields: dict) -> str | None:
    """A scenario row of flow-test.json as a Camel simple predicate: hdr_x = header x, other fields = exchange
    properties set by OsbNxsd.fields from the original payload. None = the row matches every message."""
    if not scenario or scenario == "*":
        return None
    parts = []
    for p in scenario.split("|"):
        neg = "!=" in p
        k, v = p.split("!=" if neg else "=", 1)
        ref = f"${{header.{k[4:]}}}" if k.startswith("hdr_") else f"${{exchangeProperty.osbField_{k}}}"
        if k.startswith("hdr_") is False:
            fields.setdefault(k, k)
        v = v.replace("'", "\\'")
        parts.append(f"{ref} {'!=' if neg else '=='} '{v}'")
    return " && ".join(parts)


def chain_steps(chain: list, files: dict, notes: list, osb_vars: dict) -> list:
    """YAML step lines (indent-free) for a body chain."""
    out = []
    for c in chain:
        if isinstance(c, str):
            continue
        if c["op"] == "nxsd":
            if "native-to-xml" not in c.get("type", "").lower():
                notes.append(f"nXSD {c.get('type')} ({c.get('nxsd')}) is not generated yet: XML-To-Native needs the reverse converter")
                out.append(f"# TODO nXSD {c.get('type')} {c.get('nxsd')}: not generated")
                continue
            xsd = files.get(c.get("nxsd_ref"))
            root = (c.get("root") or "").split(":")[-1]
            out += [f'- setProperty: {{name: osbNxsd, constant: "{xsd}"}}', f'- setProperty: {{name: osbNxsdRoot, constant: "{root}"}}',
                    "- bean: {beanType: osb.common.OsbNxsd, method: toXml}"]
        elif c["op"] == "xquery":
            xqy = files.get(c.get("resource_ref"))
            params = c.get("params") or {}
            main = next((n for n, p in params.items() if re.fullmatch(r"\$body(/\*)?", p.replace(" ", ""))), next(iter(params), "input"))
            out += [f'- setProperty: {{name: osbXQuery, constant: "{xqy}"}}', f'- setProperty: {{name: osbXQueryParam, constant: "{main}"}}']
            for n, p in params.items():
                if n == main:
                    continue
                m = re.fullmatch(r"\$(\w+)", p.strip())
                if m and re.search(r"uu?id", m.group(1), re.I):
                    out.append(f'- setProperty: {{name: "osbVar.{n}", simple: "${{header.traceId}}"}}')
                elif m and m.group(1) in osb_vars:
                    out.append(f'- setProperty: {{name: "osbVar.{n}", simple: "${{exchangeProperty.{m.group(1)}}}"}}')
                else:
                    notes.append(f"XQuery {c.get('resource')}: parameter ${n} = {p[:80]} is not bound (only the body and pipeline variables are)")
            out.append("- bean: {beanType: osb.common.OsbXQuery, method: transform}")
        elif c["op"] == "original":
            out.append('- setBody: {simple: "${exchangeProperty.request}"}')
        elif c["op"] == "replace":
            notes.append(f"replace $body with an expression the generator does not translate: {c.get('text', '')[:100]}")
            out.append("# TODO replace $body (see BODY_CHAIN.md)")
    return out

LEVELS = {"debug": "DEBUG", "info": "INFO", "warning": "WARN", "warn": "WARN", "error": "ERROR"}


def split_args(text: str) -> list:
    """Top-level comma split of an XQuery argument list (quotes and brackets respected)."""
    out, cur, depth, q = [], "", 0, ""
    for ch in text:
        if q:
            cur += ch
            q = "" if ch == q else q
        elif ch in "'\"":
            q, cur = ch, cur + ch
        elif ch in "([{":
            depth, cur = depth + 1, cur + ch
        elif ch in ")]}":
            depth, cur = depth - 1, cur + ch
        elif ch == "," and depth == 0:
            out, cur = out + [cur.strip()], ""
        else:
            cur += ch
    return out + ([cur.strip()] if cur.strip() else [])


def osb_value(arg: str, assigns: dict, corr: str, seen: tuple = ()) -> str | None:
    """One XQuery operand of a log or header expression as Camel simple, None if the generator cannot translate it."""
    a = arg.strip()
    m = re.fullmatch(r"(?:fn:|fn-bea:)?(?:serialize|string|data|normalize-space|trim)\((.*)\)", a, re.S)
    if m:
        return osb_value(m.group(1), assigns, corr, seen)
    if re.fullmatch(r"'[^']*'|\"[^\"]*\"", a, re.S):
        return a[1:-1].replace("${", "$\\{")
    h = re.search(r"user-header\[@name\s*=\s*['\"]([^'\"]+)['\"]\]", a)
    if h and a.startswith("$inbound"):
        return f"${{exchangeProperty.osbIn_{h.group(1)}}}"
    if a.startswith("$fault"):
        return "${exception.message}"
    m = re.fullmatch(r"\$(\w+)(/\*)?", a)
    if not m:
        return None
    v = m.group(1)
    if v == "body":
        return "${body}"
    if v == "request":
        return "${exchangeProperty.request}"
    if re.search(r"trace|uu?id", v, re.I):
        return "${exchangeProperty.osbTraceId}"      # set at entry, survives removeHeaders
    if v in assigns and v not in seen:
        return osb_value(assigns[v], assigns, corr, seen + (v,))
    return None


def osb_log(entry: dict, assigns: dict, corr: str, notes: list) -> str:
    """An OSB Log action as a Camel log step with the same text (concat(...) -> one simple expression)."""
    e = entry.get("expr", "").strip()
    m = re.fullmatch(r"(?:fn:)?concat\((.*)\)", e, re.S)
    parts = split_args(m.group(1)) if m else [e]
    text = ""
    for p in parts:
        v = osb_value(p, assigns, corr)
        if v is None:
            notes.append(f"log text: operand {p[:60]} is not translated, written as [?]")
            v = "[?]"
        text += v
    text = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'- log: {{loggingLevel: {LEVELS.get(entry.get("level", "info"), "INFO")}, logName: oracle.osb.logging.pipeline, message: "{text}"}}'


def inbound_headers(bc: dict) -> list:
    """User headers of the inbound message that logs or error headers read (saved at entry, before anything is removed)."""
    names = set()
    for r in bc["outputs"] + bc["error_outputs"]:
        texts = [x["expr"] for k in ("logs_before", "logs_out", "logs_resp") for x in r.get(k) or []]
        texts += list((r.get("header_exprs") or {}).values())
        texts += [h for h in r.get("headers") or [] if not (r.get("header_exprs") or {}).get(h)]
        texts += [v for v in (bc.get("assigns") or {}).values() if v.startswith("$inbound")]      # headers read through a variable
        for t in texts:
            names.update(re.findall(r"user-header\[@name\s*=\s*['\"]([^'\"]+)['\"]\]", t))
        for h in r.get("headers") or []:
            if not (r.get("header_exprs") or {}).get(h) or (r.get("header_exprs") or {}).get(h) == "expression":
                names.add(h)
    return sorted(n for n in names if n not in ("errorCode", "errorMessage", "debugInfo"))


def common_prefix(chains: list) -> list:
    if not chains:
        return []
    pre = []
    for steps in zip(*chains):
        if all(json.dumps(s, sort_keys=True) == json.dumps(steps[0], sort_keys=True) for s in steps):
            pre.append(steps[0])
        else:
            break
    return pre


def indent(lines: list, n: int) -> list:
    return [" " * n + ln for ln in lines]


def route_for(project: str, x: str, cfg: dict, bc: dict, files: dict, notes: list, selector: str = "") -> tuple[str, list]:
    keys = list(cfg["outputs"])
    err = cfg.get("error_output", "")
    chains = {}
    for r in bc["outputs"]:
        k = match_output(r["service"], keys)
        if k is None:
            notes.append(f"business service {r['service']} matches no output of flow-test.json ({keys})")
            continue
        chains.setdefault(k, r["chain"])
    pre = common_prefix(list(chains.values()))
    fields: dict = {}
    osb_vars = {}
    e_headers = sorted({h for r in bc["error_outputs"] for h in r["headers"]}, key=lambda h: ["errorCode", "errorMessage", "debugInfo", "traceId"].index(h) if h in ("errorCode", "errorMessage", "debugInfo", "traceId") else 9)
    corr = cfg.get("correlation_header", "traceId")
    assigns = bc.get("assigns") or {}
    ins = inbound_headers(bc)
    L = [f"# ======== flow {x}: generated from the OSB pipeline (body_chain.py) and the frozen scenario table; do not edit",
         "# by hand, regenerate (assemble_jbang.py). Body per output: see docs/" + x + "/BODY_CHAIN.md",
         "- route:", f"    id: {x}", "    from:", f'      uri: "{{{{{x}.flow.input}}}}"']
    if selector:
        L.append(f"      # OSB selector, applied by the broker on the input endpoint ({x}.flow.input in application.properties): {selector}")
    L.append("      steps:")
    S = [f"- setHeader: {{name: {corr}, simple: \"${{header.{corr}}} ?: ${{uuid(random)}}\"}}      # TraceID: kept if the message has one, else generated",
          f'- setProperty: {{name: osbTraceId, simple: "${{header.{corr}}}"}}']
    S += [f'- setProperty: {{name: osbIn_{h}, simple: "${{header.{h}}}"}}      # inbound {h}, for logs and the error path' for h in ins]
    S += ['- setProperty: {name: request, simple: "${bodyAs(String)}"}      # OSB: assign request = $body']
    all_logs = [r.get("logs_before") or [] for r in bc["outputs"]]
    pre_logs = []
    for grp in zip(*all_logs) if all_logs else []:
        if all(json.dumps(g, sort_keys=True) == json.dumps(grp[0], sort_keys=True) for g in grp):
            pre_logs.append(grp[0])
        else:
            break
    has_osb_logs = any(r.get("logs_before") or r.get("logs_out") or r.get("logs_resp") for r in bc["outputs"])
    if has_osb_logs:
        S += [osb_log(g, assigns, corr, notes) for g in pre_logs if g.get("at", 0) == 0]
    else:
        S += ["- log:", "    loggingLevel: INFO", "    logName: oracle.osb.logging.pipeline",
              f'    message: "Request Received to Project {project} :: for PS {x} with TraceID - ${{header.{corr}}} ::${{exchangeProperty.request}}"']
    T = ['- setProperty: {name: osbStage, constant: "request-translation-stage"}']
    rows = [r for r in cfg.get("scenario_mapping", []) if r.get("outputs") != [err]]
    if any(condition(r["scenario"], fields) is not None and not r["scenario"].split("|")[0].startswith("hdr_") for r in rows) or fields:
        T += [f'- setProperty: {{name: osbFields, constant: "{",".join(sorted(fields))}"}}',
              "- bean: {beanType: osb.common.OsbNxsd, method: fields}"]
    T += chain_steps(pre, files, notes, osb_vars)
    if has_osb_logs:
        T += [osb_log(g, assigns, corr, notes) for g in pre_logs if g.get("at", 0) != 0]
    T += ['- setProperty: {name: osbPrefixBody, simple: "${bodyAs(String)}"}', '- setProperty: {name: osbStage, constant: "request-transformation-stage"}']
    whens = []
    for r in rows:
        cond = condition(r["scenario"], fields)
        body = []
        if not r["outputs"]:
            body = [f'- log: {{loggingLevel: INFO, logName: oracle.osb.logging.pipeline, message: "No route for Project {project} :: PS {x} with TraceID - ${{header.{corr}}}: consumed"}}']
        for o in r["outputs"]:
            if o == "reply":
                notes.append("request/reply flows are not generated by this layout yet")
                continue
            suffix = (chains.get(o) or [])[len(pre):]
            rt = next((q for q in bc["outputs"] if match_output(q["service"], keys) == o), {})
            body += ['- setBody: {simple: "${exchangeProperty.osbPrefixBody}"}'] + chain_steps(suffix, files, notes, osb_vars)
            body += [osb_log(g, assigns, corr, notes) for g in (rt.get("logs_before") or [])[len(pre_logs):]]
            body += ['- removeHeaders: {pattern: "*"}      # OSB sends no transport headers on this route']
            if has_osb_logs:
                body += [osb_log(g, assigns, corr, notes) for g in rt.get("logs_out") or []]
            else:
                body.append(f'- log: {{loggingLevel: INFO, logName: oracle.osb.logging.pipeline, message: "Sending to {o} for Project {project} with TraceID - ${{exchangeProperty.osbTraceId}}"}}')
            body.append(f'- to: "{{{{{x}.out.{o}}}}}"')
            body += [osb_log(g, assigns, corr, notes) for g in rt.get("logs_resp") or []]
        whens.append((cond, body))
    if len(whens) == 1 and whens[0][0] is None:
        T += whens[0][1]
    else:
        T += ["- choice:", "    when:"]
        other = None
        for cond, body in whens:
            if cond is None:
                other = body
                continue
            T += [f'      - simple: "{cond}"', "        steps:"] + indent(body, 10)
        if other is not None:
            T += ["    otherwise:", "      steps:"] + indent(other, 8)
    keep = [h for h in e_headers if h not in ("errorCode", "errorMessage", "debugInfo")]
    er = (bc["error_outputs"] or [{}])[0]
    C = ['- setBody: {simple: "${exchangeProperty.request}"}      # OSB: replace $body with $request',
         '- removeHeaders: {pattern: "*"}      # OSB sets every transport header of the error message explicitly (below)']
    for h, expr in (("errorCode", "${exception.class.simpleName}"), ("errorMessage", "${exception.message}"),
                    ("debugInfo", "${exchangeProperty.osbStage}")):
        if h in e_headers:
            C.append(f'- setHeader: {{name: {h}, simple: "{expr}"}}')
    for h in keep:
        if h == corr:
            C.append(f'- setHeader: {{name: {corr}, simple: "${{exchangeProperty.osbTraceId}} ?: ${{header.{corr}}}"}}')
            continue
        src = (er.get("header_exprs") or {}).get(h, "")
        v = osb_value(src, assigns, corr) if src and src != "expression" else None
        C.append(f'- setHeader: {{name: {h}, simple: "{v or "${exchangeProperty.osbIn_" + h + "}"}"}}      # OSB transport-headers {h}')
    if any(r.get("logs_before") for r in bc["error_outputs"]):
        C += [osb_log(g, assigns, corr, notes) for g in er.get("logs_before") or []]
    else:
        C.append(f'- log: {{loggingLevel: ERROR, logName: oracle.osb.logging.pipeline, message: "Error captured for Project {project} :: for PS {x} with TraceID: ${{header.{corr}}} :: fault - ${{exception.message}}"}}')
    C.append(f'- to: "{{{{{x}.out.{err}}}}}"')
    S += ["- doTry:", "    steps:"] + indent(T, 6) + ["    doCatch:", "      - exception: [java.lang.Exception]", "        steps:"] + indent(C, 10)
    L += indent(S, 8)
    return "\n".join(L), e_headers


def body_chain_md(x: str, bc: dict, cfg: dict, notes: list) -> str:
    L = [f"# Body chain of {x}", "", "Read from the OSB pipeline by body_chain.py: what OSB does to the message body on the way to each",
         "business service. The route runs the same steps with OSB's own files (transformations/).", "",
         "| Business service | Format sent | Steps |", "|---|---|---|"]
    for r in bc["outputs"] + bc["error_outputs"]:
        steps = " → ".join(c if isinstance(c, str) else f"{c['op']} {c.get('type', '')} {c.get('nxsd') or c.get('resource') or ''}".strip()
                           for c in r["chain"]) or "original message"
        L.append(f"| {r['service']}{' (error)' if r in bc['error_outputs'] else ''} | {r['format']} | {steps} |")
    L += ["", "Not generated / to check:", ""] + ([f"- {n}" for n in notes] or ["- nothing"]) + [""]
    return "\n".join(L)


def flow_selector(mp: dict, ws: Path, osb_app: Path, project: str, x: str) -> tuple[str, str]:
    """The OSB message selector of a flow and where it was found: module properties (written once by the scaffold,
    so an old module may lack it), else research.json, else the proxy file itself. The broker filters with it."""
    if mp.get("flow.input.selector"):
        return mp["flow.input.selector"], "module properties"
    rj = ws / "research" / project / x / "research.json"
    if rj.is_file():
        sel = str((json.loads(rj.read_text(encoding="utf-8")).get("entry") or {}).get("selector") or "").strip()
        if sel:
            return sel, "research.json"
    for px in (osb_app / project).rglob(f"{x}.proxy"):
        try:
            root = ET.parse(px).getroot()
        except ET.ParseError:
            continue
        for e in root.iter():
            if "selector" in e.tag.split("}")[-1].lower() and (e.text or "").strip():
                return (e.text or "").strip(), "proxy file"
    return "", "none"


def find_file(osb_app: Path, ref: str, exts: tuple) -> Path | None:
    for e in exts:
        p = osb_app / f"{ref}{e}"
        if p.is_file():
            return p
    name = ref.rsplit("/", 1)[-1]
    return next((p for e in exts for p in osb_app.rglob(f"{name}{e}")), None)


def assemble(ws: Path, osb_app: Path, out: Path, app: str, rx: str | None) -> dict:
    root = out / app
    cs = root / "Common-setup"
    cs.mkdir(parents=True, exist_ok=True)
    for f in ("osb-jms-source.kamelet.yaml", "osb-jms-sink.kamelet.yaml", "OsbNxsd.java", "OsbXQuery.java"):
        shutil.copy2(TPL / "common" / f, cs / f)
    pkg = TPL / "package"
    shutil.copytree(pkg / "tools", root / "tools", dirs_exist_ok=True)
    shutil.copy2(pkg / "run.sh", root / "run.sh")
    if not (root / "set-env.sh").is_file():          # an edited set-env.sh is never overwritten
        shutil.copy2(pkg / "set-env.sh", root / "set-env.sh")
    summary = []
    n_proj = n_flow = 0
    for pdir in sorted(p for p in (ws / "modules").iterdir() if p.is_dir()):
        project = pdir.name
        if rx and not re.fullmatch(rx, project):
            continue
        mods = sorted(m for m in pdir.iterdir() if (m / ".scaffold.json").is_file())
        if not mods:
            continue
        short = re.sub(r"-prj$", "", project)
        dst = root / project
        if dst.exists():
            shutil.rmtree(dst)
        (dst / "transformations").mkdir(parents=True)
        routes = [f"# {short}-route.yaml: every flow of OSB project {project}. Endpoints are properties <proxy>.<key>",
                  "# (application.properties), sent and received through the kamelets of ../Common-setup."]
        props = [f"# {project}: endpoints with the OSB (JNDI) names through the kamelets; broker from the environment.",
                 f"camel.main.name={short}",
                 "# folder holding transformations/ (Camel K: where the files are mounted; camel run: this folder)",
                 "osb.files.dir={{env:OSB_FILES_DIR:.}}"]
        for kam in ("osb-jms-source", "osb-jms-sink"):
            props += [f"camel.kamelet.{kam}.brokerURL={{{{env:BROKER_URL:tcp://localhost:61616}}}}",
                      f"camel.kamelet.{kam}.username={{{{env:BROKER_USER:}}}}", f"camel.kamelet.{kam}.password={{{{env:BROKER_PASSWORD:}}}}"]
        local = ["# local Artemis: the same keys with the queue names without the jndi. prefix (ASSUMPTION: platform mapping open)"]
        flows = []
        for m in mods:
            meta = json.loads((m / ".scaffold.json").read_text(encoding="utf-8"))
            x = meta.get("proxy", m.name)
            cfg = json.loads((m / "src/test/resources/flow-test.json").read_text(encoding="utf-8"))
            pipe = next((p for p in (osb_app / project).rglob(f"{x}.pipeline")), None) or next((osb_app / project).rglob("*.pipeline"), None)
            if pipe is None:
                print(f"{project}/{x}: no .pipeline under {osb_app / project}, flow skipped", file=sys.stderr)
                continue
            bc = body_chain.walk(pipe)
            notes: list = []
            files = {}
            for r in bc["outputs"]:
                for c in r["chain"]:
                    if isinstance(c, dict) and c.get("op") in ("nxsd", "xquery"):
                        ref = c.get("nxsd_ref") or c.get("resource_ref")
                        src = find_file(osb_app, ref, (".xsd",) if c["op"] == "nxsd" else (".xqy", ".xq", ".xquery"))
                        if src is None:
                            notes.append(f"file of {c['op']} {ref} not found in the export")
                            continue
                        shutil.copy2(src, dst / "transformations" / src.name)
                        files[ref] = f"transformations/{src.name}"
            mp = props_of(m / "src/main/resources/application.properties")
            lp = props_of(m / "env/local.properties")
            sel, sel_src = flow_selector(mp, ws, osb_app, project, x)
            if sel_src not in ("module properties", "none"):
                notes.append(f"selector taken from {sel_src}: the module properties have none (module older than the selector)")
            route, e_headers = route_for(project, x, cfg, bc, files, notes, sel)
            routes += ["", route]
            props += ["", f"# ---- flow {x}", f"{x}.flow.input={source_uri(mp.get('flow.input', ''), sel)}"]
            local += [f"{x}.flow.input={source_uri(lp.get('flow.input', mp.get('flow.input', '')), sel)}"]
            for k in cfg["outputs"]:
                if k == "reply":
                    continue
                v = mp.get(f"out.{k}", "")
                props.append(f"{x}.out.{k}={sink_uri(v)}")
                local.append(f"{x}.out.{k}={sink_uri(lp.get(f'out.{k}', v))}")
            tr = dst / "test/resources" / x
            shutil.copytree(m / "src/test/resources", tr, dirs_exist_ok=True)
            docs = dst / "docs" / x
            docs.mkdir(parents=True, exist_ok=True)
            for f in ("FLOW_CARD.md", "TEST_MATRIX.md", "GATES.json"):
                if (m / f).is_file():
                    shutil.copy2(m / f, docs / f)
            (docs / "BODY_CHAIN.md").write_text(body_chain_md(x, bc, cfg, notes), encoding="utf-8", newline="\n")
            flows.append((x, cfg, bc, e_headers))
            summary.append((project, x, bc, cfg))
            n_flow += 1
        if not flows:
            shutil.rmtree(dst)
            continue
        (dst / f"{short}-route.yaml").write_text("\n".join(routes) + "\n", encoding="utf-8", newline="\n")
        (dst / "application.properties").write_text("\n".join(props) + "\n", encoding="utf-8", newline="\n")
        (dst / "local.properties").write_text("\n".join(local) + "\n", encoding="utf-8", newline="\n")
        for x, cfg, bc, e_headers in flows:
            write_test(dst, short, x, cfg, [f[0] for f in flows], e_headers)
        write_run_local(dst, short, [f[0] for f in flows])
        camelk_manifests.manifests(dst)
        n_proj += 1
    (root / "README.md").write_text(readme(app, summary), encoding="utf-8", newline="\n")
    return {"projects": n_proj, "flows": n_flow, "out": str(root)}


def readme(app: str, summary: list) -> str:
    """Top-level README of the delivery: what the flows do and how to run them, in a few steps."""
    L = [f"# {app}: OSB flows migrated to Camel K", "",
         "No pom, no kit needed: Java 21, Maven with access to the Maven repository (JBang and Camel come from there when",
         "they are not installed) and, for the broker test, an unzipped Apache Artemis. Git Bash on Windows.", "",
         "## Run it", "",
         "1. Edit `set-env.sh` once: `JAVA_HOME`, `MVN_ARGS` (if Maven needs `-s <settings.xml>`), `ARTEMIS_HOME`.",
         "2. Tests of every flow, no broker:", "   ```", "   bash run.sh test", "   ```",
         "3. Broker password in this window, and a local Artemis if none is running:", "   ```",
         "   export BROKER_PASSWORD=<password>", "   bash run.sh status            # Java, Maven, JBang, broker", "   bash run.sh setup-broker      # only if the broker is not running", "   ```",
         "4. Every flow against Artemis (start route, send one case per scenario, count the queues, stop):", "   ```",
         "   bash run.sh e2e", "   ```", "   Result per project: `<project>/test/BROKER_RUN.txt` (what was sent, what arrived on which queue, route log).", "",
         "One project or one message by hand: `bash run.sh test <project>`, `bash run.sh e2e <project>`, or in the project",
         "folder `bash run-local.sh run | send <proxy> <case folder> | stat | stop` (its RUN_LOCAL.md).", "",
         "## The flows", "", "| Project | Proxy | Output queue (business service) | Body sent | Steps (from the OSB pipeline) |", "|---|---|---|---|---|"]
    for project, x, bc, cfg in summary:
        for r in bc["outputs"] + bc["error_outputs"]:
            steps = " → ".join(c if isinstance(c, str) else f"{c['op']} {c.get('nxsd') or c.get('resource') or ''}".strip() for c in r["chain"]) or "original message"
            L.append(f"| {project} | {x} | {r['service']}{' (error)' if r in bc['error_outputs'] else ''} | {r['format']} | {steps} |")
    L += ["", "Per flow: `<project>/docs/<proxy>/BODY_CHAIN.md` (what OSB does to the body, what is not generated),",
          "`FLOW_CARD.md`, `BROKER_RUN.txt`. Routes: `<project>/<domain>-route.yaml`; endpoints: `application.properties`",
          "(OSB JNDI names) and `local.properties` (local Artemis). Shared: `Common-setup/` (Artemis kamelets, nXSD and",
          "XQuery helpers), `tools/` (JBang via Maven, Artemis CLI and local broker, broker test).", "",
          "## Layout", "", "```", f"{app}/", "  README.md  set-env.sh  run.sh", "  tools/          jbang.sh  artemis.sh  e2e.sh",
          "  Common-setup/   osb-jms-source / osb-jms-sink kamelets, OsbNxsd.java, OsbXQuery.java",
          "  <project>/      <domain>-route.yaml  application.properties  local.properties  run-local.sh  RUN_LOCAL.md",
          "                  transformations/ (OSB .xqy and nXSD .xsd)  test/ (jbang tests, cases)  docs/<proxy>/",
          "                  camel-k/ (integration.yaml, configmaps.yaml, DEPLOY.md: the project on Camel K)", "```", ""]
    return "\n".join(L)


def write_test(dst: Path, short: str, x: str, cfg: dict, all_flows: list, e_headers: list) -> None:
    flow = camel_case(x)
    t = (TPL / "FlowJBangTest.java.tpl").read_text(encoding="utf-8")
    others = "".join(f'\n            "{y}.flow.input=direct:in-{y}",' for y in all_flows if y != x)
    outs = "".join(f'\n            "{y}.out.{k}=mock:{y}-{k}",' for y in all_flows for k in (cfg["outputs"] if y == x else [])
                   if k != "reply")
    for y in all_flows:
        if y == x:
            continue
        oc = json.loads((dst / "test/resources" / y / "flow-test.json").read_text(encoding="utf-8")) if (dst / "test/resources" / y / "flow-test.json").is_file() else {"outputs": {}}
        outs += "".join(f'\n            "{y}.out.{k}=mock:{y}-{k}",' for k in oc.get("outputs", {}) if k != "reply")
    t = (t.replace("@@CLASS@@", f"{flow}Test").replace("@@PROXY@@", x).replace("@@ROUTE@@", f"{short}-route.yaml")
          .replace("@@CAMEL@@", CAMEL_VERSION).replace("@@PROPS@@", f'\n            "{x}.flow.input=direct:in-{x}",' + others + outs)
          .replace("@@ERROR_HEADERS@@", ", ".join(f'"{h}"' for h in e_headers)))
    (dst / "test").mkdir(exist_ok=True)
    (dst / "test" / f"{flow}Test.java").write_text(t, encoding="utf-8", newline="\n")


def write_run_local(dst: Path, short: str, flows: list) -> None:
    t = (TPL / "run-local-jbang.sh.tpl").read_text(encoding="utf-8")
    t = t.replace("@@ROUTE@@", f"{short}-route.yaml").replace("@@CAMEL@@", CAMEL_VERSION).replace("@@PROJECT@@", dst.name)
    (dst / "run-local.sh").write_text(t, encoding="utf-8", newline="\n")
    md = (TPL / "RUN_LOCAL_JBANG.md.tpl").read_text(encoding="utf-8")
    md = md.replace("@@PROJECT@@", dst.name).replace("@@CAMEL@@", CAMEL_VERSION).replace("@@ROUTE@@", f"{short}-route.yaml")
    md = md.replace("@@TESTS@@", "\n".join(f"jbang test/{camel_case(x)}Test.java" for x in flows))
    md = md.replace("@@SENDS@@", "\n".join(f"bash run-local.sh send {x} test/resources/{x}/parity/<flow>/<scenario>/<case>" for x in flows))
    (dst / "RUN_LOCAL.md").write_text(md, encoding="utf-8", newline="\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workspace", type=Path)
    ap.add_argument("--osb-app", type=Path, required=True)
    ap.add_argument("-o", "--out", type=Path)
    ap.add_argument("--app", default="osb-app")
    ap.add_argument("--projects")
    a = ap.parse_args()
    print(json.dumps(assemble(a.workspace, a.osb_app, a.out or a.workspace / "delivery", a.app, a.projects)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_ASSEMBLE_JBANG_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/body_chain.py")"
cat > '.pi/skills/osb-camelk-route/scripts/body_chain.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_BODY_CHAIN_PY'
#!/usr/bin/env python3
"""What OSB does to the message body on its way to each business service, read from the pipeline (no agent). Stdlib only.

    body_chain.py <file.pipeline> [-o body_chain.json] [--summary]

Walks the request pipeline stages and the route node in order, follows ifThenElse branches, and records every action
that changes $body or a variable that later becomes $body:
    nxsdTranslation  Native-To-XML / XML-To-Native with its nXSD schema and root element
    assign <var> = xqueryTransform(<resource>, params)      replace $body with $<var>   ->  the XQuery result is the body
    assign request = $body  ...  replace $body with $request                         ->  the ORIGINAL message is the body
For every route/publish it writes the chain that is in effect there, and the resulting format:
    native  = the message as received (no translation, or restored from the saved original)
    xml     = after Native-To-XML and/or an XQuery
    native-from-xml = after XML-To-Native (e.g. JSON again)
The JSON (with the XQuery/expression texts) stays on the client machine; --summary prints names only (shareable).
Unknown child elements of nxsdTranslation / xqueryTransform are listed under "unknown_tags", so a syntax the script
does not know yet is visible instead of silently ignored."""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def loc(tag: str) -> str:
    return tag.split("}")[-1]


def kids(e, name=None):
    return [c for c in e if name is None or loc(c.tag) == name]


def first(e, name):
    for c in e.iter():
        if c is not e and loc(c.tag) == name:
            return c
    return None


def text_of(e) -> str:
    if e is None:
        return ""
    t = first(e, "xqueryText")
    return re.sub(r"\s+", " ", (t.text if t is not None else (e.text or "")) or "").strip()


def short_ref(ref: str) -> str:
    return ref.rsplit("/", 1)[-1] if ref else ""


def log_of(a, at: int) -> dict:
    """One OSB Log action: level and expression text (the message OSB writes), 'at' = body-chain length when it ran."""
    lvl = first(a, "logLevel")
    return {"level": ((lvl.text or "info").strip().lower() if lvl is not None else "info"), "expr": text_of(first(a, "expr")), "at": at}


KNOWN_NXSD = {"id", "type", "sourceExpr", "nxsd", "schemaElement", "xqueryText", "assignVariable", "assign-variable",
              "enforceSchemaOrder"}
KNOWN_XQT = {"resource", "param", "path", "xqueryText"}


class Walker:
    def __init__(self):
        self.unknown = set()

    def action(self, a, state: dict) -> list:
        """Apply one action to a copy of state {'body': chain, 'vars': {name: chain}}; returns list of (cond, state)
        pairs (more than one for ifThenElse)."""
        t = loc(a.tag)
        st = {**state, "body": list(state["body"]), "vars": dict(state["vars"]), "conds": list(state["conds"]),
              "routes": list(state["routes"]), "logs": list(state.get("logs") or [])}
        if t == "log":                              # OSB Log action: its text is reproduced in the route
            st["logs"].append(log_of(a, len(st["body"])))
            return [st]
        if t == "assign":
            var = a.get("varName")
            xqt = first(a, "xqueryTransform")
            if xqt is not None:
                for c in xqt.iter():
                    if loc(c.tag) not in KNOWN_XQT and c is not xqt:
                        self.unknown.add(f"xqueryTransform/{loc(c.tag)}")
                res = first(xqt, "resource")
                params = {}
                for p in xqt.iter():
                    if loc(p.tag) == "param":
                        pe = first(p, "path")
                        params[p.get("name", "")] = text_of(p if pe is None else pe)
                st["vars"][var] = st["body"] + [{"op": "xquery", "resource": short_ref(res.get("ref", "") if res is not None else ""),
                                                 "resource_ref": res.get("ref", "") if res is not None else "", "params": params}]
            else:
                expr = text_of(a)
                if re.search(r"\$body\b", expr) and not re.search(r"\$body/\*?:?\w", expr.replace("$body/*", "")):
                    st["vars"][var] = list(st["body"]) or [{"op": "original"}]
                else:
                    st["vars"][var] = [{"op": "expr", "text": expr[:300]}]
            return [st]
        if t == "nxsdTranslation":
            for c in a.iter():
                if loc(c.tag) not in KNOWN_NXSD and c is not a:
                    self.unknown.add(f"nxsdTranslation/{loc(c.tag)}")
            typ = (first(a, "type").text or "").strip() if first(a, "type") is not None else ""
            nx = first(a, "nxsd")
            eso = first(a, "enforceSchemaOrder")
            step = {"op": "nxsd", "type": typ, "enforce_schema_order": (eso.text or "").strip() if eso is not None else "", "nxsd": short_ref(nx.get("ref", "") if nx is not None else ""),
                    "nxsd_ref": nx.get("ref", "") if nx is not None else "", "root": text_of(first(a, "schemaElement")),
                    "source": text_of(first(a, "sourceExpr"))[:200]}
            target = [loc(c.tag) for c in a if loc(c.tag) not in KNOWN_NXSD]
            var = next(((c.text or "").strip() or c.get("varName") or c.get("name") for c in a.iter()
                        if loc(c.tag) in ("assignVariable", "assign-variable", "variable", "var")
                        and ((c.text or "").strip() or c.get("varName") or c.get("name"))), None)
            if var:
                st["vars"][var] = st["body"] + [step]
            else:                                   # result lands in $body (replace-body-content) or is picked up next
                st["pending_nxsd"] = st["body"] + [step]
                st["body"] = st["body"] + [step] if any(x in target for x in ("replace", "replaceBody", "replace-body-content")) else st["body"]
            st.setdefault("pending", []).append(step)
            return [st]
        if t == "replace" and a.get("varName") == "body":
            expr = text_of(a)
            m = re.fullmatch(r"\$(\w+)(/\*)?|fn:data\(\$(\w+)\)", expr)
            name = (m.group(1) or m.group(3)) if m else None
            if name and name in st["vars"]:
                st["body"] = list(st["vars"][name])
            elif state.get("pending_nxsd") is not None and (not name or name not in st["vars"]):
                st["body"] = list(state["pending_nxsd"])      # nxsd result taken over (output var unknown to us)
            else:
                st["body"] = st["body"] + [{"op": "replace", "text": expr[:300]}]
            st["pending_nxsd"] = None
            return [st]
        if t in ("route", "publish"):
            svc = first(a, "service")
            headers, header_exprs = [], {}
            ot = first(a, "outboundTransform")
            if ot is not None:
                for h in ot.iter():
                    if loc(h.tag) == "header" and h.get("name"):
                        headers.append(h.get("name"))
                        header_exprs[h.get("name")] = text_of(h)
            rt = first(a, "responseTransform")
            st["routes"].append({"service": short_ref(svc.get("ref", "") if svc is not None else ""), "kind": t,
                                 "conds": list(st["conds"]), "chain": list(st["body"]), "headers": headers,
                                 "header_exprs": header_exprs, "logs_before": list(st["logs"]),
                                 "logs_out": [log_of(x, -1) for x in (ot.iter() if ot is not None else []) if loc(x.tag) == "log"],
                                 "logs_resp": [log_of(x, -1) for x in (rt.iter() if rt is not None else []) if loc(x.tag) == "log"]})
            return [st]
        if t == "ifThenElse":
            out = []
            negs = []
            for br in kids(a):
                bt = loc(br.tag)
                if bt == "case":
                    cond = text_of(first(br, "condition"))
                    s2 = dict(st, conds=st["conds"] + negs + [cond])
                    acts = first(br, "actions")
                    out += self.actions(acts if acts is not None else br, s2, skip={"condition"})
                    negs = negs + [f"not({cond})"]
                elif bt == "default":
                    s2 = dict(st, conds=st["conds"] + negs)
                    acts = first(br, "actions")
                    out += self.actions(acts if acts is not None else br, s2)
            if not any(loc(b.tag) == "default" for b in kids(a)):
                out.append(dict(st, conds=st["conds"] + negs))
            return out
        return [st]

    def actions(self, container, state, skip=()):
        states = [state]
        for a in kids(container):
            if loc(a.tag) in skip or loc(a.tag) in ("id", "condition"):
                continue
            nxt = []
            for s in states:
                nxt += self.action(a, s)
            states = nxt
        return states


def stages(pipeline):
    return [s for s in pipeline.iter() if loc(s.tag) == "stage"]


def walk(path: Path) -> dict:
    root = ET.parse(path).getroot()
    router = next((e for e in root.iter() if loc(e.tag) == "router"), root)
    pipes = {p.get("name"): p for p in router.iter() if loc(p.tag) == "pipeline"}
    w = Walker()
    start = {"body": [], "vars": {}, "conds": [], "routes": [], "logs": []}
    states = [start]
    req = [p for p in pipes.values() if p.get("type") == "request"]
    for p in req:                                   # request pipelines in document order (usually one)
        for stg in stages(p):
            acts = first(stg, "actions")
            acts = stg if acts is None else acts
            nxt = []
            for s in states:
                nxt += w.actions(acts, s)
            states = nxt
    routes = []
    for rn in (e for e in router.iter() if loc(e.tag) == "route-node"):
        acts = first(rn, "actions")
        acts = rn if acts is None else acts
        for s in states:
            for s2 in w.actions(acts, s):
                routes += [r for r in s2["routes"] if consistent(r["conds"])]
    errors = []
    for p in (p for p in pipes.values() if p.get("type") == "error"):
        e_states = [{"body": ["error-handler-body"], "vars": dict(states[0]["vars"]) if states else {}, "conds": [], "routes": [], "logs": []}]
        for stg in stages(p):
            acts = first(stg, "actions")
            acts = stg if acts is None else acts
            nxt = []
            for s in e_states:
                nxt += w.actions(acts, s)
            e_states = nxt
        for s in e_states:
            for r in s["routes"]:
                errors.append({"handler": [st.get("name") for st in stages(p)][:1], **r})
    for r in routes + errors:
        r["format"] = fmt(r["chain"])
    assigns = {a.get("varName"): text_of(a) for a in root.iter() if loc(a.tag) == "assign" and a.get("varName")}
    return {"pipeline": path.name, "outputs": routes, "error_outputs": errors, "unknown_tags": sorted(w.unknown), "assigns": assigns}


def norm(c: str) -> str:
    return re.sub(r"\s+", "", c)


def consistent(conds: list) -> bool:
    """False when one branch condition and its negation are both on the path (request-pipeline branch crossed with
    a route-node branch on the same condition: OSB never takes that combination)."""
    pos = {norm(c) for c in conds if not c.startswith("not(")}
    neg = {norm(c[4:-1]) for c in conds if c.startswith("not(")}
    return not (pos & neg)


def fmt(chain: list) -> str:
    if not chain or chain == ["error-handler-body"]:
        return "native"
    last = chain[-1]
    if last == "error-handler-body":
        return "unknown"
    if last.get("op") == "original":
        return "native"
    if last.get("op") == "xquery":
        return "xml"
    if last.get("op") == "nxsd":
        return "xml" if "native-to-xml" in last.get("type", "").lower() else "native-from-xml"
    return "unknown"


def summary(d: dict) -> str:
    lines = [f"pipeline {d['pipeline']}"]
    for kind in ("outputs", "error_outputs"):
        for r in d[kind]:
            ch = " -> ".join(
                c if isinstance(c, str) else
                f"{c['op']}({c.get('type', '') + ' ' if c['op'] == 'nxsd' else ''}{c.get('nxsd') or c.get('resource') or ''})".replace("( ", "(")
                for c in r["chain"]) or "original"
            lines.append(f"  {'ERROR ' if kind == 'error_outputs' else ''}{r['kind']} -> {r['service']}: format={r['format']}  chain: {ch}"
                         f"  conditions={len(r['conds'])}  headers={r['headers']}")
    if d["unknown_tags"]:
        lines.append(f"  unknown_tags: {d['unknown_tags']}")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pipeline", type=Path)
    ap.add_argument("-o", "--out", type=Path)
    ap.add_argument("--summary", action="store_true", help="print names only (shareable)")
    a = ap.parse_args()
    d = walk(a.pipeline)
    if a.out:
        a.out.write_text(json.dumps(d, indent=2), encoding="utf-8")
    print(summary(d) if a.summary or a.out else json.dumps(d, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_BODY_CHAIN_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/camelk_manifests.py")"
cat > '.pi/skills/osb-camelk-route/scripts/camelk_manifests.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_CAMELK_MANIFESTS_PY'
#!/usr/bin/env python3
"""Camel K manifests of one delivered OSB project (called by assemble_jbang.py, or alone on a delivery). Stdlib only.

    camelk_manifests.py <delivery>/<app>/<project> [--namespace NS] [--domain D]

Writes <project>/camel-k/:
  integration.yaml    Integration <name>: the route + OsbNxsd.java + OsbXQuery.java from ConfigMap <name>-sources,
                      application.properties from ConfigMap <name>-config, the OSB .xqy/.xsd files mounted from
                      ConfigMap <name>-transformations, broker user/password from Secret <name>-broker (key broker.properties)
  configmaps.yaml     the three ConfigMaps, file contents copied exactly
  DEPLOY.md           apply order and the secret command
The two Artemis kamelets of ../Common-setup are Kamelet resources already: apply them once per namespace.
Namespace and domain label: --namespace / --domain, else CAMELK_NAMESPACE / CAMELK_DOMAIN, else none / the app folder."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ARTEMIS_CLIENT = "mvn:org.apache.activemq:artemis-jakarta-client:2.44.0"   # same as the kamelets
SAXON = "mvn:net.sf.saxon:Saxon-HE:12.9"                                    # //DEPS of OsbXQuery.java
FILES_DIR = "/etc/camel/resources/osb"                                      # osb.files.dir inside the pod
CM_LIMIT = 1_000_000                                                        # ConfigMap data limit is 1 MiB
SECRET_KEYS = ("username", "password")


def yaml_str(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def block(key: str, text: str, ind: int) -> list:
    """A ConfigMap data entry. Literal block when it round-trips exactly, else a JSON-quoted string (YAML-valid)."""
    pad = " " * ind
    first = text.split("\n", 1)[0]
    literal_ok = (text.endswith("\n") and not text.endswith("\n\n") and "\r" not in text and text.strip()
                  and not first[:1].isspace() and all(not l or not l[-1].isspace() for l in text.split("\n")))
    if not literal_ok:
        return [f"{pad}{key}: {yaml_str(text)}"]
    return [f"{pad}{key}: |"] + [f"{pad}  {l}" if l else "" for l in text[:-1].split("\n")]


def configmap(name: str, files: dict, labels: dict, ns: str) -> list:
    L = ["apiVersion: v1", "kind: ConfigMap", "metadata:", f"  name: {name}"] + ([f"  namespace: {ns}"] if ns else [])
    L += ["  labels:"] + [f"    {k}: {v}" for k, v in labels.items()] + ["data:"]
    for k, text in files.items():
        L += block(k, text, 2)
    return L


def camelk_properties(text: str) -> str:
    """application.properties for the pod: broker user/password lines removed (they come from the Secret),
    so every property has exactly one source."""
    keep = [l for l in text.splitlines() if not re.match(rf"camel\.kamelet\.[\w-]+\.({'|'.join(SECRET_KEYS)})=", l)]
    return "\n".join(keep + ["# broker user and password: Secret <name>-broker, key broker.properties (camel.kamelet.<kamelet>.username / .password)"]) + "\n"


def manifests(pdir: Path, ns: str = "", domain: str = "") -> dict:
    route = next(iter(sorted(pdir.glob("*-route.yaml"))), None)
    if route is None:
        raise SystemExit(f"no *-route.yaml in {pdir}")
    name = re.sub(r"[^a-z0-9-]", "-", route.name[:-len("-route.yaml")].lower()).strip("-")
    common = pdir.parent / "Common-setup"
    ns = ns or os.environ.get("CAMELK_NAMESPACE", "")
    domain = domain or os.environ.get("CAMELK_DOMAIN", "") or pdir.parent.name
    labels = {"app": name, "domain": domain, "flow": name}
    kamelets = sorted(common.glob("*.kamelet.yaml"))
    props = (pdir / "application.properties").read_text(encoding="utf-8")
    sources = {route.name: route.read_text(encoding="utf-8")}
    for j in ("OsbNxsd.java", "OsbXQuery.java"):
        sources[j] = (common / j).read_text(encoding="utf-8")
    trans = {f.name: f.read_text(encoding="utf-8") for f in sorted((pdir / "transformations").glob("*")) if f.is_file()}
    notes = [f"ConfigMap {name}-transformations holds {sum(len(t.encode()) for t in trans.values())} bytes, over the 1 MiB limit: split it"
             ] if sum(len(t.encode()) for t in trans.values()) > CM_LIMIT else []
    bad = [k for k in trans if not re.fullmatch(r"[-._a-zA-Z0-9]+", k)]
    if bad:
        notes.append(f"file names not valid as ConfigMap keys: {', '.join(bad)}")

    I = ["apiVersion: camel.apache.org/v1", "kind: Integration", "metadata:", f"  name: {name}"]
    I += [f"  namespace: {ns}"] if ns else []
    I += ["  labels:"] + [f"    {k}: {v}" for k, v in labels.items()]
    I += ["spec:", "  profile: OpenShift", "  sources:"]
    for s in sources:
        I += [f"    - name: {s}", f"      language: {'java' if s.endswith('.java') else 'yaml'}",
              f"      contentRef: {name}-sources", f"      contentKey: {s}"]
    I += ["  dependencies:", "    - camel:yaml-dsl", "    - camel:kamelet", "    - camel:jms", "    - camel:direct",
          "    - camel:jackson", f"    - {SAXON}", f"    - {ARTEMIS_CLIENT}"]
    I += ["  traits:", "    mount:", "      configs:", f'        - "configmap:{name}-config"', f'        - "secret:{name}-broker"',
          "      resources:", f'        - "configmap:{name}-transformations@{FILES_DIR}/transformations"',
          "    environment:", "      vars:", f'        - "OSB_FILES_DIR={FILES_DIR}"', '        - "BROKER_URL=tcp://CHANGE-ME:61616"',
          "    camel:", "      enabled: true", "    kamelets:", "      enabled: true",
          f'      list: "{",".join(k.name[:-len(".kamelet.yaml")] for k in kamelets)}"',
          "    container:", "      imagePullPolicy: Always",
          "    service:", "      enabled: true", "      type: ClusterIP", "    jvm:", "      enabled: true"]
    I = [f"# {name}: Camel K Integration generated from the OSB project {pdir.name} (camelk_manifests.py, do not edit by hand).",
         "# Sources, properties and OSB files come from the ConfigMaps in configmaps.yaml; credentials from the Secret",
         f"# {name}-broker (see DEPLOY.md). BROKER_URL: replace CHANGE-ME with the Artemis service of the namespace."] + I

    C = configmap(f"{name}-sources", sources, labels, ns) + ["---"]
    C += configmap(f"{name}-config", {"application.properties": camelk_properties(props)}, labels, ns) + ["---"]
    C += configmap(f"{name}-transformations", trans, labels, ns)

    kam_names = [k.name[:-len(".kamelet.yaml")] for k in kamelets]
    nsf = f" -n {ns}" if ns else " -n <namespace>"
    D = [f"# {name} on Camel K", "", "Generated from the OSB project and the delivery; regenerated with the route. Apply in this order.", "",
         "1. The Artemis kamelets, once per namespace (shared by every project of the application):", "   ```"]
    D += [f"   oc apply{nsf} -f ../../Common-setup/{k.name}" for k in kamelets] + ["   ```",
          "2. The broker credentials as a Secret, never in a file of the repository. Write `broker.properties` on your",
          "   machine with these lines, create the Secret, delete the file:", "   ```"]
    D += [f"   camel.kamelet.{k}.{s}=<{s}>" for k in kam_names for s in SECRET_KEYS]
    D += ["   ```", "   ```", f"   oc create secret generic {name}-broker{nsf} --from-file=broker.properties", "   rm broker.properties"]
    D += ["   ```", "3. Sources, properties and OSB files, then the Integration (set BROKER_URL in integration.yaml first):", "   ```",
          f"   oc apply{nsf} -f configmaps.yaml", f"   oc apply{nsf} -f integration.yaml", f"   oc get integration {name}{nsf} -w", "   ```", "",
          f"The pod reads `application.properties` from ConfigMap `{name}-config` without the user/password lines, the",
          f"OSB .xqy/.xsd files under `{FILES_DIR}/transformations` (OSB_FILES_DIR), and the route from `{name}-sources`.",
          "The Camel version is the one of the Camel K runtime on the cluster; the routes and tests are built and run",
          "with Camel 4.18.4 (camel run / jbang tests), so the runtime should be a Camel 4.18 one."]
    if notes:
        D += ["", "## To check", ""] + [f"- {n}" for n in notes]
    out = pdir / "camel-k"
    out.mkdir(exist_ok=True)
    for f, L in (("integration.yaml", I), ("configmaps.yaml", C), ("DEPLOY.md", D)):
        (out / f).write_text("\n".join(L) + "\n", encoding="utf-8", newline="\n")
    return {"integration": name, "sources": len(sources), "transformations": len(trans), "notes": notes}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("project", type=Path)
    ap.add_argument("--namespace", default="")
    ap.add_argument("--domain", default="")
    a = ap.parse_args()
    print(json.dumps(manifests(a.project, a.namespace, a.domain)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_CAMELK_MANIFESTS_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/check_camelk.py")"
cat > '.pi/skills/osb-camelk-route/scripts/check_camelk.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_CHECK_CAMELK_PY'
#!/usr/bin/env python3
"""Gates for ONE generated Camel K module (run after `mvn test`). Stdlib only.

    check_camelk.py modules/<project>/<proxy> [--no-surefire]

K1 card approved       FLOW_CARD.md has `Status: approved` and an approver name, and was not changed after it was
                       frozen before the implementation (pi must never edit the card)
K2 no gaps left        no TODO(flow-card) in src/main (route, properties, beans)
K3 route ids           every branch-*, out-*, backend-* id from .scaffold.json is in the YAML route
K4 no infrastructure   no host names, IP addresses, host:port URIs or credentials in src/main
K5 tests untouched     FlowParityTest.java and flow-test.json equal their scaffold hash; no @Disabled anywhere
K6 backend stubs       a stub file per backend whose response is used
K7 error tests         FlowErrorTest has at least one test per error scope in research.json
K8 tests green         surefire reports: tests > 0, failures 0, errors 0 (skipped = golden pending, reported)
K9 scenarios covered   every scenario_mapping row has at least one case (real from Splunk or synthetic)
K10 properties valid   application.properties: no spaces or notes in a value, no TODO; every {{key}} the route uses
                       is defined (the tests replace endpoints with mocks, so a broken production value stays green)
K11 single destination no destination twice: a backend-<x>-bs next to out-<x> (the JMS business service IS the output),
                       or two keys with the same endpoint value: production would get every message twice
K12 reply expected     request/reply flows: every case that ends in the reply has expected-output.json/.xml, so the
                       reply body is compared (a route that passes the request through unchanged must fail)
Writes GATES.json next to the module's pom; exit 1 if any gate fails."""
import argparse
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HOST = [(re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"), "IP address"),
        (re.compile(r"://(?!\{\{)[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "host name in a URI"),
        (re.compile(r"://[^/\s\"']*:\d{2,5}"), "host:port"),
        (re.compile(r"(?i)\b(password|passwd|secret|token|apikey|api-key)\s*[=:]\s*(?!\{\{|\$\{)[^\s\"',}]+"), "credential")]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--no-surefire", action="store_true", help="skip K8 (before mvn test ran)")
    a = ap.parse_args()
    mod = a.module
    meta = json.loads((mod / ".scaffold.json").read_text(encoding="utf-8"))
    gates = {}

    card = (mod / "FLOW_CARD.md").read_text(encoding="utf-8") if (mod / "FLOW_CARD.md").is_file() else ""
    approved = re.search(r"^Status:\s*approved\s*$", card, re.M | re.I) and re.search(r"^Approver:\s*\S+", card, re.M)
    sha_now = hashlib.sha256((mod / "FLOW_CARD.md").read_bytes()).hexdigest() if (mod / "FLOW_CARD.md").is_file() else ""
    frozen = meta.get("card_sha256")
    card_changed = bool(frozen) and frozen != sha_now
    gates["K1_card_approved"] = {"ok": bool(approved) and not card_changed,
                                 **({"card_changed_after_freeze": True} if card_changed else {})}

    main_files = [p for p in (mod / "src/main").rglob("*") if p.is_file()]
    todo = [f"{p.relative_to(mod)}:{i}" for p in main_files for i, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1)
            if "TODO(flow-card)" in line]
    gates["K2_no_gaps"] = {"ok": not todo, "left": len(todo), "where": todo[:20]}

    route = "\n".join(p.read_text(encoding="utf-8") for p in (mod / "src/main/resources/routes").glob("*.camel.yaml"))
    missing = [i for i in meta["route_ids"] if not re.search(rf"\bid:\s*[\"']?{re.escape(i)}[\"']?\s*$", route, re.M)
               and not re.search(rf"\bid:\s*[\"']?{re.escape(i)}[\"']?\s*[,}}]", route)]
    gates["K3_route_ids"] = {"ok": not missing, "missing": missing}

    infra = []
    for p in main_files:
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if line.lstrip().startswith("#") or "xmlns" in line or "namespace" in line.lower():
                continue
            for rx, what in HOST:
                if rx.search(line):
                    infra.append(f"{p.relative_to(mod)}:{i} {what}")
    gates["K4_no_infrastructure"] = {"ok": not infra, "findings": infra[:20]}

    changed = [f for f, h in meta["generated"].items()
               if not (mod / f).is_file() or hashlib.sha256((mod / f).read_bytes()).hexdigest() != h]
    disabled = [str(p.relative_to(mod)) for p in (mod / "src/test").rglob("*.java") if "@Disabled" in p.read_text(encoding="utf-8")]
    gates["K5_tests_untouched"] = {"ok": not changed and not disabled, "changed": changed, "disabled": disabled}

    stubs = mod / "src/test/resources/stubs"
    no_stub = [b for b in meta.get("backends_with_response", []) if not any((stubs / f"{b}{e}").is_file() for e in (".json", ".xml", ".txt"))]
    gates["K6_backend_stubs"] = {"ok": not no_stub, "missing": no_stub}

    err_tests = 0
    for p in (mod / "src/test").rglob("FlowErrorTest.java"):
        err_tests += len(re.findall(r"@(Test|ParameterizedTest)\b", p.read_text(encoding="utf-8")))
    gates["K7_error_tests"] = {"ok": err_tests >= meta.get("errors", 0) and (err_tests > 0 or meta.get("errors", 0) == 0),
                               "tests": err_tests, "error_scopes": meta.get("errors", 0)}

    cfg = json.loads((mod / "src/test/resources/flow-test.json").read_text(encoding="utf-8"))
    scen = [dict(p.split("=", 1) for p in sc.read_text(encoding="utf-8").strip().split("|") if "=" in p)
            for sc in (mod / "src/test/resources/parity").glob("*/*/SCENARIO.txt")]

    def hit(key: str, v: dict) -> bool:
        for p in key.split("|"):
            if "!=" in p:
                k, x = p.split("!=", 1)
                if v.get(k) == x:
                    return False
            elif "=" in p:
                k, x = p.split("=", 1)
                if v.get(k) != x:
                    return False
        return bool(key)
    uncovered = [m["scenario"] for m in cfg.get("scenario_mapping", []) if not any(hit(m["scenario"], v) for v in scen)]
    gates["K9_scenarios_covered"] = {"ok": not uncovered, "uncovered": uncovered}

    # K12: a request/reply flow is only tested when the REPLY BODY is compared: every case that ends in the reply
    # has expected-output.json/.xml (OSB's logged answer, or synthetic: built from the stub by research transforms)
    reply_rows = [m["scenario"] for m in cfg.get("scenario_mapping", []) if "reply" in (m.get("outputs") or [])]
    no_expected = []
    if reply_rows and "reply" in (cfg.get("outputs") or {}):
        for sc in (mod / "src/test/resources/parity").glob("*/*/SCENARIO.txt"):
            v = dict(p.split("=", 1) for p in sc.read_text(encoding="utf-8").strip().split("|") if "=" in p)
            if not any(hit(r_, v) for r_ in reply_rows):
                continue
            for case in sorted(p.parent for p in sc.parent.glob("*/input.payload")):
                exp = json.loads((case / "expected.json").read_text(encoding="utf-8")) if (case / "expected.json").is_file() else {}
                if exp.get("outcome", "success") == "success" and not any((case / f"expected-output{e}").is_file() for e in (".json", ".xml")):
                    no_expected.append(case.relative_to(mod / "src/test/resources/parity").as_posix())
    gates["K12_reply_expected"] = {"ok": not no_expected, "cases_without_expected_reply": no_expected[:20]}

    props, bad = {}, []
    pf = mod / "src/main/resources/application.properties"
    for i, line in enumerate(pf.read_text(encoding="utf-8").splitlines() if pf.is_file() else [], 1):
        if not line.strip() or line.lstrip().startswith(("#", "!")) or "=" not in line:
            continue
        k, v = (x.strip() for x in line.split("=", 1))
        props[k] = v
        if k.endswith(".selector"):                 # a message selector is text, not an endpoint
            continue
        if re.search(r"\s|[()]", v) or "TODO" in v or not v:
            bad.append(f"{k} (line {i})")
    used = sorted({k for k in re.findall(r"\{\{([\w.-]+)\}\}", route) if not k.startswith(("env:", "sys:"))})
    undefined = [k for k in used if k not in props]
    gates["K10_properties_valid"] = {"ok": not bad and not undefined, "bad_values": bad, "undefined": undefined}

    def norm(v: str) -> str:
        return re.sub(r"^(amqp|jms|activemq|sjms2?):(queue:|topic:)?", "", v).split("?")[0].lower()
    outs = {k[4:] for k in props if k.startswith("out.")}
    twice = [k for k in props if k.startswith("backend.") and re.sub(r"-bs$", "", k[8:]) in outs]
    seen = {}
    for k, v in props.items():
        if k.startswith(("out.", "backend.")) and v and not v.startswith(("mock:", "direct:")):
            seen.setdefault(norm(v), []).append(k)
    twice += [" = ".join(ks) for ks in seen.values() if len(ks) > 1]
    gates["K11_single_destination"] = {"ok": not twice, "twice": twice}

    if not a.no_surefire:
        t = f = e = s = 0
        for rep in (mod / "target/surefire-reports").glob("TEST-*.xml"):
            r = ET.parse(rep).getroot()
            t += int(r.get("tests", 0))
            f += int(r.get("failures", 0))
            e += int(r.get("errors", 0))
            s += int(r.get("skipped", 0))
        gates["K8_tests_green"] = {"ok": t > 0 and f == 0 and e == 0, "tests": t, "failures": f, "errors": e, "skipped": s}

    ok = all(g["ok"] for g in gates.values())
    out = {"proxy": meta["proxy"], "project": meta["project"], "result": "PASS" if ok else "FAIL", "gates": gates}
    (mod / "GATES.json").write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    for k, g in gates.items():
        print(f"{'ok  ' if g['ok'] else 'FAIL'} {k} " + json.dumps({x: y for x, y in g.items() if x != 'ok'}))
    print(out["result"])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_CHECK_CAMELK_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/domain_report.py")"
cat > '.pi/skills/osb-camelk-route/scripts/domain_report.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_DOMAIN_REPORT_PY'
#!/usr/bin/env python3
"""Functional-testing report for one OSB application (domain): the proof, per flow and in total. Stdlib only.

    domain_report.py <workspace> [-o <workspace>/domain/FUNCTIONAL_TEST_REPORT.md]

Reads only what the other steps wrote (no payloads, no source): research packs, domain/COVERAGE.csv, the modules'
flow-test.json, case folders (counted), expected-output files (counted), surefire reports, GATES.json, MUTATION.json.
Per flow it answers the five proof questions:
  1 inputs     real masked Splunk messages / synthetic messages from the schema / none
  2 expected   outputs per scenario from the research pack; body: logged by OSB / original XQuery / not compared
  3 mocks      every queue and backend replaced (count), no broker
  4 result     tests run / failed against the Camel K route (or "not built yet")
  5 strength   deliberate route defects caught (mutation check)
and lists the gaps. Writes FUNCTIONAL_TEST_REPORT.md + functional-test-report.csv (names and counts only)."""
import argparse
import csv
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def load(p: Path, default):
    try:
        return json.loads(p.read_text(encoding="utf-8")) if p.is_file() else default
    except ValueError:
        return default


def surefire(mod: Path) -> dict | None:
    reps = list((mod / "target/surefire-reports").glob("TEST-*.xml"))
    if not reps:
        return None
    t = f = s = 0
    for rep in reps:
        r = ET.parse(rep).getroot()
        t += int(r.get("tests", 0))
        f += int(r.get("failures", 0)) + int(r.get("errors", 0))
        s += int(r.get("skipped", 0))
    return {"tests": t, "failed": f, "skipped": s}


def flow_row(ws: Path, project: str, proxy: str, coverage: dict) -> dict:
    res = load(ws / "research" / project / proxy / "research.json", {})
    share = load(ws / "research" / project / proxy / "SHARE_CHECK.json", {})
    mod = ws / "modules" / project / proxy
    cfg = load(mod / "src/test/resources/flow-test.json", {})
    par = mod / "src/test/resources/parity"
    cases = [p.parent for p in par.glob("**/input.payload")] if par.is_dir() else []
    real = [c for c in cases if "-synthetic" not in c.as_posix()]
    syn = [c for c in cases if "-synthetic" in c.as_posix()]
    logged = sum(1 for c in cases if any(c.glob("expected-output.*")))
    xq = any(t.get("mappings") for t in res.get("transforms") or [])
    gates = load(mod / "GATES.json", {})
    mut = load(mod / "MUTATION.json", {})
    sf = surefire(mod)
    card = (mod / "FLOW_CARD.md").read_text(encoding="utf-8") if (mod / "FLOW_CARD.md").is_file() else ""
    st = re.search(r"^Status:\s*(.+?)\s*$", card, re.M | re.I)          # the Status line, not the instruction text
    st = st.group(1).lower() if st else ""
    approved = "approved" if st == "approved" else ("POC run" if st.startswith("poc") else ("draft" if card else "-"))
    outputs = [o for o in (cfg.get("outputs") or {}) if o != "reply"]
    body = (f"compared for {logged} cases" if logged else
            ("XQuery: expected body pending" if xq else "not transformed (forwarded / no body)"))
    gaps = []
    if not share.get("pass"):
        gaps.append("research")
    if not cases:
        gaps.append("no test cases")
    elif not real:
        gaps.append("synthetic inputs only")
    if xq and not logged:
        gaps.append("body oracle")
    if sf is None:
        gaps.append("route not built")
    elif sf["failed"]:
        gaps.append(f"{sf['failed']} tests failing")
    if mut and mut.get("killed", 0) < mut.get("total", 0):
        gaps.append("mutation survived")
    if res.get("open_questions"):
        gaps.append(f"{len(res['open_questions'])} open questions")
    return {"project": project, "proxy": proxy, "group": coverage.get((project, proxy), "?"),
            "research": "PASS" if share.get("pass") else ("FAIL" if share else "-"),
            "scenarios": len(cfg.get("scenario_mapping") or []), "real_cases": len(real), "synthetic_cases": len(syn),
            "mocked_outputs": len(outputs) + len(cfg.get("backends") or {}), "reply": "yes" if "reply" in (cfg.get("outputs") or {}) else "no",
            "body_oracle": body, "card": approved,
            "tests": sf["tests"] if sf else "-", "failed": sf["failed"] if sf else "-",
            "mutations": f"{mut['killed']}/{mut['total']}" if mut else "-",
            "gates": gates.get("result", "-"), "gaps": "; ".join(gaps) or "none"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workspace", type=Path)
    ap.add_argument("-o", "--out", type=Path)
    a = ap.parse_args()
    ws = a.workspace
    status = ws / "domain/status.csv"
    if not status.is_file():
        sys.exit("domain/status.csv missing: run run_domain.sh <app> status first")
    flows = [(r["project"], r["proxy"]) for r in csv.DictReader(status.open(encoding="utf-8"))]
    coverage = {}
    cov = ws / "domain/coverage.csv"
    if cov.is_file():
        coverage = {(r["project"], r["proxy"]): r["group"].split(" ")[0] for r in csv.DictReader(cov.open(encoding="utf-8"))}
    rows = [flow_row(ws, p, x, coverage) for p, x in flows]
    out = a.out or ws / "domain/FUNCTIONAL_TEST_REPORT.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    cols = list(rows[0]) if rows else ["project"]
    with out.with_name("functional-test-report.csv").open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    n = len(rows)
    num = lambda k: sum(r[k] for r in rows if isinstance(r[k], int))  # noqa: E731
    built = [r for r in rows if isinstance(r["tests"], int)]
    green = [r for r in built if r["failed"] == 0]
    kill = [r["mutations"].split("/") for r in rows if "/" in r["mutations"]]
    proven = [r for r in green if "/" in r["mutations"] and r["mutations"].split("/")[0] == r["mutations"].split("/")[1]]
    md = [f"# Functional test report: {ws.resolve().name}", "",
          "Proof per flow: (1) inputs from production or the schema, (2) expected outputs from the OSB source and, for the "
          "body, from what OSB logged or the original XQuery, (3) every queue and backend mocked, (4) the Camel K route "
          "passes, (5) deliberate route defects are caught. Names and counts only.", "",
          "| Measure | Value |", "|---|---|",
          f"| Flows | {n} |",
          f"| Research packs PASS | {sum(r['research'] == 'PASS' for r in rows)} |",
          f"| Flows with a test pack | {sum((r['real_cases'] + r['synthetic_cases']) > 0 for r in rows)} |",
          f"| Scenarios / real cases / synthetic cases | {num('scenarios')} / {num('real_cases')} / {num('synthetic_cases')} |",
          f"| Flows built and run | {len(built)} |",
          f"| Flows green (0 failed) | {len(green)} |",
          f"| Tests run / failed | {sum(r['tests'] for r in built)} / {sum(r['failed'] for r in built)} |",
          f"| Mutations caught | {sum(int(k) for k, _ in kill)} / {sum(int(t) for _, t in kill)} |",
          f"| **Flows proven (green + every mutation caught)** | **{len(proven)}** |", "",
          "| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    md += ["| " + " | ".join(str(r[c]).replace("|", "/") for c in cols) + " |" for r in rows]
    open_gaps = {}
    for r in rows:
        for g in r["gaps"].split("; "):
            if g != "none":
                key = g.split(" ", 1)[1] if g[0].isdigit() else g
                open_gaps[key] = open_gaps.get(key, 0) + 1
    md += ["", "## Gaps across the domain", ""] + [f"- {k}: {v} flows" for k, v in sorted(open_gaps.items(), key=lambda kv: -kv[1])]
    out.write_text("\n".join(md) + "\n", encoding="utf-8")
    print(json.dumps({"flows": n, "built": len(built), "green": len(green), "proven": len(proven), "out": str(out)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_DOMAIN_REPORT_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/flow_patterns.py")"
cat > '.pi/skills/osb-camelk-route/scripts/flow_patterns.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_FLOW_PATTERNS_PY'
#!/usr/bin/env python3
"""Clusters the flows of an OSB application by their PATTERN (what the pipeline does, in which order), from the inventory
written by osb_inventory.py. Stdlib only, names and counts only.

    flow_patterns.py <inventory dir> [-o PATTERNS.md] [--json patterns.json]

Signature of a flow = proxy transport | ordered action sequence of the request stages | of the response stages | of the
error stages | branch kinds | business-service transports. Flows with the same signature differ only in names, endpoints,
conditions and transformation files, i.e. in parameters, not in logic. Why it matters for a weak model: the agent
researches ONE representative per pattern with care (few-shot material for its siblings), scripts extract the
parameters of every sibling, and the tests check each sibling against its own real messages. Research calls drop from
one per flow to one per pattern, and every sibling's answer is checked against a known-good template."""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path


def signature(d: dict) -> tuple:
    pipe = d.get("pipeline") or {}
    by_type: dict = defaultdict(list)
    for st in pipe.get("stages") or []:
        by_type[st.get("type") or "?"].append("+".join(st.get("actions") or []))
    branches = tuple(sorted(b.get("type", "?") for b in pipe.get("branches") or []))
    biz = tuple(sorted(str(b.get("transport") or "?") for b in d.get("business") or []))
    return (str((d.get("proxy") or {}).get("transport") or "?"),
            " > ".join(by_type.get("request", [])), " > ".join(by_type.get("response", [])), " > ".join(by_type.get("error", [])),
            branches, biz)


def family(d: dict) -> str:
    """Coarse group by the constructs a flow uses: the level at which research and generator work are shared."""
    pipe = d.get("pipeline") or {}
    acts = set((pipe.get("action_counts") or {}).keys())
    tr = str((d.get("proxy") or {}).get("transport") or "?")
    biz = {str(b.get("transport") or "?") for b in d.get("business") or []}
    tags = [f"in={tr}"]
    if "nxsdTranslation" in acts:
        tags.append("nxsd")
    if {"wsCallout"} & acts:
        tags.append("callout")
    if "javaScript" in acts or "javascript" in acts:
        tags.append("js")
    if "jca" in biz or tr == "jca":
        tags.append("db")
    if {"foreach", "forEach"} & acts:
        tags.append("loop")
    if "reply" in acts and tr in ("http", "local", "sb"):
        tags.append("reply")
    tags.append("out=" + ",".join(sorted(biz)) if biz else "out=-")
    return " ".join(tags)


def label(sig: tuple) -> str:
    tr, req, resp, err, br, biz = sig
    parts = [f"in={tr}", f"request[{req or '-'}]"]
    if resp:
        parts.append(f"response[{resp}]")
    if err:
        parts.append(f"error[{err}]")
    if br:
        parts.append("branches=" + ",".join(br))
    parts.append("out=" + ",".join(biz) if biz else "out=-")
    return " | ".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inventory", type=Path)
    ap.add_argument("-o", "--out", type=Path)
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()
    files = sorted((a.inventory / "flows").glob("*.json"))
    if not files:
        print(f"no flows under {a.inventory}/flows (run osb_inventory.py first)")
        return 2
    clusters: dict = defaultdict(list)
    families: dict = defaultdict(list)
    for f in files:
        d = json.loads(f.read_text(encoding="utf-8"))
        name = f"{d.get('project', '')}/{(d.get('proxy') or {}).get('name') or f.stem}"
        clusters[signature(d)].append((name, (d.get("triage") or {}).get("tier", "-")))
        families[family(d)].append(name)
    ordered = sorted(clusters.items(), key=lambda kv: -len(kv[1]))
    n = len(files)
    fam = sorted(families.items(), key=lambda kv: -len(kv[1]))
    L = [f"# Flow patterns: {a.inventory}", "", f"{n} flows in {len(fam)} families (by constructs used) and {len(ordered)} exact patterns "
         "(by action sequence). Research one representative per family with care, one per exact pattern cheaply, extract the "
         "parameters of the others by script, test each flow against its own real messages.", "",
         "## Families", "", "| # | Flows | Family | Representative | Members |", "|---|---|---|---|---|"]
    for i, (k, names) in enumerate(fam, 1):
        L.append(f"| {i} | {len(names)} | {k} | {names[0]} | {', '.join(names[1:8])}{' ...' if len(names) > 8 else ''} |")
    L += ["", "## Exact patterns", "", "| # | Flows | Pattern | Representative | Members |", "|---|---|---|---|---|"]
    out_json = []
    for i, (sig, members) in enumerate(ordered, 1):
        names = [m[0] for m in members]
        L.append(f"| {i} | {len(members)} | {label(sig)} | {names[0]} | {', '.join(names[1:6])}{' ...' if len(names) > 6 else ''} |")
        out_json.append({"pattern": i, "flows": len(members), "signature": label(sig), "representative": names[0], "members": names})
    covered = sum(len(m) for _, m in ordered[:10])
    L += ["", f"The 10 largest patterns cover {covered} of {n} flows ({100 * covered // max(n, 1)}%)."]
    text = "\n".join(L) + "\n"
    if a.out:
        a.out.write_text(text, encoding="utf-8")
    if a.json:
        a.json.write_text(json.dumps(out_json, indent=2), encoding="utf-8")
    print("\n".join(L[:3] + L[7:7 + min(len(fam), 12)] + L[-1:]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_FLOW_PATTERNS_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/generator_coverage.py")"
cat > '.pi/skills/osb-camelk-route/scripts/generator_coverage.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_GENERATOR_COVERAGE_PY'
#!/usr/bin/env python3
"""Which flows of an OSB application the generator can produce today, and which OSB constructs block the rest.
Reads the inventory written by osb_inventory.py (flows/*.json). Stdlib only, prints names and counts, no data.

    generator_coverage.py <inventory dir> [-o COVERAGE_GENERATOR.md]

Per flow: every pipeline action type, the proxy/business transports and the fn-bea functions are compared with what
assemble_jbang.py / body_chain.py generate today. A flow is "generated" when all of them are covered, else "blocked by"
the list of constructs. Per construct: how many flows use it, so the generator is extended in the order that frees
the most flows. The one-time extension replaces per-flow manual work."""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

# what the generator produces today (keep in sync with body_chain.py / assemble_jbang.py)
COVERED_ACTIONS = {"assign", "replace", "nxsdTranslation", "ifThenElse", "route", "log", "transportHeaders",
                   "transport-headers", "reply", "Error", "raiseError", "resume", "skip", "report", "alert"}
COVERED_TRANSPORTS = {"jms"}
COVERED_FN_BEA = {"uuid", "serialize"}
# covered with a documented assumption (listed under notes, not as a blocker)
NOTE_ONLY = {"routing-options": "route retry/URI overrides: generator uses the business-service defaults (retry 0); check BODY_CHAIN.md",
             "routingOptions": "see routing-options",
             "fn-bea:serialize": "serialize(): shim in OsbXQuery.java (Saxon serializer)"}
# how an uncovered construct is handled until the generator knows it
HOW = {"wsCallout": "service callout: generate to:{{backend}} + response variable; stub from WSDL/XSD",
       "javaCallout": "compiled Java in the export: port or wrap once per jar, cannot be generated",
       "javaScript": "JavaScript action: run the same script on Camel's JavaScript language (GraalJS) with a shim for the OSB process.* API; port by hand only where that fails",
       "javascript": "see javaScript",
       "publish": "publish: generate as fire-and-forget to:{{out}}", "publishTable": "publish table: generate as choice",
       "routeTable": "routing table: generate as choice", "dynamicRoute": "dynamic route: generate recipientList from the expression",
       "dynamicPublish": "dynamic publish: generate recipientList", "forEach": "forEach: generate split/aggregate",
       "insert": "insert/delete/rename: generate as an XQuery update step on Saxon", "delete": "see insert",
       "rename": "see insert", "validate": "validate: generate validator:{{xsd}}", "mflTransform": "MFL: no Camel equivalent, by hand",
       "nXSDTransform": "nXSD transform (XML-To-Native): reverse converter needed", "routingOptions": "routing options: map to endpoint options",
       "routing-options": "see routingOptions", "http": "HTTP transport: generate platform-http / http endpoints + reply",
       "sb": "SB transport: generate direct/endpoint", "jdbc": "JDBC: generate sql endpoint + stub",
       "jca": "JCA DB adapter (poller / insert / stored procedure): generate camel-sql / camel-jdbc endpoints from the adapter config; test with H2 stub",
       "lookupBasicCredentials": "service-account credentials: shim that reads a property/secret per account name",
       "execute-sql": "SQL inside XQuery: shim backed by camel-sql datasource, or move the query to a sql: step",
       "binary-to-text": "shim: base64/binary -> string", "inlinedXML": "shim: parse string -> node", "trim": "shim", "format-number": "shim",
       "fn-bea": "OSB XQuery function: one Saxon extension shim in OsbXQuery.java, written once, reused by every flow"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inventory", type=Path)
    ap.add_argument("-o", "--out", type=Path)
    a = ap.parse_args()
    files = sorted((a.inventory / "flows").glob("*.json"))
    if not files:
        print(f"no flows under {a.inventory}/flows (run osb_inventory.py first)")
        return 2
    rows, blockers, by_tier = [], Counter(), Counter()
    for f in files:
        d = json.loads(f.read_text(encoding="utf-8"))
        pipe = d.get("pipeline") or {}
        acts = set((pipe.get("action_counts") or {}).keys()) | set(pipe.get("unknown_actions") or [])
        trans = {str((d.get("proxy") or {}).get("transport") or "").lower()} | {str(b.get("transport") or "").lower() for b in d.get("business") or []}
        trans.discard("")
        fnbea = {fn for t in d.get("transforms") or [] for fn in t.get("fn_bea") or []} | set(pipe.get("fn_bea_inline") or [])
        xml_to_native = any("xml-to-native" in str(v).lower() for v in (pipe.get("nxsd_types") or []))
        raw = ((acts - COVERED_ACTIONS) | {t for t in trans if t not in COVERED_TRANSPORTS}
               | {f"fn-bea:{fn}" for fn in fnbea if fn not in COVERED_FN_BEA} | ({"nXSD XML-To-Native"} if xml_to_native else set()))
        notes = sorted(x for x in raw if x in NOTE_ONLY)
        bl = sorted(x for x in raw if x not in NOTE_ONLY)
        name = f"{d.get('project', '')}/{(d.get('proxy') or {}).get('name') or f.stem}"
        rows.append((name, (d.get("triage") or {}).get("tier", "-"), bl, notes))
        blockers.update(bl)
        by_tier[("generated" if not bl else "blocked")] += 1
    L = [f"# Generator coverage: {a.inventory}", "", f"{len(rows)} flows: {by_tier['generated']} generated today, {by_tier['blocked']} blocked by constructs the generator does not know yet.", "",
         "## Constructs by number of flows (extend the generator in this order)", "", "| Construct | Flows | How to cover it |", "|---|---|---|"]
    for c, n in blockers.most_common():
        key = c.split(":", 1)[1] if c.startswith("fn-bea:") else c
        L.append(f"| {c} | {n} | {HOW.get(key, HOW.get(c, 'extend body_chain/assemble_jbang'))} |")
    L += ["", "Covered with a documented assumption (not blockers): " + "; ".join(f"{k}: {v}" for k, v in NOTE_ONLY.items() if k != "routingOptions"), ""]
    L += ["## Flows", "", "| Flow | Triage tier | Status | Notes |", "|---|---|---|---|"]
    for name, tier, bl, notes in rows:
        L.append(f"| {name} | {tier} | {'generated' if not bl else 'blocked by ' + ', '.join(bl)} | {', '.join(notes)} |")
    text = "\n".join(L) + "\n"
    if a.out:
        a.out.write_text(text, encoding="utf-8")
    print("\n".join(L[:4 + min(len(blockers), 12) + 4]))
    if a.out:
        print(f"-> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_GENERATOR_COVERAGE_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/mutate_route.py")"
cat > '.pi/skills/osb-camelk-route/scripts/mutate_route.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_MUTATE_ROUTE_PY'
#!/usr/bin/env python3
"""Mutation check for ONE Camel K module: break the YAML route on purpose, one defect at a time, and prove the tests
notice. A test suite that stays green on a broken route proves nothing. Stdlib only.

    mutate_route.py modules/<project>/<proxy> [--mvn "mvn -B -q -s ~/.m2/settings.xml"] [--max 12]

Mutations (generic, from the route text):
  negate      every simple condition: '==' <-> '!=' (a branch taken for the wrong messages)
  swap-out    every output endpoint {{out.a}} -> another output {{out.b}} (message sent to the wrong queue)
  drop-out    every output step removed (message silently lost)
  no-retry    every redelivery count -> 0 (business service retry ignored)
Each mutation runs `mvn test`; a non-zero exit = caught. The route file is always restored, even on Ctrl-C.
Writes MUTATION.json (what, killed) next to the pom. Exit 1 if any mutation survived, 2 if the check could not run."""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


def win_path(arg: str) -> str:
    """Git Bash path (/c/Users/x) -> Windows path (c:/Users/x) when running natively on Windows; else unchanged."""
    return re.sub(r"^/([a-zA-Z])/", r"\1:/", arg) if os.name == "nt" else arg


def mutations(text: str) -> list[tuple[str, str]]:
    out = []
    for m in re.finditer(r"(simple:\s*\"[^\"]*?)(==|!=)", text):
        flip = "!=" if m.group(2) == "==" else "=="
        ids = re.findall(r"\bid:\s*([\w.-]+)", text[:m.start(2)])
        out.append((f"negate condition of {ids[-1] if ids else 'a branch'}", text[:m.start(2)] + flip + text[m.end(2):]))
    outs = re.findall(r"\{\{out\.([\w.-]+)\}\}", text)
    names = sorted(set(outs))
    for m in re.finditer(r"\{\{out\.([\w.-]+)\}\}", text):
        other = next((n for n in names if n != m.group(1)), None)
        if other:
            out.append((f"send to out-{other} instead of out-{m.group(1)}", text[:m.start()] + "{{out." + other + "}}" + text[m.end():]))
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if re.match(r"\s*- to:\s*$", line) and i + 2 < len(lines) and "{{out." in "".join(lines[i + 1:i + 3]):
            ind = len(line) - len(line.lstrip())
            j = i + 1
            while j < len(lines) and (len(lines[j]) - len(lines[j].lstrip())) > ind and lines[j].strip():
                j += 1
            target = re.search(r"\{\{out\.([\w.-]+)\}\}", "".join(lines[i:j])).group(1)
            stub = " " * ind + "- log:\n" + " " * (ind + 4) + "message: \"mutation: output removed\"\n"
            out.append((f"drop the step sending to out-{target}", "".join(lines[:i]) + stub + "".join(lines[j:])))
    for m in re.finditer(r"(maximumRedeliveries:\s*\")([^\"]+)(\")", text):
        out.append(("retry count set to 0", text[:m.start(2)] + "0" + text[m.end(2):]))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--mvn", default="mvn -B -q")
    ap.add_argument("--max", type=int, default=12)
    a = ap.parse_args()
    a.mvn = " ".join(shlex.quote(win_path(os.path.expanduser(x))) for x in shlex.split(a.mvn))   # ~ and /c/... paths
    first = shlex.split(a.mvn)[0]
    exe = shutil.which(first) or shutil.which(first + ".cmd")   # Windows: Maven is mvn.cmd, subprocess needs the full name
    if not exe:
        print(f"cannot find '{first}' on PATH (Maven 3.9 must be on PATH)")
        return 2
    a.mvn = " ".join([shlex.quote(exe)] + [shlex.quote(x) for x in shlex.split(a.mvn)[1:]])
    routes = sorted((a.module / "src/main/resources/routes").glob("*.camel.yaml"))
    if not routes:
        sys.exit("no *.camel.yaml route in the module")
    base = subprocess.run(shlex.split(a.mvn) + ["-f", str(a.module / "pom.xml"), "test"], capture_output=True, text=True)
    if base.returncode:
        print("tests are not green on the unchanged route: fix that first (mutation check needs a green baseline)")
        return 2
    results = []
    for route in routes:
        orig = route.read_text(encoding="utf-8")
        try:
            for what, text in mutations(orig)[:a.max]:
                route.write_text(text, encoding="utf-8")
                r = subprocess.run(shlex.split(a.mvn) + ["-f", str(a.module / "pom.xml"), "test"], capture_output=True, text=True)
                results.append({"route": route.name, "what": what, "killed": r.returncode != 0})
                print(f"{'caught  ' if r.returncode else 'MISSED  '}{what}", flush=True)
        finally:
            route.write_text(orig, encoding="utf-8")
    subprocess.run(shlex.split(a.mvn) + ["-f", str(a.module / "pom.xml"), "test"], capture_output=True)   # leave green reports
    killed = sum(m["killed"] for m in results)
    (a.module / "MUTATION.json").write_text(json.dumps({"killed": killed, "total": len(results), "mutations": results}, indent=2) + "\n",
                                            encoding="utf-8")
    print(f"mutations caught {killed}/{len(results)}")
    return 0 if killed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_MUTATE_ROUTE_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/review_note.py")"
cat > '.pi/skills/osb-camelk-route/scripts/review_note.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_REVIEW_NOTE_PY'
#!/usr/bin/env python3
"""Draft review handover note for flat delivery projects, with the numbers and the review points the kit can detect
filled in. Stdlib only. The author edits it (open points from people, name, channel) before sending.

    review_note.py <delivery/<app>> --projects 'a-prj|b-prj' [--modules <ws>/modules] [-o REVIEW_HANDOVER_DRAFT.md]

Reads per flat project: target/surefire-reports (mock tests), src/docs/<proxy>/E2E_ARTEMIS.txt (broker run of
e2e_local.sh), src/docs/<proxy>/GATES.json, the route file and the Java files; per module (optional): research.json
open questions. Detects: failing tests, failing gates other than K1, extra Java classes the agent added (and whether
the route uses them), route comments that call a draft card approved, cases the subscription selector filters,
selector properties the cases lack (filled in the broker run), queues that differ in the broker run."""
from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def jbang_results(project: Path) -> dict | None:
    """test/RESULTS.txt of the no-pom layout (run-local.sh test): 'PASS/FAIL name' lines and 'N tests, M failed'."""
    f = project / "test/RESULTS.txt"
    if not f.is_file():
        return None
    t = f.read_text(encoding="utf-8", errors="replace")
    tot = [tuple(map(int, m)) for m in re.findall(r"^(\d+) tests, (\d+) failed", t, re.M)]
    failed = [ln[5:200] for ln in t.splitlines() if ln.startswith("FAIL ")]
    return {"ran": bool(tot), "tests": sum(a for a, _ in tot), "failures": sum(b for _, b in tot), "errors": 0, "skipped": 0,
            "failed": failed}


def surefire(project: Path) -> dict:
    t = f = e = s = 0
    failed = []
    for x in sorted((project / "target/surefire-reports").glob("TEST-*.xml")):
        r = ET.parse(x).getroot()
        t += int(r.get("tests", 0)); f += int(r.get("failures", 0)); e += int(r.get("errors", 0)); s += int(r.get("skipped", 0))
        for tc in r.iter("testcase"):
            bad = tc.find("failure") if tc.find("failure") is not None else tc.find("error")
            if bad is not None:
                msg = ((bad.get("message") or "").strip().splitlines() or [""])[0]
                failed.append(f"{tc.get('name', '')[:90]}: {msg[:160]}")
    return {"ran": t > 0, "tests": t, "failures": f, "errors": e, "skipped": s, "failed": failed}


def e2e(text: str) -> dict:
    if not text:
        return {}
    out = {"result": "", "inputs": [], "rows": [], "filtered": [], "filled": set()}
    for ln in text.splitlines():
        if ln.startswith("RESULT:"):
            out["result"] = ln[7:].strip()
        m = re.match(r"input of (\S+): subscription queue (\S+): (\d+) expected past the selector, (\S+) arrived", ln)
        if m:
            out["inputs"].append(m.groups())
        m = re.match(r"(\S+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(OK|DIFF)$", ln.strip())
        if m:
            out["rows"].append(m.groups())
        m = re.match(r"\s+(\S+) (\S+) -> expect \(filtered by the subscription selector\)", ln)
        if m:
            out["filtered"].append((m.group(1), m.group(2)))
        m = re.search(r"\(\+(.*?) for the selector\)", ln)
        if m:
            out["filled"].update(x.strip() for x in m.group(1).split(", ") if "=" in x)
    return out


def extra_classes(project: Path, flow: str) -> list[tuple[str, bool]]:
    route = "\n".join(p.read_text(encoding="utf-8") for p in project.glob("*-route.yaml"))
    props = (project / "application.properties").read_text(encoding="utf-8") if (project / "application.properties").is_file() else ""
    out = []
    for j in sorted(project.glob(f"{flow}*.java")):
        n = j.stem
        if n == f"{flow}Transformer" or n.endswith("Test") or "Test" in n:
            continue
        used = n in route or n in props or any(n in o.read_text(encoding="utf-8") for o in project.glob("*.java")
                                               if o != j and "Test" not in o.stem)        # used by production code only
        out.append((n, used))
    return out


def camel(proxy: str) -> str:
    return "".join(p[:1].upper() + p[1:] for p in re.split(r"[^A-Za-z0-9]+", proxy) if p)


def docs_dir(project: Path) -> Path:
    return project / "docs" if (project / "docs").is_dir() else project / "src/docs"


def flows_of(project: Path) -> list[str]:
    d = docs_dir(project)
    return sorted(x.name for x in d.iterdir() if x.is_dir()) if d.is_dir() else []


def project_section(project: Path, modules: Path | None) -> tuple[list[str], list[str]]:
    """(paragraphs about the project, review points)."""
    st = jbang_results(project) or surefire(project)
    flows = flows_of(project)
    route = "\n".join(p.read_text(encoding="utf-8") for p in project.glob("*-route.yaml"))
    text, points = [], []
    if not st["ran"]:
        text.append(f"For {project.name} the mock tests did not run (build error), see target/ of the project.")
        points.append(f"{project.name}: the mock tests did not compile or run; fix before sending.")
    else:
        text.append(f"For {project.name} the mock tests ran {st['tests']} tests with {st['failures'] + st['errors']} failing "
                    f"and {st['skipped']} skipped.")
        for fl in st["failed"][:5]:
            points.append(f"{project.name}: failing test {fl}")
    for flow in flows:
        docs = docs_dir(project) / flow
        ev = e2e((docs / "E2E_ARTEMIS.txt").read_text(encoding="utf-8", errors="replace") if (docs / "E2E_ARTEMIS.txt").is_file() else "")
        br = docs / "BROKER_RUN.txt"
        if br.is_file():
            t = br.read_text(encoding="utf-8", errors="replace")
            sent = len(re.findall(r"^send ", t, re.M))
            routed = re.findall(r"^\s*(\d+) (Sending to \S+|Error captured)", t, re.M)
            text.append(f"On the local Artemis (camel run with the Artemis kamelets) I sent {sent} case(s) of {flow}; the route log shows "
                        + (", ".join(f"{n} x {w.replace('Sending to ', 'sent to ')}" for n, w in routed) or "nothing routed")
                        + f". The queue counts are in docs/{flow}/BROKER_RUN.txt.")
            if "Error captured" in t:
                points.append(f"{flow}: in the broker run some messages went to the error queue, see the route log in BROKER_RUN.txt.")
            bc = docs / "BODY_CHAIN.md"
            if bc.is_file():
                todo = [ln[2:] for ln in bc.read_text(encoding="utf-8").splitlines() if ln.startswith("- ") and ln != "- nothing"]
                points += [f"{flow}: {x}" for x in todo]
            continue
        if not ev:
            text.append(f"The broker test for {flow} has not been run (no src/docs/{flow}/E2E_ARTEMIS.txt).")
            points.append(f"{flow}: broker test missing (e2e_local.sh).")
        else:
            past = [i for i in ev["inputs"] if i[0] == flow]
            rows = [r for r in ev["rows"] if r[0] == flow]
            s = f"On the local Artemis, for {flow}"
            if past:
                s += f" {past[0][3]} of {past[0][2]} messages got through the selector"
            s += "; " + ", ".join(f"{r[3]} of {r[2]} arrived on {r[1]}" for r in rows) + f". Result: {ev['result'] or 'no result line'}."
            text.append(s)
            for r in rows:
                if r[4] == "DIFF":
                    points.append(f"{flow}: broker run, {r[1]} expected {r[2]} but {r[3]} arrived.")
            filt = [c for f_, c in ev["filtered"] if f_ == flow]
            if filt:
                points.append(f"{flow}: the subscription selector filters test cases taken from the logs for this proxy "
                              f"({', '.join(filt)}). Either the selector in the export is outdated or those cases do not belong here.")
            if ev["filled"]:
                props_ = sorted({x.split("=", 1)[0] for x in ev["filled"]})
                points.append(f"{flow}: some test cases lack {', '.join(props_)}, which the selector needs (OSB does not log "
                              f"it); the broker test set {', '.join(sorted(ev['filled']))}. Please confirm these values are realistic.")
        g = docs / "GATES.json"
        if g.is_file():
            gates = json.loads(g.read_text(encoding="utf-8")).get("gates", {})
            bad = [k for k, v in gates.items() if not v.get("ok") and k != "K1_card_approved"]
            if bad:
                points.append(f"{flow}: gates not passed: {', '.join(bad)}.")
            if not gates.get("K1_card_approved", {}).get("ok") and re.search(r"approved FLOW_CARD", route, re.I):
                points.append(f"{flow}: the route comments call the flow card approved, but it is a draft until this review.")
        for n, used in extra_classes(project, camel(flow)):
            points.append(f"{flow}: the agent added {n}.java; " + ("the route or another class uses it, please review it."
                                                                  if used else "nothing refers to it, remove it."))
        if modules:
            for r in (modules.parent / "research").glob(f"*/{flow}/research.json"):
                oq = json.loads(r.read_text(encoding="utf-8")).get("open_questions") or []
                if oq:
                    points.append(f"{flow}: {len(oq)} open question(s) from the research pack (RESEARCH.md).")
    return text, points


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("app", type=Path)
    ap.add_argument("--projects", default=".*")
    ap.add_argument("--modules", type=Path)
    ap.add_argument("-o", "--out", type=Path)
    a = ap.parse_args()
    projects = [p for p in sorted(a.app.iterdir()) if p.is_dir() and p.name != "Common-setup" and re.fullmatch(a.projects, p.name)]
    if not projects:
        print(f"no delivery projects matching '{a.projects}' in {a.app}")
        return 2
    flows = [(p.name, f) for p in projects for f in flows_of(p)]
    today = datetime.date.today().isoformat()
    paras, points = [], []
    for p in projects:
        t, pt = project_section(p, a.modules)
        paras += t
        points += pt
    names = " and ".join(f"{p} (proxy {f})" for p, f in flows)
    lines = [
        "<!-- DRAFT written by review_note.py. Check every sentence, add what only people know, then send. -->",
        "", "Hi all,", "",
        f"I am handing over {len(flows)} flow(s) from {a.app.name} for review: {names}. The routes are generated from the OSB "
        "export (pipeline, XQuery and nXSD files), and I tested them against frozen test cases taken from the Splunk logs (masked) and against a "
        "local Artemis broker. The flow cards are drafts, I would like this review to approve them or tell me what to change.", "",
        f"The archive is {a.app.name}_review_{today}.tgz. There is no pom: each OSB project folder has the route file "
        "<domain>-route.yaml (the Camel K integration), application.properties with the endpoints (OSB JNDI names, broker from "
        "BROKER_URL, BROKER_USER and BROKER_PASSWORD), local.properties for a local Artemis, transformations/ with OSB's own "
        ".xqy and nXSD files unchanged, test/ with one test file per flow, and docs/<proxy>/ with the flow card, BODY_CHAIN.md "
        "and the broker run. Common-setup holds the two Artemis kamelets (core JMS; the source opens the durable subscription "
        "with the OSB selector) and the two shared Java helpers with //DEPS (nXSD JSON to XML, and the XQuery engine).", "",
        "What the route does to the body is not written by hand or by the agent: it is read from each OSB pipeline "
        "(docs/<proxy>/BODY_CHAIN.md) and runs OSB's own files, so a flow that sends XML after its XQuery sends the same XML, "
        "and the error queue gets the original message as OSB's $request.", "",
        "bash run-local.sh test runs the tests with jbang and needs no broker and no connection factory: every endpoint is "
        "replaced by direct:/mock:. They check that every case reaches exactly the queue OSB used and no other, the original "
        "message and the error headers on the error queue, no transport headers on the business queues, well-formed XML where "
        "OSB sends XML, and equality with OSB's real output where an expected-output.xml exists. bash run-local.sh run starts "
        "the routes with camel run against a local Artemis; send and stat are described in RUN_LOCAL.md.", "",
        *[p + "\n" for p in paras],
        "Not tested yet: deployment with the Camel K operator, the production mapping of the JNDI names to broker addresses, "
        "the subscription queue on the real broker, load, broker failover, redelivery after a real broker outage, TLS and "
        "credentials from the vault, the real consumers of the output queues, and a side by side run with OSB.", "",
    ]
    if points:
        lines += ["There are a few things I need your view on:", ""] + [f"- {x}" for x in points] + [""]
    lines += [
        "From the review I would like a check of the route logic against the OSB proxies (stages, branches, error handler), "
        "your answers on the points above, approval of the flow cards in docs/<proxy>/FLOW_CARD.md or a list of changes, "
        "and your opinion on the layout.", "",
        "The test cases are masked log data and the docs contain the original XQuery logic, so please keep the archive on the "
        "client's systems.", "", "Thanks,", "<name>", ""]
    out = a.out or a.app / "REVIEW_HANDOVER_DRAFT.md"
    out.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print(json.dumps({"note": str(out), "flows": len(flows), "review_points": len(points)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_REVIEW_NOTE_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/run_local_doc.py")"
cat > '.pi/skills/osb-camelk-route/scripts/run_local_doc.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_RUN_LOCAL_DOC_PY'
#!/usr/bin/env python3
"""Standalone local run for a flat delivery project: RUN_LOCAL.md + run-local.sh written next to the route, so a
reviewer runs the flows with Java 21, Maven 3.9 and an Artemis only (no kit). Called by assemble_flat.py.

    run_local_doc.py <flat project folder>          (re)write the two files from src/env/local.properties"""
from __future__ import annotations

import json
import re
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "broker"))
try:
    from plan_queues import plan                      # noqa: E402
    from e2e_check import fill_for_selector           # noqa: E402
except ImportError:                                   # kit without broker/: no queue section
    plan = fill_for_selector = None


def local_props(project: Path) -> dict:
    out = {}
    f = project / "src/env/local.properties"
    for ln in f.read_text(encoding="utf-8").splitlines() if f.is_file() else []:
        if ln.strip() and not ln.lstrip().startswith(("#", "!")) and "=" in ln:
            k, v = ln.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def flows(props: dict) -> dict:
    """proxy -> (input address, selector, selector defaults)."""
    out = {}
    for k, v in props.items():
        if not k.endswith(".flow.input"):
            continue
        x = k[: -len(".flow.input")]
        m = re.search(r"destination=(?:queue|topic):([^?&\s]+)", v) or re.search(r"amqp:(?:queue|topic):([^?&\s]+)", v)
        addr = m.group(1).split("::")[0] if m else ""
        sel = props.get(f"{x}.flow.input.selector", "")
        out[x] = (addr, sel, fill_for_selector(sel, {}) if fill_for_selector and sel else {})
    return out


def script(project: Path, props: dict, fl: dict) -> str:
    q = shlex.quote
    creates = []
    for o in plan(dict(props)) if plan else []:
        if o["routing"] == "multicast":
            c = ["queue", "create", "--name", o["name"], "--address", o["address"], "--multicast", "--durable",
                 "--preserve-on-no-consumers", "--auto-create-address", "--silent"] + (["--filter", o["filter"]] if o["filter"] else [])
        elif o["routing"] == "anycast":
            c = ["queue", "create", "--name", o["name"], "--address", o["address"], "--anycast", "--durable", "--auto-create-address", "--silent"]
        else:
            c = ["address", "create", "--name", o["address"], "--multicast"]
        creates.append("    art " + " ".join(q(x) for x in c) + " || true")
    dlines = [f"-D{k}={v}" for k, v in props.items() if not k.endswith(".selector")]
    sends = "\n".join(f"    {q(x)}) dest={q('topic://' + a)}; defaults={q(json.dumps(d))};;" for x, (a, s, d) in fl.items())
    stats = " ".join(q(o["name"]) for o in (plan(dict(props)) if plan else []) if o["routing"] != "address")
    return f"""#!/usr/bin/env bash
# Local run of every flow of {project.name} against a local Artemis, without the migration kit.
# Needs: Java 21, Maven 3.9 with access to the Maven repository (MVN_ARGS="-s <settings.xml>" if needed),
#        an unzipped and running Artemis (ARTEMIS_HOME), and python for "send". See RUN_LOCAL.md.
#   bash run-local.sh queues                          create the subscription(s) (OSB selector as filter) and the queues
#   bash run-local.sh run                             start the route(s); Ctrl+C stops them
#   bash run-local.sh send <proxy> <case folder>      send one test case (input.payload + headers.json)
#   bash run-local.sh stat                            message counts of the queues of this project
set -u
cd "$(dirname "$0")"
: "${{ARTEMIS_HOME:?export ARTEMIS_HOME=<unzipped apache-artemis folder>}}"
: "${{BROKER_PASSWORD:?export BROKER_PASSWORD=<broker password>}}"
export BROKER_USER="${{BROKER_USER:-artemis}}" BROKER_URL="${{BROKER_URL:-amqp://localhost:5672}}"
CORE_URL="${{ARTEMIS_URL:-tcp://localhost:61616}}"
wp() {{ if command -v cygpath > /dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }}
art() {{ "${{JAVA_HOME:+$JAVA_HOME/bin/}}java" -cp "$(wp "$ARTEMIS_HOME/lib/artemis-boot.jar")" -Dartemis.home="$(wp "$ARTEMIS_HOME")" \\
  org.apache.activemq.artemis.boot.Artemis "$@" --user "$BROKER_USER" --password "$BROKER_PASSWORD" --url "$CORE_URL"; }}
case "${{1:-}}" in
  queues)
{chr(10).join(creates) or "    echo 'no broker objects found in src/env/local.properties'"}
    ;;
  run)
    export KAMELET_LOCATION="file:$(wp "$(cd ../Common-setup && pwd)")"
    exec mvn -B ${{MVN_ARGS:-}} -Prun-local compile exec:java \\
{chr(10).join("      " + q(d) + " " + chr(92) for d in dlines)}
      ;;
  send)
    x=${{2:?proxy}}; c=${{3:?case folder with input.payload and headers.json}}
    case "$x" in
{sends}
    *) echo "unknown proxy $x"; exit 2;;
    esac
    PY=$(command -v python3 || command -v python)
    props=$("$PY" -c "import json,sys; d=json.loads(sys.argv[1]); h=json.load(open(sys.argv[2], encoding='utf-8')); d.update(h); print(json.dumps([{{'type':'string','key':k,'value':str(v)}} for k,v in d.items()]))" "$defaults" "$c/headers.json")
    art producer --protocol AMQP --destination "$dest" --message-count 1 --message "$(cat "$c/input.payload")" --properties "$props" 2>&1 | grep -E "Produced|rror|xception" | head -3
    ;;
  stat)
    art queue stat --maxRows 500 --maxColumnSize -1 2>&1 | grep -E "^\\|NAME|{'|'.join(re.escape(n) for n in stats.split()) or 'NONE'}" | sed 's/^/  /'
    ;;
  *) sed -n '2,9p' "$0";;
esac
"""


def doc(project: Path, props: dict, fl: dict) -> str:
    lines = [f"# Run {project.name} locally", "",
             "This folder runs on its own: Java 21, Maven 3.9 (with access to the Maven repository), and a local Apache "
             "Artemis (2.4x). Everything below is in Git Bash (Windows) or any bash shell, in this folder.", "",
             "## 1 Mock tests, no broker", "", "```", "mvn test", "```", "",
             "Every test case under `src/test/resources/<proxy>/parity` is sent through the route with the endpoints replaced "
             "by mocks; the result says which queue each case reached, compared with what OSB did.", "",
             "## 2 Against a local Artemis", "", "```",
             "export ARTEMIS_HOME=<unzipped apache-artemis folder> BROKER_PASSWORD=<broker password>   # BROKER_USER defaults to artemis",
             "bash run-local.sh queues      # once: subscription(s) with the OSB selector as filter, output and error queues",
             "bash run-local.sh run         # start the routes, wait for 'Apache Camel ... started' (Ctrl+C stops)", "```", "",
             "In a second window (same exports):", "", "```"]
    for x in fl:
        lines.append(f"bash run-local.sh send {x} src/test/resources/{x}/parity/<flow>/<scenario>/<case>")
    lines += ["bash run-local.sh stat        # MESSAGES ADDED per queue", "```", "",
              "The route connects with `BROKER_URL` (default `amqp://localhost:5672`, the AMQP acceptor of a default Artemis "
              "instance; use `amqp://localhost:61616` if only that port is open). Queue names for the local run come from "
              "`src/env/local.properties` (the JNDI names of `application.properties` without the `jndi.` prefix).", "",
              "## Flows and their subscription", "", "| Proxy | Topic address | Selector | Added when a case lacks the property |",
              "|---|---|---|---|"]
    for x, (a, s, d) in fl.items():
        lines.append(f"| {x} | {a} | `{s or '-'}` | {', '.join(f'{k}={v}' for k, v in d.items()) or '-'} |")
    lines += ["", "OSB does not log every property the selector checks (for example eventType). `send` therefore starts from "
              "one allowed value per property and lets the case's own headers.json override it; a case whose properties the "
              "selector excludes is dropped by the broker, exactly as OSB's subscription would drop it.", ""]
    return "\n".join(lines)


def write(project: Path) -> None:
    props = local_props(project)
    fl = flows(props)
    (project / "run-local.sh").write_text(script(project, props, fl), encoding="utf-8", newline="\n")
    (project / "RUN_LOCAL.md").write_text(doc(project, props, fl), encoding="utf-8", newline="\n")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        write(Path(p))
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_RUN_LOCAL_DOC_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/scaffold_camelk.py")"
cat > '.pi/skills/osb-camelk-route/scripts/scaffold_camelk.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_SCAFFOLD_CAMELK_PY'
#!/usr/bin/env python3
"""Research pack -> Camel K module skeleton for ONE proxy (deterministic, no judgement).

    scaffold_camelk.py research/<project>/<proxy> -o modules/<project>/<proxy> --project <project>
                       [--parity task1/fixtures/parity] [--correlation-header traceId] [--force]

Reads research.json (+ facts.json for log scenario counts) and writes the module the pi implementer completes:
  FLOW_CARD.md                         the card a human approves (Status: draft -> approved)
  pom.xml                              Camel 4.18.4 test module (pilot pattern), extra deps from the transforms
  src/main/resources/routes/<proxy>.camel.yaml   route skeleton: entry, helper bean, OSB log lines, one choice per
                                       branch with ids branch-*, outputs out-*, backends listed, error catch;
                                       every gap is marked TODO(flow-card) and check_camelk.py fails until it is gone
  src/main/resources/application.properties      endpoints as properties (no hosts: env placeholders)
  src/main/java/<pkg>/OsbJson.java     lenient JSON + scenario headers (JSON flows only)
  src/test/java/<pkg>/FlowParityTest.java        generic parity test driven by
  src/test/resources/flow-test.json    outputs, backends, scenario_mapping, error output (from research.json)
  src/test/resources/stubs/README.md   which backend stubs the implementer must write (shape from research Q8)
  .scaffold.json                       hashes of the generated tests + the ids the route must contain
Route, properties and card are written once (the implementer edits them); tests and flow-test.json are regenerated
on every run so they always follow research.json. --parity copies the masked task-1 cases into the module (VDI only;
.gitignore keeps them out of Git). Stdlib only."""
import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

TPL = Path(__file__).resolve().parents[1] / "assets/templates"
TODO = "TODO(flow-card)"


def slug(s: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", (s or "").lower())).strip("-") or "x"


def java_pkg(project: str, proxy: str) -> str:
    part = lambda s: re.sub(r"^(\d)", r"_\1", re.sub(r"[^a-z0-9]", "", s.lower())) or "x"  # noqa: E731
    return f"osb.{part(project)}.{part(proxy)}"


def q(s) -> str:
    """YAML double-quoted scalar (JSON string syntax is valid YAML)."""
    return json.dumps(str(s), ensure_ascii=False)


HEADER_DIM = re.compile(r"^\$?(?:headers?|hdr|inbound)[._:]+(?:headers?[._:]+)?([\w-]+)$", re.I)


def dim_name(path: str) -> str:
    """The name Splunk labels a scenario field with (SCENARIO.txt): a message header (header.x, $header.x, hdr_x)
    -> hdr_x, a payload path (data.a.b, body:data.b, //b) -> its last segment."""
    p = path.strip()
    if p.startswith("hdr_"):
        return p
    m = HEADER_DIM.match(p)
    return "hdr_" + m.group(1) if m else re.split(r"[./:]", p.lstrip("/"))[-1]


OTHER = {"<other>", "other", "<default>", "default", "else", "<else>", "*", "any"}


def other_row(sc: str, rows: list) -> str:
    """'k=<other>' (the OSB default branch) -> 'k!=v1|k!=v2...' for every value of k named in the other rows, so the
    row matches what no other row takes (the first matching row wins anyway)."""
    out = []
    for p_ in sc.split("|"):
        k, _, v = p_.partition("=")
        if v.strip().lower() in OTHER and not k.endswith("!"):
            vals = [q.partition("=")[2] for x in rows for q in x["scenario"].split("|")
                    if q.partition("=")[0] == k and q.partition("=")[2].strip().lower() not in OTHER]
            out += [f"{k}!={x}" for x in dict.fromkeys(vals)] or [f"{k}!="]
        else:
            out.append(p_)
    return "|".join(out)


def clean(s) -> str:
    """A name as research wrote it, without notes: 'svc (BS)' -> 'svc', 'true (name auto-generated by container)' -> 'true'."""
    s = re.sub(r"\s*[(\[].*?[)\]]", "", str(s or "")).strip()
    return s.split()[0] if s.split() else ""


HTTP_WORDS = re.compile(r"(?i)^\s*(?:https?\b|(?:get|post|put|delete|patch)\s+/)")


def http_path(text) -> str:
    """The URI path of an HTTP destination as research writes it ('HTTP POST to /v1/x', 'POST /v1/x', 'http:/v1/x',
    'HTTP response on /a/b'); '' when the text is not an HTTP destination."""
    t = str(text or "")
    if not HTTP_WORDS.search(t):
        return ""
    m = re.search(r"(?<![\w:])(/[\w\-./{}~%]+)", t.replace("http:/", " /").replace("https:/", " /"))
    return m.group(1) if m else ""


def is_http(o: dict, b: dict | None) -> bool:
    """An output that is an HTTP call (its answer can be used), not a queue the flow writes to."""
    return bool(http_path(o.get("destination_raw")) or (b and str(b.get("type") or "").lower().startswith("http")))


def endpoint(dest: str, kind: str) -> str:
    """Production endpoint for a research destination (scheme:name, never a host)."""
    d = clean(dest)
    if not d or d.upper() == "UNKNOWN":
        return f"{TODO} destination of {kind}"
    m = re.match(r"^(https?):(/.*)$", d)
    if m:
        return f"{m.group(1)}://{{{{env:{slug(kind).upper().replace('-', '_')}_HOST}}}}{m.group(2)}"
    path = http_path(dest)
    if path:                             # 'HTTP POST to /v1/x', 'POST /v1/x': host from env, method set in the route
        return f"https://{{{{env:{slug(kind).upper().replace('-', '_')}_HOST}}}}{path}"
    name = re.sub(r"^(jms|amqp|queue|topic):", "", d)
    kind_ = "topic" if d.startswith("topic:") else "queue"
    return f"amqp:{kind_}:{name}"


def model(r: dict, facts: dict, corr: str) -> dict:
    """Normalise research.json: outputs keyed by the business service that writes them (JMS backends ARE outputs and
    get no reply stub), branch paths and scenario mapping resolved to those keys, one error output."""
    raw_backends = r.get("backends") or []
    outputs, alias = {}, {}
    for o in r.get("outputs") or []:
        dest = clean(o.get("destination"))
        bs = clean(o.get("business_service"))
        owner = next((b for b in raw_backends if (dest and dest in (clean(b.get("operation")), clean(b.get("destination"))))
                      or (bs and slug(clean(b.get("name"))) == slug(bs))), None)
        key = slug(bs or (clean(owner.get("name")) if owner else o.get("name")))
        outputs[key] = {"name": o.get("name"), "destination": dest, "on_path": o.get("on_path") or o.get("on") or "",
                        "headers": o.get("headers") or [], "backend": owner.get("name") if owner else None,
                        "destination_raw": str(o.get("destination") or ""), "body_from": o.get("body_from") or ""}
        for a in (o.get("name"), dest, clean(owner.get("name")) if owner else None, key):
            if a:
                alias[slug(a)] = key
    entry = r.get("entry") or {}
    wants_reply = (str(entry.get("transport") or "").lower().startswith(("http", "local", "sb"))
                   or str(entry.get("response_required") or "").lower() == "true"
                   or any(str(o).lower() == "reply" for x in r.get("scenario_mapping") or [] for o in (x.get("outputs") or [])))
    calls = {}       # request/reply flow: an HTTP business service is a CALL (mocked, answers with its stub), not an output
    if wants_reply:
        outputs["reply"] = {"name": "reply to the caller", "destination": "caller", "on_path": "end of the request pipeline",
                            "headers": [], "backend": None}
        alias["reply"] = "reply"
        for k in [k for k in outputs if k != "reply"]:
            o = outputs[k]
            b = next((x for x in raw_backends if slug(clean(x.get("name"))) in (k, slug(o.get("backend") or ""))), None)
            if is_http(o, b):
                calls[k] = {**(b or {}), "name": clean((b or {}).get("name")) or o.get("name") or k, "headers": o["headers"],
                            "operation": (b or {}).get("operation") or o["destination_raw"], "body_from": o["body_from"],
                            "type": (b or {}).get("type") or "HTTP"}
                del outputs[k]

    def resolve_(x):
        """An output as research names it in a table: exact alias, else the one output whose key contains the name as
        whole words ('bulk-register' -> 'business-service-bulk-register-bix'; the shortest wins over '...-error-queue-bix')."""
        for k in (slug(clean(x)), slug(x)):
            if k in alias:
                return alias[k]
        k = slug(clean(x))
        hits = sorted((o_ for o_ in outputs if k and re.search(rf"(^|-){re.escape(k)}(-|$)", o_)), key=len)
        return hits[0] if hits and (len(hits) == 1 or len(hits[0]) < len(hits[1])) else k

    def resolve(x):
        """As resolve_, but a scenario that 'goes to' an HTTP call ends in the reply to the caller (the call is a step)."""
        k = resolve_(x)
        return "reply" if k in calls else k
    err = next((k for k, o in outputs.items() if re.search(r"error", f"{o['on_path']} {o['name']} {o['destination']}", re.I)), None)
    for e in r.get("errors") or []:
        if err:
            break
        g = e.get("goes_to") or ""
        err = next((k for a, k in alias.items() if a and a in slug(g)), None)
    if err in calls:
        err = "reply"
    if err is None:
        outputs["error"] = {"name": "error", "destination": "", "on_path": "error handler", "headers": [], "backend": None}
        err = "error"
    # a JMS business service that writes an output IS that output (one send, not two): keep only the other backends
    out_dests = {o["destination"] for o in outputs.values() if o["destination"]}
    backends = {slug(clean(b.get("name"))): {**b, "name": clean(b.get("name"))} for b in raw_backends
                if slug(clean(b.get("name"))) not in outputs and slug(clean(b.get("name"))) not in alias
                and not (clean(b.get("operation")) in out_dests or clean(b.get("destination")) in out_dests)}
    backends = {**calls, **backends}
    paths = []
    for b in r.get("branches") or []:
        for p in b.get("paths") or []:
            paths.append({"branch": slug(b.get("name")), "id": f"branch-{slug(b.get('name'))}-{slug(p.get('label'))}",
                          "label": p.get("label", ""), "plain": p.get("condition_plain", ""), "expr": p.get("condition_expr", ""),
                          "outputs": [resolve(x) for x in p.get("outputs") or [] if resolve(x) in outputs]})
    alias = {re.split(r"[./:]", d.strip().lstrip("/"))[-1]: dim_name(d) for d in r.get("scenario_dims") or [] if d}
    mapping = []
    for x in r.get("scenario_mapping") or []:
        outs = x.get("outputs") if isinstance(x.get("outputs"), list) else [x.get("output")]
        outs = list(dict.fromkeys(resolve(o) for o in outs if o and str(o).lower() not in ("none", "-")))
        sc = x.get("scenario", "")
        # keys as the Splunk step labels the cases: last path segment ("data.hasX" / "body:data.hasX" -> "hasX")
        sc = "|".join(re.sub(r"^([^=!]+)(!?=)", lambda g: alias.get(dim_name(g.group(1)), dim_name(g.group(1))) + g.group(2), p_.strip()) for p_ in sc.split("|")) if "=" in sc else sc
        mapping.append({"scenario": sc if "=" in sc else "*", "outputs": outs, "branch": x.get("branch", ""), "path": x.get("path", "")})
    mapping = [{**x, "scenario": other_row(x["scenario"], mapping)} for x in mapping]
    dims = [(dim_name(d), d) for d in r.get("scenario_dims") or [] if d]
    fmt = ((r.get("entry") or {}).get("payload_format") or "UNKNOWN").lower()
    hdr_src = json.dumps({"o": [o.get("headers") for o in r.get("outputs") or []], "e": r.get("errors")}).lower()
    return {"outputs": outputs, "error": err, "backends": backends, "paths": paths, "mapping": mapping, "dims": dims,
            "format": fmt, "corr": corr, "logs": r.get("logs") or [], "transforms": r.get("transforms") or [],
            "branches": r.get("branches") or [], "entry": r.get("entry") or {}, "errors": r.get("errors") or [],
            "corr_generated": "uuid" in hdr_src,                       # OSB: traceId = inbound header, else fn-bea:uuid()
            "selector": str((r.get("entry") or {}).get("selector") or "").strip(),
            "calls": sorted(calls), "http_entry": str(entry.get("transport") or "").lower().startswith("http"),
            "error_status": error_status(r.get("errors") or []) if err == "reply" else None}


def error_status(errors: list) -> int | None:
    """The HTTP status OSB answers with on an error, when research names one ('... else default 500')."""
    m = re.search(r"\b([45]\d\d)\b", json.dumps(errors))
    return int(m.group(1)) if m else None


def route_yaml(proxy: str, project: str, pkg: str, m: dict) -> str:
    L = [f"# Camel K route (YAML DSL) for OSB project {project}, proxy {proxy}.",
         "# GENERATED SKELETON from the research pack (osb-camelk-route). The implementer fills every gap marked TODO",
         "# using FLOW_CARD.md; ids branch-*, out-*, backend-* must stay (check_camelk.py and the tests rely on them).",
         "# Endpoints are properties: production values in application.properties (Camel K: traits.camel.properties),",
         "# tests replace them with direct:/mock: endpoints.",
         "- route:", f"    id: {proxy}", "    from:", '      uri: "{{flow.input}}"', "      steps:"]
    if m.get("corr_generated"):
        L += [f"        # OSB: {m['corr']} = inbound header, else fn-bea:uuid()", "        - setHeader:", f"            name: {m['corr']}",
              f"            simple: \"${{header.{m['corr']}}} ?: ${{uuid(random)}}\""]
    L += ["        - doTry:", "            steps:"]
    ind = " " * 14
    stages = [lg.get("stage") for lg in m["logs"] if lg.get("stage") and not re.search(r"error", lg.get("stage"), re.I)]
    L += [f"{ind}# osbStage = the OSB stage being executed: set it again before the steps of every further stage (names in",
          f"{ind}# FLOW_CARD section 8). The error handler reports it as debugInfo (OSB: $fault/location/stage).",
          f"{ind}- setProperty:", f"{ind}    name: osbStage", f"{ind}    constant: {q(stages[0] if stages else 'request-pipeline')}"]
    if m["format"] == "json":
        L += [f"{ind}- bean:", f"{ind}    beanType: {pkg}.OsbJson", f"{ind}    method: annotate"]
    main_logs = [lg for lg in m["logs"] if not re.search(r"error", lg.get("stage") or "", re.I)]
    err_logs = [lg for lg in m["logs"] if lg not in main_logs]
    for lg in main_logs:
        L += [f"{ind}- log:", f"{ind}    loggingLevel: {(lg.get('level') or 'INFO').upper() if (lg.get('level') or '').upper() in ('INFO', 'DEBUG', 'WARN', 'ERROR', 'TRACE') else 'INFO'}",
              f"{ind}    logName: oracle.osb.logging.pipeline",
              f"{ind}    message: {q(TODO + ' convert to simple: ' + (lg.get('template') or ''))}"]
    L.append(f"{ind}# --- BEGIN flow logic (from the approved FLOW_CARD.md) ---")
    for t in m["transforms"]:
        L.append(f"{ind}# transform {t.get('name')}: {t.get('purpose', '')} -> keep the original file, see FLOW_CARD.md")
    for k, b in m["backends"].items():
        if k in m.get("calls", []):
            continue
        L.append(f"{ind}# place: - to: {{id: backend-{k}, uri: \"{{{{backend.{k}}}}}\"}}   ({b.get('type', '')} {b.get('operation', '')}; "
                 f"called when: {b.get('called_when', '')})")
    for k in m.get("calls", []):        # request/reply: the HTTP call in place, the agent fills request and response mapping
        b = m["backends"][k]
        method = (re.search(r"(?i)\b(GET|POST|PUT|DELETE|PATCH)\b", f"{b.get('request_from', '')} {b.get('operation', '')}") or [None, "POST"])[1].upper()
        L += [f"{ind}# HTTP call {b.get('name')}: {b.get('type', '')} {b.get('operation', '')}",
              f"{ind}#   request from: {b.get('request_from') or b.get('body_from') or '-'}",
              f"{ind}#   headers: " + (", ".join(f"{h.get('name')} <- {h.get('source')}" for h in b.get("headers") or [] if isinstance(h, dict)) or "-"),
              f"{ind}# Secrets and per-environment values (API keys, DVM lookups) come from properties/env, never literals.",
              f"{ind}- setProperty:", f"{ind}    name: osbStage", f"{ind}    constant: {q('call ' + str(b.get('name')))}",
              f"{ind}- setHeader:", f"{ind}    name: CamelHttpMethod", f"{ind}    constant: {q(TODO + ' ' + method + ' unless the pipeline overrides it (FLOW_CARD section 7)')}",
              f"{ind}- setHeader:", f"{ind}    name: CamelHttpQuery", f"{ind}    simple: {q(TODO + ' query string, or remove this step')}",
              f"{ind}# {TODO} request headers and body for {b.get('name')} (see the list above)",
              f"{ind}- to:", f"{ind}    id: backend-{k}", f'{ind}    uri: "{{{{backend.{k}}}}}"',
              f"{ind}# {TODO} build the reply from the answer of {b.get('name')}: research.json transforms (field by field)"]
    by_branch = {}
    for p in m["paths"]:
        by_branch.setdefault(p["branch"], []).append(p)
    placed = set()
    for b, ps in by_branch.items():
        for p in ps:
            if not p["outputs"]:
                L.append(f"{ind}# path {p['id']} ({p['plain'] or p['label']}): no output in OSB = no action, so no `when` and no log for it")
        active = [p for p in ps if p["outputs"]]
        if not active:
            continue
        L += [f"{ind}- choice:", f"{ind}    id: branch-{b}", f"{ind}    when:"]
        for p in active:
            L += [f"{ind}      - id: {p['id']}", f"{ind}        simple: {q(TODO + ' ' + (p['plain'] or p['label']) + ' (fields set by OsbJson.annotate: ${exchangeProperty.<field>}, never headers)')}",
                  f"{ind}        steps:"]
            for o in p["outputs"]:
                if o == "reply":
                    L += [f"{ind}          - log:", f"{ind}              message: {q(TODO + ' build the reply to the caller here (body at the end of the route)')}"]
                    placed.add(o)
                    continue
                L += [f"{ind}          - to:", f"{ind}              id: out-{o}", f'{ind}              uri: "{{{{out.{o}}}}}"']
                placed.add(o)
    rest = [o for o in m["outputs"] if o not in placed and o not in (m["error"], "reply")]
    if rest and not by_branch:
        for o in rest:
            L += [f"{ind}- to:", f"{ind}    id: out-{o}", f'{ind}    uri: "{{{{out.{o}}}}}"']
    elif rest:
        L.append(f"{ind}# {TODO} outputs not on any branch path in research.json, place them: " + ", ".join(f"out-{o}" for o in rest))
    L += [f"{ind}# --- END flow logic ---", "            doCatch:", "              - exception:", "                  - java.lang.Exception",
          "                steps:"]
    for lg in err_logs:
        L += ["                  - log:", "                      loggingLevel: INFO", "                      logName: oracle.osb.logging.pipeline",
              f"                      message: {q(TODO + ' convert to simple: ' + (lg.get('template') or ''))}"]
    L += error_header_steps(m)
    if m["error"] == "reply":           # OSB replies to the caller with the error: no queue, the body is the answer
        if m.get("error_status"):
            L += ["                  - setHeader:", "                      name: CamelHttpResponseCode",
                  f"                      constant: {m['error_status']}"]
        L += [f"                  # {TODO} error reply body as OSB builds it (FLOW_CARD section 9), or remove this line"]
    else:
        L += ["                  - to:", f"                      id: out-{m['error']}", f'                      uri: "{{{{out.{m["error"]}}}}}"']
    if "reply" in m["outputs"]:
        L.append("# The body at the end of the route is the reply to the caller (request/reply).")
    return "\n".join(L) + "\n"


def error_header_steps(m: dict) -> list[str]:
    """Headers OSB sets on the error message (research: error output headers / errors[].headers), as route steps.
    errorCode: OSB fault codes have no Camel equivalent -> exception class name (FLOW_CARD open question for the readers
    of the error queue). debugInfo: the osbStage property. Inbound headers travel with the message and are not re-set."""
    ind = " " * 18
    names: list[tuple[str, str]] = []
    for h in (m["outputs"].get(m["error"]) or {}).get("headers") or []:
        n = h.get("name") if isinstance(h, dict) else str(h)
        if n and n not in [x for x, _ in names]:
            names.append((n, (h.get("source") if isinstance(h, dict) else "") or ""))
    for e in m.get("errors") or []:
        for h in e.get("headers") or []:
            n = h.get("name") if isinstance(h, dict) else str(h)
            if n and n not in [x for x, _ in names]:
                names.append((n, (h.get("source") if isinstance(h, dict) else "") or ""))
    if not names:
        names = [("errorCode", "$fault errorCode"), ("errorMessage", "$fault reason"), ("debugInfo", "$fault location stage")]
    L = []
    for n, src in names:
        if not re.fullmatch(r"[A-Za-z][\w.-]*", n):     # research wrote a sentence, not a header name: keep it as a note
            if re.search(r"(?i)http.*(response|status).*code|status code", n):
                L.append(f"{ind}# OSB: {n} (set as CamelHttpResponseCode below when research names the status)")
            else:
                L.append(f"{ind}# {TODO} OSB error header described as: {n}")
            continue
        if n == m["corr"]:
            L.append(f"{ind}# {n}: already on the message (set at the start of the route)")
        elif "inbound" in src.lower():
            L.append(f"{ind}# {n}: inbound header ({src}), travels with the message: not re-set")
        elif n.lower() == "errorcode":
            L += [f"{ind}# OSB {src or '$fault errorCode'} (BEA-xxxxxx) has no Camel equivalent: exception class name, see FLOW_CARD",
                  f"{ind}- setHeader:", f"{ind}    name: {n}", f'{ind}    simple: "${{exception.class.simpleName}}"']
        elif n.lower() == "errormessage":
            L += [f"{ind}- setHeader:", f"{ind}    name: {n}", f'{ind}    simple: "${{exception.message}}"']
        elif n.lower() == "debuginfo":
            L += [f"{ind}# OSB {src or '$fault location stage'}: the osbStage property set along the route",
                  f"{ind}- setHeader:", f"{ind}    name: {n}", f'{ind}    simple: "${{exchangeProperty.osbStage}}"']
        else:
            L += [f"{ind}- setHeader:", f"{ind}    name: {n}", f"{ind}    constant: {q(TODO + ' ' + n + ' <- ' + (src or 'see FLOW_CARD section 7'))}"]
    return L


def properties(proxy: str, m: dict) -> str:
    e = m["entry"]
    dest, sub = clean(e.get("destination")), clean(e.get("durable_subscription"))
    if sub.lower() in ("true", "yes"):
        sub = proxy                      # OSB names the subscription itself; on Artemis the subscription queue is ours to name
    name = re.sub(r"^(jms|amqp|queue|topic):", "", dest)
    if m.get("http_entry"):             # OSB HTTP proxy = an HTTP endpoint of the integration (Camel K exposes it)
        path = http_path("http " + str(e.get("destination") or "")) or (dest if dest.startswith("/") else "")
        inp = f"platform-http:{path}" if path else f"{TODO} HTTP path of the proxy"
    elif not name or name.upper() == "UNKNOWN":
        inp = f"{TODO} entry destination"
    elif e.get("is_topic") and sub:
        inp = f"amqp:queue:{name}::{sub}"
    elif e.get("is_topic"):
        inp = f"{TODO} topic {name} without a durable subscription name"
    else:
        inp = f"amqp:queue:{name}"
    L = ["# Production endpoints (Camel K: spec.traits.camel.properties or a mounted config). No hosts, ports or",
         "# credentials here: HTTP hosts come from env, broker connection from the platform config.",
         "# Durable topic subscription = subscription queue consumed by FQQN <address>::<subscription> (AGENTS.md).",
         f"camel.main.name={proxy}", "camel.main.routes-include-pattern=classpath:routes/*.camel.yaml", f"flow.input={inp}"]
    if m.get("selector"):
        L += ["# OSB message selector = broker-side filter of the subscription queue (the platform register creates it with this filter)",
              f"flow.input.selector={m['selector']}"]
    L += [f"out.{k}={endpoint(o['destination'], k)}" for k, o in m["outputs"].items() if k != "reply"]
    L += [f"backend.{k}={endpoint(b.get('operation') if (b.get('type') or '').lower().startswith('http') else b.get('name'), k)}"
          for k, b in m["backends"].items()]
    if uses_broker(L):
        L += BROKER_LINES
    return "\n".join(L) + "\n"


def uses_broker(lines: list) -> bool:
    """Broker lines only when an endpoint is a queue/topic: an HTTP-only flow must not need BROKER_URL to start."""
    return any(re.search(r"=amqp:", x) for x in lines)


# the broker connection comes from the platform environment (Secret / ConfigMap) on every environment, and from
# ARTEMIS_* via broker/run_local.sh on a developer machine: never a value in this file (gate K4)
BROKER_LINES = ["# broker connection (AMQP 1.0, Qpid JMS): the environment of the pod provides BROKER_URL (e.g. failover:(amqp://a:5672,",
                "# amqp://b:5672)), BROKER_USER and BROKER_PASSWORD (Secret); broker/run_local.sh sets them for a local Artemis.",
                "# The L1 tests override the URL with a dummy (no connection is opened). Never a value here.",
                "camel.beans.amqpConnectionFactory=#class:org.apache.qpid.jms.JmsConnectionFactory",
                "camel.beans.amqpConnectionFactory.remoteURI={{env:BROKER_URL}}",
                "camel.beans.amqpConnectionFactory.username={{env:BROKER_USER:}}",
                "camel.beans.amqpConnectionFactory.password={{env:BROKER_PASSWORD:}}",
                "camel.component.amqp.connectionFactory=#bean:amqpConnectionFactory"]
TEST_BROKER_LINES = ["camel.beans.amqpConnectionFactory.remoteURI=amqp://localhost:5672"]   # parsed only, never connected


def local_properties(proxy: str, m: dict) -> str:
    """env/local.properties: the same keys against an Artemis broker on this machine (broker/LOCAL_BROKER_TEST.md).
    ASSUMPTION: local address = JNDI name without the 'jndi.' prefix; the real mapping per environment is the platform's."""
    strip = lambda v: re.sub(r"^(amqp:(queue|topic):)jndi\.", r"\1", v)  # noqa: E731
    prod = dict(ln.split("=", 1) for ln in properties(proxy, m).splitlines() if ln and not ln.startswith("#") and "=" in ln)
    L = ["# LOCAL run against an Artemis broker on this machine: broker/run_local.sh passes every line below as -D, so it",
         "# overrides the endpoints of application.properties; the connection comes from BROKER_* (set by the script from",
         "# ARTEMIS_*, the password never in a file). Not read by the L1 tests. ASSUMPTION: local address = JNDI name",
         "# without the 'jndi.' prefix; the mapping JNDI name -> Artemis address per environment belongs to the platform."]
    L += [f"{k}={strip(v) if k == 'flow.input' or k.startswith(('out.', 'backend.')) else v}" for k, v in prod.items()
          if k == "flow.input" or k.startswith(("flow.input.", "out.", "backend."))]
    return "\n".join(L) + "\n"


def test_props(m: dict) -> list[str]:
    prod = properties("x", m).splitlines()
    return (["flow.input=direct:in"] + [f"out.{k}=mock:out-{k}" for k in m["outputs"] if k != "reply"]
            + [f"backend.{k}=mock:backend-{k}" for k in m["backends"]] + (TEST_BROKER_LINES if uses_broker(prod) else []))


UUID_RX = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
TIME_RX = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}")


GEN_NAME_RX = re.compile(r"(?i)(uuid|guid|timestamp|date|time)$")   # time/id fields OSB stamps (fn:current-dateTime, uuid)


def generated_fields(parity: Path) -> list[str]:
    """Fields of OSB's logged output that OSB generated itself: in every case whose expected-output.json has the field, the
    value is a UUID, an ISO timestamp, an epoch-millis number or the field is named *uuid/*date/*time/*timestamp, and the
    value appears nowhere in that case's input. No route can
    reproduce such a value; the parity test checks the field is present instead of its value."""
    dec = json.JSONDecoder(strict=False)
    load = lambda p: dec.raw_decode(p.read_text(encoding="utf-8").strip())[0]  # noqa: E731

    def flat(x, p=""):
        if isinstance(x, dict):
            for k, v in x.items():
                yield from flat(v, f"{p}.{k}" if p else k)
        else:
            yield p, x
    counts, seen = {}, {}
    for exp in parity.rglob("expected-output.json"):
        inp = exp.parent / "input.payload"
        if not inp.is_file():
            continue
        try:
            out, raw_in = dict(flat(load(exp))), inp.read_text(encoding="utf-8")
        except ValueError:
            continue
        for k, v in out.items():
            if v is None or isinstance(v, (bool, list)):
                continue
            sv = str(v)
            seen[k] = seen.get(k, 0) + 1
            looks = UUID_RX.match(sv) or TIME_RX.match(sv) or (isinstance(v, int) and v > 10**12) or GEN_NAME_RX.search(k.split(".")[-1])
            if looks and sv not in raw_in:
                counts[k] = counts.get(k, 0) + 1
    # generated wherever it appears (a message without the field is checked by the test: absent there too)
    return sorted(k for k, c in counts.items() if c == seen[k])


def unmapped_scenarios(m: dict, facts: dict) -> list[str]:
    keys = [x["scenario"] for x in m["mapping"] if x["scenario"]]
    return [s.get("scenario", "") for s in facts.get("log_scenarios") or [] if not any(matches(k, s.get("scenario", "")) for k in keys)]


def parts(scenario: str) -> dict:
    return dict(p.split("=", 1) for p in scenario.split("|") if "=" in p and "!=" not in p)


def matches(key: str, scenario: str) -> bool:
    """Same rule as FlowParityTest: every k=v of the key equals the scenario's value, every k!=v differs (missing counts as different)."""
    sc = parts(scenario)
    for p in key.split("|"):
        if "!=" in p:
            k, v = p.split("!=", 1)
            if sc.get(k) == v:
                return False
        elif "=" in p:
            k, v = p.split("=", 1)
            if sc.get(k) != v:
                return False
    return True


def card(proxy: str, project: str, r: dict, facts: dict, m: dict, rsha: str) -> str:
    counts = {s.get("scenario"): s.get("count") for s in facts.get("log_scenarios") or []}
    unmapped = unmapped_scenarios(m, facts)
    row = lambda *c: "| " + " | ".join(str(x if x not in (None, "") else "-").replace("|", "/").replace("\n", " ") for x in c) + " |"  # noqa: E731
    L = [f"# Flow card: {project} / {proxy}", "",
         f"Source: research pack `research.json` sha256 {rsha[:16]} (no OSB code in this card).",
         "Status: draft", "Approver: ", "Date: ", "",
         "Approve by setting `Status: approved`, your name and the date, after checking every table against RESEARCH.md",
         "and resolving or accepting each open question. The implementer does not start before that.", "",
         "## 1 Entry", "", "| Item | Value |", "|---|---|"]
    L += [row(k, v) for k, v in m["entry"].items()]
    L += ["", "## 2 Branches (route ids)", "", "| Route id | Condition (plain) | Condition (OSB) | Outputs |", "|---|---|---|---|"]
    L += [row(p["id"], p["plain"], p["expr"], ", ".join("out-" + o for o in p["outputs"])) for p in m["paths"]] or ["| none | | | |"]
    L += ["", "## 3 Scenario mapping (from the logs → tests)", "", "| Scenario | Messages in export | Branch / path | Output |", "|---|---|---|---|"]
    L += [row(x["scenario"], sum(v or 0 for s, v in counts.items() if matches(x["scenario"], s)),
              f"{x['branch']} / {x['path']}", ", ".join("out-" + o for o in x["outputs"]) or "none") for x in m["mapping"]]
    if unmapped:
        L += ["", f"**{len(unmapped)} log scenario(s) without a mapping** (their parity tests fail until research.json maps them):"]
        L += [f"- {s}" for s in unmapped]
    L += ["", "## 4 Outputs", "", "| Route id | Name | Destination | Property | Headers |", "|---|---|---|---|---|"]
    L += [row("out-" + k, o["name"], o["destination"], f"out.{k}", ", ".join(f"{h.get('name')}←{h.get('source')}" for h in o["headers"]))
          for k, o in m["outputs"].items()]
    L += ["", f"Error output: `out-{m['error']}`.", "", "## 5 Backends (L1: mock endpoints with stubs)", "",
          "| Route id | Type | Operation | Called when | Response use | Retry | Timeout | On fault |", "|---|---|---|---|---|---|---|---|"]
    L += [row("backend-" + k, b.get("type"), b.get("operation"), b.get("called_when"), b.get("response_use"), b.get("retry"),
              b.get("timeout"), b.get("on_fault")) for k, b in m["backends"].items()] or ["| none | | | | | | | |"]
    L += ["", "## 6 Transforms (original files kept, run by camel-saxon / camel-xslt-saxon)", "",
          "| Name | Purpose | fn-bea functions | Mappings in research |", "|---|---|---|---|"]
    L += [row(t.get("name"), t.get("purpose"), ", ".join(t.get("fn_bea") or []), len(t.get("mappings") or [])) for t in m["transforms"]] or ["| none | | | |"]
    L += ["", "## 7 Errors (one test each in FlowErrorTest)", "", "| Scope | Catches | Goes to | Headers | Redelivery |", "|---|---|---|---|---|"]
    L += [row(e.get("scope"), e.get("catches"), e.get("goes_to"), ", ".join(e.get("headers") or []), e.get("redelivery")) for e in r.get("errors") or []] or ["| none | | | | |"]
    L += ["", "## 8 Log lines (same text as OSB, logName oracle.osb.logging.pipeline)", "", "| Stage | Level | Template |", "|---|---|---|"]
    L += [row(x.get("stage"), x.get("level"), x.get("template")) for x in m["logs"]] or ["| none | | |"]
    L += ["", "## 9 Open questions (each: answered, or accepted with a reason, before approval)", ""]
    L += [f"- [ ] {x}" for x in r.get("open_questions") or []] or ["- none"]
    return "\n".join(L) + "\n"


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def write_once(p: Path, text: str, force: bool) -> bool:
    if p.exists() and not force:
        return False
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("research", type=Path)
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--parity", type=Path, help="task1/fixtures/parity (masked cases; copied, never committed)")
    ap.add_argument("--correlation-header", default="traceId")
    ap.add_argument("--force", action="store_true", help="also overwrite route, properties and card")
    ap.add_argument("--refresh", default="", help="comma list of generated infrastructure files to overwrite: pom,env,gitignore,bean")
    ap.add_argument("--freeze-synthetic", action="store_true",
                    help="only record hashes of the tester's synthetic cases (parity/*-synthetic/**) so gate K5 protects them")
    a = ap.parse_args()
    if a.freeze_synthetic:
        moved = []
        # a case folder sits BELOW its scenario folder (SCENARIO.txt); move cases written next to SCENARIO.txt into case1/
        for scen in (a.out / "src/test/resources/parity").glob("*-synthetic/**/SCENARIO.txt"):
            loose = [p for p in scen.parent.iterdir() if p.is_file() and p.name != "SCENARIO.txt"]
            if any(p.name == "input.payload" for p in loose):
                case = scen.parent / "case1"
                case.mkdir(exist_ok=True)
                for p in loose:
                    p.rename(case / p.name)
                    moved.append(p.relative_to(a.out).as_posix())
        meta = json.loads((a.out / ".scaffold.json").read_text(encoding="utf-8"))
        for k in moved:                     # a hash frozen at the old place moves with the file (it was not edited)
            if k in meta["generated"]:
                meta["generated"][k.rsplit("/", 1)[0] + "/case1/" + k.rsplit("/", 1)[1]] = meta["generated"].pop(k)
        syn = sorted(p for p in (a.out / "src/test/resources/parity").glob("*-synthetic/**/*") if p.is_file())
        syn += sorted(p for p in (a.out / "src/test/resources/stubs").glob("*") if p.suffix in (".json", ".xml", ".txt"))
        for p in syn:                       # first freeze wins: a later change shows up in gate K5, it is never re-blessed
            meta["generated"].setdefault(p.relative_to(a.out).as_posix(), sha(p))
        (a.out / ".scaffold.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"frozen_synthetic_files": len(syn)}))
        return 0
    rp = a.research / "research.json"
    if not rp.is_file():
        sys.exit(f"missing {rp}: run pi/run_research.sh first")
    r = json.loads(rp.read_text(encoding="utf-8"))
    fp = a.research / "facts.json"
    facts = json.loads(fp.read_text(encoding="utf-8")) if fp.is_file() else {}
    proxy = r.get("proxy") or a.research.name
    pkg = java_pkg(a.project, proxy)
    m = model(r, facts, a.correlation_header)
    o = a.out
    deps = []
    kinds = " ".join((t.get("name") or "") + " " + (t.get("purpose") or "") for t in m["transforms"]).lower()
    ref_kinds = " ".join((t.get("ref") or "") + " " + (t.get("kind") or "") for t in facts.get("transforms") or []).lower()
    if "xq" in ref_kinds or "xquery" in kinds:
        deps.append("camel-saxon")
    if "xsl" in ref_kinds or "xslt" in kinds:
        deps.append("camel-xslt-saxon")
    if m.get("http_entry"):
        deps.append("camel-platform-http-main")     # the proxy's HTTP endpoint (Camel Main / Camel K)
    if m.get("calls"):
        deps.append("camel-http")                   # HTTP business services
    pom = (TPL / "pom.xml").read_text(encoding="utf-8").replace("@@GROUP@@", "osb." + slug(a.project)).replace(
        "@@ARTIFACT@@", slug(proxy)).replace("@@PROJECT@@", a.project).replace("@@PROXY@@", proxy).replace(
        "<!-- @@EXTRA_DEPS@@ -->", "\n    ".join(f"<dependency><groupId>org.apache.camel</groupId><artifactId>{d}</artifactId></dependency>"
                                            for d in deps) or "<!-- no transform dependencies -->")
    written = []
    jdir = pkg.replace(".", "/")
    refresh = {x.strip() for x in a.refresh.split(",") if x.strip()}
    for path, text, key in [
        (o / "pom.xml", pom, "pom"),
        (o / f"src/main/resources/routes/{proxy}.camel.yaml", route_yaml(proxy, a.project, pkg, m), "route"),
        (o / "src/main/resources/application.properties", properties(proxy, m), "properties"),
        (o / "env/local.properties", local_properties(proxy, m), "env"),
        (o / "FLOW_CARD.md", card(proxy, a.project, r, facts, m, sha(rp)), "card"),
        (o / ".gitignore", "target/\nsrc/test/resources/parity/\n.camel-jbang/\n", "gitignore"),
    ]:
        if write_once(path, text, a.force or key in refresh):
            written.append(path.relative_to(o).as_posix())
    if m["format"] == "json":
        bean = (TPL / "OsbJson.java.tpl").read_text(encoding="utf-8").replace("@@PACKAGE@@", pkg).replace(
            "@@HEADER_PATHS@@", ", ".join("{" + q(h) + ", " + q(p) + "}" for h, p in m["dims"] if not h.startswith("hdr_")))   # headers are not payload paths
        if write_once(o / f"src/main/java/{jdir}/OsbJson.java", bean, a.force or "bean" in refresh):
            written.append(f"src/main/java/{jdir}/OsbJson.java")
    test = (TPL / "FlowParityTest.java.tpl").read_text(encoding="utf-8").replace("@@PACKAGE@@", pkg).replace(
        "@@PROJECT@@", a.project).replace("@@PROXY@@", proxy).replace("@@INPUT@@", "direct:in").replace(
        "@@PATTERN@@", "InOut" if "reply" in m["outputs"] else "InOnly").replace(
        "@@TEST_PROPERTIES@@", ", ".join(q(p) for p in test_props(m)))
    cfg = {"outputs": {k: ("reply" if k == "reply" else f"mock:out-{k}") for k in m["outputs"]}, "error_output": m["error"],
           "backends": {k: {"mock": f"mock:backend-{k}", "response_use": b.get("response_use", "")} for k, b in m["backends"].items()},
           "scenario_mapping": [{"scenario": x["scenario"], "outputs": x["outputs"]} for x in m["mapping"]],
           "correlation_header": m["corr"], "correlation_generated": bool(m.get("corr_generated")),
           "scenario_fields": [h for h, _ in m["dims"]], "payload_format": m["format"],
           "generated_fields": generated_fields(o / "src/test/resources/parity") if (o / "src/test/resources/parity").is_dir() else []}
    if m.get("error_status"):           # request/reply: the HTTP status of OSB's error answer (FlowErrorTest checks it)
        cfg["error_http_status"] = m["error_status"]
    tp = o / f"src/test/java/{jdir}/FlowParityTest.java"
    cp = o / "src/test/resources/flow-test.json"
    for path, text in [(tp, test), (cp, json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")]:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        written.append(path.relative_to(o).as_posix())
    # FlowErrorTest: a compiling start with one test per error scope; the implementer extends it (not frozen, gate K7)
    etp = o / f"src/test/java/{jdir}/FlowErrorTest.java"
    err_tpl = (TPL / "FlowErrorTest.java.tpl").read_text(encoding="utf-8").replace("@@PACKAGE@@", pkg).replace(
        "@@PROJECT@@", a.project).replace("@@PROXY@@", proxy).replace("@@TEST_PROPERTIES@@", ", ".join(q(p) for p in test_props(m)))
    if write_once(etp, err_tpl, False):
        written.append(etp.relative_to(o).as_posix())
    stubs = ["# Backend stubs for the L1 tests", "","One file per backend, named <backend>.json / .xml / .txt: the response shape from",
             "research Q8 (WSDL/XSD), with FAKE values only. FlowErrorTest makes the same mocks throw for the error tests.", ""]
    stubs += [f"- `{k}.*`: {b.get('type', '')} {b.get('operation', '')}; response use: {b.get('response_use', '') or '-'}" for k, b in m["backends"].items()] or ["- no backends"]
    write_once(o / "src/test/resources/stubs/README.md", "\n".join(stubs) + "\n", True)
    # tests log at WARN: the Camel INFO lines of every test made each mvn run hundreds of KB (full log: target/)
    write_once(o / "src/test/resources/simplelogger.properties", "org.slf4j.simpleLogger.defaultLogLevel=warn\n", False)
    copied = 0
    if a.parity and a.parity.is_dir():
        dst = o / "src/test/resources/parity"
        for flow_dir in a.parity.iterdir():
            if flow_dir.is_dir():
                shutil.copytree(flow_dir, dst / flow_dir.name, dirs_exist_ok=True)
                copied += sum(1 for _ in (dst / flow_dir.name).glob("*/*/input.payload"))
    old_meta = json.loads((o / ".scaffold.json").read_text(encoding="utf-8")) if (o / ".scaffold.json").is_file() else {}
    active = [p for p in m["paths"] if p["outputs"]]              # a path without output is no action: no id in the route
    ids = ([f"branch-{b}" for b in {p["branch"] for p in active}] + [p["id"] for p in active]
           + [f"out-{k}" for k in m["outputs"] if k != "reply"] + [f"backend-{k}" for k in m["backends"]])
    meta = {"proxy": proxy, "project": a.project, "package": pkg, "research_sha256": sha(rp),
            "generated": {**{k: v for k, v in (old_meta.get("generated") or {}).items() if "-synthetic/" in k or "/stubs/" in k},
                          tp.relative_to(o).as_posix(): sha(tp), cp.relative_to(o).as_posix(): sha(cp)},
            "route_ids": sorted(ids), "errors": len(r.get("errors") or []),
            "task1": str(a.parity.parent.parent.resolve()) if a.parity and a.parity.is_dir() else (old_meta.get("task1") or ""),
            "backends_with_response": [k for k, b in m["backends"].items()
                                       if (b.get("response_use") or "").strip().lower() not in ("", "none", "ignored", "not used", "-")]}
    (o / ".scaffold.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"proxy": proxy, "module": str(o), "written": len(written), "parity_cases": copied,
                      "branches": len(m["paths"]), "outputs": len(m["outputs"]), "backends": len(m["backends"]),
                      "unmapped_log_scenarios": len(unmapped_scenarios(m, facts))}))
    unknown = sorted({x for row in m["mapping"] for x in row["outputs"] if x not in m["outputs"]})
    if unknown:                     # a table output that is no output: every case of that row would expect nothing
        print(json.dumps({"WARNING_unknown_outputs_in_scenario_mapping": unknown, "known": sorted(m["outputs"])}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_SCAFFOLD_CAMELK_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/synth_from_schema.py")"
cat > '.pi/skills/osb-camelk-route/scripts/synth_from_schema.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_SYNTH_FROM_SCHEMA_PY'
#!/usr/bin/env python3
"""Synthetic test messages WITHOUT an AI: one case per uncovered scenario, built from the flow's schema. Stdlib only.

    synth_from_schema.py <module> <osb-project-dir> [--research research/<p>/<x>/research.json] [--schema file.xsd]

For every scenario_mapping row of <module>/src/test/resources/flow-test.json that has no case yet:
  - message structure from the schema: the nXSD named in the research pack (entry.nxsd) or the --schema given, else
    the XSD in the project whose global element is used; nXSD with nxsd:version="JSON" -> a JSON message (the global
    element is the JSON object itself), otherwise XML
  - every field gets a FAKE value by type (string "masked_fake", numbers 1, booleans false, dates 2026-01-01)
  - the scenario fields get exactly the row's values (k=v), or a different value for k!=v (true -> false, else "other")
  - a row whose only output is the error output gets a deliberately unreadable message
Writes parity/<project>-<proxy>-synthetic/<row>/case1/{input.payload, headers.json, expected.json} + SCENARIO.txt,
the same layout as the pi tester. Rows it cannot build (no schema, field not in the schema) are listed for pi.
Fake values only, no data. Prints {"written": n, "left_for_pi": [...]}"""
import argparse
import json
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

XS = "{http://www.w3.org/2001/XMLSchema}"


def parts(key: str) -> list[tuple[str, str, str]]:
    out = []
    for p in key.split("|"):
        if "!=" in p:
            k, v = p.split("!=", 1)
            out.append((k, "!=", v))
        elif "=" in p:
            k, v = p.split("=", 1)
            out.append((k, "=", v))
    return out


def covered_keys(mod: Path) -> list[dict]:
    return [dict(p.split("=", 1) for p in sc.read_text(encoding="utf-8").strip().split("|") if "=" in p)
            for sc in (mod / "src/test/resources/parity").glob("*/*/SCENARIO.txt")]


def hit(key: str, v: dict) -> bool:
    for k, op, x in parts(key):
        if (op == "=" and v.get(k) != x) or (op == "!=" and v.get(k) == x):
            return False
    return True


class Schema:
    def __init__(self, path: Path):
        self.root = ET.parse(path).getroot()
        self.json = any(re.search(r"version$", k) and v.upper() == "JSON" for k, v in self.root.attrib.items())
        self.types = {t.get("name"): t for t in self.root.findall(XS + "complexType")}
        self.elems = {e.get("name"): e for e in self.root.findall(XS + "element")}

    def instance(self, el: ET.Element, depth: int = 0):
        if el.get("ref"):
            el = self.elems.get(el.get("ref").split(":")[-1], el)
        typ = (el.get("type") or "").split(":")[-1]
        ct = el.find(XS + "complexType")
        if ct is None:
            ct = self.types.get(typ)
        if ct is None or depth > 8:
            return self.leaf(typ)
        out = {}
        for child in self.children(ct):
            name = child.get("name") or (child.get("ref") or "").split(":")[-1]
            val = self.instance(child, depth + 1)
            out[name] = [val] if child.get("maxOccurs") not in (None, "1") else val
        return out

    def children(self, node: ET.Element) -> list:
        """Direct child elements of a complex type: through sequence/all/choice/complexContent/extension, not deeper."""
        out = []
        for c in node:
            if c.tag == XS + "element":
                out.append(c)
            elif c.tag in (XS + "sequence", XS + "all", XS + "choice", XS + "complexContent", XS + "extension", XS + "group"):
                out += self.children(c)
        return out

    @staticmethod
    def leaf(typ: str):
        t = typ.lower()
        if t in ("int", "integer", "long", "short", "decimal", "double", "float", "nonnegativeinteger", "positiveinteger"):
            return 1
        if t == "boolean":
            return False
        if t in ("date", "datetime"):
            return "2026-01-01" if t == "date" else "2026-01-01T00:00:00Z"
        return "masked_fake"


def set_path(obj, path: list[str], value) -> bool:
    for k in path[:-1]:
        if isinstance(obj, list):
            obj = obj[0]
        if not isinstance(obj, dict) or k not in obj:
            return False
        obj = obj[k]
    if isinstance(obj, list):
        obj = obj[0]
    if not isinstance(obj, dict) or path[-1] not in obj:
        return False
    obj[path[-1]] = value
    return True


def set_any(obj, name: str, value) -> bool:
    """//name: set the first field with that name at any depth (where OSB's //*:name would find it)."""
    if isinstance(obj, dict):
        if name in obj:
            obj[name] = value
            return True
        return any(set_any(v, name, value) for v in obj.values())
    if isinstance(obj, list):
        return any(set_any(v, name, value) for v in obj)
    return False


def to_xml(name: str, value) -> str:
    if isinstance(value, dict):
        return f"<{name}>" + "".join(to_xml(k, v) for k, v in value.items()) + f"</{name}>"
    if isinstance(value, list):
        return "".join(to_xml(name, v) for v in value)
    return f"<{name}>{str(value).lower() if isinstance(value, bool) else value}</{name}>"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("project", type=Path)
    ap.add_argument("--research", type=Path)
    ap.add_argument("--schema", type=Path)
    a = ap.parse_args()
    cfg = json.loads((a.module / "src/test/resources/flow-test.json").read_text(encoding="utf-8"))
    meta = json.loads((a.module / ".scaffold.json").read_text(encoding="utf-8"))
    res = json.loads(a.research.read_text(encoding="utf-8")) if a.research and a.research.is_file() else {}
    dims = {d.lstrip("/").split(".")[-1]: d.lstrip("/").split(".") for d in res.get("scenario_dims") or []}
    flow_dir = a.module / "src/test/resources/parity" / f"{meta['project']}-{meta['proxy']}-synthetic"
    rows = [m["scenario"] for m in cfg.get("scenario_mapping", [])]
    for sc in sorted(flow_dir.glob("*/SCENARIO.txt")) if flow_dir.is_dir() else []:
        v = dict(p.split("=", 1) for p in sc.read_text(encoding="utf-8").strip().split("|") if "=" in p)
        if v and not any(hit(r, v) for r in rows):        # written for a mapping that has changed since: stale
            shutil.rmtree(sc.parent)
            gone = sc.parent.relative_to(a.module).as_posix() + "/"
            meta["generated"] = {k: h for k, h in meta["generated"].items() if not k.startswith(gone)}   # unfreeze only these
            (a.module / ".scaffold.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
            print(json.dumps({"removed_stale_synthetic": sc.parent.name}))
    have = covered_keys(a.module)
    todo = [m for m in cfg.get("scenario_mapping", []) if not any(hit(m["scenario"], v) for v in have)]
    schema_file = a.schema
    if not schema_file:
        want = ((res.get("entry") or {}).get("nxsd") or "").split("/")[-1].lower()
        xsds = sorted(a.project.rglob("*.xsd"))
        schema_file = next((x for x in xsds if want and x.stem.lower().startswith(want)), None) or \
            next((x for x in xsds if "nxsd" in x.name.lower()), None)
    left, written = [], 0
    sch = None
    if schema_file and schema_file.is_file():
        try:
            sch = Schema(schema_file)
        except ET.ParseError:
            sch = None
    for i, row in enumerate(todo, 1):
        key, outs = row["scenario"], row.get("outputs") or []
        err_only = outs == [cfg.get("error_output")]
        if sch is None and not err_only:
            left.append(key)
            continue
        shown = {}
        if err_only:
            body = "{[[ deliberately unreadable message"
        else:
            root = next(iter(sch.elems.values()))
            msg = sch.instance(root)
            ok, shown = True, {}
            for k, op, v in parts(key):
                path = dims.get(k)
                if not path:
                    continue                                   # header dims (hdr_*) go to headers.json
                val = {"true": True, "false": False}.get(v, v) if op == "=" else (False if v == "true" else "other")
                shown[k] = str(val).lower() if isinstance(val, bool) else str(val)
                ok &= set_path(msg, path, val) or set_path(msg, path[1:], val) or set_any(msg, path[-1], val)
            if not ok:
                left.append(key)
                continue
            body = json.dumps(msg, indent=2) if sch.json else to_xml(root.get("name"), msg)
        slug = re.sub(r"[^a-z0-9]+", "-", key.lower().replace("!=", "-not-")).strip("-")[:70] or f"row{i}"
        case = flow_dir / slug / "case1"
        case.mkdir(parents=True, exist_ok=True)
        hdr = {k[4:]: v for k, op, v in parts(key) if k.startswith("hdr_") and op == "="}
        hdr["traceId"] = f"synthetic-{i:04d}"
        keys = "|".join(f"{k}={shown.get(k, v if op == '=' else 'other')}" for k, op, v in parts(key))
        (case.parent / "SCENARIO.txt").write_text(f"{meta['project']}/{meta['proxy']}|success" + (f"|{keys}" if keys else "") + "\n",
                                                  encoding="utf-8")
        (case / "input.payload").write_text(body + "\n", encoding="utf-8")
        (case / "headers.json").write_text(json.dumps(hdr, indent=2), encoding="utf-8")
        (case / "expected.json").write_text(json.dumps({"outcome": "success", "destination": "see mapping",
                                                         "correlation": hdr["traceId"]}, indent=2), encoding="utf-8")
        written += 1
    print(json.dumps({"schema": schema_file.name if schema_file else None, "written": written, "left_for_pi": left}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_SYNTH_FROM_SCHEMA_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/test_matrix.py")"
cat > '.pi/skills/osb-camelk-route/scripts/test_matrix.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_TEST_MATRIX_PY'
#!/usr/bin/env python3
"""Test matrix: what was tested, with which inputs, and the result, per flow and for a whole domain. Stdlib only.

    test_matrix.py modules/<project>/<proxy>            -> <module>/TEST_MATRIX.md + test-matrix.csv
    test_matrix.py --domain modules -o domain           -> domain/TEST_MATRIX.md + test-matrix.csv (one row per flow)

Per flow it joins: flow-test.json (expected outputs per scenario, from the research pack), the case folders
(SCENARIO.txt: which real masked messages were used), the surefire XML reports (display name "route <case>" /
"body <case>" per message), GATES.json (K1-K8) and MUTATION.json (route mutations the tests caught). Rows:
  P<n>  one per scenario seen in the logs: messages in the export, cases tested, expected outputs, passed/failed
  S<n>  one per scenario covered only by synthetic messages (flows that log no payload)
  E<n>  every other test method (error handler, retries, headers, invalid payload)
  K<n>  the gates;  M<n>  the mutations
No payload values are read or written: only folder names, scenario keys and counts."""
import argparse
import csv
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path


def results(mod: Path) -> dict:
    """testcase display name -> pass / fail / skip."""
    out = {}
    for rep in (mod / "target/surefire-reports").glob("TEST-*.xml"):
        for tc in ET.parse(rep).getroot().iter("testcase"):
            st = "fail" if tc.find("failure") is not None or tc.find("error") is not None else \
                 "skip" if tc.find("skipped") is not None else "pass"
            out[f"{tc.get('classname', '').split('.')[-1]}::{tc.get('name', '')}"] = st
    return out


def load(p: Path, default):
    return json.loads(p.read_text(encoding="utf-8")) if p.is_file() else default


def flow_matrix(mod: Path) -> tuple[list[dict], dict]:
    cfg = load(mod / "src/test/resources/flow-test.json", {})
    meta = load(mod / ".scaffold.json", {})
    res = results(mod)
    parity = mod / "src/test/resources/parity"
    counts = {}
    sc_json = Path(meta.get("task1", "")) / "traces/scenarios.json" if meta.get("task1") else None
    if sc_json and sc_json.is_file():
        counts = {s["scenario"]: s["count"] for s in json.loads(sc_json.read_text(encoding="utf-8"))}
    by_scenario = defaultdict(list)
    for sc in sorted(parity.glob("*/*/SCENARIO.txt")):
        key = sc.read_text(encoding="utf-8").strip()
        by_scenario[key] += [c for c in sorted(sc.parent.iterdir()) if (c / "input.payload").is_file()]

    def expected(key: str) -> str:
        if "|error|" in key:
            return "out-" + cfg.get("error_output", "?")
        vals = dict(p.split("=", 1) for p in key.split("|") if "=" in p)
        for m in cfg.get("scenario_mapping", []):
            ok = True
            for p in m["scenario"].split("|"):
                if "!=" in p:
                    k, v = p.split("!=", 1)
                    ok &= vals.get(k) != v
                elif "=" in p:
                    k, v = p.split("=", 1)
                    ok &= vals.get(k) == v
            if ok and m["scenario"]:
                return ", ".join(o if o == "reply" else "out-" + o for o in m["outputs"]) or "nothing sent"
        return "NOT MAPPED"

    rows, used = [], set()
    for i, (key, cases) in enumerate(sorted(by_scenario.items(), key=lambda kv: -counts.get(kv[0], len(kv[1]))), 1):
        rel = [c.relative_to(parity).as_posix() for c in cases]
        st = [res.get(f"FlowParityTest::reachesTheSameOutputAsOsb(String, Path) route {r}") for r in rel]
        body = [res.get(f"FlowParityTest::bodyEqualsOriginalXQueryResult(String, Path) body {r}") for r in rel]
        used.update(f"FlowParityTest::reachesTheSameOutputAsOsb(String, Path) route {r}" for r in rel)
        used.update(f"FlowParityTest::bodyEqualsOriginalXQueryResult(String, Path) body {r}" for r in rel)
        scen = "|".join(p for p in key.split("|")[2:])
        synthetic = all("-synthetic/" in r for r in rel)
        rows.append({"id": f"{'S' if synthetic else 'P'}{i:02d}",
                     "kind": "synthetic (fake values, from the schema)" if synthetic else "parity (real masked messages)",
                     "what": scen or key,
                     "inputs": f"{len(cases)} synthetic" if synthetic else f"{len(cases)} of {counts.get(key, '?')} in export",
                     "expected": expected(key),
                     "passed": st.count("pass"), "failed": st.count("fail"), "not_run": st.count(None),
                     "body_check": "pass" if body and all(b == "pass" for b in body) else
                                   ("pending (no golden)" if body and all(b == "skip" for b in body) else
                                    ("FAIL" if "fail" in body else "-")),
                     "result": "PASS" if st and all(s == "pass" for s in st) else ("FAIL" if "fail" in st else "NOT RUN")})
    other = sorted(k for k in res if k not in used)
    for j, k in enumerate(other, 1):
        cls, name = k.split("::", 1)
        rows.append({"id": f"E{j:02d}", "kind": "error/behaviour" if cls != "FlowParityTest" else "parity (generic)",
                     "what": re.sub(r"(?<!^)(?=[A-Z])", " ", name.split("(")[0]).lower(), "inputs": "fake values",
                     "expected": "-", "passed": int(res[k] == "pass"), "failed": int(res[k] == "fail"),
                     "not_run": 0, "body_check": "-", "result": {"pass": "PASS", "fail": "FAIL", "skip": "SKIP"}[res[k]]})
    for k, g in load(mod / "GATES.json", {}).get("gates", {}).items():
        rows.append({"id": k.split("_")[0], "kind": "gate", "what": k.split("_", 1)[1].replace("_", " "), "inputs": "-",
                     "expected": "ok", "passed": int(g["ok"]), "failed": int(not g["ok"]), "not_run": 0, "body_check": "-",
                     "result": "PASS" if g["ok"] else "FAIL"})
    mut = load(mod / "MUTATION.json", {})
    for n, m in enumerate(mut.get("mutations", []), 1):
        rows.append({"id": f"M{n:02d}", "kind": "mutation (route broken on purpose)", "what": m["what"], "inputs": "all tests",
                     "expected": "tests fail", "passed": int(m["killed"]), "failed": int(not m["killed"]), "not_run": 0,
                     "body_check": "-", "result": "CAUGHT" if m["killed"] else "MISSED"})
    p = [r for r in rows if r["id"][0] in "PS" and r["kind"] != "gate"]
    summary = {"flow": f"{meta.get('project', '?')}/{meta.get('proxy', mod.name)}",
               "scenarios": len(p), "scenarios_pass": sum(r["result"] == "PASS" for r in p),
               "unmapped": sum(r["expected"] == "NOT MAPPED" for r in p),
               "cases": sum(r["passed"] + r["failed"] + r["not_run"] for r in p),
               "cases_failed": sum(r["failed"] for r in p),
               "error_tests": sum(r["kind"] == "error/behaviour" for r in rows),
               "error_tests_failed": sum(r["kind"] == "error/behaviour" and r["result"] == "FAIL" for r in rows),
               "gates": load(mod / "GATES.json", {}).get("result", "not run"),
               "mutations": f"{sum(m['killed'] for m in mut.get('mutations', []))}/{len(mut.get('mutations', []))}" if mut else "not run",
               "reports": "yes" if res else "no (run mvn test)"}
    return rows, summary


COLS = ["id", "kind", "what", "inputs", "expected", "passed", "failed", "not_run", "body_check", "result"]


def write(out_md: Path, title: str, intro: list[str], cols: list[str], rows: list[dict]) -> None:
    with out_md.with_name("test-matrix.csv").open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    md = [f"# {title}", ""] + intro + ["", "| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    md += ["| " + " | ".join(str(r.get(c, "")).replace("|", " / ") for c in cols) + " |" for r in rows]
    out_md.write_text("\n".join(md) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path, nargs="?")
    ap.add_argument("--domain", type=Path, help="modules root: every */*/.scaffold.json below it")
    ap.add_argument("-o", "--out", type=Path)
    a = ap.parse_args()
    if a.domain:
        mods = sorted(p.parent for p in a.domain.glob("*/*/.scaffold.json"))
        sums = []
        for m in mods:
            rows, s = flow_matrix(m)
            write(m / "TEST_MATRIX.md", f"Test matrix: {s['flow']}", [], COLS, rows)
            sums.append(s)
        out = a.out or a.domain
        out.mkdir(parents=True, exist_ok=True)
        cols = list(sums[0]) if sums else ["flow"]
        green = sum(s["gates"] == "PASS" and s["cases_failed"] == 0 for s in sums)
        write(out / "TEST_MATRIX.md", "Test matrix: domain", [
            f"{len(sums)} flows, {green} fully green (gates PASS, no failed case). Per flow: modules/<project>/<proxy>/TEST_MATRIX.md.",
            "scenarios = scenarios seen in the Splunk logs; cases = real masked messages run through the Camel route; "
            "error_tests = error handler / retry / header tests; mutations = route defects inserted on purpose that the tests caught."],
              cols, sums)
        print(json.dumps({"flows": len(sums), "green": green, "out": str(out / "TEST_MATRIX.md")}))
        return 0
    if not a.module:
        ap.error("module or --domain required")
    rows, s = flow_matrix(a.module)
    write(a.module / "TEST_MATRIX.md", f"Test matrix: {s['flow']}", [
        f"Scenarios {s['scenarios_pass']}/{s['scenarios']} pass, {s['cases']} real masked messages "
        f"({s['cases_failed']} failed), error tests {s['error_tests']} ({s['error_tests_failed']} failed), "
        f"gates {s['gates']}, mutations caught {s['mutations']}.",
        "P = real messages from Splunk, expected outputs from the research pack (OSB source). E = error handler and "
        "behaviour tests. K = gates. M = the route broken on purpose: each must make tests fail."], COLS, rows)
    print(json.dumps(s))
    return 0 if s["cases_failed"] == 0 and s["error_tests_failed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_TEST_MATRIX_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/scripts/verify_module.py")"
cat > '.pi/skills/osb-camelk-route/scripts/verify_module.py' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_VERIFY_MODULE_PY'
#!/usr/bin/env python3
"""mvn test + gates for ONE module, with a SHORT answer: what an agent needs to fix, nothing else. Stdlib only.

    verify_module.py modules/<project>/<proxy> [--mvn "mvn -B -q -s ~/.m2/settings.xml"] [--max 8]

Why: an agent re-sends its whole conversation with every model call. The full Maven output (Camel logs of every test)
is hundreds of KB; once it is in the conversation it is paid for on every later call, which is what exhausts the model
endpoint's token quota. This script writes the full output to target/verify-mvn.log and prints at most ~30 lines:
totals, the failing tests (name + first line of the message, cut at 200 characters), the failing gates.
Exit 0 = tests green and gates PASS except K1 (approval is a person's step), 1 = something to fix, 2 = could not run."""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def win_path(arg: str) -> str:
    """Git Bash path (/c/Users/x) -> Windows path (c:/Users/x) when running natively on Windows; else unchanged."""
    return re.sub(r"^/([a-zA-Z])/", r"\1:/", arg) if os.name == "nt" else arg


SCALAR_KEYS = ("message", "uri", "logName", "loggingLevel", "beanType", "method", "id")


def yaml_lint(text: str) -> list[str]:
    """Structure mistakes models make in Camel YAML routes that make the WHOLE route fail to load (every test errors
    with one cryptic line). Line-based, no YAML library: a scalar key left empty with a block below it
    (`message:` + `simple: "..."`), and `steps:` next to `from:` instead of under it."""
    out, lines = [], text.splitlines()
    ind = lambda s: len(s) - len(s.lstrip(" "))  # noqa: E731
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.startswith("#") or not s:
            continue
        m = re.match(r"^-?\s*(\w+):\s*$", s)
        if m and m.group(1) in SCALAR_KEYS:
            nxt = next((x for x in lines[i + 1:] if x.strip() and not x.strip().startswith("#")), "")
            if ind(nxt) > ind(ln):
                out.append(f"line {i + 1}: '{m.group(1)}:' must be a plain value on the same line "
                           f"(e.g. {m.group(1)}: \"...${{body}}\"), not a block with '{nxt.strip().split(':')[0]}:' below")
        if s == "steps:":
            prev = next((x for x in reversed(lines[:i]) if x.strip() and not x.strip().startswith("#")), "")
            frm = next((x for x in reversed(lines[:i]) if x.strip() == "from:"), None)
            if frm is not None and ind(frm) == ind(ln) and not prev.strip().startswith("- "):
                out.append(f"line {i + 1}: route 'steps:' belongs UNDER 'from:' (indent it below from:)")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--mvn", default=os.environ.get("VERIFY_MVN", "mvn -B -q " + os.environ.get("MVN_ARGS", "")))
    ap.add_argument("--max", type=int, default=8, help="failing tests listed")
    a = ap.parse_args()
    mod = a.module
    args = [win_path(os.path.expanduser(x)) for x in shlex.split(a.mvn)]
    exe = shutil.which(args[0]) or shutil.which(args[0] + ".cmd")
    if not exe:
        print(f"cannot find {args[0]} on PATH")
        return 2
    lint = [f"{p.name} {x}" for p in sorted((mod / "src/main/resources/routes").glob("*.yaml")) for x in yaml_lint(p.read_text(encoding="utf-8"))]
    if lint:                            # the route would not load: every test errors; say where, before a Maven run
        print(f"ROUTE YAML STRUCTURE ({len(lint)}): fix these lines first, the route cannot load")
        for x in lint[:a.max]:
            print("  " + x)
        print("FIX NEEDED")
        return 1
    rep = mod / "target/surefire-reports"
    if rep.is_dir():
        for f in rep.glob("TEST-*.xml"):
            f.unlink()
    (mod / "target").mkdir(exist_ok=True)
    log = mod / "target/verify-mvn.log"
    env = dict(os.environ)
    if os.name == "nt" and env.get("JAVA_HOME"):
        env["JAVA_HOME"] = win_path(env["JAVA_HOME"])          # mvn.cmd needs C:/..., Git Bash exports /c/...
    r = subprocess.run([exe] + args[1:] + ["-f", str(mod / "pom.xml"), "clean", "test"], capture_output=True, text=True,
                       errors="replace", env=env)
    log.write_text(r.stdout + r.stderr, encoding="utf-8")
    t = f = e = s = 0
    fails = []
    for x in sorted(rep.glob("TEST-*.xml")) if rep.is_dir() else []:
        root = ET.parse(x).getroot()
        t += int(root.get("tests", 0)); f += int(root.get("failures", 0)); e += int(root.get("errors", 0)); s += int(root.get("skipped", 0))
        for tc in root.iter("testcase"):
            bad = tc.find("failure") if tc.find("failure") is not None else tc.find("error")
            if bad is not None:
                msg = (bad.get("message") or bad.get("type") or "").strip().splitlines()
                fails.append(f"{tc.get('classname', '').split('.')[-1]}.{tc.get('name')}: {(msg[0] if msg else '')[:200]}")
    if t == 0:
        out = [re.sub(r"\x1b\[[0-9;]*m", "", ln).strip() for ln in (r.stdout + r.stderr).splitlines()]
        lines = [ln for ln in out if re.search(r"ERROR|[Ee]rror:|Caused by|cannot find|does not exist|not defined", ln)]
        lines = lines or [ln for ln in out if ln][-15:]        # never an empty answer: the agent needs a reason
        print(f"BUILD/COMPILE FAILED (no test ran, maven exit {r.returncode}). First errors:")
        for ln in lines[:15] or ["(maven printed nothing: is mvn 3.9 / JAVA_HOME right? run the same mvn by hand)"]:
            print("  " + ln[:220])
        print(f"full output: {log}")
        return 1
    print(f"tests {t}, failures {f}, errors {e}, skipped {s}")
    for x in fails[: a.max]:
        print("  FAIL " + x)
    if len(fails) > a.max:
        print(f"  ... {len(fails) - a.max} more (full output: {log})")
    g = subprocess.run([sys.executable, str(Path(__file__).with_name("check_camelk.py")), str(mod)], capture_output=True, text=True)
    gates = json.loads((mod / "GATES.json").read_text(encoding="utf-8"))["gates"] if (mod / "GATES.json").is_file() else {}
    bad_gates = {k: v for k, v in gates.items() if not v.get("ok") and k != "K1_card_approved"}
    for k, v in bad_gates.items():
        print(f"  GATE {k} " + json.dumps({x: y for x, y in v.items() if x != "ok"})[:220])
    ok = f == 0 and e == 0 and not bad_gates
    print("PASS (K1 = approval, a person's step)" if ok else "FIX NEEDED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_SCRIPTS_VERIFY_MODULE_PY
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/references/yaml-patterns.md")"
cat > '.pi/skills/osb-camelk-route/references/yaml-patterns.md' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_REFERENCES_YAML_PATTERNS_MD'
# OSB pipeline → Camel K YAML DSL (Camel 4.18), patterns proven on the pilot

All of these ran green in `pilot/sample-adjustment` (Camel 4.18.4, `camel-test-main-junit5`). Anything else: check
the Camel 4.18 documentation of the component or EIP before writing it.

| OSB | Camel K YAML |
|---|---|
| `assign $uuId := header traceId or fn-bea:uuid()` | `- setHeader: {name: traceId, simple: "${header.traceId} ?: ${uuid(random)}"}` (`uuid(random)` = java UUID, 36 chars like fn-bea:uuid) |
| Log action | `- log: {loggingLevel: INFO, logName: oracle.osb.logging.pipeline, message: "<same literal text> ${header.x} ::${body}"}`; keep the position (OSB logs before nXSD) |
| nXSD JSON→XML used only for conditions | helper bean `OsbJson.annotate`: lenient parse (raw control characters, text after the JSON), sets condition fields as headers, **does not change the body** |
| `ifThenElse` with one case (no else) | `- choice: {id: branch-<x>, when: [{id: branch-<x>-<path>, simple: "${header.f} == 'true'", steps: [...]}]}`; no `otherwise` = nothing happens, like OSB |
| Two independent `ifThenElse` in one stage | two `choice` blocks one after the other (both can fire) |
| XPath `//*:f/text()='true'` | header from bean with path `//f` (first field of that name at any depth) or `a.b.f`; compare as text: JSON `true` and `"true"` both give `true` |
| Route/publish to a JMS business service | `- to: {id: out-<bs>, uri: "{{out.<bs>}}"}`; property `out.<bs>=amqp:queue:<name>` |
| Business service retry-count N, interval S | send through `direct:send-<bs>` in its own route with `routeConfigurationId` → `routeConfiguration` + `errorHandler.defaultErrorHandler.redeliveryPolicy {maximumRedeliveries: "{{retry.<bs>.count:N}}", redeliveryDelay: "{{retry.<bs>.delay:S000}}"}`; after the last retry the exception returns to the caller's `doCatch` |
| Pipeline error handler → error queue with headers | `doTry` around the flow, `doCatch: [{exception: [java.lang.Exception], steps: [log, setHeader errorCode/errorMessage/debugInfo, removeHeaders of internal headers, to out-<error-bs>]}]`; inbound headers (resource, eventType, traceId) travel with the message |
| Error queue gets `$requestDoc` (original body) | keep the body unchanged everywhere before the catch (the bean never replaces it) |
| `replace` with stored XQuery | `- to: "xquery:osb/<project>/<file>.xqy"` (camel-saxon), parameters as headers; fn-bea functions via the shim in skill osb-to-camel |
| XSLT | `- to: "xslt-saxon:osb/<project>/<file>.xsl"` |
| Durable topic subscription + selector | not in the route: subscription queue `<address>::<subscription>` with the selector as broker filter (Artemis config); `flow.input=amqp:queue:<address>::<subscription>`; selector tests are L2 |

Tests: `@CamelMainTest(properties = {"flow.input=direct:in", "out.x=mock:out-x", "retry.x.delay=0", ...})`,
`@Produce("direct:in") ProducerTemplate in`, mocks by `in.getCamelContext().getEndpoint("mock:out-x", MockEndpoint.class)`,
failures by `mock.whenAnyExchangeReceived(e -> { throw new IOException("down"); })`, retries by `getReceivedCounter()`.
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_REFERENCES_YAML_PATTERNS_MD
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/assets/templates/FlowErrorTest.java.tpl")"
cat > '.pi/skills/osb-camelk-route/assets/templates/FlowErrorTest.java.tpl' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_FLOWERRORTEST_JAVA_TPL'
package @@PACKAGE@@;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.camel.CamelContext;
import org.apache.camel.Exchange;
import org.apache.camel.ExchangePattern;
import org.apache.camel.Produce;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.test.main.junit5.CamelMainTest;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;

/**
 * Error tests for OSB project @@PROJECT@@, proxy @@PROXY@@: one test per error scope at least (gate K7).
 * GENERATED START by osb-camelk-route; the implementer may add tests for further error scopes of FLOW_CARD section 9.
 * Error path as in OSB: either the error output (a queue, mock) receives the message with the correlation header,
 * or (request/reply flows, error_output = "reply") the caller gets an answer, not an exception, with the HTTP status
 * OSB sets (flow-test.json error_http_status, when research names one).
 */
@CamelMainTest(properties = {@@TEST_PROPERTIES@@})
class FlowErrorTest {

    static final Path PARITY = Path.of("src/test/resources/parity");
    static final ObjectMapper JSON = new ObjectMapper();
    static final String REPLY = "reply";

    @Produce("direct:in")
    ProducerTemplate in;

    static JsonNode cfg() throws Exception {
        return JSON.readTree(Path.of("src/test/resources/flow-test.json").toFile());
    }

    CamelContext ctx() {
        return in.getCamelContext();
    }

    MockEndpoint mock(String uri) {
        return ctx().getEndpoint(uri, MockEndpoint.class);
    }

    /** Sends the message and checks it took OSB's error path. */
    void assertErrorPath(String body, Map<String, Object> headers) throws Exception {
        JsonNode cfg = cfg();
        String err = cfg.path("error_output").asText("");
        Assumptions.assumeFalse(err.isEmpty(), "research.json names no error output");
        String corr = cfg.path("correlation_header").asText("traceId");
        for (var it = cfg.path("outputs").fields(); it.hasNext(); ) {
            var o = it.next();
            if (!REPLY.equals(o.getKey())) {
                mock(o.getValue().asText()).expectedMessageCount(o.getKey().equals(err) ? 1 : 0);
            }
        }
        boolean reply = REPLY.equals(err);
        Exchange ex = in.send(e -> {
            e.setPattern(reply ? ExchangePattern.InOut : ExchangePattern.InOnly);
            e.getMessage().setBody(body);
            e.getMessage().setHeaders(new HashMap<>(headers));
        });
        MockEndpoint.assertIsSatisfied(ctx());
        if (reply) {
            assertNull(ex.getException(), "OSB answers the caller on an error, the route must not end with an exception");
            JsonNode status = cfg.path("error_http_status");
            if (status.isInt()) {
                assertEquals(status.asInt(), ex.getMessage().getHeader(Exchange.HTTP_RESPONSE_CODE, Integer.class),
                    "HTTP status of the error reply");
            }
            assertEquals(headers.get(corr), ex.getMessage().getHeader(corr), corr + " must reach the error reply");
        } else {
            var m = mock(cfg.path("outputs").path(err).asText()).getExchanges().get(0).getMessage();
            assertEquals(headers.get(corr), m.getHeader(corr), corr + " must reach the error output");
        }
    }

    @Test
    void unreadablePayloadTakesTheErrorPath() throws Exception {
        Assumptions.assumeTrue("json".equals(cfg().path("payload_format").asText()), "not a JSON flow");
        String corr = cfg().path("correlation_header").asText("traceId");
        assertErrorPath("not json at all", Map.of(corr, "t-invalid"));
    }

    static Stream<String> backends() throws Exception {
        List<String> b = new ArrayList<>();
        cfg().path("backends").fieldNames().forEachRemaining(b::add);
        return b.stream();
    }

    /** OSB error handler of the service: a backend that fails (fault, timeout, HTTP error) takes the error path. */
    @ParameterizedTest(name = "backend {0} fails")
    @MethodSource("backends")
    void backendFaultTakesTheErrorPath(String backend) throws Exception {
        Path c = firstCase();
        Assumptions.assumeTrue(c != null, "no test case to send");
        mock(cfg().path("backends").path(backend).path("mock").asText())
            .whenAnyExchangeReceived(e -> { throw new IllegalStateException("backend " + backend + " fault (test)"); });
        @SuppressWarnings("unchecked")
        Map<String, Object> headers = JSON.readValue(c.resolve("headers.json").toFile(), Map.class);
        String corr = cfg().path("correlation_header").asText("traceId");
        headers.putIfAbsent(corr, "t-backend-fault");
        assertErrorPath(Files.readString(c.resolve("input.payload")), headers);
    }

    static Path firstCase() throws Exception {
        if (!Files.isDirectory(PARITY)) {
            return null;
        }
        try (Stream<Path> s = Files.walk(PARITY)) {
            return s.filter(p -> p.getFileName().toString().equals("input.payload")).map(Path::getParent).sorted()
                .findFirst().orElse(null);
        }
    }

    @Test
    void flowTestConfigIsReadable() throws Exception {
        assertNotNull(cfg().path("outputs"));
        assertFalse(cfg().path("outputs").isEmpty(), "flow-test.json has no outputs");
    }
}
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_FLOWERRORTEST_JAVA_TPL
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/assets/templates/FlowJBangTest.java.tpl")"
cat > '.pi/skills/osb-camelk-route/assets/templates/FlowJBangTest.java.tpl' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_FLOWJBANGTEST_JAVA_TPL'
///usr/bin/env jbang "$0" "$@" ; exit $?
//JAVA 21+
//DEPS org.apache.camel:camel-bom:@@CAMEL@@@pom
//DEPS org.apache.camel:camel-core-engine
//DEPS org.apache.camel:camel-main
//DEPS org.apache.camel:camel-yaml-dsl
//DEPS org.apache.camel:camel-direct
//DEPS org.apache.camel:camel-mock
//DEPS org.apache.camel:camel-bean
//DEPS org.apache.camel:camel-log
//DEPS org.apache.camel:camel-jackson
//DEPS net.sf.saxon:Saxon-HE:12.9
//DEPS org.junit.platform:junit-platform-console-standalone:1.12.2
//DEPS org.slf4j:slf4j-simple:2.0.17
//SOURCES ../../Common-setup/OsbNxsd.java
//SOURCES ../../Common-setup/OsbXQuery.java

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.camel.CamelContext;
import org.apache.camel.Exchange;
import org.apache.camel.ExchangePattern;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.impl.DefaultCamelContext;
import org.apache.camel.support.PluginHelper;
import org.apache.camel.support.ResourceHelper;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestFactory;
import org.junit.jupiter.api.TestInstance;
import org.w3c.dom.Document;

import javax.xml.parsers.DocumentBuilderFactory;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.UUID;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Tests of flow @@PROXY@@, no pom and no broker: `jbang test/@@CLASS@@.java` in the project folder.
 * The route file is loaded unchanged; every endpoint property is replaced by direct:/mock:, so the kamelets (and their
 * broker connection) are never created. Cases: test/resources/@@PROXY@@/parity/** (masked log messages, synthetic
 * cases where the logs had none). Expected queue per case = the frozen scenario table (flow-test.json).
 * Body checks: error queue = the original message unchanged; other queues = well-formed XML when the OSB pipeline
 * sends XML (docs/@@PROXY@@/BODY_CHAIN.md), and equal to expected-output.xml where one exists (OSB's real output).
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
public class @@CLASS@@ {
    static final String PROXY = "@@PROXY@@";
    static final Path RES = Path.of("test/resources", PROXY);
    static final List<String> ERROR_HEADERS = List.of(@@ERROR_HEADERS@@);
    static final ObjectMapper JSON = new ObjectMapper();
    static final String[] PROPS = {@@PROPS@@
    };

    CamelContext camel;
    ProducerTemplate producer;
    JsonNode cfg;

    /** `jbang test/@@CLASS@@.java`: runs this class with the JUnit platform, one line per test, exit 1 on a failure. */
    public static void main(String... args) {
        var request = org.junit.platform.launcher.core.LauncherDiscoveryRequestBuilder.request()
            .selectors(org.junit.platform.engine.discovery.DiscoverySelectors.selectClass(@@CLASS@@.class)).build();
        var summary = new org.junit.platform.launcher.listeners.SummaryGeneratingListener();
        var lines = new org.junit.platform.launcher.TestExecutionListener() {
            @Override
            public void executionFinished(org.junit.platform.launcher.TestIdentifier id, org.junit.platform.engine.TestExecutionResult r) {
                if (id.isTest()) {
                    System.out.println((r.getStatus() == org.junit.platform.engine.TestExecutionResult.Status.SUCCESSFUL ? "PASS " : "FAIL ")
                        + id.getDisplayName() + r.getThrowable().map(t -> "  -> " + t.getMessage()).orElse(""));
                }
            }
        };
        org.junit.platform.launcher.core.LauncherFactory.create().execute(request, summary, lines);
        var s = summary.getSummary();
        System.out.printf("%d tests, %d failed%n", s.getTestsFoundCount(), s.getTotalFailureCount());
        System.exit(s.getTotalFailureCount() == 0 && s.getTestsFoundCount() > 0 ? 0 : 1);
    }

    @BeforeAll
    void start() throws Exception {
        cfg = JSON.readTree(RES.resolve("flow-test.json").toFile());
        camel = new DefaultCamelContext();
        Properties p = new Properties();
        for (String kv : PROPS) {
            int i = kv.indexOf('=');
            p.setProperty(kv.substring(0, i), kv.substring(i + 1));
        }
        camel.getPropertiesComponent().setOverrideProperties(p);
        PluginHelper.getRoutesLoader(camel).loadRoutes(ResourceHelper.resolveResource(camel, "file:@@ROUTE@@"));
        camel.start();
        producer = camel.createProducerTemplate();
    }

    @AfterAll
    void stop() {
        camel.stop();
    }

    String mockOf(String output) {
        return "mock:" + PROXY + "-" + output;
    }

    List<String> outputs() {
        List<String> l = new ArrayList<>();
        cfg.path("outputs").fieldNames().forEachRemaining(o -> { if (!"reply".equals(o)) l.add(o); });
        return l;
    }

    /** Sends one message; every output in targets must receive exactly one message, every other none. */
    Map<String, Exchange> send(String body, Map<String, Object> headers, List<String> targets) throws Exception {
        MockEndpoint.resetMocks(camel);
        for (String o : outputs()) {
            MockEndpoint m = camel.getEndpoint(mockOf(o), MockEndpoint.class);
            m.expectedMessageCount(targets.contains(o) ? 1 : 0);
            m.setResultWaitTime(2000);
        }
        producer.send("direct:in-" + PROXY, ExchangePattern.InOnly, e -> {
            e.getMessage().setBody(body);
            e.getMessage().setHeaders(new HashMap<>(headers));
        });
        Map<String, Exchange> got = new HashMap<>();
        for (String o : outputs()) {
            MockEndpoint m = camel.getEndpoint(mockOf(o), MockEndpoint.class);
            m.assertIsSatisfied();
            if (!m.getExchanges().isEmpty()) {
                got.put(o, m.getExchanges().get(0));
            }
        }
        return got;
    }

    static boolean matches(String key, Map<String, String> values) {
        if (key.isBlank()) {
            return false;
        }
        for (String part : key.split("\\|")) {
            int ne = part.indexOf("!=");
            int eq = part.indexOf('=');
            if (ne > 0 && part.substring(ne + 2).equals(values.get(part.substring(0, ne)))) {
                return false;
            }
            if (ne < 0 && eq > 0 && !part.substring(eq + 1).equals(values.get(part.substring(0, eq)))) {
                return false;
            }
        }
        return true;
    }

    List<String> expectedOutputs(Path c) throws Exception {
        JsonNode exp = Files.exists(c.resolve("expected.json")) ? JSON.readTree(c.resolve("expected.json").toFile()) : JSON.createObjectNode();
        if (!"success".equals(exp.path("outcome").asText("success"))) {
            return List.of(cfg.path("error_output").asText());
        }
        Path sc = c.getParent().resolve("SCENARIO.txt");
        Map<String, String> values = new HashMap<>();
        for (String part : (Files.exists(sc) ? Files.readString(sc).strip() : "").split("\\|")) {
            int i = part.indexOf('=');
            if (i > 0) {
                values.put(part.substring(0, i), part.substring(i + 1));
            }
        }
        for (JsonNode m : cfg.path("scenario_mapping")) {
            if (matches(m.path("scenario").asText(), values)) {
                List<String> outs = new ArrayList<>();
                m.path("outputs").forEach(o -> outs.add(o.asText()));
                return outs;
            }
        }
        throw new AssertionError("scenario not mapped in flow-test.json: " + values);
    }

    @SuppressWarnings("unchecked")
    Map<String, Object> headersOf(Path c) throws Exception {
        Path h = c.resolve("headers.json");
        return Files.exists(h) ? JSON.readValue(h.toFile(), Map.class) : new HashMap<>();
    }

    static Document xml(String s) throws Exception {
        DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
        f.setNamespaceAware(true);
        f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        return f.newDocumentBuilder().parse(new ByteArrayInputStream(s.getBytes(StandardCharsets.UTF_8)));
    }

    /** Values OSB generates per call (fn-bea:uuid, current time) are compared by presence only. */
    static String canonical(String s) throws Exception {
        Document d = xml(s);
        d.normalizeDocument();
        var t = javax.xml.transform.TransformerFactory.newInstance().newTransformer();
        t.setOutputProperty(javax.xml.transform.OutputKeys.OMIT_XML_DECLARATION, "yes");
        var w = new java.io.StringWriter();
        t.transform(new javax.xml.transform.dom.DOMSource(d), new javax.xml.transform.stream.StreamResult(w));
        return w.toString().replaceAll(">\\s+<", "><")
            .replaceAll(">[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}<", ">GENERATED<")
            .replaceAll(">\\d{4}-\\d{2}-\\d{2}T[0-9:.]+(Z|[+-]\\d{2}:\\d{2})?<", ">GENERATED<");
    }

    Stream<Path> cases() throws Exception {
        Path parity = RES.resolve("parity");
        if (!Files.isDirectory(parity)) {
            return Stream.empty();
        }
        try (Stream<Path> s = Files.walk(parity)) {
            return s.filter(p -> p.getFileName().toString().equals("input.payload")).map(Path::getParent).sorted().toList().stream();
        }
    }

    @Test
    void casesArePresent() throws Exception {
        assertFalse(cases().toList().isEmpty(), "no test cases under " + RES.resolve("parity"));
    }

    @TestFactory
    Stream<DynamicTest> eachCaseReachesTheQueueOsbUsed() throws Exception {
        return cases().map(c -> DynamicTest.dynamicTest(RES.relativize(c).toString(), () -> {
            String in = Files.readString(c.resolve("input.payload"));
            List<String> targets = expectedOutputs(c);
            Map<String, Exchange> got = send(in, headersOf(c), targets);
            String err = cfg.path("error_output").asText();
            for (var e : got.entrySet()) {
                String body = e.getValue().getMessage().getBody(String.class);
                if (e.getKey().equals(err)) {
                    assertEquals(in, body, "error queue gets the original message (OSB: replace $body with $request)");
                    continue;
                }
                assertNull(e.getValue().getMessage().getHeader("resource"), "OSB sends no transport headers on " + e.getKey());
                if (body != null && body.stripLeading().startsWith("<")) {
                    assertNotNull(xml(body), "well-formed XML on " + e.getKey());
                }
                Path golden = c.resolve("expected-output.xml");
                if (Files.exists(golden)) {
                    assertEquals(canonical(Files.readString(golden)), canonical(body), "body differs from OSB's real output");
                }
            }
        }));
    }

    @Test
    void unreadableMessageGoesToTheErrorQueueUnchanged() throws Exception {
        Path first = cases().findFirst().orElseThrow();
        Map<String, Object> h = headersOf(first);
        String err = cfg.path("error_output").asText();
        Exchange e = send("{[[ not a message", h, List.of(err)).get(err);
        assertEquals("{[[ not a message", e.getMessage().getBody(String.class));
        for (String name : ERROR_HEADERS) {
            if (List.of("errorCode", "errorMessage", "debugInfo").contains(name) || h.containsKey(name)) {
                assertNotNull(e.getMessage().getHeader(name), name + " must be set on the error queue (OSB transport-headers)");
            }
        }
    }

    @Test
    void traceIdIsGeneratedWhenMissing() throws Exception {
        String corr = cfg.path("correlation_header").asText("traceId");
        if (!ERROR_HEADERS.contains(corr)) {
            return;      // the route always generates it at entry; checked where OSB sends it (the error queue)
        }
        String err = cfg.path("error_output").asText();
        Exchange e = send("{[[ not a message", new HashMap<>(), List.of(err)).get(err);
        assertNotNull(UUID.fromString(e.getMessage().getHeader(corr, String.class)), corr + " generated (OSB fn-bea:uuid)");
    }
}
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_FLOWJBANGTEST_JAVA_TPL
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/assets/templates/FlowParityTest.java.tpl")"
cat > '.pi/skills/osb-camelk-route/assets/templates/FlowParityTest.java.tpl' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_FLOWPARITYTEST_JAVA_TPL'
package @@PACKAGE@@;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.camel.CamelContext;
import org.apache.camel.Exchange;
import org.apache.camel.ExchangePattern;
import org.apache.camel.Message;
import org.apache.camel.Produce;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.test.main.junit5.CamelMainTest;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.w3c.dom.Document;
import org.w3c.dom.Node;

import javax.xml.parsers.DocumentBuilderFactory;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * GENERATED by osb-camelk-route from research/@@PROJECT@@/@@PROXY@@/research.json. Do not edit: check_camelk.py
 * compares this file with its scaffold hash. Flow-specific tests (errors, transforms) go in other test classes.
 *
 * L1 test of the YAML route with Camel mock endpoints (Maven only, no broker, no cluster). Inputs are the real masked
 * messages from task 1 (src/test/resources/parity/**, copied on the VDI, never committed). For each case:
 *   - the scenario (SCENARIO.txt) is looked up in scenario_mapping (research Q5) -> the outputs it must reach;
 *   - no other output receives anything; the correlation header is carried through (and generated when missing,
 *     if OSB does: flow-test.json correlation_generated); no scenario field leaves the route as a header;
 *   - if expected-output.json/.xml exists, the body must equal it: the body OSB itself logged on its way out (task 1),
 *     or the original XQuery run on the input (golden_runner). XML is compared by namespace, not by prefix.
 * Backends are mock endpoints answering with src/test/resources/stubs/<backend>.* (shape from research Q8).
 * Cases come from Splunk (parity/<flow>/) or, where the flow logs no payload, are synthetic (parity/<flow>-synthetic/,
 * fake values from the message schema, written by the tester before the route and frozen like this file).
 */
@CamelMainTest(properties = {@@TEST_PROPERTIES@@})
class FlowParityTest {

    static final Path PARITY = Path.of("src/test/resources/parity");
    static final Path STUBS = Path.of("src/test/resources/stubs");
    static final ObjectMapper JSON = new ObjectMapper();
    static final JsonNode CFG = load();
    static final String REPLY = "reply";

    @Produce("@@INPUT@@")
    ProducerTemplate in;

    static JsonNode load() {
        try {
            return JSON.readTree(Path.of("src/test/resources/flow-test.json").toFile());
        } catch (Exception e) {
            throw new IllegalStateException("src/test/resources/flow-test.json missing or invalid", e);
        }
    }

    CamelContext ctx() {
        return in.getCamelContext();
    }

    MockEndpoint mock(String uri) {
        return ctx().getEndpoint(uri, MockEndpoint.class);
    }

    @BeforeEach
    void stubBackends() throws Exception {
        for (var it = CFG.path("backends").fields(); it.hasNext(); ) {
            var b = it.next();
            Path stub = null;
            for (String ext : new String[] {".json", ".xml", ".txt"}) {
                Path p = STUBS.resolve(b.getKey() + ext);
                if (Files.exists(p)) {
                    stub = p;
                }
            }
            if (stub != null) {
                String body = Files.readString(stub);
                mock(b.getValue().path("mock").asText()).whenAnyExchangeReceived(e -> e.getMessage().setBody(body));
            }
        }
    }

    static Stream<Arguments> cases() throws Exception {
        if (!Files.isDirectory(PARITY)) {
            return Stream.empty();
        }
        try (Stream<Path> s = Files.walk(PARITY)) {
            return s.filter(p -> p.getFileName().toString().equals("input.payload")).map(Path::getParent).sorted()
                .map(c -> Arguments.of(PARITY.relativize(c).toString(), c)).toList().stream();
        }
    }

    @Test
    void caseFoldersArePresent() throws Exception {
        assertFalse(cases().toList().isEmpty(), "no test cases: copy task1/fixtures/parity/* into " + PARITY);
    }

    /** Outputs this case must reach: error output for error cases, else the first scenario_mapping row whose key
     *  matches the case's SCENARIO.txt (k=v equal, k!=v different or missing). Empty list = consumed, nothing sent. */
    static List<String> expectedOutputs(Path c, JsonNode expected) throws Exception {
        if (!"success".equals(expected.path("outcome").asText())) {
            String err = CFG.path("error_output").asText("");
            assertFalse(err.isEmpty(), "case expects an error but research.json names no error output");
            return List.of(err);
        }
        Path sc = c.getParent().resolve("SCENARIO.txt");
        Map<String, String> values = new HashMap<>();
        for (String part : (Files.exists(sc) ? Files.readString(sc).strip() : "").split("\\|")) {
            int i = part.indexOf('=');
            if (i > 0) {
                values.put(part.substring(0, i), part.substring(i + 1));
            }
        }
        for (JsonNode m : CFG.path("scenario_mapping")) {
            if (matches(m.path("scenario").asText(), values)) {
                List<String> outs = new ArrayList<>();
                m.path("outputs").forEach(o -> outs.add(o.asText()));
                return outs;
            }
        }
        return fail("scenario not mapped in research.json scenario_mapping: " + values);
    }

    static boolean matches(String key, Map<String, String> values) {
        if (key.isBlank()) {
            return false;
        }
        for (String p : key.split("\\|")) {
            int ne = p.indexOf("!=");
            int eq = p.indexOf('=');
            if (ne > 0 && p.substring(ne + 2).equals(values.get(p.substring(0, ne)))) {
                return false;
            }
            if (ne < 0 && eq > 0 && !p.substring(eq + 1).equals(values.get(p.substring(0, eq)))) {
                return false;
            }
        }
        return true;
    }

    /** Sends the case (InOnly for one-way flows, as OSB response-required=false; InOut where the flow replies);
     *  every output in targets receives exactly one message, every other output none. "reply" = the answer to the caller. */
    List<Message> send(Path c, List<String> targets) throws Exception {
        @SuppressWarnings("unchecked")
        Map<String, Object> headers = JSON.readValue(c.resolve("headers.json").toFile(), Map.class);
        return send(Files.readString(c.resolve("input.payload")), headers, targets);
    }

    List<Message> send(String body, Map<String, Object> headers, List<String> targets) throws Exception {
        for (var it = CFG.path("outputs").fields(); it.hasNext(); ) {
            var o = it.next();
            if (!REPLY.equals(o.getKey())) {
                mock(o.getValue().asText()).expectedMessageCount(targets.contains(o.getKey()) ? 1 : 0);
            }
        }
        Exchange ex = in.send(e -> {
            e.setPattern(ExchangePattern.@@PATTERN@@);
            e.getMessage().setBody(body);
            e.getMessage().setHeaders(new HashMap<>(headers));
        });
        MockEndpoint.assertIsSatisfied(ctx());
        List<Message> out = new ArrayList<>();
        for (String t : targets) {
            if (REPLY.equals(t)) {
                assertNull(ex.getException(), "the caller must get a reply, not an exception");
                out.add(ex.getMessage());
                continue;
            }
            String uri = CFG.path("outputs").path(t).asText("");
            assertFalse(uri.isEmpty(), "scenario_mapping names output '" + t + "' that is not in outputs");
            out.add(mock(uri).getExchanges().get(0).getMessage());
        }
        return out;
    }

    @ParameterizedTest(name = "route {0}")
    @MethodSource("cases")
    void reachesTheSameOutputAsOsb(String name, Path c) throws Exception {
        JsonNode expected = JSON.readTree(c.resolve("expected.json").toFile());
        String corr = CFG.path("correlation_header").asText("traceId");
        try {
            for (Message out : send(c, expectedOutputs(c, expected))) {
                assertEquals(expected.path("correlation").asText(), out.getHeader(corr, String.class), corr + " must be carried through");
                for (JsonNode f : CFG.path("scenario_fields")) {
                    assertNull(out.getHeader(f.asText()), f.asText() + " is a routing field, OSB sends no such header");
                }
            }
        } catch (AssertionError e) {
            throw new AssertionError("case " + name + ": " + e.getMessage(), e);   // surefire reports show only [n]
        }
    }

    /** OSB: correlation id = inbound header, else fn-bea:uuid(). The first case with an output, sent without it. */
    @Test
    void correlationIdIsGeneratedWhenMissing() throws Exception {
        Assumptions.assumeTrue(CFG.path("correlation_generated").asBoolean(false), "OSB does not generate the correlation id here");
        String corr = CFG.path("correlation_header").asText("traceId");
        for (Arguments a : cases().toList()) {
            Path c = (Path) a.get()[1];
            List<String> targets = expectedOutputs(c, JSON.readTree(c.resolve("expected.json").toFile()));
            if (targets.isEmpty()) {
                continue;
            }
            @SuppressWarnings("unchecked")
            Map<String, Object> headers = JSON.readValue(c.resolve("headers.json").toFile(), Map.class);
            headers.remove(corr);
            for (Message out : send(Files.readString(c.resolve("input.payload")), headers, targets)) {
                String id = out.getHeader(corr, String.class);
                assertTrue(id != null && id.length() == 36, corr + " must be a generated UUID, was: " + id);
            }
            return;
        }
        Assumptions.assumeTrue(false, "no case reaches an output");
    }

    @ParameterizedTest(name = "body {0}")
    @MethodSource("cases")
    void bodyEqualsOriginalXQueryResult(String name, Path c) throws Exception {
        Path json = c.resolve("expected-output.json");
        Path xml = c.resolve("expected-output.xml");
        Assumptions.assumeTrue(Files.exists(json) || Files.exists(xml), "expected output pending (golden_runner on the VDI)");
        JsonNode expected = JSON.readTree(c.resolve("expected.json").toFile());
        List<String> targets = expectedOutputs(c, expected);
        List<Message> outs = send(c, targets);
        assertFalse(outs.isEmpty(), "golden output exists but the scenario maps to no output");
        // the body that is compared: the reply to the caller if the flow has one, else the first queue output
        String body = outs.get(targets.contains(REPLY) ? targets.indexOf(REPLY) : 0).getBody(String.class);
        if (Files.exists(json)) {
            JsonNode want = JSON.readTree(json.toFile());
            JsonNode got = JSON.readTree(body);
            for (JsonNode g : CFG.path("generated_fields")) {        // OSB generated these (fresh UUID, time): presence only,
                boolean osbHas = !at(want, g.asText()).isMissingNode();  // and only where OSB's output has the field
                assertEquals(osbHas, !at(got, g.asText()).isMissingNode(),
                    g.asText() + (osbHas ? " must be present (OSB generates it)" : " is not in OSB's output for this message"));
                drop(want, g.asText());
                drop(got, g.asText());
            }
            assertEquals(want, got);
        } else {
            assertTrue(xmlEqual(Files.readString(xml), body), "body differs from the OSB result (logged by OSB or the original XQuery)");
        }
    }

    static JsonNode at(JsonNode n, String dotted) {
        for (String p : dotted.split("\\.")) {
            n = n.path(p);
        }
        return n;
    }

    static void drop(JsonNode n, String dotted) {
        int i = dotted.lastIndexOf('.');
        JsonNode parent = i < 0 ? n : at(n, dotted.substring(0, i));
        if (parent instanceof com.fasterxml.jackson.databind.node.ObjectNode o) {
            o.remove(i < 0 ? dotted : dotted.substring(i + 1));
        }
    }

    @Test
    void unreadablePayloadGoesToTheErrorOutput() throws Exception {
        String err = CFG.path("error_output").asText("");
        Assumptions.assumeTrue("json".equals(CFG.path("payload_format").asText()) && !err.isEmpty(), "not a JSON flow or no error output");
        Assumptions.assumeFalse(REPLY.equals(err), "the error is a reply to the caller: FlowErrorTest checks it");
        for (var it = CFG.path("outputs").fields(); it.hasNext(); ) {
            var o = it.next();
            if (!REPLY.equals(o.getKey())) {
                mock(o.getValue().asText()).expectedMessageCount(o.getKey().equals(err) ? 1 : 0);
            }
        }
        String corr = CFG.path("correlation_header").asText("traceId");
        in.sendBodyAndHeaders("not json at all", Map.of(corr, "t-invalid"));
        MockEndpoint.assertIsSatisfied(ctx());
        Message m = mock(CFG.path("outputs").path(err).asText()).getExchanges().get(0).getMessage();
        assertEquals("t-invalid", m.getHeader(corr), corr + " must reach the error output");
    }

    static boolean xmlEqual(String a, String b) throws Exception {
        var f = DocumentBuilderFactory.newInstance();
        f.setNamespaceAware(true);
        f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        Document da = f.newDocumentBuilder().parse(new ByteArrayInputStream(a.getBytes(StandardCharsets.UTF_8)));
        Document db = f.newDocumentBuilder().parse(new ByteArrayInputStream(b.getBytes(StandardCharsets.UTF_8)));
        strip(da);
        strip(db);
        da.normalizeDocument();
        db.normalizeDocument();
        return sameXml(da.getDocumentElement(), db.getDocumentElement());
    }

    /** Same elements (namespace + local name, prefixes ignored), same attributes, same text, same order. */
    static boolean sameXml(Node a, Node b) {
        if (a.getNodeType() != b.getNodeType()) {
            return false;
        }
        if (a.getNodeType() == Node.TEXT_NODE || a.getNodeType() == Node.CDATA_SECTION_NODE) {
            return a.getNodeValue().strip().equals(b.getNodeValue().strip());
        }
        if (!java.util.Objects.equals(a.getNamespaceURI(), b.getNamespaceURI())
            || !java.util.Objects.equals(a.getLocalName(), b.getLocalName())) {
            return false;
        }
        var aa = attrs(a);
        if (!aa.equals(attrs(b))) {
            return false;
        }
        var ca = a.getChildNodes();
        var cb = b.getChildNodes();
        if (ca.getLength() != cb.getLength()) {
            return false;
        }
        for (int i = 0; i < ca.getLength(); i++) {
            if (!sameXml(ca.item(i), cb.item(i))) {
                return false;
            }
        }
        return true;
    }

    static Map<String, String> attrs(Node n) {
        Map<String, String> m = new HashMap<>();
        var at = n.getAttributes();
        for (int i = 0; at != null && i < at.getLength(); i++) {
            Node x = at.item(i);
            if (!"http://www.w3.org/2000/xmlns/".equals(x.getNamespaceURI())) {      // namespace declarations: prefixes only
                m.put(x.getNamespaceURI() + "|" + x.getLocalName(), x.getNodeValue());
            }
        }
        return m;
    }

    static void strip(Node n) {
        for (Node c = n.getFirstChild(); c != null; ) {
            Node next = c.getNextSibling();
            if (c.getNodeType() == Node.TEXT_NODE && c.getTextContent().isBlank() || c.getNodeType() == Node.COMMENT_NODE) {
                n.removeChild(c);
            } else {
                strip(c);
            }
            c = next;
        }
    }
}
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_FLOWPARITYTEST_JAVA_TPL
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/assets/templates/OsbJson.java.tpl")"
cat > '.pi/skills/osb-camelk-route/assets/templates/OsbJson.java.tpl' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_OSBJSON_JAVA_TPL'
package @@PACKAGE@@;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.json.JsonReadFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.json.JsonMapper;
import org.apache.camel.Exchange;

/**
 * Helper bean for the YAML route: reads the payload the way OSB accepts it. OSB logs showed raw control
 * characters inside strings and text after the closing brace; Jackson rejects both by default, so this bean is
 * lenient on exactly those two points and nothing else. It also lifts the scenario fields into exchange properties
 * (not headers: a header would leave the route as a JMS property on every output, which OSB does not send).
 */
public final class OsbJson {

    static final ObjectMapper LENIENT = JsonMapper.builder()
        .enable(JsonReadFeature.ALLOW_UNESCAPED_CONTROL_CHARS)
        .disable(com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
        .build();

    private OsbJson() {
    }

    /** Parse leniently (control characters, trailing text ignored); fails on anything that is not JSON. */
    public static JsonNode parse(String body) {
        if (body == null || body.isBlank()) {
            throw new IllegalArgumentException("empty payload");
        }
        try (JsonParser p = LENIENT.createParser(body.strip())) {
            JsonNode node = LENIENT.readTree(p);
            if (node == null || !node.isObject()) {
                throw new IllegalArgumentException("payload is not a JSON object");
            }
            return node;
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
            // original message only: Jackson's full message quotes the payload, which must not reach error headers/logs
            throw new IllegalArgumentException("payload is not JSON: " + e.getOriginalMessage());
        } catch (java.io.IOException e) {
            throw new IllegalArgumentException("payload could not be read");
        }
    }

    /** Fields lifted into exchange properties so branch conditions can use ${exchangeProperty.x}; set by the scaffold
     *  from research scenario_dims. "a.b.c" = that path; "//name" = first field with that name at any depth (OSB //*:name). */
    static final String[][] FIELDS = {@@HEADER_PATHS@@};

    /** Route step: checks the payload parses like OSB accepts it and sets the scenario properties. The body is NOT
     *  changed: OSB forwards the original text ($requestDoc), so the outputs must carry it byte for byte. */
    public static void annotate(Exchange exchange) throws Exception {
        JsonNode root = parse(exchange.getMessage().getBody(String.class));
        for (String[] h : FIELDS) {
            JsonNode n;
            if (h[1].startsWith("//")) {
                n = root.findValue(h[1].substring(2));
            } else {
                n = root;
                for (String part : h[1].split("\\.")) {
                    n = n.path(part);
                }
            }
            exchange.setProperty(h[0], n == null || n.isMissingNode() || n.isNull() ? null : n.asText());
        }
    }
}
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_OSBJSON_JAVA_TPL
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/assets/templates/RUN_LOCAL_JBANG.md.tpl")"
cat > '.pi/skills/osb-camelk-route/assets/templates/RUN_LOCAL_JBANG.md.tpl' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_RUN_LOCAL_JBANG_MD_TPL'
# Run @@PROJECT@@

No pom. The route is `@@ROUTE@@`, the shared kamelets and Java helpers are in `../Common-setup`, OSB's own
transformation files (.xqy, nXSD .xsd) in `transformations/`. Needs Java 21 and Maven with access to the Maven
repository (`export MVN_ARGS="-s <settings.xml>"` if Maven needs it): when JBang / the `camel` CLI are not installed,
`run-local.sh` takes both from there (`../tools/jbang.sh`, Camel JBang @@CAMEL@@ from its Maven artifact), so no
internet is needed. Settings: `../set-env.sh`. All flows at once: `../run.sh` (see `../README.md`). Below: this project alone, in Git Bash in this folder.

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
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_RUN_LOCAL_JBANG_MD_TPL
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/assets/templates/pom.xml")"
cat > '.pi/skills/osb-camelk-route/assets/templates/pom.xml' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_POM_XML'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Module for the Camel YAML route of OSB flow @@PROJECT@@ / @@PROXY@@ (generated by osb-camelk-route).
     The YAML route runs unchanged on Camel Main, Camel on Spring Boot or Camel K; this pom TESTS it (L1, mocks),
     packages the helper beans and runs it against a broker (profile run-local, broker/run_local.sh).
     camel.version = the LTS line the programme pins (4.18, decision 2026-10-14). The cluster runtime must be the
     same minor: pass -Dcamel.version=<x> to test against another 4.x line until the platform confirms it. -->
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>@@GROUP@@</groupId>
  <artifactId>@@ARTIFACT@@</artifactId>
  <version>0.1.0-SNAPSHOT</version>

  <properties>
    <camel.version>4.18.4</camel.version>
    <junit.version>5.12.2</junit.version>
    <maven.compiler.release>21</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>

  <dependencyManagement>
    <dependencies>
      <dependency>
        <groupId>org.apache.camel</groupId>
        <artifactId>camel-bom</artifactId>
        <version>${camel.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
      <dependency>
        <groupId>org.junit</groupId>
        <artifactId>junit-bom</artifactId>
        <version>${junit.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
    </dependencies>
  </dependencyManagement>

  <dependencies>
    <!-- what the route uses (on Camel K these come from the route's own dependencies) -->
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-main</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-yaml-dsl</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-direct</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-log</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-bean</artifactId></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-jackson</artifactId></dependency>
    <!-- @@EXTRA_DEPS@@ -->
    <!-- broker connection (AMQP 1.0 / Qpid JMS) for the runs against a broker; the L1 tests never open it -->
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-amqp</artifactId></dependency>
    <dependency><groupId>org.slf4j</groupId><artifactId>slf4j-simple</artifactId><version>2.0.17</version><scope>runtime</scope></dependency>

    <!-- tests -->
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-test-main-junit5</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.apache.camel</groupId><artifactId>camel-mock</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter-params</artifactId><scope>test</scope></dependency>
  </dependencies>

  <build>
    <plugins>
      <!-- pinned: older Maven installs default to compiler 3.1, which ignores maven.compiler.release and compiles as Java 1.5 -->
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>3.13.0</version>
        <configuration><release>21</release></configuration>
      </plugin>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-resources-plugin</artifactId>
        <version>3.3.1</version>
      </plugin>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-surefire-plugin</artifactId>
        <version>3.5.3</version>
        <!-- display names in the XML reports ("route <case folder>"): test_matrix.py maps every result to its case -->
        <configuration>
          <statelessTestsetReporter implementation="org.apache.maven.plugin.surefire.extensions.junit5.JUnit5Xml30StatelessReporter">
            <usePhrasedTestCaseMethodName>true</usePhrasedTestCaseMethodName>
          </statelessTestsetReporter>
        </configuration>
      </plugin>
    </plugins>
  </build>

  <profiles>
    <!-- mvn -Prun-local exec:java -D<key>=<value>...  (broker/run_local.sh): the route on Camel Main against a broker -->
    <profile>
      <id>run-local</id>
      <build>
        <plugins>
          <plugin>
            <groupId>org.codehaus.mojo</groupId>
            <artifactId>exec-maven-plugin</artifactId>
            <version>3.5.0</version>
            <configuration>
              <mainClass>org.apache.camel.main.Main</mainClass>
              <classpathScope>runtime</classpathScope>
            </configuration>
          </plugin>
        </plugins>
      </build>
    </profile>
  </profiles>
</project>
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_POM_XML
mkdir -p "$(dirname ".pi/skills/osb-camelk-route/assets/templates/run-local-jbang.sh.tpl")"
cat > '.pi/skills/osb-camelk-route/assets/templates/run-local-jbang.sh.tpl' <<'KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_RUN_LOCAL_JBANG_SH_TPL'
#!/usr/bin/env bash
# @@PROJECT@@ on a local Artemis with Camel JBang (no pom). Needs: Java 21, Maven with access to the Maven repository
# (MVN_ARGS="-s <settings.xml>"; JBang and Camel come from there when not installed), an unzipped and running Artemis
# (ARTEMIS_HOME) for run/send/stat, python for "send". See RUN_LOCAL.md.
#   bash run-local.sh test                          the tests of every flow (jbang test/*Test.java), no broker
#   bash run-local.sh run                           start the routes (camel run), Ctrl+C stops them
#   bash run-local.sh send <proxy> <case folder>    send one case (input.payload + headers.json) as the OSB caller would
#   bash run-local.sh stat                          message counts of every queue on the broker
#   bash run-local.sh stop                          stop the routes of this project (camel stop, works on Windows too)
set -u
cd "$(dirname "$0")"
[ -f ../set-env.sh ] && . ../set-env.sh               # the settings of the whole folder (JAVA_HOME, MVN_ARGS, ARTEMIS_HOME, BROKER_*)
CAMEL_VERSION="${CAMEL_VERSION:-@@CAMEL@@}"
# JBang: installed, else ../tools/jbang.sh (the JBang jar through Maven/Nexus, no internet needed)
jb() { if command -v jbang > /dev/null; then jbang "$@"; else bash ../tools/jbang.sh "$@"; fi; }
# Camel CLI: installed, else Camel JBang straight from its Maven artifact (no GitHub catalog)
camelcli() { if command -v camel > /dev/null; then camel "$@"; else jb --main main.CamelJBang "org.apache.camel:camel-jbang-main:$CAMEL_VERSION" "$@"; fi; }
SEND_PY=$(cat <<'PYEOF'
import json, re, sys
v = sys.argv[1].split("=", 1)[1]
kind = re.search(r"destinationType=(\w+)", v).group(1)
dest = re.search(r"destination=([^&]+)", v).group(1)
sel = (re.search(r"selector=RAW\((.*)\)$", v) or [None, ""])[1]
h = json.load(open(sys.argv[2], encoding="utf-8")) if sys.argv[2] and __import__("os").path.isfile(sys.argv[2]) else {}
# properties the selector needs but the case lacks (OSB does not log them): the first value the selector names
for name in dict.fromkeys(re.findall(r"(\w+)\s*=\s*'", sel)):
    if name not in h:
        vals = re.findall(rf"\b{name}\s*=\s*'([^']*)'", sel)
        if vals:
            h[name] = vals[0]
print(f"{kind}://{dest}", json.dumps([{"type": "string", "key": k, "value": str(x)} for k, x in h.items()], separators=(",", ":")))
PYEOF
)
wp() { if command -v cygpath > /dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
art() { : "${ARTEMIS_HOME:?export ARTEMIS_HOME=<unzipped apache-artemis folder>}"; : "${BROKER_PASSWORD:?export BROKER_PASSWORD=<broker password>}"
  "${JAVA_HOME:+$JAVA_HOME/bin/}java" -cp "$(wp "$ARTEMIS_HOME/lib/artemis-boot.jar")" -Dartemis.home="$(wp "$ARTEMIS_HOME")" \
    org.apache.activemq.artemis.boot.Artemis "$@" --user "${BROKER_USER:-artemis}" --password "$BROKER_PASSWORD" --url "${BROKER_URL:-tcp://localhost:61616}"; }
case "${1:-}" in
  test)
    rc=0; for t in test/*Test.java; do echo "== $t"; jb "$t" || rc=1; done; exit $rc ;;
  run)
    : "${BROKER_PASSWORD:?export BROKER_PASSWORD=<broker password>}"
    export BROKER_USER="${BROKER_USER:-artemis}" BROKER_URL="${BROKER_URL:-tcp://localhost:61616}" OSB_FILES_DIR="$(wp "$(pwd)")"
    camelcli run @@ROUTE@@ application.properties local.properties ../Common-setup/OsbNxsd.java ../Common-setup/OsbXQuery.java \
      --local-kamelet-dir=../Common-setup --camel-version="$CAMEL_VERSION" ;;
  send)
    x=${2:?proxy}; c=${3:?case folder with input.payload and headers.json}
    line=$(grep -E "^$x\.flow\.input=" local.properties | tr -d '\r'); [ -n "$line" ] || { echo "unknown proxy $x"; exit 2; }
    PY=$(command -v python3 || command -v python)
    out=$("$PY" -c "$SEND_PY" "$line" "$c/headers.json") || exit 2
    dest=${out%% *}; props=${out#* }
    art producer --protocol CORE --destination "$dest" --message-count 1 --message "$(cat "$c/input.payload")" --properties "$props" 2>&1 \
      | grep -E "Produced|rror|xception" | head -3 ;;
  stop)
    camelcli stop "$(grep -E '^camel.main.name=' application.properties | cut -d= -f2 | tr -d '\r')" ;;
  stat)
    art queue stat --maxRows 500 --maxColumnSize -1 2>&1 | grep -E "^\|" ;;
  *) sed -n '2,8p' "$0" ;;
esac
KIT_EOF__PI_SKILLS_OSB_CAMELK_ROUTE_ASSETS_TEMPLATES_RUN_LOCAL_JBANG_SH_TPL
mkdir -p "$(dirname "agents/implementer-camelk.md")"
cat > 'agents/implementer-camelk.md' <<'KIT_EOF_AGENTS_IMPLEMENTER_CAMELK_MD'
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
FlowErrorTest.java is generated as a compiling start: extend it, keep its helper methods, never rewrite it from
scratch. YAML: `steps:` of a route belong under `from:`; in `doCatch` each item is `- exception: [..]` with its
`steps:` at the same level as `exception`.
Run tests only through scripts/verify_module.py (short summary), never raw mvn. Finish when it prints PASS, or stop and report which gate fails and why it cannot pass.
KIT_EOF_AGENTS_IMPLEMENTER_CAMELK_MD
mkdir -p "$(dirname "agents/tester-camelk.md")"
cat > 'agents/tester-camelk.md' <<'KIT_EOF_AGENTS_TESTER_CAMELK_MD'
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
Request/reply flows (flow-test.json has `reply` in outputs and `backends`): the reply body must be testable, so also
- `src/test/resources/stubs/<backend>.json` per backend: its answer with FAKE values and ONLY the fields research.json
  names (transforms[].mappings[].from, backends[].response_use); include one record each filter of the transforms
  selects (e.g. the status the reply keeps) and one it skips;
- `expected-output.json` next to each `input.payload`: the reply research.json transforms build from that stub, field
  by field, every rule applied (renames, date reformat, value mapping). Never a field research does not name.
You never write or change the route, the beans, FlowParityTest.java, flow-test.json, or real (Splunk) case folders.
If the schema is missing from the export, build the message from the field names research.json / RESEARCH.md give
(message format, mappings) and say so in your answer; if research names no fields either, write nothing for that row.
KIT_EOF_AGENTS_TESTER_CAMELK_MD
mkdir -p "$(dirname "pi/run_camelk.sh")"
cat > 'pi/run_camelk.sh' <<'KIT_EOF_PI_RUN_CAMELK_SH'
#!/usr/bin/env bash
# Research pack -> Camel K module for ONE proxy: functional tests (pi/run_tests.sh) -> approval gate -> implement (pi)
# -> mvn test -> gates.
#
# Usage: pi/run_camelk.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]
#   research-dir   research/<project>/<proxy> with research.json (+ facts.json), check PASS
#   module-dir     modules/<project>/<proxy> (created on the first run)
#   task1-dir      its fixtures/parity/* are copied into the module as test inputs (masked; .gitignore keeps them out of Git)
# Env: OSB_SRC (OSB project folder: the implementer may copy original XQuery/XSLT/XSD into the module), MVN_ARGS
#      (e.g. "-s ~/.m2/client-settings.xml"), OSB_PI_MODEL, PI_THINKING (default high), KIT, PYTHON
# Exit: 0 gates PASS, 3 card not approved yet (expected after the first run), 1 anything else.
set -euo pipefail
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done   # local settings, never in Git
MVN_ARGS=${MVN_ARGS//\~/$HOME}   # "~" inside a variable is not expanded by the shell
RES=${1:?usage: run_camelk.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]}
MOD=${2:?module dir}
PRJ=${3:?osb project name}
TASK1=${4:-}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$KIT/pi/pi_call.sh"
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
skill_dir() { if [ -d "$KIT/skills/$1" ]; then echo "$KIT/skills/$1"; elif [ -d "$KIT/.pi/skills/$1" ]; then echo "$KIT/.pi/skills/$1"; fi; }
SK=$(skill_dir osb-camelk-route); [ -n "$SK" ] || { echo "skill osb-camelk-route not found under $KIT"; exit 1; }
[ -s "$RES/research.json" ] || { echo "missing $RES/research.json: run pi/run_research.sh first"; exit 1; }
if [ -f "$RES/SHARE_CHECK.json" ] && ! grep -q '"pass": true' "$RES/SHARE_CHECK.json"; then echo "research pack did not pass its check: $RES/SHARE_CHECK.json"; exit 1; fi

echo "== 1 functional tests: generated tests + mocks, synthetic inputs, frozen (pi/run_tests.sh)"
bash "$KIT/pi/run_tests.sh" "$RES" "$MOD" "$PRJ" ${TASK1:+"$TASK1"} || echo "some scenarios have no test case yet (gate K9 will fail)"

echo "== 2 approval"
if [ "${POC:-0}" = 1 ] && ! grep -qiE '^Status:[[:space:]]*approved' "$MOD/FLOW_CARD.md"; then
  # proof-of-concept run without a sign-off: build anyway, mark the card, gate K1 stays FAIL
  sed -i.bak 's/^Status:.*/Status: poc-run (NOT approved)/' "$MOD/FLOW_CARD.md" && rm -f "$MOD/FLOW_CARD.md.bak"
  echo "   POC=1: card not approved, built for the proof of concept only (gate K1 stays FAIL)"
elif ! grep -qiE '^Status:[[:space:]]*approved[[:space:]]*$' "$MOD/FLOW_CARD.md" || ! grep -qE '^Approver:[[:space:]]*[^[:space:]]' "$MOD/FLOW_CARD.md"; then
  echo "card not approved: review $MOD/FLOW_CARD.md against $RES/RESEARCH.md, set 'Status: approved' + Approver + Date, rerun"
  exit 3
fi

LOG="$MOD/.agent-logs"; mkdir -p "$LOG"
# freeze the card as it is now (approved by a person, or marked poc-run): pi must not change it (gate K1 checks the hash)
"$PY" -c "import hashlib,json,sys; p=sys.argv[1]; m=json.load(open(p)); m['card_sha256']=hashlib.sha256(open(sys.argv[2],'rb').read()).hexdigest(); json.dump(m,open(p,'w'),indent=2)" "$MOD/.scaffold.json" "$MOD/FLOW_CARD.md"
echo "== 3 implement (pi), in small calls"
# Every pi call starts fresh (--no-session) and never sees raw Maven output: verify_module.py prints ~30 lines.
# An agent re-sends its whole conversation with every model request, so big tool output is paid for again and again;
# small calls with a short summary keep each request small (the endpoint's limit is per minute).
PI=(pi --print --no-session --thinking "${PI_THINKING:-high}" --skill "$SK" --tools "read,bash,edit,write"
    --append-system-prompt "$KIT/agents/implementer-camelk.md")
[ -n "${OSB_PI_MODEL:-}" ] && PI+=(--model "$OSB_PI_MODEL")
VERIFY="$PY $SK/scripts/verify_module.py $MOD"
RULES="Never run mvn directly: '$VERIFY' runs the tests and the gates and prints a short summary. Never edit FlowParityTest.java, flow-test.json, FLOW_CARD.md or any test case folder. Write nothing outside $MOD. Do not read target/ or the parity cases."
export VERIFY_MVN="mvn -B -q ${MVN_ARGS:-}"
pi_call "$LOG/implement.out" "$LOG/implement.err" "${PI[@]}" "Use skill osb-camelk-route. Module: $MOD. Approved card: $MOD/FLOW_CARD.md. Research: $RES/research.json (RESEARCH.md only if research.json is unclear). ${OSB_SRC:+OSB source (read only, only the files the card names): $OSB_SRC.} Do steps 3-5 of the skill: fill every TODO(flow-card) in the route (request/reply: step 3b, the reply built from research.json transforms row by row), extend the generated FlowErrorTest (keep its helpers; one test per error scope at least), and write a backend stub only where src/test/resources/stubs has none. Then run '$VERIFY' ONCE and stop: fixing is the next call. $RULES" || true
for round in $(seq 1 "${PI_FIX_ROUNDS:-3}"); do
  SUMMARY=$($VERIFY 2>&1) && { echo "   verify: PASS after $round call(s)"; break; }
  echo "   verify round $round: $(echo "$SUMMARY" | head -1)"
  sleep "${PI_PAUSE:-30}"
  pi_call "$LOG/fix-$round.out" "$LOG/fix-$round.err" "${PI[@]}" "Use skill osb-camelk-route. Module: $MOD (card $MOD/FLOW_CARD.md). The last verify printed:
$SUMMARY
Fix exactly these failures in the route, the helper beans, FlowErrorTest or the stubs: read only the files you change and the card. Then run '$VERIFY' once and stop. $RULES" || true
done

echo "== 4 verify"
mvn -B -q ${MVN_ARGS:-} -f "$MOD/pom.xml" test > "$LOG/mvn.out" 2>&1 || true
grep -h "Tests run:" "$LOG/mvn.out" | tail -1 || true
"$PY" "$SK/scripts/check_camelk.py" "$MOD"
KIT_EOF_PI_RUN_CAMELK_SH
mkdir -p "$(dirname "pi/run_domain.sh")"
cat > 'pi/run_domain.sh' <<'KIT_EOF_PI_RUN_DOMAIN_SH'
#!/usr/bin/env bash
# One OSB application (domain) with many projects and proxies: run the per-flow steps for all of them, keep going when
# one flow fails, and keep a status table. Safe to rerun: finished steps are skipped.
#
# Usage: pi/run_domain.sh <osb-app-dir> <stage> [workspace]
#   osb-app-dir  e.g. /e/osb-application (the folder holding the *-prj projects)
# Short form with APP in .osb-kit.env: run_domain.sh <stage> [workspace]
# BATCH_NO=n (with BATCH_SIZE, default 10): the n-th slice of the project list, no names to type; 'batches' lists them.
#   stage        list      projects and proxies found (no agent) -> domain/projects.txt, domain/flows.txt
#                batches   how many batches of BATCH_SIZE projects, with the command for each
#                coverage  READY / THIN / SYNTHETIC per proxy: enough real Splunk messages for functional tests or not
#                          (needs SPLUNK_COVERAGE = CSV of the readiness search in DOMAIN_RUN.md) -> domain/COVERAGE.md
#                research  research pack per proxy -> <ws>/research/<project>/<proxy>/   (skips packs that PASS)
#                task1     Splunk test cases for every researched proxy, split by the fields its branches use
#                          (research scenario_dims) -> <ws>/task1/flows/<project>-<proxy>/   (needs EXPORT, MASK_KEY)
#                tests     FUNCTIONAL TESTS per researched proxy (no route needed): generated tests + mocks, real Splunk
#                          cases, synthetic cases from the schema where Splunk has none (pi tester), frozen, catalogue
#                          -> <ws>/modules/<project>/<proxy>/src/test/** + TEST_MATRIX.md
#                scaffold  same module without the tester step
#                build     implement + test + gates for every proxy whose card is approved
#                matrix    mutation check (route broken on purpose) + test matrix per flow and for the domain
#                functional  the whole proof: research -> task1 -> tests -> build -> matrix -> report
#                          (build needs approved cards, or POC=1 for a proof-of-concept run: cards marked, K1 FAIL)
#                estimate  model load per flow (calls, tokens, minutes) from the OSB source size + measured times
#                          (domain/timings.csv); quota via PI_RPM / PI_TPM -> domain/PI_LOAD_ESTIMATE.md
#                time      MEASURED time per pi step (work vs rate-limit waiting) and the projection for TOTAL_FLOWS
#                          (default 450) -> domain/TIME_PROJECTION.md
#                report    domain/FUNCTIONAL_TEST_REPORT.md: inputs, expected outputs, mocks, results, mutations per flow
#                flat      delivery/<app>/: Common-setup kamelets + per project ONE <domain>-route.yaml, <Flow>Transformer.java,
#                          <Flow>TransformerTest.java (assemble_flat.py; also the last step of functional)
#                delivery  delivery/<app>/ WITHOUT a pom (assemble_jbang.py): route built from the OSB pipeline (body_chain.py:
#                          nXSD + the flow's own .xqy), Artemis kamelets, tests run by jbang, run-local.sh (camel run)
#                review    PROJECTS='a-prj|b-prj': from tests to the review archive in one go (REVIEW_RUNBOOK.md):
#                          test cases (frozen scenario table) -> delivery without pom (route from the OSB pipeline) ->
#                          jbang tests -> broker run (camel run, needs ARTEMIS_PASSWORD) -> draft handover note -> archive
#                          REVIEW_TESTS=0 skips the first step
#                auto      research -> task1 -> tests: the functional test pack for every flow, then stops
#                          (routes: approve the cards, then build and matrix)
#                status    only rewrite <ws>/domain/STATUS.md + status.csv
#   workspace    default: current folder
# PROJECTS matches whole project names: 'a-prj|b-.*' (regex, anchored).
# Env: PI_PAUSE (seconds between two flows in a pi stage, default 30: keeps under the model's rate limit),
#      PI_RETRIES / PI_BACKOFF (retries after a 429, see pi_call.sh),
#      PROJECTS (regex on project names, e.g. 'beneficiary|cancel-'), EXPORT (one Splunk CSV export with all flows of
#      the domain, raw or *.masked.csv), MASK_KEY, MVN_ARGS (e.g. "-s ~/.m2/settings.xml"), MUTATE=0 to skip mutations,
#      MASK_JSON_KEYS ('fieldA fieldB': extra JSON/XML fields to mask in task1, when the residue check finds one),
#      plus the env of run_research.sh / run_camelk.sh (OSB_PI_MODEL, ...).
set -uo pipefail
# local client settings, never in Git: $OSB_KIT_ENV, else ./.osb-kit.env, else ~/.osb-kit.env
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
MVN_ARGS=${MVN_ARGS//\~/$HOME}   # "~" inside a variable is not expanded by the shell
STAGES='list|batches|coverage|estimate|time|research|task1|tests|scaffold|build|matrix|report|flat|delivery|review|functional|auto|status'
if echo "${1:-}" | grep -Eqx "($STAGES)"; then         # short form: run_domain.sh <stage> [workspace], APP from the env file
  STAGE=$1; WS=${2:-${WS:-.}}; APP=${APP:?set APP in .osb-kit.env or use: run_domain.sh <osb-app-dir> <stage>}
else
  APP=${1:?usage: run_domain.sh [<osb-app-dir>] <stage> [workspace]   stages: $STAGES}
  STAGE=${2:?stage}
  WS=${3:-${WS:-.}}
fi
case "$APP" in *\\*|[A-Za-z]:*) command -v cygpath >/dev/null && APP=$(cygpath -u "$APP");; esac
[ -d "$APP" ] || { echo "OSB application folder not found: $APP (Git Bash: /e/folder, not E:\\folder)"; exit 2; }
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
if [ -n "${PROJECTS:-}" ]; then   # 'a-prj b-prj' or 'a-prj,b-prj' = 'a-prj|b-prj'
  PROJECTS=$(printf '%s' "$PROJECTS" | sed -E 's/^[[:space:],]+//; s/[[:space:],]+$//; s/[[:space:],]+/|/g'); export PROJECTS
fi
FILTER=${PROJECTS:-.*}
mkdir -p "$WS/domain"
SK="$KIT/skills/osb-camelk-route/scripts"; [ -d "$SK" ] || SK="$KIT/.pi/skills/osb-camelk-route/scripts"
BATCH=$(for d in "$KIT/../../vdi-osb-migration/bin" "$KIT/bin"; do [ -f "$d/batch_task1.py" ] && echo "$d/batch_task1.py" && break; done)
t1dir() { local d="$WS/task1/flows/$(echo "$1-$2" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//;s/-$//' | tr 'A-Z' 'a-z' | cut -c1-80)"; [ -d "$d/fixtures/parity" ] && echo "$d"; }

timed() {   # timed <project> <proxy> <stage> <command...>: run it, append the duration to domain/timings.csv
  local p=$1 x=$2 st=$3 t0 rc w; shift 3; t0=$(date +%s)
  export PI_WAIT_FILE="$WS/domain/.wait.$$"; : > "$PI_WAIT_FILE"
  "$@"; rc=$?
  w=$(awk '{s+=$1} END{print s+0}' "$PI_WAIT_FILE"); rm -f "$PI_WAIT_FILE"; unset PI_WAIT_FILE
  [ -f "$WS/domain/timings.csv" ] || echo "project,proxy,stage,seconds,waited,exit" > "$WS/domain/timings.csv"
  echo "$p,$x,$st,$(( $(date +%s) - t0 )),$w,$rc" >> "$WS/domain/timings.csv"
  return $rc
}

projects() {   # project folders (sorted), after PROJECTS; BATCH_NO=n keeps the n-th slice of BATCH_SIZE (default 10)
  local all
  all=$(for prj in "$APP"/*/; do p=$(basename "$prj"); [ "${p#.}" != "$p" ] && continue
        echo "$p" | grep -Eqx "($FILTER)" && find "$prj" -type f \( -name '*.proxy' -o -name '*.ProxyService' \) | grep -q . && echo "$p"; done)
  if [ -n "${BATCH_NO:-}" ]; then
    echo "$all" | awk -v n="$BATCH_NO" -v s="${BATCH_SIZE:-10}" 'NR > (n-1)*s && NR <= n*s'
  else echo "$all"; fi
}

flows() {   # "<project> <proxy>" for every proxy file (12c .proxy, sbconfig .ProxyService) in the selected projects
  for p in $(projects); do
    prj="$APP/$p/"
    find "$prj" -type f \( -name '*.proxy' -o -name '*.ProxyService' \) | sort | while read -r f; do
      n=$(basename "$f"); echo "$p ${n%.*}"
    done
  done
}

status() {
  local csv="$WS/domain/status.csv" md="$WS/domain/STATUS.md"
  echo "project,proxy,research,open_questions,test_cases,card,gates,tests" > "$csv"
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; m="$WS/modules/$p/$x"
    rs=-; [ -f "$r/SHARE_CHECK.json" ] && { grep -q '"pass": true' "$r/SHARE_CHECK.json" && rs=PASS || rs=FAIL; }
    oq=-; [ -s "$r/research.json" ] && oq=$("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1], encoding='utf-8')).get('open_questions') or []))" "$r/research.json")
    tc=-; [ -d "$m/src/test/resources/parity" ] && tc=$(find "$m/src/test/resources/parity" -name input.payload | wc -l | tr -d ' ')
    cs=-; [ -f "$m/FLOW_CARD.md" ] && { grep -qiE '^Status:[[:space:]]*approved' "$m/FLOW_CARD.md" && cs=approved || cs=draft; }
    gs=-; ts=-; if [ -f "$m/GATES.json" ]; then grep -q '"result": "PASS"' "$m/GATES.json" && gs=PASS || gs=FAIL
      ts=$("$PY" -c "import json,sys; g=json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}); print(f\"{g.get('tests','-')}/{g.get('failures','-')}F/{g.get('skipped','-')}S\")" "$m/GATES.json"); fi
    echo "$p,$x,$rs,$oq,$tc,$cs,$gs,$ts" >> "$csv"
  done
  { echo "# Domain status: $(basename "$APP")"; echo; echo "Generated $(date '+%F %H:%M'). research = pack check, card = FLOW_CARD.md, gates = check_camelk.py, tests = run/failed/skipped."; echo
    echo "| Project | Proxy | Research | Open questions | Test cases | Card | Gates | Tests |"; echo "|---|---|---|---|---|---|---|---|"
    tail -n +2 "$csv" | awk -F, '{printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6,$7,$8}'
    echo; tail -n +2 "$csv" | awk -F, '{n++; if($3=="PASS")r++; if($5!="-")t++; if($6=="approved")c++; if($7=="PASS")g++} END{printf "%d proxies: %d researched, %d with Splunk test cases, %d cards approved, %d green\n",n,r,t,c,g}'
  } > "$md"
  tail -1 "$md"
}

task1_of() {   # task-1 folder of a proxy: domain batch first, then TASK1_ROOT/<proxy>/task1
  local t; t=$(t1dir "$1" "$2"); [ -z "$t" ] && [ -n "${TASK1_ROOT:-}" ] && [ -d "$TASK1_ROOT/$2/task1" ] && t="$TASK1_ROOT/$2/task1"; echo "$t"
}

do_research() {
  flows | while read -r p x; do
    out="$WS/research/$p/$x"
    if [ -f "$out/SHARE_CHECK.json" ] && grep -q '"pass": true' "$out/SHARE_CHECK.json"; then echo "skip $p/$x (PASS)"; continue; fi
    echo "=== research $p/$x"
    t1=$(task1_of "$p" "$x")
    timed "$p" "$x" research bash -c 'cd "$1" && OUT="research/$2/$3" bash "$4/pi/run_research.sh" "$5/$2" "$3" ${6:+"$6"}' _ "$WS" "$p" "$x" "$KIT" "$APP" "$t1" < /dev/null
    rc=$?
    [ "$rc" = 75 ] && { echo "STOP: the model endpoint refuses every call (quota). Rerun later: finished flows are skipped."; return 75; }
    [ "$rc" = 0 ] || echo "FAILED research $p/$x (continuing)"
    sleep "${PI_PAUSE:-30}"
  done
}

do_task1() {   # one batch over the whole export; scenario fields per flow = what its branches decide on
  [ -n "${EXPORT:-}" ] && [ -f "$EXPORT" ] || { echo "task1 needs EXPORT=<Splunk CSV of the domain> (DOMAIN_RUN.md)"; return 2; }
  [ -n "$BATCH" ] || { echo "batch_task1.py not found (vdi-osb-migration/bin)"; return 2; }
  mkdir -p "$WS/task1"
  { echo "flow,domain,dims"
    flows | while read -r p x; do
      r="$WS/research/$p/$x/research.json"
      d=$([ -s "$r" ] && "$PY" -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')).get('scenario_dims') or []; import re; h=re.compile(r'^[$]?(?:headers?|hdr|inbound)[._:]+(?:headers?[._:]+)?([\w-]+)$', re.I); k=lambda x: x if x.startswith('hdr_') else ('hdr_' + h.match(x).group(1) if h.match(x) else 'body:' + (x if x.startswith('//') else x.lstrip('/'))); print(';'.join(dict.fromkeys(['hdr_resource'] + [k(x.strip()) for x in d])) if d else '')" "$r")
      echo "$p/$x,$(basename "$APP"),$d"
    done; } > "$WS/task1/flows.csv"
  case "$EXPORT" in *.masked.csv) am=--already-masked;; *) am=;; esac
  mk=(); for k in ${MASK_JSON_KEYS:-}; do mk+=(--mask-json-key "$k"); done      # extra fields to mask, space separated
  "$PY" "$BATCH" "$EXPORT" -o "$WS/task1" --flows "$WS/task1/flows.csv" $am "${mk[@]}" || {
    echo "some flows need a look: $WS/task1/SUMMARY.md"
    [ -f "$WS/task1/events.masked.csv.report.json" ] && "$PY" -c "import json,sys; r=json.load(open(sys.argv[1], encoding='utf-8'))['residue_check']; [print('   residue:', w) for w in r['where']]" "$WS/task1/events.masked.csv.report.json"
    echo "   fix: MASK_JSON_KEYS='<field> <field>' on the same line, then rerun task1 (arabic-script = Arabic text in a field not masked by name)"; }
}

do_scaffold() {
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; [ -s "$r/research.json" ] || continue
    t1=$(task1_of "$p" "$x")
    "$PY" "$SK/scaffold_camelk.py" "$r" -o "$WS/modules/$p/$x" --project "$p" ${t1:+--parity "$t1/fixtures/parity"} \
      || echo "FAILED scaffold $p/$x (continuing)"
  done
}

do_tests() {
  flows | while read -r p x; do
    r="$WS/research/$p/$x"; [ -s "$r/research.json" ] || continue
    echo "=== tests $p/$x"
    t1=$(task1_of "$p" "$x")
    OSB_SRC="$APP/$p" timed "$p" "$x" tests bash "$KIT/pi/run_tests.sh" "$r" "$WS/modules/$p/$x" "$p" ${t1:+"$t1"} < /dev/null | grep -E "rate limit|^\{" || echo "INCOMPLETE tests $p/$x (continuing)"
    sleep "${PI_PAUSE:-30}"
  done
  "$PY" "$SK/test_matrix.py" --domain "$WS/modules" -o "$WS/domain" > /dev/null || true
}

do_build() {
  flows | while read -r p x; do
    m="$WS/modules/$p/$x"; [ -f "$m/FLOW_CARD.md" ] || continue
    grep -qiE '^Status:[[:space:]]*(approved|poc-run)' "$m/FLOW_CARD.md" || [ "${POC:-0}" = 1 ] || { echo "skip $p/$x (card not approved; POC=1 for a proof-of-concept build)"; continue; }
    if [ -f "$m/GATES.json" ] && "$PY" -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}).get('ok') else 1)" "$m/GATES.json"; then echo "skip $p/$x (tests green)"; continue; fi
    echo "=== build $p/$x"
    t1=$(task1_of "$p" "$x")
    OSB_SRC="$APP/$p" timed "$p" "$x" build bash "$KIT/pi/run_camelk.sh" "$WS/research/$p/$x" "$m" "$p" ${t1:+"$t1"} < /dev/null || echo "NOT GREEN $p/$x (continuing)"
    sleep "${PI_PAUSE:-30}"
  done
}

do_matrix() {   # mutation check on every green module (MUTATE=0 skips it), then the matrices
  flows | while read -r p x; do
    m="$WS/modules/$p/$x"; [ -f "$m/.scaffold.json" ] || continue
    if [ "${MUTATE:-1}" = 1 ] && [ -f "$m/GATES.json" ] && "$PY" -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['gates'].get('K8_tests_green',{}).get('ok') else 1)" "$m/GATES.json" && [ ! -f "$m/MUTATION.json" ]; then
      echo "=== mutations $p/$x"; "$PY" "$SK/mutate_route.py" "$m" --mvn "mvn -B -q ${MVN_ARGS:-}"
      case $? in 0) ;; 1) echo "MUTATION SURVIVED $p/$x: tests too weak (see $m/MUTATION.json)";;
                 *) echo "MUTATION CHECK DID NOT RUN for $p/$x (message above)";; esac
    fi
  done
  "$PY" "$SK/test_matrix.py" --domain "$WS/modules" -o "$WS/domain"
}

stop_routes() {   # leftover `camel run` of the delivery projects (a route that started late keeps its folder locked on Windows):
  local d="$1" P            # camel stop <name> per project: file-based, no PowerShell or taskkill needed
  for P in $(ls -d "$d"/*/ 2>/dev/null | xargs -n1 basename | grep -Ex "($PROJECTS)"); do
    [ -f "$d/$P/run-local.sh" ] && (cd "$d/$P" && bash run-local.sh stop 2>&1 | grep -E "Shutting down" | sed 's/^/   /')
  done
  return 0
}

do_review() {   # tests -> build -> verify -> flat -> mvn test (flat) -> broker test -> note -> archive; one line per step
  [ -n "${PROJECTS:-}" ] || { echo "review needs PROJECTS='a-prj|b-prj' (the projects that go to review together)"; return 2; }
  local app; app=$(basename "$APP"); local D="$WS/delivery/$app" day; day=$(date +%F)
  local LOG="$WS/domain/review-$day.log"; : > "$LOG"
  echo "review of PROJECTS='$PROJECTS' -> $D (details: $LOG)"
  if [ "${REVIEW_TESTS:-1}" = 1 ]; then echo "== 1 tests";  do_tests >> "$LOG" 2>&1; grep -E "^\{\"scenarios|INCOMPLETE" "$LOG" | tail -5; else echo "== 1 tests (skipped)"; fi
  echo "== 2-3 (no pi build: the route is generated from the OSB pipeline in step 4)"
  echo "== 4 delivery (no pom: route from the OSB pipeline, Artemis kamelets, JBang tests)"
  stop_routes "$D"
  "$PY" "$SK/assemble_jbang.py" "$WS" --osb-app "$APP" --app "$app" --projects "$PROJECTS" | tee -a "$LOG"
  local stop=0 P
  echo "== 5 tests (bash run.sh test: jbang, no broker)"
  local P stop=0
  for P in $(ls -d "$D"/*/ 2>/dev/null | xargs -n1 basename | grep -Ex "($PROJECTS)"); do
    [ -f "$D/$P/run-local.sh" ] || continue
    (cd "$D" && bash run.sh test "$P") 2>&1 | sed 's/^/   /' | tee -a "$LOG" | grep -vE "^   == " | head -8
    grep -qE "tests, [0-9]+ failed" "$D/$P/test/RESULTS.txt" 2>/dev/null || { echo "   $P: tests did not run (see $D/$P/test/RESULTS.txt)"; stop=1; }
  done
  [ "$stop" = 1 ] && { echo "STOP: tests did not run (compile/dependency error above)"; return 1; }
  echo "== 6 broker run (bash run.sh e2e: camel run against the local Artemis)"
  if [ -z "${ARTEMIS_PASSWORD:-${BROKER_PASSWORD:-}}" ]; then
    echo "   skipped: export ARTEMIS_PASSWORD='...' first"
  else
    for P in $(ls -d "$D"/*/ | xargs -n1 basename | grep -Ex "($PROJECTS)"); do
      [ -f "$D/$P/run-local.sh" ] || continue
      (cd "$D" && BROKER_PASSWORD="${ARTEMIS_PASSWORD:-$BROKER_PASSWORD}" BROKER_USER="${ARTEMIS_USER:-artemis}" bash run.sh e2e "$P") 2>&1 | sed 's/^/   /'
    done
  fi
  echo "== 7 draft handover note"
  "$PY" "$SK/review_note.py" "$D" --projects "$PROJECTS" --modules "$WS/modules" -o "$D/REVIEW_HANDOVER_DRAFT.md"
  echo "== 8 archive"
  local inc=(Common-setup tools README.md run.sh set-env.sh); [ -f "$D/REVIEW_HANDOVER.md" ] && inc+=(REVIEW_HANDOVER.md) || inc+=(REVIEW_HANDOVER_DRAFT.md)   # the edited note wins
  for P in $(ls -d "$D"/*/ | xargs -n1 basename | grep -Ex "($PROJECTS)"); do inc+=("$P"); done
  local tgz; tgz="$(cd "$WS/delivery" && pwd)/${app}_review_${day}.tgz"
  (cd "$D" && tar czf "$tgz" --exclude=target --exclude=.camel-jbang --exclude=broker-run.log --exclude="counts-*.txt" "${inc[@]}") && echo "   $tgz ($(du -h "$tgz" | cut -f1))"
  if [ -f "$D/REVIEW_HANDOVER.md" ]; then echo "   archived your edited REVIEW_HANDOVER.md (compare with the new draft for changed numbers)"
  else echo "next: copy REVIEW_HANDOVER_DRAFT.md to REVIEW_HANDOVER.md in $D, edit it, rerun with REVIEW_TESTS=0, send the archive through the client's channel"; fi
}

# pi runs are slow and cost tokens: show the selection, and require ALL=1 for more than 10 flows
case "$STAGE" in research|tests|build|review|auto|functional)
  n=$(flows | wc -l | tr -d ' ')
  echo "selected: $n proxies (PROJECTS='${PROJECTS:-<all>}')"
  if [ "$n" -gt 10 ] && [ "${ALL:-0}" != 1 ] && [ -z "${BATCH_NO:-}" ]; then
    echo "more than 10 proxies for a pi stage: set PROJECTS='a-prj|b-prj' on the SAME line, or ALL=1 to run them all"; exit 2
  fi;;
esac

case "$STAGE" in
  list) flows | tee "$WS/domain/flows.txt" | awk '{print} END{print NR " proxies"}'
        projects > "$WS/domain/projects.txt"
        echo "$(wc -l < "$WS/domain/projects.txt" | tr -d ' ') projects -> domain/projects.txt, domain/flows.txt" ;;
  batches) np=$(BATCH_NO= projects | wc -l | tr -d ' '); nb=$(( (np + ${BATCH_SIZE:-10} - 1) / ${BATCH_SIZE:-10} ))
        echo "$np projects = $nb batches of ${BATCH_SIZE:-10} projects. Run them one after the other:"
        for b in $(seq 1 "$nb"); do echo "  BATCH_NO=$b bash $KIT/pi/run_domain.sh functional    # $(BATCH_NO=$b projects | paste -sd' ' - | cut -c1-90)"; done ;;
  coverage)
    [ -n "${SPLUNK_COVERAGE:-}" ] && [ -f "$SPLUNK_COVERAGE" ] || { echo "coverage needs SPLUNK_COVERAGE=<csv of the Splunk payload table>"; exit 2; }
    "$PY" "$KIT/skills/osb-to-camel/scripts/osb_inventory.py" "$APP" -o "$WS/domain/inventory" > /dev/null
    "$PY" "$(dirname "$BATCH")/domain_coverage.py" "$WS/domain/inventory" "$SPLUNK_COVERAGE" -o "$WS/domain/COVERAGE.md" ;;
  research) do_research; rc=$?; status; exit $rc ;;
  task1) do_task1; status ;;
  tests) do_tests; status ;;
  scaffold) do_scaffold; status ;;
  build) do_build; status ;;
  matrix) do_matrix; status ;;
  auto) do_research; do_task1; do_tests; status
        echo "functional test packs: modules/<project>/<proxy>/src/test + TEST_MATRIX.md; domain catalogue: domain/TEST_MATRIX.md" ;;
  estimate)
    [ -d "$WS/domain/inventory/flows" ] || "$PY" "$KIT/skills/osb-to-camel/scripts/osb_inventory.py" "$APP" -o "$WS/domain/inventory" > /dev/null
    "$PY" "$(dirname "$BATCH")/estimate_pi_load.py" "$WS/domain/inventory" "$APP" --coverage "$WS/domain/coverage.csv" \
      --timings "$WS/domain/timings.csv" --rpm "${PI_RPM:-20}" --tpm "${PI_TPM:-200000}" -o "$WS/domain/PI_LOAD_ESTIMATE.md" ;;
  time) "$PY" "$(dirname "$BATCH")/time_projection.py" "$WS/domain/timings.csv" --flows "${TOTAL_FLOWS:-450}" \
          --coverage "$WS/domain/coverage.csv" -o "$WS/domain/TIME_PROJECTION.md" ;;
  report) status > /dev/null; "$PY" "$SK/domain_report.py" "$WS" ;;
  review) do_review; rc=$?; status > /dev/null; exit $rc ;;
  delivery) "$PY" "$SK/assemble_jbang.py" "$WS" --osb-app "$APP" --app "$(basename "$APP")" ${PROJECTS:+--projects "$PROJECTS"} ;;
  flat) "$PY" "$SK/assemble_flat.py" "$WS" --app "$(basename "${APP:-osb-app}")" ${PROJECTS:+--projects "$PROJECTS"} ;;
  functional) do_research || { status > /dev/null; exit 75; }; do_task1; do_tests; do_build; do_matrix; status > /dev/null; "$PY" "$SK/domain_report.py" "$WS"
              "$PY" "$SK/assemble_flat.py" "$WS" --app "$(basename "${APP:-osb-app}")" ${PROJECTS:+--projects "$PROJECTS"} ;;
  status) status ;;
  *) echo "unknown stage: $STAGE"; exit 2 ;;
esac
KIT_EOF_PI_RUN_DOMAIN_SH
mkdir -p "$(dirname "pi/run_tests.sh")"
cat > 'pi/run_tests.sh' <<'KIT_EOF_PI_RUN_TESTS_SH'
#!/usr/bin/env bash
# Functional test creation for ONE proxy, no route needed: research pack + Splunk cases -> generated tests and mocks
# -> synthetic inputs for scenarios Splunk cannot supply (pi tester) -> frozen test pack + catalogue.
#
# Usage: pi/run_tests.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]
# Env:   OSB_SRC (OSB project folder: the tester reads the message schema there), OSB_PI_MODEL, KIT, PYTHON,
#        PI_TESTER=0 (skip the synthetic messages, e.g. when the model quota is short), PI_TESTER_THINKING (default low)
# Result: <module>/src/test/** (FlowParityTest + flow-test.json + real and synthetic case folders, frozen),
#         <module>/TEST_MATRIX.md (catalogue: every scenario, its inputs and expected outputs). Exit 1 if a scenario has no case.
set -euo pipefail
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done   # local settings, never in Git
MVN_ARGS=${MVN_ARGS//\~/$HOME}   # "~" inside a variable is not expanded by the shell
RES=${1:?usage: run_tests.sh <research-dir> <module-dir> <osb-project-name> [task1-dir]}
MOD=${2:?module dir}
PRJ=${3:?osb project name}
TASK1=${4:-}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$KIT/pi/pi_call.sh"
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
SK=$(for d in "$KIT/skills/osb-camelk-route" "$KIT/.pi/skills/osb-camelk-route"; do [ -d "$d" ] && echo "$d" && break; done)
[ -n "$SK" ] || { echo "skill osb-camelk-route not found under $KIT"; exit 1; }
[ -s "$RES/research.json" ] || { echo "missing $RES/research.json: run pi/run_research.sh first"; exit 1; }

echo "== 1 generated tests + mocks (script)"
"$PY" "$SK/scripts/scaffold_camelk.py" "$RES" -o "$MOD" --project "$PRJ" ${TASK1:+--parity "$TASK1/fixtures/parity"} ${REFRESH:+--refresh "$REFRESH"}

echo "== 2 synthetic inputs where Splunk has none (script from the schema first, pi tester only for the rest)"
LOG="$MOD/.agent-logs"; mkdir -p "$LOG"
"$PY" "$SK/scripts/check_camelk.py" "$MOD" --no-surefire > /dev/null || true
UNCOV=$("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1]))['gates']['K9_scenarios_covered']['uncovered']))" "$MOD/GATES.json")
if [ "$UNCOV" != 0 ] && [ -n "${OSB_SRC:-}" ] && [ -d "$OSB_SRC" ]; then
  # first without an AI: fake-value messages built from the flow's schema (no model calls, no quota)
  "$PY" "$SK/scripts/synth_from_schema.py" "$MOD" "$OSB_SRC" --research "$RES/research.json" || true
  "$PY" "$SK/scripts/check_camelk.py" "$MOD" --no-surefire > /dev/null || true
  UNCOV=$("$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1]))['gates']['K9_scenarios_covered']['uncovered']))" "$MOD/GATES.json")
fi
if [ "$UNCOV" != 0 ] && [ "${PI_TESTER:-1}" = 0 ]; then
  echo "   PI_TESTER=0: $UNCOV scenario(s) stay without a test case (gate K9 shows them)"
elif [ "$UNCOV" != 0 ]; then
  PT=(pi --print --no-session --thinking "${PI_TESTER_THINKING:-low}" --tools "read,bash,write" --append-system-prompt "$KIT/agents/tester-camelk.md")
  [ -n "${OSB_PI_MODEL:-}" ] && PT+=(--model "$OSB_PI_MODEL")
  REPLY_TASK=""
  if "$PY" -c "import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if 'reply' in c.get('outputs',{}) and c.get('backends') else 1)" "$MOD/src/test/resources/flow-test.json"; then
    # request/reply with HTTP calls: the reply body must be tested (gate K12), so the case needs the backend's answer and
    # the reply OSB would build from it
    REPLY_TASK=" This flow answers the caller and calls backend(s) $("$PY" -c "import json,sys; print(', '.join(json.load(open(sys.argv[1]))['backends']))" "$MOD/src/test/resources/flow-test.json"). For each backend write $MOD/src/test/resources/stubs/<backend>.json: the backend's answer with FAKE values, ONLY fields that research.json names (transforms[].mappings[].from, backends[].response_use); include at least one record that matches every filter the transforms use (e.g. a status the reply selects) and one that does not. For each case write expected-output.json next to input.payload: the reply as research.json transforms build it from that stub, field by field (apply every rule: renames, date reformat, value mapping). Gate K12 checks it."
  fi
  pi_call "$LOG/tester.out" "$LOG/tester.err" "${PT[@]}" "Module: $MOD. Research: $RES/RESEARCH.md and $RES/research.json. ${OSB_SRC:+OSB source (read only, for the message schema): $OSB_SRC.} Write synthetic case folders for the $UNCOV scenario_mapping rows of $MOD/src/test/resources/flow-test.json that have no case yet (check: $PY $SK/scripts/check_camelk.py $MOD --no-surefire, gates K9 and K12). Fake values only.$REPLY_TASK Write nothing outside $MOD/src/test/resources/parity and $MOD/src/test/resources/stubs." || true
else
  echo "   every scenario already has a real Splunk case"
fi

echo "== 3 freeze + catalogue"
"$PY" "$SK/scripts/scaffold_camelk.py" "$RES" -o "$MOD" --project "$PRJ" --freeze-synthetic
"$PY" "$SK/scripts/check_camelk.py" "$MOD" --no-surefire > /dev/null || true
"$PY" "$SK/scripts/test_matrix.py" "$MOD" > /dev/null || true
"$PY" - "$MOD" <<'PY'
import json, sys
from pathlib import Path
m = Path(sys.argv[1]); par = m / "src/test/resources/parity"
real = sum(1 for p in par.glob("*/*/*/input.payload") if "-synthetic" not in p.parts[-4])
syn = sum(1 for p in par.glob("*-synthetic/*/*/input.payload"))
g = json.loads((m / "GATES.json").read_text())["gates"]["K9_scenarios_covered"]
cfg = json.loads((m / "src/test/resources/flow-test.json").read_text())
print(json.dumps({"scenarios": len(cfg["scenario_mapping"]), "real_cases": real, "synthetic_cases": syn,
                  "uncovered": g["uncovered"], "outputs": sorted(cfg["outputs"]), "catalogue": str(m / "TEST_MATRIX.md")}))
sys.exit(0 if g["ok"] else 1)
PY
KIT_EOF_PI_RUN_TESTS_SH
mkdir -p "$(dirname "pi/pi_call.sh")"
cat > 'pi/pi_call.sh' <<'KIT_EOF_PI_PI_CALL_SH'
#!/usr/bin/env bash
# Sourced by the pi runners. pi_call <out-file> <err-file> <pi args...>
# Runs pi; when the model endpoint answers 429 / rate limit / overloaded, waits and retries with a growing pause.
# Env: PI_RETRIES (default 5), PI_BACKOFF (first pause in seconds, default 60, doubled each time, max 15 min).
# Exit 75 when the endpoint still refuses after all retries (quota used up): the runners stop instead of moving on.
# PI_TIMEOUT (seconds, default 1800): a single pi run that takes longer is killed (a hanging call never returns);
# exit 124 = timed out.
pi_call() {   # every FLOW_CARD.md is a person's decision: pi may read it, any change it makes is undone
  local guard c b rc
  guard=$(mktemp -d 2>/dev/null || { mkdir -p "${TMPDIR:-/tmp}/picards.$$" && echo "${TMPDIR:-/tmp}/picards.$$"; })
  for c in "${WS:-.}"/modules/*/*/FLOW_CARD.md; do [ -f "$c" ] && cp "$c" "$guard/$(printf '%s' "$c" | tr '/: ' '___')"; done
  _pi_call_inner "$@"; rc=$?
  for c in "${WS:-.}"/modules/*/*/FLOW_CARD.md; do
    b="$guard/$(printf '%s' "$c" | tr '/: ' '___')"
    if [ -f "$b" ] && ! cmp -s "$b" "$c"; then
      cp "$b" "$c"; echo "   pi changed $c: change undone (only a person edits a flow card)"
      [ -n "${WS:-}" ] && echo "$(date '+%F %T') card restored: $c" >> "$WS/domain/card-guard.log" 2>/dev/null
    fi
  done
  rm -rf "${guard:?}"
  return $rc
}

_pi_call_inner() {
  local out=$1 err=$2; shift 2
  local n=0 wait=${PI_BACKOFF:-60}
  while :; do
    if command -v timeout >/dev/null 2>&1; then
      timeout --kill-after=30 "${PI_TIMEOUT:-1800}" "$@" > "$out" 2> "$err"
      local rc=$?
      [ $rc = 0 ] && return 0
      if [ $rc = 124 ] || [ $rc = 137 ]; then
        echo "   pi did not finish within ${PI_TIMEOUT:-1800}s (hanging call), stopped it"; return 124
      fi
    else   # no `timeout` (macOS): a watchdog kills the run after PI_TIMEOUT
      "$@" > "$out" 2> "$err" & local pid=$!
      rm -f "$err.timeout"
      ( sleep "${PI_TIMEOUT:-1800}"; kill -0 "$pid" 2>/dev/null || exit 0; touch "$err.timeout"; kill -TERM "$pid" 2>/dev/null
        sleep 30; kill -KILL "$pid" 2>/dev/null ) &
      local dog=$!
      wait "$pid"; local rc=$?
      kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
      [ $rc = 0 ] && return 0
      if [ -f "$err.timeout" ]; then
        rm -f "$err.timeout"; echo "   pi did not finish within ${PI_TIMEOUT:-1800}s (hanging call), stopped it"; return 124
      fi
    fi
    if grep -qiE '(^|[^0-9])429([^0-9]|$)|too many requests|rate.?limit|overloaded|503 service unavailable' "$err" 2>/dev/null \
       && [ "$n" -lt "${PI_RETRIES:-5}" ]; then
      n=$((n + 1))
      echo "   model endpoint busy (rate limit), waiting ${wait}s, retry $n/${PI_RETRIES:-5}"
      sleep "$wait"
      [ -n "${PI_WAIT_FILE:-}" ] && echo "$wait" >> "$PI_WAIT_FILE"     # rate-limit waiting, measured separately
      wait=$((wait * 2)); [ "$wait" -gt 900 ] && wait=900
      continue
    fi
    if grep -qiE '(^|[^0-9])429([^0-9]|$)|too many requests|rate.?limit|overloaded' "$err" 2>/dev/null; then
      echo "   model endpoint still refuses after ${PI_RETRIES:-5} retries: quota used up? stopping (exit 75)"
      return 75
    fi
    return 1
  done
}
KIT_EOF_PI_PI_CALL_SH
mkdir -p "$(dirname "pi/run_research.sh")"
cat > 'pi/run_research.sh' <<'KIT_EOF_PI_RUN_RESEARCH_SH'
#!/usr/bin/env bash
# Research pack for ONE proxy on the pi coding agent: facts (script) -> questionnaire (pi) -> share check (script).
# The OSB source never leaves the machine; only research/<proxy>/ is shared, and only after the check passes.
#
# Usage: pi/run_research.sh <osb-project-dir> <proxy> [task1-dir]
# Env:   OUT (default research/<proxy>; run_domain.sh uses research/<project>/<proxy>), OSB_PI_MODEL (model pattern for
#        `pi --model`), PI_THINKING (default high), KIT, PYTHON
set -euo pipefail
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done   # local settings, never in Git
MVN_ARGS=${MVN_ARGS//\~/$HOME}   # "~" inside a variable is not expanded by the shell
PROJECT=${1:?usage: run_research.sh <osb-project-dir> <proxy> [task1-dir]}
PROXY=${2:?proxy name}
TASK1=${3:-}
case "$PROJECT" in *\\*|[A-Za-z]:*) command -v cygpath >/dev/null && PROJECT=$(cygpath -u "$PROJECT");; esac   # Windows path (quoted) -> /e/...
case "$PROXY" in */*|*\\*) echo "2nd argument must be the proxy name (e.g. sample-adjustment), not a path. usage: run_research.sh <osb-project-dir> <proxy> [task1-dir]"; exit 2;; esac
[ -e "$PROJECT" ] || { echo "OSB project not found: $PROJECT  (Git Bash: write /e/folder/project, not E:\\folder\\project)"; exit 2; }
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
. "$KIT/pi/pi_call.sh"
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
OUT=${OUT:-research/$PROXY}
LOG="$OUT/agent-logs"
skill_dir() { if [ -d "$KIT/skills/$1" ]; then echo "$KIT/skills/$1"; elif [ -d "$KIT/.pi/skills/$1" ]; then echo "$KIT/.pi/skills/$1"; fi; }
SK=$(skill_dir osb-research); [ -n "$SK" ] || { echo "skill osb-research not found under $KIT"; exit 1; }
mkdir -p "$LOG"

echo "== 1 facts"
"$PY" "$SK/scripts/research_pack.py" "$PROJECT" "$PROXY" -o "$OUT" ${TASK1:+--scenarios "$TASK1/traces/scenarios.json"}

SHA=$(command -v sha1sum || command -v shasum)
fp() { find "$1" -type f -print0 | sort -z | xargs -0 "$SHA" 2>/dev/null | "$SHA" | cut -c1-16; }
before=$(fp "$PROJECT")

# all source files of this proxy in ONE file, so pi reads them with one call instead of one call per file (rate limit);
# it lies next to (not inside) the shareable folder and is deleted after the research
BUNDLE="$OUT.sources.txt"
while IFS= read -r f; do [ -n "$f" ] && [ -f "$PROJECT/$f" ] && { printf '\n===== FILE: %s =====\n' "$f"; cat "$PROJECT/$f"; }; done < "$OUT/SOURCES.txt" > "$BUNDLE"
trap 'rm -f "$BUNDLE"' EXIT

echo "== 2 questionnaire (pi)"
PI=(pi --print --no-session --thinking "${PI_THINKING:-high}" --skill "$SK" --tools "read,bash,write"
    --append-system-prompt "$KIT/agents/researcher.md")
[ -n "${OSB_PI_MODEL:-}" ] && PI+=(--model "$OSB_PI_MODEL")
rc=0; pi_call "$LOG/research.out" "$LOG/research.err" "${PI[@]}" "Use skill osb-research. OSB export: $PROJECT. Proxy: $PROXY. Today is $(date +%F). facts.json and SOURCES.txt are already in $OUT (step 1 done). All files of SOURCES.txt are concatenated in $BUNDLE: read that ONE file first (one read instead of one per file); open other files only for references it does not contain. Do steps 2-5: read the sources, answer every question of references/questions.md into $OUT/RESEARCH.md (assets/RESEARCH_TEMPLATE.md) and $OUT/research.json (assets/research.schema.json), run '$PY $SK/scripts/research_check.py $OUT' until it prints PASS. Write nothing outside $OUT." || rc=$?
[ "$rc" = 75 ] && exit 75
for try in 2; do   # pi sometimes ends without writing the files: one more attempt, logs kept per attempt
  [ -s "$OUT/RESEARCH.md" ] && [ -s "$OUT/research.json" ] && break
  echo "   pi wrote no answer files, attempt $try (see $LOG/research.err)"
  cp "$LOG/research.err" "$LOG/research.attempt1.err" 2>/dev/null || true
  pi_call "$LOG/research.out" "$LOG/research.err" "${PI[@]}" "Use skill osb-research. A previous attempt ended without writing RESEARCH.md and research.json: write both files. OSB export: $PROJECT. Proxy: $PROXY. Today is $(date +%F). facts.json and SOURCES.txt are already in $OUT (step 1 done). All files of SOURCES.txt are concatenated in $BUNDLE: read that ONE file first (one read instead of one per file); open other files only for references it does not contain. Do steps 2-5: read the sources, answer every question of references/questions.md into $OUT/RESEARCH.md (assets/RESEARCH_TEMPLATE.md) and $OUT/research.json (assets/research.schema.json), run '$PY $SK/scripts/research_check.py $OUT' until it prints PASS. Write nothing outside $OUT." || true
done

[ "$(fp "$PROJECT")" = "$before" ] || { echo "VIOLATION: the OSB export was changed during research"; exit 1; }

echo "== 3 share check"
for f in RESEARCH.md research.json; do [ -s "$OUT/$f" ] || { echo "missing $OUT/$f (see $LOG/research.err)"; exit 1; }; done
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); m=[k for k in ('proxy','entry','branches','outputs','transforms','backends','errors','logs','open_questions') if k not in d]; sys.exit('research.json misses: '+', '.join(m) if m else 0)" "$OUT/research.json"
rm -rf "$OUT.agent-logs"; mv "$LOG" "$OUT.agent-logs"     # agent logs may quote source: they stay on the machine, outside the shared folder
"$PY" "$SK/scripts/research_check.py" "$OUT" || { echo "NOT shareable yet: fix the lines above (logs: $OUT.agent-logs)"; exit 1; }
echo "share: $OUT/RESEARCH.md research.json facts.json SHARE_CHECK.json"
KIT_EOF_PI_RUN_RESEARCH_SH
mkdir -p "$(dirname "pi/preflight.sh")"
cat > 'pi/preflight.sh' <<'KIT_EOF_PI_PREFLIGHT_SH'
#!/usr/bin/env bash
# Preflight for the client VDI: checks everything the kit needs before the first run.
# Runs in Git Bash (Windows), WSL or Linux. Read-only: installs nothing, changes nothing.
# Usage: pi/preflight.sh [model-endpoint-url]
set -u
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done   # local settings, never in Git
ok=0; warn=0; fail=0
pass() { printf '  [ OK ] %s\n' "$1"; ok=$((ok+1)); }
wrn()  { printf '  [WARN] %s\n' "$1"; warn=$((warn+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # $1 >= $2

echo "OS: $(uname -s 2>/dev/null) $(uname -r 2>/dev/null)"

echo "Agent"
if command -v node >/dev/null; then
  v=$(node -v | tr -d v); ver_ge "$v" 22.19.0 && pass "node $v" || bad "node $v < 22.19 (pi requirement)"
else bad "node not found (pi needs Node.js 22.19+)"; fi
if command -v pi >/dev/null; then pass "pi $(pi --version 2>/dev/null | head -1)"; else bad "pi not found"; fi
[ -n "${OSB_PI_MODEL:-}" ] && pass "OSB_PI_MODEL=$OSB_PI_MODEL" || wrn "OSB_PI_MODEL unset: pi uses its default model"
for f in "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json" "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/auth.json"; do
  [ -f "$f" ] && pass "found $f" || wrn "no $f (needed for a custom endpoint or stored login)"
done
[ "${PI_OFFLINE:-}" ] && pass "PI_OFFLINE set (no catalog/network calls)" || wrn "PI_OFFLINE unset: pi may call pi.dev (catalog, version check)"
[ "${PI_TELEMETRY:-}" = "0" ] && pass "PI_TELEMETRY=0" || wrn "PI_TELEMETRY not 0"
if [ -n "${1:-}" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo 000)
  [ "$code" != "000" ] && pass "model endpoint reachable ($1 → HTTP $code)" || bad "model endpoint not reachable: $1"
fi

echo "Shell tools"
command -v bash >/dev/null && pass "bash $(bash --version | head -1 | awk '{print $4}')" || bad "bash missing (Git for Windows provides it)"
command -v sha1sum >/dev/null || command -v shasum >/dev/null && pass "sha1sum/shasum" || bad "no sha1sum/shasum"
PY=$(command -v python3 || command -v python || command -v py)
if [ -n "$PY" ]; then v=$("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])'); ver_ge "$v" 3.10 && pass "python $v ($PY)" || bad "python $v < 3.10"
else bad "python not found"; fi
command -v git >/dev/null && pass "git" || wrn "git missing (lane checks still work, CI guard needs git)"
command -v timeout >/dev/null && pass "timeout (a hanging pi call is stopped after PI_TIMEOUT, default 1800 s)" || wrn "no 'timeout' command: a hanging pi call is not stopped automatically"

echo "Build and test"
if command -v java >/dev/null; then
  v=$(java -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/'); [ "$v" -ge 21 ] 2>/dev/null && pass "java $v" || bad "java $v < 21"
else bad "java not found (JDK 21)"; fi
if command -v mvn >/dev/null; then pass "maven $(mvn -v 2>/dev/null | head -1 | awk '{print $3}')"
  [ -f "$HOME/.m2/settings.xml" ] && pass "~/.m2/settings.xml present (mirror/proxy)" || wrn "no ~/.m2/settings.xml: Maven will try Maven Central directly"
else bad "maven not found"; fi
if docker info >/dev/null 2>&1; then pass "docker"; elif podman info >/dev/null 2>&1; then pass "podman"
else printf '  [INFO] no Docker/Podman: not needed (functional tests use mocks; Artemis tests run later on the Dev environment)\n'; fi

echo "Kit layout (run from the migration repository root)"
for p in AGENTS.md agents/analyst.md tools/verify_flow.sh pi/run_flow.sh; do [ -e "$p" ] && pass "$p" || bad "$p missing"; done
sk=0; for d in .pi/skills "$HOME/.pi/agent/skills" .agents/skills skills; do [ -f "$d/osb-to-camel/SKILL.md" ] && sk=1; done
[ $sk = 1 ] && pass "skill osb-to-camel discoverable" || bad "skill osb-to-camel not in .pi/skills, ~/.pi/agent/skills or .agents/skills"
sr=0; for d in .pi/skills "$HOME/.pi/agent/skills" .agents/skills skills; do [ -f "$d/osb-research/SKILL.md" ] && sr=1; done
[ $sr = 1 ] && pass "skill osb-research discoverable" || bad "skill osb-research not found (needed for research packs: pi/run_research.sh)"
# Maven build of Camel K modules: Maven 3.6.3+ on Java 17+ (VDI default is Maven 3.5.3 on JDK 1.7)
if command -v mvn >/dev/null; then
  mv=$(mvn -v 2>/dev/null | tr -d '\033' | sed -n 's/.*Apache Maven \([0-9.]*\).*/\1/p' | head -1)
  jv=$(mvn -v 2>/dev/null | sed -n 's/^Java version: \([0-9]*\).*/\1/p' | head -1); [ "$jv" = 1 ] && jv=$(mvn -v | sed -n 's/^Java version: 1\.\([0-9]*\).*/\1/p')
  printf '%s\n3.6.3\n' "$mv" | sort -V -C 2>/dev/null && bad "Maven $mv too old for the test plugins (need 3.6.3+: Maven 3.9.9 from Nexus, see DOMAIN_RUN.md)" || pass "Maven $mv"
  [ "${jv:-0}" -ge 17 ] 2>/dev/null && pass "Maven runs on Java $jv" || bad "Maven runs on Java ${jv:-?} (need 17+: export JAVA_HOME to the JDK 21 folder)"
fi
sc=0; for d in .pi/skills "$HOME/.pi/agent/skills" .agents/skills skills; do [ -f "$d/osb-camelk-route/SKILL.md" ] && sc=1; done
[ $sc = 1 ] && pass "skill osb-camelk-route discoverable" || bad "skill osb-camelk-route not found (needed for pi/run_camelk.sh, pi/run_domain.sh)"
# pi skips a SKILL.md whose front matter is not valid YAML, without an error: check the usual traps
for f in .pi/skills/*/SKILL.md "$HOME/.pi/agent/skills"/*/SKILL.md .agents/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  issue=$(awk 'NR==1 && $0!="---"{print "no front matter"; exit} NR>1 && $0=="---"{exit}
               NR>1 && /^[A-Za-z_-]+: /{v=$0; sub(/^[A-Za-z_-]+: /,"",v);
                 if (v ~ /^["\x27]/) next;
                 if (index(v,": ")) {print "unquoted \": \" in " $1; exit}
                 if (index(v," #")) {print "unquoted \" #\" in " $1; exit}
                 if (length(v)>1024 && $1=="description:") {print "description over 1024 characters"; exit}}' "$f")
  [ -z "$issue" ] && pass "front matter valid: $f" || bad "pi will skip $f: $issue"
done
# /osb-* commands: pi reads prompt templates from .pi/prompts (project, after trust) or ~/.pi/agent/prompts
pd=""; for d in .pi/prompts "$HOME/.pi/agent/prompts"; do
  m=0; for n in osb-analyse osb-implement osb-test osb-verify osb-review; do [ -f "$d/$n.md" ] || m=$((m+1)); done
  [ $m -eq 0 ] && { pd=$d; break; }
done
if [ -n "$pd" ]; then pass "/osb-* commands found in $pd"
  [ "$pd" = .pi/prompts ] && printf '  [INFO] .pi/ loads only for a trusted project: trust it at the first pi start, or run pi --approve\n'
else bad "/osb-* commands missing: run  mkdir -p .pi/prompts && cp pi/prompts/*.md .pi/prompts/  (pi/prompts is the kit copy, pi does not read it)"; fi
[ -d osb-src ] && [ -n "$(ls -A osb-src 2>/dev/null)" ] && pass "osb-src/ has content" || wrn "osb-src/ empty: put the OSB export there"

echo; echo "Result: $ok ok, $warn warnings, $fail failures"
[ $fail -eq 0 ]
KIT_EOF_PI_PREFLIGHT_SH
mkdir -p "$(dirname "AGENTS.md")"
cat > 'AGENTS.md' <<'KIT_EOF_AGENTS_MD'
# AGENTS.md: OSB → Camel migration repository (client programme)

Every AI agent working in this repository follows these rules. Role prompts in `agents/` add duties per phase.

## What this repository is

Camel K integrations (YAML DSL) that replace Oracle Service Bus flows: one module per OSB proxy under
`modules/<project>/<proxy>/` (route `*.camel.yaml` + helper beans + L1 tests). Source of truth for behaviour = the OSB export under `osb-src/` (read-only).

## Workflow (never skip a step)

1. **Check first:** search this repository for the proxy name, its queues/topics/URLs and XQuery file names. If a
   route already exists, compare and report; do not generate a second one.
2. **Research** with skill `osb-research` → `research/<project>/<proxy>/` (shareable pack, check PASS).
3. **Card + tests** with skill `osb-camelk-route` Step 1 → `modules/<project>/<proxy>/FLOW_CARD.md` + generated tests.
4. **Stop for approval.** No code for a card without `Status: approved` and an approver name.
5. **Generate the delivery** with `osb-camelk-route` ("Delivery": `pi/run_domain.sh delivery|review`); implement by hand
   (`osb-camelk-route` Steps 3–5) only for flows BODY_CHAIN.md marks as not generated.
6. **Verify:** `check_camelk.py modules/<project>/<proxy>` must print PASS (K1–K8).
7. **Record:** `modules/<project>/<proxy>/MIGRATION_NOTES.md` with the four sections: Original OSB behaviour / Camel
   implementation / Behavioural differences / Items requiring human validation.

## Hard rules

- Inputs are files from `osb-src/`. Never build code from screenshots, chat text or memory of "how OSB usually works".
- Runtime (decision 2026-10-14): **Camel K, routes in YAML DSL** (`*.camel.yaml`), Camel 4.18.4 = Camel Quarkus 3.33.3
  (`camel.runtime-version=3.33.3`), small Java helper beans next to the YAML, tests with `camel-test-main-junit5` +
  mock endpoints. Pattern: `pilot/sample-adjustment`, skill `osb-camelk-route`. Older Spring Boot templates in
  `osb-to-camel/assets` are reference only.
- Messaging: Red Hat AMQ Broker, AMQP 1.0 on port 5672, `camel-amqp` (Qpid JMS) with a failover URI. Destinations
  exist only through the Git register; never rely on auto-create. A WebLogic durable topic subscription becomes a
  named subscription queue with a broker-side filter, consumed by FQQN `<address>::<subscription>`.
- JMS: local transacted sessions; duplicate-ID header on every send; consumers idempotent.
- Every endpoint, queue name, timeout and retry value is a `{{placeholder}}`; no host names, ports or credentials in
  code, tests or `application.yml`. Credentials come from Vault at runtime.
- Keep original XQuery/XSLT files and their behaviour (quirks included) unless the card approves a change. Never
  rewrite a working transform into Java "because it is cleaner".
- Logging: stdout, correlation id in every line, no full payloads above DEBUG, mask personal data (SIN, national ID).
- Component options: Camel MCP if connected, else `skills/osb-to-camel/references/versions.md` + Camel docs for that
  version. Do not guess options.
- **Test oracle:** expected outputs come from OSB (recordings, the original transform run on Saxon, the OSB test
  console). Never generate an expected file by running the new Camel code.
- Never delete, skip or weaken a test to get green. A skipped test needs a reason in the record.
- Never claim equivalence. Report gate results and test evidence; humans decide.

## Commands

| Purpose | Command |
|---|---|
| Research pack (source stays, knowledge travels) | `pi/run_research.sh osb-src/<project> <proxy> [task1-dir]` → `research/<proxy>/` (shared only after `research_check.py` PASS) |
| All proxies of one OSB application | `pi/run_domain.sh <osb-app-dir> <stage>` (stages: list, research, scaffold, build, status) → `domain/STATUS.md` |
| Functional tests only (no route) | `pi/run_tests.sh research/<project>/<proxy> modules/<project>/<proxy> <project> [task1-dir]` |
| Research pack → Camel K module + tests | `pi/run_camelk.sh research/<project>/<proxy> modules/<project>/<proxy> <project> [task1-dir]` (stops until the card is approved) |
| Gates of a Camel K module | `python3 skills/osb-camelk-route/scripts/check_camelk.py modules/<project>/<proxy>` (K1-K8) |
| Inventory an export | `python3 skills/osb-to-camel/scripts/osb_inventory.py osb-src/<project> -o migration/osb-inventory` |
| Scaffold a card | `python3 skills/osb-to-camel/scripts/scaffold_flow.py migration/osb-inventory/flows/<flow>.json -o migration/<flow>/` |
| Build + tests | `mvn -q -f <module>/pom.xml verify` |
| All gates | `tools/verify_flow.sh <module> <flow>` |

## Definition of done (per flow)

Card approved · gates K1–K8 PASS in `GATES.json` · `MIGRATION_NOTES.md` written · reviewer report with no open BLOCKER ·
human sign-off · shadow run passed (TESTING.md L6) before cut-over.
KIT_EOF_AGENTS_MD
mkdir -p "$(dirname ".pi/prompts/osb-camelk.md")"
cat > '.pi/prompts/osb-camelk.md' <<'KIT_EOF__PI_PROMPTS_OSB_CAMELK_MD'
---
description: "Approved flow card + research pack -> Camel K YAML route + tests, until the gates pass"
argument-hint: "<module-dir> <research-dir>"
---
Act as the implementer defined in agents/implementer-camelk.md and follow AGENTS.md.
Use skill osb-camelk-route on module $1 (approved card $1/FLOW_CARD.md) with research pack $2.
Do steps 3-6 of the skill until check_camelk.py prints PASS, then give the five-line report.
KIT_EOF__PI_PROMPTS_OSB_CAMELK_MD
mkdir -p "$(dirname ".pi/skills/osb-research/references/questions.md")"
cat > '.pi/skills/osb-research/references/questions.md' <<'KIT_EOF__PI_SKILLS_OSB_RESEARCH_REFERENCES_QUESTIONS_MD'
# Research questionnaire (one proxy)

Answer every question. Evidence column: file (relative path) + stage/action name. `UNKNOWN` + open question if the
source does not say. No code, no hosts, no data (see SKILL.md rules).

| # | Question | Answer as |
|---|---|---|
| Q1 | **Entry.** Transport, destination name, queue or topic, durable subscription and its name, message selector (verbatim, it is configuration), message type (text/bytes/XML/JSON), encoding, XA, response required, concurrency/dispatch policy | table |
| Q2 | **Message format.** What arrives (JSON or XML; root element or top-level keys), is there an nXSD/JSON-to-XML translation (which one, is the file in the export), what `$body` contains after it | short text + field list |
| Q3 | **Flow overview.** The pipeline in order: stage → action type → what it does in one sentence. Include route nodes, branches, publish, service callouts, Java callouts, reply/resume | numbered list |
| Q4 | **Branches.** For each branch/if-then: condition in plain words, the condition expression (one line), which values lead to which path, what happens on each path, default path | table per branch |
| Q5 | **Scenario mapping.** Branches decide on payload fields: list those fields in `scenario_dims` exactly as the condition finds them: a condition with `//*:name` (any depth, the usual OSB form) becomes `//name`; only a condition that spells a full path (`$body/*:a/*:b`) becomes the path `a.b` (check it against the nXSD/XSD element nesting). Never invent a path the source does not show. Then give one `scenario_mapping` row per combination of their values with the outputs reached, as `k=v|k!=v` (k = last path segment; `k!=true` also covers a missing field; first matching row wins; outputs = business service names, `[]` = consumed, nothing sent). A flow without branches has one row with scenario `*` (every message). Never answer "depends on the message": that is what the row must spell out. Then say which `log_scenarios` in `facts.json` show those fields; if none do, write `rerun task 1 with SCENARIO_DIMS=...,body:<path>` in open questions | table |
| Q6 | **Outputs.** Request-response proxies (HTTP, local, SOAP): the answer to the caller is an output named `reply` (use it in branches and scenario_mapping). Name each other output after the business service that writes it (the same name in branches, scenario_mapping and backends). Every destination the flow writes to (business service → queue/topic/HTTP path/operation): on which path, which body (built by which transform), which JMS properties / transport headers / HTTP headers are set and from where | table |
| Q7 | **Transforms.** For each XQuery/XSLT/assign/replace that builds a message: purpose, inputs (external params), output root, field mapping `source path → target path → rule` (copy, constant, format, lookup, condition), fn-bea functions used, constants | table per transform |
| Q8 | **Backends.** Each business service / service callout: type, operation, when it is called, request built from, how the response is used, retry count/interval, timeout, load balancing, result caching, what happens on fault | table |
| Q9 | **Errors.** Each error handler scope (stage, pipeline, service): what it catches, what it logs, where the message goes (error queue, reply, resume, re-raise), headers/fields set (errorCode, errorMessage, traceId ...), redelivery/retry behaviour of the transport | table |
| Q10 | **Logging.** Say explicitly when a Log action logs the OUTGOING body (e.g. "... for BS x to be posted ... ::$body"): that logged body is OSB's own output and becomes the expected result of the tests. Each Log action: stage, level, the message template with placeholders (e.g. `Request Received to Project {project} :: for PS {proxy} ... TraceID - {uuid} ::{body}`), what `{...}` are | table |
| Q11 | **Dependencies.** Shared resources from other projects, DVM lookups (name, columns used), Java callouts (class, method, what for), customisation/env properties used (names only), alerts, reporting, throttling, SLA | table |
| Q12 | **Open questions.** Everything UNKNOWN, ambiguous or missing from the export, each with why it matters for the migration | numbered list |
KIT_EOF__PI_SKILLS_OSB_RESEARCH_REFERENCES_QUESTIONS_MD
mkdir -p "$(dirname ".pi/skills/osb-research/assets/RESEARCH_TEMPLATE.md")"
cat > '.pi/skills/osb-research/assets/RESEARCH_TEMPLATE.md' <<'KIT_EOF__PI_SKILLS_OSB_RESEARCH_ASSETS_RESEARCH_TEMPLATE_MD'
# Research — <proxy>

| | |
|---|---|
| **Proxy** | <proxy> |
| **Project** | <project> |
| **Export version** | <branch / tag / commit or export date> |
| **Researched by / on** | pi osb-research / <date> |
| **Tier (facts.json)** | <tier> |
| **Check** | see SHARE_CHECK.json |

## Q1 Entry
| Item | Value | Evidence |
|---|---|---|

## Q2 Message format

## Q3 Flow overview
1.

## Q4 Branches
### Branch <name>
| Path | Condition (plain) | Expression | Actions | Evidence |
|---|---|---|---|---|

## Q5 Scenario mapping
Fields the branches decide on (`scenario_dims`): ...

| Scenario (k=v / k!=v) | Outputs (business services, or none) | Branch / path | Log scenarios showing it | Evidence |
|---|---|---|---|---|

## Q6 Outputs
| Business service | Destination | Path / branch | Body built by | Headers / properties set (name ← source) | Evidence |
|---|---|---|---|---|---|

## Q7 Transforms
### <transform>
Purpose: … Inputs: … Output root: … fn-bea: …
| Source path | Target path | Rule | Evidence |
|---|---|---|---|

## Q8 Backends
| Service | Type / operation | Called when | Request from | Response used for | Retry / timeout | On fault | Evidence |
|---|---|---|---|---|---|---|---|

## Q9 Errors
| Scope | Catches | Logs | Goes to | Headers / fields set | Redelivery | Evidence |
|---|---|---|---|---|---|---|

## Q10 Logging
| Stage | Level | Template | Placeholders | Evidence |
|---|---|---|---|---|

## Q11 Dependencies
| Kind | Name | Used for | In export? | Evidence |
|---|---|---|---|---|

## Q12 Open questions
1.
KIT_EOF__PI_SKILLS_OSB_RESEARCH_ASSETS_RESEARCH_TEMPLATE_MD
mkdir -p "$(dirname ".pi/skills/osb-research/assets/research.schema.json")"
cat > '.pi/skills/osb-research/assets/research.schema.json' <<'KIT_EOF__PI_SKILLS_OSB_RESEARCH_ASSETS_RESEARCH_SCHEMA_JSON'
{
  "$comment": "Machine-readable twin of RESEARCH.md. Same content, no code, no hosts, no data.",
  "type": "object",
  "required": [
    "proxy",
    "entry",
    "branches",
    "outputs",
    "transforms",
    "backends",
    "errors",
    "logs",
    "open_questions"
  ],
  "properties": {
    "proxy": {
      "type": "string"
    },
    "project": {
      "type": "string"
    },
    "export_version": {
      "type": "string"
    },
    "entry": {
      "type": "object",
      "properties": {
        "transport": {
          "type": "string"
        },
        "destination": {
          "type": "string"
        },
        "is_topic": {
          "type": "boolean"
        },
        "durable_subscription": {
          "type": "string"
        },
        "selector": {
          "type": "string"
        },
        "message_type": {
          "type": "string"
        },
        "payload_format": {
          "enum": [
            "json",
            "xml",
            "text",
            "binary",
            "UNKNOWN"
          ]
        },
        "nxsd": {
          "type": "string"
        }
      }
    },
    "branches": {
      "type": "array",
      "items": {
        "type": "object",
        "required": [
          "name",
          "paths"
        ],
        "properties": {
          "name": {
            "type": "string"
          },
          "stage": {
            "type": "string"
          },
          "paths": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "label": {
                  "type": "string"
                },
                "condition_plain": {
                  "type": "string"
                },
                "condition_expr": {
                  "type": "string"
                },
                "actions": {
                  "type": "array",
                  "items": {
                    "type": "string"
                  }
                },
                "outputs": {
                  "type": "array",
                  "items": {
                    "type": "string"
                  }
                }
              }
            }
          }
        }
      }
    },
    "scenario_mapping": {
      "type": "array",
      "items": {
        "type": "object",
        "required": [
          "scenario",
          "outputs"
        ],
        "properties": {
          "scenario": {
            "type": "string",
            "description": "k=v|k!=v over scenario dims (last path segment as k); first matching row wins; 'k!=true' also matches a missing field"
          },
          "outputs": {
            "type": "array",
            "items": {
              "type": "string"
            },
            "description": "business service names the message reaches; [] = consumed, nothing sent"
          },
          "branch": {
            "type": "string"
          },
          "path": {
            "type": "string"
          }
        }
      }
    },
    "outputs": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "name": {
            "type": "string"
          },
          "destination": {
            "type": "string"
          },
          "on_path": {
            "type": "string"
          },
          "body_from": {
            "type": "string"
          },
          "headers": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "name": {
                  "type": "string"
                },
                "source": {
                  "type": "string"
                }
              }
            }
          },
          "business_service": {
            "type": "string"
          }
        }
      }
    },
    "transforms": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "name": {
            "type": "string"
          },
          "purpose": {
            "type": "string"
          },
          "inputs": {
            "type": "array",
            "items": {
              "type": "string"
            }
          },
          "output_root": {
            "type": "string"
          },
          "fn_bea": {
            "type": "array",
            "items": {
              "type": "string"
            }
          },
          "mappings": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "from": {
                  "type": "string"
                },
                "to": {
                  "type": "string"
                },
                "rule": {
                  "type": "string"
                }
              }
            }
          }
        }
      }
    },
    "backends": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "name": {
            "type": "string"
          },
          "type": {
            "type": "string"
          },
          "operation": {
            "type": "string"
          },
          "called_when": {
            "type": "string"
          },
          "request_from": {
            "type": "string"
          },
          "response_use": {
            "type": "string"
          },
          "retry": {
            "type": "string"
          },
          "timeout": {
            "type": "string"
          },
          "on_fault": {
            "type": "string"
          }
        }
      }
    },
    "errors": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "scope": {
            "type": "string"
          },
          "catches": {
            "type": "string"
          },
          "logs": {
            "type": "string"
          },
          "goes_to": {
            "type": "string"
          },
          "headers": {
            "type": "array",
            "items": {
              "type": "string"
            }
          },
          "redelivery": {
            "type": "string"
          }
        }
      }
    },
    "logs": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "stage": {
            "type": "string"
          },
          "level": {
            "type": "string"
          },
          "template": {
            "type": "string"
          }
        }
      }
    },
    "dependencies": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "kind": {
            "type": "string"
          },
          "name": {
            "type": "string"
          },
          "used_for": {
            "type": "string"
          },
          "in_export": {
            "type": "boolean"
          }
        }
      }
    },
    "open_questions": {
      "type": "array",
      "items": {
        "type": "string"
      }
    },
    "scenario_dims": {
      "type": "array",
      "items": {
        "type": "string"
      },
      "description": "JSON paths (data.x) or XML element names of the payload fields the branches decide on; task 1 is rerun with SCENARIO_DIMS=...,body:<path> so the log scenarios carry them"
    }
  }
}
KIT_EOF__PI_SKILLS_OSB_RESEARCH_ASSETS_RESEARCH_SCHEMA_JSON
chmod +x .pi/skills/osb-camelk-route/scripts/*.py pi/*.sh 2>/dev/null || true
echo "installed: 37 files (skill osb-camelk-route + domain runner)"
