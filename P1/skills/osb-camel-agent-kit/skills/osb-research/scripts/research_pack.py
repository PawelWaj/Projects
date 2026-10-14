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
    ap.add_argument("proxy", help="proxy service name, e.g. maintain-adjustment")
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
