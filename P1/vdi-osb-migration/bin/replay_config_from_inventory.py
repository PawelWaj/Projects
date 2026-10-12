#!/usr/bin/env python3
"""Draft the replay-config entry of a flow from its inventory JSON (osb_inventory.py output).

    replay_config_from_inventory.py <flows/Project__Proxy.json> -o replay-config.json [--project <name>]
                                    [--correlation-header traceId] [--subscription <name>]

Reads the proxy transport (JMS address, queue/topic, selector) and the business services the pipeline routes or
publishes to, and writes/merges the entry `flows.<project>/<proxy>` in the replay config. Everything that cannot be
derived from the export is marked in `_todo`: TARGET broker names (the export holds WebLogic JNDI names), the
correlation header, the error-queue headers. HTTP inbound flows get an `_unsupported` note (replay is JMS-only;
the contract tests cover them). Negative cases are generated from the selector's equality terms. Stdlib only."""
import argparse
import json
import re
import sys
from pathlib import Path


def jndi_name(uri: str) -> str:
    """jms://host:port/jndi.CF/jndi.Queue -> Queue  (last segment, jndi. prefix stripped)."""
    last = uri.rstrip("/").split("/")[-1]
    return re.sub(r"^jndi\.", "", last)


def selector_terms(selector: str) -> list[tuple[str, str]]:
    return re.findall(r"([A-Za-z_][\w.]*)\s*=\s*'([^']*)'", selector or "")


def negative_cases(selector: str) -> list[dict]:
    terms = selector_terms(selector)
    if not terms:
        return []
    first = {}
    for k, v in terms:
        first.setdefault(k, v)
    cases = []
    for k in first:
        headers = dict(first)
        headers[k] = "not-" + first[k]
        cases.append({"name": f"{k} outside the selector is filtered out", "headers": headers})
    return cases


def entry_for(flow: dict, project: str, corr: str, subscription: str | None) -> tuple[str, dict]:
    proxy, pipe = flow["proxy"], flow["pipeline"]
    proxy_name = Path(proxy["ref"]).name
    key = f"{project}/{proxy_name}"
    todo = []
    if proxy.get("transport") != "jms":
        return key, {"_unsupported": f"inbound transport '{proxy.get('transport')}': replay is JMS-only; use the route/contract tests (L1/L2)",
                     "input": {"type": proxy.get("transport"), "uris": proxy.get("uris", [])}}
    props = proxy.get("transport_props", {})
    is_queue = str(props.get("is-queue", "true")).lower() == "true"
    address = jndi_name(proxy["uris"][0]) if proxy.get("uris") else "<input-address>"
    todo.append("input.address and outputs.*.destination are JNDI-derived: replace with the TARGET broker names from the queue register")
    targets = [b for b in flow.get("business", []) if b.get("transport") == "jms" and b.get("uris")]
    refs = pipe.get("routes_to", []) + pipe.get("publishes_to", [])
    ordered = sorted(targets, key=lambda b: refs.index(b["ref"]) if b["ref"] in refs else 99)
    err = next((b for b in ordered if re.search(r"error|dlq|fault|dead", b["ref"], re.I)), None)
    succ = next((b for b in ordered if b is not err), None)
    outputs = {}
    if succ:
        outputs["success"] = {"destination": jndi_name(succ["uris"][0]), "type": "anycast"}
    else:
        outputs["success"] = {"destination": "<success-queue>", "type": "anycast"}
        todo.append("no JMS success target found in routes_to/publishes_to: set outputs.success.destination")
    if err:
        outputs["error"] = {"destination": jndi_name(err["uris"][0]), "type": "anycast",
                            "expect_headers": ["errorCode", "errorMessage", corr]}
        todo.append("outputs.error.expect_headers: confirm against the error handler's transport headers on the flow card")
    else:
        todo.append("no error queue found: confirm from the error handler scopes " + json.dumps(pipe.get("error_handler_scopes", [])))
    e = {
        "input": {"address": address, "type": "anycast" if is_queue else "multicast",
                  "subscription": subscription or f"{proxy_name}-sub", "filter": props.get("message-selector", "")},
        "correlation_header": corr,
        "outputs": outputs,
        "negative_cases": negative_cases(props.get("message-selector", "")),
        "timeout_s": 15,
        "_source": {"proxy": proxy.get("path"), "durable": props.get("durable-subscription"),
                    "xa": props.get("XA-required"), "distribution": props.get("topic-messages-distribution")},
        "_todo": todo + [f"correlation_header '{corr}' is a default: confirm the header the flow logs"],
    }
    return key, e


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("flow_json", type=Path)
    ap.add_argument("-o", "--out", type=Path, required=True, help="replay-config.json to create or merge into")
    ap.add_argument("--project", help="project name used in the flow id (default: from the file name Project__...)")
    ap.add_argument("--correlation-header", default="traceId")
    ap.add_argument("--subscription")
    a = ap.parse_args()
    flow = json.loads(a.flow_json.read_text(encoding="utf-8"))
    stem = a.flow_json.stem
    project = a.project or (stem.split("__")[0] if "__" in stem else a.flow_json.parent.parent.name)
    key, entry = entry_for(flow, project, a.correlation_header, a.subscription)
    cfg = json.loads(a.out.read_text(encoding="utf-8")) if a.out.is_file() else {
        "_comment": "One entry per OSB flow under test. Destinations are TARGET broker names.",
        "broker": {"host": "localhost", "stomp_port": 61613, "user": "artemis", "password_env": "ARTEMIS_PASSWORD"},
        "flows": {}}
    existing = cfg.setdefault("flows", {}).get(key)
    if existing and "_todo" not in existing:
        print(json.dumps({"flow": key, "status": "kept", "detail": "entry exists and was completed by hand; not overwritten"}))
        return 0
    cfg["flows"][key] = entry
    a.out.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"flow": key, "status": "drafted", "todo": entry.get("_todo", []), "unsupported": entry.get("_unsupported")}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
