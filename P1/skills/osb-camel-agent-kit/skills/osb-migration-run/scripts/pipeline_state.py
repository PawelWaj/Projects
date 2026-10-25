#!/usr/bin/env python3
"""State of the OSB -> Camel K run for one or more projects, and the ONE next step.
    pipeline_state.py '<a-prj|b-prj>' [--json] [--ws <workspace>]

Reads what the kit scripts left behind (research pack check, task1 cases, module gates, card, mutation check, smoke or
broker run, review package, Camel K manifest) and what the environment has (settings, Maven settings, Artemis, JBang,
pi). Prints one line per item: done / todo / BLOCKED (a person must act) and `next:` = the exact command to run, or
`HUMAN:` what the person must do, or `DONE:` the handover. Secrets are reported as set/unset only; names and counts,
never message values. Deterministic: the same files give the same answer, so an agent can rerun it after every step.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import urllib.request
from pathlib import Path

SKILLS = "skills/osb-camelk-route/scripts"


def env_file(ws: Path) -> dict:
    """export KEY="value" lines of .osb-kit.env as a dict (the file is sourced by the shell; here only read)."""
    f = ws / ".osb-kit.env"
    out = {}
    if f.is_file():
        for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r'^\s*export\s+([A-Z_][A-Z0-9_]*)=["\']?(.*?)["\']?\s*(#.*)?$', line)
            if m and not m.group(2).startswith("${"):
                out[m.group(1)] = m.group(2)
    return out


def win_path(arg: str) -> str:
    """Git Bash path (/c/Users/x) -> Windows path (c:/Users/x) when running natively on Windows; else unchanged.
    .osb-kit.env and the exports of a Git Bash session carry /c/... and /e/... paths, which a Windows Python cannot open."""
    return re.sub(r"^/([a-zA-Z])/", r"\1:/", arg) if os.name == "nt" else arg


def setting(name: str, env: dict, default: str = "") -> str:
    v = os.environ.get(name) or env.get(name) or default
    return win_path(v.replace("~", str(Path.home()))) if v else v


def console_up(url: str) -> bool:
    try:
        with urllib.request.urlopen(url + "/", timeout=2) as r:   # noqa: S310 (localhost console)
            return r.status in (200, 301, 302, 303, 401)
    except Exception as e:  # urllib raises on 401 too: that still proves the console answers
        return "401" in str(e) or "Unauthorized" in str(e)


def proxies(app: Path, filt: str) -> list[tuple[str, str]]:
    """'<project> <proxy>' pairs as run_domain.sh flows(): every .proxy/.ProxyService file of the selected projects."""
    out = []
    for prj in sorted(p for p in app.iterdir() if p.is_dir() and not p.name.startswith(".")) if app.is_dir() else []:
        if not re.fullmatch(f"({filt})", prj.name):
            continue
        files = sorted(f for f in prj.rglob("*") if f.is_file() and f.suffix in (".proxy", ".ProxyService"))
        out += [(prj.name, f.stem) for f in files]
    return out


def task1_dir(ws: Path, p: str, x: str) -> Path | None:
    slug = re.sub(r"[^A-Za-z0-9]+", "-", f"{p}-{x}").strip("-").lower()[:80]
    d = ws / "task1" / "flows" / slug
    return d if (d / "fixtures" / "parity").is_dir() else None


def jload(f: Path) -> dict | None:
    try:
        return json.loads(f.read_text(encoding="utf-8"))
    except Exception:
        return None


def newest(path: Path) -> float:
    """newest mtime under src/main of a module (route, properties, beans): what pi may have changed."""
    files = [f for f in (path / "src" / "main").rglob("*") if f.is_file()] if (path / "src" / "main").is_dir() else []
    return max((f.stat().st_mtime for f in files), default=0.0)


def mtime(f: Path) -> float:
    return f.stat().st_mtime if f.is_file() else 0.0


class State:
    def __init__(self, ws: Path, filt: str):
        self.ws, self.filt = ws, filt
        self.env = env_file(ws)
        self.kit = Path(setting("KIT", self.env, str(Path(__file__).resolve().parents[3])))
        self.app = Path(setting("APP", self.env, "/nonexistent"))
        self.items: list[tuple[str, str, str, str]] = []   # (scope, name, status, detail)
        self.next: dict | None = None

    def add(self, scope, name, status, detail=""):
        self.items.append((scope, name, status, detail))

    def propose(self, kind, text, stage, scope="env"):
        if self.next is None:
            self.next = {"kind": kind, "text": text, "stage": stage, "scope": scope}

    # --- environment -------------------------------------------------------------------------------------------------
    def environment(self):
        kit_ok = (self.kit / "pi" / "vdi_session.sh").is_file()
        self.add("env", "kit", "done" if kit_ok else "BLOCKED", str(self.kit))
        if not kit_ok:
            self.propose("human", f"kit not found at {self.kit}: unzip the repository and export KIT=<kit folder>", "kit")
        has_env = (self.ws / ".osb-kit.env").is_file()
        n_prj = len([p for p in self.app.glob("*-prj") if p.is_dir()]) if self.app.is_dir() else 0
        self.add("env", "settings", "done" if has_env and n_prj else "BLOCKED",
                 f".osb-kit.env {'present' if has_env else 'missing'}, APP={self.app} ({n_prj} *-prj)")
        if not (has_env and n_prj):
            self.propose("human", "run once in the workspace: bash $KIT/pi/vdi_session.sh setup <osb-application-folder> "
                                  "(the folder above the *-prj folders)", "setup")
        mvn_args = setting("MVN_ARGS", self.env)
        m = re.search(r"(?:^|\s)(?:-s|--settings)\s+(\S+)", mvn_args)
        sfile = Path(win_path(m.group(1).replace("~", str(Path.home())))) if m else Path.home() / ".m2" / "settings.xml"
        home_settings = (Path.home() / ".m2" / "settings.xml").is_file()
        ok = sfile.is_file() and home_settings
        self.add("env", "maven-settings", "done" if ok else "BLOCKED",
                 f"{sfile} {'present' if sfile.is_file() else 'MISSING'}; ~/.m2/settings.xml {'present' if home_settings else 'MISSING (JBang reads only that file)'}")
        if not ok:
            self.propose("human", "write ~/.m2/settings.xml with the client Nexus mirror (runbook step 2), then: "
                                  "curl -s -o /dev/null -w '%{http_code}' <nexus>/repository/maven-public/junit/junit/4.13.2/junit-4.13.2.pom  -> 200", "nexus")
        home = Path(setting("ARTEMIS_HOME", self.env, "/nonexistent"))
        broker = Path(setting("ARTEMIS_BROKER", self.env, str(self.ws.parent / "artemis-broker")))
        console = setting("ARTEMIS_CONSOLE", self.env, "http://localhost:8161")
        dist = (home / "lib" / "artemis-boot.jar").is_file()
        inst = (broker / "etc" / "broker.xml").is_file()
        up = console_up(console) if inst else False
        jb = shutil.which("jbang") is not None
        smoke_env = (self.ws / ".env-smoke" / "SMOKE.ts").is_file()
        pw = bool(os.environ.get("ARTEMIS_PASSWORD"))
        self.add("env", "artemis", "done" if dist and inst and up else "todo",
                 f"distribution {'ok' if dist else 'missing'}, instance {'ok' if inst else 'missing'}, broker {'running' if up else 'down'}, ARTEMIS_PASSWORD {'set' if pw else 'unset'}")
        self.add("env", "jbang", "done" if jb else "todo", "on PATH" if jb else "not on PATH")
        self.add("env", "camel-smoke", "done" if smoke_env else "todo", "JBang smoke test passed" if smoke_env else "not run yet")
        if not (dist and inst and jb and smoke_env):
            if not pw:
                self.propose("human", "export ARTEMIS_PASSWORD='<choose one>' (per session, never in a file), then rerun", "artemis-password")
            else:
                self.propose("command", "bash $KIT/pi/env_setup.sh install && . ./.osb-kit.env", "env-install")
        elif not up:
            if not pw:
                self.propose("human", "export ARTEMIS_PASSWORD='<the instance password>' then rerun", "artemis-password")
            else:
                self.propose("command", "bash $KIT/broker/artemis_setup.sh start", "broker-start")
        self.pi = shutil.which("pi") is not None
        model = os.environ.get("OSB_PI_MODEL", "")
        self.add("env", "pi", "done" if self.pi and model else "todo",
                 f"{'on PATH' if self.pi else 'NOT on PATH'}, OSB_PI_MODEL {model or 'unset'}")
        exp = win_path(os.environ.get("EXPORT", ""))
        self.export = bool(exp) and Path(exp).is_file()
        self.mask = bool(os.environ.get("MASK_KEY"))
        self.add("env", "splunk-export", "done" if self.export else "none",
                 (f"EXPORT set ({Path(exp).name}), MASK_KEY {'set' if self.mask else 'UNSET'}" if self.export
                  else "no EXPORT: existing task1 cases are used, missing scenarios get synthetic cases"))
        if self.export and not self.mask:
            self.propose("human", "export MASK_KEY='<from the data owner>' (typed, never in a file) so task1 can mask the export", "mask-key")

    # --- one proxy ---------------------------------------------------------------------------------------------------
    def proxy(self, p: str, x: str):
        sc = f"{p}/{x}"
        r = self.ws / "research" / p / x
        m = self.ws / "modules" / p / x
        kit = "$KIT"
        pi_note = "" if self.pi else " (needs pi on PATH: BLOCKED on this machine)"
        chk = jload(r / "SHARE_CHECK.json") or {}
        research = bool(chk.get("pass"))
        self.add(sc, "research", "done" if research else "todo", "pack check PASS" if research else "no PASS pack")
        t1 = task1_dir(self.ws, p, x)
        n_t1 = len(list((t1 / "fixtures" / "parity").rglob("input.payload"))) if t1 else 0
        self.add(sc, "task1", "done" if t1 else ("todo" if self.export else "none"),
                 f"{n_t1} real cases" if t1 else ("export set: task1 runs in flows" if self.export else "no export"))
        gates = jload(m / "GATES.json")
        built = gates is not None and (m / "pom.xml").is_file()
        g = (gates or {}).get("gates", {})
        bad = [k.split("_")[0] for k, v in g.items() if not v.get("ok")]
        k8 = g.get("K8_tests_green", {})
        self.add(sc, "module", "done" if built else "todo",
                 (f"gates: {', '.join(bad) + ' FAIL' if bad else 'all ok'}; tests {k8.get('tests', '-')}/{k8.get('failures', '-')}F/{k8.get('skipped', '-')}S"
                  if built else "not built"))
        if not research or (self.export and not t1) or not built:
            self.propose("command", f"GEN=skills bash {kit}/pi/vdi_session.sh flows '{p}' 2>&1 | tee -a domain/agent-run.log{pi_note}", "flows", sc)
            return
        card = (m / "FLOW_CARD.md").read_text(encoding="utf-8", errors="replace") if (m / "FLOW_CARD.md").is_file() else ""
        approved = bool(re.search(r"^Status:\s*approved\s*$", card, re.M | re.I)) and bool(re.search(r"^Approver:\s*\S+", card, re.M))
        open_q = len(re.findall(r"^- \[ \]", card, re.M))
        status = re.search(r"^Status:\s*(.*)$", card, re.M)
        self.add(sc, "card", "done" if approved and not open_q else "BLOCKED",
                 f"{status.group(1).strip() if status else 'no card'}; {open_q} open question(s) unticked")
        others_bad = [k for k in bad if k != "K1"]
        if others_bad:
            self.propose("command", f"GEN=skills bash {kit}/pi/vdi_session.sh review '{p}' 2>&1 | tee -a domain/agent-run.log{pi_note}", "review-fix", sc)
            return
        if not approved or open_q:
            self.propose("human", f"approve the flow card {m / 'FLOW_CARD.md'}: read it against {r / 'RESEARCH.md'}, tick every "
                                  f"'- [ ]' open question (answered or accepted with a reason), set 'Status: approved', 'Approver: <name>', "
                                  f"'Date: <YYYY-MM-DD>'; then rerun", "card-approval", sc)
            return
        if "K1" in bad or mtime(m / "FLOW_CARD.md") > mtime(m / "GATES.json"):
            self.propose("command", f"GEN=skills bash {kit}/pi/vdi_session.sh review '{p}' 2>&1 | tee -a domain/agent-run.log{pi_note}", "review-refreeze", sc)
            return
        src_t = newest(m)
        mut = jload(m / "MUTATION.json")
        mut_ok = bool(mut) and mut.get("total", 0) > 0 and mut.get("killed") == mut.get("total") and mtime(m / "MUTATION.json") >= src_t
        survived = [z.get("what", "?") for z in (mut or {}).get("mutations", []) if not z.get("killed")] if mut else []
        acc = m / "MUTATION_ACCEPTED.md"   # a person's written decision on a surviving mutation (reason inside), newer than the check
        accepted = survived and acc.is_file() and mtime(acc) >= mtime(m / "MUTATION.json") and mtime(m / "MUTATION.json") >= src_t
        if accepted:
            mut_ok = True
        self.add(sc, "mutations", "done" if mut_ok else ("BLOCKED" if survived and mtime(m / "MUTATION.json") >= src_t else "todo"),
                 (f"caught {mut.get('killed')}/{mut.get('total')}" if mut and mut.get("total") else "not run")
                 + (" (stale)" if mut and mtime(m / "MUTATION.json") < src_t else "") + (f", survivor accepted by a person ({acc.name})" if accepted else ""))
        if not mut_ok:
            if survived and mtime(m / "MUTATION.json") >= src_t:
                self.propose("human", f"mutation(s) survived on {sc}: {', '.join(survived)} — the tests do not catch it; a person decides "
                                      f"(a missing scenario or case in research/task1 -> fix and rerun flows; or accept it with the reason written "
                                      f"into {acc}) before the handover", "mutation-survived", sc)
                return
            self.propose("command", f"python {kit}/{SKILLS}/mutate_route.py {m} --mvn \"mvn -B -q $MVN_ARGS\" 2>&1 | tee -a domain/agent-run.log", "mutations", sc)
            return
        props = (m / "src/main/resources/application.properties").read_text(encoding="utf-8", errors="replace") if (m / "src/main/resources/application.properties").is_file() else ""
        http = bool(re.search(r"^flow\.input=platform-http:", props, re.M))
        if http:
            sm = jload(m / "SMOKE.json")
            sm_ok = bool(sm) and sm.get("ok") and mtime(m / "SMOKE.json") >= src_t
            self.add(sc, "local-run", "done" if sm_ok else "todo",
                     (f"smoke {len(sm.get('cases', []))} cases, error case {'ok' if (sm.get('error_case') or {}).get('ok') else 'FAIL'}" if sm else "smoke not run")
                     + (" (stale)" if sm and mtime(m / "SMOKE.json") < src_t else ""))
            if not sm_ok:
                self.propose("command", f"bash {kit}/pi/vdi_session.sh smoke '{p}' 2>&1 | tee -a domain/agent-run.log", "smoke", sc)
                return
        else:
            e2e = jload(m / "target" / "e2e-result.json")
            e2e_ok = bool(e2e) and e2e.get("ok") and mtime(m / "target" / "e2e-result.json") >= src_t
            self.add(sc, "local-run", "done" if e2e_ok else "todo",
                     (f"broker run {e2e.get('cases', '-')} cases, {'ok' if e2e.get('ok') else 'DIFF'}" if e2e else "broker run not done"))
            if not e2e_ok:
                self.propose("command", f"bash {kit}/broker/e2e_local.sh {m} 2>&1 | tee -a domain/agent-run.log", "broker-run", sc)
                return
        tgz = self.ws / "review" / f"{p}-{x}.tgz"
        pack_ok = tgz.is_file() and mtime(tgz) >= max(src_t, mtime(m / "GATES.json"), mtime(m / "MUTATION.json"), mtime(m / "SMOKE.json"))
        self.add(sc, "review-pack", "done" if pack_ok else "todo", str(tgz) if pack_ok else "not packed (or older than the module)")
        if not pack_ok:
            self.propose("command", f"bash {kit}/pi/make_review_pack.sh {p} {x} 2>&1 | tee -a domain/agent-run.log", "review-pack", sc)
            return
        ck = jload(m / "camel-k" / "CHECK.json") or {}
        ready = bool(ck.get("ready")) and mtime(m / "camel-k" / "CHECK.json") >= src_t
        ns = os.environ.get("CAMELK_NAMESPACE", "")
        envf = win_path(os.environ.get("CAMELK_ENV_FILE", ""))
        open_vals = [o.split(":")[0] for o in ck.get("open", [])]
        self.add(sc, "deploy-file", "done" if ready else "todo",
                 "integration.yaml ready" if ready else f"open values: {', '.join(open_vals) or 'none listed'}; CAMELK_NAMESPACE {'set' if ns else 'unset'}, CAMELK_ENV_FILE {'set' if envf and Path(envf).is_file() else 'unset'}")
        if not ready:
            if not ns or not (envf and Path(envf).is_file()):
                self.propose("human", f"Dev values for {sc}: write {', '.join(open_vals) or 'the keys in camel-k/DEPLOY.md'} as KEY=VALUE into a local "
                                      f"file (e.g. dev.env, never in Git), then export CAMELK_NAMESPACE=<dev namespace> CAMELK_ENV_FILE=<that file>"
                                      f"{' CAMELK_BROKER_URL=amqp://<artemis-service>:5672' if not http else ''}; then rerun", "dev-values", sc)
            else:
                self.propose("command", f"bash {kit}/pi/vdi_session.sh deploy '{p}' 2>&1 | tee -a domain/agent-run.log", "deploy", sc)
            return
        self.add(sc, "handover", "done", f"{m / 'camel-k' / 'integration.yaml'} + DEPLOY.md -> the colleague (GitOps repo, Argo CD)")

    def run(self):
        self.environment()
        px = proxies(self.app, self.filt)
        if not px and self.app.is_dir():
            self.add("env", "projects", "BLOCKED", f"no proxy in APP matching '{self.filt}'")
            self.propose("human", f"no project matching '{self.filt}' under {self.app}: check the project name", "projects")
        for p, x in px:
            self.proxy(p, x)
        if self.next is None:
            self.next = {"kind": "done", "text": "every flow is ready: hand over camel-k/integration.yaml + DEPLOY.md per flow", "stage": "handover", "scope": "all"}
        return self

    def fingerprint(self) -> str:
        return hashlib.sha1(json.dumps([i[:3] for i in self.items] + [self.next["stage"], self.next["scope"]]).encode()).hexdigest()[:12]

    def text(self) -> str:
        w = max(len(i[1]) for i in self.items)
        out, scope = [], None
        for s, n, st, d in self.items:
            if s != scope:
                out.append(s if s == "env" else f"proxy {s}")
                scope = s
            out.append(f"  {n:<{w}}  {st:<8} {d}")
        k = self.next["kind"]
        out.append("")
        out.append(("next: " if k == "command" else "HUMAN: " if k == "human" else "DONE: ") + self.next["text"])
        return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("projects", help="'a-prj|b-prj' (regex alternatives, as PROJECTS of run_domain.sh)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--ws", default=".", help="workspace (default: current folder)")
    a = ap.parse_args()
    st = State(Path(win_path(a.ws)).resolve(), a.projects).run()
    if a.json:
        print(json.dumps({"items": [{"scope": s, "name": n, "status": t, "detail": d} for s, n, t, d in st.items],
                          "next": st.next, "fingerprint": st.fingerprint()}, indent=1))
    else:
        print(st.text())
    return {"command": 0, "human": 3, "done": 0}[st.next["kind"]]


if __name__ == "__main__":
    sys.exit(main())
