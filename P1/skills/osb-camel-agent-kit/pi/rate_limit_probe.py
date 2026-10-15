#!/usr/bin/env python3
"""Ask the model endpoint for its rate limits: ONE tiny request, then print only the status and the rate-limit
headers (x-ratelimit-*, retry-after, ...). Never prints the API key, the URL's credentials or the answer text.

    python rate_limit_probe.py [--model fast] [--models ~/.pi/agent/models.json]

Reads the provider of the model from pi's models.json (baseUrl, apiKey or apiKey env name, api type) and sends an
OpenAI-compatible chat request ("Reply OK", max 5 tokens). Other API styles: prints what it found and stops."""
import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def find(models: dict, name: str):
    for pname, prov in (models.get("providers") or {}).items():
        for m in prov.get("models") or []:
            if name in (m.get("id"), m.get("name")):
                return pname, prov, m
    return None, None, None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=os.environ.get("OSB_PI_MODEL", "fast"))
    ap.add_argument("--models", type=Path, default=Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent")) / "models.json")
    a = ap.parse_args()
    models = json.loads(a.models.read_text(encoding="utf-8"))
    pname, prov, m = find(models, a.model.split("/")[-1])
    if not prov:
        print(f"model '{a.model}' not in {a.models}; providers: {list((models.get('providers') or {}).keys())}")
        return 2
    base = (prov.get("baseUrl") or prov.get("baseURL") or "").rstrip("/")
    key = prov.get("apiKey") or ""
    if key and key.upper() == key and not key.startswith(("sk-", "ey")) and os.environ.get(key):
        key = os.environ[key]                          # apiKey given as the NAME of an environment variable
    api = prov.get("api") or m.get("api") or "openai-completions"
    print(f"provider: {pname}  api: {api}  model id: {m.get('id')}  endpoint host: {base.split('/')[2] if '//' in base else '?'}")
    if "openai" not in api and "completions" not in api:
        print("not an OpenAI-compatible endpoint: probe stops here (send this line to the endpoint owner instead)")
        return 0
    body = json.dumps({"model": m.get("id"), "messages": [{"role": "user", "content": "Reply OK"}], "max_tokens": 5}).encode()
    req = urllib.request.Request(base + "/chat/completions", data=body, method="POST",
                                 headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {key}"} if key else {}),
                                          **(prov.get("headers") or {})})
    t0 = time.time()
    try:
        r = urllib.request.urlopen(req, timeout=60, context=ssl.create_default_context())
        status, headers = r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        status, headers = e.code, dict(e.headers)
    except Exception as e:                              # noqa: BLE001
        print(f"request failed: {type(e).__name__}")
        return 1
    print(f"status: {status}  in {time.time() - t0:.1f}s")
    shown = {k: v for k, v in headers.items() if any(w in k.lower() for w in ("ratelimit", "rate-limit", "retry-after", "quota", "x-ms-region", "apim"))}
    for k, v in sorted(shown.items()):
        print(f"  {k}: {v}")
    if not shown:
        print("  no rate-limit headers sent by the endpoint: only its owner can tell the limits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
