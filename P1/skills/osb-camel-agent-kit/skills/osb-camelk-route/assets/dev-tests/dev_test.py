#!/usr/bin/env python3
"""Functional tests of a migrated HTTP flow against the DEPLOYED route (Dev / E2E), optionally side by side with OSB.

    python dev_test.py --url https://<dev host>/<entry path> [--cases dev-cases] [--flow-test flow-test.json]
                       [--osb-url https://<osb host>/<proxy path>] [--header-env Authorization=DEV_TOKEN]
                       [--method POST] [--timeout 30] [--insecure] [-o results]

Tests (IDs match DEV_TEST_PLAN.md):
  D1  every case in --cases: status 2xx (or OSB's error status when expected.json says outcome error); the reply has
      the same JSON key paths and types as expected-output.json (values differ on Dev: shape only); the correlation
      header comes back unchanged
  D2  a body that is not JSON: OSB's error status, correlation header back, error fields named (errorCode /
      errorMessage / debugInfo, as header or body key)
  D3  no credential-like header in any reply (apikey, authorization, secret, token, password, requestid, sourceid)
  D4  with --osb-url: the same case to OSB and to the route, same status, same JSON (generated fields and the
      correlation id ignored); every differing key path listed
Output: <out>/DEV_TEST_RESULT.md + .json. Prints and writes test names, statuses, key paths, header NAMES and timings
only, never message values. Credentials only from environment variables (--header-env), never from files.
Exit 0 when every test passed. Stdlib only (Python 3.8+), runs in Git Bash on Windows and on Linux/macOS."""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

LEAK = ("apikey", "api-key", "authorization", "secret", "token", "password", "requestid", "sourceid")
ERROR_FIELDS = ("errorcode", "errormessage", "debuginfo")


def call(url, body, headers, method, timeout, ctx):
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            return r.status, dict(r.headers.items()), r.read(), int((time.time() - t0) * 1000)
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers.items()), e.read(), int((time.time() - t0) * 1000)
    except (urllib.error.URLError, OSError) as e:
        return 0, {}, str(getattr(e, "reason", e)).encode(), int((time.time() - t0) * 1000)


def shape(v, path=""):
    """key path -> JSON type, recursively (lists: shape of the first element)."""
    out = {path or "$": type(v).__name__}
    if isinstance(v, dict):
        for k, x in v.items():
            out.update(shape(x, f"{path}.{k}" if path else k))
    elif isinstance(v, list) and v:
        out.update(shape(v[0], f"{path}[]"))
    return out


def drop(d, dotted):
    parts = dotted.split(".")
    for p in parts[:-1]:
        d = d.get(p) if isinstance(d, dict) else None
    if isinstance(d, dict):
        d.pop(parts[-1], None)


def diff(a, b, path=""):
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            out += diff(a.get(k), b.get(k), f"{path}.{k}" if path else k) if k in a and k in b else [f"{path}.{k}" if path else k]
        return out
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return [f"{path}[] (length)"]
        return [d for i, (x, y) in enumerate(zip(a, b)) for d in diff(x, y, f"{path}[{i}]")]
    return [] if a == b else [path or "$"]


def as_json(raw):
    try:
        return json.loads(raw.decode("utf-8", errors="replace"))
    except json.JSONDecodeError:
        return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", required=True, help="the route's URL on Dev (host + entry path)")
    ap.add_argument("--cases", type=Path, default=Path(__file__).parent / "dev-cases")
    ap.add_argument("--flow-test", type=Path, default=Path(__file__).parent / "flow-test.json")
    ap.add_argument("--osb-url", help="OSB proxy URL in the same environment (D4 side by side)")
    ap.add_argument("--header-env", action="append", default=[], help="NAME=ENVVAR: send header NAME with the value of $ENVVAR")
    ap.add_argument("--method", default="POST")
    ap.add_argument("--timeout", type=int, default=30)
    ap.add_argument("--insecure", action="store_true", help="skip TLS verification (Dev self-signed only)")
    ap.add_argument("-o", "--out", type=Path, default=Path("results"))
    a = ap.parse_args()

    cfg = json.loads(a.flow_test.read_text(encoding="utf-8")) if a.flow_test.is_file() else {}
    corr = cfg.get("correlation_header") or "traceId"
    err_status = int(cfg.get("error_http_status") or 500)
    generated = list(cfg.get("generated_fields") or [])
    ctype = "application/json" if cfg.get("payload_format", "json") == "json" else "application/xml"
    ctx = ssl._create_unverified_context() if a.insecure else None   # noqa: S323 (explicit opt-in for Dev)
    extra = {}
    for spec in a.header_env:
        name, _, var = spec.partition("=")
        if not os.environ.get(var):
            print(f"environment variable {var} is empty (for header {name})")
            return 2
        extra[name] = os.environ[var]

    cases = sorted(p.parent for p in a.cases.glob("**/input.payload"))
    if not cases:
        print(f"no case with input.payload under {a.cases}")
        return 2
    rows, times = [], []

    def add(tid, name, ok, detail=""):
        rows.append({"id": tid, "test": name, "ok": bool(ok), "detail": detail})
        print(f"{'PASS' if ok else 'FAIL'} {tid} {name}{': ' + detail if detail else ''}")

    def headers_for(c):
        h = json.loads((c / "headers.json").read_text(encoding="utf-8")) if (c / "headers.json").is_file() else {}
        h = {k: str(v) for k, v in h.items()}
        h.setdefault("Content-Type", ctype)
        h[corr] = f"devtest-{uuid.uuid4()}"
        h.update(extra)
        return h

    def leak_names(hdrs):
        return sorted(k for k in hdrs if any(s in k.lower().replace("_", "") for s in LEAK))

    # D1 functional, D3 per reply
    for i, c in enumerate(cases, 1):
        name = c.relative_to(a.cases).as_posix()
        exp = json.loads((c / "expected.json").read_text(encoding="utf-8")) if (c / "expected.json").is_file() else {}
        want_ok = exp.get("outcome", "success") == "success"
        h = headers_for(c)
        st, rh, body, ms = call(a.url, (c / "input.payload").read_bytes(), h, a.method, a.timeout, ctx)
        times.append(ms)
        if st == 0:
            add(f"D1.{i}", name, False, "no connection: " + body.decode(errors="replace")[:80])
            continue
        problems = []
        if want_ok and not 200 <= st < 300:
            problems.append(f"status {st}")
        if not want_ok and st != err_status:
            problems.append(f"status {st}, expected {err_status}")
        if {k.lower(): v for k, v in rh.items()}.get(corr.lower()) != h[corr]:
            problems.append(f"{corr} not returned unchanged")
        golden = c / "expected-output.json"
        if want_ok and golden.is_file():
            got = as_json(body)
            if got is None:
                problems.append("reply is not JSON")
            else:
                ws, gs = shape(json.loads(golden.read_text(encoding="utf-8"))), shape(got)
                missing = sorted(k for k in ws if k not in gs)
                typed = sorted(k for k in ws if k in gs and ws[k] != gs[k] and "NoneType" not in (ws[k], gs[k]))
                if missing:
                    problems.append("missing keys: " + ", ".join(missing[:8]))
                if typed:
                    problems.append("other type: " + ", ".join(typed[:8]))
        add(f"D1.{i}", name, not problems, "; ".join(problems) or f"status {st}, {ms} ms")
        leaks = leak_names(rh)
        add(f"D3.{i}", f"no credential header in the reply ({name})", not leaks, ("names: " + ", ".join(leaks)) if leaks else "")

    # D2 error path
    h = headers_for(cases[0])
    st, rh, body, ms = call(a.url, b"this is not " + ctype.split("/")[1].encode() + b" {", h, a.method, a.timeout, ctx)
    low = {k.lower(): v for k, v in rh.items()}
    j = as_json(body)
    named = sorted(f for f in ERROR_FIELDS if f in low or (isinstance(j, dict) and f in {k.lower() for k in j}))
    p = []
    if st != err_status:
        p.append(f"status {st}, expected {err_status}")
    if low.get(corr.lower()) != h[corr]:
        p.append(f"{corr} not returned")
    if not named:
        p.append("no errorCode / errorMessage / debugInfo in headers or body")
    add("D2.1", "unreadable payload -> OSB error answer", not p, "; ".join(p) or f"status {st}, error fields: {', '.join(named)}")
    leaks = leak_names(rh)
    add("D3.0", "no credential header in the error reply", not leaks, ("names: " + ", ".join(leaks)) if leaks else "")

    # D4 side by side
    if a.osb_url:
        for i, c in enumerate(cases, 1):
            name = c.relative_to(a.cases).as_posix()
            h = headers_for(c)
            payload = (c / "input.payload").read_bytes()
            s1, _, b1, _ = call(a.osb_url, payload, h, a.method, a.timeout, ctx)
            s2, _, b2, _ = call(a.url, payload, h, a.method, a.timeout, ctx)
            j1, j2 = as_json(b1), as_json(b2)
            p = [] if s1 == s2 else [f"status OSB {s1} vs route {s2}"]
            if j1 is not None and j2 is not None:
                for g in generated + [corr]:
                    drop(j1, g), drop(j2, g)
                d = diff(j1, j2)
                if d:
                    p.append("differs at: " + ", ".join(d[:10]))
            elif (j1 is None) != (j2 is None):
                p.append("one reply is JSON, the other is not")
            elif b1.strip() != b2.strip():
                p.append("bodies differ (not JSON)")
            add(f"D4.{i}", f"OSB vs route ({name})", not p, "; ".join(p))

    ok = all(r["ok"] for r in rows)
    times.sort()
    summary = {"url_host": a.url.split("/")[2] if "//" in a.url else a.url, "cases": len(cases), "passed": sum(r["ok"] for r in rows),
               "failed": sum(not r["ok"] for r in rows), "side_by_side": bool(a.osb_url), "ok": ok,
               "latency_ms": {"p50": times[len(times) // 2], "max": times[-1]} if times else {},
               "date": time.strftime("%Y-%m-%dT%H:%M:%S"), "tests": rows}
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / "DEV_TEST_RESULT.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    md = [f"# Dev test result: {'PASS' if ok else 'FAIL'}", "",
          f"Host {summary['url_host']}, {summary['date']}, {len(cases)} cases, side by side with OSB: {'yes' if a.osb_url else 'no'}, "
          f"latency p50 {summary['latency_ms'].get('p50', '-')} ms / max {summary['latency_ms'].get('max', '-')} ms.", "",
          "| ID | Test | Result | Detail |", "|---|---|---|---|"]
    md += [f"| {r['id']} | {r['test']} | {'pass' if r['ok'] else 'FAIL'} | {r['detail']} |" for r in rows]
    (a.out / "DEV_TEST_RESULT.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print(f"dev test: {summary['passed']} passed, {summary['failed']} failed -> {a.out / 'DEV_TEST_RESULT.md'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
