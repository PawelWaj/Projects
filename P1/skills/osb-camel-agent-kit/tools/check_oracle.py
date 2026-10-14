#!/usr/bin/env python3
"""G7: every expected-output fixture comes from OSB, not from the generated Camel code.

Checks every file under <resources>/golden and <resources>/parity against <resources>/golden/MANIFEST.csv
(columns: file,source,flow,captured_by,date[,sha256,key_id,source_ref,reason,approved_by]; file relative to <resources>).
Sources card-rule and source-derived (not observed in OSB) need reason and approved_by.
Exit 0 = clean, 1 = violations, 2 = usage / input error.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))

ALLOWED = {"osb-recording", "original-transform", "osb-test-console", "card-rule", "source-derived"}
NEEDS_APPROVAL = {"card-rule", "source-derived"}        # not observed in OSB: a reason and a named approver are mandatory
FIXTURE_DIRS = ("golden", "parity")
IGNORED = {"MANIFEST.csv", "ignore-fields.txt", "README.md", ".gitkeep"}


def load_manifest(path: Path) -> dict[str, dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as fh:
        return {row["file"].strip(): row for row in csv.DictReader(fh)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("resources", type=Path, help="e.g. <module>/src/test/resources")
    args = ap.parse_args()
    manifest_path = args.resources / "golden" / "MANIFEST.csv"
    fixtures = [p for d in FIXTURE_DIRS if (args.resources / d).is_dir()
                for p in (args.resources / d).rglob("*") if p.is_file() and p.name not in IGNORED]
    if not fixtures:
        print(json.dumps({"gate": "G7", "status": "FAIL", "detail": "no golden/parity fixtures found"}))
        return 1
    if not manifest_path.is_file():
        print(json.dumps({"gate": "G7", "status": "FAIL", "detail": "golden/MANIFEST.csv missing"}))
        return 1
    try:
        manifest = load_manifest(manifest_path)
    except (KeyError, csv.Error) as exc:
        print(json.dumps({"gate": "G7", "status": "ERROR", "detail": f"bad manifest: {exc}"}))
        return 2
    unlisted, bad_source = [], []
    for p in fixtures:
        rel = p.relative_to(args.resources).as_posix()
        row = manifest.get(rel)
        if row is None:
            unlisted.append(rel)
        elif row.get("source", "").strip() not in ALLOWED:
            bad_source.append(f"{rel} ({row.get('source', '').strip() or 'empty'})")
        elif row.get("source", "").strip() in NEEDS_APPROVAL and not (
                (row.get("reason") or "").strip() and (row.get("approved_by") or "").strip()):
            bad_source.append(f"{rel} ({row['source'].strip()}: reason and approved_by required)")
    ok = not unlisted and not bad_source
    print(json.dumps({"gate": "G7", "status": "PASS" if ok else "FAIL", "fixtures": len(fixtures),
                      "unlisted": unlisted, "bad_source": bad_source, "allowed_sources": sorted(ALLOWED)}))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
