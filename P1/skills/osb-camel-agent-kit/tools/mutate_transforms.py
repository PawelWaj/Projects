#!/usr/bin/env python3
"""G8: break each transform on purpose; the golden tests must fail for every mutant.

Mutants (one at a time, original restored after each run, even on error or Ctrl-C):
  XQuery: the content of an element constructor  >{ expr }<  becomes  >{"__MUTANT__"}<
  XSLT:   the select of an <xsl:value-of select="..."/> becomes  select="'__MUTANT__'"
Up to --per-file mutants per transform. A mutant "survives" when the test command exits 0.
Exit 0 = all mutants killed, 1 = survivors or no mutants, 2 = usage error.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

XQ_SITE = re.compile(r">\{([^{}]+)\}<")
XSL_SITE = re.compile(r"(<xsl:value-of\s+select=)\"([^\"]+)\"")


def mutants(text: str, suffix: str, limit: int) -> list[str]:
    out = []
    if suffix in {".xqy", ".xq", ".xquery"}:
        for m in list(XQ_SITE.finditer(text))[:limit]:
            out.append(text[:m.start()] + '>{"__MUTANT__"}<' + text[m.end():])
    elif suffix in {".xsl", ".xslt"}:
        for m in list(XSL_SITE.finditer(text))[:limit]:
            out.append(text[:m.start()] + m.group(1) + "\"'__MUTANT__'\"" + text[m.end():])
    return out


def run_tests(cmd: list[str], cwd: Path, timeout: int) -> bool:
    """True when the tests pass (mutant survived)."""
    try:
        res = subprocess.run(cmd, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False
    return res.returncode == 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("module", type=Path)
    ap.add_argument("--per-file", type=int, default=3)
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--test-cmd", default="mvn -q -Dtest=*GoldenTest*,*RouteTest* -Dsurefire.failIfNoSpecifiedTests=false test")
    args = ap.parse_args()
    main_res = args.module / "src" / "main" / "resources"
    if not main_res.is_dir():
        print(json.dumps({"gate": "G8", "status": "ERROR", "detail": f"{main_res} not found"}))
        return 2
    cmd = args.test_cmd.split()
    cmd[0] = shutil.which(cmd[0]) or cmd[0]  # resolves mvn.cmd on Windows
    results = []
    for f in sorted(p for p in main_res.rglob("*") if p.suffix in {".xqy", ".xq", ".xquery", ".xsl", ".xslt"}):
        original = f.read_text(encoding="utf-8")
        backup = f.with_suffix(f.suffix + ".g8bak")
        shutil.copy2(f, backup)
        try:
            for i, mutant in enumerate(mutants(original, f.suffix, args.per_file), 1):
                f.write_text(mutant, encoding="utf-8")
                survived = run_tests(cmd, args.module, args.timeout)
                results.append({"file": f.relative_to(args.module).as_posix(), "mutant": i,
                                "result": "SURVIVED" if survived else "KILLED"})
        finally:
            shutil.move(backup, f)
    survivors = [r for r in results if r["result"] == "SURVIVED"]
    status = "PASS" if results and not survivors else "FAIL"
    detail = "no mutable transform sites found" if not results else ""
    print(json.dumps({"gate": "G8", "status": status, "mutants": len(results), "survivors": survivors,
                      "detail": detail}))
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
