#!/usr/bin/env python3
"""Standalone local run for a flat delivery project: RUN_LOCAL.md + run-local.sh written next to the route, so a
reviewer runs the flows with Java 21, Maven 3.9 and an Artemis only (no kit). Called by assemble_flat.py.

    run_local_doc.py <flat project folder>          (re)write the two files from src/env/local.properties"""
from __future__ import annotations

import json
import re
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "broker"))
try:
    from plan_queues import plan                      # noqa: E402
    from e2e_check import fill_for_selector           # noqa: E402
except ImportError:                                   # kit without broker/: no queue section
    plan = fill_for_selector = None


def local_props(project: Path) -> dict:
    out = {}
    f = project / "src/env/local.properties"
    for ln in f.read_text(encoding="utf-8").splitlines() if f.is_file() else []:
        if ln.strip() and not ln.lstrip().startswith(("#", "!")) and "=" in ln:
            k, v = ln.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def flows(props: dict) -> dict:
    """proxy -> (input address, selector, selector defaults)."""
    out = {}
    for k, v in props.items():
        if not k.endswith(".flow.input"):
            continue
        x = k[: -len(".flow.input")]
        m = re.search(r"destination=(?:queue|topic):([^?&\s]+)", v) or re.search(r"amqp:(?:queue|topic):([^?&\s]+)", v)
        addr = m.group(1).split("::")[0] if m else ""
        sel = props.get(f"{x}.flow.input.selector", "")
        out[x] = (addr, sel, fill_for_selector(sel, {}) if fill_for_selector and sel else {})
    return out


def script(project: Path, props: dict, fl: dict) -> str:
    q = shlex.quote
    creates = []
    for o in plan(dict(props)) if plan else []:
        if o["routing"] == "multicast":
            c = ["queue", "create", "--name", o["name"], "--address", o["address"], "--multicast", "--durable",
                 "--preserve-on-no-consumers", "--auto-create-address", "--silent"] + (["--filter", o["filter"]] if o["filter"] else [])
        elif o["routing"] == "anycast":
            c = ["queue", "create", "--name", o["name"], "--address", o["address"], "--anycast", "--durable", "--auto-create-address", "--silent"]
        else:
            c = ["address", "create", "--name", o["address"], "--multicast"]
        creates.append("    art " + " ".join(q(x) for x in c) + " || true")
    dlines = [f"-D{k}={v}" for k, v in props.items() if not k.endswith(".selector")]
    sends = "\n".join(f"    {q(x)}) dest={q('topic://' + a)}; defaults={q(json.dumps(d))};;" for x, (a, s, d) in fl.items())
    stats = " ".join(q(o["name"]) for o in (plan(dict(props)) if plan else []) if o["routing"] != "address")
    return f"""#!/usr/bin/env bash
# Local run of every flow of {project.name} against a local Artemis, without the migration kit.
# Needs: Java 21, Maven 3.9 with access to the Maven repository (MVN_ARGS="-s <settings.xml>" if needed),
#        an unzipped and running Artemis (ARTEMIS_HOME), and python for "send". See RUN_LOCAL.md.
#   bash run-local.sh queues                          create the subscription(s) (OSB selector as filter) and the queues
#   bash run-local.sh run                             start the route(s); Ctrl+C stops them
#   bash run-local.sh send <proxy> <case folder>      send one test case (input.payload + headers.json)
#   bash run-local.sh stat                            message counts of the queues of this project
set -u
cd "$(dirname "$0")"
: "${{ARTEMIS_HOME:?export ARTEMIS_HOME=<unzipped apache-artemis folder>}}"
: "${{BROKER_PASSWORD:?export BROKER_PASSWORD=<broker password>}}"
export BROKER_USER="${{BROKER_USER:-artemis}}" BROKER_URL="${{BROKER_URL:-amqp://localhost:5672}}"
CORE_URL="${{ARTEMIS_URL:-tcp://localhost:61616}}"
wp() {{ if command -v cygpath > /dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }}
art() {{ "${{JAVA_HOME:+$JAVA_HOME/bin/}}java" -cp "$(wp "$ARTEMIS_HOME/lib/artemis-boot.jar")" -Dartemis.home="$(wp "$ARTEMIS_HOME")" \\
  org.apache.activemq.artemis.boot.Artemis "$@" --user "$BROKER_USER" --password "$BROKER_PASSWORD" --url "$CORE_URL"; }}
case "${{1:-}}" in
  queues)
{chr(10).join(creates) or "    echo 'no broker objects found in src/env/local.properties'"}
    ;;
  run)
    export KAMELET_LOCATION="file:$(wp "$(cd ../Common-setup && pwd)")"
    exec mvn -B ${{MVN_ARGS:-}} -Prun-local compile exec:java \\
{chr(10).join("      " + q(d) + " " + chr(92) for d in dlines)}
      ;;
  send)
    x=${{2:?proxy}}; c=${{3:?case folder with input.payload and headers.json}}
    case "$x" in
{sends}
    *) echo "unknown proxy $x"; exit 2;;
    esac
    PY=$(command -v python3 || command -v python)
    props=$("$PY" -c "import json,sys; d=json.loads(sys.argv[1]); h=json.load(open(sys.argv[2], encoding='utf-8')); d.update(h); print(json.dumps([{{'type':'string','key':k,'value':str(v)}} for k,v in d.items()]))" "$defaults" "$c/headers.json")
    art producer --protocol AMQP --destination "$dest" --message-count 1 --message "$(cat "$c/input.payload")" --properties "$props" 2>&1 | grep -E "Produced|rror|xception" | head -3
    ;;
  stat)
    art queue stat --maxRows 500 --maxColumnSize -1 2>&1 | grep -E "^\\|NAME|{'|'.join(re.escape(n) for n in stats.split()) or 'NONE'}" | sed 's/^/  /'
    ;;
  *) sed -n '2,9p' "$0";;
esac
"""


def doc(project: Path, props: dict, fl: dict) -> str:
    lines = [f"# Run {project.name} locally", "",
             "This folder runs on its own: Java 21, Maven 3.9 (with access to the Maven repository), and a local Apache "
             "Artemis (2.4x). Everything below is in Git Bash (Windows) or any bash shell, in this folder.", "",
             "## 1 Mock tests, no broker", "", "```", "mvn test", "```", "",
             "Every test case under `src/test/resources/<proxy>/parity` is sent through the route with the endpoints replaced "
             "by mocks; the result says which queue each case reached, compared with what OSB did.", "",
             "## 2 Against a local Artemis", "", "```",
             "export ARTEMIS_HOME=<unzipped apache-artemis folder> BROKER_PASSWORD=<broker password>   # BROKER_USER defaults to artemis",
             "bash run-local.sh queues      # once: subscription(s) with the OSB selector as filter, output and error queues",
             "bash run-local.sh run         # start the routes, wait for 'Apache Camel ... started' (Ctrl+C stops)", "```", "",
             "In a second window (same exports):", "", "```"]
    for x in fl:
        lines.append(f"bash run-local.sh send {x} src/test/resources/{x}/parity/<flow>/<scenario>/<case>")
    lines += ["bash run-local.sh stat        # MESSAGES ADDED per queue", "```", "",
              "The route connects with `BROKER_URL` (default `amqp://localhost:5672`, the AMQP acceptor of a default Artemis "
              "instance; use `amqp://localhost:61616` if only that port is open). Queue names for the local run come from "
              "`src/env/local.properties` (the JNDI names of `application.properties` without the `jndi.` prefix).", "",
              "## Flows and their subscription", "", "| Proxy | Topic address | Selector | Added when a case lacks the property |",
              "|---|---|---|---|"]
    for x, (a, s, d) in fl.items():
        lines.append(f"| {x} | {a} | `{s or '-'}` | {', '.join(f'{k}={v}' for k, v in d.items()) or '-'} |")
    lines += ["", "OSB does not log every property the selector checks (for example eventType). `send` therefore starts from "
              "one allowed value per property and lets the case's own headers.json override it; a case whose properties the "
              "selector excludes is dropped by the broker, exactly as OSB's subscription would drop it.", ""]
    return "\n".join(lines)


def write(project: Path) -> None:
    props = local_props(project)
    fl = flows(props)
    (project / "run-local.sh").write_text(script(project, props, fl), encoding="utf-8", newline="\n")
    (project / "RUN_LOCAL.md").write_text(doc(project, props, fl), encoding="utf-8", newline="\n")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        write(Path(p))
