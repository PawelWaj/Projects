#!/usr/bin/env bash
# Paste into the migration workspace root on the VDI and run: bash 6_install_log_replay.sh
# osb-log-replay: Splunk logs -> masked test cases -> fixtures -> replay (log-replay/).
set -euo pipefail
mkdir -p "$(dirname "log-replay/tools/anonymize_logs.py")"
cat > 'log-replay/tools/anonymize_logs.py' <<'KIT_EOF_LOG_REPLAY_TOOLS_ANONYMIZE_LOGS_PY'
#!/usr/bin/env python3
"""Anonymise an OSB log export BEFORE anything else is done with it. No OSB source is needed.

    export MASK_KEY='<key held by the data owner>'
    python3 tools/anonymize_logs.py <events.csv|events.log> -o <masked.csv|masked.log> [--report masked.report.json]
                                    [--mask-json-key <exact>] [--mask-key-pattern <regex>] [--delete-input]

Input: a Splunk CSV export (columns incl. `_raw`, usually `_time,_raw`; multi-line events are kept intact) or a plain
log file (one event per line: WebLogic / ODL). Output: the same file shape with every personal value replaced, so all
later steps (traces, fixtures, golden oracle) run on the masked file only.

Masking rules are the same as in osb_log_traces.py (one implementation, `Masker`):
  * keyed HMAC-SHA256 with MASK_KEY: same value + same key -> same masked value, in every line, flow and future
    extract; no key -> not reversible. The key is never written anywhere; the report holds only its 8-char id.
  * JSON fields and XML elements whose name matches the personal-data rules (names incl. Arabic/English variants,
    address/remarks/notes, birth date, identity-document dates, e-mail/phone/mobile, NIN/iqama/passport/national id/
    social insurance no/IBAN/account), plus in free text: digit runs of 9+, e-mails, Saudi IBANs.
  * format kept: names -> masked_<hex>, identifiers -> digits of the same length (the same number masked identically
    whether it appears as a JSON number, a JSON string or inside a URL), dates -> shifted <=183 days, e-mails ->
    @example.invalid. UUIDs, ECIDs, FlowIds, timestamps and technical codes are left untouched.

After writing, the residue check runs on the output (Arabic script, e-mails, IBANs, unmasked personal keys). Exit 1 if
it finds anything; the report then lists file:line:check, never a value.

The report (default <output>.report.json) is what the reviewer looks at instead of raw data: events read/written,
masked value count, key id, residue result, and a KEY INVENTORY of every JSON key seen in the payloads with its count,
value type and whether it was masked. No values. Use it to decide which further keys must be masked
(--mask-json-key / --mask-key-pattern) and rerun. Stdlib only."""
import argparse
import csv
import io
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from osb_log_traces import DEFAULT_JSON_KEYS, DEFAULT_KEY_PATTERNS, DEFAULT_MASKS, Masker, find_payload, osb_message, payload_error  # noqa: E402

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))
_KEY_VAL = re.compile(r'"([A-Za-z0-9_.\-]+)"\s*:\s*("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|true|false|null|\{|\[)')


def value_type(v: str) -> str:
    if v.startswith('"'):
        return "string"
    if v in ("true", "false"):
        return "boolean"
    if v == "null":
        return "null"
    if v in ("{", "["):
        return "object" if v == "{" else "array"
    return "number"


def inventory(raw: str, inv: dict, masker: Masker) -> None:
    for key, val in _KEY_VAL.findall(raw):
        e = inv[key]
        e["count"] += 1
        e["types"][value_type(val)] += 1
        e["masked_by_rule"] = masker.is_personal(key)


def read_csv(path: Path):
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    reader = csv.DictReader(io.StringIO(text, newline=""))
    if "_raw" not in (reader.fieldnames or []):
        sys.exit(f"{path}: CSV without a _raw column (export the Splunk search with 'table _time _raw')")
    return reader.fieldnames, list(reader)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", type=Path)
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--report", type=Path)
    ap.add_argument("--mask-json-key", action="append", default=[], help="extra exact JSON key / XML element to mask")
    ap.add_argument("--mask-key-pattern", action="append", default=[], help="extra case-insensitive key pattern (full match)")
    ap.add_argument("--mask-regex", action="append", default=[], help="extra free-text regex to mask")
    ap.add_argument("--mask-key-env", default="MASK_KEY")
    ap.add_argument("--unkeyed", action="store_true", help="synthetic samples only")
    ap.add_argument("--delete-input", action="store_true", help="delete the raw input after a clean run (residue 0)")
    a = ap.parse_args()

    key = os.environ.get(a.mask_key_env, "").encode()
    if not key and not a.unkeyed:
        sys.exit(f"no masking key: export {a.mask_key_env}=<key held by the data owner> (or --unkeyed for synthetic samples only)")
    if a.out.resolve() == a.input.resolve():
        sys.exit("output must differ from input")
    masker = Masker(DEFAULT_MASKS + a.mask_regex, DEFAULT_JSON_KEYS + a.mask_json_key, key=key or None,
                    key_patterns=DEFAULT_KEY_PATTERNS + a.mask_key_pattern)
    inv = defaultdict(lambda: {"count": 0, "types": Counter(), "masked_by_rule": False})

    a.out.parent.mkdir(parents=True, exist_ok=True)
    events = 0
    states, errors = {"before": Counter(), "after": Counter()}, Counter()

    def payload_state(raw: str, masked: str) -> None:       # value-free: only states, decoder messages and key names
        states["before"][find_payload(osb_message(raw)[0])[1]] += 1
        msg = osb_message(masked)[0]
        st = find_payload(msg)[1]
        states["after"][st] += 1
        if st not in ("json", "xml", "none"):
            errors[payload_error(msg)] += 1

    if a.input.suffix.lower() == ".csv":
        fields, rows = read_csv(a.input)
        with a.out.open("w", encoding="utf-8", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=fields, quoting=csv.QUOTE_ALL)
            w.writeheader()
            for r in rows:
                raw = r.get("_raw") or ""
                inventory(raw, inv, masker)
                r["_raw"] = masker(raw)
                payload_state(raw, r["_raw"])
                for col in fields:                      # any other text column (e.g. extracted fields) is masked too
                    if col not in ("_raw", "_time") and r.get(col):
                        r[col] = masker(r[col])
                w.writerow(r)
                events += 1
    else:
        with a.input.open(encoding="utf-8", errors="replace") as src, a.out.open("w", encoding="utf-8") as dst:
            for line in src:
                inventory(line, inv, masker)
                masked = masker(line)
                payload_state(line, masked)
                dst.write(masked)
                events += 1

    residue = subprocess.run([sys.executable, str(Path(__file__).with_name("mask_residue_check.py")), str(a.out)]
                             + sum((["--json-key", k] for k in a.mask_json_key), [])
                             + sum((["--key-pattern", k] for k in a.mask_key_pattern), []),
                             capture_output=True, text=True)
    findings = [l for l in residue.stdout.splitlines() if re.match(r".+:\d+: ", l)]
    report = {
        "input": a.input.name, "output": a.out.name, "events": events, "masked_values": masker.count,
        "masking": {"keyed": bool(key), "key_id": masker.key_id, "extra_keys": a.mask_json_key,
                    "extra_patterns": a.mask_key_pattern},
        "residue_check": {"findings": len(findings), "where": [l.split(": ", 1)[0].rsplit("/", 1)[-1] + ": " + l.split(": ", 1)[1]
                                                               for l in findings][:50]},
        "payloads": {"before_masking": dict(states["before"]), "after_masking": dict(states["after"]),
                     "not_strict_json": [{"reason": k, "events": v} for k, v in errors.most_common(10)],
                     "legend": "json = valid; json-lenient = raw tabs/newlines inside strings; json-trailing = text after "
                               "the closing brace; unparsed = starts after '::' but does not parse; none = no payload"},
        "key_inventory": {k: {"count": v["count"], "types": dict(v["types"]), "masked": v["masked_by_rule"]}
                          for k, v in sorted(inv.items())},
        "review_hint": "masked=true means the key rule masks the value. Numbers with 9+ digits are masked anywhere, whatever "
                       "the key. Check keys with masked=false that can identify a person (short IDs, names, dates, "
                       "addresses, free text); add them with --mask-json-key / --mask-key-pattern and rerun.",
    }
    rp = a.report or a.out.with_name(a.out.name + ".report.json")
    rp.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    unmasked = sum(1 for v in report["key_inventory"].values() if not v["masked"])
    print(f"{events} events -> {a.out}; {masker.count} values masked (key {masker.key_id}); "
          f"residue findings {len(findings)}; {len(inv)} JSON keys seen, {unmasked} not masked by rule -> review {rp}")
    print("payloads before masking " + json.dumps(dict(states["before"])) + ", after " + json.dumps(dict(states["after"]))
          + (f"; not strict JSON: {errors.most_common(1)[0][0]}" if errors else ""))
    if findings:
        return 1
    if a.delete_input:
        a.input.unlink()
        print(f"deleted raw input {a.input}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_LOG_REPLAY_TOOLS_ANONYMIZE_LOGS_PY
mkdir -p "$(dirname "log-replay/tools/broker_setup_commands.py")"
cat > 'log-replay/tools/broker_setup_commands.py' <<'KIT_EOF_LOG_REPLAY_TOOLS_BROKER_SETUP_COMMANDS_PY'
#!/usr/bin/env python3
"""Print the Artemis CLI commands that create the mock broker's addresses and queues from replay-config.json:
the input multicast address, the named durable subscription queue with the proxy's selector as its filter, and the
anycast output queues. mock/setup_broker.sh runs them inside the broker container.

Usage: broker_setup_commands.py replay-config.json [--cli /var/lib/artemis-instance/bin/artemis]
"""
from __future__ import annotations

import argparse
import json
import shlex
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("config", type=Path)
    ap.add_argument("--cli", default="/var/lib/artemis-instance/bin/artemis")
    args = ap.parse_args()
    cfg = json.loads(args.config.read_text(encoding="utf-8"))
    auth = '--user "$ARTEMIS_USER" --password "$ARTEMIS_PASSWORD" --silent'
    seen = set()
    for flow, fc in cfg["flows"].items():
        inp = fc["input"]
        if inp["address"] not in seen:
            seen.add(inp["address"])
            print(f"{args.cli} address create --name {shlex.quote(inp['address'])} --multicast --no-anycast {auth}")
        if inp.get("subscription"):
            filt = f" --filter {shlex.quote(inp['filter'])}" if inp.get("filter") else ""
            print(f"{args.cli} queue create --name {shlex.quote(inp['subscription'])} --address {shlex.quote(inp['address'])} "
                  f"--multicast --durable --preserve-on-no-consumers{filt} {auth}")
        for out in fc["outputs"].values():
            if out["destination"] in seen:
                continue
            seen.add(out["destination"])
            print(f"{args.cli} queue create --name {shlex.quote(out['destination'])} --address {shlex.quote(out['destination'])} "
                  f"--anycast --durable --preserve-on-no-consumers --auto-create-address {auth}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_LOG_REPLAY_TOOLS_BROKER_SETUP_COMMANDS_PY
mkdir -p "$(dirname "log-replay/tools/fixtures_from_traces.py")"
cat > 'log-replay/tools/fixtures_from_traces.py' <<'KIT_EOF_LOG_REPLAY_TOOLS_FIXTURES_FROM_TRACES_PY'
#!/usr/bin/env python3
"""Step 4: pick representative traces per scenario and write test fixtures.

For each scenario, up to N traces with a payload are written as one fixture each:
  <out>/parity/<flow>/<scenario-slug>/<correlation>/input.payload   the logged request body (masked)
  <out>/parity/<flow>/<scenario-slug>/<correlation>/headers.json    JMS/HTTP headers reconstructed from the log fields
  <out>/parity/<flow>/<scenario-slug>/<correlation>/expected.json   outcome, destination, fault code, business keys
and every file is registered in <out>/golden/MANIFEST.csv with source 'osb-recording', which is what gate G7 of the
agent kit accepts. The expected OUTPUT body is not in the logs: produce it with the original XQuery (golden test,
source 'original-transform'), never with the new Camel code.

Usage: fixtures_from_traces.py traces.jsonl replay-config.json -o fixtures/ [--per-scenario 3]
"""
from __future__ import annotations

import argparse
import csv
import datetime
import hashlib
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))


def slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-").lower()[:80]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("traces", type=Path)
    ap.add_argument("config", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=Path("fixtures"))
    ap.add_argument("--per-scenario", type=int, default=3)
    ap.add_argument("--captured-by", default="osb-log-replay")
    args = ap.parse_args()

    cfg = json.loads(args.config.read_text(encoding="utf-8"))
    flows_cfg = cfg["flows"]
    by_scen = defaultdict(list)
    for line in args.traces.read_text(encoding="utf-8").splitlines():
        if line.strip():
            t = json.loads(line)
            by_scen[t["scenario"]].append(t)

    manifest_path = args.out / "golden" / "MANIFEST.csv"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    cols = ["file", "source", "flow", "captured_by", "date", "sha256", "key_id", "source_ref", "reason", "approved_by"]
    rows = []
    if manifest_path.exists():                      # rewrite, never append: re-runs replace this flow's rows
        with manifest_path.open(encoding="utf-8", newline="") as mf:
            rows = [r for r in csv.DictReader(mf)]
    cov_path = args.traces.with_name("coverage.json")
    key_id, source_ref = "", args.traces.name
    if cov_path.is_file():
        cov = json.loads(cov_path.read_text(encoding="utf-8"))
        key_id = cov.get("masking", {}).get("key_id", "")
        source_ref = f"{args.traces.name}; events {cov.get('events_read')}; signatures {len(cov.get('signatures_seen', {}) or {})}"
    written, skipped, flows_written = 0, [], set()
    today = datetime.date.today().isoformat()
    if True:
        def w_row(path, flow):
            rows.append({"file": path.relative_to(args.out).as_posix(), "source": "osb-recording", "flow": flow,
                         "captured_by": args.captured_by, "date": today,
                         "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "key_id": key_id,
                         "source_ref": source_ref, "reason": "", "approved_by": ""})
        for scen, traces in sorted(by_scen.items()):
            flow = traces[0]["flow"]
            fc = flows_cfg.get(flow)
            if not fc:
                skipped.append(f"{scen}: flow not in config")
                continue
            usable = [t for t in traces if t["has_payload"]]
            if not usable:
                skipped.append(f"{scen}: no trace with a payload (debug logging off?)")
                continue
            for t in usable[: args.per_scenario]:
                merged = {}
                for e in t["events"]:
                    for k, v in e["fields"].items():
                        merged.setdefault(k, v)
                d = args.out / "parity" / slug(flow) / slug(scen.split("|", 1)[1]) / slug(t["correlation"])
                d.mkdir(parents=True, exist_ok=True)
                headers = {k[4:]: v for k, v in merged.items() if k.startswith("hdr_")}
                headers[fc.get("correlation_header", "traceId")] = t["correlation"]
                out_cfg = fc["outputs"][t["outcome"]]
                expected = {"outcome": t["outcome"], "destination": out_cfg["destination"],
                            "destination_type": out_cfg.get("type", "anycast"), "correlation": t["correlation"],
                            "fault_code": t["fault_code"],
                            "business_keys": {k: v for k, v in merged.items() if k.startswith("body_")},
                            "expected_headers": out_cfg.get("expect_headers", []),
                            "body_oracle": "original XQuery on input.payload (golden test), not the logs"}
                files = {"input.payload": merged["body"], "headers.json": json.dumps(headers, indent=2, ensure_ascii=False),
                         "expected.json": json.dumps(expected, indent=2, ensure_ascii=False)}
                if flow not in flows_written:
                    rows = [r for r in rows if r.get("flow") != flow]
                    flows_written.add(flow)
                for name, content in files.items():
                    (d / name).write_text(content, encoding="utf-8")
                    w_row(d / name, flow)
                written += 1
    with manifest_path.open("w", newline="", encoding="utf-8") as mf:
        w = csv.DictWriter(mf, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({c: r.get(c, "") for c in cols})
    print(f"{written} fixtures written to {args.out}/parity; manifest {manifest_path} ({len(rows)} rows, key_id {key_id or 'n/a'})")
    for s in skipped:
        print("SKIPPED", s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_LOG_REPLAY_TOOLS_FIXTURES_FROM_TRACES_PY
mkdir -p "$(dirname "log-replay/tools/mask_residue_check.py")"
cat > 'log-replay/tools/mask_residue_check.py' <<'KIT_EOF_LOG_REPLAY_TOOLS_MASK_RESIDUE_CHECK_PY'
#!/usr/bin/env python3
"""Residue check after masking: scans files (traces.jsonl, fixtures, test resources) for personal data that masking
should have removed. Prints file, line and check name only, NEVER the value. Exit 1 on any finding.

    python3 tools/mask_residue_check.py work/traces work/fixtures [--allow '<regex of allowed strings>']

Checks: Arabic-script runs (names in Arabic must be masked to ASCII tokens), e-mail addresses outside
@example.invalid, Saudi IBANs, JSON personal-data keys (same key rules as the masker) whose string value is not a
masked token or a shifted date, and XML personal elements with unmasked text.
What it cannot judge: digit-only identifiers (masked values are digits of the same length) and free text under
technical keys. Those are covered by the data owner's sample review. Stdlib only."""
import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from osb_log_traces import DEFAULT_JSON_KEYS, DEFAULT_KEY_PATTERNS, IBAN_RE, personal_key_matcher  # noqa: E402

ARABIC = re.compile(r"[؀-ۿ]{2,}")
EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
IBAN = re.compile(IBAN_RE)
JSON_STR = re.compile(r'"([A-Za-z0-9_.\-]+)"\s*:\s*"((?:[^"\\]|\\.)*)"')
XML_ELEM = re.compile(r"<(?:[A-Za-z_][\w.\-]*:)?([A-Za-z_][\w.\-]*)(?:\s[^<>]*)?>([^<]+)</")
MASKED = re.compile(r"^(masked_[0-9a-f]{10}(@example\.invalid)?|\d{4}-\d{2}-\d{2}.*|\d+|)$")
SKIP_SUFFIX = {".png", ".jpg", ".jar", ".zip", ".class", ".pdf"}


def scan_line(line: str, is_personal, allow) -> list[str]:
    hits = []
    if ARABIC.search(line) and not (allow and allow.search(line)):
        hits.append("arabic-script")
    for m in EMAIL.finditer(line):
        if not m.group(0).endswith("@example.invalid"):
            hits.append("unmasked-email")
            break
    if IBAN.search(line):
        hits.append("iban")
    for key, val in JSON_STR.findall(line):
        if is_personal(key) and not MASKED.match(val.encode().decode("unicode_escape", "ignore")):
            hits.append(f"unmasked-json-key:{key}")
    for name, text in XML_ELEM.findall(line):
        if is_personal(name) and not MASKED.match(text.strip()):
            hits.append(f"unmasked-xml-element:{name}")
    return hits


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", type=Path)
    ap.add_argument("--allow", help="regex of strings that may legitimately contain Arabic script (e.g. enum labels)")
    ap.add_argument("--json-key", action="append", default=[], help="extra exact personal key")
    ap.add_argument("--key-pattern", action="append", default=[], help="extra personal key pattern")
    args = ap.parse_args()
    allow = re.compile(args.allow) if args.allow else None
    is_personal = personal_key_matcher(DEFAULT_JSON_KEYS + args.json_key, DEFAULT_KEY_PATTERNS + args.key_pattern)

    files = []
    for p in args.paths:
        files += [f for f in (p.rglob("*") if p.is_dir() else [p]) if f.is_file() and f.suffix.lower() not in SKIP_SUFFIX]
    findings, scanned = [], 0
    for f in sorted(files):
        try:
            lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError as exc:
            print(f"cannot read {f}: {exc}", file=sys.stderr)
            continue
        scanned += 1
        for i, line in enumerate(lines, 1):
            for hit in scan_line(line, is_personal, allow):
                findings.append((str(f), i, hit))
    for f, i, hit in findings:
        print(f"{f}:{i}: {hit}")
    summary = {"files_scanned": scanned, "findings": len(findings),
               "by_check": sorted({h.split(":")[0] for _, _, h in findings})}
    print(json.dumps(summary))
    print(f"{len(findings)} findings in {scanned} files")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_LOG_REPLAY_TOOLS_MASK_RESIDUE_CHECK_PY
mkdir -p "$(dirname "log-replay/tools/osb_log_signatures.py")"
cat > 'log-replay/tools/osb_log_signatures.py' <<'KIT_EOF_LOG_REPLAY_TOOLS_OSB_LOG_SIGNATURES_PY'
#!/usr/bin/env python3
"""Step 1: read the logging contract from OSB source.

Parses every Log action in an OSB export (12c .pipeline files, 11g inline routers in .proxy files) and turns its XQuery
expression into a log signature: a regex that matches the line the action writes, with one named group per variable
part, the longest literal as a search anchor, and the roles of the groups (correlation id, payload, fault, headers).

Usage: osb_log_signatures.py <osb-export-dir> -o signatures.json
Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

CORRELATION_HINT = re.compile(r"uuid|traceid|trace_id|correlation|messageid|msgid", re.I)
PIPELINE_SUFFIXES = {".pipeline", ".proxy", ".ptx"}


def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def split_top_level(args: str) -> list[str]:
    """Split the argument list of fn:concat on commas that are not inside quotes, parentheses or brackets."""
    parts, depth, buf, quote = [], 0, [], None
    i = 0
    while i < len(args):
        ch = args[i]
        if quote:
            buf.append(ch)
            if ch == quote:
                if i + 1 < len(args) and args[i + 1] == quote:   # XQuery escapes a quote by doubling it
                    buf.append(args[i + 1]); i += 1
                else:
                    quote = None
        elif ch in "\"'":
            quote = ch; buf.append(ch)
        elif ch in "([{":
            depth += 1; buf.append(ch)
        elif ch in ")]}":
            depth -= 1; buf.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(buf).strip()); buf = []
        else:
            buf.append(ch)
        i += 1
    if buf:
        parts.append("".join(buf).strip())
    return parts


def concat_args(expr: str) -> list[str]:
    e = expr.strip()
    m = re.match(r"^(?:fn:)?concat\s*\((.*)\)\s*$", e, re.S)
    return split_top_level(m.group(1)) if m else [e]


def is_literal(arg: str) -> bool:
    return len(arg) >= 2 and arg[0] == arg[-1] and arg[0] in "\"'"


def literal_value(arg: str) -> str:
    q = arg[0]
    return arg[1:-1].replace(q + q, q)


def group_name(arg: str, used: dict) -> str:
    a = arg.strip()
    m = re.search(r"user-header\[@name\s*=\s*[\"']([^\"']+)[\"']\]", a)
    if m:
        name = "hdr_" + m.group(1)
    elif "$fault" in a:
        name = "fault"
    elif "$body" in a:
        m = re.findall(r"[/:]([A-Za-z_][\w.-]*)\s*(?:/text\(\))?\s*\)?\s*$", a.replace("*:", ":"))
        name = "body_" + m[-1] if m and m[-1] not in ("body", "text") else "body"
    else:
        m = re.findall(r"\$([A-Za-z_][\w.-]*)", a)
        name = m[-1] if m else "expr"
    name = re.sub(r"[^A-Za-z0-9_]", "_", name)
    used[name] = used.get(name, 0) + 1
    return name if used[name] == 1 else f"{name}_{used[name]}"


def to_regex(literal: str) -> str:
    return r"\s+".join(re.escape(tok) for tok in literal.split()) if literal.strip() else re.escape(literal)


def build_signature(expr: str) -> dict:
    args = concat_args(expr)
    regex, groups, literals, warnings, used = [], [], [], [], {}
    prev_group = False
    for i, arg in enumerate(args):
        if is_literal(arg):
            lit = literal_value(arg)
            literals.append(lit)
            body = to_regex(lit.strip())
            lead = r"\s*" if lit[:1].isspace() else ""
            trail = r"\s*" if lit[-1:].isspace() else ""
            regex.append(lead + body + trail if lit.strip() else r"\s*")
            prev_group = False
        else:
            if prev_group:
                warnings.append(f"two variable parts without a literal between them (arg {i}); split is ambiguous")
            name = group_name(arg, used)
            last = i == len(args) - 1
            regex.append(f"(?P<{name}>.*)" if last else f"(?P<{name}>.*?)")
            groups.append({"name": name, "expr": arg})
            prev_group = True
    anchor = max(literals, key=lambda s: len(s.strip()), default="").strip()
    if len(anchor) < 12:
        warnings.append("no literal of 12+ characters: weak Splunk anchor, expect false matches")
    names = [g["name"] for g in groups]
    roles = {
        "correlation": [n for n in names if CORRELATION_HINT.search(n)],
        "payload": [n for n in names if n == "body"],
        "fault": [n for n in names if n == "fault"],
        "headers": [n for n in names if n.startswith("hdr_")],
        "business_keys": [n for n in names if n.startswith("body_")],
    }
    if not roles["correlation"]:
        warnings.append("no correlation field: lines cannot be grouped into traces")
    return {"regex": "".join(regex), "anchor": anchor, "groups": groups, "roles": roles, "warnings": warnings}


def parse_file(path: Path, root: Path) -> list[dict]:
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        return [{"file": str(path.relative_to(root)), "error": f"unparseable XML: {exc}"}]
    parent = {c: p for p in tree.iter() for c in p}
    rel = path.relative_to(root)
    project = rel.parts[0] if len(rel.parts) > 1 else rel.stem
    flow = f"{project}/{path.stem}"
    out, n = [], 0
    for el in tree.iter():
        if local(el.tag) != "log":
            continue
        n += 1
        expr = next((t.text for t in el.iter() if local(t.tag) == "xqueryText" and t.text), None)
        level = next((t.text.strip() for t in el.iter() if local(t.tag) == "logLevel" and t.text), "")
        annotation = next((t.text.strip() for t in el.iter() if local(t.tag) == "message" and t.text), "")
        stage, ptype, node = None, None, el
        while node in parent:
            node = parent[node]
            ln = local(node.tag)
            if ln == "stage" and stage is None:
                stage = node.get("name")
            if ln == "pipeline" and ptype is None:
                ptype = node.get("type")
            if ln == "route-node" and ptype is None:
                ptype, stage = "route", stage or node.get("name")
        sig = {"id": f"{flow}#{n}", "flow": flow, "file": str(rel), "pipeline_type": ptype or "unknown", "stage": stage,
               "level": level.lower(), "annotation": annotation, "expression": (expr or "").strip()}
        if expr:
            sig.update(build_signature(expr))
        else:
            sig.update({"regex": None, "warnings": ["log action without an XQuery expression"]})
        out.append(sig)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("export", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=Path("signatures.json"))
    args = ap.parse_args()
    if not args.export.is_dir():
        print(f"not a directory: {args.export}", file=sys.stderr)
        return 2
    sigs = []
    for p in sorted(args.export.rglob("*")):
        if p.suffix in PIPELINE_SUFFIXES and p.is_file():
            sigs.extend(parse_file(p, args.export))
    args.out.write_text(json.dumps({"source": str(args.export), "signatures": sigs}, indent=2), encoding="utf-8")
    levels = {}
    for s in sigs:
        levels[s.get("level", "?")] = levels.get(s.get("level", "?"), 0) + 1
    warn = sum(1 for s in sigs if s.get("warnings"))
    print(f"{len(sigs)} log signatures from {len({s.get('flow') for s in sigs})} flows; levels {levels}; {warn} with warnings -> {args.out}")
    if levels.get("debug"):
        print("NOTE: debug-level log actions are usually disabled in PROD; their lines (often the ones with the payload) may be missing in Splunk.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_LOG_REPLAY_TOOLS_OSB_LOG_SIGNATURES_PY
mkdir -p "$(dirname "log-replay/tools/osb_log_traces.py")"
cat > 'log-replay/tools/osb_log_traces.py' <<'KIT_EOF_LOG_REPLAY_TOOLS_OSB_LOG_TRACES_PY'
#!/usr/bin/env python3
"""Step 3: turn exported OSB log events into traces and scenarios.

Input: events exported from Splunk (JSON lines from the REST export, or a CSV export with a _raw column) or a raw
server log in either format OSB writes: the classic WebLogic server log (events start with '####<') or the ODL
diagnostic log of OSB 12c ('[2026-10-08T11:59:16.339+03:00] [osb_server1] [NOTIFICATION] ... [ecid: ...]
[FlowId: ...]  [stage, pipeline, REQUEST] text'). Each event's OSB text is taken out of its envelope,
matched against the log signatures from step 1, masked, and grouped by correlation id into a trace. Traces are
classified into scenarios: flow x outcome (success / error) x branch values (header fields by default).

Usage:
  osb_log_traces.py signatures.json events.jsonl|events.csv|server.log -o out/
                    [--format auto|splunk-json|csv|weblogic|odl|lines] [--dims hdr_resource,hdr_eventType]
                    [--mask-regex PATTERN ...] [--mask-json-key KEY ...] [--no-default-masks] [--no-default-json-keys]
Personal data is masked in every extracted field: long numbers, e-mail addresses, and the values of JSON fields with
personal names, birth dates, identity and contact data (defaults below; add client-specific keys with --mask-json-key).
Writes out/traces.jsonl, out/scenarios.json, out/coverage.json. Stdlib only.
"""
from __future__ import annotations

import argparse
import csv
import datetime as _dt
import hashlib
import hmac
import io
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

WL_EVENT_START = re.compile(r"^####<", re.M)
WL_MESSAGE = re.compile(r"<(BEA-\d+)>\s*<(.*)>\s*$", re.S)
WL_TIME = re.compile(r"^####<([^>]+)>")
WL_EPOCH = re.compile(r"<(\d{13})>")
LOCATION_PREFIX = re.compile(r"^\s*\[[^\]]*\]\s*", re.S)        # [stage, pipeline, ..., REQUEST] written by OSB before the text
ODL_EVENT_START = re.compile(r"^\[\d{4}-\d{2}-\d{2}T[^\]]*\]", re.M)
ODL_TIME = re.compile(r"^\[(\d{4}-\d{2}-\d{2}T[^\]]+)\]")
ODL_LEVEL = re.compile(r"^\[[^\]]*\]\s*\[[^\]]*\]\s*\[([A-Z_]+)(?::\d+)?\]")
ODL_ECID = re.compile(r"\[ecid:\s*([^\],]+)")
ODL_FLOWID = re.compile(r"\[FlowId:\s*([^\]]+)\]")
ODL_LOCATION = re.compile(r"\[[^\[\]]*,\s*(?:REQUEST|RESPONSE|ERROR_HANDLER|ROUTING|ROUTE|NONE)\]\s?")
DEFAULT_JSON_KEYS = ["firstName", "secondName", "thirdName", "middleName", "lastName", "surName", "familyName", "fullName",
                     "nameEnglish", "nameArabic", "englishName", "arabicName", "birthDate", "dateOfBirth", "dob",
                     "email", "mobile", "mobileNo", "phone", "phoneNo", "address", "passportNo", "iqamaNo",
                     "nationalId", "nin", "newNin", "oldNin", "socialInsuranceNo", "iban", "accountNo"]
DEFAULT_MASKS = [r"(?<![\w-])\d{9,}(?![\w-])",                   # national / account / phone numbers (not digits inside UUIDs or codes)
                 r"[\w.+-]+@[\w-]+\.[\w.-]+",                    # e-mail addresses
                 r"(?<![A-Z0-9])SA\d{22}(?![0-9])"]                # Saudi IBAN


_LENIENT = json.JSONDecoder(strict=False)       # OSB often logs raw tabs/newlines inside JSON strings


def find_payload(msg: str) -> tuple[int | None, str]:
    """Where the logged payload starts in an OSB message, and its state, without returning any value:
    'json' (strict), 'json-lenient' (control characters in strings), 'json-trailing' (text after the closing brace),
    'xml', 'unparsed' (starts after '::' but does not parse), or 'none'."""
    for m in re.finditer(r"[{<]", msg):
        rest = msg[m.start():].rstrip()
        if rest.startswith("{"):
            try:
                json.loads(rest)
                return m.start(), "json"
            except ValueError:
                pass
            try:
                _, end = _LENIENT.raw_decode(rest)
                return m.start(), "json-lenient" if end == len(rest) else "json-trailing"
            except ValueError:
                continue
        elif re.match(r"<[A-Za-z_][\w:.-]*[\s>/]", rest) and rest.endswith(">"):
            return m.start(), "xml"
    m = re.search(r"::\s*([{<])", msg)                  # OSB Log convention '... ::$body': take it even if broken
    return (m.start(1), "unparsed") if m else (None, "none")


def payload_error(msg: str) -> str:
    """Why a payload does not parse: decoder message, position and the nearest JSON key before it (no values)."""
    start, _ = find_payload(msg)
    if start is None:
        return "no payload"
    rest = msg[start:].rstrip()
    try:
        _LENIENT.raw_decode(rest)
        return "ok"
    except ValueError as e:
        pos = getattr(e, "pos", 0) or 0
        keys = re.findall(r'"([A-Za-z0-9_.\-]+)"\s*:', rest[:pos])
        return f"{getattr(e, 'msg', str(e))} at char {pos} of {len(rest)} (after key '{keys[-1] if keys else '-'}')"


def dim_value(fields: dict, dim: str) -> str:
    """A scenario dimension: a captured field, or body:<a.b.c> = a field of the JSON payload ('?' when absent)."""
    if not dim.startswith("body:"):
        return fields.get(dim, "?")
    try:
        node = _LENIENT.raw_decode((fields.get("body") or "").strip())[0]
    except ValueError:
        return "?"
    for part in dim[5:].split("."):
        node = node.get(part) if isinstance(node, dict) else None
    return "?" if node is None or isinstance(node, (dict, list)) else str(node)


csv.field_size_limit(min(sys.maxsize, 2**31 - 1))   # large payloads: Python's default CSV field limit is 128 KB


# ------------------------------------------------------------------ loading
def load_events(path: Path, fmt: str) -> list[dict]:
    text = path.read_text(encoding="utf-8", errors="replace")
    if fmt == "auto":
        if path.suffix == ".csv":
            fmt = "csv"
        elif text.lstrip().startswith("{"):
            fmt = "splunk-json"
        elif WL_EVENT_START.search(text):
            fmt = "weblogic"
        elif ODL_EVENT_START.search(text):
            fmt = "odl"
        else:
            fmt = "lines"
    events = []
    if fmt == "splunk-json":
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            res = obj.get("result", obj)
            if "_raw" in res:
                events.append({"raw": res["_raw"], "time": res.get("_time")})
    elif fmt == "csv":
        for row in csv.DictReader(io.StringIO(text, newline="")):
            if row.get("_raw"):
                events.append({"raw": row["_raw"], "time": row.get("_time")})
    elif fmt in ("weblogic", "odl"):
        start = WL_EVENT_START if fmt == "weblogic" else ODL_EVENT_START
        starts = [m.start() for m in start.finditer(text)] + [len(text)]
        for a, b in zip(starts, starts[1:]):
            events.append({"raw": text[a:b].rstrip("\n"), "time": None})
    elif fmt == "lines":
        events = [{"raw": line, "time": None} for line in text.splitlines() if line.strip()]
    else:
        raise ValueError(fmt)
    for e in events:
        epoch = WL_EPOCH.search(e["raw"]) if e["raw"].startswith("####<") else None
        if not e["time"]:
            m = WL_TIME.match(e["raw"]) or ODL_TIME.match(e["raw"])
            e["time"] = m.group(1) if m else None
        e["epoch_ms"] = int(epoch.group(1)) if epoch else parse_epoch_ms(e["time"])
    return events


def parse_epoch_ms(value) -> int | None:
    """ISO-8601 timestamps (ODL header, Splunk _time) -> epoch milliseconds, for ordering lines within a trace."""
    if not value:
        return None
    try:
        return int(datetime.fromisoformat(str(value).strip().replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return None


def osb_message(raw: str) -> tuple[str, dict]:
    """Return the OSB text without its envelope (WebLogic or ODL) and without the location prefix, plus metadata:
    format, BEA message id (WebLogic), level, ecid and FlowId (ODL). The ecid identifies one request inside OSB."""
    m = WL_MESSAGE.search(raw)
    if m and raw.lstrip().startswith("####<"):
        return LOCATION_PREFIX.sub("", m.group(2), count=1), {"format": "weblogic", "bea": m.group(1)}
    if ODL_TIME.match(raw):
        meta = {"format": "odl"}
        for key, rx in (("level", ODL_LEVEL), ("ecid", ODL_ECID), ("flow_id", ODL_FLOWID)):
            mm = rx.search(raw)
            if mm:
                meta[key] = mm.group(1).strip()
        loc = ODL_LOCATION.search(raw)
        return (raw[loc.end():] if loc else raw), meta
    return raw, {"format": "unknown"}


# ------------------------------------------------------------------ masking
# Personal-data keys matched case-insensitively on the JSON key / XML element local name. Deliberately NOT matched:
# plain "name" (event type), "description", "resource": technical fields the scenarios depend on.
DEFAULT_KEY_PATTERNS = [
    r"(?:first|second|third|middle|last|sur|family|full|father|grand|grandfather|mother|given|maiden|display|person|"
    r"contributor|employee|beneficiary|employer|customer|applicant|holder)name(?:arb|arabic|eng|english|ar|en)?",
    r".*name(?:arb|arabic|eng|english)",
    r".*(?:address|street|district|remark|note|comment)s?(?:line\d*|arb|eng|ar|en)?",
    r".*(?:birthdate|dateofbirth|dob)",
    r".*(?:email|mail|mobile|phone|msisdn)(?:no|number|address)?",
    r"(?:new|old|unified)?(?:nin|iqama|iqamano|passport|passportno|nationalid|socialinsuranceno|iban|accountno|bankaccount)",
    r".*(?:dateofissue|issuedate|issuingdate|expirydate|dateofexpiry|idexpiry\w*)",   # identity-document dates
]
IBAN_RE = r"(?<![A-Z0-9])SA\d{22}(?![0-9])"
_DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})(.*)$", re.S)
_JSON_PAIR = re.compile(r'("([A-Za-z0-9_.\-]+)"\s*:\s*)("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|\{[^{}]*\})')
_XML_ELEM = re.compile(r"<(?:[A-Za-z_][\w.\-]*:)?([A-Za-z_][\w.\-]*)(\s[^<>]*)?>([^<]+)</")


def personal_key_matcher(exact_keys: list[str] | None, patterns: list[str] | None):
    """Returns key -> bool. Exact keys are case-sensitive extras; patterns are full-match, case-insensitive."""
    exact = set(exact_keys or [])
    pats = [re.compile(p, re.I) for p in (patterns or [])]

    def is_personal(key: str) -> bool:
        return key in exact or any(p.fullmatch(key) for p in pats)
    return is_personal


class Masker:
    """Deterministic, KEYED masking (HMAC-SHA256 with a key the client holds): the same input always gives the same
    output, so masked keys still join across lines, flows and extracts made with the same key; without the key the
    values cannot be reversed by brute force. Format-preserving so the masked payload still parses in the code under
    test: strings -> masked_<10 hex>, digit identifiers -> digits of the same length, dates -> shifted by a keyed
    offset of at most 183 days (format and age band kept), e-mails -> masked_<hex>@example.invalid.
    Applies to JSON fields (key match, nested objects, arrays of pairs), XML elements (local-name match) and free
    text (digit runs of 9+, e-mails, Saudi IBANs)."""

    def __init__(self, patterns: list[str], json_keys: list[str] | None = None, key: bytes | None = None,
                 key_patterns: list[str] | None = None):
        self.patterns = [re.compile(p) for p in patterns]
        self.count = 0
        self.key = key
        self.is_personal = personal_key_matcher(json_keys, DEFAULT_KEY_PATTERNS if key_patterns is None else key_patterns)

    @property
    def key_id(self) -> str:
        return hashlib.sha256(self.key).hexdigest()[:8] if self.key else "unkeyed"

    def _h(self, s: str) -> str:
        return hmac.new(self.key, s.encode(), hashlib.sha256).hexdigest() if self.key else hashlib.sha256(s.encode()).hexdigest()

    def _digits(self, s: str) -> str:
        h = self._h(s)
        out = "".join(str(int(c, 16) % 10) for c in h)[: len(s)]
        if out[:1] == "0" and s[:1] != "0":          # never introduce a leading zero: 0123 is not a valid JSON number
            out = str(1 + int(h[-1], 16) % 9) + out[1:]
        return out

    def _date(self, m: re.Match) -> str:
        y, mo, d, rest = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
        off = int(self._h(m.group(0)[:10])[:8], 16) % 366 - 183 or 1          # never 0: the date always changes
        if y >= 1700:                                                          # Gregorian
            try:
                nd = _dt.date(y, mo, d) + _dt.timedelta(days=off)
                return f"{nd.year:04d}-{nd.month:02d}-{nd.day:02d}{rest}"
            except ValueError:
                return f"{y:04d}-{mo:02d}-01{rest}"
        n = (mo - 1) * 30 + (d - 1) + off                                       # Hijri-like: 12 x 30 arithmetic
        y += n // 360
        n %= 360
        return f"{y:04d}-{n // 30 + 1:02d}-{n % 30 + 1:02d}{rest}"

    def _token(self, s: str) -> str:
        self.count += 1
        if _DATE_RE.match(s):
            return _DATE_RE.sub(self._date, s)
        if s.isdigit():
            return self._digits(s)
        if "@" in s:
            return "masked_" + self._h(s)[:10] + "@example.invalid"
        return "masked_" + self._h(s)[:10] if s else s

    def _json_pair(self, m: re.Match, in_personal: bool = False) -> str:
        head, key, val = m.group(1), m.group(2), m.group(3)
        personal = in_personal or self.is_personal(key)
        if val.startswith("{"):                                                # nested object: keep scanning inside
            return head + "{" + self._json(val[1:-1], personal) + "}"
        if val.startswith('"'):
            text = val[1:-1]
            if self.is_personal(key) or (personal and _DATE_RE.match(text)):   # inside birthDate {gregorian, hijiri}
                return head + '"' + self._token(text) + '"'
            return m.group(0)
        if self.is_personal(key) and val.isdigit():
            return head + self._token(val)
        return m.group(0)

    def _json(self, value: str, in_personal: bool = False) -> str:
        return _JSON_PAIR.sub(lambda m: self._json_pair(m, in_personal), value)

    def _xml(self, value: str) -> str:
        def elem(m: re.Match) -> str:
            if not self.is_personal(m.group(1)):
                return m.group(0)
            text = m.group(3)
            return m.group(0)[: -len(text) - 2] + self._token(text.strip()) + "</"
        return _XML_ELEM.sub(elem, value) if "<" in value else value

    def _sub(self, m: re.Match) -> str:
        self.count += 1
        s = m.group(0)
        if s.isdigit():                                           # same length, digits only, same input -> same output
            return self._digits(s)
        if "@" in s:
            return "masked_" + self._h(s)[:10] + "@example.invalid"
        return "masked_" + self._h(s)[:10]

    def __call__(self, value: str) -> str:
        value = self._xml(self._json(value))
        for p in self.patterns:
            value = p.sub(self._sub, value)
        return value


# ------------------------------------------------------------------ matching
def compile_signatures(doc: dict) -> list[dict]:
    sigs = []
    for s in doc["signatures"]:
        if not s.get("regex"):
            continue
        s = dict(s)
        s["_re"] = re.compile(s["regex"], re.S)
        sigs.append(s)
    return sigs


def match(sigs: list[dict], message: str) -> tuple[dict, dict] | None:
    best = None
    for s in sigs:
        if s["anchor"] and s["anchor"].split()[0] not in message:
            continue
        m = s["_re"].fullmatch(message.strip()) or s["_re"].search(message)
        if m:
            literal_len = len(s["regex"]) - sum(len(g["name"]) for g in s["groups"])
            if best is None or literal_len > best[2]:            # the most specific signature wins
                best = (s, {k: (v or "").strip() for k, v in m.groupdict().items()}, literal_len)
    return (best[0], best[1]) if best else None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("signatures", type=Path)
    ap.add_argument("events", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=Path("traces-out"))
    ap.add_argument("--format", default="auto", choices=["auto", "splunk-json", "csv", "weblogic", "odl", "lines"])
    ap.add_argument("--dims", default="", help="comma-separated fields that split scenarios (default: all hdr_* fields); "
                    "body:<json.path> takes a field of the JSON payload, e.g. body:data.businessTransaction")
    ap.add_argument("--mask-regex", action="append", default=[])
    ap.add_argument("--no-default-masks", action="store_true")
    ap.add_argument("--mask-json-key", action="append", default=[], help="extra JSON field to mask, e.g. establishmentNameArb")
    ap.add_argument("--no-default-json-keys", action="store_true")
    ap.add_argument("--mask-key-pattern", action="append", default=[], help="extra case-insensitive key pattern (full match)")
    ap.add_argument("--mask-key-env", default="MASK_KEY", help="environment variable holding the masking key (default MASK_KEY)")
    ap.add_argument("--unkeyed", action="store_true", help="development samples only: SHA-256 without a key (reversible for small ID spaces)")
    ap.add_argument("--delete-input", action="store_true", help="delete the raw events file after a successful run")
    ap.add_argument("--already-masked", action="store_true",
                    help="input was anonymised by tools/anonymize_logs.py: no second masking (its residue check must be clean)")
    args = ap.parse_args()
    key = os.environ.get(args.mask_key_env, "").encode()
    if args.already_masked:
        rep = args.events.with_name(args.events.name + ".report.json")
        if not rep.is_file() or json.loads(rep.read_text(encoding="utf-8")).get("residue_check", {}).get("findings") != 0:
            sys.exit(f"--already-masked needs a clean anonymisation report next to the input ({rep.name}); run tools/anonymize_logs.py")
    elif not key and not args.unkeyed:
        sys.exit(f"no masking key: export {args.mask_key_env}=<key held by the data owner> (or --unkeyed for synthetic samples only)")

    sigs = compile_signatures(json.loads(args.signatures.read_text(encoding="utf-8")))
    masker = Masker(([] if args.no_default_masks else DEFAULT_MASKS) + args.mask_regex,
                    ([] if args.no_default_json_keys else DEFAULT_JSON_KEYS) + args.mask_json_key,
                    key=key or None, key_patterns=DEFAULT_KEY_PATTERNS + args.mask_key_pattern)
    events = load_events(args.events, args.format)
    traces, orphans, unmatched, by_ecid = defaultdict(list), 0, 0, 0
    seen, formats = Counter(), Counter()
    for e in events:
        msg, meta = osb_message(e["raw"])
        formats[meta["format"]] += 1
        hit = match(sigs, msg)
        if not hit:
            unmatched += 1
            continue
        s, fields = hit
        fields = fields if args.already_masked else {k: masker(v) for k, v in fields.items()}
        seen[s["id"]] += 1
        corr = next((fields[c] for c in s["roles"]["correlation"] if fields.get(c)), None)
        if not corr and meta.get("ecid"):                      # no id in the log text: the ODL ecid ties one OSB request
            corr, by_ecid = "ecid:" + meta["ecid"], by_ecid + 1
        rec = {"time": e["time"], "epoch_ms": e["epoch_ms"], "signature": s["id"], "flow": s["flow"],
               "pipeline_type": s["pipeline_type"], "level": s["level"], "log": meta, "fields": fields}
        if not corr:
            orphans += 1
            continue
        traces[(s["flow"], corr)].append(rec)

    args.out.mkdir(parents=True, exist_ok=True)
    dims_arg = [d for d in args.dims.split(",") if d]
    scen = defaultdict(lambda: {"count": 0, "examples": [], "with_payload": 0})
    with (args.out / "traces.jsonl").open("w", encoding="utf-8") as fh:
        for (flow, corr), evs in sorted(traces.items()):
            evs.sort(key=lambda r: (r["epoch_ms"] or 0))
            merged = {}
            for r in evs:
                for k, v in r["fields"].items():
                    merged.setdefault(k, v)
            outcome = "error" if any(r["pipeline_type"] == "error" for r in evs) else "success"
            dims = dims_arg or sorted(k for k in merged if k.startswith("hdr_"))
            branch = {d.split(".")[-1] if d.startswith("body:") else d: dim_value(merged, d) for d in dims}
            fault_code = None
            if merged.get("fault"):
                m = re.search(r"<(?:\w+:)?errorCode>([^<]+)<", merged["fault"])
                fault_code = m.group(1) if m else "unparsed"
            key = "|".join([flow, outcome] + [f"{k}={v}" for k, v in branch.items()] + ([f"errorCode={fault_code}"] if fault_code else []))
            has_payload = bool(merged.get("body"))
            trace = {"flow": flow, "correlation": corr, "outcome": outcome, "branch": branch, "fault_code": fault_code,
                     "scenario": key, "has_payload": has_payload, "events": evs}
            fh.write(json.dumps(trace, ensure_ascii=False) + "\n")
            sc = scen[key]
            sc["count"] += 1
            sc["with_payload"] += int(has_payload)
            if len(sc["examples"]) < 5:
                sc["examples"].append(corr)

    total = sum(v["count"] for v in scen.values()) or 1
    scenarios = sorted(({"scenario": k, **v, "share": round(v["count"] / total * 100, 1)} for k, v in scen.items()),
                       key=lambda x: -x["count"])
    (args.out / "scenarios.json").write_text(json.dumps(scenarios, indent=2, ensure_ascii=False), encoding="utf-8")
    all_ids = [s["id"] for s in sigs]
    coverage = {"events_read": len(events), "formats": dict(formats), "events_correlated_by_ecid": by_ecid,
                "events_matched": sum(seen.values()), "events_unmatched": unmatched,
                "events_without_correlation": orphans, "traces": len(traces), "masked_values": masker.count,
                "masking": ({"keyed": True, "key_id": json.loads(args.events.with_name(args.events.name + ".report.json").read_text(encoding="utf-8"))["masking"]["key_id"],
                             "already_masked_by": "anonymize_logs.py"} if args.already_masked else
                            {"keyed": bool(key), "key_id": masker.key_id, "key_env": args.mask_key_env}),
                "signatures_seen": dict(seen), "signatures_never_seen": [i for i in all_ids if i not in seen],
                "traces_without_payload": sum(1 for (f, c), evs in traces.items()
                                              if not any(r["fields"].get("body") for r in evs))}
    (args.out / "coverage.json").write_text(json.dumps(coverage, indent=2), encoding="utf-8")
    if args.delete_input:
        args.events.unlink()
        print(f"deleted raw input {args.events}")
    print(f"{coverage['events_read']} events, {coverage['events_matched']} matched, {coverage['traces']} traces, "
          f"{len(scenarios)} scenarios, {coverage['traces_without_payload']} traces without payload, "
          f"{len(coverage['signatures_never_seen'])} signatures never seen -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_LOG_REPLAY_TOOLS_OSB_LOG_TRACES_PY
mkdir -p "$(dirname "log-replay/tools/replay_runner.py")"
cat > 'log-replay/tools/replay_runner.py' <<'KIT_EOF_LOG_REPLAY_TOOLS_REPLAY_RUNNER_PY'
#!/usr/bin/env python3
"""Step 5: replay recorded OSB traffic against the Camel flow under test, through the mock architecture.

For every fixture written by fixtures_from_traces.py: publish input.payload with headers.json to the flow's input
address (so the broker-side subscription filter is exercised too), wait for the message that carries the same
correlation id on one of the flow's output destinations, and check:
  - it arrived on the destination of the expected outcome (success queue or error queue);
  - the headers listed in expected.json are present (error path: errorCode, errorMessage, traceId, ...);
  - if expected-output.xml exists next to the fixture (produced by the ORIGINAL XQuery, golden test), the body equals it
    after XML canonicalisation.
Negative cases from replay-config.json (messages the subscription filter must drop) expect NO output within the timeout.
They come from the proxy configuration, not from the logs: OSB never logs a message its selector rejected.

Writes a JSON report and a JUnit XML file (for Jenkins). Broker access is STOMP through stomp.py (pip install stomp.py);
the Broker class is the only network code, so the logic is unit-tested with a fake broker.

Usage: replay_runner.py replay-config.json fixtures/ [-o report/] [--flow <flow>] [--no-negative]
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import re
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape


def slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-").lower()[:80]


class StompBroker:
    """Artemis via STOMP. destination-type tells Artemis whether a name is an anycast queue or a multicast address."""

    def __init__(self, host: str, port: int, user: str, password: str):
        import stomp  # imported here so the rest of the module works without it
        self._inbox: queue.Queue = queue.Queue()
        outer = self

        class _Listener(stomp.ConnectionListener):
            def on_message(self, frame):
                outer._inbox.put((frame.headers.get("destination", ""), dict(frame.headers), frame.body))

        self.conn = stomp.Connection([(host, port)])
        self.conn.set_listener("replay", _Listener())
        self.conn.connect(user, password, wait=True)
        self._sub = 0

    def subscribe(self, destination: str, dtype: str) -> None:
        self._sub += 1
        self.conn.subscribe(destination=destination, id=str(self._sub), ack="auto",
                            headers={"destination-type": dtype.upper(), "subscription-type": dtype.upper()})

    def send(self, destination: str, dtype: str, body: str, headers: dict) -> None:
        self.conn.send(destination=destination, body=body,
                       headers={**headers, "destination-type": dtype.upper(), "persistent": "true"})

    def receive(self, timeout: float):
        try:
            return self._inbox.get(timeout=timeout)
        except queue.Empty:
            return None

    def close(self) -> None:
        self.conn.disconnect()


def canonical(xml_text: str) -> str:
    return ET.canonicalize(xml_text.strip(), strip_text=True)


def find_fixtures(root: Path, flow: str) -> list[Path]:
    base = root / "parity" / slug(flow)
    return sorted(p.parent for p in base.rglob("input.payload")) if base.is_dir() else []


def wait_for(broker, corr: str, corr_header: str, timeout: float, seen: list) -> tuple | None:
    """Return the first message carrying the correlation id (header or body); keep others for later fixtures."""
    for i, msg in enumerate(seen):
        if msg[1].get(corr_header) == corr or corr in (msg[2] or ""):
            return seen.pop(i)
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = broker.receive(max(0.1, deadline - time.time()))
        if msg is None:
            break
        if msg[1].get(corr_header) == corr or corr in (msg[2] or ""):
            return msg
        seen.append(msg)
    return None


def run_flow(broker, flow: str, fc: dict, fixtures: list[Path], negative: bool) -> list[dict]:
    corr_header = fc.get("correlation_header", "traceId")
    inp = fc["input"]
    timeout = float(fc.get("timeout_s", 15))
    dest_by_name = {o["destination"]: outcome for outcome, o in fc["outputs"].items()}
    for o in fc["outputs"].values():
        broker.subscribe(o["destination"], o.get("type", "anycast"))
    results, backlog = [], []
    for fx in fixtures:
        exp = json.loads((fx / "expected.json").read_text(encoding="utf-8"))
        headers = json.loads((fx / "headers.json").read_text(encoding="utf-8"))
        body = (fx / "input.payload").read_text(encoding="utf-8")
        corr = headers.get(corr_header) or exp["correlation"]
        t0 = time.time()
        broker.send(inp["address"], inp.get("type", "multicast"), body, headers)
        msg = wait_for(broker, corr, corr_header, timeout, backlog)
        r = {"flow": flow, "case": f"{fx.parent.name}/{fx.name}", "expected_outcome": exp["outcome"], "problems": []}
        if msg is None:
            r["problems"].append(f"no output within {timeout:.0f}s")
        else:
            dest = msg[0].split("::")[0].split("/")[-1]
            got = dest_by_name.get(dest, f"unexpected destination {dest}")
            r["actual_outcome"] = got
            if got != exp["outcome"]:
                r["problems"].append(f"outcome {got}, expected {exp['outcome']}")
            missing = [h for h in exp.get("expected_headers", []) if h not in msg[1]]
            if missing:
                r["problems"].append("missing headers: " + ", ".join(missing))
            golden = fx / "expected-output.xml"
            if golden.exists() and got == "success":
                try:
                    if canonical(msg[2]) != canonical(golden.read_text(encoding="utf-8")):
                        r["problems"].append("body differs from expected-output.xml (original transform)")
                except ET.ParseError as exc:
                    r["problems"].append(f"body is not XML: {exc}")
        r["seconds"] = round(time.time() - t0, 2)
        r["status"] = "PASS" if not r["problems"] else "FAIL"
        results.append(r)
    if negative:
        for case in fc.get("negative_cases", []):
            corr = f"negative-{uuid.uuid4()}"
            headers = {**case["headers"], corr_header: corr}
            broker.send(inp["address"], inp.get("type", "multicast"), "{}", headers)
            msg = wait_for(broker, corr, corr_header, min(timeout, 5.0), backlog)
            results.append({"flow": flow, "case": "negative: " + case["name"], "expected_outcome": "dropped by filter",
                            "problems": [] if msg is None else [f"message was delivered to {msg[0]}"],
                            "status": "PASS" if msg is None else "FAIL"})
    return results


def junit(results: list[dict]) -> str:
    fails = sum(1 for r in results if r["status"] == "FAIL")
    cases = []
    for r in results:
        name = escape(r["case"], {'"': "&quot;"})
        inner = "" if r["status"] == "PASS" else f'<failure message="{escape("; ".join(r["problems"]), {chr(34): "&quot;"})}"/>'
        cases.append(f'  <testcase classname="{escape(r["flow"])}" name="{name}" time="{r.get("seconds", 0)}">{inner}</testcase>')
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="osb-log-replay" tests="{len(results)}" failures="{fails}">\n'
            + "\n".join(cases) + "\n</testsuite>\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("config", type=Path)
    ap.add_argument("fixtures", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=Path("replay-report"))
    ap.add_argument("--flow")
    ap.add_argument("--no-negative", action="store_true")
    args = ap.parse_args()
    cfg = json.loads(args.config.read_text(encoding="utf-8"))
    b = cfg["broker"]
    broker = StompBroker(os.environ.get("BROKER_HOST", b["host"]), int(os.environ.get("BROKER_STOMP_PORT", b["stomp_port"])),
                         b["user"], os.environ.get(b.get("password_env", "ARTEMIS_PASSWORD"), ""))
    results = []
    try:
        for flow, fc in cfg["flows"].items():
            if args.flow and flow != args.flow:
                continue
            fx = find_fixtures(args.fixtures, flow)
            print(f"{flow}: {len(fx)} fixtures")
            results += run_flow(broker, flow, fc, fx, not args.no_negative)
    finally:
        broker.close()
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "report.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    (args.out / "junit.xml").write_text(junit(results), encoding="utf-8")
    fails = [r for r in results if r["status"] == "FAIL"]
    for r in fails:
        print("FAIL", r["case"], "|", "; ".join(r["problems"]))
    print(f"{len(results) - len(fails)}/{len(results)} passed -> {args.out}")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_LOG_REPLAY_TOOLS_REPLAY_RUNNER_PY
mkdir -p "$(dirname "log-replay/tools/signature_from_example.py")"
cat > 'log-replay/tools/signature_from_example.py' <<'KIT_EOF_LOG_REPLAY_TOOLS_SIGNATURE_FROM_EXAMPLE_PY'
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
from osb_log_traces import find_payload, osb_message, payload_error  # noqa: E402

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
    return find_payload(msg)[0]


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
        "warnings": ([] if "traceId" in names else ["no UUID in the line: traces will be grouped by the ODL ecid"])
                    + ([f"payload is {find_payload(msg)[1]}: {payload_error(msg)}"] if find_payload(msg)[1] not in ("json", "xml", "none") else []),
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
KIT_EOF_LOG_REPLAY_TOOLS_SIGNATURE_FROM_EXAMPLE_PY
mkdir -p "$(dirname "log-replay/tools/spl_from_signatures.py")"
cat > 'log-replay/tools/spl_from_signatures.py' <<'KIT_EOF_LOG_REPLAY_TOOLS_SPL_FROM_SIGNATURES_PY'
#!/usr/bin/env python3
"""Step 2: generate Splunk searches from the log signatures.

For every signature: a search on its anchor text plus a rex that extracts the same named fields. For every flow: one
combined search that pulls all of the flow's lines and groups them by correlation id, so the analyst can eyeball
traces in Splunk before exporting.

Usage: spl_from_signatures.py signatures.json --index osb --sourcetype weblogic_stdout -o queries.spl
The index and sourcetype are environment-specific: ask the Splunk owner (they are usually not 'main').
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path


def pcre(py_regex: str) -> str:
    """Python named groups -> PCRE named groups; escape characters that end an SPL string."""
    return py_regex.replace("(?P<", "(?<").replace("\\", "\\\\").replace('"', '\\"')


def spl_string(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("signatures", type=Path)
    ap.add_argument("--index", required=True)
    ap.add_argument("--sourcetype", required=True)
    ap.add_argument("-o", "--out", type=Path, default=Path("queries.spl"))
    args = ap.parse_args()
    sigs = [s for s in json.loads(args.signatures.read_text(encoding="utf-8"))["signatures"] if s.get("regex")]
    base = f'index={args.index} sourcetype="{args.sourcetype}"'
    lines = ["``` Generated by spl_from_signatures.py. Run with an explicit time range that covers a full business cycle. ```", ""]
    by_flow = defaultdict(list)
    for s in sigs:
        by_flow[s["flow"]].append(s)
        lines += [f"``` {s['id']}  stage={s['stage']}  pipeline={s['pipeline_type']}  level={s['level']} ```",
                  f'{base} "{spl_string(s["anchor"])}"',
                  f'| rex field=_raw max_match=1 "(?s){pcre(s["regex"])}"',
                  "| table _time " + " ".join(g["name"] for g in s["groups"] if g["name"] != "body") + " _raw", ""]
    for flow, ss in by_flow.items():
        anchors = " OR ".join(f'"{spl_string(s["anchor"])}"' for s in ss)
        corr = sorted({c for s in ss for c in s["roles"]["correlation"]})
        rexes = "\n".join(f'| rex field=_raw max_match=1 "(?s){pcre(s["regex"])}"' for s in ss)
        lines += [f"``` EXPORT for {flow}: run this one, then Export -> CSV. Keeps one row per log line (_time, _raw). ```",
                  f"{base} ({anchors})",
                  "| sort 0 _time",
                  "| table _time _raw", ""]
        lines += [f"``` TRACES for {flow}: all lines grouped by correlation id (to look at, not to export) ```",
                  f"{base} ({anchors})", rexes,
                  f"| eval corr=coalesce({', '.join(corr)})" if corr else "| eval corr=\"NO-CORRELATION-FIELD\"",
                  "| stats min(_time) as start max(_time) as end count as lines values(source) as sources list(_raw) as events by corr",
                  "| sort - start", ""]
    lines += ["``` Export (REST, JSON lines), e.g.:",
              "curl -sk -H \"Authorization: Bearer $SPLUNK_TOKEN\" https://<splunk>:8089/services/search/jobs/export \\",
              "  --data-urlencode search='search <one of the searches above>' -d earliest_time=-30d -d latest_time=now -d output_mode=json > events.jsonl",
              "or: SPLUNK_TOKEN=... python3 tools/splunk_export.py --url https://<splunk>:8089 --search '<the EXPORT search>' --earliest -30d -o events.jsonl ```"]
    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{len(sigs)} signature searches and {len(by_flow)} trace searches -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_LOG_REPLAY_TOOLS_SPL_FROM_SIGNATURES_PY
mkdir -p "$(dirname "log-replay/tools/splunk_export.py")"
cat > 'log-replay/tools/splunk_export.py' <<'KIT_EOF_LOG_REPLAY_TOOLS_SPLUNK_EXPORT_PY'
#!/usr/bin/env python3
"""Step 2b: export raw OSB events from Splunk through the REST export endpoint (JSON lines).

The token comes from the environment (SPLUNK_TOKEN), never from a file in the repository. Only _raw and _time are kept.
Alternative without API access: run the search in the Splunk UI and export CSV (keep the _raw column);
osb_log_traces.py reads both formats.

Usage:
  SPLUNK_TOKEN=... splunk_export.py --url https://splunk.example:8089 --search 'index=osb sourcetype=... "anchor"' \
      --earliest -30d --latest now -o events.jsonl [--insecure]
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.parse
import urllib.request
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True, help="Splunk management URL, usually port 8089")
    ap.add_argument("--search", required=True)
    ap.add_argument("--earliest", default="-7d")
    ap.add_argument("--latest", default="now")
    ap.add_argument("--max", type=int, default=0, help="stop after this many events (0 = no limit)")
    ap.add_argument("-o", "--out", type=Path, default=Path("events.jsonl"))
    ap.add_argument("--insecure", action="store_true", help="skip TLS verification (test instances only)")
    args = ap.parse_args()
    token = os.environ.get("SPLUNK_TOKEN")
    if not token:
        print("SPLUNK_TOKEN is not set", file=sys.stderr)
        return 2
    search = args.search if args.search.lstrip().startswith(("search ", "|")) else "search " + args.search
    data = urllib.parse.urlencode({"search": search, "earliest_time": args.earliest, "latest_time": args.latest,
                                   "output_mode": "json"}).encode()
    req = urllib.request.Request(args.url.rstrip("/") + "/services/search/jobs/export", data=data,
                                 headers={"Authorization": f"Bearer {token}"})
    ctx = ssl._create_unverified_context() if args.insecure else ssl.create_default_context()
    n = 0
    with urllib.request.urlopen(req, context=ctx, timeout=600) as resp, args.out.open("w", encoding="utf-8") as fh:
        for raw in resp:
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            obj = json.loads(line)
            res = obj.get("result")
            if not res or "_raw" not in res:
                continue
            fh.write(json.dumps({"result": {"_raw": res["_raw"], "_time": res.get("_time")}}, ensure_ascii=False) + "\n")
            n += 1
            if args.max and n >= args.max:
                break
    print(f"{n} events -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_LOG_REPLAY_TOOLS_SPLUNK_EXPORT_PY
mkdir -p "$(dirname "log-replay/replay-config.json")"
cat > 'log-replay/replay-config.json' <<'KIT_EOF_LOG_REPLAY_REPLAY_CONFIG_JSON'
{
  "_comment": "One entry per OSB flow under test. Destinations are the TARGET broker names (from the queue register), not the WebLogic JNDI names. Values below are for the synthetic order-event sample.",
  "broker": {
    "host": "localhost",
    "stomp_port": 61613,
    "user": "artemis",
    "password_env": "ARTEMIS_PASSWORD"
  },
  "flows": {
    "order-event-prj/order-event": {
      "input": {
        "address": "orderEventsTopic",
        "type": "multicast",
        "subscription": "order-event-sub",
        "filter": "(resource='Create Order' OR resource='Cancel Order') AND (eventType='updated')"
      },
      "correlation_header": "traceId",
      "outputs": {
        "success": {"destination": "InboundOrderEventQueue", "type": "anycast"},
        "error": {"destination": "orderEventErrorQueue", "type": "anycast",
                  "expect_headers": ["errorCode", "errorMessage", "traceId", "resource", "eventType"]}
      },
      "negative_cases": [
        {"name": "eventType created is filtered out by the subscription", "headers": {"resource": "Create Order", "eventType": "created"}},
        {"name": "unknown resource is filtered out", "headers": {"resource": "Delete Order", "eventType": "updated"}}
      ],
      "timeout_s": 15
    }
  }
}
KIT_EOF_LOG_REPLAY_REPLAY_CONFIG_JSON
mkdir -p "$(dirname "log-replay/run_offline.sh")"
cat > 'log-replay/run_offline.sh' <<'KIT_EOF_LOG_REPLAY_RUN_OFFLINE_SH'
#!/usr/bin/env bash
# Offline pipeline (no Splunk, no broker): source -> signatures -> SPL -> traces -> scenarios -> fixtures.
# Usage: ./run_offline.sh [osb-export-dir] [events-file] [out-dir]
# Defaults run the synthetic sample. With real data: ./run_offline.sh osb-src/my-project events.jsonl work
set -euo pipefail
cd "$(dirname "$0")"
SRC=${1:-samples}; EVENTS=${2:-samples/osb-weblogic-sample.log}; OUT=${3:-work}
PY=${PYTHON:-$(command -v python3 || command -v python)}
mkdir -p "$OUT"
"$PY" tools/osb_log_signatures.py "$SRC" -o "$OUT/signatures.json"
"$PY" tools/spl_from_signatures.py "$OUT/signatures.json" --index "${SPLUNK_INDEX:-osb}" --sourcetype "${SPLUNK_SOURCETYPE:-weblogic}" -o "$OUT/queries.spl"
"$PY" tools/osb_log_traces.py "$OUT/signatures.json" "$EVENTS" -o "$OUT/traces" $([ -n "${MASK_KEY:-}" ] || echo --unkeyed)   # synthetic samples run unkeyed
rm -rf "$OUT/fixtures"
"$PY" tools/fixtures_from_traces.py "$OUT/traces/traces.jsonl" replay-config.json -o "$OUT/fixtures"
echo "Scenarios by frequency:"
"$PY" -c "import json,sys; [print(f\"  {s['share']:5.1f} %  {s['count']:4d}  payload {s['with_payload']:3d}  {s['scenario']}\") for s in json.load(open(sys.argv[1]))]" "$OUT/traces/scenarios.json"
KIT_EOF_LOG_REPLAY_RUN_OFFLINE_SH
mkdir -p "$(dirname "log-replay/templates/java/RecordedCasesBrokerIT.java")"
cat > 'log-replay/templates/java/RecordedCasesBrokerIT.java' <<'KIT_EOF_LOG_REPLAY_TEMPLATES_JAVA_RECORDEDCASESBROKERIT_JAVA'
package com.example.integration.orderevent;   // TEMPLATE: use the module's package

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.github.tomakehurst.wiremock.junit5.WireMockExtension;
import jakarta.jms.Connection;
import jakarta.jms.Message;
import jakarta.jms.MessageConsumer;
import jakarta.jms.MessageProducer;
import jakarta.jms.Session;
import jakarta.jms.TextMessage;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Iterator;
import java.util.Map;
import java.util.stream.Stream;
import org.apache.qpid.jms.JmsConnectionFactory;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.RegisterExtension;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.activemq.ArtemisContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * LEVEL 2, COMPONENT (needs Docker on the build agent). The flow runs in the Spring Boot test context against a REAL
 * Artemis in a container and WireMock for the HTTP backends. Proves what mocks cannot: the broker-side subscription
 * filter (the old proxy's JMS selector), transacted consume, redelivery, and the headers on the wire.
 *
 * TEMPLATE: adapt the names below and the property keys in brokerProperties() to the module's configuration.
 * Check the Artemis image tag and the CLI path against your registry and broker version.
 */
@Testcontainers
@SpringBootTest
class RecordedCasesBrokerIT {

    static final Path FLOW_DIR = Path.of("src/test/resources/parity/order-event-prj-order-event");
    static final String TOPIC = "orderEventsTopic";
    static final String SUBSCRIPTION = "order-event-sub";
    static final String SELECTOR = "(resource='Create Order' OR resource='Cancel Order') AND (eventType='updated')";
    static final String SUCCESS_QUEUE = "InboundOrderEventQueue";
    static final String ERROR_QUEUE = "orderEventErrorQueue";
    static final String CLI = "/var/lib/artemis-instance/bin/artemis";
    private static final ObjectMapper JSON = new ObjectMapper();

    @Container
    static ArtemisContainer artemis = new ArtemisContainer("apache/activemq-artemis:2.37.0").withExposedPorts(61616, 5672, 8161);

    @RegisterExtension
    static WireMockExtension backend = WireMockExtension.newInstance().build();       // stubs: templates/wiremock/*.json

    static String amqpUrl() {
        return "amqp://" + artemis.getHost() + ":" + artemis.getMappedPort(5672);
    }

    @DynamicPropertySource
    static void brokerProperties(DynamicPropertyRegistry r) {                         // TEMPLATE: the module's own keys
        r.add("broker.url", RecordedCasesBrokerIT::amqpUrl);
        r.add("broker.user", artemis::getUser);
        r.add("broker.password", artemis::getPassword);
        r.add("backend.base-url", backend::baseUrl);
    }

    @BeforeAll
    static void createBrokerObjects() throws Exception {                              // same objects as the Git register
        cli("address", "create", "--name", TOPIC, "--multicast", "--no-anycast");
        cli("queue", "create", "--name", SUBSCRIPTION, "--address", TOPIC, "--multicast", "--durable",
            "--preserve-on-no-consumers", "--filter", SELECTOR);
        for (String q : new String[] {SUCCESS_QUEUE, ERROR_QUEUE}) {
            cli("queue", "create", "--name", q, "--address", q, "--anycast", "--durable", "--preserve-on-no-consumers", "--auto-create-address");
        }
    }

    static void cli(String... args) throws Exception {
        String[] cmd = Stream.concat(Stream.of(CLI), Stream.concat(Stream.of(args),
            Stream.of("--user", artemis.getUser(), "--password", artemis.getPassword(), "--silent"))).toArray(String[]::new);
        artemis.execInContainer(cmd);
    }

    static Stream<Path> recordedCases() throws Exception {
        try (Stream<Path> files = Files.walk(FLOW_DIR)) {
            return files.filter(p -> p.getFileName().toString().equals("input.payload")).map(Path::getParent).sorted().toList().stream();
        }
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("recordedCases")
    void recordedCaseArrivesOnTheExpectedQueue(Path fx) throws Exception {
        JsonNode expected = JSON.readTree(fx.resolve("expected.json").toFile());
        JsonNode headers = JSON.readTree(fx.resolve("headers.json").toFile());
        String traceId = headers.get("traceId").asText();
        String queue = "success".equals(expected.get("outcome").asText()) ? SUCCESS_QUEUE : ERROR_QUEUE;
        try (Connection c = new JmsConnectionFactory(artemis.getUser(), artemis.getPassword(), amqpUrl()).createConnection()) {
            c.start();
            Session s = c.createSession(false, Session.AUTO_ACKNOWLEDGE);
            MessageProducer p = s.createProducer(s.createTopic(TOPIC));
            TextMessage m = s.createTextMessage(Files.readString(fx.resolve("input.payload")));
            for (Iterator<Map.Entry<String, JsonNode>> it = headers.fields(); it.hasNext(); ) {
                Map.Entry<String, JsonNode> e = it.next();
                m.setStringProperty(e.getKey(), e.getValue().asText());
            }
            p.send(m);
            MessageConsumer consumer = s.createConsumer(s.createQueue(queue), "traceId = '" + traceId + "'");
            Message out = consumer.receive(15_000);
            assertThat(out).as("message on " + queue).isNotNull();
            for (JsonNode h : expected.get("expected_headers")) {
                assertThat(out.propertyExists(h.asText())).as("header " + h.asText()).isTrue();
            }
        }
    }

    @Test
    void messagesOutsideTheSelectorAreDropped() throws Exception {                    // OSB never logged these: from the proxy config
        try (Connection c = new JmsConnectionFactory(artemis.getUser(), artemis.getPassword(), amqpUrl()).createConnection()) {
            c.start();
            Session s = c.createSession(false, Session.AUTO_ACKNOWLEDGE);
            TextMessage m = s.createTextMessage("{}");
            m.setStringProperty("resource", "Create Order");
            m.setStringProperty("eventType", "created");
            m.setStringProperty("traceId", "negative-1");
            s.createProducer(s.createTopic(TOPIC)).send(m);
            for (String q : new String[] {SUCCESS_QUEUE, ERROR_QUEUE}) {
                assertThat(s.createConsumer(s.createQueue(q), "traceId = 'negative-1'").receive(3_000)).as(q).isNull();
            }
        }
    }
}
KIT_EOF_LOG_REPLAY_TEMPLATES_JAVA_RECORDEDCASESBROKERIT_JAVA
mkdir -p "$(dirname "log-replay/templates/java/RecordedCasesRouteTest.java")"
cat > 'log-replay/templates/java/RecordedCasesRouteTest.java' <<'KIT_EOF_LOG_REPLAY_TEMPLATES_JAVA_RECORDEDCASESROUTETEST_JAVA'
package com.example.integration.orderevent;   // TEMPLATE: use the module's package

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;
import java.util.stream.Stream;
import org.apache.camel.CamelContext;
import org.apache.camel.EndpointInject;
import org.apache.camel.Exchange;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.builder.AdviceWith;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.test.spring.junit5.CamelSpringBootTest;
import org.apache.camel.test.spring.junit5.UseAdviceWith;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;

/**
 * LEVEL 1, UNIT (no Docker). Replays every recorded OSB case through the route with all boundaries mocked:
 * the input subscription becomes direct:in, the output queues become mock endpoints, HTTP backends become mocks.
 *
 * Fixtures: src/test/resources/parity/<flow>/<scenario>/<trace>/ written by osb-log-replay/tools/fixtures_from_traces.py
 *   input.payload, headers.json, expected.json, optional expected-output.xml (from the ORIGINAL XQuery, golden test).
 *
 * TEMPLATE: adapt ROUTE_ID, FLOW_DIR and the three endpoint patterns to the route; nothing else should need editing.
 */
@CamelSpringBootTest
@SpringBootTest
@UseAdviceWith
class RecordedCasesRouteTest {

    static final String ROUTE_ID = "order-event";                                     // routeId of the migrated proxy
    static final Path FLOW_DIR = Path.of("src/test/resources/parity/order-event-prj-order-event");
    static final String SUCCESS_URI = "amqp:queue:InboundOrderEventQueue*";           // patterns of the real endpoints
    static final String ERROR_URI = "amqp:queue:orderEventErrorQueue*";
    static final String BACKEND_URI = "http*";                                        // remove if the flow calls no backend

    private static final ObjectMapper JSON = new ObjectMapper();

    @Autowired CamelContext context;
    @Autowired ProducerTemplate producer;
    @EndpointInject("mock:success") MockEndpoint success;
    @EndpointInject("mock:error") MockEndpoint error;
    @EndpointInject("mock:backend") MockEndpoint backend;

    @BeforeEach
    void mockTheBoundaries() throws Exception {
        if (context.isStarted()) {
            MockEndpoint.resetMocks(context);
            return;
        }
        AdviceWith.adviceWith(context, ROUTE_ID, r -> {
            r.replaceFromWith("direct:in");                                           // instead of the topic subscription
            r.weaveByToUri(SUCCESS_URI).replace().to("mock:success");
            r.weaveByToUri(ERROR_URI).replace().to("mock:error");
            r.weaveByToUri(BACKEND_URI).replace().to("mock:backend");                 // canned reply set per test if needed
        });
        context.start();
    }

    static Stream<Path> recordedCases() throws Exception {
        try (Stream<Path> files = Files.walk(FLOW_DIR)) {
            return files.filter(p -> p.getFileName().toString().equals("input.payload")).map(Path::getParent).sorted().toList().stream();
        }
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("recordedCases")
    void replaysRecordedCase(Path fx) throws Exception {
        JsonNode expected = JSON.readTree(fx.resolve("expected.json").toFile());
        Map<String, Object> headers = new HashMap<>();
        JSON.readTree(fx.resolve("headers.json").toFile()).fields().forEachRemaining(e -> headers.put(e.getKey(), e.getValue().asText()));
        boolean ok = "success".equals(expected.get("outcome").asText());
        MockEndpoint target = ok ? success : error;
        target.expectedMessageCount(1);
        (ok ? error : success).expectedMessageCount(0);

        producer.sendBodyAndHeaders("direct:in", Files.readString(fx.resolve("input.payload")), headers);

        MockEndpoint.assertIsSatisfied(context);
        Exchange out = target.getReceivedExchanges().get(0);
        for (JsonNode h : expected.get("expected_headers")) {                         // e.g. errorCode, errorMessage, traceId
            assertThat(out.getMessage().getHeaders()).containsKey(h.asText());
        }
        Path golden = fx.resolve("expected-output.xml");
        if (ok && Files.exists(golden)) {                                              // oracle = original transform, never this code
            org.xmlunit.assertj3.XmlAssert.assertThat(out.getMessage().getBody(String.class))
                .and(Files.readString(golden)).ignoreWhitespace().areIdentical();
        }
    }
}
KIT_EOF_LOG_REPLAY_TEMPLATES_JAVA_RECORDEDCASESROUTETEST_JAVA
mkdir -p "$(dirname "log-replay/templates/wiremock/backend-from-bix.json")"
cat > 'log-replay/templates/wiremock/backend-from-bix.json' <<'KIT_EOF_LOG_REPLAY_TEMPLATES_WIREMOCK_BACKEND_FROM_BIX_JSON'
{
  "_comment": "TEMPLATE: one stub per business-service operation. Take the URL path and SOAPAction (or HTTP method) from the .bix endpoint and WSDL; take the response from the logs if OSB logged it, else from the OSB test console or a WSDL example. Add a fault variant to test the error path, and a delayed variant (fixedDelayMilliseconds above the business-service timeout) to test retries.",
  "mappings": [
    {
      "request": {"method": "POST", "urlPath": "/backend/MemberLookup", "headers": {"SOAPAction": {"contains": "lookupMember"}},
                  "bodyPatterns": [{"matchesXPath": "//*[local-name()='memberId']"}]},
      "response": {"status": 200, "headers": {"Content-Type": "text/xml; charset=utf-8"},
                   "bodyFileName": "lookupMember-ok.xml"}
    },
    {
      "request": {"method": "POST", "urlPath": "/backend/MemberLookup", "headers": {"X-Test-Case": {"equalTo": "fault"}}},
      "response": {"status": 500, "headers": {"Content-Type": "text/xml; charset=utf-8"},
                   "body": "<soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\"><soap:Body><soap:Fault><faultcode>soap:Server</faultcode><faultstring>backend unavailable</faultstring></soap:Fault></soap:Body></soap:Envelope>"}
    },
    {
      "request": {"method": "POST", "urlPath": "/backend/MemberLookup", "headers": {"X-Test-Case": {"equalTo": "timeout"}}},
      "response": {"status": 200, "fixedDelayMilliseconds": 35000}
    }
  ]
}
KIT_EOF_LOG_REPLAY_TEMPLATES_WIREMOCK_BACKEND_FROM_BIX_JSON
mkdir -p "$(dirname "log-replay/mock/.env.example")"
cat > 'log-replay/mock/.env.example' <<'KIT_EOF_LOG_REPLAY_MOCK__ENV_EXAMPLE'
# Copy to .env and adjust. Never commit .env.
ARTEMIS_USER=artemis
ARTEMIS_PASSWORD=change-me
ARTEMIS_IMAGE=apache/activemq-artemis:2.37.0
WIREMOCK_IMAGE=wiremock/wiremock:3.9.1
PYTHON_IMAGE=python:3.12-slim
# Image of the migrated Camel flow under test (profile "sut"):
SUT_IMAGE=registry.example/camel/order-event:dev
SUT_BROKER_URL=amqp://artemis:5672
FIXTURES_DIR=work/fixtures
REPORT_DIR=work/report
KIT_EOF_LOG_REPLAY_MOCK__ENV_EXAMPLE
mkdir -p "$(dirname "log-replay/mock/docker-compose.yml")"
cat > 'log-replay/mock/docker-compose.yml' <<'KIT_EOF_LOG_REPLAY_MOCK_DOCKER_COMPOSE_YML'
# Mock architecture for replaying recorded OSB traffic against a migrated Camel flow.
# Profiles:  (default) broker + wiremock  ·  sut = your Camel flow image  ·  selftest = stub flow  ·  replay = runner
# Image tags are pinned through .env; check them against your registry mirror before first use.
services:
  artemis:
    image: ${ARTEMIS_IMAGE:-apache/activemq-artemis:2.37.0}
    environment:
      ARTEMIS_USER: ${ARTEMIS_USER:-artemis}
      ARTEMIS_PASSWORD: ${ARTEMIS_PASSWORD:?set ARTEMIS_PASSWORD in .env}
    ports: ["61616:61616", "5672:5672", "61613:61613", "8161:8161"]
    healthcheck:
      test: ["CMD-SHELL", "/var/lib/artemis-instance/bin/artemis check node --up --user $$ARTEMIS_USER --password $$ARTEMIS_PASSWORD --silent || exit 1"]
      interval: 10s
      retries: 12

  wiremock:                       # HTTP / SOAP backends the flow calls (business services); stubs in ./wiremock/mappings
    image: ${WIREMOCK_IMAGE:-wiremock/wiremock:3.9.1}
    command: ["--verbose", "--global-response-templating"]
    volumes: ["./wiremock:/home/wiremock"]
    ports: ["8080:8080"]

  sut:                            # the migrated Camel flow (Camel K integration image or Camel on Spring Boot jar image)
    profiles: ["sut"]
    image: ${SUT_IMAGE:?set SUT_IMAGE in .env to the image of the flow under test}
    environment:                  # map these to the flow's own property names in .env / an env file
      BROKER_URL: ${SUT_BROKER_URL:-amqp://artemis:5672}
      BROKER_USER: ${ARTEMIS_USER:-artemis}
      BROKER_PASSWORD: ${ARTEMIS_PASSWORD}
      BACKEND_BASE_URL: http://wiremock:8080
    depends_on:
      artemis: {condition: service_healthy}

  sut-stub:                       # harness self-test only: forwards valid JSON to the success queue, invalid to the error queue
    profiles: ["selftest"]
    image: ${PYTHON_IMAGE:-python:3.12-slim}
    working_dir: /app
    volumes: ["./sut-stub:/app", "${REPLAY_CONFIG:-../replay-config.json}:/app/replay-config.json:ro"]
    environment:
      BROKER_HOST: artemis
      ARTEMIS_PASSWORD: ${ARTEMIS_PASSWORD}
    command: ["sh", "-c", "pip install -q stomp.py==8.1.2 && python stub_flow.py replay-config.json"]
    depends_on:
      artemis: {condition: service_healthy}

  replay:                         # runs the recorded fixtures through the broker and writes report/junit.xml
    profiles: ["replay"]
    image: ${PYTHON_IMAGE:-python:3.12-slim}
    working_dir: /work
    volumes: ["..:/work"]
    environment:
      BROKER_HOST: artemis
      ARTEMIS_PASSWORD: ${ARTEMIS_PASSWORD}
    command: ["sh", "-c", "pip install -q stomp.py==8.1.2 && python tools/replay_runner.py ${REPLAY_CONFIG_IN_WORK:-replay-config.json} ${FIXTURES_DIR:-work/fixtures} -o ${REPORT_DIR:-work/report}"]
    depends_on:
      artemis: {condition: service_healthy}
KIT_EOF_LOG_REPLAY_MOCK_DOCKER_COMPOSE_YML
mkdir -p "$(dirname "log-replay/mock/setup_broker.sh")"
cat > 'log-replay/mock/setup_broker.sh' <<'KIT_EOF_LOG_REPLAY_MOCK_SETUP_BROKER_SH'
#!/usr/bin/env bash
# Creates the input address, the filtered subscription queue and the output queues in the mock broker,
# from replay-config.json. Run after `docker compose up -d artemis` and whenever the config changes.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a
python3 ../tools/broker_setup_commands.py "${REPLAY_CONFIG:-../replay-config.json}" | while IFS= read -r cmd; do
  echo "+ ${cmd%%--user*}"
  docker compose exec -T -e ARTEMIS_USER="${ARTEMIS_USER:-artemis}" -e ARTEMIS_PASSWORD="$ARTEMIS_PASSWORD" artemis sh -c "$cmd" \
    || echo "  (already exists or failed: check the output above)"
done
KIT_EOF_LOG_REPLAY_MOCK_SETUP_BROKER_SH
mkdir -p "$(dirname "log-replay/mock/sut-stub/stub_flow.py")"
cat > 'log-replay/mock/sut-stub/stub_flow.py' <<'KIT_EOF_LOG_REPLAY_MOCK_SUT_STUB_STUB_FLOW_PY'
"""Harness self-test stub, NOT a migration: consumes each flow's subscription queue (FQQN address::queue) and forwards
valid JSON payloads to the flow's success queue, invalid ones to the error queue with error headers. Lets you prove the
mock architecture and the replay runner before the real Camel flow exists."""
import json
import os
import sys
import time

import stomp

cfg = json.load(open(sys.argv[1]))
b = cfg["broker"]
conn = stomp.Connection([(os.environ.get("BROKER_HOST", b["host"]), int(b["stomp_port"]))])


class Forward(stomp.ConnectionListener):
    def __init__(self, fc):
        self.fc = fc

    def on_message(self, frame):
        out, extra = self.fc["outputs"]["success"], {}
        try:
            json.loads(frame.body, strict=False)   # OSB logs may carry raw tabs/newlines inside strings
        except ValueError as exc:
            out = self.fc["outputs"]["error"]
            extra = {"errorCode": "STUB-PARSE", "errorMessage": str(exc)[:200], "debugInfo": "stub"}
        keep = {k: v for k, v in frame.headers.items() if k in ("traceId", "resource", "eventType")}
        conn.send(destination=out["destination"], body=frame.body,
                  headers={**keep, **extra, "destination-type": out.get("type", "anycast").upper()})


for i, (flow, fc) in enumerate(cfg["flows"].items(), start=1):
    conn.set_listener(f"f{i}", Forward(fc))
connect_ok = False
for _ in range(30):
    try:
        conn.connect(b["user"], os.environ.get(b.get("password_env", "ARTEMIS_PASSWORD"), ""), wait=True)
        connect_ok = True
        break
    except Exception:
        time.sleep(2)
if not connect_ok:
    sys.exit("broker not reachable")
for i, (flow, fc) in enumerate(cfg["flows"].items(), start=1):
    inp = fc["input"]
    conn.subscribe(destination=f"{inp['address']}::{inp['subscription']}", id=str(i), ack="auto",
                   headers={"destination-type": "MULTICAST"})
    print("stub consuming", f"{inp['address']}::{inp['subscription']}", flush=True)
while True:
    time.sleep(60)
KIT_EOF_LOG_REPLAY_MOCK_SUT_STUB_STUB_FLOW_PY
mkdir -p "$(dirname "log-replay/mock/wiremock/mappings/example-backend.json")"
cat > 'log-replay/mock/wiremock/mappings/example-backend.json' <<'KIT_EOF_LOG_REPLAY_MOCK_WIREMOCK_MAPPINGS_EXAMPLE_BACKEND_JSON'
{
  "_comment": "Example stub for an HTTP/SOAP business service the flow calls. One file per backend operation; generate them from the business service (.bix) endpoint and the recorded responses.",
  "request": {"method": "POST", "urlPath": "/backend/MemberLookup", "headers": {"SOAPAction": {"contains": "lookupMember"}}},
  "response": {"status": 200, "headers": {"Content-Type": "text/xml; charset=utf-8"},
               "body": "<soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\"><soap:Body><lookupMemberResponse><status>ACTIVE</status></lookupMemberResponse></soap:Body></soap:Envelope>"}
}
KIT_EOF_LOG_REPLAY_MOCK_WIREMOCK_MAPPINGS_EXAMPLE_BACKEND_JSON
mkdir -p "$(dirname "log-replay/skill/osb-log-test-mining/SKILL.md")"
cat > 'log-replay/skill/osb-log-test-mining/SKILL.md' <<'KIT_EOF_LOG_REPLAY_SKILL_OSB_LOG_TEST_MINING_SKILL_MD'
---
name: osb-log-test-mining
description: Build test cases for migrated OSB flows from production OSB logs. Reads the Log actions in the OSB pipeline source to derive log signatures, generates Splunk searches, rebuilds traces and scenarios from exported events with personal-data masking, writes fixtures with provenance, and replays them end to end against the Camel flow on a mock broker. Use when asked to test an OSB-to-Camel migration with real traffic, to mine Splunk or WebLogic logs for test cases, or to set up a replay or mock environment for a migrated flow.
---

# OSB log test mining

Tools live in `osb-log-replay/tools/` (stdlib Python; the replay runner needs `stomp.py`). Method and pitfalls:
`osb-log-replay/docs/WORKFLOW.md`. Read it before step 2.

## Steps

1. **Signatures from source**: `python3 tools/osb_log_signatures.py <osb-export> -o work/signatures.json`.
   Report: number of signatures per flow, log levels (debug lines are often off in production), signatures without a
   correlation field, ambiguous splits. These limit everything after; say so before searching.
2. **Splunk searches**: `python3 tools/spl_from_signatures.py work/signatures.json --index <idx> --sourcetype <st> -o work/queries.spl`.
   Ask the user for index and sourcetype. Ask them to run one trace search in Splunk and confirm that a multi-line
   payload arrives as one event.
3. **Export**: the user exports `_raw` + `_time` (CSV from the UI, or `tools/splunk_export.py` with `SPLUNK_TOKEN` in the
   environment). Never ask for the token in chat; never write it to a file.
4. **Traces and scenarios**: `python3 tools/osb_log_traces.py work/signatures.json <events> -o work/traces [--dims ...]`.
   Read `coverage.json` and explain: signatures never seen, traces without payload, events without correlation.
   Present `scenarios.json` by frequency.
5. **Fixtures**: `python3 tools/fixtures_from_traces.py work/traces/traces.jsonl replay-config.json -o work/fixtures`.
   Copy `work/fixtures/parity` and `golden/MANIFEST.csv` into the Camel module's `src/test/resources`.
6. **Golden outputs**: run the ORIGINAL XQuery/XSLT on each `input.payload` (osb-to-camel skill, golden test) and save
   `expected-output.xml` next to it with manifest source `original-transform`.
7. **Unit tests**: the tester role of the agent kit writes route tests from the flow card, using these fixtures as
   inputs (template `templates/java/RecordedCasesRouteTest.java`; level 2: `RecordedCasesBrokerIT.java`). They are the
   base layer and must pass before replay. How to mock at each level: `docs/MOCKING_RUNBOOK.md`.
8. **E2E replay**: fill `replay-config.json` with the flow's target broker names and the proxy selector; then
   `cd mock && docker compose up -d && ./setup_broker.sh`; start the flow (`--profile sut`); run
   `docker compose --profile replay run --rm replay`. Report `work/report/junit.xml`.

## Rules

- Expected values come from OSB evidence (logs, recorded messages, the original transform), never from the new code.
- Mask personal data at extraction with the data owner's key (`MASK_KEY` env var; `--unkeyed` only for synthetic samples), delete the raw export (`--delete-input`), run `tools/mask_residue_check.py` (must report 0 findings) and have a named reviewer check a sample before fixtures leave the secure environment.
- Negative cases for the JMS selector come from the proxy configuration (`negative_cases`), because OSB never logs a
  message its selector rejected.
- A scenario without a payload is reported, not invented. Propose the options in WORKFLOW.md ("When logs are not enough").
KIT_EOF_LOG_REPLAY_SKILL_OSB_LOG_TEST_MINING_SKILL_MD
mkdir -p "$(dirname "log-replay/README.md")"
cat > 'log-replay/README.md' <<'KIT_EOF_LOG_REPLAY_README_MD'
# osb-log-replay

Turn OSB logs from Splunk into test cases for the migrated Camel flows.

You give it two things:
1. the **OSB project files** (`.pipeline` / `.proxy`);
2. the **OSB log lines exported from Splunk**.

You get back one folder per test scenario, holding the real input message, its headers and the expected result.
Those are the inputs for the unit tests the agent kit writes, and for an optional end-to-end replay.

![one-time flow](docs/osb_log_replay_p3.png)

---

## 1. What you need

| Need | Why |
|---|---|
| Python 3.10 or newer | all scripts; standard library only |
| The OSB project folder | e.g. `my-flow-prj/` with its `Pipeline/*.pipeline` and `Proxy_Service/*.proxy` files |
| Read access to Splunk (the UI is enough) | to run one search and export it as CSV |
| The Splunk **index** and **sourcetype** of the OSB server logs | ask the Splunk owner |
| *Optional:* Docker | only for the end-to-end replay (section 6) |

Nothing to install for steps 1–5. The replay runner (step 6) needs `stomp.py`, installed inside its container.

---

## 2. Quick start: try it on the bundled sample (2 minutes)

```bash
cd osb-log-replay
./run_offline.sh                       # runs steps 1, 2, 4, 5 on the synthetic sample, results in ./work
python3 -m unittest discover -s tests  # 15 unit tests, should print OK
```

Open `work/traces/scenarios.json` and `work/fixtures/parity/` to see what you will get for a real flow.

---

## 3. Use it on your flow, step by step

### Step 0. Put the OSB files in place
```bash
mkdir -p osb-src work
cp -r /path/to/my-flow-prj osb-src/
```

### Step 1. Read the logging from the OSB source → `tools/osb_log_signatures.py`
```bash
python3 tools/osb_log_signatures.py osb-src -o work/signatures.json
```
It finds every **Log action** in the pipelines and records, per action:
- what the log line looks like;
- which part of it is the message body;
- its log level;
- which field links the lines of one message (correlation id).

Read the printed summary and any warnings. If the line with the body is `debug`, it is probably not written in
production (see step 3).

### Step 2. Make the Splunk searches → `tools/spl_from_signatures.py`
```bash
python3 tools/spl_from_signatures.py work/signatures.json --index <index> --sourcetype <sourcetype> -o work/queries.spl
```
`work/queries.spl` contains, per flow:
- **EXPORT** search: run this one and export it;
- **TRACES** search: groups the lines per message, for looking only;
- one search per log line: to check that the fields are extracted.

### Step 3. Export the log lines from Splunk (you, in the Splunk UI)
1. Paste the **EXPORT** search and set the time range to 7–30 days.
2. Check three things:
   - lines are found;
   - the line with the message body is there;
   - a multi-line message shows as **one** event.
3. **Export → CSV** and save the file as `work/events.csv`. It needs the `_time` and `_raw` columns, which the
   EXPORT search already returns.

**No line with the body?** Debug logging is off. Either enable debug for that proxy in a test environment and export
from there, or use OSB Report actions or message tracing if they are on.

*Without the UI:* `tools/splunk_export.py` does the same export through the Splunk REST API. The token is read from
the `SPLUNK_TOKEN` environment variable:
```bash
SPLUNK_TOKEN=... python3 tools/splunk_export.py --url https://<splunk>:8089 --search '<EXPORT search>' \
    --earliest -30d --latest now -o work/events.jsonl
```

### Step 4. Analyse → `tools/osb_log_traces.py`
```bash
python3 tools/osb_log_traces.py work/signatures.json work/events.csv -o work/traces
```
It reads the CSV (a Splunk JSON export and raw server logs work too, in either OSB format: classic WebLogic `####<…>` or the 12c **ODL** diagnostic log `[2026-…] [server] [NOTIFICATION] … [ecid: …]`) and:
- **masks personal data with a key the data owner holds** (`MASK_KEY` environment variable, HMAC-SHA256): the values of JSON fields and XML elements whose name matches the personal-data rules (names incl. Arabic/English variants, address/remarks/notes, birth dates, e-mail/phone/mobile, NIN/iqama/passport/national id/social insurance no/IBAN/account), plus digit runs of 9+, e-mail addresses and Saudi IBANs in free text. The same value always gets the same mask with the same key, so masked data from different flows and extracts still joins; without the key it cannot be reversed. Names and text become `masked_<hex>`, identifiers keep their length, birth dates shift by up to 183 days (format and age band kept), e-mails end in `@example.invalid`; the payload stays valid JSON/XML;
- **groups the lines into one trace per message;**
- **sorts the traces into scenarios:** success or error × header values × error code.

| Output | What to read in it |
|---|---|
| `work/traces/scenarios.json` | scenarios by frequency: the top ones are most of the traffic, the rare ones are where migrations break |
| `work/traces/coverage.json` | lines matched vs. read, traces without a body, Log actions never seen |
| `work/traces/traces.jsonl` | every trace with its masked lines (input for step 5) |

Useful options:
- `--dims hdr_resource,hdr_eventType` chooses which fields split the scenarios;
- `--mask-regex '<pattern>'` adds more masking;
- `--mask-json-key <field>` masks an extra exact JSON field; `--mask-key-pattern <regex>` adds a case-insensitive key pattern (full match on the key or XML element name);
- `--unkeyed` runs without a key (synthetic samples only; refused otherwise); `--delete-input` removes the raw events file after a successful run;
- `coverage.json` records `masking.keyed` and `masking.key_id` (hash prefix of the key, never the key) for the fixture manifest.
- **Residue check before anything leaves the secure environment:** `python3 tools/mask_residue_check.py work/traces work/fixtures` scans for Arabic script, e-mails outside `@example.invalid`, Saudi IBANs and unmasked personal keys/elements; it prints file, line and check name only, never a value, and exits 1 on any finding. Digit-only identifiers cannot be judged by the scan: the data owner's sample review covers them.

### Step 5. Produce the test cases → `tools/fixtures_from_traces.py`
First edit **`replay-config.json`** for your flow (see section 5). Then:
```bash
python3 tools/fixtures_from_traces.py work/traces/traces.jsonl replay-config.json -o work/fixtures --per-scenario 3
```
Result, one folder per test case:
```
work/fixtures/parity/<flow>/<scenario>/<trace-id>/
    input.payload    the real request message (masked)
    headers.json     its JMS headers, incl. the correlation id
    expected.json    expected outcome (success / error), destination queue, error code, error headers
work/fixtures/golden/MANIFEST.csv   every file marked "osb-recording" (accepted by gate G7 of the agent kit)
```
The logs do not contain the **output** message. Add `expected-output.xml` to each folder by running the
**original** OSB XQuery on `input.payload`: the golden test of the osb-to-camel skill does this.

### Step 6. Use the test cases (how to mock: [`docs/MOCKING_RUNBOOK.md`](docs/MOCKING_RUNBOOK.md))
- **Unit tests (the base):** copy `work/fixtures/parity` and `work/fixtures/golden/MANIFEST.csv` into the Camel
  module's `src/test/resources`, then run `/osb-test` in pi (agent kit). The tester writes unit tests with these inputs.
- **End-to-end replay (optional, needs Docker):** see section 6.

**One command for steps 1, 2, 4 and 5**, once `work/events.csv` exists:
```bash
SPLUNK_INDEX=<index> SPLUNK_SOURCETYPE=<sourcetype> ./run_offline.sh osb-src work/events.csv work
```

---

## 4. Which script does what

| Script | Step | Input | Output | Command |
|---|---|---|---|---|
| `tools/osb_log_signatures.py` | 1 | OSB project folder | `signatures.json` | `osb_log_signatures.py osb-src -o work/signatures.json` |
| `tools/spl_from_signatures.py` | 2 | `signatures.json` | `queries.spl` | `spl_from_signatures.py work/signatures.json --index I --sourcetype S -o work/queries.spl` |
| `tools/splunk_export.py` | 3 (optional) | a search + `SPLUNK_TOKEN` | `events.jsonl` | `splunk_export.py --url U --search Q --earliest -30d -o work/events.jsonl` |
| `tools/osb_log_traces.py` | 4 | `signatures.json` + `events.csv` / `.jsonl` / `.log` | `traces.jsonl`, `scenarios.json`, `coverage.json` | `osb_log_traces.py work/signatures.json work/events.csv -o work/traces` |
| `tools/fixtures_from_traces.py` | 5 | `traces.jsonl` + `replay-config.json` | `parity/…` folders + `MANIFEST.csv` | `fixtures_from_traces.py work/traces/traces.jsonl replay-config.json -o work/fixtures` |
| `tools/replay_runner.py` | 6 (optional) | `replay-config.json` + fixtures | `report.json`, `junit.xml` | run through Docker, see section 6 |
| `tools/broker_setup_commands.py` | 6 (optional) | `replay-config.json` | broker CLI commands | used by `mock/setup_broker.sh` |
| `run_offline.sh` | 1, 2, 4, 5 | OSB folder + events file | everything in `work/` | `./run_offline.sh osb-src work/events.csv work` |

All scripts print their options with `-h`.

---

## 5. `replay-config.json` (one entry per flow)

```json
"my-flow-prj/my-flow": {
  "input":  {"address": "<input topic or queue>", "type": "multicast",
             "subscription": "<subscription queue>", "filter": "<the proxy's JMS selector>"},
  "correlation_header": "traceId",
  "outputs": {
    "success": {"destination": "<output queue>", "type": "anycast"},
    "error":   {"destination": "<error queue>",  "type": "anycast",
                "expect_headers": ["errorCode", "errorMessage", "traceId"]}
  },
  "negative_cases": [{"name": "filtered out", "headers": {"eventType": "created"}}],
  "timeout_s": 15
}
```

- **The key** is `<project folder>/<pipeline name>`, as printed in step 1.
- **Queue names** are the names on the **new** broker, not the WebLogic JNDI names.
- **`negative_cases`** are messages the proxy's selector must drop. OSB never logs those, so they come from the proxy
  configuration, not from Splunk.

---

## 6. End-to-end replay (optional, needs Docker)

Runs the test cases through a mock broker against the real Camel flow:

```bash
cd mock
cp .env.example .env                         # set ARTEMIS_PASSWORD and SUT_IMAGE (the Camel flow image)
docker compose up -d                         # Artemis broker + WireMock
./setup_broker.sh                            # creates the topic, the filtered subscription and the output queues
docker compose --profile selftest up -d      # optional: a stub flow to prove the setup first
docker compose --profile sut up -d           # the real Camel flow
docker compose --profile replay run --rm replay   # results in ../work/report/report.json and junit.xml
```

For each test case it publishes the input, waits for the message with the same correlation id, and checks:
- it went to the success or error queue as expected;
- the error headers are present;
- the body equals `expected-output.xml`, if present.

---

## 7. Folder layout

```
osb-log-replay/
  README.md               this file
  run_offline.sh          steps 1, 2, 4, 5 in one command
  replay-config.json      per-flow settings (edit for your flow)
  tools/                  the scripts (section 4)
  mock/                   Docker Compose mock: Artemis, WireMock, flow under test, stub, replay runner
  samples/                SYNTHETIC OSB pipeline and WebLogic log (invented values) used by the tests
  tests/                  unit tests for every script
  docs/ONE_TIME_FLOW.md   the step-by-step guide with checks and decisions
  docs/MOCKING_RUNBOOK.md how to mock: unit (no Docker), component (Testcontainers), end to end (Compose)
  templates/java/         RecordedCasesRouteTest (level 1), RecordedCasesBrokerIT (level 2)
  templates/wiremock/     backend stub template (reply, fault, timeout) from a business service
  docs/WORKFLOW.md        the method in depth: OSB logging, Splunk pitfalls, test layers
  docs/AUTOMATION.md      later, optional: running it automatically
  docs/*.drawio, *.png    diagrams: workflow, mock architecture, one-time flow, automation, how to mock
  skill/                  Agent Skill so an AI agent can run the steps
```

---

## 8. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Step 1 finds 0 signatures | wrong folder level, or the project has no Log actions | point at the folder that contains the project folders; check the pipeline has Log actions |
| Warning "no correlation field" | the Log action does not write the message id | traces cannot be grouped; use another Log action, or add the id in a test environment |
| Splunk finds no lines | wrong index or sourcetype, time range, or the flow did not run | check with the Splunk owner; widen the time range |
| `traces_without_payload` is high | the body line is debug-level and off | enable debug for this proxy in a test environment (step 3) |
| One message shows as many events | Splunk event breaking splits multi-line lines | ask the Splunk owner, or use the raw WebLogic log files as input to step 4 |
| `events_unmatched` is high, matches low | the log line format differs from the pipeline expression | compare one `_raw` line with `signatures.json`; report the case |
| `coverage.json` shows `"formats": {"unknown": …}` | the log format is neither WebLogic nor ODL | send one line (personal data removed) to extend the parser |
| lines of one message are not grouped | the Log action does not write a trace id | ODL lines are grouped by their `ecid` automatically (`events_correlated_by_ecid`) |
| Step 5 skips scenarios | those traces have no body | expected, see the line above |

## Status

- **Steps 1–5 and the replay logic:** unit-tested on the synthetic sample.
- **Not yet run:** the Docker stack and the live broker connection; check the image tags and the Artemis CLI options
  on first use.
- **Before trusting the counts:** run step 1 and one Splunk search on a real export.

Background reading: [`docs/ONE_TIME_FLOW.md`](docs/ONE_TIME_FLOW.md) (guide), [`docs/MOCKING_RUNBOOK.md`](docs/MOCKING_RUNBOOK.md) (mocking), [`docs/WORKFLOW.md`](docs/WORKFLOW.md) (method).

## Anonymise first (no OSB source needed)

`tools/anonymize_logs.py <events.csv|.log> -o <masked.csv>` masks a Splunk CSV (multi-line `_raw` kept) or a plain log
with the same keyed rules as the trace builder (`MASK_KEY`), runs the residue check, and writes
`<masked>.report.json` with counts, key id, residue result and a key inventory (key, count, type, masked yes/no, no
values) for the reviewer. `osb_log_traces.py --already-masked` then reads the masked file without masking again.
Synthetic example with the structure of a real ODL pipeline line: `samples/splunk-export-synthetic.csv`.

## Without the OSB source

`tools/signature_from_example.py <masked.csv> -o signatures.json` builds the log signature from one anonymised example line (payload, TraceID, `Resource Name`, flow id, stage direction), so traces, fixtures and the replay work on the log alone. `vdi-osb-migration/bin/task1_log_only.sh` chains it: anonymise → signature → traces → fixtures → optional mock replay.
KIT_EOF_LOG_REPLAY_README_MD
mkdir -p "$(dirname "log-replay/docs/AUTOMATION.md")"
cat > 'log-replay/docs/AUTOMATION.md' <<'KIT_EOF_LOG_REPLAY_DOCS_AUTOMATION_MD'
# Automation plan (later, optional)

Run the one-time flow in [ONE_TIME_FLOW.md](ONE_TIME_FLOW.md) first. Automate only after it has proven the method on the pilot flow.

![automation](osb_log_replay_p4.png)

**Principle:** deterministic scripts in CI do the repetitive work and decide pass or fail. The AI agent is used only
where judgement is needed: writing unit tests, fixing code, explaining gaps. Humans set things up once, then decide
at three points. Nothing the agent says counts as evidence; only script output does.

## Four phases, four triggers

| Phase | Trigger | What runs (scripts, no AI) | AI agent | Human | Result |
|---|---|---|---|---|---|
| **P0 Catalogue** | new OSB export pushed to Git | `osb_inventory.py` (agent kit) + `osb_log_signatures.py` for all flows; **`replay-config.json` generated** from the proxy and business services (topic, selector, queues) plus a JNDI → target-name map | explains weak signatures (no correlation, ambiguous split, debug-only payload) | once: Splunk index + sourcetype, event breaking checked, service token, name map | signature catalogue with warnings, replay config per flow |
| **P1 Harvest** | Jenkins cron (weekly) + on demand per flow | `spl_from_signatures.py` → `splunk_export.py` (token from Jenkins credentials) → `osb_log_traces.py` | explains coverage gaps and proposes the cheapest fix | decides gaps: enable debug for a flow in test, use Report action / tracing, or accept and record the gap | scenarios by frequency and coverage per flow |
| **P2 Build tests** | flow card approved (gate A of the agent kit) | `fixtures_from_traces.py` (top and rare scenarios); **golden outputs** from the original XQuery on each input; copy into the module's `src/test/resources` | **tester role writes unit tests** from the card's test matrix, using the fixtures (the base) | reviews a masked sample before fixtures leave the secure environment | fixtures + MANIFEST, golden outputs, unit tests |
| **P3 Verify** | Camel flow image built | Docker Compose mock (Artemis + WireMock + flow) → `setup_broker.sh` → `replay_runner.py` → junit = **gate G9**, after gates G1–G8 | implementer fixes red (production code only, max 3 loops); reviewer adds replay evidence to the record | gate B sign-off, then shadow run and cut-over | replay report, migration record with evidence |

A **coverage dashboard** built from the result files shows one row per flow: scenarios seen, scenarios with fixtures,
unit / golden / replay green, and open gaps. It answers "which flows are ready for the shadow run" across the estate.

## How it plugs into the agent kit

```
pi/run_flow.sh:  analyst → [gate A] → implementer → (P2: fixtures + golden) → tester → gates G1-G8 → (P3: replay = G9) → reviewer → [gate B]
```

- **P2 sits between the implementer and the tester,** so the tester writes unit tests on recorded inputs, not invented ones.
- **P3 adds gate G9 to `tools/verify_flow.sh`.** A red G9 sends the flow back into the existing fix loop.
- **P0 and P1 are not tied to a flow;** they run per export and on schedule in Jenkins.

## What exists and what is still to build

| Item | Status |
|---|---|
| Steps 1-5 (signatures, SPL, export, traces, fixtures, replay) | **built**, unit-tested on the synthetic sample |
| Mock architecture (compose, broker setup, stub flow) | **built**, not yet run on a real Docker host |
| `replay-config.json` generator from the OSB inventory (selector, topic, queues) + name map | to build: the inventory already extracts these fields |
| Golden-output runner (original XQuery on each `input.payload`, Saxon + fn-bea shim) | to build: reuse the golden-test template of the osb-to-camel skill |
| Jenkins stages: P0 on export push, P1 on cron, P3 as gate G9 in `verify_flow.sh` | to build |
| `run_flow.sh` hook for P2 between implementer and tester | to build |
| Coverage dashboard (static HTML from the result files) | to build |

## First run (pilot flow)

1. **P0 on the pilot project:** check that the signatures and warnings make sense against the pipeline.
2. **P1 with one trace search,** run in the Splunk UI first:
   - confirm that a multi-line payload is one event;
   - confirm the debug lines exist (or don't) in the chosen environment.
3. **Export a week of events, then build traces and scenarios.** Compare the scenario list with the flow card's test matrix.
4. **P2 and P3 with the stub flow first,** then with the real Camel flow image.
KIT_EOF_LOG_REPLAY_DOCS_AUTOMATION_MD
mkdir -p "$(dirname "log-replay/docs/MOCKING_RUNBOOK.md")"
cat > 'log-replay/docs/MOCKING_RUNBOOK.md' <<'KIT_EOF_LOG_REPLAY_DOCS_MOCKING_RUNBOOK_MD'
# Mocking runbook: testing a migrated OSB flow with recorded cases

![mocking workflow](osb_log_replay_p5.png)

"Mocking" means replacing everything outside the Camel flow with something the test controls:

| Outside the flow | In OSB it was | Mocked by |
|---|---|---|
| Input | the proxy's JMS topic/queue (with its selector) | Level 1: `direct:in` · Level 2/3: real Artemis in a container, selector as subscription filter |
| Outputs | the business services that put on queues (success, error queue) | Level 1: `mock:success`, `mock:error` · Level 2/3: real queues, read by the test |
| HTTP/SOAP backends | the business services that call HTTP/SOAP | Level 1: `mock:backend` · Level 2/3: WireMock |
| Data source | Splunk / WebLogic logs | not mocked: export once (CSV); `samples/` for development |
| Generated ids, time | `fn-bea:uuid()`, `fn:current-dateTime()` | the correlation id comes from `headers.json`; ignore time fields in comparisons |

All three levels use the **same recorded cases**, produced by the one-time flow (`docs/ONE_TIME_FLOW.md`):

```
parity/<flow>/<scenario>/<trace>/input.payload · headers.json · expected.json · expected-output.xml (golden, optional)
```

## Which level for which flow

| Flow has… | Level 1 | Level 2 | Level 3 |
|---|---|---|---|
| any logic (always) | **yes**, every build | | |
| a JMS selector, durable subscription, transactions, redelivery | yes | **yes** | |
| HTTP/SOAP backends with timeouts / retries / faults | yes (mock replies) | **yes** (WireMock delays, faults) | |
| a built image (Camel K integration or Spring Boot jar) | | | **yes**, before the shadow run |

Start with Level 1: it needs nothing but Maven, and that is where most migration bugs show.

---

## Level 1: unit tests, no Docker

**Goal:** the route's logic for every recorded case, with all boundaries replaced by Camel mock endpoints.

1. **Copy the recorded cases into the module:**
   ```bash
   cp -r work/fixtures/parity <module>/src/test/resources/
   cp work/fixtures/golden/MANIFEST.csv <module>/src/test/resources/golden/MANIFEST.csv
   ```
2. **Copy the template:** `templates/java/RecordedCasesRouteTest.java` → `<module>/src/test/java/<package>/`.
3. **Adapt the constants at the top:**
   - `ROUTE_ID`: the `routeId` of the migrated proxy;
   - `FLOW_DIR`: the folder under `parity/`;
   - `SUCCESS_URI`, `ERROR_URI`, `BACKEND_URI`: patterns of the real endpoints in the route (e.g. `amqp:queue:InboundOrderEventQueue*`).
4. **Add golden outputs:** run the **original** XQuery on each `input.payload` (the osb-to-camel skill's golden test)
   and save the result as `expected-output.xml` next to it.
5. **Run:**
   ```bash
   mvn -q test -Dtest=RecordedCasesRouteTest
   ```
   Test dependencies needed: `camel-test-spring-junit5`, `spring-boot-starter-test`, `xmlunit-assertj3`, Jackson.
6. **Read the result:** one test per recorded case, named after its folder.

| Failure | Meaning |
|---|---|
| expected on `mock:error`, got `mock:success` (or the reverse) | the outcome differs from OSB's for this real message |
| missing header | the error path does not set what OSB's error handler set |
| body differs from expected-output.xml | the transform differs from the original |

**With the agent kit:** the tester role (`/osb-test`) generates this class from the flow card; the recorded cases are
its inputs. Gate G4 runs it.

---

## Level 2: component tests with containers (Docker on the build machine)

**Goal:** prove what mocks cannot:
- the broker-side filter (the old proxy's JMS selector);
- transacted consume and redelivery;
- the headers as they really travel on AMQP;
- backend timeouts and faults.

1. **Test dependencies:** `org.testcontainers:activemq`, `org.testcontainers:junit-jupiter`, `org.wiremock:wiremock-standalone`,
   and `qpid-jms-client` (already present with `camel-amqp`).
2. **Copy the template:** `templates/java/RecordedCasesBrokerIT.java` → `<module>/src/test/java/<package>/`.
3. **Adapt:**
   - the topic, subscription, selector and queue names (from `replay-config.json`);
   - the property keys in `brokerProperties()` that the module uses for the broker URL, user, password and backend base URL.
4. **WireMock stubs:** one per business-service operation, from `templates/wiremock/backend-from-bix.json`:
   - the URL and SOAPAction from the `.bix` and WSDL;
   - the reply from the logs if OSB logged it, else from the OSB test console;
   - a **fault** variant (error path);
   - a **delayed** variant longer than the business-service timeout (retry count from the `.bix`).
5. **Run** (the `*IT` classes run in failsafe; gate G5 of the agent kit):
   ```bash
   mvn -q verify -Dit.test=RecordedCasesBrokerIT
   ```
6. **The template also contains `messagesOutsideTheSelectorAreDropped`.** OSB never logs messages its selector
   rejected, so this negative case comes from the proxy configuration.

---

## Level 3: end-to-end mock architecture (Docker Compose)

**Goal:** the built flow image as a black box, between a mock broker and mock backends, before the shadow run.

```bash
cd osb-log-replay/mock
cp .env.example .env                              # ARTEMIS_PASSWORD, SUT_IMAGE = the flow image
docker compose up -d                              # Artemis + WireMock
./setup_broker.sh                                 # topic, filtered subscription, output queues from replay-config.json
cp ../templates/wiremock/backend-from-bix.json wiremock/mappings/   # adapt first; bodies go to wiremock/__files/
docker compose --profile selftest up -d           # optional first: stub flow proves the harness
docker compose --profile replay run --rm replay   # with the stub: plumbing check
docker compose --profile selftest down
docker compose --profile sut up -d                # the real flow image
docker compose --profile replay run --rm replay   # -> ../work/report/report.json, junit.xml
```

- **The flow image** must take its broker URL, credentials and backend URL from environment variables; map them in
  `docker-compose.yml` (service `sut`).
- **Read `work/report/report.json`:** one line per recorded case and negative case, PASS or FAIL with the reason
  (wrong queue, missing header, body differs, no output).
- **Clean up:** `docker compose --profile sut --profile selftest down -v`.

---

## Troubleshooting

| Symptom | Level | Cause / fix |
|---|---|---|
| `AdviceWith` finds no node for the URI | 1 | the pattern does not match the route's URI; print `context.getRoute(ROUTE_ID)` endpoints and copy the exact prefix |
| route starts consuming from the real broker in the test | 1 | `@UseAdviceWith` missing, or the context was started before advising |
| no message on any queue | 2, 3 | the subscription filter does not match the headers (compare `headers.json` with the selector); or the flow consumes another queue name |
| negative case delivered | 2, 3 | the filter is not on the subscription queue: re-run the queue creation (`setup_broker.sh` or `@BeforeAll`) |
| `queue create` fails | 2, 3 | Artemis CLI options differ in your broker version: run `artemis queue create --help` in the container and adjust |
| body differs only in whitespace/namespace prefixes | 1, 3 | expected: comparisons are canonical; real differences remain after canonicalisation |
| timeouts in replay | 3 | the flow is not connected (check `docker compose logs sut`), or `timeout_s` too low for a cold start |

## Done when

- Level 1 is green for every recorded case of the flow.
- Level 2 is green where the flow has a selector, transactions or backends.
- Level 3 is green on the built image.

Then the flow goes to the shadow run in a real environment (agent kit, TESTING.md) and to sign-off.
KIT_EOF_LOG_REPLAY_DOCS_MOCKING_RUNBOOK_MD
mkdir -p "$(dirname "log-replay/docs/ONE_TIME_FLOW.md")"
cat > 'log-replay/docs/ONE_TIME_FLOW.md' <<'KIT_EOF_LOG_REPLAY_DOCS_ONE_TIME_FLOW_MD'
# One-time flow: from Splunk logs to test cases (pilot)

![one-time flow](osb_log_replay_p3.png)

One engineer runs this once, for one OSB project, to learn what the logs contain and to produce the first test cases.
No CI, no Docker needed. You need:
- Python 3;
- read access to Splunk (UI is enough);
- the OSB project files.

```bash
cd osb-log-replay
mkdir -p work
cp -r <path-to>/<project>-prj osb-src/          # the same OSB files the estimate was counted from
```

## Step 1. Read the logging from the OSB source

```bash
python3 tools/osb_log_signatures.py osb-src -o work/signatures.json
```

Open `work/signatures.json` and answer these four questions before going to Splunk:

| Question | Where to look |
|---|---|
| Which lines does the flow write? | one entry per Log action: `stage`, `pipeline_type` (request / response / error) |
| Which line carries the message (`body`)? At which level? | `roles.payload`, `level`; **debug is usually off in production** |
| Which field ties the lines of one message together? | `roles.correlation` (e.g. `uuId`, `traceId`) |
| Any warnings? | `warnings`: no correlation field, ambiguous split, weak anchor |

## Step 2. Make the Splunk searches

```bash
python3 tools/spl_from_signatures.py work/signatures.json --index <index> --sourcetype <sourcetype> -o work/queries.spl
```

The index and sourcetype of the OSB servers' logs come from whoever owns Splunk. `queries.spl` contains, per flow:
- an **EXPORT** search, to export;
- a **TRACES** search, to look at;
- one search per log line, to check field extraction.

## Step 3. Run the EXPORT search in the Splunk UI

1. Paste the **EXPORT** search for the flow and set the time range to 7–30 days (include a month end if the flow is
   business-cycle dependent).
2. Check three things before exporting:
   - **Lines found?** If not: wrong index or sourcetype, or the flow did not run in that period.
   - **Is the payload line there** (the Log action with `body` from step 1)? If not, see "No payload lines" below.
   - **One event per log line?** Open an event whose message spans several lines: it must be one event, not several.
     If it is split, ask the Splunk owner to fix event breaking for these sources, or ask for the raw WebLogic log
     files (step 4 reads them too).
3. Optional: run the **TRACES** search to see the lines grouped per message.
4. Export: **Export → CSV**. The file must contain the `_time` and `_raw` columns. Save it as `work/events.csv`.

**No payload lines?** In production the debug Log action is usually not written. Options, cheapest first:
- enable debug logging for this proxy in a test environment with production-like traffic and export from there;
- use the Report action or message tracing if they are already enabled for the service;
- or accept the gap: you still get scenarios and frequencies from the other lines, and inputs must come from
  elsewhere (OSB test console).

## Step 4. Analyse

```bash
python3 tools/osb_log_traces.py work/signatures.json work/events.csv -o work/traces
```

What it does:
- removes the WebLogic header from each line;
- matches the lines to the signatures;
- masks personal data with the data owner's key (`MASK_KEY`): names (incl. Arabic/English variants), addresses/remarks, birth dates (shifted, age band kept), e-mails, phone numbers, identity numbers, IBANs, in JSON and XML; the same value always gives the same mask with the same key; the raw input is deleted afterwards (`--delete-input`) and `tools/mask_residue_check.py` must report 0 findings before the fixtures leave the secure environment;
- groups the lines into one trace per message and classifies the traces.

Read:
- `work/traces/coverage.json`:
  - lines matched vs. read;
  - traces without payload;
  - Log actions never seen in the period.
- `work/traces/scenarios.json`: scenarios by frequency, in the form `flow | success or error | header values | errorCode`.

## Step 5. Decide

- **Compare the scenarios with the flow card's test matrix.** A scenario in the logs but not on the card is a missing
  test; a card row never seen in the logs needs a reason (rare branch, or dead code).
- **Pick what to test:** the top scenarios (most of the traffic) plus every error code.
- **Write down the gaps:** no payload, never-seen lines. Each gap gets an owner or a decision.

## Step 6. Produce the test cases

Fill `replay-config.json` for the flow: the output queues per outcome, and the error headers OSB sets. Then:

```bash
python3 tools/fixtures_from_traces.py work/traces/traces.jsonl replay-config.json -o work/fixtures --per-scenario 3
```

Result: `work/fixtures/parity/<flow>/<scenario>/<trace>/` with `input.payload`, `headers.json` and `expected.json`, plus
`work/fixtures/golden/MANIFEST.csv` (every file marked as recorded from OSB).

Then, with the agent kit in pi:
1. **Golden output for each test case:** run the **original** XQuery of the flow on each `input.payload` (the
   osb-to-camel skill's golden test) and save the result as `expected-output.xml` next to it. The logs do not contain
   the output; the original transform is the reference.
2. **Unit tests:** copy `work/fixtures/parity` and `golden/MANIFEST.csv` into the Camel module's `src/test/resources`,
   then run `/osb-test`. The tester writes the unit tests with these recorded inputs.
3. **Optional, end-to-end:** if Docker is available, replay the test cases on the mock architecture (`README.md`,
   "E2E replay").

Shortcut for steps 1, 2, 4 and 6 in one go, once you have `events.csv`:

```bash
SPLUNK_INDEX=<index> SPLUNK_SOURCETYPE=<sourcetype> ./run_offline.sh osb-src work/events.csv work
```

## What to send back after the pilot

- `coverage.json` and `scenarios.json`;
- the list of gaps and the decisions taken;
- the number of test cases produced per scenario;
- whether the payload line was available, and in which environment.

That decides whether the method scales to the other flows as it is, or needs debug logging switched on first.
KIT_EOF_LOG_REPLAY_DOCS_ONE_TIME_FLOW_MD
mkdir -p "$(dirname "log-replay/docs/WORKFLOW.md")"
cat > 'log-replay/docs/WORKFLOW.md' <<'KIT_EOF_LOG_REPLAY_DOCS_WORKFLOW_MD'
# From OSB logs to tests: the method

The goal: test cases for each migrated Camel flow that come from what OSB really processed in production, not from what
someone thinks it processed. Logs are the evidence; the OSB source tells you how to read them.

```
 OSB source ──► 1 log signatures ──► 2 Splunk searches ──► 3 traces + scenarios ──► 4 fixtures ──► 5 tests
 (.pipeline)     what each Log        anchors + rex           group by correlation     per scenario,     unit (agent) ·
                 action writes                                 id, classify, mask       MANIFEST          golden (original
                                                                                                          XQuery) · e2e replay
```

## 1. Read the logging contract from the source first

Start in the OSB export, not in Splunk. Every **Log action** in a pipeline is an XQuery expression, almost always an
`fn:concat` of fixed text and variables:

```xquery
fn:concat("Request Received to Project order-event-prj :: ... TraceID - ", $uuId, " ::", $body)
```

`tools/osb_log_signatures.py` turns each one into a **signature**:
- **a regex** with one named group per variable part;
- **the longest fixed text** as the search anchor;
- **the role of each group:**

| Group comes from | Name | Role |
|---|---|---|
| `$uuId`, `$traceId`, `$messageID` … | `uuId` | correlation id: groups lines into one trace |
| `$inbound/.../user-header[@name="resource"]/@value` | `hdr_resource` | JMS/transport header: becomes a test header and a scenario dimension |
| `$body` | `body` | the request payload: becomes the test input |
| `$body//*:referenceNo/text()` | `body_referenceNo` | business key: helps pick and check cases |
| `$fault` / `fn-bea:serialize($fault)` | `fault` | error path: fault code and reason |

What the source tells you before you search anything:

- **Which lines can exist at all.**
  - A flow with no Log action that writes the correlation id cannot be traced.
  - A flow that never logs `$body` gives you no inputs.
- **Log levels.** A `debug` Log action only writes if the OSB logging level for that service allows it. In production
  it usually does not, and the payload line is very often the debug one. The extractor warns about this.
- **Where the line is written.**
  - OSB Log actions go to the WebLogic server log (and its diagnostic log): one event per action, with the OSB text
    after the WebLogic header.
  - Other OSB sources exist; check which ones are switched on:
    - **Report actions** go to the reporting data stream (JMS reporting provider, reporting tables) and often hold the full message with report keys.
    - **Pipeline alerts** go to alert destinations.
    - **Message tracing** writes full messages when enabled on a service.
- **What is never logged.** The message OSB sends to the backend or queue is usually not logged, and neither is a
  message rejected by the proxy's JMS selector (it never reaches the pipeline). The first needs another oracle; the
  second needs tests from the proxy configuration.

## 2. Find the lines in Splunk

`tools/spl_from_signatures.py` writes:
- one search per signature: anchor plus `rex` with the same fields;
- one **trace search** per flow that groups all its lines by correlation id.

Before trusting a search:

- **Ask the Splunk owner for the index and sourcetype** of the OSB servers' logs. They are rarely the defaults.
- **Check event breaking.** WebLogic events start with `####<` and can span many lines (pretty-printed payloads). If
  the sourcetype breaks on newlines, a payload arrives as many events and `rex` sees only the first line. Look at one
  event with a multi-line body before exporting.
- **Check truncation.** Long events are cut at the sourcetype's truncation limit; a truncated payload is not a valid
  test input. The trace builder keeps such inputs, but they fail when parsed: look at `has_payload`, and treat
  unparseable bodies as an extraction problem, not a test case.
- **Pick a time range that covers a business cycle** (month end, batch days), not just the last hour.
- **Export only `_raw` and `_time`**, via `tools/splunk_export.py` (REST, token from the environment) or a CSV
  export from the UI.

## 3. Rebuild traces and scenarios

`tools/osb_log_traces.py`:
1. takes the OSB text out of its envelope. Two formats: the classic WebLogic server log (`####<…> <BEA-000000> <…>`) and the
   OSB 12c **ODL** diagnostic log (`[time] [server] [LEVEL] … [ecid: …] [FlowId: …]  [stage, pipeline, REQUEST] text`). From ODL
   it also keeps the `ecid`, which ties all lines of one OSB request together, used when the text has no trace id;
2. matches the signatures (the most specific match wins);
3. **masks personal data deterministically**, including JSON fields with names, birth dates and identity numbers (add
   client-specific fields with `--mask-json-key`): the same input gives the same masked value, so masked keys still join
   across lines;
4. groups by correlation id and classifies each trace:
   - **outcome:** `error` if any error-pipeline line exists, else `success`;
   - **branch:** header values such as `resource` and `eventType`, or any `--dims`;
   - **fault code** (`BEA-38xxxx` and friends) for errors.

Read `coverage.json` before going further:

| Field | Meaning | Action |
|---|---|---|
| `signatures_never_seen` | Log actions with no line in the time range | Wrong index/time range, level filtered, or a branch that never runs; ask before writing tests for it |
| `traces_without_payload` | Traces where the payload line is missing | Usually debug logging off; see "When logs are not enough" |
| `events_without_correlation` | Matched lines with no correlation value | The pipeline assigns the id after this log action; fix by reading the stage order |
| `events_unmatched` | Lines from other sources | Normal; a high count with few matches means the anchors are wrong |

`scenarios.json` lists scenarios by frequency. The top few usually cover most of the traffic; the rare ones (error
codes, unusual branches) are where migrations break.

## 4. Write fixtures

`tools/fixtures_from_traces.py` takes up to N traces per scenario (with a payload) and writes `input.payload`,
`headers.json` and `expected.json`. Every file is registered in `golden/MANIFEST.csv` with source `osb-recording`,
the provenance gate G7 of the agent kit accepts.

`expected.json` holds what the logs prove: the outcome, the destination of that outcome, the fault code, the headers
the error path must carry, and the business keys. It does **not** hold the output body, because OSB rarely logs it.

## 5. Build the tests in three layers

| Layer | From | Proves | Runs |
|---|---|---|---|
| **Unit** (the base, written by the agent's tester role) | the flow card's test matrix, the fixture inputs | every branch and error path of the route with all backends mocked | every build |
| **Golden** | fixture inputs run through the **original** XQuery/XSLT (Saxon + fn-bea shim) | the migrated transform produces what OSB produced, quirks included | every build |
| **E2E replay** | fixtures, against the mock architecture | broker filter, routing, error queue headers, end-to-end shape with the real Camel flow | per change of the flow |

Then the shadow run in a real environment (see the agent kit's TESTING.md) closes the loop on live traffic.

The oracle rule: an expected value comes from OSB (logs, recorded messages, the original transform), never from
running the new Camel code.

## The mock architecture (E2E replay)

```
 replay_runner ──publish──► Artemis: orderEventsTopic ──filter──► order-event-sub ──► Camel flow under test ──► InboundOrderEventQueue
      ▲                                (multicast)                 (durable, FQQN)       (Camel K or Spring Boot) └──► orderEventErrorQueue
      └──────────────────────────── waits for the same correlation id on the output queues ◄──────────────────────┘
                                                        WireMock: HTTP/SOAP backends the flow calls
```

- `mock/setup_broker.sh` creates the broker objects from `replay-config.json`:
  - the input address;
  - the subscription queue, with **the proxy's JMS selector as its broker-side filter**;
  - the output queues.

  The filter is part of what is tested.
- The flow under test runs from its own image (`SUT_IMAGE`) against the mock broker and WireMock.
- Negative cases (messages the selector must drop) come from `replay-config.json`, because OSB never logged them.
- `sut-stub` is a forwarding stub that proves the harness before the real flow exists.

## When logs are not enough

| Gap | Option, cheapest first |
|---|---|
| Payload line is debug and off in production | Enable debug logging for the specific services in a test environment with production-like traffic; or use the Report action / message tracing if already enabled |
| Output body not logged | Golden tests with the original XQuery (preferred); a non-exclusive copy (divert) of the OSB output queue during the shadow run |
| Payloads truncated or split | Fix the sourcetype's event breaking for these sources, or read the WebLogic log files directly (the trace builder reads raw logs) |
| No correlation id in the log text | Add it to the first Log action in a test environment, or correlate by business key (`body_*` fields) with a time window |
| Personal data | Mask at extraction (the trace builder does), review a sample before fixtures leave the secure environment |
KIT_EOF_LOG_REPLAY_DOCS_WORKFLOW_MD
chmod +x log-replay/tools/*.py log-replay/*.sh log-replay/mock/*.sh 2>/dev/null || true
echo "installed: 26 files (log replay tools)"
