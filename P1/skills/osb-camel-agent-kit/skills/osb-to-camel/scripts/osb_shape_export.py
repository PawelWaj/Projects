#!/usr/bin/env python3
"""Shape-only copy of an OSB project, shareable outside the client machine: keeps every structural fact the migration
tooling needs (which actions, how they nest, which attributes, which functions, which files reference which) and
replaces every business-specific value by a consistent token. Stdlib only.

    osb_shape_export.py <osb project folder> -o <out folder> [--salt <text>]

Kept as is:    XML element and attribute names, structural attribute values (type, contents-only, varName, id,
               xsi:type, maxOccurs, minOccurs, nxsd:version, nxsd:jsonNestedArray ...), numbers, XQuery/XPath syntax,
               function calls (fn:, fn-bea:, xs:, local:), variable names, OSB namespaces (bea.com, oracle.com, w3.org).
Tokenised:     file and folder names, ref="..." paths, stage/branch/pipeline names, service names, business
               namespaces, element names inside XQuery/XSD/XPath, header names, queue/JNDI names, URLs, hosts.
               Same original -> same token (sha256 with --salt), so cross-references still line up.
Replaced:      string literals in expressions -> 's1', 's2' ... (per distinct value), comments dropped.
Result:        the same file tree with the same extensions; a MANIFEST.json with counts per action type and per
               fn-bea function (no originals). Review the output once before sharing; the mapping is NOT written."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from collections import Counter
from pathlib import Path

KEEP_NS = ("bea.com", "oracle.com", "w3.org", "xmlsoap.org", "xml.org", "schemas.xmlsoap.org")
KEEP_ATTR = {"type", "contents-only", "id", "xsi:type", "maxOccurs", "minOccurs", "use", "nillable",
             "elementFormDefault", "attributeFormDefault", "version", "encoding", "errorHandler", "error-handler",
             "mixed", "abstract", "value"}
KEEP_ATTR_PREFIX = ("nxsd:", "xmlns")
STRUCT_VALUES = {"true", "false", "request", "response", "error", "Native-To-XML", "XML-To-Native", "unbounded", "qualified",
                 "unqualified", "expression", "Text", "Binary", "XML", "JSON", "ref:BusinessServiceRef", "ref:ProxyRef",
                 "ref:PipelineRef", "ref:XqueryRef", "ref:XsdRef", "ref:WsdlRef", "ref:XsltRef", "ref:MflRef", "ref:ServiceAccountRef",
                 "ref:JarRef", "ref:ArchiveRef"}
FUNC_PREFIX = ("fn:", "fn-bea:", "xs:", "xsd:", "xsi:", "ctx:", "con:", "con1:", "con2:", "con3:", "tp:", "http:", "jms:", "env:",
               "soap-env:", "xdt:", "math:", "map:", "array:", "jms-ctx:")          # OSB context / vendor prefixes: structural
KEEP_VARS = {"body", "inbound", "outbound", "fault", "header", "request", "response", "attachments", "operation", "uuId", "uuid"}
SYNTAX = set("""xquery version encoding declare namespace variable function external return let for where order by if then else
  element attribute node text document data concat string number count sum exists empty not and or div mod eq ne lt gt le ge
  true false as at import schema default collation boundary-space preserve strip option local fn xs xsi xsd typeswitch case
  satisfies some every instance of castable cast treat union intersect except to ascending descending null""".split())
TAG_RX = re.compile(r"<(/?)([A-Za-z_][\w.-]*:)?([A-Za-z_][\w.-]*)")
ATTR_RX = re.compile(r'\s([A-Za-z_][\w:.-]*)="([^"]*)"')
STRING_RX = re.compile(r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"")
IDENT_RX = re.compile(r"(?<![\w:$-])([A-Za-z_][\w.-]*):([A-Za-z_][\w.-]*)|(?<![\w:$-])\*:([A-Za-z_][\w.-]*)")
VAR_RX = re.compile(r"\$([A-Za-z_][\w.-]*)")
STEP_RX = re.compile(r"(?<=/)(@?)([A-Za-z_][\w.-]*)(?![\w(:.-])")
URL_RX = re.compile(r"[a-z][a-z0-9+.-]*://[^\s\"'<>]+")
COMMENT_XML = re.compile(r"<!--.*?-->", re.S)
EXPR_TAGS = {"xqueryText", "xpathText", "condition", "expr", "javaScript", "javascript", "xqueryTextExpr", "script", "value"}
COMMENT_XQ = re.compile(r"\(:.*?:\)", re.S)


class Tok:
    def __init__(self, salt: str):
        self.salt, self.strings, self.counts = salt, {}, Counter()

    def name(self, s: str, kind: str = "n") -> str:
        if not s:
            return s
        h = hashlib.sha256((self.salt + "|" + s).encode("utf-8")).hexdigest()[:8]
        return f"{kind}{h}"

    def string(self, s: str) -> str:
        if s not in self.strings:
            self.strings[s] = f"s{len(self.strings) + 1}"
        return self.strings[s]

    def path(self, p: str) -> str:
        parts = p.replace("\\", "/").split("/")
        out = []
        for part in parts:
            stem, dot, ext = part.rpartition(".")
            out.append(self.name(stem, "f") + dot + ext if dot and len(ext) <= 12 else self.name(part, "f"))
        return "/".join(out)


def keep_ns(uri: str) -> bool:
    return any(k in uri for k in KEEP_NS)


def tok_expr(text: str, t: Tok) -> str:
    """XQuery / XPath text: keep syntax and functions, tokenise business names and literals."""
    text = COMMENT_XQ.sub("", text)
    text = STRING_RX.sub(lambda m: "'" + t.string(m.group(0)[1:-1]) + "'", text)
    text = URL_RX.sub(lambda m: m.group(0) if keep_ns(m.group(0)) else "http://" + t.name(m.group(0), "ns") + "/", text)

    def ident(m):
        if m.group(3):                      # *:name
            return "*:" + t.name(m.group(3), "e")
        pfx, local = m.group(1), m.group(2)
        if (pfx + ":") in FUNC_PREFIX:
            return m.group(0)               # function, type or OSB context element: keep
        if pfx == "local":
            return "local:" + t.name(local, "fn")
        return f"{pfx}:{t.name(local, 'e')}"
    text = IDENT_RX.sub(ident, text)
    text = re.sub(r"&lt;(/?)([A-Za-z_][\w.-]*:)?([A-Za-z_][\w.-]*)",            # escaped element constructors in expressions
                  lambda m: f"&lt;{m.group(1)}{m.group(2) or ''}{t.name(m.group(3), 'e')}", text)
    text = re.sub(r"&gt;([^&{}<>$]+?)&lt;", lambda m: "&gt;" + (m.group(1) if not m.group(1).strip() or re.fullmatch(r"[\d\s.-]+", m.group(1)) else t.name(m.group(1).strip(), "t")) + "&lt;", text)
    text = VAR_RX.sub(lambda m: m.group(0) if m.group(1) in KEEP_VARS else "$" + t.name(m.group(1), "v"), text)
    return STEP_RX.sub(lambda m: m.group(0) if m.group(2) in SYNTAX else m.group(1) + t.name(m.group(2), "e"), text)


def tok_xml(text: str, t: Tok, counts: Counter) -> str:
    text = COMMENT_XML.sub("", text)
    out, pos, last = [], 0, ""
    for m in re.finditer(r"<[^>]+>", text):
        between = text[pos:m.start()]
        v = between.strip()
        if not v:
            out.append(between)
        elif last in EXPR_TAGS:
            out.append(tok_expr(between, t))
        elif v in STRUCT_VALUES or re.fullmatch(r"-?\d+(\.\d+)?", v) or keep_ns(v):
            out.append(between)
        else:
            out.append(between.replace(v, t.name(v, "t")))
        tag = m.group(0)
        tm0 = TAG_RX.match(tag)
        if tm0 and not tm0.group(1):
            last = tm0.group(3)
        if tag.startswith("<?") or tag.startswith("<!"):
            out.append(tag)
        else:
            tm = TAG_RX.match(tag)
            if tm and not tm.group(1):
                counts[tm.group(3)] += 1

            def attr(a):
                k, v = a.group(1), a.group(2)
                if k in ("select", "match", "test", "use-when"):
                    return f' {k}="{tok_expr(v, t)}"'
                if k.startswith(KEEP_ATTR_PREFIX):
                    return f' {k}="{v if keep_ns(v) else "http://" + t.name(v, "ns") + "/"}"' if k.startswith("xmlns") and v else a.group(0)
                if v in STRUCT_VALUES or re.fullmatch(r"-?\d+(\.\d+)?", v):
                    return a.group(0)
                if k in ("type", "base", "ref") and tm and tm.group(2) and tm.group(2).rstrip(":") in ("xs", "xsd"):
                    pfx, _, local = v.rpartition(":")
                    return a.group(0) if pfx in ("xs", "xsd") else f' {k}="{pfx + ":" if pfx else ""}{t.name(local, "e")}"'
                if k in KEEP_ATTR and k != "type":
                    return a.group(0)
                if k == "type":
                    pfx, _, local = v.rpartition(":")
                    return a.group(0) if pfx in ("xs", "xsd") or not pfx and v in STRUCT_VALUES else f' {k}="{pfx + ":" if pfx else ""}{t.name(local, "e")}"'
                if k == "ref":
                    return f' ref="{t.path(v)}"'
                if k in ("varName", "variable", "var") :
                    return a.group(0) if v in KEEP_VARS else f' {k}="{t.name(v, "v")}"'
                if k == "name" and tm and tm.group(3) in ("element", "attribute", "complexType", "simpleType", "group"):
                    return f' name="{t.name(v, "e")}"'
                return f' {k}="{t.name(v)}"'
            out.append(ATTR_RX.sub(attr, tag))
        pos = m.end()
    tail = text[pos:]
    out.append(tok_expr(tail, t) if tail.strip() else tail)
    return "".join(out)


def tok_xquery(text: str, t: Tok) -> str:
    text = COMMENT_XQ.sub("", text)
    head = re.match(r'\s*xquery version "[^"]*"( encoding "[^"]*")?;', text)
    keep_head = head.group(0) if head else ""
    text = text[len(keep_head):]
    # element constructors <ns:name ...> inside XQuery: tokenise local names, keep namespaces of known vendors
    def tag(m):
        slash, pfx, local = m.group(1), m.group(2) or "", m.group(3)
        return f"<{slash}{pfx}{t.name(local, 'e')}"
    text = TAG_RX.sub(tag, text)
    text = re.sub(r'declare namespace (\w+)="([^"]*)"', lambda m: f'declare namespace {m.group(1)}="{m.group(2) if keep_ns(m.group(2)) else "http://" + t.name(m.group(2), "ns") + "/"}"', text)
    text = re.sub(r'import schema (namespace \w+=)?"[^"]*" at "([^"]*)"', lambda m: f'import schema {m.group(1) or ""}"http://{t.name(m.group(0), "ns")}/" at "{t.path(m.group(2))}"', text)
    return keep_head + tok_expr(text, t)


def residue(src: Path, out: Path) -> list:
    """Words of 4+ letters left in the output that are not XML element/attribute names of the output (structural, kept
    by design), not syntax, not vendor namespaces and not generated tokens. Whatever is listed came through
    untokenised and must be checked by a person before the folder is shared."""
    words = lambda t: set(re.findall(r"[A-Za-z][A-Za-z]{3,}", t))
    pieces = lambda names: {w for n in names for w in re.findall(r"[A-Za-z][A-Za-z]{3,}", n)}
    outw, struct = set(), set()
    for f in out.rglob("*"):
        if f.is_file() and f.name != "MANIFEST.json":
            t = f.read_text(encoding="utf-8")
            outw |= words(t)
            struct |= pieces(re.findall(r"<[/]?(?:[\w.-]+:)?([A-Za-z_][\w.-]*)", t)) | pieces(re.findall(r"\s([A-Za-z_][\w:.-]*)=\"", t))
            struct |= pieces(re.findall(r'\s(?:xsi:type|type|use|version|encoding)="([^"]*)"', t))
    vendor = words(" ".join(KEEP_NS)) | {"http", "https", "www", "schemas", "xmlsoap", "xmlns", "soap", "envelope", "wsdl", "wli"}
    token = re.compile(r"^(?:[efntv]|fn|ns|p)[0-9a-f]{8}$")
    return sorted(w for w in outw - struct - vendor
                  if w.lower() not in SYNTAX and w not in STRUCT_VALUES and not token.match(w) and not re.fullmatch(r"[a-f]+", w))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("project", type=Path)
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--salt", default="osb-shape", help="changes every token; keep it private, it is not stored")
    a = ap.parse_args()
    if a.out.exists():
        shutil.rmtree(a.out)
    t = Tok(a.salt)
    counts: Counter = Counter()
    fnbea: Counter = Counter()
    files = 0
    for f in sorted(p for p in a.project.rglob("*") if p.is_file()):
        rel = f.relative_to(a.project)
        dst = a.out / Path(t.path(str(rel.parent))) / (t.name(f.stem, "f") + f.suffix.lower()) if str(rel.parent) != "." else a.out / (t.name(f.stem, "f") + f.suffix.lower())
        dst.parent.mkdir(parents=True, exist_ok=True)
        ext = f.suffix.lower()
        try:
            text = f.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            dst.with_suffix(ext + ".binary").write_text(f"binary file, {f.stat().st_size} bytes\n", encoding="utf-8")
            files += 1
            continue
        fnbea.update(re.findall(r"\bfn-bea:([A-Za-z0-9_-]+)", text))
        if ext in (".xqy", ".xq", ".xquery"):
            dst.write_text(tok_xquery(text, t), encoding="utf-8")
        elif text.lstrip().startswith("<"):
            dst.write_text(tok_xml(text, t, counts), encoding="utf-8")
        else:
            dst.write_text(f"text file, {len(text)} chars, not copied\n", encoding="utf-8")
        files += 1
    (a.out / "MANIFEST.json").write_text(json.dumps({"project": t.name(a.project.name, "p"), "files": files,
                                                      "xml_elements": dict(counts.most_common()), "fn_bea": dict(fnbea.most_common()),
                                                      "string_literals_replaced": len(t.strings)}, indent=2), encoding="utf-8")
    print(json.dumps({"out": str(a.out), "files": files, "fn_bea": dict(fnbea), "strings_replaced": len(t.strings)}))
    left = residue(a.project, a.out)
    print(f"residue check: {len(left)} original word(s) still present (XML element/attribute names and syntax excluded)")
    if left:
        print("  " + ", ".join(left[:40]) + (" ..." if len(left) > 40 else ""))
        print("  these are either harmless structural words or a leak: check them before sharing the folder")
    return 0


if __name__ == "__main__":
    sys.exit(main())
