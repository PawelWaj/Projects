#!/usr/bin/env python3
"""Live demo of the model platform limits that slow the pi agent down, and of the workaround. Stdlib only.

    python demo_limits.py config                         # which model pi uses, context window, pacer on or off
    python demo_limits.py burst  [--n 6] [--parallel 3]  # N tiny requests at once, DIRECT to the platform -> 429s
    python demo_limits.py paced  [--n 6]                 # the same requests through the pacer -> all 200, waits shown
    python demo_limits.py size   [--sizes 2,8,16,32,48]  # one request per prompt size (thousand tokens) -> time, 429, context
    python demo_limits.py agent  --project <osb-prj> --research <research/prj/proxy> [--turns 12]
                                                         # what ONE research run sends: tokens per call and per minute
    python demo_limits.py log    [domain/pacer.log]      # what the real runs met: calls, 429 retries, waiting, longest call

Every request carries SYNTHETIC text only ("line 0001 ...", "Reply OK"): no client data, no OSB source. Prints status,
seconds and token counts, never the API key, the answer text or the source. Keep --n small: the endpoint is shared.
Reads the provider from pi's models.json like rate_limit_probe.py; if pi points at the pacer, `burst` and `size` use
the platform URL saved in models.json.pacer.json, so they show what pi meets without the pacer."""
import argparse
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

CHARS_PER_TOKEN = 4          # rough rule for English text and XML; good enough to compare sizes
PACER = "http://127.0.0.1:{port}"


def models_file() -> Path:
    return Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent")) / "models.json"


def load_provider(model: str):
    """(provider name, provider dict, model dict, platform base URL, pacer active)."""
    mf = models_file()
    if not mf.is_file():
        sys.exit(f"no pi models.json at {mf} (set PI_CODING_AGENT_DIR)")
    models = json.loads(mf.read_text(encoding="utf-8"))
    for pname, prov in (models.get("providers") or {}).items():
        for m in prov.get("models") or []:
            if model.split("/")[-1] in (m.get("id"), m.get("name")):
                base = (prov.get("baseUrl") or prov.get("baseURL") or "").rstrip("/")
                paced = "127.0.0.1" in base or "localhost" in base
                side = mf.with_name("models.json.pacer.json")
                if paced and side.is_file():
                    base = (json.loads(side.read_text(encoding="utf-8")).get(pname) or base).rstrip("/")
                return pname, prov, m, base, paced
    sys.exit(f"model '{model}' not in {mf}; providers: {list((models.get('providers') or {}).keys())}")


def api_key(prov: dict) -> str:
    key = prov.get("apiKey") or ""
    if key and key.upper() == key and not key.startswith(("sk-", "ey")) and os.environ.get(key):
        key = os.environ[key]                     # apiKey given as the NAME of an environment variable
    return key


def host(url: str) -> str:
    return url.split("/")[2] if "//" in url else "?"


def call(base: str, prov: dict, model_id: str, prompt: str, max_tokens: int, timeout: float, ctx) -> dict:
    """One chat request. Returns status, seconds, usage and rate-limit headers; never the answer text."""
    body = json.dumps({"model": model_id, "messages": [{"role": "user", "content": prompt}],
                       "max_tokens": max_tokens, "temperature": 0}).encode()
    key = api_key(prov)
    headers = {"Content-Type": "application/json", **({"Authorization": f"Bearer {key}"} if key else {}),
               **(prov.get("headers") or {})}
    req = urllib.request.Request(base + "/chat/completions", data=body, method="POST", headers=headers)
    t0 = time.time()
    out = {"status": None, "usage": {}, "limits": {}, "note": ""}
    try:
        r = urllib.request.urlopen(req, timeout=timeout, context=ctx)
        out["status"], hdrs = r.status, dict(r.headers)
        try:
            out["usage"] = json.loads(r.read()).get("usage") or {}
        except ValueError:
            out["note"] = "answer not JSON"
    except urllib.error.HTTPError as e:
        out["status"], hdrs = e.code, dict(e.headers)
        text = e.read()[:400].decode("utf-8", "replace").lower()
        if "context" in text or "maximum" in text or "too long" in text or "tokens" in text:
            out["note"] = "refused: prompt longer than the context window"
        elif e.code == 429:
            out["note"] = "rate limit"
    except TimeoutError:
        out["status"], hdrs, out["note"] = "timeout", {}, f"no answer within {timeout:.0f}s"
    except Exception as e:                         # noqa: BLE001
        out["status"], hdrs = type(e).__name__, {}
        if "timed out" in str(e):
            out["status"], out["note"] = "timeout", f"no answer within {timeout:.0f}s"
    out["seconds"] = time.time() - t0
    out["limits"] = {k: v for k, v in hdrs.items() if any(w in k.lower() for w in ("ratelimit", "rate-limit", "retry-after", "quota"))}
    return out


def ssl_ctx():
    ctx = ssl.create_default_context()
    if os.environ.get("PACER_INSECURE") == "1":
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    return ctx


def filler(tokens: int) -> str:
    """Synthetic numbered lines of about `tokens` tokens, then one question about them."""
    line = "line {:05d}: the service reads a message, maps the fields and sends it to the next queue.\n"
    n = max(1, tokens * CHARS_PER_TOKEN // len(line.format(0)))
    return "".join(line.format(i) for i in range(1, n + 1)) + "\nReply with the number of the last line only."


def fmt(r: dict) -> str:
    u = r["usage"]
    tok = f"  prompt {u.get('prompt_tokens')} tok, answer {u.get('completion_tokens')} tok" if u else ""
    lim = ("  " + " ".join(f"{k}={v}" for k, v in sorted(r["limits"].items()))) if r["limits"] else ""
    return f"{str(r['status']):>8}  {r['seconds']:6.1f}s{tok}{('  ' + r['note']) if r['note'] else ''}{lim}"


def cmd_config(a) -> int:
    pname, prov, m, base, paced = load_provider(a.model)
    print(f"model      : {m.get('id')}  (provider {pname}, api {prov.get('api') or m.get('api') or 'openai-completions'})")
    print(f"platform   : {host(base)}")
    print(f"context    : {m.get('contextWindow', '? (not in models.json)')} tokens   max answer: {m.get('maxTokens', '?')} tokens")
    print(f"pi -> pacer: {'yes (127.0.0.1)' if paced else 'no, pi calls the platform directly'}")
    print(f"pi timeout : PI_TIMEOUT={os.environ.get('PI_TIMEOUT', '1800')}s per pi run (pi_call.sh), pacer 900s per call")
    return 0


def run_many(base, prov, m, n, parallel, prompt, max_tokens, timeout, label) -> list:
    ctx, results, lock, sem = ssl_ctx(), [None] * n, threading.Lock(), threading.Semaphore(parallel)
    t_start = time.time()

    def one(i):
        with sem:
            r = call(base, prov, m.get("id"), prompt, max_tokens, timeout, ctx)
            r["at"] = time.time() - t_start
            results[i] = r
            with lock:
                print(f"  #{i + 1:<2} start+{r['at'] - r['seconds']:5.1f}s {fmt(r)}", flush=True)

    print(f"{label}: {n} requests, {parallel} at a time, to {host(base)}")
    threads = [threading.Thread(target=one, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    counts: dict = {}
    for r in results:
        counts[str(r["status"])] = counts.get(str(r["status"]), 0) + 1
    print(f"result: {counts}  in {time.time() - t_start:.1f}s")
    return results


def cmd_burst(a) -> int:
    pname, prov, m, base, _ = load_provider(a.model)
    rs = run_many(base, prov, m, a.n, a.parallel, "Reply OK", 5, a.timeout, "burst DIRECT (what pi does without the pacer)")
    refused = sum(1 for r in rs if r["status"] == 429)
    print(f"=> {refused} of {a.n} refused with 429 although each request is tiny: the platform limits requests per time,"
          " and an agent fires its calls back to back" if refused else
          "=> no 429 this time: raise --n / --parallel a little, or run `size` (the limit also counts tokens per minute)")
    return 0


def cmd_paced(a) -> int:
    pname, prov, m, _, _ = load_provider(a.model)
    base = PACER.format(port=a.port)
    import socket
    with socket.socket() as so:
        so.settimeout(2)
        if so.connect_ex(("127.0.0.1", a.port)) != 0:
            sys.exit(f"pacer not running on {base}: bash $KIT/pi/vdi_session.sh start (or python llm_pacer.py)")
    run_many(base, prov, m, a.n, a.parallel, "Reply OK", 5, a.timeout + 600, "same requests THROUGH THE PACER (gap, retry on 429)")
    print("=> the pacer spaces the calls and repeats a refused call itself; pi never sees the 429. Cost: waiting time"
          " (see the pacer window / domain/pacer.log: 'retry n/30 in 15s')")
    return 0


def cmd_size(a) -> int:
    pname, prov, m, base, _ = load_provider(a.model)
    ctx = ssl_ctx()
    window = m.get("contextWindow")
    print(f"prompt size test, synthetic text, one request each, {a.pause:.0f}s pause, to {host(base)}"
          f" (context window in models.json: {window or '?'})")
    for k in a.sizes:
        tokens = int(k * 1000)
        r = call(base, prov, m.get("id"), filler(tokens), 16, a.timeout, ctx)
        print(f"  ~{k:>4}k tokens {fmt(r)}", flush=True)
        if a.pause:
            time.sleep(a.pause)
    print("=> time grows with the prompt; past the window the platform refuses; several big prompts within a minute"
          " hit the tokens-per-minute limit (429) although the requests are few")
    return 0


def tokens_of(paths) -> int:
    return sum(p.stat().st_size for p in paths if p.is_file()) // CHARS_PER_TOKEN


def cmd_agent(a) -> int:
    """Estimate, from file sizes only, what one research run (pi) sends to the model."""
    kit = Path(a.kit)
    sk = next((d for d in (kit / "skills/osb-research", kit / ".pi/skills/osb-research") if d.is_dir()), None)
    if not sk:
        sys.exit(f"skill osb-research not found under {kit}")
    research, project = Path(a.research), Path(a.project)
    sources = research / "SOURCES.txt"
    if not sources.is_file():
        sys.exit(f"{sources} missing: run research step 1 (facts) first")
    src = [project / s.strip() for s in sources.read_text(encoding="utf-8").splitlines() if s.strip()]
    fixed = {"pi system prompt + tool definitions (estimate)": 3000,
             "role prompt agents/researcher.md": tokens_of([kit / "agents/researcher.md"]),
             "skill osb-research (SKILL.md, questions, template, schema)": tokens_of(
                 [sk / "SKILL.md", sk / "references/questions.md", sk / "assets/RESEARCH_TEMPLATE.md", sk / "assets/research.schema.json"]),
             f"OSB sources of this proxy ({len(src)} files, one bundle)": tokens_of(src),
             "facts.json (step 1)": tokens_of([research / "facts.json"])}
    first = sum(fixed.values())
    print(f"one research run of {research.name}: what the model must hold (file sizes / {CHARS_PER_TOKEN}, no content shown)")
    for k, v in fixed.items():
        print(f"  {v:>7} tok  {k}")
    print(f"  {first:>7} tok  = context after the first turns (read skill + bundle)")
    print(f"\nan agent resends the WHOLE conversation on every call; each turn adds its own tool output and answer"
          f" (~{a.grow} tok here, thinking 'high' adds more):")
    total, ctx_now = 0, first
    for t in range(1, a.turns + 1):
        total += ctx_now
        flag = "  <- over the 64k window" if ctx_now > a.window else ""
        print(f"  call {t:>2}: sends {ctx_now:>7} tok   running total {total:>8} tok{flag}")
        ctx_now += a.grow
    per_min = total * 60 // max(1, int(a.turns * (a.gap + a.call_s)))
    print(f"\n=> ESTIMATE: {a.turns} calls = {total} tokens for ONE proxy; at {a.call_s:.0f}s per answer + {a.gap:.0f}s gap"
          f" that is ~{per_min} tokens per minute. The per-minute limit counts these tokens, not the number of calls."
          " A 4-proxy project = 4 such runs. Measured numbers: `demo_limits.py log` after a run through the pacer.")
    return 0


LOG_RE = re.compile(r"^(\d\d:\d\d:\d\d) (POST|GET) \S+ -> (\S+) attempts (\d+) waited (\d+)s total (\d+)s(?: sent (\d+) bytes)?")
RETRY_RE = re.compile(r"^(\d\d:\d\d:\d\d) \S+ -> (\S+), retry (\d+)/(\d+) in (\d+)s")


def _secs(hms: str) -> int:
    h, m, s = (int(x) for x in hms.split(":"))
    return h * 3600 + m * 60 + s


def cmd_log(a) -> int:
    p = Path(a.file)
    if not p.is_file():
        sys.exit(f"{p} not found (the pacer writes it when started by vdi_session.sh start)")
    calls, retries, statuses, waited, longest, per_hour, sizes = 0, 0, {}, 0, 0, {}, []
    retry_status: dict = {}
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        m = LOG_RE.match(line)
        if m and m.group(2) == "POST":
            calls += 1
            statuses[m.group(3)] = statuses.get(m.group(3), 0) + 1
            waited += int(m.group(5))
            longest = max(longest, int(m.group(6)))
            per_hour[m.group(1)[:2]] = per_hour.get(m.group(1)[:2], 0) + 1
            if m.group(7):
                sizes.append((m.group(1), int(m.group(7)) // CHARS_PER_TOKEN, int(m.group(6))))
            continue
        m = RETRY_RE.match(line)
        if m:
            retries += 1
            retry_status[m.group(2)] = retry_status.get(m.group(2), 0) + 1
    print(f"{p}: {calls} model calls answered, final status {statuses}")
    print(f"  refused and repeated by the pacer: {retries} times {retry_status}")
    print(f"  waiting caused by the limits: {waited}s ({waited / 60:.0f} min); longest single call {longest}s")
    print("  calls per hour of day: " + "  ".join(f"{h}h:{n}" for h, n in sorted(per_hour.items())))
    if sizes:
        last = sizes[-a.last:]
        print(f"  last {len(last)} calls, measured request size (bytes / {CHARS_PER_TOKEN}): an agent resends the whole conversation")
        for t, tok, secs in last:
            print(f"    {t}  ~{tok:>7} tok sent  answered in {secs:>4}s{'  <- over 64k' if tok > a.window else ''}")
        span = max(60, _secs(last[-1][0]) - _secs(last[0][0]) + last[-1][2])
        print(f"  ~{sum(t for _, t, _ in last) * 60 // span} tokens per minute over these calls")
    print("=> without the pacer every one of those refusals would have ended the pi run and restarted it from the beginning")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["config", "burst", "paced", "size", "agent", "log"])
    ap.add_argument("file", nargs="?", default=os.path.join(os.environ.get("WS", "."), "domain", "pacer.log"))
    ap.add_argument("--model", default=os.environ.get("OSB_PI_MODEL", "fast"))
    ap.add_argument("--n", type=int, default=6)
    ap.add_argument("--parallel", type=int, default=3)
    ap.add_argument("--port", type=int, default=int(os.environ.get("PACER_PORT", 8765)))
    ap.add_argument("--timeout", type=float, default=300, help="seconds per request")
    ap.add_argument("--sizes", type=lambda s: [float(x) for x in s.split(",")], default=[2, 8, 16, 32, 48])
    ap.add_argument("--pause", type=float, default=0, help="seconds between the size requests (0 = show the per-minute limit)")
    ap.add_argument("--project", help="OSB project folder (agent)")
    ap.add_argument("--research", help="research/<project>/<proxy> folder (agent)")
    ap.add_argument("--kit", default=os.environ.get("KIT", str(Path(__file__).resolve().parents[1])))
    ap.add_argument("--turns", type=int, default=12, help="model calls of one research run (agent)")
    ap.add_argument("--grow", type=int, default=2500, help="tokens one turn adds (agent)")
    ap.add_argument("--window", type=int, default=64000)
    ap.add_argument("--call-s", type=float, default=20, help="seconds one answer takes (agent estimate)")
    ap.add_argument("--last", type=int, default=15, help="calls shown with their size (log)")
    ap.add_argument("--gap", type=float, default=float(os.environ.get("PACER_GAP", 4)))
    a = ap.parse_args()
    if a.action == "agent" and not (a.project and a.research):
        ap.error("agent needs --project <osb-project-dir> --research <research/<project>/<proxy>>")
    return {"config": cmd_config, "burst": cmd_burst, "paced": cmd_paced, "size": cmd_size, "agent": cmd_agent, "log": cmd_log}[a.action](a)


if __name__ == "__main__":
    sys.exit(main())
