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
