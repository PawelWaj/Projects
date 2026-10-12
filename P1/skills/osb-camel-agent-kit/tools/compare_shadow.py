#!/usr/bin/env python3
"""L6 shadow comparison: pair OSB and Camel output messages by a correlation key and diff them.

Each message is a file <name>.xml or <name>.json with an optional <name>.headers.json ({"header": "value"}).
The key is taken from the headers first, else from the first XML element / JSON field whose local name equals --key.
Elements or fields whose name is in --ignore are removed before the comparison (XML: canonical C14N 2.0; JSON: sorted
keys); headers listed in --ignore are dropped too. Duplicate keys on either side are reported (a message delivered
twice). Body differences name the first differing path. Exit 0 = no differences and no unmatched messages,
1 = differences, 2 = usage error.
"""
from __future__ import annotations

import argparse
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def strip(elem: ET.Element, ignore: set[str]) -> None:
    for child in list(elem):
        if local(child.tag) in ignore:
            elem.remove(child)
        else:
            strip(child, ignore)


def strip_json(obj, ignore: set[str]):
    if isinstance(obj, dict):
        return {k: strip_json(v, ignore) for k, v in obj.items() if k not in ignore}
    if isinstance(obj, list):
        return [strip_json(v, ignore) for v in obj]
    return obj


def find_json_key(obj, key: str):
    if isinstance(obj, dict):
        if key in obj and isinstance(obj[key], (str, int)):
            return str(obj[key])
        for v in obj.values():
            r = find_json_key(v, key)
            if r:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = find_json_key(v, key)
            if r:
                return r
    return None


def first_diff_path(a, b, path="$") -> str:
    """First differing path of two parsed JSON values ("$" root)."""
    if type(a) is not type(b):
        return path
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                return f"{path}.{k}"
            d = first_diff_path(a[k], b[k], f"{path}.{k}")
            if d:
                return d
        return ""
    if isinstance(a, list):
        if len(a) != len(b):
            return f"{path}[len {len(a)} vs {len(b)}]"
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_diff_path(x, y, f"{path}[{i}]")
            if d:
                return d
        return ""
    return path if a != b else ""


def load(dir_: Path, key: str, ignore: set[str]) -> tuple[dict[str, tuple[str, dict, object]], list[str], list[str]]:
    """Returns {key: (canonical body text, headers, parsed json or None)}, unreadable, duplicate keys."""
    msgs, errors, dups = {}, [], []
    files = [f for f in sorted(dir_.iterdir()) if f.suffix in (".xml", ".json") and not f.name.endswith(".headers.json")]
    for f in files:
        hdr_file = f.with_name(f.stem + ".headers.json")
        headers = json.loads(hdr_file.read_text(encoding="utf-8")) if hdr_file.is_file() else {}
        parsed = None
        try:
            if f.suffix == ".json":
                parsed = strip_json(json.loads(f.read_text(encoding="utf-8")), ignore)
                k = headers.get(key) or find_json_key(parsed, key)
                canon = json.dumps(parsed, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            else:
                root = ET.fromstring(f.read_bytes())
                k = headers.get(key) or next((e.text for e in root.iter() if local(e.tag) == key and e.text), None)
                strip(root, ignore)
                canon = ET.canonicalize(ET.tostring(root, encoding="unicode"), strip_text=True)
        except (ET.ParseError, json.JSONDecodeError) as exc:
            errors.append(f"{f.name}: {exc}")
            continue
        if not k:
            errors.append(f"{f.name}: no key '{key}'")
            continue
        if k in msgs:
            dups.append(k)
            continue
        msgs[k] = (canon, {h: v for h, v in headers.items() if h not in ignore}, parsed)
    return msgs, errors, dups


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--osb", type=Path, required=True)
    ap.add_argument("--camel", type=Path, required=True)
    ap.add_argument("--key", default="correlationId")
    ap.add_argument("--ignore", default="", help="comma-separated element/header local names")
    ap.add_argument("-o", "--out", type=Path)
    args = ap.parse_args()
    if not args.osb.is_dir() or not args.camel.is_dir():
        print("both --osb and --camel must be directories", file=sys.stderr)
        return 2
    ignore = {s.strip() for s in args.ignore.split(",") if s.strip()}
    osb, osb_err, osb_dup = load(args.osb, args.key, ignore)
    cam, cam_err, cam_dup = load(args.camel, args.key, ignore)
    equal, body_diff, header_diff = [], [], []
    for k in sorted(set(osb) & set(cam)):
        (ob, oh, oj), (cb, ch, cj) = osb[k], cam[k]
        if ob != cb:
            body_diff.append({"key": k, "path": first_diff_path(oj, cj) if oj is not None and cj is not None else "xml body"})
        if oh != ch:
            header_diff.append({"key": k, "osb": oh, "camel": ch})
        if ob == cb and oh == ch:
            equal.append(k)
    report = {"matched_equal": len(equal), "body_diff": body_diff, "header_diff": header_diff,
              "osb_only": sorted(set(osb) - set(cam)), "camel_only": sorted(set(cam) - set(osb)),
              "duplicate_keys": {"osb": sorted(osb_dup), "camel": sorted(cam_dup)},
              "unreadable": osb_err + cam_err, "ignored": sorted(ignore)}
    clean = not (body_diff or header_diff or report["osb_only"] or report["camel_only"] or report["unreadable"]
                 or osb_dup or cam_dup)
    report["status"] = "PASS" if clean else "FAIL"
    text = json.dumps(report, indent=2)
    if args.out:
        args.out.write_text(text, encoding="utf-8")
    print(text)
    return 0 if clean else 1


if __name__ == "__main__":
    sys.exit(main())
