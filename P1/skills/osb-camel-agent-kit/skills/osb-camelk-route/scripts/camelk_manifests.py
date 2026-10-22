#!/usr/bin/env python3
"""Camel K manifests of one delivered OSB project (called by assemble_jbang.py, or alone on a delivery). Stdlib only.

    camelk_manifests.py <delivery>/<app>/<project> [--namespace NS] [--domain D]

Writes <project>/camel-k/:
  integration.yaml    Integration <name>: the route + OsbNxsd.java + OsbXQuery.java from ConfigMap <name>-sources,
                      application.properties from ConfigMap <name>-config, the OSB .xqy/.xsd files mounted from
                      ConfigMap <name>-transformations, broker user/password from Secret <name>-broker (key broker.properties)
  configmaps.yaml     the three ConfigMaps, file contents copied exactly
  DEPLOY.md           apply order and the secret command
The two Artemis kamelets of ../Common-setup are Kamelet resources already: apply them once per namespace.
Namespace and domain label: --namespace / --domain, else CAMELK_NAMESPACE / CAMELK_DOMAIN, else none / the app folder."""
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
    """application.properties for the pod: broker user/password lines removed (they come from the Secret),
    so every property has exactly one source."""
    keep = [l for l in text.splitlines() if not re.match(rf"camel\.kamelet\.[\w-]+\.({'|'.join(SECRET_KEYS)})=", l)]
    return "\n".join(keep + ["# broker user and password: Secret <name>-broker, key broker.properties (camel.kamelet.<kamelet>.username / .password)"]) + "\n"


def manifests(pdir: Path, ns: str = "", domain: str = "") -> dict:
    route = next(iter(sorted(pdir.glob("*-route.yaml"))), None)
    if route is None:
        raise SystemExit(f"no *-route.yaml in {pdir}")
    name = re.sub(r"[^a-z0-9-]", "-", route.name[:-len("-route.yaml")].lower()).strip("-")
    common = pdir.parent / "Common-setup"
    ns = ns or os.environ.get("CAMELK_NAMESPACE", "")
    domain = domain or os.environ.get("CAMELK_DOMAIN", "") or pdir.parent.name
    labels = {"app": name, "domain": domain, "flow": name}
    kamelets = sorted(common.glob("*.kamelet.yaml"))
    props = (pdir / "application.properties").read_text(encoding="utf-8")
    sources = {route.name: route.read_text(encoding="utf-8")}
    for j in ("OsbNxsd.java", "OsbXQuery.java"):
        sources[j] = (common / j).read_text(encoding="utf-8")
    trans = {f.name: f.read_text(encoding="utf-8") for f in sorted((pdir / "transformations").glob("*")) if f.is_file()}
    notes = [f"ConfigMap {name}-transformations holds {sum(len(t.encode()) for t in trans.values())} bytes, over the 1 MiB limit: split it"
             ] if sum(len(t.encode()) for t in trans.values()) > CM_LIMIT else []
    bad = [k for k in trans if not re.fullmatch(r"[-._a-zA-Z0-9]+", k)]
    if bad:
        notes.append(f"file names not valid as ConfigMap keys: {', '.join(bad)}")

    I = ["apiVersion: camel.apache.org/v1", "kind: Integration", "metadata:", f"  name: {name}"]
    I += [f"  namespace: {ns}"] if ns else []
    I += ["  labels:"] + [f"    {k}: {v}" for k, v in labels.items()]
    I += ["spec:", "  profile: OpenShift", "  sources:"]
    for s in sources:
        I += [f"    - name: {s}", f"      language: {'java' if s.endswith('.java') else 'yaml'}",
              f"      contentRef: {name}-sources", f"      contentKey: {s}"]
    I += ["  dependencies:", "    - camel:yaml-dsl", "    - camel:kamelet", "    - camel:jms", "    - camel:direct",
          "    - camel:jackson", f"    - {SAXON}", f"    - {ARTEMIS_CLIENT}"]
    I += ["  traits:", "    mount:", "      configs:", f'        - "configmap:{name}-config"', f'        - "secret:{name}-broker"',
          "      resources:", f'        - "configmap:{name}-transformations@{FILES_DIR}/transformations"',
          "    environment:", "      vars:", f'        - "OSB_FILES_DIR={FILES_DIR}"', '        - "BROKER_URL=tcp://CHANGE-ME:61616"',
          "    camel:", "      enabled: true", "    kamelets:", "      enabled: true",
          f'      list: "{",".join(k.name[:-len(".kamelet.yaml")] for k in kamelets)}"',
          "    container:", "      imagePullPolicy: Always",
          "    service:", "      enabled: true", "      type: ClusterIP", "    jvm:", "      enabled: true"]
    I = [f"# {name}: Camel K Integration generated from the OSB project {pdir.name} (camelk_manifests.py, do not edit by hand).",
         "# Sources, properties and OSB files come from the ConfigMaps in configmaps.yaml; credentials from the Secret",
         f"# {name}-broker (see DEPLOY.md). BROKER_URL: replace CHANGE-ME with the Artemis service of the namespace."] + I

    C = configmap(f"{name}-sources", sources, labels, ns) + ["---"]
    C += configmap(f"{name}-config", {"application.properties": camelk_properties(props)}, labels, ns) + ["---"]
    C += configmap(f"{name}-transformations", trans, labels, ns)

    kam_names = [k.name[:-len(".kamelet.yaml")] for k in kamelets]
    nsf = f" -n {ns}" if ns else " -n <namespace>"
    D = [f"# {name} on Camel K", "", "Generated from the OSB project and the delivery; regenerated with the route. Apply in this order.", "",
         "1. The Artemis kamelets, once per namespace (shared by every project of the application):", "   ```"]
    D += [f"   oc apply{nsf} -f ../../Common-setup/{k.name}" for k in kamelets] + ["   ```",
          "2. The broker credentials as a Secret, never in a file of the repository. Write `broker.properties` on your",
          "   machine with these lines, create the Secret, delete the file:", "   ```"]
    D += [f"   camel.kamelet.{k}.{s}=<{s}>" for k in kam_names for s in SECRET_KEYS]
    D += ["   ```", "   ```", f"   oc create secret generic {name}-broker{nsf} --from-file=broker.properties", "   rm broker.properties"]
    D += ["   ```", "3. Sources, properties and OSB files, then the Integration (set BROKER_URL in integration.yaml first):", "   ```",
          f"   oc apply{nsf} -f configmaps.yaml", f"   oc apply{nsf} -f integration.yaml", f"   oc get integration {name}{nsf} -w", "   ```", "",
          f"The pod reads `application.properties` from ConfigMap `{name}-config` without the user/password lines, the",
          f"OSB .xqy/.xsd files under `{FILES_DIR}/transformations` (OSB_FILES_DIR), and the route from `{name}-sources`.",
          "The Camel version is the one of the Camel K runtime on the cluster; the routes and tests are built and run",
          "with Camel 4.18.4 (camel run / jbang tests), so the runtime should be a Camel 4.18 one."]
    if notes:
        D += ["", "## To check", ""] + [f"- {n}" for n in notes]
    out = pdir / "camel-k"
    out.mkdir(exist_ok=True)
    for f, L in (("integration.yaml", I), ("configmaps.yaml", C), ("DEPLOY.md", D)):
        (out / f).write_text("\n".join(L) + "\n", encoding="utf-8", newline="\n")
    return {"integration": name, "sources": len(sources), "transformations": len(trans), "notes": notes}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("project", type=Path)
    ap.add_argument("--namespace", default="")
    ap.add_argument("--domain", default="")
    a = ap.parse_args()
    print(json.dumps(manifests(a.project, a.namespace, a.domain)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
