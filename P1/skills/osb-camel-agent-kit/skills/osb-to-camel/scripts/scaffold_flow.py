#!/usr/bin/env python3
"""Scaffold the flow card (and the fixture/test skeleton) for one OSB proxy service from its inventory JSON.

Usage: scaffold_flow.py osb-inventory/flows/<Project__Proxy__Name>.json -o migration/<flow>/
                        [--camel 4.18.x] [--spring-boot 3.5.x] [--package com.example] [--module <name>]

Writes:
  <out>/FLOW_CARD.md          the card with every table pre-filled from the inventory (decisions left to the reviewer)
  <out>/test-matrix.json      the rows that become tests (route / golden / contract / jms / parity)
  <out>/config-keys.yml       the configuration block per business service, values from the export where it had them
  <out>/fixtures/README.md    which fixture files the tests expect, by name

Deterministic parts only. The script proposes a Camel step per OSB action from the mapping table in
references/osb-action-mapping.md; the reviewer confirms or overrides on the card. It never reads the XML again: the
inventory is the single source, so the card and the inventory cannot disagree.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATE = HERE.parent / "assets" / "templates" / "FLOW_CARD.md"

# One-line proposals per OSB action. The reference file explains the traps; these are the defaults it argues for.
PROPOSAL = {
    "assign": "`setProperty(<var>, OsbXQuery.of(<expr>).ns(NS).asNode()|asString())`",
    "replace": "`OsbXQuery.of(<expr>)|resource(<xqy>).replaceBodyContentsOnly()|replaceBody()`; XSLT via `xslt-saxon:`",
    "insert": "XQuery/XSLT rebuilding the parent (mode: where=first-child/last-child/before/after)",
    "delete": "XSLT identity template with an empty template for the path",
    "rename": "XSLT identity template with a renaming template",
    "javaCallout": "`.bean(<Class>, \"<method>\")`; port the jar source, else stub + blocking TODO",
    "javaScript": "`.process()` ported to Java (or `js` language if GraalJS is accepted)",
    "javascript": "`.process()` ported to Java (or `js` language if GraalJS is accepted)",
    "mflTransform": "`bindy`/`flatpack` or custom DataFormat from the MFL spec; golden tests with real samples",
    "nXSDTransform": "as mflTransform",
    "nxsdTranslation": "as mflTransform (JSON nXSD: Jackson processor, see osb-action-mapping)",
    "transport-headers": "setHeader per header on the outbound exchange",
    "validate": "`.to(\"validator:classpath:osb/<project>/<xsd>\")`; doTry/doCatch when resultVar is used",
    "transportHeaders": "`setHeader`/`removeHeaders(\"*\", keep...)`; honour copy-all",
    "route": "`unwrap() -> .to(<backend endpoint>) -> rewrap()` terminal; response steps follow",
    "routeTable": "`choice().when(...).to(...)`, one case per row",
    "dynamicRoute": "`toD`/`recipientList` from a property, lookup map service-ref → endpoint",
    "routingOptions": "endpoint/URI override headers; effective values on the card",
    "routing-options": "endpoint/URI override headers; effective values on the card",
    "wsCallout": "save wrapped body → body = request variable (bare) → `.to(<backend>)` → response into property → restore body",
    "publish": "`wireTap(direct:<flow>-publish<Name>)`, InOnly, outbound transform inside the tap route",
    "publishTable": "`choice` + `wireTap`",
    "dynamicPublish": "`toD` InOnly from a property",
    "ifThenElse": "`choice().when(OsbXQuery.of(<condition>).ns(NS).asPredicate())...otherwise()`",
    "forEach": "`split(xpath(...))` with aggregation, or XQuery rebuild when the loop writes back",
    "foreach": "`split(xpath(...))` with aggregation, or XQuery rebuild when the loop writes back",
    "reply": "`.stop()` (request pipeline: before the backend call); isErrorReply → SOAP fault",
    "skip": "`.stop()` scoped to the pipeline sub-route",
    "Error": "`throwException(new OsbFaultException(<errCode>, <message>))`",
    "raiseError": "`throwException(new OsbFaultException(<errCode>, <message>))`",
    "resume": "`onException(...).handled(true).continued(true)`",
    "log": "`.log(<LEVEL>, logger, \"...\")` after review for personal data",
    "alert": "`.log(WARN, \"ALERT <dest> <severity>: ...\")` + micrometer counter; destination to monitoring owner",
    "report": "`.log(INFO, ...)` with the key as a structured field",
}

INBOUND = {
    ("http", "SOAP"): ("`cxf:bean:<proxy>Endpoint?dataFormat=PAYLOAD` (same WSDL/port)", "camel-cxf-soap-starter"),
    ("http", None): ("`platform-http:<path>` / `rest()`", "camel-platform-http-starter"),
    ("jms", None): ("`amqp:queue:<dest>` (AMQP 5672)", "camel-amqp-starter"),
    ("sb", None): ("`direct:`", "core"), ("local", None): ("`direct:`", "core"),
    ("file", None): ("`file:`", "camel-file-starter"), ("ftp", None): ("`ftp:`", "camel-ftp-starter"), ("sftp", None): ("`sftp:`", "camel-ftp-starter"),
}
OUTBOUND = {
    ("http", "SOAP"): "`cxf:bean:<Name>Endpoint?dataFormat=PAYLOAD` address={{osb.business.<Name>.url}}",
    ("http", None): "`http:{{osb.business.<Name>.url}}`",
    ("jms", None): "`amqp:queue|topic:{{osb.business.<Name>.destination}}` (InOnly when response-required=false)",
    ("sb", None): "`direct:<proxy>`", ("local", None): "`direct:<proxy>`",
}


def comp(transport, binding, table, default):
    b = "SOAP" if (binding or "").upper().startswith("SOAP") else None
    return table.get((transport, b)) or table.get((transport, None)) or default


def slug(ref: str) -> str:
    return ref.replace("/", "__")


def short(ref: str) -> str:
    return ref.split("/")[-1] if ref else "?"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("flow_json")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--camel", default="4.18.x (versions.md)")
    ap.add_argument("--spring-boot", default="3.5.x (versions.md)")
    ap.add_argument("--package", default="com.example.integration")
    ap.add_argument("--module", default=None)
    args = ap.parse_args(argv)

    f = json.loads(Path(args.flow_json).read_text(encoding="utf-8"))
    proxy, pipe, business, transforms, tri = f["proxy"], f.get("pipeline") or {}, f["business"], f["transforms"], f["triage"]
    project = proxy["ref"].split("/")[0]
    proxy_name = short(proxy["ref"])
    flow = slug(proxy["ref"])
    out = Path(args.out)
    (out / "fixtures").mkdir(parents=True, exist_ok=True)

    # ---- pipeline walk rows
    rows, n = [], 0
    for st in pipe.get("stages", []):
        for a in st["actions"]:
            n += 1
            rows.append(f"| {n} | {st.get('pipeline')}/{st.get('type')} / {st.get('stage')} | `{a}` | (read the XML: id, vars, expressions) | {PROPOSAL.get(a, 'no default: design on the card')} | |")
    for b in pipe.get("branches", []):
        n += 1
        rows.append(f"| {n} | flow | branch-node `{b.get('type')}` {b.get('name')} | cases: {', '.join(b.get('branches', []))} | one route per operation / `choice` per case | |")
    action_rows = "\n".join(rows) or "| | | | (pipeline not resolved: open item) | | |"

    # ---- variables
    vrows = []
    for v in sorted(pipe.get("context_vars", [])):
        camel = {"body": "message body (wrapped <Body>)", "header": "property `osb.header` / CXF headers", "inbound": "properties `osb.inbound.*` + headers",
                 "outbound": "headers before `.to()`", "fault": "headers `osb.fault.*` + `<ctx:fault>`", "operation": "`operationName` header",
                 "attachments": "CXF attachments (complex)", "messageID": "`${exchangeId}` (ignore list)"}.get(v, "exchange property")
        vrows.append(f"| `${v}` | pipeline | pipeline | {camel} | |")
    for st in pipe.get("stages", []):
        pass
    for xq in pipe.get("inline_xquery", []):
        for m in re.finditer(r"\$([A-Za-z][A-Za-z0-9_]*)", xq):
            name = m.group(1)
            if name not in ("body", "header", "inbound", "outbound", "fault", "operation", "attachments", "messageID") and f"`${name}`" not in "".join(vrows):
                vrows.append(f"| `${name}` | assign / callout | later actions | exchange property `{name}` | user variable |")
    variable_rows = "\n".join(vrows) or "| (none detected) | | | | |"

    # ---- backends
    brows, cfg = [], {"osb": {"proxy": {proxy_name: {"path": (proxy.get("uris") or ["?"])[0]}}, "business": {}}}
    for b in business:
        name = short(b["ref"])
        ep = comp(b.get("transport"), b.get("binding"), OUTBOUND, "case by case").replace("<Name>", name)
        timeout_ms = str(int(b["timeout"]) * 1000) if b.get("timeout") and str(b["timeout"]).isdigit() else "?"
        brows.append(f"| `{b['ref']}` | {b.get('transport')} / {b.get('binding')} | {', '.join(b.get('uris') or [])} | {b.get('timeout') or '-'} s | {b.get('retry_count') or '0'} / {b.get('retry_interval') or '0'} s / {b.get('transport_props', {}).get('retry-application-errors', 'default')} | {short(b.get('service_account') or '') or '-'} | {ep} | `osb.business.{name}.*` |")
        block = {"url": (b.get("uris") or ["?"])[0] if b.get("transport") != "jms" else None,
                 "destination": (b.get("uris") or ["?"])[0].split("/")[-1] if b.get("transport") == "jms" else None,
                 "timeout": timeout_ms if b.get("transport") != "jms" else None,
                 "retry-count": b.get("retry_count") or "0", "retry-interval": str(int(b["retry_interval"]) * 1000) if (b.get("retry_interval") or "").isdigit() else "0",
                 "response-required": b.get("transport_props", {}).get("response-required") if b.get("transport") == "jms" else None,
                 "username": "${vault:osb/" + name + "/username}" if b.get("service_account") else None,
                 "password": "${vault:osb/" + name + "/password}" if b.get("service_account") else None}
        cfg["osb"]["business"][name] = {k: v for k, v in block.items() if v is not None}
    backend_rows = "\n".join(brows) or "| (none) | | | | | | | |"

    # ---- transforms
    trows = []
    for t in transforms:
        plan = "keep + shim import" if t.get("fn_bea") else "keep unchanged"
        if t.get("kind") == "?":
            plan = "NOT FOUND in export: open item"
        trows.append(f"| `{t['ref']}` | {t.get('kind')} | {t.get('lines', '?')} | {t.get('xquery_version') or '-'} | {', '.join(t.get('fn_bea', [])) or '-'} | {', '.join(t.get('external_params', [])) or '-'} | {plan} |")
    transform_rows = "\n".join(trows) or "| (none) | | | | | | |"

    # ---- error handling
    erows = []
    for scope in pipe.get("error_handler_scopes", []):
        camel = {"service": "route-level `onException` running the error pipeline, then SOAP fault reply",
                 "pipeline": "`onException` in the pipeline's `direct:` sub-route", "route": "`onException`/`doTry` around the backend `.to()`",
                 "stage": "`doTry/doCatch` around the stage's steps"}.get(scope.split(":")[0], "see mapping")
        erows.append(f"| {scope.split(':')[0]} | {scope} | (read the error pipeline XML) | {camel} | (from the fault XSLT) |")
    error_rows = "\n".join(erows) or "| (none declared: errors propagate to the transport) | | | | |"

    # ---- test matrix
    tests = []
    tid = 0
    def add(kind, scenario, inp, exp, mocks):
        nonlocal tid
        tid += 1
        tests.append({"id": f"T-{tid:02d}", "type": kind, "scenario": scenario, "input": inp, "expected": exp, "mocks": mocks})
    ops = pipe.get("operations") or ["(single operation)"]
    for op in ops:
        add("route", f"{op}: happy path through the pipeline to the route node", f"fixtures/{op}-input.xml (from XSD)", "mock expectations: backend receives transformed body", "all backends mock:")
    counts = pipe.get("action_counts", {})
    for _ in range(counts.get("ifThenElse", 0)):
        add("route", "ifThenElse: condition true branch", "fixture with the deciding value set true", "branch actions executed", "mock:")
        add("route", "ifThenElse: condition false / default branch", "fixture with the deciding value set false", "default actions executed", "mock:")
    for _ in range(counts.get("routeTable", 0) + counts.get("publishTable", 0)):
        add("route", "routing/publish table: one test per case", "one fixture per case", "right target mock receives", "mock:")
    for scope in pipe.get("error_handler_scopes", []):
        if not scope.startswith("error-pipeline"):
            add("route", f"error handler at {scope} scope: forced failure maps to the documented fault", "happy-path fixture + throwing mock", "fault body from the fault XSLT, error code", "mock: throwing")
    if counts.get("reply", 0):
        add("route", "reply short-circuit: backend not called", "fixture that reaches the reply", "backend mock count 0", "mock:")
    if counts.get("transportHeaders", 0):
        add("route", "transport headers: set/propagated per copy-all", "fixture + inbound headers", "backend mock sees expected headers only", "mock:")
    for t in transforms:
        add("golden", f"{short(t['ref'])}: original (with shim) == migrated, happy path + one per branch/optional/empty-for", f"fixtures/transforms/{short(t['ref'])}/<NN>/params/", "produced by running the original", "none (Saxon only)")
    for b in business:
        name = short(b["ref"])
        if b.get("transport") == "jms":
            add("jms", f"{name}: publish is InOnly, one message, transformed body", "happy-path fixture", "message on the container queue", "Testcontainers ArtemisContainer")
        else:
            add("contract", f"{name}: request shape and headers", "happy-path fixture", "WireMock verify (SOAPAction, XPath)", "WireMock")
            if (b.get("retry_count") or "0") != "0" or b.get("timeout"):
                add("contract", f"{name}: timeout → {b.get('retry_count') or '0'} retries then fault; SOAP fault not retried", "happy-path fixture", f"verify exactly {int(b.get('retry_count') or 0) + 1} calls; fault code", "WireMock delayed/fault stubs")
    add("parity", "recorded OSB exchanges replayed; response and backend requests similar", "src/test/resources/parity/<flow>/<NN>/", "recorded response.xml", "WireMock replaying recorded backend responses")
    test_rows = "\n".join(f"| {t['id']} | {t['type']} | {t['scenario']} | {t['input']} | {t['expected']} | {t['mocks']} |" for t in tests)

    # ---- open items
    items = []
    def oi(text, owner, blocks="yes"):
        items.append(f"| O{len(items) + 1} | {text} | {blocks} | {owner} |")
    for t in transforms:
        for fn in t.get("fn_bea", []):
            oi(f"`fn-bea:{fn}` in `{short(t['ref'])}`: shim covers it? (expression mapping §4)", "migration engineer", "until the golden test runs")
    for jc in pipe.get("java_callouts", []):
        oi(f"Java callout `{jc.get('class')}.{jc.get('method')}` (archive `{jc.get('archive')}`): source available?", "the client integration team", "yes")
    for u in pipe.get("unknown_actions", []):
        oi(f"Unknown pipeline action `{u}`: add to the mapping table before implementation", "skill maintainer", "yes")
    for m in f.get("missing_refs", []):
        oi(f"`{m['ref']}` is referenced (from `{m['referenced_from']}`) but missing from the export: obtain it or confirm it is retired", "the client OSB team", "yes")
    for b in business:
        if "NOT FOUND in export" in " ".join(b.get("notes", [])):
            oi(f"Business service `{b['ref']}` referenced but not in the export", "the client OSB team", "yes")
        if b.get("service_account"):
            oi(f"Service account `{short(b['service_account'])}` for `{short(b['ref'])}`: Vault path and owner", "the client security", "before UAT")
        if b.get("ws_policies"):
            oi(f"WS-Security policies on `{short(b['ref'])}`: where does the control live on the target?", "the client security", "yes")
        if b.get("transport") == "jms":
            oi(f"Destination `{(b.get('uris') or ['?'])[0].split('/')[-1]}` must exist on the target broker (messaging migration)", "messaging workstream", "before UAT")
    if proxy.get("ws_policies"):
        oi("WS-Security policies on the proxy: gateway/mesh decision", "the client security", "yes")
    if counts.get("alert", 0):
        oi("Alert destinations: which monitoring rule replaces them?", "the client monitoring", "no")
    if "header" in pipe.get("context_vars", []) or "attachments" in pipe.get("context_vars", []):
        oi("Pipeline reads SOAP headers/attachments: confirm CXF header/attachment handling", "migration engineer", "yes")
    oi("Recorded OSB traffic for the parity test (capture mechanism agreed with the client)", "the client OSB team", "before cutover")
    open_items = "\n".join(items)

    inbound = comp(proxy.get("transport"), proxy.get("binding"), INBOUND, ("case by case", "?"))
    card = TEMPLATE.read_text(encoding="utf-8")
    repl = {
        "proxy_ref": proxy["ref"], "project": project, "proxy_path": proxy.get("path") or "path not in inventory",
        "pipeline_ref": proxy.get("pipeline") or "(inline / not resolved)", "pipeline_path": pipe.get("path") or "", "tier": tri["tier"], "score": str(tri["score"]),
        "reasons": "; ".join(tri["reasons"]), "camel_version": args.camel, "spring_boot_version": args.spring_boot,
        "module": args.module or f"osb-{project.lower()}", "package": f"{args.package}.{project.lower()}",
        "proxy_transport": str(proxy.get("transport")) + (" (" + "; ".join(f"{k}={v}" for k, v in sorted((proxy.get("transport_props") or {}).items())) + ")"
                                                         if proxy.get("transport_props") else ""), "proxy_uris": ", ".join(proxy.get("uris") or []), "binding": str(proxy.get("binding")),
        "soap12": str(proxy.get("soap12")), "wsdl": str(proxy.get("wsdl")), "operations": ", ".join(ops),
        "inbound_security": ", ".join(proxy.get("ws_policies") or []) or (proxy.get("transport_props", {}).get("authentication") or "see proxy provider-specific"),
        "action_rows": action_rows, "error_handler_scopes": ", ".join(pipe.get("error_handler_scopes", [])) or "none",
        "variable_rows": variable_rows, "backend_rows": backend_rows, "transform_rows": transform_rows, "error_rows": error_rows,
        "throttling": str(proxy.get("throttling")), "result_caching": str(proxy.get("result_caching") or any(b.get("result_caching") for b in business)),
        "transactional": proxy.get("transport_props", {}).get("transaction-required", "n/a"), "ws_policies": ", ".join(proxy.get("ws_policies") or []) or "none",
        "alert_destinations": str(counts.get("alert", 0)) + " alert action(s)", "test_rows": test_rows, "open_items": open_items,
    }
    for k, v in repl.items():
        card = card.replace("{{" + k + "}}", v)
    card = card.replace("| Camel inbound endpoint | | decided here |", f"| Camel inbound endpoint | {inbound[0]} ({inbound[1]}) | proposal |")
    (out / "FLOW_CARD.md").write_text(card, encoding="utf-8")
    (out / "test-matrix.json").write_text(json.dumps(tests, indent=2), encoding="utf-8")

    def yaml(d, ind=0):
        s = ""
        for k, v in d.items():
            if isinstance(v, dict):
                s += " " * ind + f"{k}:\n" + yaml(v, ind + 2)
            else:
                s += " " * ind + f"{k}: {v}\n"
        return s
    (out / "config-keys.yml").write_text("# generated from the OSB export; values are the non-prod ones the export carried, Vault keys are placeholders\n" + yaml(cfg), encoding="utf-8")

    fx = ["# Fixtures the generated tests expect", "", f"Flow: `{proxy['ref']}`", ""]
    fx += [f"- `{t['input']}` → `{t['expected']}` ({t['id']}, {t['type']})" for t in tests]
    fx += ["", "Naming: `<NN>-<kebab-description>-input.xml` / `-expected.xml`; values traceable to field names; dates fixed; see references/test-strategy.md."]
    (out / "fixtures" / "README.md").write_text("\n".join(fx), encoding="utf-8")
    print(f"card: {out / 'FLOW_CARD.md'}  tests: {len(tests)}  open items: {len(items)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
