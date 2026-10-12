#!/usr/bin/env python3
"""Inventory an Oracle Service Bus (OSB 11g/12c) export for migration to Apache Camel.

Input : a directory (unzipped sbconfig.jar, or a JDeveloper OSB project tree) or a .jar/.zip export.
Output: <out>/inventory.json      every artefact, every proxy/pipeline/business service with the facts
        <out>/INVENTORY.md        the human-readable inventory, triage and dependency tables
        <out>/dependencies.dot    Graphviz graph proxy -> pipeline -> business services / transforms
        <out>/flows/<flow>.json   one card per proxy service: everything the migration of that flow needs

Why a script and not the model: the export is XML with eight namespaces and two naming conventions
(.ProxyService/.Pipeline/.BusinessService in sbconfig exports, .proxy/.pipeline/.bix in 12c projects). Counting
actions, resolving refs and scoring complexity is deterministic work; doing it by reading files in context is slow,
expensive and inconsistent across 450 flows. The script matches on XML local names, so a prefix or namespace variant
degrades to an "unknown action" line in the report instead of a crash.

Stdlib only. Python 3.9+.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import zipfile
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterable, Optional
from xml.etree import ElementTree as ET

# ----------------------------------------------------------------------------- artefact types
# Both naming conventions. Keys are lowercase extensions.
ARTEFACT_TYPES = {
    "proxyservice": "proxy", "proxy": "proxy",
    "pipeline": "pipeline",
    "businessservice": "business", "bix": "business", "biz": "business",
    "wsdl": "wsdl", "xsd": "xsd", "xquery": "xquery", "xqy": "xquery", "xq": "xquery",
    "xslt": "xslt", "xsl": "xslt", "mfl": "mfl", "jca": "jca", "wadl": "wadl",
    "serviceaccount": "serviceaccount", "sa": "serviceaccount",
    "servicekeyprovider": "servicekeyprovider", "skp": "servicekeyprovider",
    "alert": "alertdestination", "alertdestination": "alertdestination",
    "flow": "splitjoin", "splitjoin": "splitjoin",
    "xmlschema": "xsd", "archive": "javajar", "jar": "javajar",
    "throttlinggroup": "throttling", "wspolicy": "wspolicy", "uddiregistry": "uddi",
    "xmldocument": "xmldocument", "jndiprovider": "jndiprovider", "smtpserver": "smtp",
    "jar_": "javajar",
}

# Pipeline action vocabulary (OSB local names) -> family. Anything else is reported as unknown.
ACTIONS = {
    # message processing
    "assign": "transform", "replace": "transform", "insert": "transform", "delete": "transform",
    "rename": "transform", "javaCallout": "callout", "mflTransform": "transform", "nXSDTransform": "transform",
    "nxsdTranslation": "transform",
    "validate": "validate", "transportHeaders": "headers", "transport-headers": "headers",
    # communication
    "route": "routing", "routeTable": "routing", "dynamicRoute": "routing",
    "wsCallout": "callout", "publish": "publish", "publishTable": "publish", "dynamicPublish": "publish",
    # flow control
    "ifThenElse": "flow", "forEach": "flow", "foreach": "flow", "reply": "flow", "skip": "flow",
    "resume": "flow", "Error": "flow", "raiseError": "flow",
    # 12c additions: JavaScript action, Routing Options (outbound URI / QoS / retry overrides)
    "javaScript": "callout", "javascript": "callout", "routingOptions": "routing", "routing-options": "routing",
    # reporting
    "log": "reporting", "alert": "reporting", "report": "reporting",
}
# Things that make a flow harder than its action count suggests.
HARD_ACTIONS = {"javaCallout", "javaScript", "javascript", "mflTransform", "nXSDTransform", "nxsdTranslation", "dynamicRoute", "dynamicPublish", "forEach", "foreach"}

# OSB XQuery extension functions that have no Camel/Saxon equivalent and must be rewritten.
FN_BEA = re.compile(r"\bfn-bea:([A-Za-z0-9_-]+)")
XQUERY_VERSION = re.compile(r'xquery\s+version\s+"([^"]+)"')
DOC_FN = re.compile(r"\b(fn:)?doc\(")
NS_DECL = re.compile(r"declare\s+namespace\s+([A-Za-z0-9_]+)\s*=\s*\"([^\"]+)\"")


def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def iter_local(el: ET.Element, name: str) -> Iterable[ET.Element]:
    for e in el.iter():
        if local(e.tag) == name:
            yield e


def first_text(el: ET.Element, name: str) -> Optional[str]:
    for e in iter_local(el, name):
        if e.text and e.text.strip():
            return e.text.strip()
    return None


def attr_any(el: ET.Element, name: str) -> Optional[str]:
    for k, v in el.attrib.items():
        if local(k) == name:
            return v
    return None


def collect_refs(el: ET.Element) -> list:
    """Every ref="Project/Folder/Name" attribute in an artefact, with the local name of the element carrying it."""
    out = []
    for e in el.iter():
        r = attr_any(e, "ref")
        if r and "/" in r:
            out.append({"ref": r, "via": local(e.tag)})
    return out


# ----------------------------------------------------------------------------- data model
@dataclass
class Artefact:
    ref: str            # OSB reference path without extension, e.g. Project/Folder/Name
    path: str           # file path relative to the export root
    kind: str           # proxy | pipeline | business | wsdl | xquery | ...
    size: int


@dataclass
class Service:
    ref: str
    kind: str                                  # proxy | business
    path: str = ""                             # file path relative to the export root
    transport: Optional[str] = None            # http, jms, sb, local, file, ftp, sftp, email, mq, jca, ws, ...
    inbound: Optional[bool] = None
    uris: list = field(default_factory=list)
    binding: Optional[str] = None              # SOAP | XML | REST | Messaging | Any ...
    soap12: Optional[bool] = None
    wsdl: Optional[str] = None
    pipeline: Optional[str] = None             # proxy -> pipeline (12c) or inline router (11g)
    service_account: Optional[str] = None
    retry_count: Optional[str] = None
    retry_interval: Optional[str] = None
    timeout: Optional[str] = None
    load_balancing: Optional[str] = None
    ws_policies: list = field(default_factory=list)
    throttling: bool = False
    result_caching: bool = False
    transport_props: dict = field(default_factory=dict)
    notes: list = field(default_factory=list)
    refs: list = field(default_factory=list)                   # every ref attribute found in the file


@dataclass
class Pipeline:
    ref: str
    path: str = ""
    error_handler_scopes: list = field(default_factory=list)   # service | pipeline | route | stage
    stages: list = field(default_factory=list)                 # [{pipeline, type, stage, actions:[...]}]
    branches: list = field(default_factory=list)               # [{type: operation|condition, names:[...]}]
    action_counts: dict = field(default_factory=dict)
    unknown_actions: list = field(default_factory=list)
    routes_to: list = field(default_factory=list)              # business service refs (route)
    callouts_to: list = field(default_factory=list)            # business service refs (wsCallout)
    publishes_to: list = field(default_factory=list)           # business service refs (publish)
    xquery_refs: list = field(default_factory=list)
    xslt_refs: list = field(default_factory=list)
    xsd_refs: list = field(default_factory=list)
    java_callouts: list = field(default_factory=list)
    inline_xquery: list = field(default_factory=list)          # short inline expressions (assign/replace/condition)
    context_vars: set = field(default_factory=set)
    operations: list = field(default_factory=list)
    namespaces: dict = field(default_factory=dict)
    refs: list = field(default_factory=list)
    alert_destinations: list = field(default_factory=list)
    fn_bea_inline: list = field(default_factory=list)          # fn-bea calls inside pipeline expressions


@dataclass
class Transform:
    ref: str
    kind: str                                  # xquery | xslt
    lines: int = 0
    xquery_version: Optional[str] = None
    fn_bea: list = field(default_factory=list)
    uses_doc: bool = False
    external_params: list = field(default_factory=list)
    namespaces: dict = field(default_factory=dict)


# ----------------------------------------------------------------------------- loading
def load_root(src: Path) -> tuple[Path, Optional[tempfile.TemporaryDirectory]]:
    if src.is_dir():
        return src, None
    if src.suffix.lower() in (".jar", ".zip"):
        tmp = tempfile.TemporaryDirectory(prefix="osb-export-")
        with zipfile.ZipFile(src) as z:
            for m in z.infolist():
                # refuse path traversal and absolute members
                p = Path(m.filename)
                if p.is_absolute() or ".." in p.parts:
                    raise SystemExit(f"refusing unsafe archive member: {m.filename}")
            z.extractall(tmp.name)
        return Path(tmp.name), tmp
    raise SystemExit(f"not a directory or archive: {src}")


def ref_of(rel: Path) -> str:
    stem = rel.with_suffix("")
    return "/".join(stem.parts)


def discover(root: Path) -> list[Artefact]:
    out = []
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        ext = p.suffix.lower().lstrip(".")
        kind = ARTEFACT_TYPES.get(ext)
        if not kind:
            continue
        rel = p.relative_to(root)
        out.append(Artefact(ref=ref_of(rel), path=str(rel), kind=kind, size=p.stat().st_size))
    return out


def parse_xml(path: Path) -> Optional[ET.Element]:
    try:
        return ET.parse(path).getroot()
    except ET.ParseError as e:  # report, never crash on one bad file
        sys.stderr.write(f"warn: cannot parse {path}: {e}\n")
        return None


# ----------------------------------------------------------------------------- services
def parse_service(art: Artefact, root_dir: Path) -> Service:
    s = Service(ref=art.ref, kind=art.kind, path=art.path)
    el = parse_xml(root_dir / art.path)
    if el is None:
        s.notes.append("unparseable XML")
        return s
    s.refs = collect_refs(el)
    s.transport = first_text(el, "provider-id")
    inb = first_text(el, "inbound")
    s.inbound = (inb.lower() == "true") if inb else None
    for uri in iter_local(el, "URI"):
        for v in iter_local(uri, "value"):
            if v.text and v.text.strip():
                s.uris.append(v.text.strip())
    for b in iter_local(el, "binding"):
        s.binding = attr_any(b, "type") or s.binding
        s12 = attr_any(b, "isSoap12")
        if s12 is not None:
            s.soap12 = s12.lower() == "true"
        for w in iter_local(b, "wsdl"):
            s.wsdl = attr_any(w, "ref") or s.wsdl
        break
    # 12c proxy -> pipeline reference; 11g keeps the router inline
    for inv in iter_local(el, "invoke"):
        r = attr_any(inv, "ref")
        if r:
            s.pipeline = r
    for pr in iter_local(el, "pipeline-ref"):
        s.pipeline = attr_any(pr, "ref") or s.pipeline
    for sa in iter_local(el, "service-account"):
        s.service_account = attr_any(sa, "ref") or s.service_account
    s.retry_count = first_text(el, "retry-count")
    s.retry_interval = first_text(el, "retry-interval")
    s.timeout = first_text(el, "timeout") or first_text(el, "response-timeout")
    s.load_balancing = first_text(el, "load-balancing-algorithm")
    for pol in iter_local(el, "policy"):
        r = attr_any(pol, "ref") or (pol.text or "").strip()
        if r:
            s.ws_policies.append(r)
    # <throttling enabled="false"/> is the 12c default: only an enabled element counts
    s.throttling = any((attr_any(th, "enabled") or "true").lower() == "true" for th in iter_local(el, "throttling"))
    s.result_caching = any(
        local(e.tag) in ("result-caching", "resultCaching")
        or (local(e.tag) == "resultCachingEnabled" and (e.text or "").strip().lower() == "true")
        for e in el.iter())
    for e in el.iter():
        ln = local(e.tag)
        if ln in ("request-method", "destination-type", "message-type", "response-required", "is-response-required", "retry-application-errors",
                  "jndi-service-account", "connection-factory", "dispatch-policy", "chunked-streaming-mode",
                  "follow-redirects", "use-ssl", "transaction-required", "same-transaction-for-response",
                  # JMS: topic vs queue, durable subscription, selector, XA, persistence
                  "is-queue", "durable-subscription", "message-selector", "topic-messages-distribution",
                  "XA-required", "enable-message-persistence", "expiration", "request-encoding"):
            if e.text and e.text.strip():
                s.transport_props[ln] = e.text.strip()
    if s.kind == "proxy" and s.pipeline is None and any(True for _ in iter_local(el, "router")):
        s.notes.append("inline router (11g-style): pipeline logic lives in the proxy file")
    return s


# ----------------------------------------------------------------------------- pipelines
def parse_pipeline(art: Artefact, root_dir: Path, inline_root: Optional[ET.Element] = None) -> Pipeline:
    p = Pipeline(ref=art.ref, path=art.path)
    el = inline_root if inline_root is not None else parse_xml(root_dir / art.path)
    if el is None:
        p.unknown_actions.append("unparseable XML")
        return p
    counts: Counter = Counter()
    p.refs = collect_refs(el)
    for al in iter_local(el, "alert"):
        for d in iter_local(al, "destination"):
            r = attr_any(d, "ref")
            if r:
                p.alert_destinations.append(r)
    # namespaces declared for XPath/XQuery inside the pipeline
    for d in iter_local(el, "userNsDecl"):
        pre, ns = attr_any(d, "prefix"), attr_any(d, "namespace")
        if pre and ns:
            p.namespaces[pre] = ns
    # error handlers by scope
    for e in el.iter():
        ln = local(e.tag)
        if ln == "router" and attr_any(e, "errorHandler"):
            p.error_handler_scopes.append("service")
        if ln == "pipeline" and attr_any(e, "errorHandler"):
            p.error_handler_scopes.append("pipeline")
        if ln == "route-node" and attr_any(e, "errorHandler"):
            p.error_handler_scopes.append("route")
        if ln == "stage" and attr_any(e, "errorHandler"):
            p.error_handler_scopes.append("stage")
        if ln == "pipeline" and (attr_any(e, "type") or "") == "error":
            p.error_handler_scopes.append("error-pipeline:" + (attr_any(e, "name") or "?"))
    # branches
    for b in iter_local(el, "branch-node"):
        names = [attr_any(x, "name") or "?" for x in iter_local(b, "branch")]
        btype = attr_any(b, "type") or "?"
        p.branches.append({"type": btype, "name": attr_any(b, "name"), "branches": names})
        if btype == "operation":
            p.operations.extend(n for n in names if n not in p.operations)
    # stages and actions
    for pl in iter_local(el, "pipeline"):
        ptype, pname = attr_any(pl, "type"), attr_any(pl, "name")
        for st in iter_local(pl, "stage"):
            acts = []
            for a in st.iter():
                ln = local(a.tag)
                if ln in ACTIONS:
                    acts.append(ln)
                    counts[ln] += 1
            p.stages.append({"pipeline": pname, "type": ptype, "stage": attr_any(st, "name"), "actions": acts})
    # route nodes count as routing actions even outside a stage
    for rn in iter_local(el, "route-node"):
        for a in rn.iter():
            ln = local(a.tag)
            if ln in ("route", "routeTable", "dynamicRoute"):
                counts[ln] += 1
                p.stages.append({"pipeline": "route-node", "type": "route", "stage": attr_any(rn, "name"), "actions": [ln]})
    # targets
    def targets(action_name: str) -> list:
        out = []
        for a in iter_local(el, action_name):
            for svc in iter_local(a, "service"):
                r = attr_any(svc, "ref")
                if r:
                    out.append(r)
        return out
    p.routes_to = sorted(set(targets("route") + targets("routeTable")))
    p.callouts_to = sorted(set(targets("wsCallout")))
    p.publishes_to = sorted(set(targets("publish") + targets("publishTable")))
    # resources
    for xq in iter_local(el, "xqueryTransform"):
        for r in iter_local(xq, "resource"):
            ref = attr_any(r, "ref")
            if ref:
                p.xquery_refs.append(ref)
    for xs in iter_local(el, "xsltTransform"):
        for r in iter_local(xs, "resource"):
            ref = attr_any(r, "ref")
            if ref:
                p.xslt_refs.append(ref)
    for v in iter_local(el, "validate"):
        for r in v.iter():
            if local(r.tag) in ("schema", "resource", "wsdl"):
                ref = attr_any(r, "ref")
                if ref:
                    p.xsd_refs.append(ref)
    for jc in iter_local(el, "javaCallout"):
        cls = first_text(jc, "className") or first_text(jc, "class") or "?"
        method = first_text(jc, "method") or first_text(jc, "methodName") or "?"
        arch = None
        for a in iter_local(jc, "archive"):
            arch = attr_any(a, "ref")
        p.java_callouts.append({"class": cls, "method": method, "archive": arch})
    for t in iter_local(el, "xqueryText"):
        if t.text and t.text.strip():
            txt = " ".join(t.text.split())
            p.inline_xquery.append(txt[:200])
            for m in re.finditer(r"\$(body|header|inbound|outbound|fault|operation|attachments|messageID)\b", txt):
                p.context_vars.add(m.group(1))
    p.xquery_refs = sorted(set(p.xquery_refs))
    p.xslt_refs = sorted(set(p.xslt_refs))
    p.xsd_refs = sorted(set(p.xsd_refs))
    p.action_counts = dict(counts)
    # unknown action-like elements inside <actions>
    known = set(ACTIONS) | {"actions", "id", "expr", "xqueryText", "xqueryTransform", "xsltTransform", "resource",
                            "param", "path", "service", "operation", "request", "response", "body", "header",
                            "case", "default", "condition", "actions", "location", "where", "userNsDecl",
                            "context", "varName", "logLevel", "message", "errCode", "comment", "outboundTransform",
                            "responseTransform", "route-node", "flow", "stage", "pipeline", "pipeline-node",
                            "branch-node", "branch", "router", "coreEntry", "binding", "wsdl", "port", "name",
                            "namespace", "pipelineEntry", "xml-fragment", "selector", "schema", "schemaElement",
                            "destination", "text", "value", "severity", "alert", "variable", "payload", "key",
                            "headers", "transportHeaders", "headerSet", "add", "inbound", "outbound", "requestTransform"}
    for acts in iter_local(el, "actions"):
        for child in list(acts):
            ln = local(child.tag)
            if ln not in known and ln not in ACTIONS:
                p.unknown_actions.append(ln)
    p.unknown_actions = sorted(set(p.unknown_actions))
    # fn-bea calls written inline in the pipeline (assign/log/replace expressions), not only in .xqy files
    p.fn_bea_inline = sorted({fn for e in el.iter() if e.text for fn in FN_BEA.findall(e.text)})
    return p


# ----------------------------------------------------------------------------- transforms
def parse_transform(art: Artefact, root_dir: Path) -> Transform:
    t = Transform(ref=art.ref, kind=art.kind)
    text = (root_dir / art.path).read_text(encoding="utf-8", errors="replace")
    # sbconfig exports wrap the query in <xqu:xqueryEntry><xqu:xquery>...</xqu:xquery>; projects store raw .xqy
    if text.lstrip().startswith("<") and art.kind == "xquery":
        el = parse_xml(root_dir / art.path)
        inner = first_text(el, "xquery") if el is not None else None
        if inner:
            text = inner
    t.lines = text.count("\n") + 1
    m = XQUERY_VERSION.search(text)
    t.xquery_version = m.group(1) if m else None
    t.fn_bea = sorted(set(FN_BEA.findall(text)))
    t.uses_doc = bool(DOC_FN.search(text))
    t.external_params = re.findall(r"declare\s+variable\s+\$([A-Za-z0-9_]+)\s+(?:as\s+[^;]+?)?external", text)
    t.namespaces = dict(NS_DECL.findall(text))
    return t


# ----------------------------------------------------------------------------- triage
def triage(flow: dict) -> tuple[str, int, list[str]]:
    """Return (tier, score, reasons). Tiers follow the estimate's unit rates: simple / medium / complex.

    The thresholds are a starting point, calibrated on nothing yet. The POC on the first slice is what sets them;
    until then every tier is a proposal and the reasons are what a reviewer argues with.
    """
    reasons = []
    score = 0
    p = flow.get("pipeline") or {}
    counts = p.get("action_counts", {})
    n_actions = sum(counts.values())
    score += n_actions
    reasons.append(f"{n_actions} pipeline actions")
    n_targets = len(p.get("routes_to", [])) + len(p.get("callouts_to", [])) + len(p.get("publishes_to", []))
    score += 3 * n_targets
    if n_targets:
        reasons.append(f"{n_targets} downstream services")
    hard = [a for a in counts if a in HARD_ACTIONS]
    if hard:
        score += 8 * len(hard)
        reasons.append("hard actions: " + ", ".join(hard))
    if p.get("java_callouts"):
        score += 10
        reasons.append(f"{len(p['java_callouts'])} Java callout(s): jar must be read and re-hosted")
    xq_lines = sum(t.get("lines", 0) for t in flow.get("transforms", []))
    if xq_lines:
        score += xq_lines // 20
        reasons.append(f"{xq_lines} lines of XQuery/XSLT")
    fnbea = sorted({f for t in flow.get("transforms", []) for f in t.get("fn_bea", [])}
                   | set((flow.get("pipeline") or {}).get("fn_bea_inline", [])))
    if fnbea:
        score += 4 * len(fnbea)
        reasons.append("fn-bea functions to rewrite: " + ", ".join(fnbea))
    transports = {flow.get("proxy", {}).get("transport")} | {b.get("transport") for b in flow.get("business", [])}
    transports.discard(None)
    exotic = transports - {"http", "ws", "sb", "local", "jms"}
    if exotic:
        score += 6 * len(exotic)
        reasons.append("non-trivial transports: " + ", ".join(sorted(exotic)))
    if any(b.get("ws_policies") for b in flow.get("business", [])) or flow.get("proxy", {}).get("ws_policies"):
        score += 6
        reasons.append("WS-Security policies attached")
    if flow.get("proxy", {}).get("throttling") or any(b.get("throttling") for b in flow.get("business", [])):
        score += 3
        reasons.append("throttling configured")
    if flow.get("proxy", {}).get("result_caching") or any(b.get("result_caching") for b in flow.get("business", [])):
        score += 4
        reasons.append("result caching (Coherence) in use")
    if len(p.get("branches", [])) > 1:
        score += 2 * (len(p["branches"]) - 1)
        reasons.append(f"{len(p['branches'])} branch nodes")
    if p.get("unknown_actions"):
        score += 5
        reasons.append("unknown actions: " + ", ".join(p["unknown_actions"]))
    if flow.get("missing_refs"):
        score += 3 * len(flow["missing_refs"])
        reasons.append("referenced but missing from the export: " + ", ".join(m["ref"].split("/")[-1] for m in flow["missing_refs"]))
    tier = "simple" if score < 12 else ("medium" if score < 28 else "complex")
    return tier, score, reasons


# ----------------------------------------------------------------------------- main
def build(root: Path) -> dict:
    arts = discover(root)
    by_ref = {a.ref: a for a in arts}
    services: dict[str, Service] = {}
    pipelines: dict[str, Pipeline] = {}
    transforms: dict[str, Transform] = {}
    for a in arts:
        if a.kind in ("proxy", "business"):
            services[a.ref] = parse_service(a, root)
        elif a.kind == "pipeline":
            pipelines[a.ref] = parse_pipeline(a, root)
        elif a.kind in ("xquery", "xslt"):
            transforms[a.ref] = parse_transform(a, root)
    # 11g-style proxies with inline routers: parse the proxy file as a pipeline too
    for ref, s in services.items():
        if s.kind == "proxy" and s.pipeline is None:
            el = parse_xml(root / by_ref[ref].path)
            if el is not None and any(True for _ in iter_local(el, "router")):
                pipelines[ref] = parse_pipeline(by_ref[ref], root, inline_root=el)
                s.pipeline = ref

    def resolve(ref: Optional[str]) -> Optional[str]:
        """OSB refs are Project/Folder/Name without extension; exports sometimes keep a leading project folder."""
        if not ref:
            return None
        if ref in by_ref:
            return ref
        tail = ref.split("/")[-1]
        cands = [r for r in by_ref if r.endswith("/" + tail) or r == tail]
        return cands[0] if len(cands) == 1 else ref

    flows = []
    unreferenced_business = set(r for r, s in services.items() if s.kind == "business")
    for ref, s in sorted(services.items()):
        if s.kind != "proxy":
            continue
        pref = resolve(s.pipeline)
        p = pipelines.get(pref) if pref else None
        pd = asdict(p) if p else None
        if pd:
            pd["context_vars"] = sorted(pd["context_vars"])
        bs_refs = []
        if p:
            bs_refs = [resolve(r) for r in p.routes_to + p.callouts_to + p.publishes_to]
        business = []
        for b in sorted(set(x for x in bs_refs if x)):
            unreferenced_business.discard(b)
            svc = services.get(b)
            business.append(asdict(svc) if svc else {"ref": b, "kind": "business", "notes": ["NOT FOUND in export"]})
        tr = []
        if p:
            for r in p.xquery_refs + p.xslt_refs:
                rr = resolve(r)
                t = transforms.get(rr) if rr else None
                tr.append(asdict(t) if t else {"ref": r, "kind": "?", "notes": ["NOT FOUND in export"]})
        # proxies that call other proxies (sb/local transport) are a chain, not a leaf
        chained = [b["ref"] for b in business if services.get(b["ref"]) and services[b["ref"]].kind == "proxy"]
        # every reference the flow's artefacts make, resolved against the export: missing ones block the migration
        all_refs = list(s.refs) + (list(p.refs) if p else [])
        for b in business:
            all_refs += b.get("refs", [])
        missing, seen = [], set()
        for r in all_refs:
            if resolve(r["ref"]) not in by_ref and r["ref"] not in seen:
                seen.add(r["ref"])
                missing.append({"ref": r["ref"], "referenced_from": r["via"]})
        flow = {"proxy": asdict(s), "pipeline": pd, "business": business, "transforms": tr, "chained_proxies": chained,
                "missing_refs": missing}
        tier, score, reasons = triage(flow)
        flow["triage"] = {"tier": tier, "score": score, "reasons": reasons}
        flows.append(flow)

    counts = Counter(a.kind for a in arts)
    tiers = Counter(f["triage"]["tier"] for f in flows)
    transports_in = Counter(f["proxy"].get("transport") for f in flows)
    transports_out = Counter(b.get("transport") for f in flows for b in f["business"])
    actions_total: Counter = Counter()
    for f in flows:
        if f["pipeline"]:
            actions_total.update(f["pipeline"]["action_counts"])
    fnbea_total = Counter(fn for t in transforms.values() for fn in t.fn_bea)
    fnbea_total.update(fn for p in pipelines.values() for fn in p.fn_bea_inline)
    unknown_total = Counter(u for p in pipelines.values() for u in p.unknown_actions)
    return {
        "root": str(root),
        "artefact_counts": dict(counts),
        "artefacts": [asdict(a) for a in arts],
        "flows": flows,
        "unreferenced_business_services": sorted(unreferenced_business),
        "summary": {
            "proxies": len(flows), "tiers": dict(tiers),
            "inbound_transports": dict(transports_in), "outbound_transports": dict(transports_out),
            "actions": dict(actions_total), "fn_bea": dict(fnbea_total), "unknown_actions": dict(unknown_total),
            "java_callouts": sum(len(f["pipeline"]["java_callouts"]) for f in flows if f["pipeline"]),
            "ws_policies": sum(1 for f in flows if f["proxy"]["ws_policies"] or any(b.get("ws_policies") for b in f["business"])),
        },
    }


def write_markdown(inv: dict, out: Path) -> None:
    s = inv["summary"]
    lines = ["# OSB export inventory", "", f"Source: `{inv['root']}`", ""]
    lines += ["## Summary", "", "| Item | Value |", "|---|---|"]
    lines.append(f"| Proxy services (flows) | {s['proxies']} |")
    lines.append(f"| Triage | " + ", ".join(f"{k}: {v}" for k, v in sorted(s['tiers'].items())) + " |")
    lines.append(f"| Artefacts | " + ", ".join(f"{k}: {v}" for k, v in sorted(inv['artefact_counts'].items())) + " |")
    lines.append(f"| Inbound transports | " + ", ".join(f"{k}: {v}" for k, v in s['inbound_transports'].items()) + " |")
    lines.append(f"| Outbound transports | " + ", ".join(f"{k}: {v}" for k, v in s['outbound_transports'].items()) + " |")
    lines.append(f"| Pipeline actions | " + ", ".join(f"{k}: {v}" for k, v in sorted(s['actions'].items())) + " |")
    lines.append(f"| fn-bea functions | " + (", ".join(f"{k}: {v}" for k, v in sorted(s['fn_bea'].items())) or "none") + " |")
    lines.append(f"| Java callouts | {s['java_callouts']} |")
    lines.append(f"| Flows with WS-Security policies | {s['ws_policies']} |")
    lines.append(f"| Unknown actions | " + (", ".join(f"{k}: {v}" for k, v in sorted(s['unknown_actions'].items())) or "none") + " |")
    lines.append(f"| Business services referenced by no proxy | {len(inv['unreferenced_business_services'])} |")
    n_missing = sum(len(f.get("missing_refs", [])) for f in inv["flows"])
    lines.append(f"| Referenced resources missing from the export | {n_missing} |")
    lines += ["", "## Flows (one row per proxy service)", "",
              "| Proxy | In | Binding | Pipeline | Ops | Actions | Routes to | Callouts | Publishes | XQ/XSL | Tier | Score | Why |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for f in sorted(inv["flows"], key=lambda x: (-x["triage"]["score"], x["proxy"]["ref"])):
        p = f["pipeline"] or {}
        pr = f["proxy"]
        lines.append("| " + " | ".join([
            f"`{pr['ref']}`", pr.get("transport") or "?", pr.get("binding") or "?",
            "inline" if pr.get("pipeline") == pr["ref"] else (pr.get("pipeline") or "none").split("/")[-1],
            str(len(p.get("operations", []))), str(sum(p.get("action_counts", {}).values())),
            str(len(p.get("routes_to", []))), str(len(p.get("callouts_to", []))), str(len(p.get("publishes_to", []))),
            str(len(p.get("xquery_refs", [])) + len(p.get("xslt_refs", []))),
            f["triage"]["tier"], str(f["triage"]["score"]), "; ".join(f["triage"]["reasons"]),
        ]) + " |")
    lines += ["", "## Triage thresholds", "",
              "simple < 12, medium < 28, complex >= 28 on the score in `osb_inventory.py::triage`. "
              "Uncalibrated: the first POC slice sets them. Reasons are listed so a reviewer can disagree per flow.", ""]
    miss_rows = [(f["proxy"]["ref"], m) for f in inv["flows"] for m in f.get("missing_refs", [])]
    if miss_rows:
        lines += ["## Referenced but missing from the export (blocking until provided)", "",
                  "| Flow | Missing resource | Referenced from |", "|---|---|---|"]
        lines += [f"| `{fl}` | `{m['ref']}` | `{m['referenced_from']}` |" for fl, m in miss_rows] + [""]
    if inv["unreferenced_business_services"]:
        lines += ["## Business services no proxy references", ""] + [f"- `{r}`" for r in inv["unreferenced_business_services"]] + [""]
    # decisions the export forces, derived from facts already extracted; the flow card repeats them per flow
    dec = []
    fnbea = sorted({fn for f in inv["flows"] for t in f["transforms"] for fn in t.get("fn_bea", [])}
                   | {fn for f in inv["flows"] if f["pipeline"] for fn in f["pipeline"].get("fn_bea_inline", [])})
    if fnbea:
        dec.append(f"`fn-bea:` functions used ({', '.join(fnbea)}): confirm each is covered by the shim table (expression mapping §4) or decide the rewrite; `execute-sql`, `lookupBasicCredentials`, `isUserIn*` need a redesign")
    jc = [(f["proxy"]["ref"], c) for f in inv["flows"] if f["pipeline"] for c in f["pipeline"].get("java_callouts", [])]
    if jc:
        dec.append("Java callouts: source of " + ", ".join(f"`{c.get('class')}`" for _, c in jc) + " must be provided or the flows are blocked")
    sas = sorted({b.get("service_account") for f in inv["flows"] for b in f["business"] if b.get("service_account")})
    if sas:
        dec.append("Service accounts " + ", ".join(f"`{x.split('/')[-1]}`" for x in sas) + ": Vault path and owner for each; static credentials never move into Git")
    pols = [f["proxy"]["ref"] for f in inv["flows"] if f["proxy"].get("ws_policies") or any(b.get("ws_policies") for b in f["business"])]
    if pols:
        dec.append(f"WS-Security policies on {len(pols)} flow(s): where the control lives on the target (gateway, mesh, Vault) before those flows are scheduled")
    jms = sorted({(b.get("uris") or ["?"])[0].split("/")[-1] for f in inv["flows"] for b in f["business"] if b.get("transport") == "jms"})
    if jms:
        dec.append("JMS destinations " + ", ".join(f"`{d}`" for d in jms) + " must exist on the target broker and be aligned with the queue-group register (messaging workstream owns the bridge)")
    alerts = sorted({d for f in inv["flows"] if f["pipeline"] for d in f["pipeline"].get("alert_destinations", [])})
    if alerts:
        dec.append("Alert destinations " + ", ".join(f"`{d.split('/')[-1]}`" for d in alerts) + ": which monitoring rule replaces each (no SNMP/email gateway is rebuilt)")
    missing = sorted({m["ref"] for f in inv["flows"] for m in f.get("missing_refs", [])})
    if missing:
        dec.append("Referenced resources missing from the export: " + ", ".join(f"`{m}`" for m in missing) + "; obtain them or confirm retirement")
    if any(f["proxy"].get("throttling") or any(b.get("throttling") for b in f["business"]) for f in inv["flows"]):
        dec.append("Throttling configured: route-level `throttle()` or leave it to the gateway")
    if any(f["proxy"].get("result_caching") or any(b.get("result_caching") for b in f["business"]) for f in inv["flows"]):
        dec.append("Result caching (Coherence) in use: cache component with the same key/TTL, or drop with a reason")
    dec.append("Recorded request/response traffic for the parity tests: OSB has no bulk export; agree the capture mechanism (Report action + provider, Test Console, or gateway logs) and the masking rules before the first slice")
    dec.append("Triage thresholds are uncalibrated: the first measured slice sets them; tier counts are not effort figures")
    lines += ["## Decisions this export forces (before migration starts)", ""] + [f"{i}. {d}" for i, d in enumerate(dec, 1)] + [""]
    (out / "INVENTORY.md").write_text("\n".join(lines), encoding="utf-8")


def write_dot(inv: dict, out: Path) -> None:
    def q(x: str) -> str:
        return '"' + x.replace('"', "'") + '"'
    lines = ["digraph osb {", "  rankdir=LR;", "  node [shape=box, fontsize=10];"]
    for f in inv["flows"]:
        pr = f["proxy"]["ref"]
        lines.append(f"  {q(pr)} [style=filled, fillcolor=\"#EAF9F4\", label={q(pr + chr(10) + f['triage']['tier'])}];")
        p = f["pipeline"] or {}
        for kind, refs, style in (("route", p.get("routes_to", []), "solid"), ("callout", p.get("callouts_to", []), "dashed"),
                                  ("publish", p.get("publishes_to", []), "dotted")):
            for r in refs:
                lines.append(f"  {q(pr)} -> {q(r)} [label=\"{kind}\", style={style}];")
        for r in p.get("xquery_refs", []) + p.get("xslt_refs", []):
            lines.append(f"  {q(pr)} -> {q(r)} [label=\"transform\", color=\"#8893A5\"];")
    lines.append("}")
    (out / "dependencies.dot").write_text("\n".join(lines), encoding="utf-8")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="OSB export directory, sbconfig.jar or .zip")
    ap.add_argument("-o", "--out", default="osb-inventory", help="output directory (default: ./osb-inventory)")
    args = ap.parse_args(argv)
    root, tmp = load_root(Path(args.source).expanduser().resolve())
    try:
        inv = build(root)
    finally:
        if tmp:
            tmp.cleanup()
    out = Path(args.out)
    (out / "flows").mkdir(parents=True, exist_ok=True)
    (out / "inventory.json").write_text(json.dumps(inv, indent=2, default=list), encoding="utf-8")
    for f in inv["flows"]:
        name = f["proxy"]["ref"].replace("/", "__")
        (out / "flows" / f"{name}.json").write_text(json.dumps(f, indent=2, default=list), encoding="utf-8")
    write_markdown(inv, out)
    write_dot(inv, out)
    s = inv["summary"]
    print(f"flows: {s['proxies']}  tiers: {s['tiers']}  unknown actions: {s['unknown_actions'] or 'none'}  -> {out}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
