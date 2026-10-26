#!/usr/bin/env python3
"""Answer the open questions of a flow card: a recommended answer per question, computed from the evidence the chain
already has; the person accepts it with Enter or types their own. Then the card is approved.

    card_answers.py modules/<project>/<proxy>                    interactive: Enter accepts [recommended], s = skip
    card_answers.py modules/<project>/<proxy> --answers a.json   answers prepared in advance {question-prefix: answer}
    card_answers.py modules/<project>/<proxy> --defaults         every recommendation, no questions (lab / POC only)
    options: --approver "<name>"  (else asked, recommended from git config user.name / USERNAME)

Evidence per question (names and counts only, never message values): research.json (entry, outputs, backends,
errors, dependencies), the route YAML (CamelHttpMethod), the OSB source under $APP/<project> (.pipeline / .bix, file
and line of the HTTP method), MUTATION.json, GATES.json (K7, K9), the parity cases (counted), camel-k/CHECK.json and
the env names of the route (which go to the Secret). Writes the answers into FLOW_CARD.md section 9
("- [x] <question> -- answered|accepted: <text> [evidence: ...]"), sets Status/Approver/Date only when no question is
left open, keeps FLOW_CARD.md.bak-<time>, and writes CARD_ANSWERS.json as the audit trail. Afterwards:
`vdi_session.sh review '<project>'` refreezes the card (gate K1).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SECRETISH = re.compile(r"(?i)(PASSWORD|PASSWD|PWD|SECRET|TOKEN|API_?KEY|_KEY$|_USER$|USERNAME|CREDENTIAL)")
ENV_REF = re.compile(r"env[:.]([A-Z][A-Z0-9_]*)")
OPEN = re.compile(r"^- \[ \] (.*)$", re.M)


def win_path(arg: str) -> str:
    return re.sub(r"^/([a-zA-Z])/", r"\1:/", arg) if os.name == "nt" else arg


def jload(p: Path) -> dict:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def env_setting(ws: Path, name: str) -> str:
    v = os.environ.get(name, "")
    if not v and (ws / ".osb-kit.env").is_file():
        m = re.search(rf'^\s*export\s+{name}="?([^"\n]*)"?', (ws / ".osb-kit.env").read_text(encoding="utf-8"), re.M)
        v = m.group(1) if m and not m.group(1).startswith("${") else ""
    return win_path(v)


class Evidence:
    """Everything the rules read, loaded once."""

    def __init__(self, mod: Path):
        self.mod = mod
        self.meta = jload(mod / ".scaffold.json")
        self.project = self.meta.get("project") or mod.parent.name
        self.proxy = self.meta.get("proxy") or mod.name
        self.ws = mod.parents[2] if len(mod.parents) > 2 else mod.parent
        self.research = jload(self.ws / "research" / self.project / self.proxy / "research.json")
        res = mod / "src/main/resources"
        self.routes = {p.name: p.read_text(encoding="utf-8") for p in sorted((res / "routes").glob("*.yaml"))}
        self.props = (res / "application.properties").read_text(encoding="utf-8") if (res / "application.properties").is_file() else ""
        self.gates = (jload(mod / "GATES.json").get("gates") or {})
        self.mutation = jload(mod / "MUTATION.json")
        self.check = jload(mod / "camel-k/CHECK.json")
        self.name = re.sub(r"[^a-z0-9-]+", "-", self.proxy.lower()).strip("-")[:63]
        self.app = env_setting(self.ws, "APP")

    # -- facts -------------------------------------------------------------------------------------------------------
    def env_names(self) -> list[str]:
        names = ENV_REF.findall("\n".join([*self.routes.values(), self.props]))
        return list(dict.fromkeys(n for n in names if n not in ("OSB_FILES_DIR", "BROKER_URL", "BROKER_USER", "BROKER_PASSWORD")))

    def route_method(self) -> tuple[str, str]:
        for f, text in self.routes.items():
            lines = text.splitlines()
            for i, ln in enumerate(lines):
                if "CamelHttpMethod" in ln:
                    for nxt in lines[i + 1:i + 3]:
                        m = re.search(r'(?:constant|simple):\s*"?(GET|POST|PUT|DELETE|PATCH)"?', nxt)
                        if m:
                            return m.group(1), f"{f}:{i + 2}"
        return "", ""

    def osb_methods(self) -> list[tuple[str, str]]:
        """(method, file:line) in the OSB source of the project: route-node / business-service HTTP method settings."""
        base = Path(self.app) / self.project if self.app else None
        if not base or not base.is_dir():
            return []
        out = []
        for p in sorted([*base.rglob("*.pipeline"), *base.rglob("*.bix"), *base.rglob("*.biz")]):
            try:
                lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            for i, ln in enumerate(lines, 1):
                if re.search(r"(?i)(http-?method|request-?method|<[\w:]*method>|verb)", ln):
                    m = re.search(r"\b(GET|POST|PUT|DELETE|PATCH)\b", ln)
                    if m:
                        out.append((m.group(1), f"{p.relative_to(base)}:{i}"))
        return out

    def method_mutation(self) -> str:
        for m in self.mutation.get("mutations") or []:
            if "method" in str(m.get("what", "")).lower():
                return f"mutation '{m['what']}' {'caught' if m.get('killed') else 'SURVIVED'}"
        return "no method mutation in MUTATION.json"

    def cases(self) -> tuple[int, int]:
        par = self.mod / "src/test/resources/parity"
        real = synth = 0
        for c in par.glob("*/*/*"):
            if (c / "input.payload").is_file() or (c / "input.json").is_file():
                if "-synthetic" in str(c.relative_to(par)).split("/")[0]:
                    synth += 1
                else:
                    real += 1
        return real, synth

    def gate(self, k: str) -> str:
        g = next((v for n, v in self.gates.items() if n.startswith(k + "_")), None)
        return "not run" if g is None else ("ok" if g.get("ok") else "FAIL")


# -- rules -----------------------------------------------------------------------------------------------------------
def rule_host(q: str, e: Evidence):
    if not re.search(r"(?i)\b(host|endpoint|url|uri|address)\b", q):
        return None
    hosts = [n for n in e.env_names() if re.search(r"HOST|URL|URI|ENDPOINT", n)] or ["<BACKEND>_HOST"]
    return ("answered", f"per-environment value {', '.join(hosts)} from dev.env / the environment, never in code (gate K4 {e.gate('K4')})",
            f"route env names {', '.join(hosts)}; camel-k/CHECK.json open {len(e.check.get('open') or [])}")


def rule_method(q: str, e: Evidence):
    if not re.search(r"(?i)\b(method|GET|POST|PUT|verb)\b", q):
        return None
    rm, rloc = e.route_method()
    osb = e.osb_methods()
    mut = e.method_mutation()
    said = re.findall(r"\b(GET|POST|PUT|DELETE|PATCH)\b", q)
    override = re.search(r"(?i)overrid\w*\s+(?:\w+\s+){0,3}?(GET|POST|PUT|DELETE|PATCH)", q)
    want = (override.group(1) if override else "") or (osb[-1][0] if osb else "") or (said[-1] if said else "")
    ev = [f"route sends {rm or '?'} ({rloc or 'no CamelHttpMethod'})",
          ("OSB source: " + "; ".join(f"{m} at {loc}" for m, loc in osb[:3])) if osb else "OSB source not readable here (APP unset or no .pipeline/.bix)",
          mut]
    if want and rm and want != rm:
        return ("accepted", f"OSB sends {want} (the route-node setting wins at runtime); the route sends {rm}: "
                f"change CamelHttpMethod to {want} and rerun before Dev; confirm with one call on Dev", "; ".join(ev))
    return ("accepted", f"{want or rm} as OSB sends it (the route-node setting wins over the business service); "
            f"confirm with one call on Dev", "; ".join(ev))


def rule_empty(q: str, e: Evidence):
    if not re.search(r"(?i)\b(empty|no record|no records|not found|nothing)\b", q):
        return None
    return ("accepted", "same behaviour as OSB (the reply OSB gives today, no new error); a change is a functional "
            "decision for the flow owner", "migration rule: parity with OSB")


def rule_secret(q: str, e: Evidence):
    if not re.search(r"(?i)\b(dvm|credential|credentials|api.?key|secret|password|token)\b", q):
        return None
    names = e.env_names()
    sec = [n for n in names if SECRETISH.search(n) or not re.search(r"HOST|URL|URI|ENDPOINT|PORT|PATH", n)]
    extra = [n for n in sec if not SECRETISH.search(n)]
    tip = f"; CAMELK_SECRET_KEYS='{','.join(extra)}'" if extra else ""
    return ("answered", f"values come from Secret {e.name}-env, keys {', '.join(sec) or 'none'}{tip}; nothing in code or Git "
            f"(gate K4 {e.gate('K4')})", f"route env names {len(names)}, Secret keys {len(sec)}; DEPLOY.md lists the Secret")


def rule_scenario(q: str, e: Evidence):
    if not re.search(r"(?i)\b(scenario|scenarios|trace|traces|test data|log_scenarios|cases)\b", q):
        return None
    real, synth = e.cases()
    return ("answered", f"{real} real Splunk case(s) and {synth} synthetic case(s) in the tests; gate K9 {e.gate('K9')}",
            f"src/test/resources/parity: {real} real, {synth} synthetic")


def rule_messaging(q: str, e: Evidence):
    if not re.search(r"(?i)\b(selector|topic|queue|jms|subscription|destination)\b", q):
        return None
    en = e.research.get("entry") or {}
    outs = [o.get("name", "?") for o in e.research.get("outputs") or []]
    return ("answered", f"entry {en.get('destination', '?')}{' (topic, durable subscription)' if en.get('is_topic') else ''}"
            f"{', selector on the broker' if en.get('selector') else ''}; outputs {', '.join(outs) or '?'}; proven on the "
            "local Artemis run (local acceptance step 4)", f"research.json entry/outputs ({len(outs)} outputs)")


def rule_error(q: str, e: Evidence):
    if not re.search(r"(?i)(\berror|fault|retry|retries|redelivery|exception|errorcode|unreadable|nxsd fails)", q):
        return None
    errs = e.research.get("errors") or []
    heads = sorted({h for x in errs for h in (x.get("headers") or []) if re.match(r"^[A-Za-z]\w*$", h)})
    goes = sorted({str(x.get("goes_to")) for x in errs if x.get("goes_to")})
    err_cases = [s for s in e.research.get("scenario_mapping") or [] if any("error" in o for o in s.get("outputs") or [])]
    if re.search(r"(?i)errorcode", q):
        return ("accepted", "errorCode = the Camel exception class name (OSB's BEA-xxxxxx codes have no Camel equivalent); "
                "errorMessage and debugInfo as OSB; the error-queue consumer must not rely on BEA codes: tell its owner",
                f"error headers {', '.join(heads) or '?'}; FLOW_CARD section 7; GATES K7 {e.gate('K7')}")
    return ("answered", f"same error handling as OSB: {len(errs)} error scope(s) to {', '.join(goes) or '?'} with headers "
            f"{', '.join(heads) or '?'}; {len(err_cases)} error scenario(s) tested (gate K7 {e.gate('K7')}) and sent on the "
            "local Artemis run (local acceptance step 4)", f"research.json errors {len(errs)}, error scenarios {len(err_cases)}")


def rule_routing(q: str, e: Evidence):
    if not re.search(r"(?i)\b(both|first|branch|route vs publish|publish|which queue|order)\b", q):
        return None
    sm = e.research.get("scenario_mapping") or []
    multi = [s for s in sm if len(s.get("outputs") or []) > 1]
    if not multi:
        return None
    ex = "; ".join(f"{s.get('branch') or s.get('scenario')}: {' + '.join(s['outputs'])}" for s in multi[:2])
    return ("answered", f"both, as research reads the pipeline ({ex}); the parity test of that scenario expects every "
            f"output and the local Artemis run counts each queue", f"research.json scenario_mapping: {len(multi)} scenario(s) with more than one output")


RULES = (rule_secret, rule_host, rule_method, rule_empty, rule_error, rule_routing, rule_scenario, rule_messaging)


def recommend(q: str, e: Evidence) -> tuple[str, str, str]:
    for r in RULES:
        out = r(q, e)
        if out:
            return out
    return ("accepted", f"accepted for the POC as stated; to be confirmed by the flow owner", "no rule matched")


# -- card ------------------------------------------------------------------------------------------------------------
def default_approver() -> str:
    try:
        n = subprocess.run(["git", "config", "user.name"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        n = ""
    return n or os.environ.get("USERNAME") or os.environ.get("USER") or "<name>"


def ask(prompt: str, default: str) -> str:
    print(prompt, end="", flush=True)
    try:
        v = input().strip()
    except EOFError:
        v = ""
    return v or default


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--defaults", action="store_true", help="take every recommendation without asking (lab / POC)")
    ap.add_argument("--answers", type=Path, help="JSON {question-prefix: answer} prepared in advance")
    ap.add_argument("--approver", help="name written as Approver (else asked)")
    a = ap.parse_args()
    mod = Path(win_path(str(a.module))).resolve()
    card = mod / "FLOW_CARD.md"
    if not card.is_file():
        print(f"no FLOW_CARD.md in {mod}")
        return 2
    text = card.read_text(encoding="utf-8")
    e = Evidence(mod)
    prepared = json.loads(a.answers.read_text(encoding="utf-8")) if a.answers else {}
    qs = OPEN.findall(text)
    if not qs:
        print("no open question left on the card")
    log, n_def, n_own, n_skip = [], 0, 0, 0
    for i, q in enumerate(qs, 1):
        kind, rec, ev = recommend(q, e)
        own = next((v for k, v in prepared.items() if q.startswith(k) or k in q), None)
        print(f"\nQ{i}/{len(qs)}: {q}\n   evidence: {ev}")
        if own is not None:
            ans = own
            print(f"   answer (from {a.answers.name}): {ans}")
        elif a.defaults:
            ans = f"{kind}: {rec}"
            print(f"   answer (recommended): {ans}")
        else:
            ans = ask(f"   Answer [{kind}: {rec}]: ", f"{kind}: {rec}")
        if ans.strip().lower() in ("s", "skip"):
            n_skip += 1
            log.append({"question": q, "answer": None, "recommended": f"{kind}: {rec}", "accepted_default": False, "evidence": ev})
            continue
        default = ans == f"{kind}: {rec}"
        n_def += default
        n_own += not default
        if not re.match(r"(?i)(answered|accepted)\b", ans):
            ans = "answered: " + ans
        line = f"- [x] {q} -- {ans} [evidence: {ev}]"
        text = text.replace(f"- [ ] {q}", line, 1)
        log.append({"question": q, "answer": ans, "recommended": f"{kind}: {rec}", "accepted_default": default, "evidence": ev})
    left = len(OPEN.findall(text))
    approved = left == 0
    approver = ""
    if approved:
        approver = a.approver or (default_approver() if a.defaults else ask(f"\nApprover [{default_approver()}]: ", default_approver()))
        today = dt.date.today().isoformat()
        text = re.sub(r"^Status:.*$", "Status: approved", text, count=1, flags=re.M)
        text = re.sub(r"^Approver:.*$", f"Approver: {approver}", text, count=1, flags=re.M)
        text = re.sub(r"^Date:.*$", f"Date: {today}", text, count=1, flags=re.M)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    (mod / f"FLOW_CARD.md.bak-{stamp}").write_text(card.read_text(encoding="utf-8"), encoding="utf-8")
    card.write_text(text, encoding="utf-8")
    trail = jload(mod / "CARD_ANSWERS.json").get("runs") or []
    trail.append({"when": stamp, "approver": approver or None, "approved": approved, "answers": log})
    (mod / "CARD_ANSWERS.json").write_text(json.dumps({"runs": trail}, indent=2), encoding="utf-8")
    print(f"\n{len(qs)} question(s): {n_def} recommended answer(s) accepted, {n_own} own answer(s), {n_skip} skipped; "
          f"approved: {'yes (' + approver + ')' if approved else 'no, ' + str(left) + ' still open'}")
    print("next: bash $KIT/pi/vdi_session.sh review '" + e.project + "'   (refreezes the card: gate K1)" if approved
          else "rerun card_answers.py for the skipped questions")
    return 0 if approved else 3


if __name__ == "__main__":
    sys.exit(main())
