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
