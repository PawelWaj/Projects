#!/usr/bin/env python3
"""Check the generated camel-k/integration.yaml of a work module before it is handed over for Argo CD.

    check_manifest.py modules/<project>/<proxy> [--json]

1. every document has apiVersion, kind and metadata.name (and, when PyYAML is installed, the file parses as YAML);
2. the ConfigMap sources are exactly the module's route YAML and Java files, and the config ConfigMap is exactly the
   Camel K variant of application.properties (camelk_manifests.camelk_properties): nothing edited by hand;
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


def configmap_data(doc: str) -> dict[str, str]:
    """data entries of a ConfigMap as camelk_manifests.block writes them (literal block or JSON-quoted string)."""
    lines = doc.split("\n")
    try:
        start = lines.index("data:") + 1
    except ValueError:
        return {}
    out, i = {}, start
    while i < len(lines):
        ln = lines[i]
        m = re.match(r"^  ([^ ][^:]*): (\|)?(.*)$", ln)
        if not m:
            i += 1
            continue
        key, lit, rest = m.group(1), m.group(2), m.group(3)
        if not lit:
            out[key] = json.loads(rest)
            i += 1
            continue
        body, i = [], i + 1
        while i < len(lines) and (lines[i].startswith("    ") or lines[i] == ""):
            body.append(lines[i][4:])
            i += 1
        while body and body[-1] == "":
            body.pop()
        out[key] = "\n".join(body) + "\n"
    return out


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
    ds = docs(text)
    bad = [i for i, d in enumerate(ds, 1) if not (head(d, "apiVersion") and head(d, "kind") and meta_name(d))]
    parsed = "not checked (no PyYAML)"
    try:
        import yaml  # type: ignore
        list(yaml.safe_load_all(text))
        parsed = "parses"
    except ImportError:
        pass
    except Exception as e:  # noqa: BLE001
        bad.append(f"YAML: {type(e).__name__}")
    kinds = [head(d, "kind") for d in ds]
    step("structure", not bad, f"{len(ds)} documents ({', '.join(kinds)}), YAML {parsed}" + (f"; broken: {bad}" if bad else ""))

    main = mod / "src/main"
    want = {p.name: p.read_text(encoding="utf-8") for p in sorted((main / "resources/routes").glob("*.yaml"))}
    want.update({p.name: p.read_text(encoding="utf-8") for p in sorted((main / "java").rglob("*.java"))})
    props = (main / "resources/application.properties").read_text(encoding="utf-8")
    cms = {meta_name(d): configmap_data(d) for d in ds if head(d, "kind") == "ConfigMap"}
    src = next((v for k, v in cms.items() if k.endswith("-sources")), {})
    cfg = next((v for k, v in cms.items() if k.endswith("-config")), {})
    diff = sorted({k for k in want if src.get(k) != want[k]} | {k for k in src if k not in want})
    if cfg.get("application.properties") != cm.camelk_properties(props):
        diff.append("application.properties")
    step("sources", not diff, f"{len(src)} source(s) + properties identical to the module" if not diff else f"differ: {diff}")

    refs = sorted(set(re.findall(r"secret:([\w.-]+)/([\w.-]+)", text)))
    deploy = (out / "DEPLOY.md").read_text(encoding="utf-8") if (out / "DEPLOY.md").is_file() else ""
    missing = [f"{s}/{k}" for s, k in refs if s not in deploy or k not in deploy]
    step("secrets-documented", not missing, f"{len(refs)} secret reference(s), all in DEPLOY.md" if not missing else f"not in DEPLOY.md: {missing}")

    names = secret_names(mod, text)
    literal = sorted(n for n in names if re.search(rf'"{n}=(?!secret:)', text))
    env_file = os.environ.get("CAMELK_ENV_FILE", "")
    leaked = []
    if env_file and Path(env_file).is_file():
        vals = cm.read_env_file(env_file)
        leaked = sorted(k for k in names if vals.get(k) and len(vals[k]) >= 4 and vals[k] in text)
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
