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

Routing comes from the frozen scenario table of the module (flow-test.json, checked against the Splunk cases);
transformations never come from an agent: what OSB does to the body is read from the pipeline and run with OSB's
own files. Prints {"projects": n, "flows": n, "out": ...}; per flow what could not be generated goes to BODY_CHAIN.md."""
import argparse
import json
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import body_chain  # noqa: E402

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


def route_for(project: str, x: str, cfg: dict, bc: dict, files: dict, notes: list) -> tuple[str, list]:
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
    L = [f"# ======== flow {x}: generated from the OSB pipeline (body_chain.py) and the frozen scenario table; do not edit",
         "# by hand, regenerate (assemble_jbang.py). Body per output: see docs/" + x + "/BODY_CHAIN.md",
         "- route:", f"    id: {x}", "    from:", f'      uri: "{{{{{x}.flow.input}}}}"', "      steps:"]
    S = []
    if cfg.get("correlation_generated"):
        S += [f"- setHeader: {{name: {corr}, simple: \"${{header.{corr}}} ?: ${{uuid(random)}}\"}}"]
    S += ['- setProperty: {name: request, simple: "${bodyAs(String)}"}      # OSB: assign request = $body',
          "- log:", "    loggingLevel: INFO", "    logName: oracle.osb.logging.pipeline",
          f'    message: "Request Received to Project {project} :: for PS {x} with TraceID - ${{header.{corr}}} ::${{exchangeProperty.request}}"']
    T = ['- setProperty: {name: osbStage, constant: "request-translation-stage"}']
    rows = [r for r in cfg.get("scenario_mapping", []) if r.get("outputs") != [err]]
    if any(condition(r["scenario"], fields) is not None and not r["scenario"].split("|")[0].startswith("hdr_") for r in rows) or fields:
        T += [f'- setProperty: {{name: osbFields, constant: "{",".join(sorted(fields))}"}}',
              "- bean: {beanType: osb.common.OsbNxsd, method: fields}"]
    T += chain_steps(pre, files, notes, osb_vars)
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
            body += ['- setBody: {simple: "${exchangeProperty.osbPrefixBody}"}'] + chain_steps(suffix, files, notes, osb_vars)
            body += ['- removeHeaders: {pattern: "*"}      # OSB sends no transport headers on this route',
                     f'- log: {{loggingLevel: INFO, logName: oracle.osb.logging.pipeline, message: "Sending to {o} for Project {project} with TraceID - ${{exchangeProperty.osbTraceId}}"}}',
                     f'- to: "{{{{{x}.out.{o}}}}}"']
        whens.append((cond, body))
    T += ['- setProperty: {name: osbTraceId, simple: "${header.' + corr + '}"}']
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
    C = ['- setBody: {simple: "${exchangeProperty.request}"}      # OSB: replace $body with $request',
         f'- removeHeaders: {{pattern: "*", excludePattern: "{"|".join(keep) or "NONE"}"}}']
    for h, expr in (("errorCode", "${exception.class.simpleName}"), ("errorMessage", "${exception.message}"),
                    ("debugInfo", "${exchangeProperty.osbStage}")):
        if h in e_headers:
            C.append(f'- setHeader: {{name: {h}, simple: "{expr}"}}')
    if corr in e_headers:
        C.append(f'- setHeader: {{name: {corr}, simple: "${{exchangeProperty.osbTraceId}} ?: ${{header.{corr}}}"}}')
    C += [f'- log: {{loggingLevel: ERROR, logName: oracle.osb.logging.pipeline, message: "Error captured for Project {project} :: for PS {x} with TraceID: ${{header.{corr}}} :: fault - ${{exception.message}}"}}',
          f'- to: "{{{{{x}.out.{err}}}}}"']
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
    for f in ("osb-jms-source.kamelet.yaml", "osb-jms-sink.kamelet.yaml", "OsbNxsd.java", "OsbXQuery.java", "jbang.sh"):
        shutil.copy2(TPL / "common" / f, cs / f)
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
            route, e_headers = route_for(project, x, cfg, bc, files, notes)
            routes += ["", route]
            mp = props_of(m / "src/main/resources/application.properties")
            lp = props_of(m / "env/local.properties")
            sel = mp.get("flow.input.selector", "")
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
        n_proj += 1
    return {"projects": n_proj, "flows": n_flow, "out": str(root)}


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
