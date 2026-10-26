#!/usr/bin/env python3
"""Camel K deployment of ONE migrated flow: a single integration.yaml you apply to the Dev namespace. Stdlib only.

    camelk_manifests.py <delivery>/<app>/<project>         scripts path (called by assemble_jbang.py)
    camelk_manifests.py modules/<project>/<proxy>           skills path (a Maven module, called by run_camelk.sh)
        [--namespace NS] [--domain D] [--broker-url URL] [--env-file FILE]

Writes <folder>/camel-k/:
  integration.yaml    every resource the flow needs, in apply order, as one multi-document file:
                      Kamelets (scripts path; shared, re-applying is harmless), ConfigMap <name>-sources (route + Java),
                      <name>-config (application.properties), <name>-transformations (OSB .xqy/.xsd), the Integration
  DEPLOY.md           the Secret commands (credentials are never in a file), apply, check, remove
  CHECK.json          ready (true/false) + what is still open (CHANGE-ME values), for the run summary
Values that differ per environment come from the command line or the environment, never from the repository:
  --broker-url / CAMELK_BROKER_URL   broker of the namespace (scripts path: core protocol tcp://host:61616, the kamelets
                                     use the Artemis core client; skills path: amqp://host:5672 or failover:(...))
  --env-file / CAMELK_ENV_FILE       KEY=VALUE lines for the {{env:X}} values of the route (hosts, ids), kept on the machine
  CAMELK_SECRET_KEYS='A,B'           env names that go into the Secret too (names with PASSWORD/TOKEN/API_KEY/... always do)
  Names that look like credentials (PASSWORD, SECRET, TOKEN, KEY, USER) are read from Secret <name>-env instead
  (environment trait NAME=secret:<name>-env/NAME, Camel K 2.3+); DEPLOY.md prints the command that creates it.
Namespace and domain label: --namespace / --domain, else CAMELK_NAMESPACE / CAMELK_DOMAIN, else none / the folder.
DEV_VALUES=later: files for review before the Dev values exist. Missing values stay CHANGE-ME and are listed as open,
CHECK.json says ready false + for_review true; a value typed as CHANGE-ME or <...> always counts as open."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ARTEMIS_CLIENT = "mvn:org.apache.activemq:artemis-jakarta-client:2.44.0"   # same as the kamelets
SAXON = "mvn:net.sf.saxon:Saxon-HE:12.9"                                    # //DEPS of OsbXQuery.java
FILES_DIR = "/etc/camel/resources/osb"                                      # osb.files.dir inside the pod
CM_LIMIT = 1_000_000                                                        # ConfigMap data limit is 1 MiB
SECRET_KEYS = ("username", "password")
CHANGE = "CHANGE-ME"
SECRETISH = re.compile(r"(?i)(PASSWORD|PASSWD|PWD|SECRET|TOKEN|API_?KEY|_KEY$|_USER$|USERNAME|CREDENTIAL)")
POM_SKIP = {"camel-bom", "camel-main", "camel-mock", "camel-test-main-junit5", "camel-test-junit5", "camel-log"}
POM_MAP = {"camel-platform-http-main": "camel:platform-http"}


def yaml_str(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def block(key: str, text: str, ind: int) -> list:
    """A ConfigMap data entry. Literal block when it round-trips exactly, else a JSON-quoted string (YAML-valid)."""
    pad = " " * ind
    first = text.split("\n", 1)[0]
    literal_ok = (text.endswith("\n") and not text.endswith("\n\n") and "\r" not in text and text.strip()
                  and not first[:1].isspace() and all(not l or not l[-1].isspace() for l in text.split("\n")))
    if not literal_ok:
        return [f"{pad}{key}: {yaml_str(text)}"]
    return [f"{pad}{key}: |"] + [f"{pad}  {l}" if l else "" for l in text[:-1].split("\n")]


def configmap(name: str, files: dict, labels: dict, ns: str) -> list:
    L = ["apiVersion: v1", "kind: ConfigMap", "metadata:", f"  name: {name}"] + ([f"  namespace: {ns}"] if ns else [])
    L += ["  labels:"] + [f"    {k}: {v}" for k, v in labels.items()] + ["data:"]
    for k, text in files.items():
        L += block(k, text, 2)
    return L


def camelk_properties(text: str) -> str:
    """application.properties for the pod: broker user/password lines removed (they come from the Secret), and the
    classpath route pattern of the Maven module (Camel K loads the sources itself)."""
    keep = [l for l in text.splitlines() if not re.match(rf"camel\.kamelet\.[\w-]+\.({'|'.join(SECRET_KEYS)})=", l)
            and not l.startswith("camel.main.routes-include-pattern=")]
    return "\n".join(keep) + "\n"


def read_env_file(path: str) -> dict:
    if not path:
        return {}
    out = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip().removeprefix("export ").strip()] = v.strip().strip('"')
    return out


def for_review(open_: list) -> bool:
    """DEV_VALUES=later and only missing values open (no structural problem): the files can go to review."""
    return os.environ.get("DEV_VALUES", "") == "later" and all(": no value" in o for o in open_)


def env_refs(texts) -> list:
    names = []
    for t in texts:
        names += re.findall(r"env[:.]([A-Z][A-Z0-9_]*)", t)
    return list(dict.fromkeys(n for n in names if n != "OSB_FILES_DIR"))


def extra_secret_keys() -> set:
    """CAMELK_SECRET_KEYS='A,B': further env names that go into the Secret although their name does not look secret
    (e.g. client ids a DVM holds next to the API key). Their values never appear in integration.yaml or Git."""
    return {k for k in re.split(r"[\s,]+", os.environ.get("CAMELK_SECRET_KEYS", "")) if k}


def env_vars(name: str, refs: list, values: dict, broker_url: str) -> tuple:
    """environment trait vars, the Secret keys to create, and the open points (values still CHANGE-ME)."""
    vars_, secret, open_ = [], [], []
    for n in refs:
        if n == "BROKER_URL":
            v = broker_url or values.get(n, "")
        elif SECRETISH.search(n) or n in extra_secret_keys():
            secret.append(n)
            vars_.append(f"{n}=secret:{name}-env/{n}")
            continue
        else:
            v = values.get(n, "")
        if not v or v == CHANGE or re.fullmatch(r"<[^>]*>", v):
            v = ""
            open_.append(f"{n}: no value (--env-file / CAMELK_ENV_FILE{', --broker-url / CAMELK_BROKER_URL' if n == 'BROKER_URL' else ''})")
        vars_.append(f"{n}={v or CHANGE}")
    return vars_, secret, open_


def integration(name: str, labels: dict, ns: str, sources: dict, deps: list, configs: list, resources: list,
                env: list, kamelets: list, http: bool, origin: str) -> list:
    I = [f"# {name}: Camel K Integration generated from {origin} (camelk_manifests.py, do not edit by hand).",
         "apiVersion: camel.apache.org/v1", "kind: Integration", "metadata:", f"  name: {name}"]
    I += [f"  namespace: {ns}"] if ns else []
    I += ["  labels:"] + [f"    {k}: {v}" for k, v in labels.items()]
    I += ["spec:", "  profile: OpenShift", "  sources:"]
    for s in sources:
        I += [f"    - name: {s}", f"      language: {'java' if s.endswith('.java') else 'yaml'}",
              f"      contentRef: {name}-sources", f"      contentKey: {s}"]
    I += ["  dependencies:"] + [f"    - {d}" for d in deps]
    I += ["  traits:", "    mount:", "      configs:"] + [f'        - "{c}"' for c in configs]
    if resources:
        I += ["      resources:"] + [f'        - "{r}"' for r in resources]
    I += ["    environment:", "      vars:"] + [f'        - "{v}"' for v in env]
    I += ["    camel:", "      enabled: true"]
    if kamelets:
        I += ["    kamelets:", "      enabled: true", f'      list: "{",".join(kamelets)}"']
    I += ["    container:", "      imagePullPolicy: Always"]
    I += ["    service:", "      enabled: true", "      type: ClusterIP"] if http else ["    service:", "      enabled: false"]
    I += ["    jvm:", "      enabled: true"]
    return I


def deploy_md(name: str, ns: str, secret_env: list, broker_secret: list, open_: list, http: bool, kind: str) -> list:
    nsf = f" -n {ns}" if ns else " -n <namespace>"
    D = [f"# {name} on Camel K ({kind})", "", "Generated with the route; regenerate, never edit. Everything except credentials is in",
         "`integration.yaml`. Run from this folder, logged in with `oc login` to the Dev cluster.", ""]
    n = 1
    if broker_secret:
        D += [f"{n}. Broker credentials (once per namespace and flow). Write `broker.properties` on your machine, create the",
              "   Secret, delete the file:", "   ```"] + [f"   {k}=<{k.rsplit('.', 1)[-1]}>" for k in broker_secret]
        D += [f"   oc create secret generic {name}-broker{nsf} --from-file=broker.properties", "   rm broker.properties", "   ```"]
        n += 1
    if secret_env:
        D += [f"{n}. Credentials the route reads from the environment (Secret {name}-env):", "   ```",
              f"   oc create secret generic {name}-env{nsf} " + " ".join(f"--from-literal={k}=<{k.lower()}>" for k in secret_env),
              "   ```", "   Type the values in the window; do not keep them in a script or the shell history file.", ""]
        n += 1
    D += [f"{n}. Check, apply, watch:", "   ```", f"   oc apply{nsf} --dry-run=server -f integration.yaml",
          f"   oc apply{nsf} -f integration.yaml", f"   oc get integration {name}{nsf} -w        # phase Running",
          f"   oc logs{nsf} -l camel.apache.org/integration={name} --tail=50", "   ```"]
    if http:
        D += ["   The route answers HTTP on the Service `" + name + "` (port 80 -> 8080). Expose it only as the platform",
              "   decides (Route / Istio gateway); no Route is created here."]
    D += [f"{n + 1}. Remove: `oc delete{nsf} -f integration.yaml` (Secrets stay: delete them by name if needed).", "",
          "Camel version: the Camel K runtime of the cluster decides it; routes and tests are built for Camel 4.18, so use a",
          "Camel 4.18 runtime (Camel K 2.x with camel-k-runtime of that line)."]
    if open_ or not ns:
        D += ["", "## Open before applying (CHANGE-ME in integration.yaml)", ""] + [f"- {o}" for o in open_]
        D += [] if ns else ["- namespace: none in the file; the Argo CD Application destination sets it (or `-n <namespace>`)"]
        D += ["", "Regenerate with the values on the migration machine (dev.env, CAMELK_NAMESPACE) or fill the CHANGE-ME",
              "lines in the GitOps repository; credentials only through the Secret above."] if open_ else []
    return D


def write(out: Path, docs: list, D: list, check: dict) -> None:
    out.mkdir(exist_ok=True)
    (out / "integration.yaml").write_text("\n---\n".join("\n".join(d) for d in docs) + "\n", encoding="utf-8", newline="\n")
    (out / "DEPLOY.md").write_text("\n".join(D) + "\n", encoding="utf-8", newline="\n")
    (out / "CHECK.json").write_text(json.dumps(check, indent=2) + "\n", encoding="utf-8")
    old = out / "configmaps.yaml"                       # earlier layout: ConfigMaps in their own file
    if old.is_file():
        old.unlink()


def settings(ns: str, domain: str, broker_url: str, env_file: str, default_domain: str) -> tuple:
    return (ns or os.environ.get("CAMELK_NAMESPACE", ""), domain or os.environ.get("CAMELK_DOMAIN", "") or default_domain,
            broker_url or os.environ.get("CAMELK_BROKER_URL", ""), read_env_file(env_file or os.environ.get("CAMELK_ENV_FILE", "")))


def manifests(pdir: Path, ns: str = "", domain: str = "", broker_url: str = "", env_file: str = "") -> dict:
    """Scripts path: a delivered project folder (route + Common-setup kamelets and Java helpers)."""
    route = next(iter(sorted(pdir.glob("*-route.yaml"))), None)
    if route is None:
        raise SystemExit(f"no *-route.yaml in {pdir}")
    name = re.sub(r"[^a-z0-9-]", "-", route.name[:-len("-route.yaml")].lower()).strip("-")
    common = pdir.parent / "Common-setup"
    ns, domain, broker_url, values = settings(ns, domain, broker_url, env_file, pdir.parent.name)
    labels = {"app": name, "domain": domain, "flow": name}
    kamelets = sorted(common.glob("*.kamelet.yaml"))
    props = camelk_properties((pdir / "application.properties").read_text(encoding="utf-8"))
    props += "# broker user and password: Secret <name>-broker, key broker.properties (camel.kamelet.<kamelet>.username / .password)\n"
    sources = {route.name: route.read_text(encoding="utf-8")}
    for j in ("OsbNxsd.java", "OsbXQuery.java"):
        sources[j] = (common / j).read_text(encoding="utf-8")
    trans = {f.name: f.read_text(encoding="utf-8") for f in sorted((pdir / "transformations").glob("*")) if f.is_file()}
    size = sum(len(t.encode()) for t in trans.values())
    open_ = [f"ConfigMap {name}-transformations holds {size} bytes, over the 1 MiB limit: split it"] if size > CM_LIMIT else []
    bad = [k for k in trans if not re.fullmatch(r"[-._a-zA-Z0-9]+", k)]
    if bad:
        open_.append(f"file names not valid as ConfigMap keys: {', '.join(bad)}")
    refs = ["BROKER_URL"] + [r for r in env_refs([*sources.values(), props]) if r not in ("BROKER_URL", "BROKER_USER", "BROKER_PASSWORD")]
    env, secret_env, more = env_vars(name, refs, values, broker_url)
    env = [f"OSB_FILES_DIR={FILES_DIR}"] + env
    kam = [k.name[:-len(".kamelet.yaml")] for k in kamelets]
    http = any("platform-http" in s for s in sources.values())
    docs = [k.read_text(encoding="utf-8").rstrip("\n").split("\n") for k in kamelets]
    docs += [configmap(f"{name}-sources", sources, labels, ns), configmap(f"{name}-config", {"application.properties": props}, labels, ns),
             configmap(f"{name}-transformations", trans, labels, ns)]
    deps = ["camel:yaml-dsl", "camel:kamelet", "camel:jms", "camel:direct", "camel:jackson", SAXON, ARTEMIS_CLIENT]
    docs.append(integration(name, labels, ns, sources, deps, [f"configmap:{name}-config", f"secret:{name}-broker"],
                            [f"configmap:{name}-transformations@{FILES_DIR}/transformations"], env, kam, http,
                            f"the OSB project {pdir.name}"))
    open_ += more
    check = {"integration": name, "path": "scripts", "ready": not open_, "open": open_,
             "secrets": [f"{name}-broker"] + ([f"{name}-env"] if secret_env else []), "sources": len(sources), "transformations": len(trans)}
    write(pdir / "camel-k", docs, deploy_md(name, ns, secret_env, [f"camel.kamelet.{k}.{s}" for k in kam for s in SECRET_KEYS],
                                            open_, http, "scripts path"), check)
    return check


def module_deps(mod: Path, used: str) -> list:
    """The Camel K dependency list of a Maven module: its camel-* artifacts as camel:<name> (test-only and runtime-
    provided ones skipped). Also what local_acceptance passes to `camel run --dep`, so both run the same classpath."""
    pom = (mod / "pom.xml").read_text(encoding="utf-8") if (mod / "pom.xml").is_file() else ""
    arts = list(dict.fromkeys(re.findall(r"<artifactId>(camel-[\w-]+)</artifactId>", pom)))
    deps = ["camel:yaml-dsl"] + [POM_MAP.get(a, "camel:" + a[len("camel-"):]) for a in arts if a not in POM_SKIP and a != "camel-yaml-dsl"]
    return [d for d in dict.fromkeys(deps) if d != "camel:amqp" or re.search(r"\bamqp:", used)]   # the scaffold pom always has it


def module_manifests(mod: Path, ns: str = "", domain: str = "", broker_url: str = "", env_file: str = "") -> dict:
    """Skills path: a Maven module written by the implementer (routes/*.camel.yaml + beans under src/main/java)."""
    main = mod / "src/main"
    routes = sorted((main / "resources/routes").glob("*.yaml"))
    if not routes:
        raise SystemExit(f"no route under {main}/resources/routes")
    meta = json.loads((mod / ".scaffold.json").read_text(encoding="utf-8")) if (mod / ".scaffold.json").is_file() else {}
    name = re.sub(r"[^a-z0-9-]+", "-", (meta.get("proxy") or mod.name).lower()).strip("-")[:63]
    ns, domain, broker_url, values = settings(ns, domain, broker_url, env_file, meta.get("project") or mod.parent.name)
    labels = {"app": name, "domain": domain, "flow": name}
    sources = {r.name: r.read_text(encoding="utf-8") for r in routes}
    java = sorted((main / "java").rglob("*.java"))
    clash = sorted({j.name for j in java if sum(1 for x in java if x.name == j.name) > 1})
    sources.update({j.name: j.read_text(encoding="utf-8") for j in java})
    props = camelk_properties((main / "resources/application.properties").read_text(encoding="utf-8"))
    deps = module_deps(mod, "\n".join([*sources.values(), props]))
    amqp = "camel:amqp" in deps
    env, secret_env, open_ = env_vars(name, env_refs([*sources.values(), props]), values, broker_url)
    if clash:
        open_.append(f"two Java files with the same name ({', '.join(clash)}): Camel K needs unique source names")
    http = any("platform-http" in s for s in [*sources.values(), props])
    docs = [configmap(f"{name}-sources", sources, labels, ns), configmap(f"{name}-config", {"application.properties": props}, labels, ns)]
    docs.append(integration(name, labels, ns, sources, deps, [f"configmap:{name}-config"], [], env, [], http,
                            f"the migrated module {meta.get('project', '')}/{meta.get('proxy', mod.name)}"))
    kind = "skills path, " + ("HTTP request/reply" if http else "AMQP" if amqp else "messaging")
    check = {"integration": name, "path": "skills", "ready": not open_, "for_review": for_review(open_), "open": open_,
             "secrets": [f"{name}-env"] if secret_env else [], "sources": len(sources), "dependencies": deps}
    write(mod / "camel-k", docs, deploy_md(name, ns, secret_env, [], open_, http, kind), check)
    return check


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", type=Path, help="delivered project folder, or a module with pom.xml")
    ap.add_argument("--namespace", default="")
    ap.add_argument("--domain", default="")
    ap.add_argument("--broker-url", default="")
    ap.add_argument("--env-file", default="")
    a = ap.parse_args()
    fn = module_manifests if (a.folder / "pom.xml").is_file() else manifests
    print(json.dumps(fn(a.folder, a.namespace, a.domain, a.broker_url, a.env_file)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
