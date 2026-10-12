#!/usr/bin/env python3
"""Build a log signature from ONE example log line, when the OSB source is not available yet.

    signature_from_example.py <masked.csv|masked.log> -o signatures.json [--line N] [--flow project/proxy]
                              [--field hdr_name="literal text"] [--append]

The normal path derives signatures from the Log actions in the OSB source (osb_log_signatures.py). Without the
source, this tool takes one ANONYMISED example line and turns it into the same signature format, so
osb_log_traces.py, fixtures_from_traces.py and the replay work on the log alone:
  * the OSB message text is taken without its ODL/WebLogic envelope;
  * a trailing JSON or XML payload becomes the `body` group;
  * UUIDs become `traceId` (the first one is the correlation id; without any, traces fall back to the ODL ecid);
  * "Resource Name: <x> event" becomes `hdr_resource` (a scenario dimension); add more with --field hdr_x="literal";
  * `Project <p> :: for PS <proxy>` gives the flow id <p>/<proxy> (or pass --flow);
  * the stage direction in the ODL location ([..., REQUEST|RESPONSE|ERROR_HANDLER]) gives the pipeline type.
Run it once per kind of line (e.g. a request line, then an error line) with --append to build one signatures file.
Stdlib only."""
import argparse
import csv
import io
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from osb_log_traces import osb_message  # noqa: E402

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
DIRECTION = re.compile(r",\s*(REQUEST|RESPONSE|ERROR_HANDLER|ROUTING|ROUTE|NONE)\]")
LEVEL = re.compile(r"^\[[^\]]*\]\s*\[[^\]]*\]\s*\[([A-Z_]+)")


def example_lines(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    if path.suffix.lower() == ".csv":
        return [r["_raw"] for r in csv.DictReader(io.StringIO(text, newline="")) if r.get("_raw")]
    return [line for line in text.splitlines() if line.strip()]


def payload_start(msg: str) -> int | None:
    """Earliest position from which the rest of the message parses as JSON (or looks like an XML document)."""
    for m in re.finditer(r"[{<]", msg):
        rest = msg[m.start():].strip()
        if rest.startswith("{"):
            try:
                json.loads(rest)
                return m.start()
            except ValueError:
                continue
        elif re.match(r"<[A-Za-z_][\w:.-]*[\s>/]", rest) and rest.rstrip().endswith(">"):
            return m.start()
    return None


def to_regex(literal: str) -> str:
    return r"\s+".join(re.escape(part) for part in literal.split())


def build(raw: str, flow: str | None, fields: dict[str, str]) -> dict:
    msg, meta = osb_message(raw)
    msg = msg.strip()
    p = payload_start(msg)
    prefix, has_body = (msg[:p], True) if p is not None else (msg, False)

    m = re.search(r"Resource Name:\s*(.+?)\s+event\b", prefix)
    if m and "hdr_resource" not in fields:
        fields = {**fields, "hdr_resource": m.group(1)}
    pieces = [(prefix, None)]

    def split(pieces, literal, name):
        out = []
        for text, grp in pieces:
            if grp is not None or literal not in text:
                out.append((text, grp))
                continue
            a, b = text.split(literal, 1)
            out += [(a, None), (literal, name), (b, None)]
        return out

    for name, literal in fields.items():
        pieces = split(pieces, literal, name)
    uuids = []
    for text, grp in list(pieces):
        if grp is None:
            uuids += UUID.findall(text)
    for i, u in enumerate(dict.fromkeys(uuids)):
        pieces = split(pieces, u, "traceId" if i == 0 else f"uuid{i + 1}")

    regex, groups = "", []
    for text, grp in pieces:
        if grp is None:
            if text[:1].isspace():
                regex += r"\s*"
            regex += to_regex(text) if text.strip() else ""
            if text[-1:].isspace() and text.strip():
                regex += r"\s*"
        else:
            regex += rf"(?P<{grp}>.+?)" if not grp.startswith(("traceId", "uuid")) else rf"(?P<{grp}>[0-9a-fA-F-]{{36}})"
            groups.append({"name": grp, "expr": "example"})
    regex = re.sub(r"(\\s\*)+", r"\\s*", regex)
    if has_body:
        regex += r"\s*(?P<body>.*)"
        groups.append({"name": "body", "expr": "example payload"})

    fm = re.search(r"Project\s+(\S+)\s+::\s+for\s+PS\s+(\S+)", prefix)
    flow = flow or (f"{fm.group(1)}/{fm.group(2)}" if fm else None)
    if not flow:
        sys.exit("cannot derive the flow id from the line: pass --flow <project>/<proxy>")
    d = DIRECTION.search(raw)
    direction = d.group(1) if d else "NONE"
    lv = LEVEL.search(raw)
    level = (lv.group(1) if lv else meta.get("level", "")).lower()
    ptype = "error" if direction == "ERROR_HANDLER" or level in ("error", "incident_error") else (
        "response" if direction == "RESPONSE" else "request")
    anchor = next((t for t, g in pieces if g is None and t.strip()), "").strip()
    names = [g["name"] for g in groups]
    return {
        "id": f"{flow}#example-{ptype}",
        "flow": flow, "file": "(from example log line)", "pipeline_type": ptype, "stage": direction.lower(),
        "level": level or "info", "annotation": "derived from an example line, not from the OSB source",
        "expression": "", "regex": regex, "anchor": anchor[:80], "groups": groups,
        "roles": {"correlation": [n for n in names if n == "traceId"], "payload": ["body"] if has_body else [],
                  "fault": ["body"] if ptype == "error" and has_body else [],
                  "headers": [n for n in names if n.startswith("hdr_")], "business_keys": []},
        "warnings": [] if "traceId" in names else ["no UUID in the line: traces will be grouped by the ODL ecid"],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("examples", type=Path, help="anonymised CSV (_raw column) or log file")
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--line", type=int, default=1, help="which event of the file to use as the example (1-based)")
    ap.add_argument("--flow", help="flow id <project>/<proxy> when the line does not name them")
    ap.add_argument("--field", action="append", default=[], help='hdr_<name>="literal" turns a literal into a scenario field')
    ap.add_argument("--append", action="store_true", help="add to an existing signatures file (one signature per kind of line)")
    a = ap.parse_args()
    lines = example_lines(a.examples)
    if not 1 <= a.line <= len(lines):
        sys.exit(f"{a.examples}: {len(lines)} events, --line {a.line} out of range")
    fields = dict(f.split("=", 1) for f in a.field)
    sig = build(lines[a.line - 1], a.flow, {k: v.strip('"') for k, v in fields.items()})
    rx = re.compile(sig["regex"], re.S)
    msg = osb_message(lines[a.line - 1])[0].strip()
    if not (rx.fullmatch(msg) or rx.search(msg)):
        sys.exit("internal check failed: the generated regex does not match its own example")
    doc = json.loads(a.out.read_text(encoding="utf-8")) if a.append and a.out.is_file() else {"source": "example lines", "signatures": []}
    doc["signatures"] = [s for s in doc["signatures"] if s["id"] != sig["id"]] + [sig]
    a.out.write_text(json.dumps(doc, indent=2, ensure_ascii=False), encoding="utf-8")
    matched = sum(1 for line in lines if rx.search(osb_message(line)[0]))
    print(json.dumps({"signature": sig["id"], "pipeline_type": sig["pipeline_type"], "groups": [g["name"] for g in sig["groups"]],
                      "matches_in_file": f"{matched}/{len(lines)}", "warnings": sig["warnings"], "out": str(a.out)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
