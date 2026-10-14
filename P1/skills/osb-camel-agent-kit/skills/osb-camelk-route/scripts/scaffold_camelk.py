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


def endpoint(dest: str, kind: str) -> str:
    """Production endpoint for a research destination (scheme:name, never a host)."""
    d = (dest or "").strip()
    if not d or d.upper() == "UNKNOWN":
        return f"{TODO} destination of {kind}"
    m = re.match(r"^(https?):(/.*)$", d)
    if m:
        return f"{m.group(1)}://{{{{env:{slug(kind).upper().replace('-', '_')}_HOST}}}}{m.group(2)}"
    name = re.sub(r"^(jms|amqp|queue|topic):", "", d)
    kind_ = "topic" if d.startswith("topic:") else "queue"
    return f"amqp:{kind_}:{name}"


def model(r: dict, facts: dict, corr: str) -> dict:
    """Normalise research.json: outputs keyed by the business service that writes them (JMS backends ARE outputs and
    get no reply stub), branch paths and scenario mapping resolved to those keys, one error output."""
    raw_backends = r.get("backends") or []
    outputs, alias = {}, {}
    for o in r.get("outputs") or []:
        dest = o.get("destination") or ""
        owner = next((b for b in raw_backends if dest and dest in (b.get("operation") or "", b.get("destination") or "")), None)
        key = slug(owner.get("name") if owner else o.get("name"))
        outputs[key] = {"name": o.get("name"), "destination": dest, "on_path": o.get("on_path") or o.get("on") or "",
                        "headers": o.get("headers") or [], "backend": owner.get("name") if owner else None}
        for a in (o.get("name"), dest, owner.get("name") if owner else None, key):
            if a:
                alias[slug(a)] = key
    resolve = lambda x: alias.get(slug(x), slug(x))  # noqa: E731
    err = next((k for k, o in outputs.items() if re.search(r"error", f"{o['on_path']} {o['name']} {o['destination']}", re.I)), None)
    for e in r.get("errors") or []:
        if err:
            break
        g = e.get("goes_to") or ""
        err = next((k for a, k in alias.items() if a and a in slug(g)), None)
    if err is None:
        outputs["error"] = {"name": "error", "destination": "", "on_path": "error handler", "headers": [], "backend": None}
        err = "error"
    backends = {slug(b.get("name")): b for b in raw_backends if slug(b.get("name")) not in outputs}
    paths = []
    for b in r.get("branches") or []:
        for p in b.get("paths") or []:
            paths.append({"branch": slug(b.get("name")), "id": f"branch-{slug(b.get('name'))}-{slug(p.get('label'))}",
                          "label": p.get("label", ""), "plain": p.get("condition_plain", ""), "expr": p.get("condition_expr", ""),
                          "outputs": [resolve(x) for x in p.get("outputs") or [] if resolve(x) in outputs]})
    mapping = []
    for x in r.get("scenario_mapping") or []:
        outs = x.get("outputs") if isinstance(x.get("outputs"), list) else [x.get("output")]
        outs = [resolve(o) for o in outs if o and str(o).lower() not in ("none", "-")]
        mapping.append({"scenario": x.get("scenario", ""), "outputs": outs, "branch": x.get("branch", ""), "path": x.get("path", "")})
    dims = [(d.lstrip("/").split(".")[-1], d) for d in r.get("scenario_dims") or [] if d]
    fmt = ((r.get("entry") or {}).get("payload_format") or "UNKNOWN").lower()
    return {"outputs": outputs, "error": err, "backends": backends, "paths": paths, "mapping": mapping, "dims": dims,
            "format": fmt, "corr": corr, "logs": r.get("logs") or [], "transforms": r.get("transforms") or [],
            "branches": r.get("branches") or [], "entry": r.get("entry") or {}}


def route_yaml(proxy: str, project: str, pkg: str, m: dict) -> str:
    L = [f"# Camel K route (YAML DSL) for OSB project {project}, proxy {proxy}.",
         "# GENERATED SKELETON from the research pack (osb-camelk-route). The implementer fills every gap marked TODO",
         "# using FLOW_CARD.md; ids branch-*, out-*, backend-* must stay (check_camelk.py and the tests rely on them).",
         "# Endpoints are properties: production values in application.properties (Camel K: traits.camel.properties),",
         "# tests replace them with direct:/mock: endpoints.",
         "- route:", f"    id: {proxy}", "    from:", '      uri: "{{flow.input}}"', "      steps:",
         "        - doTry:", "            steps:"]
    ind = " " * 14
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
        L.append(f"{ind}# place: - to: {{id: backend-{k}, uri: \"{{{{backend.{k}}}}}\"}}   ({b.get('type', '')} {b.get('operation', '')}; "
                 f"called when: {b.get('called_when', '')})")
    by_branch = {}
    for p in m["paths"]:
        by_branch.setdefault(p["branch"], []).append(p)
    placed = set()
    for b, ps in by_branch.items():
        L += [f"{ind}- choice:", f"{ind}    id: branch-{b}", f"{ind}    when:"]
        for p in ps:
            L += [f"{ind}      - id: {p['id']}", f"{ind}        simple: {q(TODO + ' ' + (p['plain'] or p['label']))}",
                  f"{ind}        steps:"]
            outs = p["outputs"] or []
            for o in outs:
                L += [f"{ind}          - to:", f"{ind}              id: out-{o}", f'{ind}              uri: "{{{{out.{o}}}}}"']
                placed.add(o)
            if not outs:
                L += [f"{ind}          - log:", f"{ind}              message: {q(TODO + ' path ' + p['label'] + ': no output in research')}"]
    rest = [o for o in m["outputs"] if o not in placed and o != m["error"]]
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
    L += ["                  - setHeader:", "                      name: errorCode",
          f"                      constant: {q(TODO + ' errorCode per research Q9')}",
          "                  - setHeader:", "                      name: errorMessage", '                      simple: "${exception.message}"',
          "                  - to:", f"                      id: out-{m['error']}", f'                      uri: "{{{{out.{m["error"]}}}}}"']
    return "\n".join(L) + "\n"


def properties(proxy: str, m: dict) -> str:
    e = m["entry"]
    dest, sub = e.get("destination") or "", str(e.get("durable_subscription") or "")
    if sub.lower() in ("true", "yes"):
        sub = proxy                      # OSB names the subscription itself; on Artemis the subscription queue is ours to name
    name = re.sub(r"^(jms|amqp|queue|topic):", "", dest)
    if not name or name.upper() == "UNKNOWN":
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
    L += [f"out.{k}={endpoint(o['destination'], k)}" for k, o in m["outputs"].items()]
    L += [f"backend.{k}={endpoint(b.get('operation') if (b.get('type') or '').lower().startswith('http') else b.get('name'), k)}"
          for k, b in m["backends"].items()]
    return "\n".join(L) + "\n"


def test_props(m: dict) -> list[str]:
    return (["flow.input=direct:in"] + [f"out.{k}=mock:out-{k}" for k in m["outputs"]]
            + [f"backend.{k}=mock:backend-{k}" for k in m["backends"]])


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
    a = ap.parse_args()
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
    pom = (TPL / "pom.xml").read_text(encoding="utf-8").replace("@@GROUP@@", "osb." + slug(a.project)).replace(
        "@@ARTIFACT@@", slug(proxy)).replace("@@PROJECT@@", a.project).replace("@@PROXY@@", proxy).replace(
        "<!-- @@EXTRA_DEPS@@ -->", "\n    ".join(f"<dependency><groupId>org.apache.camel</groupId><artifactId>{d}</artifactId></dependency>"
                                            for d in deps) or "<!-- no transform dependencies -->")
    written = []
    jdir = pkg.replace(".", "/")
    for path, text, once in [
        (o / "pom.xml", pom, True),
        (o / f"src/main/resources/routes/{proxy}.camel.yaml", route_yaml(proxy, a.project, pkg, m), True),
        (o / "src/main/resources/application.properties", properties(proxy, m), True),
        (o / "FLOW_CARD.md", card(proxy, a.project, r, facts, m, sha(rp)), True),
        (o / ".gitignore", "target/\nsrc/test/resources/parity/\n", True),
    ]:
        if write_once(path, text, a.force):
            written.append(path.relative_to(o).as_posix())
    if m["format"] == "json":
        bean = (TPL / "OsbJson.java.tpl").read_text(encoding="utf-8").replace("@@PACKAGE@@", pkg).replace(
            "@@HEADER_PATHS@@", ", ".join("{" + q(h) + ", " + q(p) + "}" for h, p in m["dims"]))
        if write_once(o / f"src/main/java/{jdir}/OsbJson.java", bean, a.force):
            written.append(f"src/main/java/{jdir}/OsbJson.java")
    test = (TPL / "FlowParityTest.java.tpl").read_text(encoding="utf-8").replace("@@PACKAGE@@", pkg).replace(
        "@@PROJECT@@", a.project).replace("@@PROXY@@", proxy).replace("@@INPUT@@", "direct:in").replace(
        "@@TEST_PROPERTIES@@", ", ".join(q(p) for p in test_props(m)))
    cfg = {"outputs": {k: f"mock:out-{k}" for k in m["outputs"]}, "error_output": m["error"],
           "backends": {k: {"mock": f"mock:backend-{k}", "response_use": b.get("response_use", "")} for k, b in m["backends"].items()},
           "scenario_mapping": [{"scenario": x["scenario"], "outputs": x["outputs"]} for x in m["mapping"]],
           "correlation_header": m["corr"], "payload_format": m["format"]}
    tp = o / f"src/test/java/{jdir}/FlowParityTest.java"
    cp = o / "src/test/resources/flow-test.json"
    for path, text in [(tp, test), (cp, json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")]:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        written.append(path.relative_to(o).as_posix())
    stubs = ["# Backend stubs for the L1 tests", "", "One file per backend, named <backend>.json / .xml / .txt: the response shape from",
             "research Q8 (WSDL/XSD), with FAKE values only. FlowErrorTest makes the same mocks throw for the error tests.", ""]
    stubs += [f"- `{k}.*`: {b.get('type', '')} {b.get('operation', '')}; response use: {b.get('response_use', '') or '-'}" for k, b in m["backends"].items()] or ["- no backends"]
    write_once(o / "src/test/resources/stubs/README.md", "\n".join(stubs) + "\n", True)
    copied = 0
    if a.parity and a.parity.is_dir():
        dst = o / "src/test/resources/parity"
        for flow_dir in a.parity.iterdir():
            if flow_dir.is_dir():
                shutil.copytree(flow_dir, dst / flow_dir.name, dirs_exist_ok=True)
                copied += sum(1 for _ in (dst / flow_dir.name).glob("*/*/input.payload"))
    ids = ([f"branch-{b}" for b in {p["branch"] for p in m["paths"]}] + [p["id"] for p in m["paths"]]
           + [f"out-{k}" for k in m["outputs"]] + [f"backend-{k}" for k in m["backends"]])
    meta = {"proxy": proxy, "project": a.project, "package": pkg, "research_sha256": sha(rp),
            "generated": {tp.relative_to(o).as_posix(): sha(tp), cp.relative_to(o).as_posix(): sha(cp)},
            "route_ids": sorted(ids), "errors": len(r.get("errors") or []),
            "backends_with_response": [k for k, b in m["backends"].items()
                                       if (b.get("response_use") or "").strip().lower() not in ("", "none", "ignored", "not used", "-")]}
    (o / ".scaffold.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"proxy": proxy, "module": str(o), "written": len(written), "parity_cases": copied,
                      "branches": len(m["paths"]), "outputs": len(m["outputs"]), "backends": len(m["backends"]),
                      "unmapped_log_scenarios": len(unmapped_scenarios(m, facts))}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
