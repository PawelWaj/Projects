#!/usr/bin/env python3
"""Synthetic test messages WITHOUT an AI: one case per uncovered scenario, built from the flow's schema. Stdlib only.

    synth_from_schema.py <module> <osb-project-dir> [--research research/<p>/<x>/research.json] [--schema file.xsd]

For every scenario_mapping row of <module>/src/test/resources/flow-test.json that has no case yet:
  - message structure from the schema: the nXSD named in the research pack (entry.nxsd) or the --schema given, else
    the XSD in the project whose global element is used; nXSD with nxsd:version="JSON" -> a JSON message (the global
    element is the JSON object itself), otherwise XML
  - every field gets a FAKE value by type (string "masked_fake", numbers 1, booleans false, dates 2026-01-01)
  - the scenario fields get exactly the row's values (k=v), or a different value for k!=v (true -> false, else "other")
  - a row whose only output is the error output gets a deliberately unreadable message
Writes parity/<project>-<proxy>-synthetic/<row>/case1/{input.payload, headers.json, expected.json} + SCENARIO.txt,
the same layout as the pi tester. Rows it cannot build (no schema, field not in the schema) are listed for pi.
Fake values only, no data. Prints {"written": n, "left_for_pi": [...]}"""
import argparse
import json
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

XS = "{http://www.w3.org/2001/XMLSchema}"


def parts(key: str) -> list[tuple[str, str, str]]:
    out = []
    for p in key.split("|"):
        if "!=" in p:
            k, v = p.split("!=", 1)
            out.append((k, "!=", v))
        elif "=" in p:
            k, v = p.split("=", 1)
            out.append((k, "=", v))
    return out


def covered_keys(mod: Path) -> list[dict]:
    return [dict(p.split("=", 1) for p in sc.read_text(encoding="utf-8").strip().split("|") if "=" in p)
            for sc in (mod / "src/test/resources/parity").glob("*/*/SCENARIO.txt")]


def hit(key: str, v: dict) -> bool:
    for k, op, x in parts(key):
        if (op == "=" and v.get(k) != x) or (op == "!=" and v.get(k) == x):
            return False
    return True


class Schema:
    def __init__(self, path: Path):
        self.root = ET.parse(path).getroot()
        self.json = any(re.search(r"version$", k) and v.upper() == "JSON" for k, v in self.root.attrib.items())
        self.types = {t.get("name"): t for t in self.root.findall(XS + "complexType")}
        self.elems = {e.get("name"): e for e in self.root.findall(XS + "element")}

    def instance(self, el: ET.Element, depth: int = 0):
        if el.get("ref"):
            el = self.elems.get(el.get("ref").split(":")[-1], el)
        typ = (el.get("type") or "").split(":")[-1]
        ct = el.find(XS + "complexType")
        if ct is None:
            ct = self.types.get(typ)
        if ct is None or depth > 8:
            return self.leaf(typ)
        out = {}
        for child in self.children(ct):
            name = child.get("name") or (child.get("ref") or "").split(":")[-1]
            val = self.instance(child, depth + 1)
            out[name] = [val] if child.get("maxOccurs") not in (None, "1") else val
        return out

    def children(self, node: ET.Element) -> list:
        """Direct child elements of a complex type: through sequence/all/choice/complexContent/extension, not deeper."""
        out = []
        for c in node:
            if c.tag == XS + "element":
                out.append(c)
            elif c.tag in (XS + "sequence", XS + "all", XS + "choice", XS + "complexContent", XS + "extension", XS + "group"):
                out += self.children(c)
        return out

    @staticmethod
    def leaf(typ: str):
        t = typ.lower()
        if t in ("int", "integer", "long", "short", "decimal", "double", "float", "nonnegativeinteger", "positiveinteger"):
            return 1
        if t == "boolean":
            return False
        if t in ("date", "datetime"):
            return "2026-01-01" if t == "date" else "2026-01-01T00:00:00Z"
        return "masked_fake"


def set_path(obj, path: list[str], value) -> bool:
    for k in path[:-1]:
        if isinstance(obj, list):
            obj = obj[0]
        if not isinstance(obj, dict) or k not in obj:
            return False
        obj = obj[k]
    if isinstance(obj, list):
        obj = obj[0]
    if not isinstance(obj, dict) or path[-1] not in obj:
        return False
    obj[path[-1]] = value
    return True


def set_any(obj, name: str, value) -> bool:
    """//name: set the first field with that name at any depth (where OSB's //*:name would find it)."""
    if isinstance(obj, dict):
        if name in obj:
            obj[name] = value
            return True
        return any(set_any(v, name, value) for v in obj.values())
    if isinstance(obj, list):
        return any(set_any(v, name, value) for v in obj)
    return False


def to_xml(name: str, value) -> str:
    if isinstance(value, dict):
        return f"<{name}>" + "".join(to_xml(k, v) for k, v in value.items()) + f"</{name}>"
    if isinstance(value, list):
        return "".join(to_xml(name, v) for v in value)
    return f"<{name}>{str(value).lower() if isinstance(value, bool) else value}</{name}>"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("project", type=Path)
    ap.add_argument("--research", type=Path)
    ap.add_argument("--schema", type=Path)
    a = ap.parse_args()
    cfg = json.loads((a.module / "src/test/resources/flow-test.json").read_text(encoding="utf-8"))
    meta = json.loads((a.module / ".scaffold.json").read_text(encoding="utf-8"))
    res = json.loads(a.research.read_text(encoding="utf-8")) if a.research and a.research.is_file() else {}
    dims = {d.lstrip("/").split(".")[-1]: d.lstrip("/").split(".") for d in res.get("scenario_dims") or []}
    flow_dir = a.module / "src/test/resources/parity" / f"{meta['project']}-{meta['proxy']}-synthetic"
    rows = [m["scenario"] for m in cfg.get("scenario_mapping", [])]
    for sc in sorted(flow_dir.glob("*/SCENARIO.txt")) if flow_dir.is_dir() else []:
        v = dict(p.split("=", 1) for p in sc.read_text(encoding="utf-8").strip().split("|") if "=" in p)
        if v and not any(hit(r, v) for r in rows):        # written for a mapping that has changed since: stale
            shutil.rmtree(sc.parent)
            gone = sc.parent.relative_to(a.module).as_posix() + "/"
            meta["generated"] = {k: h for k, h in meta["generated"].items() if not k.startswith(gone)}   # unfreeze only these
            (a.module / ".scaffold.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
            print(json.dumps({"removed_stale_synthetic": sc.parent.name}))
    have = covered_keys(a.module)
    todo = [m for m in cfg.get("scenario_mapping", []) if not any(hit(m["scenario"], v) for v in have)]
    schema_file = a.schema
    if not schema_file:
        want = ((res.get("entry") or {}).get("nxsd") or "").split("/")[-1].lower()
        xsds = sorted(a.project.rglob("*.xsd"))
        schema_file = next((x for x in xsds if want and x.stem.lower().startswith(want)), None) or \
            next((x for x in xsds if "nxsd" in x.name.lower()), None)
    left, written = [], 0
    sch = None
    if schema_file and schema_file.is_file():
        try:
            sch = Schema(schema_file)
        except ET.ParseError:
            sch = None
    for i, row in enumerate(todo, 1):
        key, outs = row["scenario"], row.get("outputs") or []
        err_only = outs == [cfg.get("error_output")]
        if sch is None and not err_only:
            left.append(key)
            continue
        shown = {}
        if err_only:
            body = "{[[ deliberately unreadable message"
        else:
            root = next(iter(sch.elems.values()))
            msg = sch.instance(root)
            ok, shown = True, {}
            for k, op, v in parts(key):
                path = dims.get(k)
                if not path:
                    continue                                   # header dims (hdr_*) go to headers.json
                val = {"true": True, "false": False}.get(v, v) if op == "=" else (False if v == "true" else "other")
                shown[k] = str(val).lower() if isinstance(val, bool) else str(val)
                ok &= set_path(msg, path, val) or set_path(msg, path[1:], val) or set_any(msg, path[-1], val)
            if not ok:
                left.append(key)
                continue
            body = json.dumps(msg, indent=2) if sch.json else to_xml(root.get("name"), msg)
        slug = re.sub(r"[^a-z0-9]+", "-", key.lower().replace("!=", "-not-")).strip("-")[:70] or f"row{i}"
        case = flow_dir / slug / "case1"
        case.mkdir(parents=True, exist_ok=True)
        hdr = {k[4:]: v for k, op, v in parts(key) if k.startswith("hdr_") and op == "="}
        hdr["traceId"] = f"synthetic-{i:04d}"
        keys = "|".join(f"{k}={shown.get(k, v if op == '=' else 'other')}" for k, op, v in parts(key))
        (case.parent / "SCENARIO.txt").write_text(f"{meta['project']}/{meta['proxy']}|success" + (f"|{keys}" if keys else "") + "\n",
                                                  encoding="utf-8")
        (case / "input.payload").write_text(body + "\n", encoding="utf-8")
        (case / "headers.json").write_text(json.dumps(hdr, indent=2), encoding="utf-8")
        (case / "expected.json").write_text(json.dumps({"outcome": "success", "destination": "see mapping",
                                                         "correlation": hdr["traceId"]}, indent=2), encoding="utf-8")
        written += 1
    print(json.dumps({"schema": schema_file.name if schema_file else None, "written": written, "left_for_pi": left}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
