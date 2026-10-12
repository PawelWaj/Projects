#!/usr/bin/env python3
"""G6: every test-matrix row (T1..Tn) of the flow card has at least one test that names it.

A test "names" a row when the ID appears as a whole token in the test sources, e.g. @DisplayName("T3 filter ...")
or a method t3_filterRejectsCreated(). T1 does not match T10.
Exit 0 = all rows covered, 1 = rows missing, 2 = usage / input error.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROW_ID = re.compile(r"^\|\s*(T\d+)\s*\|", re.MULTILINE)


def matrix_ids(card: Path) -> list[str]:
    text = card.read_text(encoding="utf-8")
    match = re.search(r"^##\s*8\..*?$(.*?)(^##\s|\Z)", text, re.MULTILINE | re.DOTALL)
    section = match.group(1) if match else text
    return sorted(set(ROW_ID.findall(section)), key=lambda s: int(s[1:]))


def covered(test_text: str, row: str) -> bool:
    num = row[1:]
    return re.search(rf"(?<![A-Za-z0-9])[Tt]{num}(?![0-9])", test_text) is not None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("card", type=Path)
    ap.add_argument("test_dir", type=Path, help="e.g. <module>/src/test/java")
    args = ap.parse_args()
    if not args.card.is_file() or not args.test_dir.is_dir():
        print(json.dumps({"gate": "G6", "status": "ERROR", "detail": "card or test dir not found"}))
        return 2
    ids = matrix_ids(args.card)
    if not ids:
        print(json.dumps({"gate": "G6", "status": "FAIL", "detail": "no T-rows found in card section 8"}))
        return 1
    sources = "\n".join(p.read_text(encoding="utf-8", errors="replace")
                        for p in args.test_dir.rglob("*") if p.suffix in {".java", ".kt", ".groovy", ".yaml", ".yml"})
    missing = [r for r in ids if not covered(sources, r)]
    status = "PASS" if not missing else "FAIL"
    print(json.dumps({"gate": "G6", "status": status, "rows": len(ids), "missing": missing}))
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
