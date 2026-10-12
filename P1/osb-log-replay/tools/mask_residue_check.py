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
