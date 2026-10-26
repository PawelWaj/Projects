#!/usr/bin/env python3
"""Gates for ONE generated Camel K module (run after `mvn test`). Stdlib only.

    check_camelk.py modules/<project>/<proxy> [--no-surefire]

K1 card approved       FLOW_CARD.md has `Status: approved` and an approver name, and was not changed after it was
                       frozen before the implementation (pi must never edit the card)
K2 no gaps left        no TODO(flow-card) in src/main (route, properties, beans)
K3 route ids           every branch-*, out-*, backend-* id from .scaffold.json is in the YAML route
K4 no infrastructure   no host names, IP addresses, host:port URIs or credentials in src/main
K5 tests untouched     FlowParityTest.java, FlowErrorTest.java and flow-test.json equal their scaffold hash; no @Disabled anywhere
K6 backend stubs       a stub file per backend whose response is used
K7 error tests         FlowErrorTest has at least one test per error scope in research.json
K8 tests green         surefire reports: tests > 0, failures 0, errors 0 (skipped = golden pending, reported)
K9 scenarios covered   every scenario_mapping row has at least one case (real from Splunk or synthetic)
K10 properties valid   application.properties: no spaces or notes in a value, no TODO; every {{key}} the route uses
                       is defined (the tests replace endpoints with mocks, so a broken production value stays green)
K11 single destination no destination twice: a backend-<x>-bs next to out-<x> (the JMS business service IS the output),
                       or two keys with the same endpoint value: production would get every message twice
K12 reply expected     request/reply flows: every case that ends in the reply has expected-output.json/.xml, so the
                       reply body is compared (a route that passes the request through unchanged must fail)
K13 runtime safe       what a parity test cannot see but production must not do: (a) a credential header (set from
                       {{backend.*}}/{{env:*}}, or named like a key/token/password) or a credential property inside a
                       log message; (b) a fixed host name as a value in the route or the properties (Host header,
                       constant); (c) ${exception.message} sent back or logged on a flow with an HTTP backend without
                       its own catch for HttpOperationFailedException (that message carries the full backend URL with
                       its query); (d) an HTTP-in flow calling an HTTP backend without removeHeaders before the backend
                       (caller headers forwarded) and after it (backend headers returned to the caller)
Writes GATES.json next to the module's pom; exit 1 if any gate fails."""
import argparse
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HOST = [(re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"), "IP address"),
        (re.compile(r"://(?!\{\{)[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "host name in a URI"),
        (re.compile(r"://[^/\s\"']*:\d{2,5}"), "host:port"),
        (re.compile(r"(?i)\b(password|passwd|secret|token|apikey|api-key)\s*[=:]\s*(?!\{\{|\$\{)[^\s\"',}]+"), "credential")]


CRED_NAME = re.compile(r"(?i)(api-?key|token|secret|passw|authorization|credential)")
BARE_HOST = re.compile(r":\s*[\"']?((?:[a-z0-9-]+\.){2,}[a-z]{2,}(?::\d{2,5})?)[\"']?\s*$")


def runtime_safe(route: str, props_text: str) -> list:
    """K13 findings (see the docstring); names and line numbers only."""
    out = []
    code = [(i, l) for i, l in enumerate(route.splitlines(), 1) if not l.lstrip().startswith("#")]
    cred_headers = set()
    lines = [l for _, l in code]
    for j, l in enumerate(lines):
        m = re.match(r"\s*-?\s*name:\s*[\"']?([\w-]+)", l)
        if m and j > 0 and "setHeader" in lines[j - 1] + (lines[j - 2] if j > 1 else ""):
            val = " ".join(lines[j + 1:j + 3])
            if CRED_NAME.search(m.group(1)) or re.search(r"\{\{(backend\.|env:)", val):
                cred_headers.add(m.group(1))
    for i, l in code:
        if "message:" in l:
            used = set(re.findall(r"\$\{headers?\.([\w-]+)\}", l))
            leak = sorted(h for h in used if h in cred_headers or CRED_NAME.search(h))
            leak += re.findall(r"\{\{(backend\.[\w.-]*(?:key|token|secret|passw|requestid|sourceid)[\w.-]*)\}\}", l, re.I)
            if leak:
                out.append(f"route line {i}: credential in a log message ({', '.join(leak)})")
        if BARE_HOST.search(l) and "beanType" not in l and "logName" not in l:
            out.append(f"route line {i}: fixed host name as a value (make it a {{{{property}}}} from env)")
    for i, l in enumerate(props_text.splitlines(), 1):
        if "=" in l and not l.lstrip().startswith(("#", "!")) and re.fullmatch(r"(?:[a-z0-9-]+\.){2,}[a-z]{2,}(?::\d{2,5})?", l.split("=", 1)[1].strip()):
            out.append(f"application.properties line {i}: fixed host name as a value")
    http_backend = bool(re.search(r"^backend\.[\w.-]+=\s*https?:", props_text, re.M))
    if http_backend and "${exception.message}" in route and "HttpOperationFailedException" not in route:
        out.append("${exception.message} on a flow with an HTTP backend: catch org.apache.camel.http.base.HttpOperationFailedException "
                   "first and report 'backend returned HTTP ${exception.statusCode}' (the message holds the backend URL and query)")
    if http_backend and re.search(r"^flow\.input=platform-http:", props_text, re.M):
        b = route.find("id: backend-")
        before, after = route[:b] if b >= 0 else route, route[b:] if b >= 0 else ""
        if "removeHeaders" not in before:
            out.append("no removeHeaders before the HTTP backend call: every caller header is forwarded (keep only the ones OSB sends)")
        if b >= 0 and "removeHeaders" not in after:
            out.append("no removeHeaders after the HTTP backend call: backend response headers go back to the caller")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--no-surefire", action="store_true", help="skip K8 (before mvn test ran)")
    a = ap.parse_args()
    mod = a.module
    meta = json.loads((mod / ".scaffold.json").read_text(encoding="utf-8"))
    gates = {}

    card = (mod / "FLOW_CARD.md").read_text(encoding="utf-8") if (mod / "FLOW_CARD.md").is_file() else ""
    approved = re.search(r"^Status:\s*approved\s*$", card, re.M | re.I) and re.search(r"^Approver:\s*\S+", card, re.M)
    sha_now = hashlib.sha256((mod / "FLOW_CARD.md").read_bytes()).hexdigest() if (mod / "FLOW_CARD.md").is_file() else ""
    frozen = meta.get("card_sha256")
    card_changed = bool(frozen) and frozen != sha_now
    gates["K1_card_approved"] = {"ok": bool(approved) and not card_changed,
                                 **({"card_changed_after_freeze": True} if card_changed else {})}

    main_files = [p for p in (mod / "src/main").rglob("*") if p.is_file()]
    todo = [f"{p.relative_to(mod)}:{i}" for p in main_files for i, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1)
            if "TODO(flow-card)" in line]
    gates["K2_no_gaps"] = {"ok": not todo, "left": len(todo), "where": todo[:20]}

    route = "\n".join(p.read_text(encoding="utf-8") for p in (mod / "src/main/resources/routes").glob("*.camel.yaml"))
    missing = [i for i in meta["route_ids"] if not re.search(rf"\bid:\s*[\"']?{re.escape(i)}[\"']?\s*$", route, re.M)
               and not re.search(rf"\bid:\s*[\"']?{re.escape(i)}[\"']?\s*[,}}]", route)]
    gates["K3_route_ids"] = {"ok": not missing, "missing": missing}

    infra = []
    for p in main_files:
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if line.lstrip().startswith("#") or "xmlns" in line or "namespace" in line.lower():
                continue
            for rx, what in HOST:
                if rx.search(line):
                    infra.append(f"{p.relative_to(mod)}:{i} {what}")
    gates["K4_no_infrastructure"] = {"ok": not infra, "findings": infra[:20]}

    changed = [f for f, h in meta["generated"].items()
               if not (mod / f).is_file() or hashlib.sha256((mod / f).read_bytes()).hexdigest() != h]
    disabled = [str(p.relative_to(mod)) for p in (mod / "src/test").rglob("*.java") if "@Disabled" in p.read_text(encoding="utf-8")]
    gates["K5_tests_untouched"] = {"ok": not changed and not disabled, "changed": changed, "disabled": disabled}

    stubs = mod / "src/test/resources/stubs"
    no_stub = [b for b in meta.get("backends_with_response", []) if not any((stubs / f"{b}{e}").is_file() for e in (".json", ".xml", ".txt"))]
    gates["K6_backend_stubs"] = {"ok": not no_stub, "missing": no_stub}

    err_tests = 0
    for p in (mod / "src/test").rglob("FlowErrorTest.java"):
        err_tests += len(re.findall(r"@(Test|ParameterizedTest)\b", p.read_text(encoding="utf-8")))
    gates["K7_error_tests"] = {"ok": err_tests >= meta.get("errors", 0) and (err_tests > 0 or meta.get("errors", 0) == 0),
                               "tests": err_tests, "error_scopes": meta.get("errors", 0)}

    cfg = json.loads((mod / "src/test/resources/flow-test.json").read_text(encoding="utf-8"))
    scen = [dict(p.split("=", 1) for p in sc.read_text(encoding="utf-8").strip().split("|") if "=" in p)
            for sc in (mod / "src/test/resources/parity").glob("*/*/SCENARIO.txt")]

    def hit(key: str, v: dict) -> bool:
        for p in key.split("|"):
            if "!=" in p:
                k, x = p.split("!=", 1)
                if v.get(k) == x:
                    return False
            elif "=" in p:
                k, x = p.split("=", 1)
                if v.get(k) != x:
                    return False
        return bool(key)
    uncovered = [m["scenario"] for m in cfg.get("scenario_mapping", []) if not any(hit(m["scenario"], v) for v in scen)]
    gates["K9_scenarios_covered"] = {"ok": not uncovered, "uncovered": uncovered}

    # K12: a request/reply flow is only tested when the REPLY BODY is compared: every case that ends in the reply
    # has expected-output.json/.xml (OSB's logged answer, or synthetic: built from the stub by research transforms)
    reply_rows = [m["scenario"] for m in cfg.get("scenario_mapping", []) if "reply" in (m.get("outputs") or [])]
    no_expected = []
    if reply_rows and "reply" in (cfg.get("outputs") or {}):
        for sc in (mod / "src/test/resources/parity").glob("*/*/SCENARIO.txt"):
            v = dict(p.split("=", 1) for p in sc.read_text(encoding="utf-8").strip().split("|") if "=" in p)
            if not any(hit(r_, v) for r_ in reply_rows):
                continue
            for case in sorted(p.parent for p in sc.parent.glob("*/input.payload")):
                exp = json.loads((case / "expected.json").read_text(encoding="utf-8")) if (case / "expected.json").is_file() else {}
                if exp.get("outcome", "success") == "success" and not any((case / f"expected-output{e}").is_file() for e in (".json", ".xml")):
                    no_expected.append(case.relative_to(mod / "src/test/resources/parity").as_posix())
    gates["K12_reply_expected"] = {"ok": not no_expected, "cases_without_expected_reply": no_expected[:20]}

    props, bad = {}, []
    pf = mod / "src/main/resources/application.properties"
    for i, line in enumerate(pf.read_text(encoding="utf-8").splitlines() if pf.is_file() else [], 1):
        if not line.strip() or line.lstrip().startswith(("#", "!")) or "=" not in line:
            continue
        k, v = (x.strip() for x in line.split("=", 1))
        props[k] = v
        if k.endswith(".selector"):                 # a message selector is text, not an endpoint
            continue
        if re.search(r"\s|[()]", v) or "TODO" in v or not v:
            bad.append(f"{k} (line {i})")
    used = sorted({k for k in re.findall(r"\{\{([\w.-]+)\}\}", route) if not k.startswith(("env:", "sys:"))})
    undefined = [k for k in used if k not in props]
    gates["K10_properties_valid"] = {"ok": not bad and not undefined, "bad_values": bad, "undefined": undefined}

    def norm(v: str) -> str:
        return re.sub(r"^(amqp|jms|activemq|sjms2?):(queue:|topic:)?", "", v).split("?")[0].lower()
    outs = {k[4:] for k in props if k.startswith("out.")}
    twice = [k for k in props if k.startswith("backend.") and re.sub(r"-bs$", "", k[8:]) in outs]
    seen = {}
    for k, v in props.items():
        if k.startswith(("out.", "backend.")) and v and not v.startswith(("mock:", "direct:")):
            seen.setdefault(norm(v), []).append(k)
    twice += [" = ".join(ks) for ks in seen.values() if len(ks) > 1]
    gates["K11_single_destination"] = {"ok": not twice, "twice": twice}

    k13 = runtime_safe(route, pf.read_text(encoding="utf-8") if pf.is_file() else "")
    gates["K13_runtime_safe"] = {"ok": not k13, "findings": k13[:20]}

    if not a.no_surefire:
        t = f = e = s = 0
        for rep in (mod / "target/surefire-reports").glob("TEST-*.xml"):
            r = ET.parse(rep).getroot()
            t += int(r.get("tests", 0))
            f += int(r.get("failures", 0))
            e += int(r.get("errors", 0))
            s += int(r.get("skipped", 0))
        gates["K8_tests_green"] = {"ok": t > 0 and f == 0 and e == 0, "tests": t, "failures": f, "errors": e, "skipped": s}

    ok = all(g["ok"] for g in gates.values())
    out = {"proxy": meta["proxy"], "project": meta["project"], "result": "PASS" if ok else "FAIL", "gates": gates}
    (mod / "GATES.json").write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    for k, g in gates.items():
        print(f"{'ok  ' if g['ok'] else 'FAIL'} {k} " + json.dumps({x: y for x, y in g.items() if x != 'ok'}))
    print(out["result"])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
