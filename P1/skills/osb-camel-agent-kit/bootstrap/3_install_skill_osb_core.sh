#!/usr/bin/env bash
# Paste into the migration workspace root on the VDI and run: bash 3_install_skill_osb_core.sh
# Skill osb-to-camel: SKILL.md, scripts, references under .pi/skills/.
set -euo pipefail
mkdir -p "$(dirname ".pi/skills/osb-to-camel/SKILL.md")"
cat > '.pi/skills/osb-to-camel/SKILL.md' <<'KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_SKILL_MD'
---
name: osb-to-camel
description: Migrate Oracle Service Bus (OSB 11g/12c) flows to Apache Camel on Spring Boot, flow by flow, with a mocked JUnit test suite. Reads an OSB export (unzipped sbconfig.jar or JDeveloper OSB project with .proxy, .pipeline, .bix, .xqy, .xsl, .xsd and .wsdl files), inventories and triages flows, writes a design card per flow, then generates the RouteBuilder, adapted XQuery/XSLT, configuration keys and tests (AdviceWith route tests, WireMock backends, Testcontainers Artemis, golden tests against the original transform, parity replay). Use whenever OSB, Oracle Service Bus, sbconfig, proxy or business services, pipelines, XQuery flows or "ESB to Camel" are mentioned, including inventory, triage or estimation questions, even without the word migrate.
---

# OSB to Camel: migration factory for one flow or four hundred

An OSB flow is a proxy service (the contract and the inbound transport), a pipeline (stages of actions on a
message context), business services (the outbound endpoints) and transforms (XQuery, XSLT). Camel has an exact
counterpart for almost every piece, which is why this migration is repetitive, and why the repetitive part should be
done the same way every time. The skill fixes the order of work, the mapping tables and the test shape, so that the
450th flow is produced like the first and every flow arrives with its evidence.

Three things make an OSB migration go wrong, and the workflow is built around them:

1. **The behaviour lives in details nobody wrote down**: `contents-only` on a Replace, a `retry-count` on a business
   service, an error handler three scopes up, `$body` meaning the SOAP Body content rather than the envelope. The
   inventory script extracts them; the flow card forces a decision on each before code exists.
2. **XQuery is the real volume.** OSB queries are XQuery 1.0 with Oracle `fn-bea:` extensions. Saxon runs XQuery 3.1,
   which is a superset for everything except those extensions and a few `fn:doc`/collation habits. Keep the queries,
   rewrite only `fn-bea:`, and prove equivalence with golden tests run against the original query.
3. **Tests must not depend on the systems OSB talked to.** Every backend is a mock (WireMock for SOAP/REST, an Artemis
   container for JMS, in-memory for direct/local). The only "real" thing in a test is the route and the transform.

Design before code holds here as it does in camel-kit: a flow card is written and read before a route is generated.
When this skill runs inside camel-kit's pipeline, the card is the Phase 1/Phase 2 input and code generation belongs to
`camel-execute`; see `references/camel-kit-integration.md`. Standalone, the card is approved by the user (or by batch
decision for a tier) and the skill generates the code and the tests itself.

## Inputs you need, and what to do when they are missing

| Input | Why | If missing |
|---|---|---|
| The OSB export: a directory (unzipped `sbconfig.jar` or JDeveloper OSB project) or the `.jar`/`.zip` | Everything else derives from it | Stop. Ask for the export, or for read access to the OSB project repository. Never reconstruct a flow from a description |
| Target: Camel version, Spring Boot version, DSL (default Java DSL on Spring Boot), package base, repository layout | Generated code must match the team's build | Read `references/versions.md` for the defaults and say which defaults were applied |
| The Java callout jars' source, when the inventory lists `javaCallout` | A callout cannot be migrated from its class name | Generate a bean stub with the exact signature and a `TODO` that blocks the flow's done-state; list it as an open item |
| Recorded OSB traffic (request/response pairs from OSB message reporting, tracing, or the gateway logs), personal data masked | Parity replay, the strongest proof | Generate the replay test anyway, with the fixture directory empty and the test skipped-until-fixtures; say so in the record |
| WSDL/XSD for every SOAP proxy and business service | Contract tests and CXF endpoints | The inventory flags the missing reference; treat the flow as blocked, not as "any XML" |

## Workflow

### Step 0: inventory and triage (deterministic, run first, run once)

```bash
python3 <skill>/scripts/osb_inventory.py <export-dir-or-jar> -o osb-inventory
```

Read `osb-inventory/INVENTORY.md` end to end, then `osb-inventory/inventory.json` `summary`. The script resolves
proxy → pipeline → business services → transforms, counts every pipeline action, extracts transports, URIs, retries,
timeouts, service accounts, WS-policies, throttling, result caching, operational branches, error-handler scopes,
context variables, `fn-bea:` functions and external XQuery parameters, and scores each flow into `simple`, `medium`,
`complex` (`references/triage-rules.md` explains the score; it is uncalibrated until the first slice is measured).

Then establish, with the user, before any flow is touched:

- **Scope:** which flows (by name, by tier, by project folder, or all). Shared business services across flows are the
  natural grouping: one WireMock stub set and one configuration block serve every flow that calls the same backend.
- **Unknowns the report lists:** `unknown actions`, `NOT FOUND in export`, Java callouts without source, flows whose
  pipeline could not be resolved. Each is an open item on the affected flow card; none is silently skipped.
- **Target conventions:** confirm `references/versions.md` defaults or take the team's values; confirm the base package
  and where routes, resources and tests go (the templates assume one Maven module per OSB project folder, one
  `RouteBuilder` per proxy service).

If the inventory shows zero flows, the export is not what you think it is (wrong directory level, or an export of
resources only). Say so and stop.

### Step 1: flow card (design, no code)

For each flow in scope, scaffold the card and complete it:

```bash
python3 <skill>/scripts/scaffold_flow.py osb-inventory/flows/<flow>.json -o migration/<flow>/
```

The scaffold pre-fills `FLOW_CARD.md` from the inventory: contract and operations, the stage-by-stage action walk with
the proposed Camel step for each action (from `references/osb-action-mapping.md`), the backends with their proposed
components and configuration keys (from `references/osb-transport-mapping.md`), the transforms with their `fn-bea:`
functions and external parameters, the context variables, the error-handler scopes, and a test matrix with one row per
operation, per branch, per error path, per transform and per backend. It also lists the open questions it could not
answer from the export.

Your job on the card is judgement, not transcription:

- Read the actual pipeline XML and the transforms (paths are in the card). The script counts; it does not understand.
  Confirm each proposed mapping or replace it, and write one line of reason where you deviate.
- Decide the four things that decide the route's shape: SOAP 1.1 or 1.2 and document/literal from the binding; which
  context variables become headers, which become exchange properties (`references/osb-expression-mapping.md`,
  section "Context variables"); where each error handler scope lands (`onException` on the route, `doTry` around a
  stage, or a route-level `errorHandler`); and whether a publish is fire-and-forget (`response-required=false` →
  `InOnly` wire tap) or a callout in disguise.
- Record every behaviour the test suite must prove: branch conditions with the exact XQuery, retry and timeout values,
  fault shapes, header propagation.
- Mark anything you cannot settle from the export as an open item with an owner. Do not resolve it by assumption.

Present the card (or, in batch mode, the cards of a tier) and obtain approval before Step 2. For `simple` flows
approval can be a batch decision; for `complex` flows it should be per flow.

### Step 2: generate the Camel module

Generate from the approved card, using `assets/templates/java/` as the shape (read the template before writing; the
templates carry the conventions the team's reviewers will check):

- `RouteBuilder` per proxy service: route id = the OSB proxy name; one route per WSDL operation when the pipeline has an
  operational branch, dispatching from the inbound endpoint by operation; sub-routes (`direct:`) per OSB stage when a
  stage is reused or long; `routeId`/`description` on every route; `{{placeholders}}` for every endpoint, timeout and
  retry value, never literals.
- Inbound: `cxf:` endpoint with the original WSDL and port for SOAP proxies (the contract must not change: same WSDL,
  same `SOAPAction`, same namespaces), `platform-http`/`rest` for REST or any-XML proxies, `amqp:`/`jms:` for JMS
  proxies. Keep the OSB URI path as the Camel path so the Apigee route rule can switch per flow (`B2` in the
  programme roadmap: the cutover is an Apigee target change, not a client change).
- Transforms and expressions: copy each `.xqy`/`.xsl` into `src/main/resources/osb/<project>/...`, keep the file
  name, apply only the edits in `references/osb-expression-mapping.md` (the `fn-bea:` shim import). Run every OSB
  expression, inline or stored, through the `OsbXQuery` helper from the templates: it binds `$body`, `$inbound`,
  `$fault` and the pipeline variables by their OSB names, so expressions are pasted verbatim from the pipeline XML.
  Never paste an OSB expression into Camel's own `xquery()` language (it binds `$in.headers.*`, not `$body`), and never
  rewrite a working XQuery into Java "because it is cleaner"; equivalence is the goal, and the golden test proves it.
- `$body` boundaries: `wrap()` once at the inbound, `unwrap()` before **every** backend call, `rewrap()` after a
  request-response call, `unwrap()` at the reply (expression mapping §1). A backend must never receive the wrapper.
- Backends: one configuration block per business service (`osb.business.<Name>.url`, `.timeout`, `.retry-count`,
  `.retry-interval`), the component from the transport table, credentials as Vault-delivered properties never values.
  OSB `retry-count`/`retry-interval` become Camel redelivery on that endpoint's `onException`, not a global policy;
  `retry-application-errors=false` means retry only on transport failures.
- Error handling in the scope the card decided; an OSB `Reply with error` becomes a SOAP fault through CXF with the
  same fault shape the XSLT produced; `Resume` becomes `handled(true)` and continue.
- Logging to stdout through the application's logger (ECS JSON on this programme), with the correlation header the
  pipeline propagated; `alert` actions become a log line at WARN with a stable marker and a counter metric.

Do not generate anything the card did not approve; do not "improve" the contract; do not add components that are not
in `references/versions.md` without saying why.

### Step 3: generate the test suite (mocks everywhere)

Follow `references/test-strategy.md`. Every flow gets, from the templates in `assets/templates/java/`:

| Test | Proves | Mocked with |
|---|---|---|
| `<Flow>RouteTest` | Every operation, branch and error path of the pipeline, in isolation | `@CamelSpringBootTest`, `@UseAdviceWith`, `AdviceWith` replacing each backend endpoint with `mock:`; one `@Test` per test-matrix row |
| `<Transform>GoldenTest` | The adapted XQuery/XSLT produces what the original produced | The original query run by Saxon with the `fn-bea` shim module; XMLUnit comparison with an ignore list for timestamps |
| `<Flow>BackendContractTest` | Requests leave in the shape the backend expects; timeouts and retries behave as the business service was configured | WireMock stubs per business service (`SOAPAction` + XPath matching); a delayed stub to force the timeout and count retries |
| `<Flow>JmsPublishTest` | Publish is fire-and-forget, body and headers as the pipeline built them | Testcontainers `ArtemisContainer` (or embedded broker when Docker is unavailable, the test says which) |
| `<Flow>ParityReplayTest` | Recorded OSB request → identical response from Camel, with the backends replayed | Recorded pairs under `src/test/resources/parity/<flow>/`; WireMock replays the recorded backend exchanges; XMLUnit with `ignore-fields.txt` |

If the card lists a database, DVM/XRef lookup, Java callout, file/FTP/SFTP, email or module-level security, add the
matching interface-mock test as well (`references/test-strategy.md`, "Interface mocks beyond JMS and HTTP"): the
templates are `DatabaseMockTestTemplate`, `DvmLookup` + `LookupMockTestTemplate`, `JavaCalloutMockTestTemplate`,
`FileSftpMockTestTemplate`, `EmailMockTestTemplate`, `SecurityMockTestTemplate`, with support files in
`assets/templates/mocks/`.

Test inputs come from the WSDL/XSD (one valid message per operation, values traceable to the field name) and from the
branch conditions on the card (one input per side of every condition). Expected outputs for transforms are generated,
not hand-written: run the original transform. If Saxon cannot run an original query because of an `fn-bea:` function
the shim does not cover, that is a finding on the card, not a reason to hand-write the expectation.

Run the suite (`mvn -q test` in the module). A flow is not "migrated" with a red or skipped test unless the record says
why (missing parity fixtures, Java callout without source).

### Step 4: migration record and status

Write `migration/<flow>/MIGRATION_RECORD.md` from `assets/templates/MIGRATION_RECORD.md`: the action-to-code map
(OSB action id → Camel step), the test matrix with results, every deviation from the original behaviour with its
reason, the configuration keys and their sources, the open items with owners, and the cutover note (the Apigee route
rule to switch, the OSB proxy to leave deployed until the soak ends). Update `osb-inventory/STATUS.md` (flow, tier,
state, tests green/red, open items). The record is what the reviewer, the tester and the estimate reconciliation read;
write it for them.

### Batch mode

For a tier or a project folder: Step 0 once, Step 1 for all flows in the batch, one approval, Steps 2 to 4 per flow in
order of shared backends (flows sharing a business service share the WireMock stub set and the configuration block,
generate those once). Keep a running `STATUS.md`. Stop the batch and report when three flows in a row produce an
unknown action, a missing resource, or a shim gap: the mapping tables need an entry before more flows are produced.

## What this skill does not do

- It does not decide the cutover, the Apigee change or the OSB retirement; it produces the code, the tests and the
  record that make those decisions safe. Operational steps go into the record as proposals.
- It does not migrate Oracle JMS or AQ destinations; a business service on `jms://` becomes a Camel endpoint on the
  target broker and the record notes the destination that must exist there (the messaging migration owns the bridge).
- It does not translate WS-Security policies into mesh or gateway configuration; it records the policy references and
  marks the flow blocked until the security owner decides where that control lives.
- It does not estimate. The triage tier and the per-flow counts are inputs for whoever owns the estimate.

## References (read when the step needs them)

| File | Read when |
|---|---|
| `references/osb-action-mapping.md` | Step 1, every flow: pipeline action → Camel step, with the traps per action |
| `references/osb-transport-mapping.md` | Step 1 and 2: transport → component, configuration keys, programme constraints |
| `references/osb-expression-mapping.md` | Step 1 to 3: XQuery/XPath/XSLT handling, `fn-bea:` table, context variables, the `$body` root rule |
| `references/test-strategy.md` | Step 3: what each test proves, how fixtures are produced, what "mocked" means here |
| `references/triage-rules.md` | Step 0: how the score is built and how to recalibrate it after the first slice |
| `references/camel-kit-integration.md` | When camel-kit is installed in the target repository, or the user asks how this relates to `/camel-migrate` |
| `references/programme-rules.md` | Step 1 and 2 on the target platform: runtime, logging, Vault, messaging, coexistence bridges, open programme decisions. Wins over the generic tables |
| `references/versions.md` | Step 0 and 2: default versions and artifacts; update it when the team pins others |
| `assets/templates/` | Step 1 to 4: the card, the record, the Java templates, the Maven dependency fragment, the test properties |
KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_SKILL_MD
mkdir -p "$(dirname ".pi/skills/osb-to-camel/scripts/osb_inventory.py")"
cat > '.pi/skills/osb-to-camel/scripts/osb_inventory.py' <<'KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_SCRIPTS_OSB_INVENTORY_PY'
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
        parts = ref.split("/")
        for i in range(1, len(parts)):          # export rooted at the project folder: drop the leading project name(s)
            if "/".join(parts[i:]) in by_ref and i < len(parts) - 1:
                return "/".join(parts[i:])
        two = "/".join(parts[-2:])              # Folder/Name is unique where Name alone is not (proxy + pipeline + bix share it)
        cands = [r for r in by_ref if r.endswith("/" + two) or r == two]
        if len(cands) == 1:
            return cands[0]
        tail = parts[-1]
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
KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_SCRIPTS_OSB_INVENTORY_PY
mkdir -p "$(dirname ".pi/skills/osb-to-camel/scripts/osb_shape_export.py")"
cat > '.pi/skills/osb-to-camel/scripts/osb_shape_export.py' <<'KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_SCRIPTS_OSB_SHAPE_EXPORT_PY'
#!/usr/bin/env python3
"""Shape-only copy of an OSB project, shareable outside the client machine: keeps every structural fact the migration
tooling needs (which actions, how they nest, which attributes, which functions, which files reference which) and
replaces every business-specific value by a consistent token. Stdlib only.

    osb_shape_export.py <osb project folder> -o <out folder> [--salt <text>]

Kept as is:    XML element and attribute names, structural attribute values (type, contents-only, varName, id,
               xsi:type, maxOccurs, minOccurs, nxsd:version, nxsd:jsonNestedArray ...), numbers, XQuery/XPath syntax,
               function calls (fn:, fn-bea:, xs:, local:), variable names, OSB namespaces (bea.com, oracle.com, w3.org).
Tokenised:     file and folder names, ref="..." paths, stage/branch/pipeline names, service names, business
               namespaces, element names inside XQuery/XSD/XPath, header names, queue/JNDI names, URLs, hosts.
               Same original -> same token (sha256 with --salt), so cross-references still line up.
Replaced:      string literals in expressions -> 's1', 's2' ... (per distinct value), comments dropped.
Result:        the same file tree with the same extensions; a MANIFEST.json with counts per action type and per
               fn-bea function (no originals). Review the output once before sharing; the mapping is NOT written."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from collections import Counter
from pathlib import Path

KEEP_NS = ("bea.com", "oracle.com", "w3.org", "xmlsoap.org", "xml.org", "schemas.xmlsoap.org")
KEEP_ATTR = {"type", "contents-only", "id", "xsi:type", "maxOccurs", "minOccurs", "use", "nillable",
             "elementFormDefault", "attributeFormDefault", "version", "encoding", "errorHandler", "error-handler",
             "mixed", "abstract", "value"}
KEEP_ATTR_PREFIX = ("nxsd:", "xmlns")
STRUCT_VALUES = {"true", "false", "request", "response", "error", "Native-To-XML", "XML-To-Native", "unbounded", "qualified",
                 "unqualified", "expression", "Text", "Binary", "XML", "JSON", "ref:BusinessServiceRef", "ref:ProxyRef",
                 "ref:PipelineRef", "ref:XqueryRef", "ref:XsdRef", "ref:WsdlRef", "ref:XsltRef", "ref:MflRef", "ref:ServiceAccountRef",
                 "ref:JarRef", "ref:ArchiveRef"}
FUNC_PREFIX = ("fn:", "fn-bea:", "xs:", "xsd:", "xsi:", "ctx:", "con:", "con1:", "con2:", "con3:", "tp:", "http:", "jms:", "env:",
               "soap-env:", "xdt:", "math:", "map:", "array:", "jms-ctx:")          # OSB context / vendor prefixes: structural
KEEP_VARS = {"body", "inbound", "outbound", "fault", "header", "request", "response", "attachments", "operation", "uuId", "uuid"}
SYNTAX = set("""xquery version encoding declare namespace variable function external return let for where order by if then else
  element attribute node text document data concat string number count sum exists empty not and or div mod eq ne lt gt le ge
  true false as at import schema default collation boundary-space preserve strip option local fn xs xsi xsd typeswitch case
  satisfies some every instance of castable cast treat union intersect except to ascending descending null""".split())
TAG_RX = re.compile(r"<(/?)([A-Za-z_][\w.-]*:)?([A-Za-z_][\w.-]*)")
ATTR_RX = re.compile(r'\s([A-Za-z_][\w:.-]*)="([^"]*)"')
STRING_RX = re.compile(r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"")
IDENT_RX = re.compile(r"(?<![\w:$-])([A-Za-z_][\w.-]*):([A-Za-z_][\w.-]*)|(?<![\w:$-])\*:([A-Za-z_][\w.-]*)")
VAR_RX = re.compile(r"\$([A-Za-z_][\w.-]*)")
STEP_RX = re.compile(r"(?<=/)(@?)([A-Za-z_][\w.-]*)(?![\w(:.-])")
URL_RX = re.compile(r"[a-z][a-z0-9+.-]*://[^\s\"'<>]+")
COMMENT_XML = re.compile(r"<!--.*?-->", re.S)
EXPR_TAGS = {"xqueryText", "xpathText", "condition", "expr", "javaScript", "javascript", "xqueryTextExpr", "script", "value"}
COMMENT_XQ = re.compile(r"\(:.*?:\)", re.S)


class Tok:
    def __init__(self, salt: str):
        self.salt, self.strings, self.counts = salt, {}, Counter()

    def name(self, s: str, kind: str = "n") -> str:
        if not s:
            return s
        h = hashlib.sha256((self.salt + "|" + s).encode("utf-8")).hexdigest()[:8]
        return f"{kind}{h}"

    def string(self, s: str) -> str:
        if s not in self.strings:
            self.strings[s] = f"s{len(self.strings) + 1}"
        return self.strings[s]

    def path(self, p: str) -> str:
        parts = p.replace("\\", "/").split("/")
        out = []
        for part in parts:
            stem, dot, ext = part.rpartition(".")
            out.append(self.name(stem, "f") + dot + ext if dot and len(ext) <= 12 else self.name(part, "f"))
        return "/".join(out)


def keep_ns(uri: str) -> bool:
    return any(k in uri for k in KEEP_NS)


def tok_expr(text: str, t: Tok) -> str:
    """XQuery / XPath text: keep syntax and functions, tokenise business names and literals."""
    text = COMMENT_XQ.sub("", text)
    text = STRING_RX.sub(lambda m: "'" + t.string(m.group(0)[1:-1]) + "'", text)
    text = URL_RX.sub(lambda m: m.group(0) if keep_ns(m.group(0)) else "http://" + t.name(m.group(0), "ns") + "/", text)

    def ident(m):
        if m.group(3):                      # *:name
            return "*:" + t.name(m.group(3), "e")
        pfx, local = m.group(1), m.group(2)
        if (pfx + ":") in FUNC_PREFIX:
            return m.group(0)               # function, type or OSB context element: keep
        if pfx == "local":
            return "local:" + t.name(local, "fn")
        return f"{pfx}:{t.name(local, 'e')}"
    text = IDENT_RX.sub(ident, text)
    text = re.sub(r"&lt;(/?)([A-Za-z_][\w.-]*:)?([A-Za-z_][\w.-]*)",            # escaped element constructors in expressions
                  lambda m: f"&lt;{m.group(1)}{m.group(2) or ''}{t.name(m.group(3), 'e')}", text)
    text = re.sub(r"&gt;([^&{}<>$]+?)&lt;", lambda m: "&gt;" + (m.group(1) if not m.group(1).strip() or re.fullmatch(r"[\d\s.-]+", m.group(1)) else t.name(m.group(1).strip(), "t")) + "&lt;", text)
    text = VAR_RX.sub(lambda m: m.group(0) if m.group(1) in KEEP_VARS else "$" + t.name(m.group(1), "v"), text)
    return STEP_RX.sub(lambda m: m.group(0) if m.group(2) in SYNTAX else m.group(1) + t.name(m.group(2), "e"), text)


def tok_xml(text: str, t: Tok, counts: Counter) -> str:
    text = COMMENT_XML.sub("", text)
    out, pos, last = [], 0, ""
    for m in re.finditer(r"<[^>]+>", text):
        between = text[pos:m.start()]
        v = between.strip()
        if not v:
            out.append(between)
        elif last in EXPR_TAGS:
            out.append(tok_expr(between, t))
        elif v in STRUCT_VALUES or re.fullmatch(r"-?\d+(\.\d+)?", v) or keep_ns(v):
            out.append(between)
        else:
            out.append(between.replace(v, t.name(v, "t")))
        tag = m.group(0)
        tm0 = TAG_RX.match(tag)
        if tm0 and not tm0.group(1):
            last = tm0.group(3)
        if tag.startswith("<?") or tag.startswith("<!"):
            out.append(tag)
        else:
            tm = TAG_RX.match(tag)
            if tm and not tm.group(1):
                counts[tm.group(3)] += 1

            def attr(a):
                k, v = a.group(1), a.group(2)
                if k in ("select", "match", "test", "use-when"):
                    return f' {k}="{tok_expr(v, t)}"'
                if k.startswith(KEEP_ATTR_PREFIX):
                    return f' {k}="{v if keep_ns(v) else "http://" + t.name(v, "ns") + "/"}"' if k.startswith("xmlns") and v else a.group(0)
                if v in STRUCT_VALUES or re.fullmatch(r"-?\d+(\.\d+)?", v):
                    return a.group(0)
                if k in ("type", "base", "ref") and tm and tm.group(2) and tm.group(2).rstrip(":") in ("xs", "xsd"):
                    pfx, _, local = v.rpartition(":")
                    return a.group(0) if pfx in ("xs", "xsd") else f' {k}="{pfx + ":" if pfx else ""}{t.name(local, "e")}"'
                if k in KEEP_ATTR and k != "type":
                    return a.group(0)
                if k == "type":
                    pfx, _, local = v.rpartition(":")
                    return a.group(0) if pfx in ("xs", "xsd") or not pfx and v in STRUCT_VALUES else f' {k}="{pfx + ":" if pfx else ""}{t.name(local, "e")}"'
                if k == "ref":
                    return f' ref="{t.path(v)}"'
                if k in ("varName", "variable", "var") :
                    return a.group(0) if v in KEEP_VARS else f' {k}="{t.name(v, "v")}"'
                if k == "name" and tm and tm.group(3) in ("element", "attribute", "complexType", "simpleType", "group"):
                    return f' name="{t.name(v, "e")}"'
                return f' {k}="{t.name(v)}"'
            out.append(ATTR_RX.sub(attr, tag))
        pos = m.end()
    tail = text[pos:]
    out.append(tok_expr(tail, t) if tail.strip() else tail)
    return "".join(out)


def tok_xquery(text: str, t: Tok) -> str:
    text = COMMENT_XQ.sub("", text)
    head = re.match(r'\s*xquery version "[^"]*"( encoding "[^"]*")?;', text)
    keep_head = head.group(0) if head else ""
    text = text[len(keep_head):]
    # element constructors <ns:name ...> inside XQuery: tokenise local names, keep namespaces of known vendors
    def tag(m):
        slash, pfx, local = m.group(1), m.group(2) or "", m.group(3)
        return f"<{slash}{pfx}{t.name(local, 'e')}"
    text = TAG_RX.sub(tag, text)
    text = re.sub(r'declare namespace (\w+)="([^"]*)"', lambda m: f'declare namespace {m.group(1)}="{m.group(2) if keep_ns(m.group(2)) else "http://" + t.name(m.group(2), "ns") + "/"}"', text)
    text = re.sub(r'import schema (namespace \w+=)?"[^"]*" at "([^"]*)"', lambda m: f'import schema {m.group(1) or ""}"http://{t.name(m.group(0), "ns")}/" at "{t.path(m.group(2))}"', text)
    return keep_head + tok_expr(text, t)


def residue(src: Path, out: Path) -> list:
    """Words of 4+ letters left in the output that are not XML element/attribute names of the output (structural, kept
    by design), not syntax, not vendor namespaces and not generated tokens. Whatever is listed came through
    untokenised and must be checked by a person before the folder is shared."""
    words = lambda t: set(re.findall(r"[A-Za-z][A-Za-z]{3,}", t))
    pieces = lambda names: {w for n in names for w in re.findall(r"[A-Za-z][A-Za-z]{3,}", n)}
    outw, struct = set(), set()
    for f in out.rglob("*"):
        if f.is_file() and f.name != "MANIFEST.json":
            t = f.read_text(encoding="utf-8")
            outw |= words(t)
            struct |= pieces(re.findall(r"<[/]?(?:[\w.-]+:)?([A-Za-z_][\w.-]*)", t)) | pieces(re.findall(r"\s([A-Za-z_][\w:.-]*)=\"", t))
            struct |= pieces(re.findall(r'\s(?:xsi:type|type|use|version|encoding)="([^"]*)"', t))
    vendor = words(" ".join(KEEP_NS)) | {"http", "https", "www", "schemas", "xmlsoap", "xmlns", "soap", "envelope", "wsdl", "wli"}
    token = re.compile(r"^(?:[efntv]|fn|ns|p)[0-9a-f]{8}$")
    return sorted(w for w in outw - struct - vendor
                  if w.lower() not in SYNTAX and w not in STRUCT_VALUES and not token.match(w) and not re.fullmatch(r"[a-f]+", w))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("project", type=Path)
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--salt", default="osb-shape", help="changes every token; keep it private, it is not stored")
    a = ap.parse_args()
    if a.out.exists():
        shutil.rmtree(a.out)
    t = Tok(a.salt)
    counts: Counter = Counter()
    fnbea: Counter = Counter()
    files = 0
    for f in sorted(p for p in a.project.rglob("*") if p.is_file()):
        rel = f.relative_to(a.project)
        dst = a.out / Path(t.path(str(rel.parent))) / (t.name(f.stem, "f") + f.suffix.lower()) if str(rel.parent) != "." else a.out / (t.name(f.stem, "f") + f.suffix.lower())
        dst.parent.mkdir(parents=True, exist_ok=True)
        ext = f.suffix.lower()
        try:
            text = f.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            dst.with_suffix(ext + ".binary").write_text(f"binary file, {f.stat().st_size} bytes\n", encoding="utf-8")
            files += 1
            continue
        fnbea.update(re.findall(r"\bfn-bea:([A-Za-z0-9_-]+)", text))
        if ext in (".xqy", ".xq", ".xquery"):
            dst.write_text(tok_xquery(text, t), encoding="utf-8")
        elif text.lstrip().startswith("<"):
            dst.write_text(tok_xml(text, t, counts), encoding="utf-8")
        else:
            dst.write_text(f"text file, {len(text)} chars, not copied\n", encoding="utf-8")
        files += 1
    (a.out / "MANIFEST.json").write_text(json.dumps({"project": t.name(a.project.name, "p"), "files": files,
                                                      "xml_elements": dict(counts.most_common()), "fn_bea": dict(fnbea.most_common()),
                                                      "string_literals_replaced": len(t.strings)}, indent=2), encoding="utf-8")
    print(json.dumps({"out": str(a.out), "files": files, "fn_bea": dict(fnbea), "strings_replaced": len(t.strings)}))
    left = residue(a.project, a.out)
    print(f"residue check: {len(left)} original word(s) still present (XML element/attribute names and syntax excluded)")
    if left:
        print("  " + ", ".join(left[:40]) + (" ..." if len(left) > 40 else ""))
        print("  these are either harmless structural words or a leak: check them before sharing the folder")
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_SCRIPTS_OSB_SHAPE_EXPORT_PY
mkdir -p "$(dirname ".pi/skills/osb-to-camel/scripts/scaffold_flow.py")"
cat > '.pi/skills/osb-to-camel/scripts/scaffold_flow.py' <<'KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_SCRIPTS_SCAFFOLD_FLOW_PY'
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
KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_SCRIPTS_SCAFFOLD_FLOW_PY
mkdir -p "$(dirname ".pi/skills/osb-to-camel/references/camel-kit-integration.md")"
cat > '.pi/skills/osb-to-camel/references/camel-kit-integration.md' <<'KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_CAMEL_KIT_INTEGRATION_MD'
# Using this skill with camel-kit

[camel-kit](https://github.com/luigidemasi/camel-kit) (Apache-2.0, v0.4.1 at the time of writing, actively developed)
installs a Spec-Kit-style workflow into Claude Code, Copilot, Codex and others: `/camel-start → /camel-migrate →
/camel-plan → /camel-execute → /camel-validate`, with a knowledge MCP for the Camel catalog, a project graph, Citrus
tests, and a set of "iron laws" (design approval before code, catalog verification of every component, adversarial
review). Its `/camel-migrate` has vendor adapters for MuleSoft, BizTalk, Camel 2/3 and JBoss Fuse. **It has no OSB
adapter**, no OSB parser in `camel-kit-graph`, and its examples contain no OSB artefact.

This skill is the OSB adapter in camel-kit's shape, written so that it works standalone and can slot into the camel-kit
pipeline without re-explaining itself.

## Correspondence

| camel-kit concept | This skill |
|---|---|
| Vendor detection row (`camel-migrate/SKILL.md` Step 3) | OSB signals: files `.proxy`/`.pipeline`/`.bix` (12c project) or `.ProxyService`/`.Pipeline`/`.BusinessService` (sbconfig export); root namespaces `http://www.bea.com/wli/sb/services`, `http://www.bea.com/wli/sb/pipeline/config`; `fn-bea:` in XQuery |
| Graph acceleration (`camel-kit-graph` parsers; `graph stats` node types) | `scripts/osb_inventory.py` → `inventory.json` and `dependencies.dot`. Node types to add upstream: `OSB_PROXY`, `OSB_PIPELINE`, `OSB_BUSINESS_SERVICE`, `OSB_TRANSFORM` |
| Phase 1 guide (`<vendor>-phase1.md`: inventory, adapters, business requirements) | Step 0 + the flow card's sections 1, 4, 7, 9; `osb-transport-mapping.md` plays the role of `<vendor>-component-mapping.md` |
| R1 behavioural analysis and source-retirement audit (`migration-analysis.md`, `source-retirement-audit.md`) | The inventory's `unreferenced_business_services`, `NOT FOUND` references and `chained_proxies` are the retirement-audit inputs; the card's section 6 and 7 carry the behavioural risks |
| Phase 2 guide (`<vendor>-phase2.md`: design spec per flow, sections 1–11) | The flow card is that per-flow design: contract, source, processing steps with a field-mapping audit trail, sink, error handling, configuration, dependencies, testing strategy, checklist |
| `<vendor>-expression-mapping.md`, `<vendor>-map-conversion.md`, `<vendor>-pipeline-mapping.md` | `osb-expression-mapping.md` (XQuery/XSLT/context), `osb-action-mapping.md` (pipeline) |
| `camel-plan` task template for migrations | Steps 2–4 of SKILL.md, one task per flow; in camel-kit, the plan generates them |
| `camel-execute` (implementation under iron laws) | Step 2, standalone. Inside camel-kit, do **not** generate code from this skill; hand the card to the plan and let `camel-execute` implement, loading `osb-*-mapping.md` as implementer context |
| `camel-test` (Citrus YAML + Testcontainers) | `test-strategy.md` (JUnit 5 + AdviceWith + WireMock + Testcontainers). Both can coexist |
| `camel-validate` static gate | Run it on the generated module if routes are YAML; for Java DSL, the constitution checks (route ids, descriptions, placeholders, no hardcoded endpoints) are in the templates and the record's checklist |
| `shared/flow-test-data.md` fixture rules | The fixture rules in `test-strategy.md` follow the same naming and value conventions on purpose |

## Two deliberate differences

1. **Java DSL on Spring Boot, not YAML DSL on Camel Main.** The programme's integration code lives inside Spring Boot
   domain services maintained by Java teams, and `AdviceWith`-based isolation of pipeline branches is a Java-side
   capability. camel-kit supports the Spring Boot runtime; its Ship controller and some validators prefer YAML. If a
   team adopts camel-kit fully, the card is runtime-neutral and the mapping tables carry a YAML column where it matters.
2. **No MCP catalog gate inside this skill.** camel-kit's Iron Law 1 verifies every component against the Camel
   catalog through its knowledge MCP. Standalone, this skill pins components and versions in `versions.md`; when the MCP
   is available, verify the components the card proposes before generating code, exactly as the iron law asks.

## Running inside a camel-kit project

1. `camel-kit init --here --ai claude` in the target repository (installs its skills under `.claude/`).
2. Copy this skill next to them (`.claude/skills/osb-to-camel/`), or keep it user-scoped.
3. Run `/camel-start` and point it at the OSB export; when it reports an unknown vendor, invoke this skill's Step 0 and
   Step 1 to produce the cards, then feed `/camel-plan` with the cards as the approved design package
   (`business-requirements.md` = inventory summary + scope; `design-spec.md` = the cards; `migration-analysis.md` =
   the open items and retirement audit).
4. Let `/camel-execute` implement with `references/osb-*.md` as context, and run both test suites.

## Contributing upstream

The adapter is deliberately shaped like `biztalk-*.md`. To contribute it: `osb-phase1.md` (from SKILL.md Step 0–1 and
the card template), `osb-phase2.md` (from the card's design sections), `osb-action-mapping.md`,
`osb-expression-mapping.md`, `osb-transport-mapping.md` as shared guides, a vendor row in `camel-migrate/SKILL.md`,
and an `OsbParser` in `camel-kit-graph` porting `osb_inventory.py`. The `examples/osb-contributor-enquiry/` fixture in
`evals/fixtures/` is a ready example project.
KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_CAMEL_KIT_INTEGRATION_MD
mkdir -p "$(dirname ".pi/skills/osb-to-camel/references/osb-action-mapping.md")"
cat > '.pi/skills/osb-to-camel/references/osb-action-mapping.md' <<'KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_OSB_ACTION_MAPPING_MD'
# OSB pipeline action → Camel step

How to read this: the OSB column is the action's local XML name as the inventory reports it. "Camel (Java DSL)" is the
default proposal the scaffold writes on the flow card. "Trap" is the detail that produces a behavioural difference if
ignored; most of them are not visible in the OSB console and only exist in the XML.

Vocabulary of the message context, used throughout: OSB's `$body` is the **content of the SOAP Body** (for SOAP
services) or the whole payload (for XML/any services); `$header` is the SOAP Header; `$inbound`/`$outbound` are the
transport and service metadata; `$fault` exists only in error handlers. In Camel the message body is the whole payload
the component delivered; with `camel-cxf` in `PAYLOAD` mode it is the SOAP Body content, which is the closest match and
the reason the templates use that mode. See `osb-expression-mapping.md` for the variable mapping.

## Message processing actions

| OSB action | What it does | Camel (Java DSL) | Trap |
|---|---|---|---|
| `assign` (varName, expr) | Evaluates XQuery/XPath into a named context variable | `.setProperty("<varName>", OsbXQuery.of(<expr>).ns(NS).asNode())` for XML values, `.asString()` for scalars (expression mapping §5). Properties, never headers, unless the value must cross a wire | OSB variables are document fragments; an `assign` of `$body/ns:x/text()` yields a text node, not a string. Type the Camel expression explicitly (`String.class`) or the next XQuery sees a different node kind |
| `replace` (varName, contents-only="true") | Replaces the **children** of the selected node | `.process(OsbXQuery.of(<expr>).ns(NS).replaceBodyContentsOnly())` when the variable is `body` (`replaceBody()` for contents-only=false); for a sub-node, an XSLT/XQuery that rebuilds the parent with new children | `contents-only="true"` keeps the wrapper element; `"false"` replaces the node itself. Getting this wrong changes the root element the next step sees and every downstream XPath breaks silently |
| `replace` with `xqueryTransform` resource | Runs a stored `.xqy` with named parameters | `.process(OsbXQuery.resource("osb/<project>/Transform/<Name>.xqy").ns(NS).param(<osbParam>, <property>[, <path>])...replaceBodyContentsOnly())` (expression mapping §5) | Parameters are bound by name; OSB passes node sequences, Camel passes whatever the header holds. Bind `Document`/`Node` objects for element parameters, not strings |
| `replace` with `xsltTransform` | Runs a stored `.xsl` | `.to("xslt-saxon:classpath:osb/<project>/<Name>.xsl")`; XSLT parameters from headers (`transformerFactory` defaults suffice) | The `input` of the OSB XSLT is often `$fault` or a variable, not `$body`. Set the body to that variable first, then transform, then restore |
| `insert` (location, where=before/after/first-child/last-child) | Inserts a fragment relative to an XPath | An XQuery/XSLT that rebuilds the parent, or a small `Processor` using DOM. Prefer XQuery: it stays declarative and testable with the golden test | Four `where` modes; `first-child` and `last-child` are the common ones. Write the XQuery per mode, do not approximate |
| `delete` (location) | Removes nodes | XSLT identity template with an empty template for the path, or XQuery `copy-modify` is not in 3.1 core: use XSLT | Deleting `$body` children versus the variable itself (same `contents-only` logic) |
| `rename` (location, localname/namespace) | Renames an element | XSLT identity template with a renaming template | Namespace renames usually also need the prefix fixed in the children; test with the golden test, not by eye |
| `javaCallout` (archive, class, method, params) | Calls a static Java method from an uploaded jar | `.bean(<Class>, "<method>")` with the parameters bound from headers/properties; port the class into the module if its source exists | Without the jar's source the method cannot be reproduced. Generate the bean with the exact signature and a failing `TODO` test; block the flow's done-state |
| `mflTransform` | Binary/flat-file ↔ XML via MFL | `bindy` (fixed-length/CSV) or `flatpack`, or a custom `DataFormat`; the MFL file is the spec | Padding, justification and code pages are in the MFL. Golden tests with real sample files are mandatory; there is no shim |
| `nXSDTransform` / `nxsdTranslation` | Native XSD (JCA-style) translation, Native-To-XML or XML-To-Native | JSON nXSD (`nxsd:version="JSON"`, appinfo `NXSDSAMPLE`/`USEHEADER`): a small processor that reads the JSON with Jackson and writes the target element in the nXSD namespace and element order; delimited/fixed-length: `camel-bindy` or a hand parser. Then keep the downstream XQuery unchanged | As MFL; golden test = OSB's own nXSD output for recorded native inputs (OSB test console), never the processor's output. Empty/missing JSON fields: replicate OSB (usually empty elements) |
| `validate` (schema, schemaElement, location, resultVar) | Validates a node against an XSD element | `.to("validator:classpath:osb/<project>/<Schema>.xsd")`; set the body to the `location` node first if it is not the body | OSB `validate` can write a boolean into `resultVar` instead of raising. Mirror that: `doTry/doCatch(ValidationException)` setting a property when the pipeline branches on the result |
| `javaScript` (12c JavaScript action: script over `$body`/variables, JSON-friendly) | Runs a script in the pipeline | `.process()` with a small Java class, or Camel's `js` language (`camel-javascript`) only if the team accepts GraalJS at runtime | Scripts often mutate several variables and build JSON; port to Java and prove with a golden test on the inputs the script saw |
| `routingOptions` (12c Routing Options: URI, QoS exactly-once, mode, retry, priority overrides on an outbound) | Overrides the business service settings for that call | `setHeader(Exchange.HTTP_URI)`/`toD` for the URI override; `transacted()`/InOnly for QoS; endpoint options for retries | An override hidden inside a route or publish action beats the business service's configuration; the card must show the effective values |
| `transportHeaders` (header-set=inbound-response / outbound-request, copy-all, header name/value) | Sets or copies transport headers | `.setHeader("<name>", ...)` / `.removeHeaders("*", <keep>)`; `copy-all=true` → propagate the inbound headers (Camel does by default) | Camel propagates **all** headers by default; OSB only when `copy-all`. With `copy-all=false`, strip inbound headers before the outbound call (`removeHeaders("*", "SOAPAction", "Content-Type", "X-Correlation-Id")`) or the backend receives client headers it never saw before |

## Communication actions

| OSB action | What it does | Camel (Java DSL) | Trap |
|---|---|---|---|
| `route` (service, operation, outbound/response transform) | Terminal request-response call to a business service; the response becomes the proxy response | `.process(OsbBodyWrapper.unwrap()).to("<backend-endpoint>").process(OsbBodyWrapper.rewrap())` as the last step of the request path; the response pipeline continues after it | A route node is terminal: nothing in the request pipeline runs after it, and the response pipeline runs on the way back. In Camel that is simply the steps after `.to()`. The `outboundTransform`/`responseTransform` inside the route node are ordinary replace actions: map them |
| `routeTable` (cases on an expression) | Routes to different services by a value | `.choice().when(xpath/xquery).to(...).otherwise()...` | One `when` per case; the `default` case is `otherwise`. The test matrix needs one input per case |
| `dynamicRoute` (service ref computed) | Target computed at runtime from a variable | `.toD("${exchangeProperty.target}")` or `recipientList` | The computed target in OSB is a **service reference**, not a URL. Build a lookup property → endpoint map and fail fast on an unknown key |
| `wsCallout` (service, operation, request/response bodies, headers) | Synchronous call in the middle of a pipeline, result into variables | Save the wrapped body to a property, set the body to the request variable (bare, no wrapper), `.to(endpoint)`, move the response into the named property, restore the wrapped body (template `_ActionId-4`); or `.enrich()` with an aggregation strategy doing the same | The callout does not replace `$body`; it fills `response/body` variable. The naïve `.to()` overwrites the body. Always restore |
| `publish` (service, outbound transform) | One-way send; errors do not stop the pipeline unless quality-of-service is exactly-once | `.wireTap("<backend-endpoint>")` with a copy, applying the outbound transform in the tap route; `ExchangePattern.InOnly` | `publish` inside a request pipeline is asynchronous "best effort" in OSB unless `qualityOfService=exactly-once`. Check the business service: a JMS publish with `response-required=false` is InOnly; an HTTP publish still waits for the HTTP response but ignores it. Transactions: OSB publish to JMS joins the inbound transaction when the proxy is transactional (JMS in → JMS out). Record whether the proxy is transactional before choosing a `transacted()` route |
| `publishTable` / `dynamicPublish` | As `routeTable` / `dynamicRoute`, one-way | `choice` + `wireTap` / `toD` InOnly | As above |

## Flow control actions

| OSB action | What it does | Camel (Java DSL) | Trap |
|---|---|---|---|
| `ifThenElse` (case condition, actions; default) | Conditional execution inside a stage | `.choice().when(OsbXQuery.of(<condition>).ns(NS).asPredicate()).…endChoice().otherwise()…end()` | OSB conditions are XQuery booleans over variables; copy them verbatim into the helper with the pipeline's `userNsDecl` list. A missing namespace declaration makes the condition silently false |
| `forEach` (variable, value, index/count vars, body) | Iterates over a node sequence, actions per item, mutating the context | `.split(xpath(...)).aggregationStrategy(...)...end()` when the result is rebuilt; a `Processor` when the loop mutates several variables | OSB `forEach` mutates variables in place and can change the iterated document. Camel `split` works on copies. If the loop writes back into `$body`, rebuild the document in an XQuery instead of a loop |
| `reply` (isErrorReply) | Ends processing and returns the current `$body`; with `isErrorReply` returns a fault | `.stop()` after setting the body; for the error case set a SOAP fault (CXF: throw `SoapFault` or set the `CamelCxfMessage` fault body) | A `reply` inside the **request** pipeline short-circuits the route node: the backend is never called. In Camel the `.stop()` must come before the `.to()`. Easy to miss when a reply sits inside an `ifThenElse` |
| `reply` with `isError=false` **inside an error handler** | Ends the flow as a success: the fault is swallowed; for a JMS proxy the message is acknowledged and never redelivered | `onException(...).handled(true)` with the handler's actions, no rethrow; for a transacted JMS route the error-queue send and the acknowledgement commit together | Common OSB pattern "log, route to an error queue, reply success". Do not turn it into a redelivery or a DLQ policy unless the card approves the change; the error-queue headers built in the handler are part of the contract |
| `skip` | Skips the rest of the current pipeline (request or response) | `.stop()` scoped to the sub-route of that pipeline (use `direct:` sub-routes per pipeline, so `stop()` ends only that part) | Not the same as `reply`: `skip` in the request pipeline still routes |
| `Error` / raise error (errCode, message) | Raises a fault handled by the nearest error handler | `.throwException(new OsbFaultException("<errCode>", "<message>"))` with a small exception type carrying code and reason | The error code is contractual: downstream handlers and callers test it. Keep the exact string |
| `resume` | In an error handler: continue the pipeline as if no error | `onException(...).handled(true).continued(true)` | Resume returns to the step after the failing one, not to the start. Camel's `continued(true)` does the same |
| Error handler on **stage** | Catches errors from that stage's actions | `doTry()...doCatch(Exception.class)` around the stage's steps, or a `direct:` sub-route per stage with its own `onException` | Scope order: stage → route node → pipeline → service. The nearest handler wins; an unhandled error propagates outward. Put each handler at the equivalent Camel scope, never all at the route level |
| Error handler on **route node** | Catches errors from the backend call | `onException` on the backend's endpoint segment, or `doTry` around the `.to()` | This is where retries live too: OSB retries at the business service, then the route-node handler sees the final failure |
| Error handler on **pipeline** (request or response) | Catches anything in that pipeline | `onException` in the `direct:` sub-route for that pipeline | |
| Error handler on **service** (`router errorHandler`) | Catches everything else, usually maps `$fault` to a SOAP fault and replies | Route-level `onException(Exception.class)` that runs the error pipeline's actions and replies | `$fault` carries `errorCode`, `reason`, `details`, `location` (node, pipeline, stage, error-handler, path) and `java-exception`. 12c codes are `OSB-38xxxx` (380000–380999 transport, 382000–382499 pipeline runtime, 382500–382999 pipeline actions, 386000–386999 WS-Security); 11g exports still say `BEA-`. The templates' `OsbFaultProcessor` sets headers with the same fields so the original fault XSLT can run on them |

## Reporting actions

| OSB action | Camel (Java DSL) | Trap |
|---|---|---|
| `log` (logLevel, expr) | `.log(LoggingLevel.<LEVEL>, "<logger>", "${...}")`; an OSB XQuery log expression is evaluated into a property with `OsbXQuery...asString()` first, then logged | OSB log levels: debug/info/warning/error. Personal data in log expressions is common in OSB flows and forbidden on the target (ECS JSON to Splunk): review every log expression on the card |
| `alert` (destination, severity, expr) | `.log(WARN, "ALERT <destination> <severity>: ...")` plus a Micrometer counter `osb.alert{destination,severity}`; no SNMP/email destination is reproduced | Alert destinations (email, SNMP, JMS) are platform concerns the programme does not carry over; the record lists each destination for the monitoring owner |
| `report` (key/value) | `.log(INFO, ...)` with the key as a structured field | OSB reporting wrote to a database for the console's search; the equivalent is a searchable log field, not a table |

## Node-level constructs (outside stages)

| OSB construct | Camel | Trap |
|---|---|---|
| Operational branch (`branch-node type="operation"`) | One route per operation; the inbound route dispatches on the operation (`CamelCxf` operation name header for CXF, `SOAPAction` otherwise) with `choice` | A branch with no pipeline pair and no route node is a valid "do nothing" operation: generate a route that returns an empty response, and a test that proves it |
| Conditional branch (`branch-node type="condition"`, variable + cases) | `choice` on the variable | Cases are compared as strings; `xs:string` the value |
| Pipeline pair (request + response) | The steps before and after the backend `.to()`; or two `direct:` sub-routes | |
| Split-join (`.flow`) | `split` + `aggregate` or `multicast().parallelProcessing()` | Split-joins are separate artefacts with their own semantics (parallel invokes, scoped variables). Treat every split-join as `complex` and design it on its own card |

## Settings that are not actions but change behaviour

| OSB setting | Where | Camel |
|---|---|---|
| `retry-count`, `retry-interval`, `retry-application-errors` | Business service | `onException(ConnectException/SocketTimeoutException).maximumRedeliveries(n).redeliveryDelay(ms)` scoped to that endpoint; `retry-application-errors=false` → do not retry on HTTP 5xx/SOAP faults, only on transport failures |
| `timeout` (`http:timeout`, seconds) | Business service | `?connectTimeout=…&receiveTimeout=…` on the CXF/HTTP endpoint (milliseconds) |
| `load-balancing-algorithm`, multiple URIs | Business service | On OpenShift one Service name replaces the URI list; record the original list, do not implement client-side balancing |
| `service-account` | Business service / proxy | Credentials from Vault-delivered properties; basic auth on the endpoint, never in the URI |
| `throttling` | Proxy/business service | `throttle()` with the same maximum concurrency, or leave it to the gateway and say so |
| `result-caching` | Business service | A cache (`caffeine-cache`) with the same key expression and TTL, or drop with a reason; it is usually a performance workaround |
| `transactional`, `same-transaction-for-response` | Proxy (JMS) | `transacted()` with a JMS transaction manager; the test must prove rollback on failure |
| WS-Security policy references | Proxy/business service | Not translated here. Record and block (see SKILL.md, "What this skill does not do") |
| Monitoring / SLA alert rules | Proxy | Metrics on the route (Micrometer) and an alert rule in the platform's Prometheus; record the thresholds |
KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_OSB_ACTION_MAPPING_MD
mkdir -p "$(dirname ".pi/skills/osb-to-camel/references/osb-expression-mapping.md")"
cat > '.pi/skills/osb-to-camel/references/osb-expression-mapping.md' <<'KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_OSB_EXPRESSION_MAPPING_MD'
# XQuery, XPath, XSLT and the message context: what to keep, what to change

The guiding rule: **keep the transforms, change the glue.** OSB transforms are XQuery 1.0 and XSLT 1.0. Saxon (via
`camel-saxon` for XQuery and `camel-xslt-saxon` for XSLT) executes XQuery 3.1 and XSLT 3.0, both backward compatible
with the 1.0 scripts except for the points below. Every transform is copied verbatim, edited only where this file
says, and proven by a golden test that runs the original and the migrated version side by side.

## 1. The `$body` root rule

In OSB, for a SOAP proxy, `$body` is the `soap:Body` element: `$body/ns:getContributorRequest` addresses the operation
element **inside** the Body. For an XML/any-XML proxy, `$body` is the payload wrapped in an OSB `Body` element.

| Target inbound component | What the Camel body is | Edit to the XQuery/XPath |
|---|---|---|
| `cxf` in `PAYLOAD` data format (default in the templates) | The content of the SOAP Body as a list of elements; for XQuery the templates bind the first element as `$body` **wrapped in a synthetic `<Body>`** so that `$body/ns:x` still works | None. This is why the templates wrap: zero edits to hundreds of queries beats editing every path |
| `cxf` in `MESSAGE`/`RAW` mode | The whole SOAP envelope | Paths need `/soap:Envelope/soap:Body/` prefixes. Avoid this mode for migrated flows |
| `platform-http` / `rest` (XML payload) | The payload root element | Wrap in `<Body>` the same way (the template's `OsbContext` processor does it) or change `$body/ns:x` to `/ns:x`. Prefer wrapping, for the same reason |
| `amqp`/`jms` text message | The text payload, parsed | Same as `platform-http` |

The wrapper is applied by `OsbBodyWrapper` in the templates, and it follows OSB's boundaries exactly: `wrap()` once at
the inbound (it also captures the transport headers as `osb.inbound.*` properties), **`unwrap()` before every outbound
call** (route node, service callout, publish), so a backend never sees the wrapper, `rewrap()` after a request-response
call so the response pipeline sees the backend response as `$body`, and `unwrap()` at the reply. A callout's request is
a pipeline variable, sent bare; its response is stored as a variable, not as `$body`. Forgetting the unwrap before a
backend call is the single most likely defect in a hand-written route; the template puts the two processors around
every `.to()`.

## 2. Context variables → Camel

| OSB | Meaning | Camel | Note |
|---|---|---|---|
| `$body` | SOAP Body content / payload | Message body (wrapped, see §1) | |
| `$header` | SOAP Header element | `CamelCxfMessage` headers in CXF; otherwise a property `osb.header` holding the parsed header element | WS-Addressing and security headers live here; if a pipeline reads them, note it on the card |
| `$inbound/ctx:transport/ctx:request/tp:headers/http:<Name>` | Inbound HTTP header | Camel header `<Name>` | Camel keeps the original case; OSB XQuery used the element name |
| `$inbound/ctx:transport/ctx:request/tp:user-metadata` | Transport metadata | Headers with the component's names (`CamelHttpUri`, `CamelHttpMethod`, …) | |
| `$inbound/ctx:service/ctx:operation`, `$operation` | WSDL operation | `operationName` header (CXF) or `SOAPAction` | |
| `$inbound/ctx:transport/ctx:uri`, `ctx:mode` | Inbound URI and request/response mode | `CamelHttpPath`, exchange pattern | |
| `$outbound/ctx:transport/ctx:request/tp:headers/...` | Outbound headers set by `transportHeaders` | `.setHeader(...)` before the `.to()` | Remember the `copy-all` trap in the action mapping |
| `$outbound/ctx:transport/ctx:response/...` | Backend response metadata | `CamelHttpResponseCode` and headers after the `.to()` | |
| `$fault/ctx:errorCode`, `ctx:reason`, `ctx:details`, `ctx:location` (`node`, `pipeline`, `stage`, `error-handler`, `path`), `ctx:java-exception` | Error context, populated only in error handlers | Headers `osb.fault.*` set by the templates' `OsbFaultProcessor` from the caught exception; the original fault XSLT runs on a synthetic `<ctx:fault>` element built from them | Keeps the original error XSLTs runnable. Codes are `OSB-38xxxx` in 12c (`BEA-` in 11g): transport 380000–380999, pipeline runtime 382000–382499, pipeline actions 382500–382999, WS-Security 386000–386999; the processor maps exception types to the nearest range, user-raised codes pass through unchanged |
| `$attachments` | MIME attachments | CXF attachments / `AttachmentMessage` | Rare; mark complex |
| user variables (`assign varName`) | Pipeline-scoped | Exchange properties of the same name | Properties, not headers: they must not leak onto the wire |
| `$messageID` | Unique id | `${exchangeId}` | In the parity ignore list |

## 3. XQuery 1.0 → Saxon XQuery 3.1: what actually breaks

| Construct | Status | Action |
|---|---|---|
| Core XQuery 1.0 (FLWOR, constructors, `fn:*` 1.0 functions) | Runs unchanged | Nothing |
| `xquery version "1.0";` prolog | Accepted by Saxon | Leave as is (Saxon treats it as 3.1) |
| `(:: OracleAnnotationVersion ... ::)` and `(:: pragma ... ::)` comments | Comments | Leave |
| `declare namespace`, `declare variable $x external` | Supported | Bind externals from headers/properties, see §5 |
| `fn-bea:*` functions | **Do not exist in Saxon** | Rewrite per §4, or import the shim module |
| `fn:doc("...")` to OSB resources (`doc("ContributorIntegration/XSD/...")`) | Resolves against the OSB config, not a file system | Replace with a classpath URI and a `URIResolver`, or inline the lookup table as a module variable; the golden test will show if semantics changed |
| Collations, `fn:string-join` on mixed sequences, implicit timezone | Minor differences possible | Covered by the golden test; fix per finding |
| XQuery Update (`insert node`, `replace value of`) | Not in Saxon-HE | Rewrite as a constructor expression (rare in OSB, which did updates with Insert/Replace actions instead) |
| Oracle-specific type coercions (`xs:date` from `yyyy-MM-dd` strings) | Standard | Nothing; `fn-bea` date formatting is the issue, not the types |

## 4. `fn-bea:` replacement table

The shim module `assets/templates/xquery/fn-bea-shim.xqy` implements the common functions in XQuery 3.1 under the
same namespace URI (`http://www.bea.com/xquery/xquery-functions`), so that **the original query runs unchanged** in the
golden test and in production, with one added line: `import module namespace fn-bea = "http://www.bea.com/xquery/xquery-functions" at "fn-bea-shim.xqy";`.
Prefer the import over rewriting. Rewrite only when the shim cannot express the function (SQL, credentials).

| `fn-bea:` function | Shim / replacement | Note |
|---|---|---|
| `date-to-string-with-format(fmt, date)`, `dateTime-to-string-with-format(fmt, dateTime)`, `time-to-string-with-format` | Shim: Java-style pattern → `fn:format-date`/`format-dateTime` picture string translation for the common patterns (`yyyy`, `MM`, `dd`, `HH`, `mm`, `ss`, `SSS`, literal quotes) | Patterns outside the table raise an error in the shim rather than guessing; add the pattern to the shim when found |
| `date-from-string-with-format(fmt, str)`, `dateTime-from-string-with-format` | Shim: parse the common patterns into `xs:date`/`xs:dateTime` | Same policy |
| `trim(str)`, `trim-left`, `trim-right` | `normalize-space` is **not** equivalent (it collapses inner spaces); shim uses `replace()` with anchored patterns | |
| `uuid()` | Shim: `random-number-generator()` based or, better, bind a header `osb.uuid` generated by Camel and read it | In the parity ignore list either way |
| `inlinedXML(str)` | `fn:parse-xml(str)` (3.1) | |
| `serialize(node)` | `fn:serialize(node)` (3.1) | Output method differences possible; golden test |
| `lookupBasicCredentials(ref)` | **Not shimmed.** Credentials come from Vault properties; the route sets the header, the query reads an external variable | Record on the card |
| `execute-sql(datasource, rowElement, sql, params)` | **Not shimmed.** Replace the enrichment with a `sql:` endpoint step before the transform and pass the result as an external variable | Appears in enrichment flows; mark the flow `complex` |
| `generate-guid()` | As `uuid()` | |
| `format-number(...)` variants | `fn:format-number` (3.1) with picture translation | |
| `fn-bea:isUserInGroup`, `fn-bea:isUserInRole` | **Not shimmed.** Authorization moved to the gateway/mesh; record and block | |
| `fn-bea:format-base64Binary`, `fn-bea:decode-xml`, `fn-bea:encode-xml` | Shim or `fn:` equivalents | |

Any `fn-bea:` function not in this table: stop, add a row (shim or "not shimmed, because"), then continue. The
inventory lists every function used in the export, so the table is complete for the estate after the first pass.

## 5. Running OSB expressions: one helper, OSB semantics, zero edits

Camel's own `xquery` language binds the message as the context item and exposes headers as `$in.headers.<name>`
(Camel XQuery language documentation); it knows nothing about `$body`, `$memberResp` or `$inbound`. So an OSB
expression pasted into `.xquery("$body/ns:x")` fails with an undeclared variable. The templates therefore run **every
OSB expression, inline or stored, through `OsbXQuery`** (Saxon s9api, in `OsbSupport.java`):

- `OsbXQuery.of("<inline OSB expression>").ns(NS)` for `assign`, `replace` with inline XQuery, `ifThenElse` and
  `routeTable` conditions, `log`/`alert` expressions, `transportHeaders` values. It declares every `$name` the
  expression references as an external variable and binds it at evaluation time: `$body` to the wrapped document,
  `$inbound` to a `ctx:inbound/ctx:transport/ctx:request/tp:headers/http:<Name>` element built from the captured
  headers, `$fault` to the `<ctx:fault>` element the fault processor built, `$operation` to the operation name, and
  any other `$name` to the exchange property of that name (DOM nodes for elements, atomics for strings/numbers).
  Adapters: `.asString()` / `.asNode()` (Camel `Expression`), `.asPredicate()` (Camel `Predicate`),
  `.replaceBodyContentsOnly()` / `.replaceBody()` (Camel `Processor`, the two Replace modes).
- `OsbXQuery.resource("osb/<project>/Transform/<Name>.xqy").ns(NS).param(<osbParam>, <property>[, <path>])` for
  `xqueryTransform` resources: the stored query keeps its own `declare variable $x external;` lines and each parameter
  is bound by its OSB name from the exchange property; the optional path is the OSB `<con1:path>` (`$memberResp/mem:...`)
  evaluated inside the property.
- `NS` is the pipeline's `userNsDecl` list (the inventory reports it per pipeline) plus the OSB context namespaces.

Expressions you write yourself (new routing logic, test helpers) may use Camel's `xquery()`/`xpath()` freely; copied
OSB expressions never, so that the golden tests and the card's action-to-code map stay literal.

## 6. XPath in conditions and locations

Most OSB conditions are XPath-compatible one-liners; they still go through `OsbXQuery` (§5) for the variable binding.
Always carry the pipeline's namespace declarations into `ns(...)`; a missing declaration does not error, it makes the
condition false.

## 7. XSLT 1.0 → Saxon XSLT 3.0

Runs unchanged. Watch: `xsl:output method="xml" indent="yes"` adds whitespace Camel then sends to the backend (normalize
in the golden comparison, keep in production only if the original did); EXSLT extensions (`exslt:node-set`) are
supported by Saxon; Oracle `oraxsl:` extensions are not (rare in OSB, common in SOA Suite).

## 8. What never to do

- Do not re-implement a working XQuery in Java "for performance" during migration. Equivalence first; profile later.
- Do not hand-write the expected output of a golden test. The original transform produces it.
- Do not change element order, whitespace handling or namespace prefixes in constructors "to clean them up"; backends
  with schema validation or XPath-based routing see the difference.
KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_OSB_EXPRESSION_MAPPING_MD
mkdir -p "$(dirname ".pi/skills/osb-to-camel/references/osb-transport-mapping.md")"
cat > '.pi/skills/osb-to-camel/references/osb-transport-mapping.md' <<'KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_OSB_TRANSPORT_MAPPING_MD'
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
KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_OSB_TRANSPORT_MAPPING_MD
mkdir -p "$(dirname ".pi/skills/osb-to-camel/references/programme-rules.md")"
cat > '.pi/skills/osb-to-camel/references/programme-rules.md' <<'KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_PROGRAMME_RULES_MD'
# Programme rules for generated Camel code (template)

Fill this file once per client programme before Step 2. Each rule names the programme document it comes from; when a
rule and a generic mapping table disagree, this file wins. Mark undecided items OPEN: the skill never invents the value,
it puts an open item on the flow card. The rows below are the decisions every programme has to make; the example
column shows a typical choice, not a default.

## Runtime and packaging

| Decision | Example | Your programme | Source |
|---|---|---|---|
| Camel runtime | Camel on Spring Boot inside the owning domain's service; no Camel K, no operators | | |
| Module per OSB project | per domain, or a shared integration service for cross-domain flows | OPEN | |
| Base image | a vendor JRE image pinned by digest, non-root UID | | |
| Deployment | Helm or plain manifests through GitOps; environment chain Dev → E2E → UAT → PROD | | |
| Configuration | every endpoint, destination, timeout and retry is a per-environment property | | |

## Logging, metrics, diagnostics

| Decision | Example | Your programme | Source |
|---|---|---|---|
| Log target | stdout as JSON (for example ECS), never a file inside the container | | |
| Correlation id | the header the OSB pipeline used, carried in MDC | | |
| Personal data | no payloads above DEBUG; masking rules for national identifiers | | |
| Metrics | Micrometer + actuator endpoint; OSB alert actions become a WARN marker + counter | | |

## Secrets and identity

| Decision | Example | Your programme | Source |
|---|---|---|---|
| Secret delivery | a secret manager injecting files at runtime; nothing secret in Git or properties | | |
| Token issuer and m2m auth | one identity provider; JWT for user context, mTLS for service-to-service | | |
| WS-Security policies and service accounts | recorded, not translated; flow blocked until security decides | | |

## Messaging

| Decision | Example | Your programme | Source |
|---|---|---|---|
| Broker and protocol | ActiveMQ Artemis / AMQ Broker over AMQP 1.0 (Qpid JMS) with a failover URI | | |
| Destination management | created only through a Git register; auto-create off | | |
| Destination names | from the register | OPEN | |
| Dead-letter / expiry | every anycast address has both | | |
| Durable topic subscription | named subscription queue with a broker-side filter, consumed by FQQN | | |
| Delivery guarantees | duplicate-ID header on producers, idempotent consumers, local transactions | | |
| Multi-site | which site consumes a queue (never both at once) | | |

## Calls to and from the flow

| Decision | Example | Your programme | Source |
|---|---|---|---|
| Inbound cut-over | per-proxy route rule on the API gateway; callers unchanged | | |
| Outbound calls | service names through the mesh sidecar; host per environment | | |
| Coexistence bridges | JMS bridge while queues are still on the legacy broker | | |
| Dependencies (rules engine, content store, workflow engine) | endpoint switch per flow | OPEN | |
KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_PROGRAMME_RULES_MD
mkdir -p "$(dirname ".pi/skills/osb-to-camel/references/test-strategy.md")"
cat > '.pi/skills/osb-to-camel/references/test-strategy.md' <<'KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_TEST_STRATEGY_MD'
# Test strategy: a suite derived from the OSB source, with every external system mocked

The OSB export is the specification. Its WSDLs say what messages look like, its pipelines say which branches exist,
its business services say which backends are called with which timeouts, its transforms say what the output must be.
A test suite derived from those four sources covers the flow's behaviour without a single call to a real system. The
tests are generated per flow from the templates in `assets/templates/java/`; the fixtures are generated from the
schemas and the branch conditions; the expected transform outputs are generated by running the original transform.

"Mocked" here means: the Camel route under test talks to `mock:` endpoints, a WireMock server, or a throwaway broker
in a container. Nothing in `src/test` knows a hostname of the client's systems.

## The five tests per flow

### 1. Route test (`<Flow>RouteTest`): the pipeline's logic in isolation

- `@CamelSpringBootTest` with the route's `RouteBuilder` only (`@Import`), `@UseAdviceWith`, and `AdviceWith` that
  replaces every backend endpoint (`cxf:bean:*`, `amqp:*`, `http:*`) with `mock:<businessService>` and, when the
  inbound is CXF, replaces the `from` with `direct:in` so the test sends payloads directly.
- One `@Test` per row of the card's test matrix of type `route`: one per WSDL operation, one per side of every
  `ifThenElse`/`routeTable`/conditional branch, one per error-handler scope (force the error with a mock that throws),
  one for each `reply`/`skip` short-circuit, one for header propagation (`transportHeaders`), one for the publish
  (expect the mock for the publish endpoint to receive exactly one InOnly exchange with the transformed body).
- Assertions on the mocks: `expectedMessageCount`, body as XML compared with XMLUnit (`isSimilarTo`, ignore
  whitespace), the headers the pipeline set, the exchange pattern for publishes.
- Inputs: `src/test/resources/fixtures/<flow>/<NN>-<description>-input.xml`, generated from the XSD (one element per
  operation, realistic traceable values: `contributorId` → `test-contributorId`, dates fixed, never `now()`), and one
  variant per branch condition with the deciding value set on each side of the condition.

### 2. Transform golden test (`<Transform>GoldenTest`): the adapted XQuery/XSLT equals the original

- For every `.xqy`/`.xsl` the flow uses. Two runs per fixture: the **original** file (copied untouched to
  `src/test/resources/osb-original/`) executed by Saxon with the `fn-bea` shim module imported, and the **migrated**
  file from `src/main/resources/osb/`. External variables bound identically from the fixture's `params/` folder.
- Comparison: XMLUnit `isSimilarTo` with `ignoreWhitespace`, `ignoreComments`, and the node filter from the fixture's
  `ignore-fields.txt` (XPath per line: timestamps, UUIDs, `lookupTime`).
- Fixtures: at least the happy path and one per conditional branch inside the query (`if (...) then ... else`), one with
  optional elements absent, one with an empty sequence for every `for` clause.
- If the original cannot run under Saxon (an `fn-bea:` function the shim does not implement, XQuery Update), the test
  fails with that message; that is a card finding, not a reason to write the expected output by hand.

### 3. Backend contract test (`<Flow>BackendContractTest`): what leaves the route, and how failures behave

- WireMock (`org.wiremock:wiremock-standalone`) started per test class on a random port; the route's endpoint
  properties (`osb.business.<Name>.url`) overridden to the WireMock base URL.
- One stub per business service and operation: SOAP matched on `SOAPAction` header (or the body's operation element
  via `matchingXPath` with namespaces), REST on method and path. The stub response is built from the backend WSDL/XSD
  (`src/test/resources/fixtures/<flow>/backend/<Name>/<operation>-response.xml`), or from recorded traffic when it
  exists (then it is the same file the parity test uses).
- Tests: (a) request shape, `verify(postRequestedFor(...).withRequestBody(matchingXPath(...)))` for the fields the
  pipeline built; (b) timeout: a stub with `withFixedDelay(timeout + 1s)` must produce the fault the card documented
  within the configured retries (`verify(exactly(retryCount + 1), ...)`); (c) application error: a SOAP fault response
  must **not** be retried when `retry-application-errors=false`; (d) headers: `X-Correlation-Id` present when
  `copy-all` or an explicit header said so, absent otherwise.
- The WireMock recording mode (`startRecording(targetUrl)`) is how a tester captures real backend behaviour in a test
  environment once, producing stub files for everyone; never point it at production.

### 4. JMS publish test (`<Flow>JmsPublishTest`): fire-and-forget means fire-and-forget

- Testcontainers `ArtemisContainer` (`org.testcontainers:activemq`) when Docker is available; otherwise the test is
  `@EnabledIf(docker)` and the record says it did not run. An embedded broker is an acceptable fallback only if the
  team already uses one.
- Route configured with the container's AMQP URL. Test: send the inbound message; assert the proxy response is not
  delayed by the publish (`InOnly`), consume one message from the destination and compare body and the headers the
  outbound transform set; for transactional proxies, force a failure after the publish and assert the message is not
  on the destination (rollback).

### 5. Parity replay test (`<Flow>ParityReplayTest`): the real traffic, replayed

- The strongest evidence, and the one that needs the client's help. OSB has no built-in bulk export of request/response
  pairs: the sources are the OSB Report action with a reporting provider that persists the message data, the Test
  Console for single cases, or the Apigee/gateway logs in a test environment, all with personal data masked. Agree the
  capture mechanism with the client before the first slice; it is a prerequisite, not a nice-to-have. Layout:
  `src/test/resources/parity/<flow>/<NN>/request.xml`, `response.xml`, `backend/<Name>/request.xml`, `response.xml`,
  and `ignore-fields.txt`.
- The test loads every `<NN>` folder, programmes WireMock with the backend pairs, sends `request.xml` through the
  route, and compares the response with XMLUnit under the ignore list. Additionally verifies that the backend request
  the route produced is similar to the recorded backend request (the same comparison, same ignore list).
- Without fixtures the test is skipped with an explicit reason, and the migration record carries "parity: no fixtures".
  A flow can be cut over without parity only by a written decision on the record.

## Interface mocks beyond JMS and HTTP (add only what the card lists)

Every interface of the flow is mocked; JMS and HTTP/SOAP are covered by the five tests above. The inventory lists
the rest per flow (transports, `javaCallout`, `fn-bea:execute-sql`, DVM/XRef references); for each one present,
add the matching test from `assets/templates/java/`:

| Interface | Template | Mock | Data from | Needs Docker |
|---|---|---|---|---|
| Database: JCA DB adapter, `fn-bea:execute-sql`, XRef tables | `DatabaseMockTestTemplate` (`<Flow>DatabaseIT`) + `mocks/db-seed.sql` | Oracle Free container, same SQL as the `.jca`/XQuery; H2 `MODE=Oracle` only for plain lookups | Seed rows from the recorded cases or the client's test data, masked | Yes (H2 variant: no) |
| DVM lookups | `DvmLookup` (main) + `LookupMockTestTemplate` + `mocks/sample.dvm` (shape only) | The exported `.dvm` file is the mock; Saxon extension so the original XQuery runs | Export (DG1) | No |
| Java callout | `JavaCalloutMockTestTemplate` | A: real class/JAR; B: stub by step id (route-only proof, flow stays blocked) | JAR/source (DG1); logged results | No |
| File / FTP / SFTP | `FileSftpMockTestTemplate` (`<Flow>FileTransportIT`) | `@TempDir` for file; `atmoz/sftp` container for SFTP | Sample files from the client; logged payloads | SFTP only |
| Email transport | `EmailMockTestTemplate` | GreenMail SMTP + IMAP in the test JVM | Recorded case (recipient, subject, body) | No |
| Security done by the module | `SecurityMockTestTemplate` + `mocks/make_test_certs.sh` | WireMock token endpoint + JWKS, test-signed JWTs, test keystores for mTLS | Generated in the test | No |
| Vault secrets | `application-test.yml` | Plain test properties replace what the Agent Injector would write | — | No |

Rules: every mock reads its address from a property the route already uses in production (`@DynamicPropertySource`);
no real host, certificate or personal value in `src/test`; a stub value is never an oracle (gate G7 rejects it).

## Fixture generation rules (so fixtures look the same across 450 flows)

- Names: `<NN>-<kebab-description>-input.xml` / `-expected.xml`; `NN` two digits; `01` is always the happy path.
- Values: strings `test-<fieldName>`, integers 42/100/7, decimals `19.99`, dates `2026-01-15`, dateTimes
  `2026-01-15T10:30:00Z`, enumerations the first valid value from the XSD, booleans `true` on the happy path.
- Branch fixtures take the condition literally: for `status = 'ACTIVE'` generate `ACTIVE` and `INACTIVE`; for a
  threshold generate values clearly on each side.
- Optional elements: absent in the "nullable" fixture, never empty.
- `ignore-fields.txt` auto-filled from anything the transform or pipeline derives from time, random, or exchange ids.

## What the suite does not prove, and what does

| Not proven by the suite | Proven by |
|---|---|
| Behaviour of the real backend under the migrated request | UAT integration run against the real backends, per flow group |
| Performance of XQuery under Saxon versus OSB | The W1 baseline and the UAT performance test (k6), not unit tests |
| Message ordering and transactions on the real broker | The messaging workstream's drills |
| WS-Security, JWT and mTLS at the edge | The API security design and the gateway/mesh tests |
| That the cutover (Apigee route rule) is correct | The canary and rollback rehearsal in the record's cutover note |

## Mapping to camel-kit's test approach

camel-kit generates Citrus YAML integration tests with Testcontainers. This skill generates JUnit 5 + Camel test
support + WireMock, because the programme's services are Java/Spring Boot teams with JUnit already in the pipeline,
and because `AdviceWith` is the only clean way to isolate a pipeline's branches. Both can coexist: Citrus tests for
end-to-end flows in a camel-kit pipeline, this suite for per-flow behaviour. See `camel-kit-integration.md`.
KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_TEST_STRATEGY_MD
mkdir -p "$(dirname ".pi/skills/osb-to-camel/references/triage-rules.md")"
cat > '.pi/skills/osb-to-camel/references/triage-rules.md' <<'KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_TRIAGE_RULES_MD'
# Triage: how the inventory scores a flow, and how to recalibrate

The estimate for this programme priced OSB flows in three tiers with fixed unit efforts (simple, medium, complex;
the figures are internal and are not repeated here or on any customer artefact). The inventory script assigns a tier
so that the estimate can be reconciled against evidence instead of a top-down split, and so that batch migration can
start with the flows that teach the most for the least risk.

## The score (`scripts/osb_inventory.py::triage`)

| Signal | Points | Why it costs effort |
|---|---|---|
| Each pipeline action | +1 | Each is a card row, a code step and usually a test row |
| Each downstream service (route, callout, publish target) | +3 | A backend means a stub set, a configuration block, a timeout/retry decision |
| Each hard action present (`javaCallout`, `mflTransform`, `nXSDTransform`, `dynamicRoute`, `dynamicPublish`, `forEach`) | +8 | No mechanical mapping; design per occurrence |
| Java callouts | +10 | The jar must be found, read, ported or stubbed |
| XQuery/XSLT lines | +1 per 20 lines | Golden fixtures and review grow with the transform |
| Each distinct `fn-bea:` function | +4 | Shim entry or rewrite, plus the proof |
| Each transport outside `http`, `ws`, `sb`, `local`, `jms` | +6 | File/FTP/email/JCA/MQ need infrastructure decisions |
| WS-Security policies attached | +6 | Blocked on the security owner |
| Throttling configured | +3 | A decision: route-level or gateway |
| Result caching | +4 | A decision: cache component or drop |
| Each branch node beyond the first | +2 | More paths, more tests |
| Unknown actions | +5 | Something the mapping table has not met |

Thresholds: `simple` < 12, `medium` < 28, `complex` ≥ 28.

## Signals that force `complex` regardless of score

Treat the flow as complex, and design it on its own card, when any of these is true: a split-join (`.flow`) is involved;
a Java callout has no source; `mflTransform`/`nXSDTransform` is used; `fn-bea:execute-sql`, `lookupBasicCredentials`,
`isUserInGroup/Role` appear; a JCA adapter is the inbound or outbound transport; the proxy is a transactional JMS
consumer that publishes in the same transaction; WS-Security policies are attached; the pipeline reads `$header`
(SOAP headers) or `$attachments`. The script does not enforce this list yet; the card does. Add the rule to the script
once the first slice shows which ones occur.

## Recalibration after the first slice

The thresholds above are a guess shaped like the estimate. They become a measurement like this:

1. Migrate the first slice (the programme's own proposal was about twenty flows across the three tiers) with the skill,
   recording actual effort per flow in the migration record (design, code, tests, review, separately).
2. Plot score against actual effort. Set the two thresholds so that the tier bands match the estimate's unit-effort
   bands; if the relationship is not monotonic, find the signal that explains the outliers and change its weight.
3. Re-run the inventory over the whole export with the new weights; the tier counts are what the estimate
   reconciliation uses. Keep the old `INVENTORY.md` next to the new one; the delta is the evidence.
4. Repeat after each wave. The script's docstring says the thresholds are uncalibrated; remove that sentence only when
   they are.

## How the tiers drive batch order

- `simple` first, grouped by shared business services: the stubs and configuration blocks are built once and the team
  learns the mapping tables on low-risk flows.
- `medium` next, by project folder, because folders tend to share transforms and namespaces.
- `complex` one card at a time, each approved individually; schedule the Java-callout and JCA flows last, after their
  owners have answered the open items.

## Never

Never quote the tier counts as an effort figure outside the estimate workbook, and never let the script's tier override
a reviewer's judgement on the card without a written reason; the score is an input, the card is the decision.
KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_TRIAGE_RULES_MD
mkdir -p "$(dirname ".pi/skills/osb-to-camel/references/versions.md")"
cat > '.pi/skills/osb-to-camel/references/versions.md' <<'KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_VERSIONS_MD'
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
KIT_EOF__PI_SKILLS_OSB_TO_CAMEL_REFERENCES_VERSIONS_MD
chmod +x .pi/skills/osb-to-camel/scripts/*.py 2>/dev/null || true
echo "installed: 12 files (skill osb-to-camel: SKILL.md, scripts, references)"
