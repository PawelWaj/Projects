#!/usr/bin/env python3
"""Gate before a research pack leaves the VDI: nothing sensitive and no verbatim source code.

    research_check.py research/<proxy> [--allow-host example.com]...

Scans every .md/.json/.txt/.csv in the folder. Fails (exit 1) on:
  host    URLs with a host that is not an XML namespace of the flow or an allowed public host; name.domain:port; IPv4
  secret  password/secret/token/api key assignments, private keys
  pii     numbers with 9+ digits, e-mail addresses, Arabic script
  code    verbatim OSB source: XQuery/XSLT/XSD/WSDL/OSB XML markers, or a fenced code block longer than 12 lines
Prints findings as file:line + rule + a 3-character preview (never the full value) and writes SHARE_CHECK.json
(pass/fail, counts per rule, sha256 per file) into the folder. Share the folder only when it passes. Stdlib only."""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

PUBLIC = {"www.w3.org", "w3.org", "xmlns.oracle.com", "www.bea.com", "schemas.xmlsoap.org", "camel.apache.org",
          "docs.oracle.com", "example.com", "www.example.com", "json-schema.org"}
RULES = [
    ("host", re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")),
    ("host", re.compile(r"\b[A-Za-z][\w-]*(?:\.[\w-]+)+:\d{2,5}\b")),
    ("secret", re.compile(r"(?i)\b(?:password|passwd|pwd|secret|token|api[_-]?key|client[_-]?secret)\b\s*[\"']?\s*[:=]\s*[\"']?[^\s\"',}]{3,}")),
    ("secret", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("pii", re.compile(r"(?<![\w.-])\d{9,}(?![\w-])")),
    ("pii", re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")),
    ("pii", re.compile(r"[\u0600-\u06FF]")),
    ("code", re.compile(r"(?i)xquery\s+version|declare\s+(?:function|variable|namespace)\s|<xsl:|<xsd?:(?:schema|element|complexType)"
                        r"|<(?:con|ser|tran|jms|http|wsdl|soapenv|env):[A-Za-z]")),
]
URL = re.compile(r"\b[a-zA-Z][a-zA-Z0-9+.-]*://([^/\s\"'<>)|]+)")


def namespace_hosts(folder: Path) -> set[str]:
    hosts = set()
    for f in folder.glob("*.json"):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except ValueError:
            continue
        stack = [data]
        while stack:
            o = stack.pop()
            if isinstance(o, dict):
                for k, v in o.items():
                    if k == "namespaces" and isinstance(v, list):
                        hosts |= {m.group(1).lower() for n in v if isinstance(n, dict) and (m := URL.match(str(n.get("uri", ""))))}
                    else:
                        stack.append(v)
            elif isinstance(o, list):
                stack.extend(o)
    return hosts


def scan(f: Path, allowed: set[str]) -> list[tuple[str, int, str]]:
    found, fence, fence_start = [], False, 0
    for n, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if line.strip().startswith("```"):
            if fence and n - fence_start - 1 > 12:
                found.append(("code", fence_start, "fenced block of %d lines" % (n - fence_start - 1)))
            fence, fence_start = (not fence), n
        for m in URL.finditer(line):
            host = m.group(1).split("@")[-1].split(":")[0].lower()
            if host and host not in allowed and not any(host.endswith("." + p) for p in PUBLIC):
                found.append(("host", n, m.group(0)[:3] + "***"))
        for rule, rx in RULES:
            for m in rx.finditer(line):
                found.append((rule, n, m.group(0)[:3] + "***"))
    return found


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", type=Path)
    ap.add_argument("--allow-host", action="append", default=[])
    a = ap.parse_args()
    allowed = PUBLIC | {h.lower() for h in a.allow_host} | namespace_hosts(a.folder)
    files = sorted(p for p in a.folder.rglob("*") if p.is_file() and p.suffix.lower() in (".md", ".json", ".txt", ".csv")
                   and p.name != "SHARE_CHECK.json")
    findings = []
    for f in files:
        findings += [(f.relative_to(a.folder).as_posix(), *x) for x in scan(f, allowed)]
    counts = {}
    for _, rule, _, _ in findings:
        counts[rule] = counts.get(rule, 0) + 1
    result = {"pass": not findings, "files": {f.relative_to(a.folder).as_posix(): hashlib.sha256(f.read_bytes()).hexdigest()
                                              for f in files},
              "findings_per_rule": counts, "namespace_hosts_allowed": sorted(namespace_hosts(a.folder))}
    (a.folder / "SHARE_CHECK.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    for path, rule, line, preview in findings[:200]:
        print(f"{path}:{line}: {rule}: {preview}")
    print(f"{'PASS' if not findings else 'FAIL'}: {len(files)} files, {len(findings)} findings {counts or ''}")
    return 0 if not findings else 1


if __name__ == "__main__":
    sys.exit(main())
