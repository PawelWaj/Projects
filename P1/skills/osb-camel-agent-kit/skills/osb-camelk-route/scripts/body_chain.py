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
              "routes": list(state["routes"])}
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
            headers = []
            ot = first(a, "outboundTransform")
            if ot is not None:
                for h in ot.iter():
                    if loc(h.tag) == "header" and h.get("name"):
                        headers.append(h.get("name"))
            st["routes"].append({"service": short_ref(svc.get("ref", "") if svc is not None else ""), "kind": t,
                                 "conds": list(st["conds"]), "chain": list(st["body"]), "headers": headers})
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
    start = {"body": [], "vars": {}, "conds": [], "routes": []}
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
        e_states = [{"body": ["error-handler-body"], "vars": dict(states[0]["vars"]) if states else {}, "conds": [], "routes": []}]
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
    return {"pipeline": path.name, "outputs": routes, "error_outputs": errors, "unknown_tags": sorted(w.unknown)}


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
