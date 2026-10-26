#!/usr/bin/env python3
"""Local smoke run of an HTTP request/reply module: the route really running, called over HTTP, backends stubbed.

    smoke_http.py modules/<project>/<proxy> [--port 8089] [--stub-port 8099] [--timeout 120] [--mvn "mvn -B -q -s ..."]
                  [--engine mvn|jbang]

What it proves, beyond the L1 tests (which call the route in-process with mock endpoints):
  curl -> platform-http entry of the running route -> http backend call -> stub server -> reply to the caller.
Steps: 1. a stub HTTP server on 127.0.0.1:<stub-port> answers every backend with src/test/resources/stubs/<name>.*;
2. the route starts on Camel Main (`mvn -Prun-local compile exec:java`, the module's own profile; or, with
--engine jbang, as Camel K runs it: `camel run` of the route YAML + the Java sources + the Camel K properties with
the dependency list of integration.yaml, no Maven build of the module) with each
backend.<name> property pointed at the stub and camel-platform-http-main listening on <port>; every {{env:X}} /
${env:X} name of the route gets a fake value smoke-X; 3. every parity case (input.payload + headers.json) is POSTed
to the entry path; a reply must have a 2xx status (outcome success) or error_http_status (other outcomes) and, where
expected-output.json/.xml exists, the same body (JSON-aware, generated_fields ignored); 4. the stub is switched to 500
and the first case is sent again: the route must answer error_http_status. Writes SMOKE.json + SMOKE.txt in the
module, the route log to target/smoke-route.log. Prints names and counts only, never message values. Exit 1 on any
failure, 2 when the module is not an HTTP flow (JMS flows: broker/run_local.sh). Stdlib only, Git Bash/Windows + macOS.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ENV_REF = re.compile(r"(?:\{\{|\$\{)env:([A-Za-z_][A-Za-z0-9_]*)")
CONTENT_TYPES = {".json": "application/json", ".xml": "application/xml", ".txt": "text/plain"}


def win_path(arg: str) -> str:
    """Git Bash path (/c/Users/x) -> Windows path (c:/Users/x) when running natively on Windows; else unchanged."""
    return re.sub(r"^/([a-zA-Z])/", r"\1:/", arg) if os.name == "nt" else arg


def read_properties(path: Path) -> dict[str, str]:
    """key=value lines of a .properties file (comments and blank lines skipped, CRLF tolerated)."""
    props: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        props[k.strip()] = v.strip()
    return props


def entry_path(props: dict[str, str]) -> str | None:
    """The HTTP path of flow.input when the flow is an HTTP entry (platform-http:<path>), else None."""
    m = re.match(r"platform-http:(/[^?]*)", props.get("flow.input", ""))
    return m.group(1) if m else None


def backends(props: dict[str, str], mod: Path | None = None) -> dict[str, str]:
    """The backend endpoints: backend.<name> properties the route calls as an endpoint URI. A module may keep other
    backend.<name> values (header values such as an API key or a request id taken from the env); those are no endpoint
    and get no stub. Route known: the names used in a uri. Else: values that look like an endpoint URI."""
    cand = {k[len("backend."):]: v for k, v in props.items() if k.startswith("backend.")}
    used: set[str] = set()
    if mod is not None:
        for y in (mod / "src/main/resources/routes").glob("*.yaml"):
            for line in y.read_text(encoding="utf-8").splitlines():
                if re.search(r"\b(uri|to)\s*:", line):
                    used |= set(re.findall(r"\{\{backend\.([\w.-]+)\}\}", line))
    if used:
        return {n: v for n, v in cand.items() if n in used}
    return {n: v for n, v in cand.items() if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:(//)?[^{]", v)}


def stub_uri(uri: str, stub_port: int) -> str:
    """scheme://host[:port] of a backend URI -> http://127.0.0.1:<stub-port>; path, query and options stay."""
    return re.sub(r"^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?]+", f"http://127.0.0.1:{stub_port}", uri, count=1)


def uri_path(uri: str) -> str:
    rest = re.sub(r"^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?]+", "", uri, count=1)
    return rest.split("?", 1)[0] or "/"


def env_names(*texts: str) -> set[str]:
    return {m.group(1) for t in texts for m in ENV_REF.finditer(t)}


def drop(node, dotted: str) -> None:
    parts = dotted.split(".")
    for p in parts[:-1]:
        node = node.get(p) if isinstance(node, dict) else None
        if node is None:
            return
    if isinstance(node, dict):
        node.pop(parts[-1], None)


def first_difference(want, got, path: str = "$") -> str | None:
    """Key path of the first difference between two JSON values; never a value."""
    if type(want) is not type(got):
        return f"{path}: type {type(want).__name__} vs {type(got).__name__}"
    if isinstance(want, dict):
        for k in want:
            if k not in got:
                return f"{path}.{k}: missing"
            d = first_difference(want[k], got[k], f"{path}.{k}")
            if d:
                return d
        extra = [k for k in got if k not in want]
        return f"{path}.{extra[0]}: unexpected" if extra else None
    if isinstance(want, list):
        if len(want) != len(got):
            return f"{path}: length {len(want)} vs {len(got)}"
        for i, (a, b) in enumerate(zip(want, got)):
            d = first_difference(a, b, f"{path}[{i}]")
            if d:
                return d
        return None
    return None if want == got else f"{path}: value differs"


def compare_reply(expected_file: Path, body: bytes, generated_fields: list[str]) -> str | None:
    """None when the reply equals the golden file; else the first difference (key path only)."""
    text = body.decode("utf-8", errors="replace")
    if expected_file.suffix == ".json":
        try:
            want = json.loads(expected_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return "golden file is not JSON"
        try:
            got = json.loads(text)
        except json.JSONDecodeError:
            return "reply is not JSON"
        for g in generated_fields:
            drop(want, g)
            drop(got, g)
        return first_difference(want, got)
    norm = lambda s: re.sub(r">\s+<", "><", s.strip())  # noqa: E731
    return None if norm(expected_file.read_text(encoding="utf-8")) == norm(text) else "xml text differs"


class Stub(BaseHTTPRequestHandler):
    """Answers every backend with its stub file; counts calls per backend; `fail` makes it answer 500."""
    routes: dict[str, tuple[str, str, bytes]] = {}       # path -> (backend name, content type, body)
    counts: dict[str, int] = {}
    fail = False
    lock = threading.Lock()

    def _answer(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)                       # consumed, never logged
        path = self.path.split("?", 1)[0]
        hit = self.routes.get(path) or (next(iter(self.routes.values())) if len(self.routes) == 1 else None)
        if not hit:
            self.send_response(404)
            self.end_headers()
            return
        name, ctype, body = hit
        with self.lock:
            self.counts[name] = self.counts.get(name, 0) + 1
        if self.fail:
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"stub failure"}')
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _answer

    def log_message(self, fmt, *args):                    # no request lines on the console
        pass


def stub_files(stubs_dir: Path, names: list[str]) -> dict[str, tuple[str, bytes]]:
    out = {}
    for n in names:
        for ext, ctype in CONTENT_TYPES.items():
            p = stubs_dir / (n + ext)
            if p.is_file():
                out[n] = (ctype, p.read_bytes())
    return out


def port_open(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(1)
        return s.connect_ex(("127.0.0.1", port)) == 0


def call(url: str, data: bytes, headers: dict[str, str]) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def stop(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
    else:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)


def mvn_command(spec: str) -> list[str]:
    args = [win_path(os.path.expanduser(x)) for x in shlex.split(spec) if x != "-q"]   # -q would silence the route's log
    exe = shutil.which(args[0]) or shutil.which(args[0] + ".cmd")
    if not exe:
        raise FileNotFoundError(f"cannot find {args[0]} on PATH")
    return [exe] + args[1:]


def jbang_launcher() -> list[str]:
    """Camel JBang through the kit's JBang wrapper (the JBang jar comes from Nexus), the same on Git Bash and macOS."""
    sh = Path(__file__).resolve().parents[1] / "assets/templates/package/tools/jbang.sh"
    bash = git_bash()
    if not bash:
        raise FileNotFoundError("bash not on PATH (Git Bash)")
    return [bash, win_path(str(sh))]


def git_bash() -> str | None:
    """bash for the kit's shell wrappers. On Windows the first bash.exe on PATH is often WSL's launcher
    (C:\\Windows\\System32\\bash.exe or WindowsApps), which starts Linux and fails at once: take Git Bash instead."""
    if os.name != "nt":
        return shutil.which("bash")
    for d in os.environ.get("PATH", "").split(os.pathsep):
        low = d.lower().replace("/", "\\")
        if not d or "\\windows\\system32" in low or "windowsapps" in low:
            continue
        cand = Path(win_path(d)) / "bash.exe"
        if cand.is_file():
            return str(cand)
    git = shutil.which("git")
    if git:
        for rel in ("../bin/bash.exe", "../../bin/bash.exe", "../usr/bin/bash.exe"):
            cand = (Path(git).parent / rel).resolve()
            if cand.is_file():
                return str(cand)
    return None


def camel_version() -> str:
    src = (Path(__file__).resolve().parent / "assemble_jbang.py").read_text(encoding="utf-8")
    return os.environ.get("CAMEL_VERSION") or re.search(r'^CAMEL_VERSION = "([^"]+)"', src, re.M).group(1)


def maven_settings(mvn_spec: str) -> str:
    """The -s file of MVN_ARGS / --mvn (camel run resolves --dep with the same settings as Maven), else ~/.m2."""
    args = shlex.split(mvn_spec)
    for i, x in enumerate(args[:-1]):
        if x in ("-s", "--settings"):
            return win_path(os.path.expanduser(args[i + 1]))
    return str(Path.home() / ".m2" / "settings.xml")


def jbang_command(mod: Path, port: int, timeout: int, overrides: dict[str, str], mvn_spec: str) -> list[str]:
    """`camel run` of the module the way Camel K runs it: route YAML + Java sources (compiled by Camel, as on Camel K)
    + other resources, the Camel K variant of application.properties with the overrides applied, the dependency list
    camelk_manifests.py writes into integration.yaml. Writes target/camel-run/application.properties."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import camelk_manifests as cm   # noqa: E402  (same folder)
    res = mod / "src/main/resources"
    routes = sorted((res / "routes").glob("*.yaml"))
    java = sorted((mod / "src/main/java").rglob("*.java"))
    other = sorted(p for p in res.rglob("*") if p.is_file() and p.parent != res / "routes" and p.name != "application.properties")
    text = (res / "application.properties").read_text(encoding="utf-8")
    props = cm.camelk_properties(text)
    lines = []
    for line in props.splitlines():
        k = line.split("=", 1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else None
        lines.append(f"{k}={overrides[k]}" if k in overrides else line)
    lines += [f"{k}={v}" for k, v in overrides.items() if not any(l.startswith(k + "=") for l in lines)]
    out = mod / "target/camel-run"
    out.mkdir(parents=True, exist_ok=True)
    (out / "application.properties").write_text("\n".join(lines) + "\n", encoding="utf-8")
    used = "\n".join([text] + [r.read_text(encoding="utf-8") for r in routes + java])
    deps = cm.module_deps(mod, used)
    return (jbang_launcher() + ["--main", "main.CamelJBang", f"org.apache.camel:camel-jbang-main:{camel_version()}", "run"]
            + [win_path(str(p)) for p in routes + java + other]
            + [f"--properties={win_path(str(out / 'application.properties'))}", f"--dep={','.join(deps)}",
               f"--maven-settings={maven_settings(mvn_spec)}", f"--max-seconds={timeout + 600}", f"--name={mod.name}"]
            + ([f"--port={port}"] if port else []))


def hint(log: Path, offset: int) -> list[str]:
    """Exception lines the route logged since `offset`, redacted (no query strings, no digit runs): names only."""
    text = log.read_bytes()[offset:].decode("utf-8", errors="replace")
    out = []
    for line in text.splitlines():
        if re.search(r"[A-Za-z]+(Exception|Error)\b|Invalid url|Caused by", line) and "oracle.osb" not in line:
            line = re.sub(r"\?\S*", "?...", line)
            line = re.sub(r"\d{4,}", "#", line)
            out.append(line.strip()[:200])
        if len(out) == 2:
            break
    return out


def cases(parity: Path) -> list[Path]:
    return sorted(p.parent for p in parity.rglob("input.payload")) if parity.is_dir() else []


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--port", type=int, default=8089, help="platform-http port of the route")
    ap.add_argument("--stub-port", type=int, default=8099, help="port of the stub backend server")
    ap.add_argument("--timeout", type=int, default=120, help="seconds to wait for the route to listen")
    ap.add_argument("--mvn", default=os.environ.get("VERIFY_MVN", "mvn -B -q " + os.environ.get("MVN_ARGS", "")))
    ap.add_argument("--engine", choices=("mvn", "jbang"), default="mvn",
                    help="mvn: the module's run-local profile; jbang: camel run as Camel K runs it (local_acceptance.sh)")
    a = ap.parse_args()
    mod = a.module.resolve()
    res = mod / "src/main/resources"
    props = read_properties(res / "application.properties")
    path = entry_path(props)
    if not path:
        print(f"not an HTTP flow (flow.input={props.get('flow.input', '<none>')}): use broker/run_local.sh {a.module}")
        return 2
    if a.engine == "mvn" and "camel-platform-http-main" not in (mod / "pom.xml").read_text(encoding="utf-8"):
        print("pom.xml has no camel-platform-http-main: the route cannot listen on Camel Main (scaffold a fresh module)")
        return 2
    be = backends(props, mod)
    cfg = json.loads((mod / "src/test/resources/flow-test.json").read_text(encoding="utf-8"))
    err_status = int(cfg.get("error_http_status") or 500)
    generated = [str(g) for g in cfg.get("generated_fields") or []]
    for p in (a.port, a.stub_port):
        if port_open(p):
            print(f"port {p} is already in use: pick another with --port/--stub-port")
            return 1
    stubs = stub_files(mod / "src/test/resources/stubs", list(be))
    missing = [n for n in be if n not in stubs]
    if missing:
        print(f"no stub file for backend(s) {missing} in src/test/resources/stubs (gate K6)")
        return 1
    Stub.routes = {uri_path(uri): (n, stubs[n][0], stubs[n][1]) for n, uri in be.items()}
    Stub.counts = {n: 0 for n in be}
    Stub.fail = False
    server = ThreadingHTTPServer(("127.0.0.1", a.stub_port), Stub)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    route_files = list((res / "routes").glob("*.yaml")) + [res / "application.properties"]
    env = dict(os.environ)
    fake = sorted(n for n in env_names(*(f.read_text(encoding="utf-8") for f in route_files)) if n not in env)
    for n in fake:
        env[n] = f"smoke-{n}"
    sysprops = [f"-Dbackend.{n}={stub_uri(uri, a.stub_port)}" for n, uri in be.items()]
    sysprops += ["-Dcamel.server.enabled=true", f"-Dcamel.server.port={a.port}", f"-Dcamel.main.durationMaxSeconds={a.timeout + 600}"]
    try:
        if a.engine == "jbang":
            cmd = jbang_command(mod, a.port, a.timeout, {f"backend.{n}": stub_uri(uri, a.stub_port) for n, uri in be.items()}, a.mvn)
        else:
            cmd = mvn_command(a.mvn) + ["-f", str(mod / "pom.xml"), "-Prun-local", "compile", "exec:java"] + sysprops
    except FileNotFoundError as e:
        print(e)
        return 1
    (mod / "target").mkdir(exist_ok=True)
    log = mod / "target/smoke-route.log"
    print(f"route ({a.engine}): {path} on :{a.port}; backends {list(be)} -> stub :{a.stub_port}; fake env {fake}; log target/smoke-route.log")
    result = {"module": str(mod), "entry": path, "port": a.port, "engine": a.engine, "cases": [], "error_case": None, "backend_calls": {}, "ok": False}
    with log.open("wb") as lf:
        proc = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT, env=env, cwd=str(mod),
                                **({} if os.name == "nt" else {"start_new_session": True}))
    try:
        t0 = time.time()
        while not port_open(a.port):
            if proc.poll() is not None or time.time() - t0 > a.timeout:
                why = "exited" if proc.poll() is not None else f"did not listen within {a.timeout}s"
                print(f"ROUTE DID NOT START ({why}); first errors of target/smoke-route.log:")
                for line in [l for l in log.read_text(encoding="utf-8", errors="replace").splitlines()
                             if re.search(r"ERROR|Exception|Caused by|BUILD FAILURE", l)][:8]:
                    print("   " + line[:160])
                return 1
            time.sleep(1)
        print(f"route up after {int(time.time() - t0)}s")
        url = f"http://127.0.0.1:{a.port}{path}"
        failed = 0
        all_cases = cases(mod / "src/test/resources/parity")
        if not all_cases:
            print("no parity case with input.payload")
            return 1
        for c in all_cases:
            name = str(c.relative_to(mod / "src/test/resources/parity"))
            headers = {k: str(v) for k, v in json.loads((c / "headers.json").read_text(encoding="utf-8")).items()} if (c / "headers.json").is_file() else {}
            headers.setdefault("Content-Type", "application/json" if cfg.get("payload_format", "json") == "json" else "application/xml")
            expected = json.loads((c / "expected.json").read_text(encoding="utf-8")) if (c / "expected.json").is_file() else {}
            want_ok = expected.get("outcome", "success") == "success"
            offset = log.stat().st_size
            status, body = call(url, (c / "input.payload").read_bytes(), headers)
            golden = next((c / f for f in ("expected-output.json", "expected-output.xml") if (c / f).is_file()), None)
            problem = None
            if want_ok and not 200 <= status < 300:
                problem = f"status {status}"
            elif not want_ok and status != err_status:
                problem = f"status {status}, expected {err_status}"
            elif want_ok and golden:
                problem = compare_reply(golden, body, generated)
            note = "" if golden else " (status only: no expected-output file)"
            print(f"{'FAIL' if problem else 'PASS'} {name}{': ' + problem if problem else note}")
            if problem:
                for h in hint(log, offset):
                    print("   " + h)
            failed += bool(problem)
            result["cases"].append({"case": name, "status": status, "golden": bool(golden), "problem": problem})
        Stub.fail = True
        status, body = call(url, (all_cases[0] / "input.payload").read_bytes(),
                            {k: str(v) for k, v in json.loads((all_cases[0] / "headers.json").read_text(encoding="utf-8")).items()} if (all_cases[0] / "headers.json").is_file() else {})
        try:
            json.loads(body.decode("utf-8", errors="replace"))
            kind = "json"
        except json.JSONDecodeError:
            kind = "empty" if not body.strip() else "text"
        err_ok = status == err_status
        print(f"{'PASS' if err_ok else 'FAIL'} error case: backend 500 -> reply status {status} (expected {err_status}), body {kind}")
        result["error_case"] = {"status": status, "expected": err_status, "body": kind, "ok": err_ok}
        result["backend_calls"] = dict(Stub.counts)
        result["ok"] = failed == 0 and err_ok
        print(f"smoke: {len(all_cases)} cases, {failed} failed, error case {'ok' if err_ok else 'FAIL'}, backend calls: {dict(Stub.counts)}")
        return 0 if result["ok"] else 1
    finally:
        stop(proc)
        server.shutdown()
        (mod / "SMOKE.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        lines = [f"{'PASS' if not c['problem'] else 'FAIL'} {c['case']} (status {c['status']})" for c in result["cases"]]
        if result["error_case"]:
            lines.append(f"error case: status {result['error_case']['status']} expected {result['error_case']['expected']} -> {'ok' if result['error_case']['ok'] else 'FAIL'}")
        lines.append(f"backend calls: {result['backend_calls']}")
        lines.append(f"engine: {result.get('engine')}")
        lines.append("smoke OK" if result["ok"] else "smoke FAILED")
        (mod / "SMOKE.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
