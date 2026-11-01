#!/usr/bin/env python3
"""Check the generated camel-k/ Kustomize folder of a work module before it is handed over for Argo CD.

    check_manifest.py modules/<project>/<proxy> [--json]

1. integration.yaml is ONE Integration resource with no code in it (no ConfigMap, no inline source content), and
   kustomization.yaml generates <name>-sources from every file in sources/ and <name>-config from config/; every file
   it names exists; kustomizeconfig.yaml maps the Integration contentRef (YAML parsed when PyYAML is installed);
2. sources/ holds exactly the module's route YAML and Java files, byte for byte, and config/application.properties
   is exactly the Camel K variant (camelk_manifests.camelk_properties): nothing edited by hand;
3. every `secret:<name>/<key>` reference is named in DEPLOY.md;
4. no credential is written as a value: env names that look secret (PASSWORD, TOKEN, API_KEY ...) or are listed in
   CAMELK_SECRET_KEYS appear only as secret: references, and no value of such a key from CAMELK_ENV_FILE is in the file;
5. camel-k/CHECK.json: ready, or only per-environment values open ("ready for Dev once values are set").
Prints names and counts only. Exit 0 = PASS (also "ready once values are set"), 1 = FAIL.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import camelk_manifests as cm  # noqa: E402


def docs(text: str) -> list[str]:
    return [d for d in re.split(r"^---\s*$", text, flags=re.M) if d.strip()]


def head(doc: str, key: str) -> str:
    m = re.search(rf"^{key}:\s*(\S+)", doc, re.M)
    return m.group(1) if m else ""


def meta_name(doc: str) -> str:
    m = re.search(r"^metadata:\s*\n(?:\s+.*\n)*?\s+name:\s*(\S+)", doc, re.M)
    return m.group(1) if m else ""


def listed(kust: str, cm_name: str) -> list[str]:
    """files of one configMapGenerator entry in kustomization.yaml as camelk_manifests.kustomization writes it."""
    m = re.search(rf"^  - name: {re.escape(cm_name)}\n    files:\n((?:      - .+\n)+)", kust, re.M)
    return re.findall(r"^      - (.+)$", m.group(1), re.M) if m else []


def secret_names(mod: Path, text: str) -> set[str]:
    refs = cm.env_refs([text])
    return {n for n in refs if cm.SECRETISH.search(n)} | cm.extra_secret_keys()


def check(mod: Path) -> dict:
    out = mod / "camel-k"
    f = out / "integration.yaml"
    res = {"module": str(mod), "steps": [], "ok": False, "ready": False, "open": []}

    def step(name: str, ok: bool, detail: str):
        res["steps"].append({"check": name, "ok": ok, "detail": detail})

    if not f.is_file():
        step("file", False, "no camel-k/integration.yaml (camelk_manifests.py)")
        return res
    text = f.read_text(encoding="utf-8")
    kf = out / "kustomization.yaml"
    kust = kf.read_text(encoding="utf-8") if kf.is_file() else ""
    ds = docs(text)
    kinds = [head(d, "kind") for d in ds]
    name = meta_name(ds[0]) if ds else ""
    bad = []
    if kinds != ["Integration"]:
        bad.append(f"integration.yaml must hold only the Integration, has: {kinds}")
    if re.search(r"^\s+content:\s", text, re.M) or "kind: ConfigMap" in text:
        bad.append("code inside integration.yaml (inline content or a ConfigMap)")
    if not kust:
        bad.append("no kustomization.yaml")
    else:
        for need in ("kind: Kustomization", "  - integration.yaml", "  - kustomizeconfig.yaml", f"  - name: {name}-sources",
                     f"  - name: {name}-config"):
            if need not in kust:
                bad.append(f"kustomization.yaml lacks '{need.strip()}'")
        gone = [g for g in re.findall(r"^      - (.+)$", kust, re.M) if not (out / g).is_file()]
        gone += [r for r in re.findall(r"^  - (kamelets/.+)$", kust, re.M) if not (out / r).is_file()]
        if gone:
            bad.append(f"files named in kustomization.yaml missing: {gone}")
    kc = out / "kustomizeconfig.yaml"
    if not kc.is_file() or "path: spec/sources/contentRef" not in kc.read_text(encoding="utf-8"):
        bad.append("kustomizeconfig.yaml missing or without the Integration contentRef mapping")
    parsed = "not checked (no PyYAML)"
    try:
        import yaml  # type: ignore
        for t in (text, kust):
            list(yaml.safe_load_all(t))
        parsed = "parses"
    except ImportError:
        pass
    except Exception as e:  # noqa: BLE001
        bad.append(f"YAML: {type(e).__name__}")
    step("structure", not bad, f"Integration {name} without code + kustomization.yaml, YAML {parsed}" + (f"; broken: {bad}" if bad else ""))

    main = mod / "src/main"
    want = {p.name: p.read_bytes() for p in sorted((main / "resources/routes").glob("*.yaml"))}
    want.update({p.name: p.read_bytes() for p in sorted((main / "java").rglob("*.java"))})
    have = {p.name: p.read_bytes() for p in sorted((out / "sources").glob("*")) if p.is_file()}
    norm = lambda b: b.replace(b"\r\n", b"\n")   # noqa: E731  (a Windows checkout may differ in line ends only)
    diff = sorted({k for k in want if norm(have.get(k, b"")) != norm(want[k])} | {k for k in have if k not in want})
    unlisted = sorted(k for k in have if f"sources/{k}" not in listed(kust, f"{name}-sources"))
    props = (main / "resources/application.properties").read_text(encoding="utf-8")
    cfg = out / "config/application.properties"
    if not cfg.is_file() or cfg.read_text(encoding="utf-8") != cm.camelk_properties(props):
        diff.append("application.properties")
    step("sources", not diff and not unlisted,
         f"{len(have)} source file(s) + properties identical to the module, all in {name}-sources" if not (diff or unlisted)
         else f"differ: {diff}" + (f"; not in the generator: {unlisted}" if unlisted else ""))

    refs = sorted(set(re.findall(r"secret:([\w.-]+)/([\w.-]+)", text)))
    deploy = (out / "DEPLOY.md").read_text(encoding="utf-8") if (out / "DEPLOY.md").is_file() else ""
    missing = [f"{s}/{k}" for s, k in refs if s not in deploy or k not in deploy]
    step("secrets-documented", not missing, f"{len(refs)} secret reference(s), all in DEPLOY.md" if not missing else f"not in DEPLOY.md: {missing}")

    code = "\n".join(q.read_text(encoding="utf-8", errors="replace") for d in ("sources", "config") for q in sorted((out / d).glob("*")) if q.is_file())
    names = secret_names(mod, code + "\n" + text)
    literal = sorted(n for n in names if re.search(rf'"{n}=(?!secret:)', text))
    env_file = os.environ.get("CAMELK_ENV_FILE", "")
    leaked = []
    if env_file and Path(env_file).is_file():
        vals = cm.read_env_file(env_file)
        every = "\n".join(q.read_text(encoding="utf-8", errors="replace") for q in sorted(out.rglob("*")) if q.is_file())
        leaked = sorted(k for k in names if vals.get(k) and len(vals[k]) >= 4 and vals[k] in every)
    step("no-credentials", not literal and not leaked,
         f"{len(names)} credential name(s), all as secret: references" if not (literal or leaked)
         else f"written as values: {literal + leaked}")

    chk = json.loads((out / "CHECK.json").read_text(encoding="utf-8")) if (out / "CHECK.json").is_file() else {}
    res["open"] = chk.get("open") or []
    per_env = all("no value (--env-file" in o or "CAMELK_BROKER_URL" in o for o in res["open"])
    res["ready"] = bool(chk.get("ready"))
    step("ready", res["ready"] or per_env,
         "ready: true" if res["ready"] else ("ready for Dev once values are set: " + ", ".join(o.split(":")[0] for o in res["open"]) if per_env
                                             else f"open: {res['open']}"))
    res["ok"] = all(s["ok"] for s in res["steps"])
    return res


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    r = check(a.module.resolve())
    if a.json:
        print(json.dumps(r, indent=1))
    else:
        for s in r["steps"]:
            print(f"{'ok  ' if s['ok'] else 'FAIL'} {s['check']}: {s['detail']}")
        print("manifest:", "PASS" if r["ok"] else "FAIL")
    return 0 if r["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
