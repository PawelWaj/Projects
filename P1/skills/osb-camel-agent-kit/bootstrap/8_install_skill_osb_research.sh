#!/usr/bin/env bash
# Paste into the migration workspace root on the VDI and run: bash 8_install_skill_osb_research.sh
# Skill osb-research (shareable research pack) under .pi/skills/ + researcher role + pi runner.
set -euo pipefail
mkdir -p "$(dirname ".pi/skills/osb-research/SKILL.md")"
cat > '.pi/skills/osb-research/SKILL.md' <<'KIT_EOF__PI_SKILLS_OSB_RESEARCH_SKILL_MD'
---
name: osb-research
description: "Research one Oracle Service Bus proxy from its source on the client machine and produce a SHAREABLE research pack (no source code, no hosts, no credentials, no personal data) that someone without access to the source can turn into a Camel K route and tests. Use when asked to research, analyse, describe or explain an OSB proxy, pipeline, business service or XQuery for migration and the result must leave the client network, or when the user says osb-research."
---

# OSB research pack: the source stays, the knowledge travels

The OSB source cannot leave the client network. The people who design the Camel K route and the tests work outside it.
This skill turns one proxy into a research pack that carries everything they need and nothing they must not have:
facts extracted by a script, plus answers to a fixed questionnaire written in plain language and mapping tables.
A check script blocks the pack if it still contains code, hosts, credentials or personal data.

## Rules (apply to every line you write into the pack)

1. **No source code.** Never paste XQuery, XSLT, XSD, WSDL or OSB XML. Describe it: what it does, which fields it reads
   and writes (as paths), which functions it calls. A short XPath *condition* (one line, at most 200 characters) may be
   quoted when a branch depends on it.
2. **No infrastructure.** No host names, IP addresses, ports, credentials, service accounts or key material.
   Destinations by name only (queue/topic JNDI name, HTTP path, SOAP operation).
3. **No data.** No values from payloads, logs or test files. Field names, codes and enum values defined in the code
   (for example `businessTransaction = 'TYPE_A'`) are allowed; personal values never.
4. **Evidence for every answer.** Each answer names the file (path relative to the export) and the stage/action it
   comes from. If something cannot be determined from the source, write `UNKNOWN` and add it to open questions.
   Never guess.
5. Namespaces are referred to by prefix; their URIs are already in `facts.json`.

## Steps

1. **Facts (script, no judgement):**
   `python <skill>/scripts/research_pack.py <osb-export> <proxy> -o research/<proxy> [--scenarios task1/traces/scenarios.json]`
   Writes `facts.json` (sanitised inventory of the proxy) and `SOURCES.txt` (the files to read). Read `facts.json` first.
2. **Read the sources** listed in `SOURCES.txt`, plus every resource they reference (shared XQuery, DVM, schemas,
   Java callouts). Anything referenced but missing goes to open questions.
3. **Answer the questionnaire** in `references/questions.md`: write `research/<proxy>/RESEARCH.md` using
   `assets/RESEARCH_TEMPLATE.md` (same headings, same tables), and `research/<proxy>/research.json` following
   `assets/research.schema.json`. The two must agree.
4. **Check before sharing:**
   `python <skill>/scripts/research_check.py research/<proxy>`
   It must print `PASS`. On `FAIL`, rewrite the flagged lines (describe instead of quoting, drop the value) and rerun.
   Never delete a finding by weakening the check.
5. **Report**: five lines: proxy, tier, number of branches/backends/transforms, number of open questions, check result.
   The human shares only `RESEARCH.md`, `research.json`, `facts.json`, `SHARE_CHECK.json`.

## What the pack is used for (so you know what matters)

- **Selector, subscription, outputs** → the Camel K route's endpoints and the broker filter.
- **Branches with their conditions and the scenario values that trigger them** → one test group per branch; the
  scenarios from the Splunk logs (`log_scenarios` in `facts.json`) must each map to a branch.
- **Transform mappings (source path → target path → rule)** → the route's transformation and the reviewer's checklist;
  the expected outputs themselves are still computed on the client machine by running the original XQuery.
- **Backends with request/response use, retries, timeouts** → WireMock stubs and Artemis mocks.
- **Error handling per scope** → the error tests (what is caught, where it goes, which headers).
- **Log actions** → the same log lines in Camel so the existing Splunk searches keep working.
KIT_EOF__PI_SKILLS_OSB_RESEARCH_SKILL_MD
mkdir -p "$(dirname ".pi/skills/osb-research/scripts/research_check.py")"
cat > '.pi/skills/osb-research/scripts/research_check.py' <<'KIT_EOF__PI_SKILLS_OSB_RESEARCH_SCRIPTS_RESEARCH_CHECK_PY'
#!/usr/bin/env python3
"""Gate before a research pack leaves the VDI: nothing sensitive and no verbatim source code.

    research_check.py research/<proxy> [--allow-host example.com]...

Scans every .md/.json/.txt/.csv in the folder. Fails (exit 1) on:
  host    URLs with a host that is not an XML namespace of the flow or an allowed public host; name.domain:port; IPv4
  secret  password/secret/token/api key assignments, private keys
  pii     numbers with 9+ digits, e-mail addresses, Arabic script
  code    verbatim OSB source: XQuery/XSLT/XSD/WSDL/OSB XML markers, or a fenced code block longer than 12 lines
  dims    research.json scenario_dims entry that is not a bare key (header.<name>, //<name>, a.b): later steps read it
Prints findings as file:line + rule + a 3-character preview (never the full value) and writes SHARE_CHECK.json
(pass/fail, counts per rule, sha256 per file) into the folder. Share the folder only when it passes. Stdlib only."""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

PUBLIC = {"www.w3.org", "w3.org", "xmlns.oracle.com", "www.bea.com", "schemas.xmlsoap.org", "camel.apache.org",
          "docs.oracle.com", "example.com", "www.example.com", "json-schema.org"}
RULES = [
    ("host", re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")),
    ("host", re.compile(r"\b[A-Za-z][\w-]*(?:\.[\w-]+)+:\d{2,5}\b")),
    ("secret", re.compile(r"(?i)\b(?:password|passwd|pwd|secret|token|api[_-]?key|client[_-]?secret)\b\s*[\"']?\s*[:=]\s*[\"']?[^\s\"',}]{3,}")),
    ("secret", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("pii", re.compile(r"(?<![\w.-])\d{9,}(?![\w-])")),
    ("pii", re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")),
    ("pii", re.compile(r"[\u0600-\u06FF]")),
    ("code", re.compile(r"(?i)xquery\s+version|declare\s+(?:function|variable|namespace)\s|<xsl:|<xsd?:(?:schema|element|complexType)"
                        r"|<(?:con|ser|tran|jms|http|wsdl|soapenv|env):[A-Za-z]")),
]
DIM = re.compile(r"^(?:header\.[\w-]+|hdr_[\w-]+|body:[\w./-]+|(?://)?[\w-]+(?:[./][\w-]+)*)$")
URL = re.compile(r"\b[a-zA-Z][a-zA-Z0-9+.-]*://([^/\s\"'<>)|]+)")


def namespace_hosts(folder: Path) -> set[str]:
    hosts = set()
    for f in folder.glob("*.json"):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except ValueError:
            continue
        stack = [data]
        while stack:
            o = stack.pop()
            if isinstance(o, dict):
                for k, v in o.items():
                    if k == "namespaces" and isinstance(v, list):
                        hosts |= {m.group(1).lower() for n in v if isinstance(n, dict) and (m := URL.match(str(n.get("uri", ""))))}
                    else:
                        stack.append(v)
            elif isinstance(o, list):
                stack.extend(o)
    return hosts


def dims_findings(f: Path) -> list[tuple[str, str, int, str]]:
    """scenario_dims must be keys task1, the scaffold and the case generator can read: words in brackets made a
    header field look like a payload field and the synthetic case tested the wrong branch."""
    if not f.is_file():
        return []
    try:
        dims = json.loads(f.read_text(encoding="utf-8")).get("scenario_dims") or []
    except (ValueError, AttributeError):
        return []
    lines = f.read_text(encoding="utf-8").splitlines()
    return [(f.name, "dims", next((n for n, ln in enumerate(lines, 1) if json.dumps(d) in ln), 0),
             "not a bare key, write header.<name> or //<name> (explanations go in RESEARCH.md)")
            for d in dims if not isinstance(d, str) or not DIM.match(d.strip())]


def scan(f: Path, allowed: set[str]) -> list[tuple[str, int, str]]:
    found, fence, fence_start = [], False, 0
    for n, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if line.strip().startswith("```"):
            if fence and n - fence_start - 1 > 12:
                found.append(("code", fence_start, "fenced block of %d lines" % (n - fence_start - 1)))
            fence, fence_start = (not fence), n
        for m in URL.finditer(line):
            host = m.group(1).split("@")[-1].split(":")[0].lower()
            if host and host not in allowed and not any(host.endswith("." + p) for p in PUBLIC):
                found.append(("host", n, m.group(0)[:3] + "***"))
        for rule, rx in RULES:
            for m in rx.finditer(line):
                found.append((rule, n, m.group(0)[:3] + "***"))
    return found


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", type=Path)
    ap.add_argument("--allow-host", action="append", default=[])
    a = ap.parse_args()
    allowed = PUBLIC | {h.lower() for h in a.allow_host} | namespace_hosts(a.folder)
    files = sorted(p for p in a.folder.rglob("*") if p.is_file() and p.suffix.lower() in (".md", ".json", ".txt", ".csv")
                   and p.name != "SHARE_CHECK.json")
    findings = []
    for f in files:
        findings += [(f.relative_to(a.folder).as_posix(), *x) for x in scan(f, allowed)]
    findings += dims_findings(a.folder / "research.json")
    counts = {}
    for _, rule, _, _ in findings:
        counts[rule] = counts.get(rule, 0) + 1
    result = {"pass": not findings, "files": {f.relative_to(a.folder).as_posix(): hashlib.sha256(f.read_bytes()).hexdigest()
                                              for f in files},
              "findings_per_rule": counts, "namespace_hosts_allowed": sorted(namespace_hosts(a.folder))}
    (a.folder / "SHARE_CHECK.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    for path, rule, line, preview in findings[:200]:
        print(f"{path}:{line}: {rule}: {preview}")
    print(f"{'PASS' if not findings else 'FAIL'}: {len(files)} files, {len(findings)} findings {counts or ''}")
    return 0 if not findings else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_RESEARCH_SCRIPTS_RESEARCH_CHECK_PY
mkdir -p "$(dirname ".pi/skills/osb-research/scripts/research_pack.py")"
cat > '.pi/skills/osb-research/scripts/research_pack.py' <<'KIT_EOF__PI_SKILLS_OSB_RESEARCH_SCRIPTS_RESEARCH_PACK_PY'
#!/usr/bin/env python3
"""Deterministic half of the OSB research: facts about ONE proxy, safe to share outside the client network.

    research_pack.py <osb-project-dir> <proxy> -o research/<proxy> [--scenarios task1/traces/scenarios.json]

Runs the osb-to-camel inventory on the export and keeps only facts that describe behaviour: transports, selector,
subscription, retries, timeouts, stage/action structure, error-handler scopes, business services, transforms by name
with their fn-bea functions, missing references, triage. It never copies code, hosts, ports, credentials or
payloads: URIs keep scheme + destination name (jms://<host>/jndi.X -> jms:jndi.X; http://h:p/a/b -> http:/a/b),
inline XQuery is reduced to the functions it calls. Writes:
  facts.json         the sanitised facts (input for RESEARCH.md and for the Camel side)
  SOURCES.txt        the files of this proxy the agent must read (paths relative to the export), for the questionnaire
Stdlib only."""
import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
INVENTORY = next((p for p in (HERE.parents[1] / "osb-to-camel/scripts/osb_inventory.py",
                              HERE.parents[2] / ".pi/skills/osb-to-camel/scripts/osb_inventory.py") if p.is_file()), None)
FUNC = re.compile(r"\b([A-Za-z][\w-]*:[A-Za-z][\w.-]*)\s*\(")


def safe_uri(uri: str) -> str:
    """Scheme + destination only: no host, port or credentials."""
    m = re.match(r"^(\w+)://[^/]*(/.*)?$", uri or "")
    if not m:
        return re.sub(r"//[^/]*", "//<host>", uri or "")
    scheme, path = m.group(1), (m.group(2) or "")
    if scheme in ("jms", "t3", "t3s"):
        dest = path.rstrip("/").split("/")[-1] if path else ""
        return f"{scheme}:{dest}"
    return f"{scheme}:{re.sub(r'[?;].*$', '', path)}"


def service(s: dict) -> dict:
    keep = ("ref", "kind", "transport", "binding", "soap12", "retry_count", "retry_interval", "timeout", "load_balancing",
            "throttling", "result_caching", "ws_policies")
    props = {k: v for k, v in (s.get("transport_props") or {}).items() if not re.search(r"pass|secret|cred|user|key", k, re.I)}
    return {**{k: s.get(k) for k in keep}, "destinations": [safe_uri(u) for u in s.get("uris") or []],
            "wsdl": Path(s["wsdl"]).name if s.get("wsdl") else None, "transport_props": props,
            "service_account": "set" if s.get("service_account") else None}


def pipeline(p: dict) -> dict:
    inline = p.get("inline_xquery") or []
    return {"ref": p.get("ref"), "stages": p.get("stages"), "branches": p.get("branches"),
            "error_handler_scopes": p.get("error_handler_scopes"), "action_counts": p.get("action_counts"),
            "unknown_actions": p.get("unknown_actions"), "routes_to": p.get("routes_to"), "callouts_to": p.get("callouts_to"),
            "publishes_to": p.get("publishes_to"), "java_callouts": p.get("java_callouts"), "operations": p.get("operations"),
            "context_vars": p.get("context_vars"), "alert_destinations": p.get("alert_destinations"),
            "transform_refs": {"xquery": p.get("xquery_refs"), "xslt": p.get("xslt_refs"), "xsd": p.get("xsd_refs")},
            "inline_expressions": {"count": len(inline),
                                   "functions": sorted({f for e in inline for f in FUNC.findall(e or "")})},
            "fn_bea_functions": p.get("fn_bea_inline")}


TRANSFORM_EXT = {".xqy", ".xq", ".xquery", ".xsl", ".xslt"}


def transform_files(project: Path, transforms: list[dict]) -> list[str]:
    """Paths (relative to the export) of the transforms this proxy uses: matched by the ref's last segment."""
    names = {(t.get("ref") or "").split("/")[-1].lower() for t in transforms}
    out = []
    for p in project.rglob("*"):
        if p.is_file() and (p.suffix.lower() in TRANSFORM_EXT or p.name.lower().endswith(".xquery")) \
                and p.stem.split(".")[0].lower() in names:
            out.append(p.relative_to(project).as_posix())
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("project", type=Path, help="OSB export directory (unzipped sbconfig.jar or JDeveloper project)")
    ap.add_argument("proxy", help="proxy service name, e.g. sample-adjustment")
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--scenarios", type=Path, help="task1/traces/scenarios.json: scenario values to map to branches")
    a = ap.parse_args()
    if not INVENTORY:
        sys.exit("osb-to-camel skill not found next to osb-research (scripts/osb_inventory.py)")
    with tempfile.TemporaryDirectory() as tmp:
        r = subprocess.run([sys.executable, str(INVENTORY), str(a.project), "-o", tmp], capture_output=True, text=True)
        if r.returncode:
            sys.exit("inventory failed: " + r.stderr[-400:])
        flows = sorted(Path(tmp, "flows").glob("*.json"))
        hits = [f for f in flows if f.stem.split("__")[-1] == a.proxy] or [f for f in flows if a.proxy in f.stem]
        if len(hits) != 1:
            names = [f.stem.split("__")[-1] for f in flows]
            sys.exit(f"proxy '{a.proxy}' found {len(hits)} times; proxies in the export: {', '.join(names) or 'none'}")
        flow = json.loads(hits[0].read_text(encoding="utf-8"))
    px, pl = flow["proxy"], flow.get("pipeline") or {}
    facts = {
        "proxy": a.proxy, "source": "osb_inventory.py (deterministic), sanitised by research_pack.py",
        "entry": service(px), "pipeline": pipeline(pl),
        "business_services": [service(b) for b in flow.get("business") or []],
        "transforms": [{"ref": t.get("ref"), "kind": t.get("kind"), "lines": t.get("lines"),
                        "xquery_version": t.get("xquery_version"), "fn_bea_functions": t.get("fn_bea"),
                        "external_params": t.get("external_params"), "uses_doc": t.get("uses_doc"),
                        "namespaces": [{"prefix": k, "uri": v} for k, v in (t.get("namespaces") or {}).items()]}
                       for t in flow.get("transforms") or []],
        "chained_proxies": flow.get("chained_proxies"), "missing_refs": flow.get("missing_refs"),
        "triage": flow.get("triage"),
    }
    if a.scenarios and a.scenarios.is_file():
        facts["log_scenarios"] = [{"scenario": s["scenario"].split("|", 2)[-1], "count": s["count"]}
                                  for s in json.loads(a.scenarios.read_text(encoding="utf-8"))]
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / "facts.json").write_text(json.dumps(facts, indent=2, ensure_ascii=False), encoding="utf-8")
    files = sorted(({px.get("path")} | {pl.get("path")} | {b.get("path") for b in flow.get("business") or []}
                    | set(transform_files(a.project, flow.get("transforms") or []))) - {None})
    (a.out / "SOURCES.txt").write_text("\n".join(files) + "\n", encoding="utf-8")
    print(json.dumps({"proxy": a.proxy, "tier": (flow.get("triage") or {}).get("tier"), "files": len(files),
                      "missing_refs": len(flow.get("missing_refs") or []), "out": str(a.out)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF__PI_SKILLS_OSB_RESEARCH_SCRIPTS_RESEARCH_PACK_PY
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
| Q5 | **Scenario mapping.** Branches decide on payload fields or headers: list those fields in `scenario_dims` exactly as the condition finds them: a condition with `//*:name` (any depth, the usual OSB form) becomes `//name`; only a condition that spells a full path (`$body/*:a/*:b`) becomes the path `a.b` (check it against the nXSD/XSD element nesting); a condition on a transport or user header (`$inbound/ctx:transport/ctx:request/tp:headers/tp:user-header[@name='x']`, JMS property, HTTP header) becomes `header.x`. Each entry is ONLY that key: no words, no brackets, no explanation (that goes in RESEARCH.md); research_check.py fails on anything else. Never invent a path the source does not show. Then give one `scenario_mapping` row per combination of their values with the outputs reached, as `k=v|k!=v` (k = last path segment; `k!=true` also covers a missing field; first matching row wins; outputs = business service names, `[]` = consumed, nothing sent). A flow without branches has one row with scenario `*` (every message). Never answer "depends on the message": that is what the row must spell out. Then say which `log_scenarios` in `facts.json` show those fields; if none do, write `rerun task 1 with SCENARIO_DIMS=...,body:<path>` in open questions | table |
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
mkdir -p "$(dirname "agents/researcher.md")"
cat > 'agents/researcher.md' <<'KIT_EOF_AGENTS_RESEARCHER_MD'
# Role: researcher (OSB research pack)

You research ONE OSB proxy from its source and write a research pack that will leave the client network.
Follow skill `osb-research` exactly. You never change the OSB export or any module: you only write into
`research/<proxy>/`. You never paste code, hosts, credentials or data into the pack; you describe and give evidence.
If the source does not answer a question, write UNKNOWN and add an open question; never guess.
Finish only when `research_check.py` prints PASS, then give the five-line report.
KIT_EOF_AGENTS_RESEARCHER_MD
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
        echo "   pi did not finish within ${PI_TIMEOUT:-1800}s , stopped it (a hanging call, or a slow model: check the model server log; raise PI_TIMEOUT for a slow local model)"; return 124
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
        rm -f "$err.timeout"; echo "   pi did not finish within ${PI_TIMEOUT:-1800}s , stopped it (a hanging call, or a slow model: check the model server log; raise PI_TIMEOUT for a slow local model)"; return 124
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
mkdir -p "$(dirname "pi/osb-kit.env.example")"
cat > 'pi/osb-kit.env.example' <<'KIT_EOF_PI_OSB_KIT_ENV_EXAMPLE'
# Copy to ~/.osb-kit.env on the client machine and fill in. NEVER commit the filled copy: client-specific values
# (application folder, Splunk names, Maven settings) live only on the machine. Every runner in pi/ reads it if present
# (another path: export OSB_KIT_ENV=/path/to/file). Values set on the command line win over this file (every line is a default: ${VAR:-...}).
export KIT="${KIT:-/e/Pawel/Projects-main/P1/skills/osb-camel-agent-kit}"   # the kit in the unzipped repo
export APP="${APP:-/e/<osb-application-folder>}"                              # OSB application with the *-prj projects
export WS="${WS:-/e/Pawel/work}"                                             # workspace: research/, task1/, modules/, domain/
export JAVA_HOME="${JAVA_HOME:-/c/Program Files/<jdk-21-folder>}"
export PATH="/e/Pawel/apache-maven-3.9.9/bin:$JAVA_HOME/bin:$PATH"
export MVN_ARGS="${MVN_ARGS:--s $HOME/.m2/settings.xml}"                          # the client's Nexus mirror
export PI_OFFLINE="${PI_OFFLINE:-1}" PI_TELEMETRY="${PI_TELEMETRY:-0}" PI_PAUSE="${PI_PAUSE:-60}"   # pi: no outside calls, stay under the rate limit
export SPLUNK_INDEX="${SPLUNK_INDEX:-<e2e_index>}"                                     # used in the Splunk searches of the guides
export SPLUNK_SOURCETYPE="${SPLUNK_SOURCETYPE:-<osb_sourcetype>}"
export ARTEMIS_HOME="${ARTEMIS_HOME:-/e/Pawel/apache-artemis-<version>}"              # local broker (broker/LOCAL_BROKER_TEST.md)
export ARTEMIS_BROKER="${ARTEMIS_BROKER:-/e/Pawel/artemis-broker}"                   # the broker instance (artemis_setup.sh create)
export ARTEMIS_ZIP="${ARTEMIS_ZIP:-/e/Pawel/apache-artemis-<version>-bin.zip}"       # the download, for artemis_setup.sh install
export ARTEMIS_USER="${ARTEMIS_USER:-artemis}"
# export MASK_KEY=... / ARTEMIS_PASSWORD=...   # NEVER here: type them per session (data owner / broker password)
KIT_EOF_PI_OSB_KIT_ENV_EXAMPLE
mkdir -p "$(dirname "pi/init_env.sh")"
cat > 'pi/init_env.sh' <<'KIT_EOF_PI_INIT_ENV_SH'
#!/usr/bin/env bash
# Writes ./.osb-kit.env for this workspace with what it can find on the machine, so nobody types paths again.
# Usage (in the workspace, e.g. /e/Pawel/work):  bash <kit>/pi/init_env.sh <osb-application-folder>
# The file is client-specific: it stays here, .gitignore keeps it out of Git. Edit it afterwards if a value is wrong.
set -u
APP_DIR=${1:?usage: init_env.sh <osb-application-folder>}
case "$APP_DIR" in *\\*|[A-Za-z]:*) command -v cygpath >/dev/null && APP_DIR=$(cygpath -u "$APP_DIR");; esac
[ -d "$APP_DIR" ] || { echo "not a folder: $APP_DIR"; exit 2; }
KIT_DIR=$(cd "$(dirname "$0")/.." && pwd)
pick() { for d in "$@"; do [ -d "$d" ] && { echo "$d"; return; }; done; }
JDK=$(pick /c/Program\ Files/Eclipse\ Adoptium/jdk-21* /c/Program\ Files/Java/jdk-21* /c/Program\ Files/Microsoft/jdk-21* "${JAVA_HOME:-/nonexistent}")
MVN=$(pick /e/Pawel/apache-maven-3.9* "$HOME"/apache-maven-3.9* /c/apache-maven-3.9* "$(dirname "$(dirname "$(command -v mvn 2>/dev/null || echo /x/x/x)")")")
first() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return; }; done; }
cat > .osb-kit.env <<ENV
# written by init_env.sh on $(date +%F); local only (.gitignore). Command-line values win over these defaults.
export KIT="\${KIT:-$KIT_DIR}"
export APP="\${APP:-$APP_DIR}"
export WS="\${WS:-$(pwd)}"
export JAVA_HOME="\${JAVA_HOME_21:-$JDK}"
export PATH="$MVN/bin:\$JAVA_HOME/bin:\$PATH"
export MVN_ARGS="\${MVN_ARGS:--s $HOME/.m2/settings.xml}"
export PI_OFFLINE="\${PI_OFFLINE:-1}" PI_TELEMETRY="\${PI_TELEMETRY:-0}" PI_PAUSE="\${PI_PAUSE:-60}"
export EXPORT="\${EXPORT:-$(first "$(pwd)/domain-export.csv")}"
export SPLUNK_COVERAGE="\${SPLUNK_COVERAGE:-$(first "$(pwd)/splunk-payload.csv")}"
export MASK_JSON_KEYS="\${MASK_JSON_KEYS:-reason}"
export POC="\${POC:-1}"
export BATCH_SIZE="\${BATCH_SIZE:-10}"
export ARTEMIS_HOME="\${ARTEMIS_HOME:-$(ls -d "$(dirname "$(pwd)")"/apache-artemis-* 2>/dev/null | head -1)}"   # local broker (broker/)
export ARTEMIS_BROKER="\${ARTEMIS_BROKER:-$(dirname "$(pwd)")/artemis-broker}"
export ARTEMIS_USER="\${ARTEMIS_USER:-artemis}"
# MASK_KEY and ARTEMIS_PASSWORD are NOT stored here: export them per session (data owner / broker password)
ENV
echo "written $(pwd)/.osb-kit.env"
grep -E '^export (KIT|APP|WS|JAVA_HOME|EXPORT|SPLUNK_COVERAGE)=' .osb-kit.env | sed 's/^export /  /'
[ -n "$JDK" ] || echo "  WARNING: no JDK 21 found: edit JAVA_HOME in .osb-kit.env"
[ -n "$MVN" ] || echo "  WARNING: no Maven 3.9 found: edit PATH in .osb-kit.env"
KIT_EOF_PI_INIT_ENV_SH
mkdir -p "$(dirname "pi/make_review_pack.sh")"
cat > 'pi/make_review_pack.sh' <<'KIT_EOF_PI_MAKE_REVIEW_PACK_SH'
#!/usr/bin/env bash
# One review package per flow: research -> card -> the module (standard Maven layout, runnable as is) -> results, with
# a reviewer checklist. Stays on the client machine (it contains the original XQuery and masked test data).
#
# Usage (in the workspace):  bash <kit>/pi/make_review_pack.sh <project> <proxy> [reference-route-dir]
# Env: ROUTE_AUTHOR (default "pi agent (osb-camelk-route)"): who wrote the route, shown in README_REVIEW.md
#   reference-route-dir  optional: another route for the same flow (e.g. the hand-written pilot) -> compared against
#                        the SAME frozen tests with compare_codegen.py
# Result: review/<project>-<proxy>/ + review/<project>-<proxy>.tgz   (agent logs and build output are left out)
#   1-research/   RESEARCH.md, research.json, facts.json, SHARE_CHECK.json
#   2-card/       FLOW_CARD.md
#   module/       pom.xml, src/main (route, properties, beans), src/test (frozen tests, cases, stubs), env/,
#                 MIGRATION_NOTES.md, .scaffold.json  ->  `mvn test` and the broker scripts work in this folder
#   5-results/    TEST_MATRIX.md, GATES.json, MUTATION.json, surefire summaries
#   6-compare/    (optional) generated route vs reference route on the same tests
set -uo pipefail
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
MVN_ARGS=${MVN_ARGS//\~/$HOME}   # "~" inside a variable is not expanded by the shell
P=${1:?usage: make_review_pack.sh <project> <proxy> [reference-route-dir]}
X=${2:?proxy}
REF=${3:-}
WS=${WS:-.}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
R="$WS/research/$P/$X"; M="$WS/modules/$P/$X"; O="$WS/review/$P-$X"
[ -s "$R/research.json" ] || { echo "no research pack in $R: run run_domain.sh research first"; exit 2; }
[ -d "$M" ] || { echo "no module in $M: run run_domain.sh tests (and build) first"; exit 2; }
rm -rf "$O"; mkdir -p "$O"/{1-research,2-card,module,5-results}
cp "$R"/RESEARCH.md "$R"/research.json "$R"/facts.json "$R"/SHARE_CHECK.json "$O/1-research/" 2>/dev/null
cp "$M/FLOW_CARD.md" "$O/2-card/" 2>/dev/null
for f in pom.xml FLOW_CARD.md MIGRATION_NOTES.md .scaffold.json .gitignore; do [ -f "$M/$f" ] && cp "$M/$f" "$O/module/"; done
for d in src env; do [ -d "$M/$d" ] && cp -r "$M/$d" "$O/module/"; done
cp "$M/GATES.json" "$M/MUTATION.json" "$M/TEST_MATRIX.md" "$M/test-matrix.csv" "$O/5-results/" 2>/dev/null
[ -d "$M/target/surefire-reports" ] && cp "$M"/target/surefire-reports/*.txt "$O/5-results/" 2>/dev/null
if [ -n "$REF" ] && [ -d "$REF" ]; then
  echo "== comparing the generated route with $REF on the same frozen tests"
  "$PY" "$(cd "$KIT/../../vdi-osb-migration/bin" 2>/dev/null && pwd || echo "$KIT/bin")/compare_codegen.py" "$M" \
    --candidate generated="$M/src/main" --candidate reference="$REF" --mvn "mvn -B -q ${MVN_ARGS:-}" -o "$O/6-compare" >/dev/null 2>&1 \
    && rm -rf "$O"/6-compare/generated "$O"/6-compare/reference || echo "   comparison failed: see $O/6-compare"
fi
"$PY" - "$O" "$P" "$X" "$M" "${ROUTE_AUTHOR:-pi agent (osb-camelk-route)}" <<'PY'
import json, sys, re
from pathlib import Path
o, p, x, m, author = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4]), sys.argv[5]
load = lambda f: json.loads(f.read_text(encoding="utf-8")) if f.is_file() else {}
g = load(m / "GATES.json"); mu = load(m / "MUTATION.json"); res = load(o / "1-research/research.json")
cfg = load(m / "src/test/resources/flow-test.json")
cases = [c for c in (m / "src/test/resources/parity").glob("**/input.payload")] if (m / "src/test/resources/parity").is_dir() else []
real = sum("-synthetic" not in c.as_posix() for c in cases)
card = (m / "FLOW_CARD.md").read_text(encoding="utf-8") if (m / "FLOW_CARD.md").is_file() else ""
st = (re.search(r"^Status:\s*(.+)$", card, re.M) or [None, "-"])[1]
k8 = g.get("gates", {}).get("K8_tests_green", {})
routes = sorted(p_.name for p_ in (m / "src/main/resources/routes").glob("*.yaml")) if (m / "src/main/resources/routes").is_dir() else []
lines = [f"# Review package: {p} / {x}", "",
         "Everything below stays on the client machine. Read in this order:", "",
         "| # | Where | What to check |", "|---|---|---|",
         "| 1 | `1-research/RESEARCH.md` | what the OSB flow does (entry, branches, outputs, errors, logs) with evidence; open questions |",
         "| 2 | `2-card/FLOW_CARD.md` | the behaviour the code must implement; status of the approval |",
         f"| 3 | `module/src/main/resources/routes/` | **the Camel route, written by: {author}** (YAML DSL); helper beans in `module/src/main/java`; `application.properties` = production descriptor (OSB names, selector, connection from the environment); `MIGRATION_NOTES.md` |",
         "| 4 | `module/src/test/` | FlowParityTest (generated, frozen), FlowErrorTest, expected outputs (`flow-test.json`), test messages (`resources/parity`, masked / synthetic), stubs |",
         "| 5 | `5-results/` | TEST_MATRIX.md, GATES.json (K1-K11), MUTATION.json, surefire summaries |",
         "| 6 | `6-compare/COMPARISON.md` | (if present) generated route vs reference route on the same tests |", "",
         "Run it yourself: `cd module && mvn -B -s <team settings.xml> test` (JDK 21, Maven 3.9); against a local Artemis:",
         "`broker/LOCAL_BROKER_TEST.md` of the kit (`env/local.properties` is in the module).", "",
         "## Summary", "",
         f"- Route written by: **{author}**",
         f"- Card status: **{st}**",
         f"- Route files: {', '.join(routes) or 'none (not built yet)'}",
         f"- Scenarios: {len(cfg.get('scenario_mapping') or [])}; test messages: {real} real (masked Splunk), {len(cases) - real} synthetic",
         f"- Outputs mocked: {', '.join(k for k in (cfg.get('outputs') or {}))}",
         f"- Tests: {k8.get('tests', '-')} run, {k8.get('failures', '-')} failed, {k8.get('errors', '-')} errors, {k8.get('skipped', '-')} skipped",
         f"- Gates: {g.get('result', 'not run')}" + ("; failing: " + ", ".join(k for k, v in g.get('gates', {}).items() if not v.get('ok')) if g else ""),
         f"- Mutations caught: {mu.get('killed', '-')}/{mu.get('total', '-')}",
         f"- Open questions in the research: {len(res.get('open_questions') or [])}", "",
         "## Reviewer checklist", "",
         "- [ ] Every branch, output, retry and error header of the card is in the route, nothing that is not on the card",
         "- [ ] One send per destination (a JMS business service that writes an output IS that output)",
         "- [ ] OSB log lines kept with the same text and logName (the tests do not check log text)",
         "- [ ] Original XQuery/XSLT used unchanged (not rewritten)",
         "- [ ] Body forwarded unchanged where OSB forwards it; routing fields are exchange properties, not headers",
         "- [ ] Endpoints only as properties with the OSB names; connection only as {{env:...}}; no hosts, ports, secrets",
         "- [ ] Error message: errorCode / errorMessage / debugInfo (osbStage) / correlation id as on the card",
         "- [ ] Helper beans small and readable; YAML DSL idiomatic for Camel 4.18",
         "- [ ] Differences to OSB listed in MIGRATION_NOTES.md and acceptable",
         "- [ ] Open questions answered or accepted before the card is approved", "",
         "Reviewer: ____________  Date: ________  Result: approve / changes needed"]
(o / "README_REVIEW.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
print("\n".join(lines[16:26]))
PY
(cd "$WS/review" && tar -czf "$P-$X.tgz" "$P-$X")
echo "review package: $O  (+ $WS/review/$P-$X.tgz). Keep it on the client machine."
KIT_EOF_PI_MAKE_REVIEW_PACK_SH
mkdir -p "$(dirname "pi/run_overnight.sh")"
cat > 'pi/run_overnight.sh' <<'KIT_EOF_PI_RUN_OVERNIGHT_SH'
#!/usr/bin/env bash
# Unattended run: works through a domain stage in small steps, pauses when the model quota is used up, tries again,
# and stops at a deadline. Start it, go home, read the log and the report in the morning.
#
# Usage (in the workspace, .osb-kit.env loaded, MASK_KEY exported):
#   bash <kit>/pi/run_overnight.sh <stage> [hours]          e.g.  POC=1 PROJECTS='a-prj' bash .../run_overnight.sh functional 10
# Env: QUIET=1 (output only to domain/overnight.log, not the terminal), QUOTA_SLEEP (seconds to wait after the endpoint refused everything, default 1800), MAX_ROUNDS (default 12),
#      plus the run_domain.sh env.
# Every round runs `run_domain.sh <stage>`; finished flows are skipped, so each round only does what is left.
# Log: domain/overnight.log. At the end: domain/FUNCTIONAL_TEST_REPORT.md and domain/TIME_PROJECTION.md.
set -u
for f in "${OSB_KIT_ENV:-}" ./.osb-kit.env "$HOME/.osb-kit.env"; do [ -n "$f" ] && [ -f "$f" ] && { . "$f"; break; }; done
MVN_ARGS=${MVN_ARGS//\~/$HOME}   # "~" inside a variable is not expanded by the shell
STAGE=${1:?usage: run_overnight.sh <stage> [hours]}
HOURS=${2:-10}
KIT=${KIT:-$(cd "$(dirname "$0")/.." && pwd)}
WS=${WS:-.}
LOG="$WS/domain/overnight.log"; mkdir -p "$WS/domain"
end=$(( $(date +%s) + HOURS * 3600 ))
round=0
echo "$(date '+%F %T') start: stage=$STAGE hours=$HOURS PROJECTS='${PROJECTS:-<all>}' BATCH_NO='${BATCH_NO:-}'" | tee -a "$LOG"
while [ "$(date +%s)" -lt "$end" ] && [ "$round" -lt "${MAX_ROUNDS:-12}" ]; do
  round=$((round + 1))
  echo "$(date '+%F %T') round $round" | tee -a "$LOG"
  # one tiny call first: on this endpoint a short call before a long run helped (login/token refresh or limit window)
  timeout 120 pi --print --no-session ${OSB_PI_MODEL:+--model "$OSB_PI_MODEL"} "Reply with the word OK" >> "$LOG" 2>&1 < /dev/null \
    || echo "$(date '+%F %T') warm-up call failed" >> "$LOG"
  if [ "${QUIET:-0}" = 1 ]; then          # QUIET=1: log file only; default: log file AND this terminal
    ALL=${ALL:-1} bash "$KIT/pi/run_domain.sh" "$STAGE" "$WS" >> "$LOG" 2>&1 < /dev/null; rc=$?
    tail -1 "$LOG"
  else
    ALL=${ALL:-1} bash "$KIT/pi/run_domain.sh" "$STAGE" "$WS" 2>&1 < /dev/null | tee -a "$LOG"; rc=${PIPESTATUS[0]}
  fi
  if [ "$rc" = 75 ] || tail -40 "$LOG" | grep -q "^STOP: the model endpoint"; then
    echo "$(date '+%F %T') quota used up: sleeping ${QUOTA_SLEEP:-1800}s" | tee -a "$LOG"
    sleep "${QUOTA_SLEEP:-1800}"; continue
  fi
  # nothing left to do when a round no longer starts any pi step
  if ! tail -n 200 "$LOG" | sed -n "/round $round\$/,\$p" | grep -qE "^=== (research|tests|build)"; then
    echo "$(date '+%F %T') nothing left for stage $STAGE: done" | tee -a "$LOG"; break
  fi
done
bash "$KIT/pi/run_domain.sh" report "$WS" >> "$LOG" 2>&1 < /dev/null
bash "$KIT/pi/run_domain.sh" time "$WS" >> "$LOG" 2>&1 < /dev/null
echo "$(date '+%F %T') finished after $round round(s); see domain/FUNCTIONAL_TEST_REPORT.md" | tee -a "$LOG"
KIT_EOF_PI_RUN_OVERNIGHT_SH
mkdir -p "$(dirname "pi/rate_limit_probe.py")"
cat > 'pi/rate_limit_probe.py' <<'KIT_EOF_PI_RATE_LIMIT_PROBE_PY'
#!/usr/bin/env python3
"""Ask the model endpoint for its rate limits: ONE tiny request, then print only the status and the rate-limit
headers (x-ratelimit-*, retry-after, ...). Never prints the API key, the URL's credentials or the answer text.

    python rate_limit_probe.py [--model fast] [--models ~/.pi/agent/models.json]

Reads the provider of the model from pi's models.json (baseUrl, apiKey or apiKey env name, api type) and sends an
OpenAI-compatible chat request ("Reply OK", max 5 tokens). Other API styles: prints what it found and stops."""
import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def find(models: dict, name: str):
    for pname, prov in (models.get("providers") or {}).items():
        for m in prov.get("models") or []:
            if name in (m.get("id"), m.get("name")):
                return pname, prov, m
    return None, None, None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=os.environ.get("OSB_PI_MODEL", "fast"))
    ap.add_argument("--models", type=Path, default=Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent")) / "models.json")
    a = ap.parse_args()
    models = json.loads(a.models.read_text(encoding="utf-8"))
    pname, prov, m = find(models, a.model.split("/")[-1])
    if not prov:
        print(f"model '{a.model}' not in {a.models}; providers: {list((models.get('providers') or {}).keys())}")
        return 2
    base = (prov.get("baseUrl") or prov.get("baseURL") or "").rstrip("/")
    key = prov.get("apiKey") or ""
    if key and key.upper() == key and not key.startswith(("sk-", "ey")) and os.environ.get(key):
        key = os.environ[key]                          # apiKey given as the NAME of an environment variable
    api = prov.get("api") or m.get("api") or "openai-completions"
    print(f"provider: {pname}  api: {api}  model id: {m.get('id')}  endpoint host: {base.split('/')[2] if '//' in base else '?'}")
    if "openai" not in api and "completions" not in api:
        print("not an OpenAI-compatible endpoint: probe stops here (send this line to the endpoint owner instead)")
        return 0
    body = json.dumps({"model": m.get("id"), "messages": [{"role": "user", "content": "Reply OK"}], "max_tokens": 5}).encode()
    req = urllib.request.Request(base + "/chat/completions", data=body, method="POST",
                                 headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {key}"} if key else {}),
                                          **(prov.get("headers") or {})})
    t0 = time.time()
    try:
        r = urllib.request.urlopen(req, timeout=60, context=ssl.create_default_context())
        status, headers = r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        status, headers = e.code, dict(e.headers)
    except Exception as e:                              # noqa: BLE001
        print(f"request failed: {type(e).__name__}")
        return 1
    print(f"status: {status}  in {time.time() - t0:.1f}s")
    shown = {k: v for k, v in headers.items() if any(w in k.lower() for w in ("ratelimit", "rate-limit", "retry-after", "quota", "x-ms-region", "apim"))}
    for k, v in sorted(shown.items()):
        print(f"  {k}: {v}")
    if not shown:
        print("  no rate-limit headers sent by the endpoint: only its owner can tell the limits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_PI_RATE_LIMIT_PROBE_PY
mkdir -p "$(dirname "pi/demo_limits.py")"
cat > 'pi/demo_limits.py' <<'KIT_EOF_PI_DEMO_LIMITS_PY'
#!/usr/bin/env python3
"""Live demo of the model platform limits that slow the pi agent down, and of the workaround. Stdlib only.

    python demo_limits.py config                         # which model pi uses, context window, pacer on or off
    python demo_limits.py burst  [--n 6] [--parallel 3]  # N tiny requests at once, DIRECT to the platform -> 429s
    python demo_limits.py paced  [--n 6]                 # the same requests through the pacer -> all 200, waits shown
    python demo_limits.py size   [--sizes 2,8,16,32,48]  # one request per prompt size (thousand tokens) -> time, 429, context
    python demo_limits.py agent  --project <osb-prj> --research <research/prj/proxy> [--turns 12]
                                                         # what ONE research run sends: tokens per call and per minute
    python demo_limits.py log    [domain/pacer.log]      # what the real runs met: calls, 429 retries, waiting, longest call

Every request carries SYNTHETIC text only ("line 0001 ...", "Reply OK"): no client data, no OSB source. Prints status,
seconds and token counts, never the API key, the answer text or the source. Keep --n small: the endpoint is shared.
Reads the provider from pi's models.json like rate_limit_probe.py; if pi points at the pacer, `burst` and `size` use
the platform URL saved in models.json.pacer.json, so they show what pi meets without the pacer."""
import argparse
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

CHARS_PER_TOKEN = 4          # rough rule for English text and XML; good enough to compare sizes
PACER = "http://127.0.0.1:{port}"


def models_file() -> Path:
    return Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent")) / "models.json"


def load_provider(model: str):
    """(provider name, provider dict, model dict, platform base URL, pacer active)."""
    mf = models_file()
    if not mf.is_file():
        sys.exit(f"no pi models.json at {mf} (set PI_CODING_AGENT_DIR)")
    models = json.loads(mf.read_text(encoding="utf-8"))
    for pname, prov in (models.get("providers") or {}).items():
        for m in prov.get("models") or []:
            if model.split("/")[-1] in (m.get("id"), m.get("name")):
                base = (prov.get("baseUrl") or prov.get("baseURL") or "").rstrip("/")
                paced = "127.0.0.1" in base or "localhost" in base
                side = mf.with_name("models.json.pacer.json")
                if paced and side.is_file():
                    base = (json.loads(side.read_text(encoding="utf-8")).get(pname) or base).rstrip("/")
                return pname, prov, m, base, paced
    sys.exit(f"model '{model}' not in {mf}; providers: {list((models.get('providers') or {}).keys())}")


def api_key(prov: dict) -> str:
    key = prov.get("apiKey") or ""
    if key and key.upper() == key and not key.startswith(("sk-", "ey")) and os.environ.get(key):
        key = os.environ[key]                     # apiKey given as the NAME of an environment variable
    return key


def host(url: str) -> str:
    return url.split("/")[2] if "//" in url else "?"


def call(base: str, prov: dict, model_id: str, prompt: str, max_tokens: int, timeout: float, ctx) -> dict:
    """One chat request. Returns status, seconds, usage and rate-limit headers; never the answer text."""
    body = json.dumps({"model": model_id, "messages": [{"role": "user", "content": prompt}],
                       "max_tokens": max_tokens, "temperature": 0}).encode()
    key = api_key(prov)
    headers = {"Content-Type": "application/json", **({"Authorization": f"Bearer {key}"} if key else {}),
               **(prov.get("headers") or {})}
    req = urllib.request.Request(base + "/chat/completions", data=body, method="POST", headers=headers)
    t0 = time.time()
    out = {"status": None, "usage": {}, "limits": {}, "note": ""}
    try:
        r = urllib.request.urlopen(req, timeout=timeout, context=ctx)
        out["status"], hdrs = r.status, dict(r.headers)
        try:
            out["usage"] = json.loads(r.read()).get("usage") or {}
        except ValueError:
            out["note"] = "answer not JSON"
    except urllib.error.HTTPError as e:
        out["status"], hdrs = e.code, dict(e.headers)
        text = e.read()[:400].decode("utf-8", "replace").lower()
        if "context" in text or "maximum" in text or "too long" in text or "tokens" in text:
            out["note"] = "refused: prompt longer than the context window"
        elif e.code == 429:
            out["note"] = "rate limit"
    except TimeoutError:
        out["status"], hdrs, out["note"] = "timeout", {}, f"no answer within {timeout:.0f}s"
    except Exception as e:                         # noqa: BLE001
        out["status"], hdrs = type(e).__name__, {}
        if "timed out" in str(e):
            out["status"], out["note"] = "timeout", f"no answer within {timeout:.0f}s"
    out["seconds"] = time.time() - t0
    out["limits"] = {k: v for k, v in hdrs.items() if any(w in k.lower() for w in ("ratelimit", "rate-limit", "retry-after", "quota"))}
    return out


def ssl_ctx():
    ctx = ssl.create_default_context()
    if os.environ.get("PACER_INSECURE") == "1":
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    return ctx


def filler(tokens: int) -> str:
    """Synthetic numbered lines of about `tokens` tokens, then one question about them."""
    line = "line {:05d}: the service reads a message, maps the fields and sends it to the next queue.\n"
    n = max(1, tokens * CHARS_PER_TOKEN // len(line.format(0)))
    return "".join(line.format(i) for i in range(1, n + 1)) + "\nReply with the number of the last line only."


def fmt(r: dict) -> str:
    u = r["usage"]
    tok = f"  prompt {u.get('prompt_tokens')} tok, answer {u.get('completion_tokens')} tok" if u else ""
    lim = ("  " + " ".join(f"{k}={v}" for k, v in sorted(r["limits"].items()))) if r["limits"] else ""
    return f"{str(r['status']):>8}  {r['seconds']:6.1f}s{tok}{('  ' + r['note']) if r['note'] else ''}{lim}"


def cmd_config(a) -> int:
    pname, prov, m, base, paced = load_provider(a.model)
    print(f"model      : {m.get('id')}  (provider {pname}, api {prov.get('api') or m.get('api') or 'openai-completions'})")
    print(f"platform   : {host(base)}")
    print(f"context    : {m.get('contextWindow', '? (not in models.json)')} tokens   max answer: {m.get('maxTokens', '?')} tokens")
    print(f"pi -> pacer: {'yes (127.0.0.1)' if paced else 'no, pi calls the platform directly'}")
    print(f"pi timeout : PI_TIMEOUT={os.environ.get('PI_TIMEOUT', '1800')}s per pi run (pi_call.sh), pacer 900s per call")
    return 0


def run_many(base, prov, m, n, parallel, prompt, max_tokens, timeout, label) -> list:
    ctx, results, lock, sem = ssl_ctx(), [None] * n, threading.Lock(), threading.Semaphore(parallel)
    t_start = time.time()

    def one(i):
        with sem:
            r = call(base, prov, m.get("id"), prompt, max_tokens, timeout, ctx)
            r["at"] = time.time() - t_start
            results[i] = r
            with lock:
                print(f"  #{i + 1:<2} start+{r['at'] - r['seconds']:5.1f}s {fmt(r)}", flush=True)

    print(f"{label}: {n} requests, {parallel} at a time, to {host(base)}")
    threads = [threading.Thread(target=one, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    counts: dict = {}
    for r in results:
        counts[str(r["status"])] = counts.get(str(r["status"]), 0) + 1
    print(f"result: {counts}  in {time.time() - t_start:.1f}s")
    return results


def cmd_burst(a) -> int:
    pname, prov, m, base, _ = load_provider(a.model)
    rs = run_many(base, prov, m, a.n, a.parallel, "Reply OK", 5, a.timeout, "burst DIRECT (what pi does without the pacer)")
    refused = sum(1 for r in rs if r["status"] == 429)
    print(f"=> {refused} of {a.n} refused with 429 although each request is tiny: the platform limits requests per time,"
          " and an agent fires its calls back to back" if refused else
          "=> no 429 this time: raise --n / --parallel a little, or run `size` (the limit also counts tokens per minute)")
    return 0


def cmd_paced(a) -> int:
    pname, prov, m, _, _ = load_provider(a.model)
    base = PACER.format(port=a.port)
    import socket
    with socket.socket() as so:
        so.settimeout(2)
        if so.connect_ex(("127.0.0.1", a.port)) != 0:
            sys.exit(f"pacer not running on {base}: bash $KIT/pi/vdi_session.sh start (or python llm_pacer.py)")
    run_many(base, prov, m, a.n, a.parallel, "Reply OK", 5, a.timeout + 600, "same requests THROUGH THE PACER (gap, retry on 429)")
    print("=> the pacer spaces the calls and repeats a refused call itself; pi never sees the 429. Cost: waiting time"
          " (see the pacer window / domain/pacer.log: 'retry n/30 in 15s')")
    return 0


def cmd_size(a) -> int:
    pname, prov, m, base, _ = load_provider(a.model)
    ctx = ssl_ctx()
    window = m.get("contextWindow")
    print(f"prompt size test, synthetic text, one request each, {a.pause:.0f}s pause, to {host(base)}"
          f" (context window in models.json: {window or '?'})")
    for k in a.sizes:
        tokens = int(k * 1000)
        r = call(base, prov, m.get("id"), filler(tokens), 16, a.timeout, ctx)
        print(f"  ~{k:>4}k tokens {fmt(r)}", flush=True)
        if a.pause:
            time.sleep(a.pause)
    print("=> time grows with the prompt; past the window the platform refuses; several big prompts within a minute"
          " hit the tokens-per-minute limit (429) although the requests are few")
    return 0


def tokens_of(paths) -> int:
    return sum(p.stat().st_size for p in paths if p.is_file()) // CHARS_PER_TOKEN


def cmd_agent(a) -> int:
    """Estimate, from file sizes only, what one research run (pi) sends to the model."""
    kit = Path(a.kit)
    sk = next((d for d in (kit / "skills/osb-research", kit / ".pi/skills/osb-research") if d.is_dir()), None)
    if not sk:
        sys.exit(f"skill osb-research not found under {kit}")
    research, project = Path(a.research), Path(a.project)
    sources = research / "SOURCES.txt"
    if not sources.is_file():
        sys.exit(f"{sources} missing: run research step 1 (facts) first")
    src = [project / s.strip() for s in sources.read_text(encoding="utf-8").splitlines() if s.strip()]
    fixed = {"pi system prompt + tool definitions (estimate)": 3000,
             "role prompt agents/researcher.md": tokens_of([kit / "agents/researcher.md"]),
             "skill osb-research (SKILL.md, questions, template, schema)": tokens_of(
                 [sk / "SKILL.md", sk / "references/questions.md", sk / "assets/RESEARCH_TEMPLATE.md", sk / "assets/research.schema.json"]),
             f"OSB sources of this proxy ({len(src)} files, one bundle)": tokens_of(src),
             "facts.json (step 1)": tokens_of([research / "facts.json"])}
    first = sum(fixed.values())
    print(f"one research run of {research.name}: what the model must hold (file sizes / {CHARS_PER_TOKEN}, no content shown)")
    for k, v in fixed.items():
        print(f"  {v:>7} tok  {k}")
    print(f"  {first:>7} tok  = context after the first turns (read skill + bundle)")
    print(f"\nan agent resends the WHOLE conversation on every call; each turn adds its own tool output and answer"
          f" (~{a.grow} tok here, thinking 'high' adds more):")
    total, ctx_now = 0, first
    for t in range(1, a.turns + 1):
        total += ctx_now
        flag = "  <- over the 64k window" if ctx_now > a.window else ""
        print(f"  call {t:>2}: sends {ctx_now:>7} tok   running total {total:>8} tok{flag}")
        ctx_now += a.grow
    per_min = total * 60 // max(1, int(a.turns * (a.gap + a.call_s)))
    print(f"\n=> ESTIMATE: {a.turns} calls = {total} tokens for ONE proxy; at {a.call_s:.0f}s per answer + {a.gap:.0f}s gap"
          f" that is ~{per_min} tokens per minute. The per-minute limit counts these tokens, not the number of calls."
          " A 4-proxy project = 4 such runs. Measured numbers: `demo_limits.py log` after a run through the pacer.")
    return 0


LOG_RE = re.compile(r"^(\d\d:\d\d:\d\d) (POST|GET) \S+ -> (\S+) attempts (\d+) waited (\d+)s total (\d+)s(?: sent (\d+) bytes)?")
RETRY_RE = re.compile(r"^(\d\d:\d\d:\d\d) \S+ -> (\S+), retry (\d+)/(\d+) in (\d+)s")


def _secs(hms: str) -> int:
    h, m, s = (int(x) for x in hms.split(":"))
    return h * 3600 + m * 60 + s


def cmd_log(a) -> int:
    p = Path(a.file)
    if not p.is_file():
        sys.exit(f"{p} not found (the pacer writes it when started by vdi_session.sh start)")
    calls, retries, statuses, waited, longest, per_hour, sizes = 0, 0, {}, 0, 0, {}, []
    retry_status: dict = {}
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        m = LOG_RE.match(line)
        if m and m.group(2) == "POST":
            calls += 1
            statuses[m.group(3)] = statuses.get(m.group(3), 0) + 1
            waited += int(m.group(5))
            longest = max(longest, int(m.group(6)))
            per_hour[m.group(1)[:2]] = per_hour.get(m.group(1)[:2], 0) + 1
            if m.group(7):
                sizes.append((m.group(1), int(m.group(7)) // CHARS_PER_TOKEN, int(m.group(6))))
            continue
        m = RETRY_RE.match(line)
        if m:
            retries += 1
            retry_status[m.group(2)] = retry_status.get(m.group(2), 0) + 1
    print(f"{p}: {calls} model calls answered, final status {statuses}")
    print(f"  refused and repeated by the pacer: {retries} times {retry_status}")
    print(f"  waiting caused by the limits: {waited}s ({waited / 60:.0f} min); longest single call {longest}s")
    print("  calls per hour of day: " + "  ".join(f"{h}h:{n}" for h, n in sorted(per_hour.items())))
    if sizes:
        last = sizes[-a.last:]
        print(f"  last {len(last)} calls, measured request size (bytes / {CHARS_PER_TOKEN}): an agent resends the whole conversation")
        for t, tok, secs in last:
            print(f"    {t}  ~{tok:>7} tok sent  answered in {secs:>4}s{'  <- over 64k' if tok > a.window else ''}")
        span = max(60, _secs(last[-1][0]) - _secs(last[0][0]) + last[-1][2])
        print(f"  ~{sum(t for _, t, _ in last) * 60 // span} tokens per minute over these calls")
    print("=> without the pacer every one of those refusals would have ended the pi run and restarted it from the beginning")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["config", "burst", "paced", "size", "agent", "log"])
    ap.add_argument("file", nargs="?", default=os.path.join(os.environ.get("WS", "."), "domain", "pacer.log"))
    ap.add_argument("--model", default=os.environ.get("OSB_PI_MODEL", "fast"))
    ap.add_argument("--n", type=int, default=6)
    ap.add_argument("--parallel", type=int, default=3)
    ap.add_argument("--port", type=int, default=int(os.environ.get("PACER_PORT", 8765)))
    ap.add_argument("--timeout", type=float, default=300, help="seconds per request")
    ap.add_argument("--sizes", type=lambda s: [float(x) for x in s.split(",")], default=[2, 8, 16, 32, 48])
    ap.add_argument("--pause", type=float, default=0, help="seconds between the size requests (0 = show the per-minute limit)")
    ap.add_argument("--project", help="OSB project folder (agent)")
    ap.add_argument("--research", help="research/<project>/<proxy> folder (agent)")
    ap.add_argument("--kit", default=os.environ.get("KIT", str(Path(__file__).resolve().parents[1])))
    ap.add_argument("--turns", type=int, default=12, help="model calls of one research run (agent)")
    ap.add_argument("--grow", type=int, default=2500, help="tokens one turn adds (agent)")
    ap.add_argument("--window", type=int, default=64000)
    ap.add_argument("--call-s", type=float, default=20, help="seconds one answer takes (agent estimate)")
    ap.add_argument("--last", type=int, default=15, help="calls shown with their size (log)")
    ap.add_argument("--gap", type=float, default=float(os.environ.get("PACER_GAP", 4)))
    a = ap.parse_args()
    if a.action == "agent" and not (a.project and a.research):
        ap.error("agent needs --project <osb-project-dir> --research <research/<project>/<proxy>>")
    return {"config": cmd_config, "burst": cmd_burst, "paced": cmd_paced, "size": cmd_size, "agent": cmd_agent, "log": cmd_log}[a.action](a)


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_PI_DEMO_LIMITS_PY
mkdir -p "$(dirname ".pi/prompts/osb-research.md")"
cat > '.pi/prompts/osb-research.md' <<'KIT_EOF__PI_PROMPTS_OSB_RESEARCH_MD'
---
description: "OSB proxy -> shareable research pack (no code, no hosts, no data)"
argument-hint: "<osb-project-dir> <proxy> [task1-dir]"
---
Act as the researcher defined in agents/researcher.md and follow AGENTS.md.
Use skill osb-research on the OSB export $1 for proxy $2 (scenarios from $3/traces/scenarios.json if given).
Write research/$2/RESEARCH.md and research/$2/research.json, run the share check until it passes, then give the five-line report.
KIT_EOF__PI_PROMPTS_OSB_RESEARCH_MD
chmod +x .pi/skills/osb-research/scripts/*.py pi/run_research.sh 2>/dev/null || true
echo "installed: 16 files (skill osb-research)"
