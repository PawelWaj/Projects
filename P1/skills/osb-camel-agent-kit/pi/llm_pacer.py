#!/usr/bin/env python3
"""Local pacer between pi and the model platform. Stdlib only.

    python llm_pacer.py pi-on  [--port 8765]     # pi's models.json -> the pacer (the platform URL is kept in models.json.pacer.json)
    python llm_pacer.py [--gap 4] [--parallel 1] [--retries 30]    # run the pacer (window stays open; upstream from pi-on)
    python llm_pacer.py pi-off                   # pi's models.json back to the platform

pi sends its requests to http://127.0.0.1:<port>/... instead of the platform (models.json baseUrl). The pacer
forwards them (same path, headers, body; streamed answers stream through), but
  - at most --parallel requests at a time, and at least --gap seconds between two request starts: an agent fires
    its requests back to back, which trips a requests-per-time limiter on the platform;
  - a 429 / 502 / 503 / 504 before any answer byte is not passed to pi: the pacer waits (Retry-After if the platform
    sends one, else 15 s doubling up to 300 s) and sends the SAME request again, up to --retries times. pi never sees
    the refusal, so its run continues instead of failing and being restarted from the beginning.
Logs one line per request to stdout: time, path, status, attempts, seconds waited, seconds total, request size in
bytes (an agent resends the whole conversation, so the size grows per call). No content, no key.
Env: PACER_INSECURE=1 skips TLS verification (only if the platform certificate is not trusted on this machine)."""
import argparse
import json
import os
from pathlib import Path
from urllib.parse import urlparse
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RETRY_STATUS = {429, 502, 503, 504}
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding",
       "upgrade", "host", "content-length", "accept-encoding"}


class Pacer:
    def __init__(self, gap: float, parallel: int):
        self.gap, self.slots, self.lock, self.last = gap, threading.Semaphore(parallel), threading.Lock(), 0.0

    def wait_turn(self) -> float:
        with self.lock:
            delay = max(0.0, self.last + self.gap - time.time())
            if delay:
                time.sleep(delay)
            self.last = time.time()
            return delay


def make_handler(routes: dict, default: str, pacer: Pacer, retries: int, ctx: ssl.SSLContext, timeout: float):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):          # one own line per request instead
            pass

        def forward(self, method: str):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0)) if method in ("POST", "PUT") else None
            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
            upstream = default                                   # several providers: the request's model picks the platform
            if body and len(routes) > 1:
                try:
                    upstream = routes.get(json.loads(body).get("model"), default)
                except (ValueError, AttributeError):
                    pass
            prefix = urlparse(upstream).path.rstrip("/")         # pi may send /api/... or /... : never /api/api/...
            path = self.path[len(prefix):] if prefix and self.path.startswith(prefix + "/") else self.path
            url = upstream.rstrip("/") + path
            t0, waited, backoff = time.time(), 0.0, 15.0
            with pacer.slots:
                for attempt in range(1, retries + 2):
                    waited += pacer.wait_turn()
                    req = urllib.request.Request(url, data=body, headers=headers, method=method)
                    try:
                        resp = urllib.request.urlopen(req, context=ctx, timeout=timeout)
                        status = resp.status
                    except urllib.error.HTTPError as e:
                        resp, status = e, e.code
                    except Exception as e:  # noqa: BLE001  network error: retry like a refusal
                        resp, status = None, f"{type(e).__name__}"
                    if (status in RETRY_STATUS or resp is None) and attempt <= retries:
                        ra = resp.headers.get("Retry-After") if resp is not None else None
                        pause = float(ra) if ra and ra.isdigit() else backoff
                        backoff = min(backoff * 2, 300.0)
                        print(f"{time.strftime('%H:%M:%S')} {self.path} -> {status}, retry {attempt}/{retries} in {pause:.0f}s", flush=True)
                        if resp is not None:
                            resp.read()
                        time.sleep(pause)
                        waited += pause
                        continue
                    break
                if resp is None:
                    self.send_error(502, f"pacer: upstream unreachable ({status})")
                    return
                self.send_response(resp.status if hasattr(resp, "status") else status)
                for k, v in resp.headers.items():
                    if k.lower() not in HOP:
                        self.send_header(k, v)
                self.send_header("Connection", "close")
                self.end_headers()
                while True:                   # stream through (server-sent events arrive in pieces)
                    chunk = resp.read1(8192) if hasattr(resp, "read1") else resp.read(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                self.close_connection = True
            print(f"{time.strftime('%H:%M:%S')} {method} {self.path} -> {status} attempts {attempt} waited {waited:.0f}s total {time.time() - t0:.0f}s"
                  f" sent {len(body or b'')} bytes", flush=True)

        def do_POST(self):
            self.forward("POST")

        def do_GET(self):
            self.forward("GET")

    return H


def models_path() -> Path:
    return Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent")) / "models.json"


def switch(on: bool, port: int) -> int:
    p = models_path(); side = p.with_name("models.json.pacer.json")
    m = json.loads(p.read_text(encoding="utf-8"))
    if on:
        saved = json.loads(side.read_text(encoding="utf-8")) if side.is_file() else {}
        for name, prov in m.get("providers", {}).items():
            url = prov.get("baseUrl", "")
            if url and "127.0.0.1" not in url and "localhost" not in url:
                saved[name] = url
                prov["baseUrl"] = f"http://127.0.0.1:{port}"
        side.write_text(json.dumps(saved, indent=2), encoding="utf-8")
        print(f"pi now talks to the pacer http://127.0.0.1:{port}; platform kept in {side}: {list(saved.values())}")
    else:
        if not side.is_file():
            print("nothing to undo (no models.json.pacer.json)")
            return 0
        saved = json.loads(side.read_text(encoding="utf-8"))
        for name, url in saved.items():
            if name in m.get("providers", {}):
                m["providers"][name]["baseUrl"] = url
        print(f"pi talks to the platform again: {list(saved.values())}")
        side.unlink()
    p.write_text(json.dumps(m, indent=2), encoding="utf-8")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", nargs="?", default="serve", choices=["serve", "pi-on", "pi-off"])
    ap.add_argument("--upstream", help="platform base URL (default: the one saved by pi-on)")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--gap", type=float, default=float(os.environ.get("PACER_GAP", 4)))
    ap.add_argument("--parallel", type=int, default=1)
    ap.add_argument("--retries", type=int, default=30)
    ap.add_argument("--timeout", type=float, default=900, help="seconds per upstream request")
    a = ap.parse_args()
    if a.action != "serve":
        return switch(a.action == "pi-on", a.port)
    routes: dict = {}
    if not a.upstream:
        side = models_path().with_name("models.json.pacer.json")
        saved = json.loads(side.read_text(encoding="utf-8")) if side.is_file() else {}
        if not saved:
            sys.exit("no upstream: run 'llm_pacer.py pi-on' first, or give --upstream https://<platform>/api")
        a.upstream = next(iter(saved.values()))
        provs = json.loads(models_path().read_text(encoding="utf-8")).get("providers", {})
        for name, url in saved.items():                 # model id -> its own platform (not all to the first one)
            for m in (provs.get(name) or {}).get("models") or []:
                for k in (m.get("id"), m.get("name")):
                    if k:
                        routes[k] = url
    ctx = ssl.create_default_context()
    if os.environ.get("PACER_INSECURE") == "1":
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(routes, a.upstream, Pacer(a.gap, a.parallel), a.retries, ctx, a.timeout))
    for model, url in sorted(routes.items()):
        print(f"  model {model} -> {url}", flush=True)
    print(f"pacer on http://127.0.0.1:{a.port} -> {a.upstream} (gap {a.gap}s, parallel {a.parallel}, retries {a.retries}); Ctrl+C stops it",
          flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
