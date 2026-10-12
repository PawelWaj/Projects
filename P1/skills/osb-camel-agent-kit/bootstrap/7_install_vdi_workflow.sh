#!/usr/bin/env bash
# Paste into the migration workspace root on the VDI and run: bash 7_install_vdi_workflow.sh
# VDI workflow: bin/start_flow.sh (one entry point per flow), preflight, replay-config generator, RUNBOOK.md.
set -euo pipefail
mkdir -p "$(dirname "bin/build_bootstrap.py")"
cat > 'bin/build_bootstrap.py' <<'KIT_EOF_BIN_BUILD_BOOTSTRAP_PY'
#!/usr/bin/env python3
"""Regenerate the paste-install scripts for a VDI without file transfer (one quoted heredoc per file, nothing is
expanded by the shell). Run from the repo root after any change:

    python3 vdi-osb-migration/bin/build_bootstrap.py

Writes skills/osb-camel-agent-kit/bootstrap/<n>_install_<part>.sh (1-7). Paste each script into the migration workspace root on the
VDI (`cat > 1_install_agents.sh`, paste, Ctrl-D, `bash 1_install_agents.sh`), in order. Each ends with
`installed: N files`; if that line is missing the paste was truncated. Layout after install (workspace root = KIT):
AGENTS.md, agents/, pi/, tools/, ci/, .pi/skills/<skill>/, .pi/prompts/osb-*.md, log-replay/ (osb-log-replay),
bin/ + RUNBOOK.md (this workflow). The same repo checked out with git needs none of this."""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
KIT = REPO / "skills" / "osb-camel-agent-kit"
REPLAY = REPO / "osb-log-replay"
VDI = REPO / "vdi-osb-migration"
OUT = KIT / "bootstrap"


def marker(dest: str) -> str:
    return "KIT_EOF_" + re.sub(r"[^A-Za-z0-9]", "_", dest).upper()


def files_under(root: pathlib.Path, patterns: list[str]) -> list[pathlib.Path]:
    out = []
    for pat in patterns:
        out += [p for p in sorted(root.glob(pat)) if p.is_file() and ".ruff_cache" not in p.parts and "__pycache__" not in p.parts]
    seen, uniq = set(), []
    for p in out:
        if p not in seen:
            seen.add(p)
            uniq.append(p)
    return uniq


def emit(name: str, what: str, items: list[tuple[pathlib.Path, str]], post: list[str], done: str) -> None:
    lines = ["#!/usr/bin/env bash", f"# Paste into the migration workspace root on the VDI and run: bash {name}", f"# {what}",
             "set -euo pipefail"]
    for src, dest in items:
        text = src.read_text(encoding="utf-8")
        if not text.endswith("\n"):
            text += "\n"
        m = marker(dest)
        if m in text:
            sys.exit(f"{src} contains its own end marker {m}")
        lines += [f'mkdir -p "$(dirname "{dest}")"', f"cat > '{dest}' <<'{m}'", text.rstrip("\n"), m]
    lines += post + [f'echo "installed: {len(items)} files ({done})"']
    script = "\n".join(lines) + "\n"
    (OUT / name).write_text(script, encoding="utf-8")
    print(f"{name}: {len(items)} files, {len(script.encode()) // 1024} KB")


def main() -> None:
    OUT.mkdir(exist_ok=True)
    rel = lambda root, p: p.relative_to(root).as_posix()  # noqa: E731
    # 1 agents: kit root files, role prompts, pi runner + prompts (also copied to .pi/prompts where pi reads them)
    agents = files_under(KIT, ["AGENTS.md", "README.md", "TESTING.md", "TRIAL_GUIDE.md", "TRIAL_RESULTS_TEMPLATE.csv",
                               "agents/*.md", "pi/*.sh", "pi/*.md", "pi/prompts/*.md"])
    items = [(p, rel(KIT, p)) for p in agents] + [(p, ".pi/prompts/" + p.name) for p in files_under(KIT, ["pi/prompts/*.md"])]
    emit("1_install_agents.sh", "Agent layer: AGENTS.md, role prompts, pi runner, /osb-* prompt templates (kit + .pi/prompts). Existing files are overwritten.",
         items, ["chmod +x pi/*.sh 2>/dev/null || true",
                 'echo "commands /osb-* installed in .pi/prompts: start pi in this folder and trust the project (or pi --approve)"'],
         "agent layer")
    # 2 gates
    gates = files_under(KIT, ["tools/*.sh", "tools/*.py", "tools/*.xml", "ci/*"])
    emit("2_install_gates.sh", "Gate tools: verify_flow.sh (G1-G8, G10), check_matrix, check_oracle, golden_runner, mutate_transforms, compare_shadow, pom plugins, Jenkins stages.",
         [(p, rel(KIT, p)) for p in gates], ["chmod +x tools/*.sh tools/*.py 2>/dev/null || true"], "gate tools")
    # 3 + 4 skill osb-to-camel (core, templates) -> .pi/skills
    sk = KIT / "skills" / "osb-to-camel"
    core = files_under(sk, ["SKILL.md", "scripts/*.py", "references/*"])
    tpl = files_under(sk, ["assets/templates/**/*"])
    emit("3_install_skill_osb_core.sh", "Skill osb-to-camel: SKILL.md, scripts, references under .pi/skills/.",
         [(p, ".pi/skills/osb-to-camel/" + rel(sk, p)) for p in core],
         ["chmod +x .pi/skills/osb-to-camel/scripts/*.py 2>/dev/null || true"], "skill osb-to-camel: SKILL.md, scripts, references")
    emit("4_install_skill_osb_templates.sh", "Skill osb-to-camel: assets/templates (Java, XQuery shim, mocks) under .pi/skills/.",
         [(p, ".pi/skills/osb-to-camel/" + rel(sk, p)) for p in tpl],
         ["chmod +x .pi/skills/osb-to-camel/assets/templates/mocks/*.sh 2>/dev/null || true"], "skill osb-to-camel: assets/templates")
    # 5 verification skill
    vk = KIT / "skills" / "camel-migration-verification"
    ver = files_under(vk, ["**/*"])
    emit("5_install_skill_verification.sh", "Skill camel-migration-verification under .pi/skills/.",
         [(p, ".pi/skills/camel-migration-verification/" + rel(vk, p)) for p in ver], [], "skill camel-migration-verification")
    # 6 log replay tools -> log-replay/
    lr = files_under(REPLAY, ["tools/*.py", "replay-config.json", "run_offline.sh", "templates/**/*", "mock/*", "mock/**/*",
                              "skill/**/*", "README.md", "docs/*.md"])
    emit("6_install_log_replay.sh", "osb-log-replay: Splunk logs -> masked test cases -> fixtures -> replay (log-replay/).",
         [(p, "log-replay/" + rel(REPLAY, p)) for p in lr], ["chmod +x log-replay/tools/*.py log-replay/*.sh log-replay/mock/*.sh 2>/dev/null || true"],
         "log replay tools")
    # 7 this workflow -> bin/ + RUNBOOK.md
    wf = files_under(VDI, ["bin/*", "RUNBOOK.md"])
    emit("7_install_vdi_workflow.sh", "VDI workflow: bin/start_flow.sh (one entry point per flow), preflight, replay-config generator, RUNBOOK.md.",
         [(p, rel(VDI, p)) for p in wf], ["chmod +x bin/*.sh bin/*.py 2>/dev/null || true",
                                          'echo "next: bash bin/preflight_vdi.sh, then read RUNBOOK.md"'], "VDI workflow")


if __name__ == "__main__":
    main()
KIT_EOF_BIN_BUILD_BOOTSTRAP_PY
mkdir -p "$(dirname "bin/preflight_vdi.sh")"
cat > 'bin/preflight_vdi.sh' <<'KIT_EOF_BIN_PREFLIGHT_VDI_SH'
#!/usr/bin/env bash
# Preflight for the VDI workflow: what is present, what is missing, and which gate each gap affects. Never fails hard;
# prints a table and a count. Run from the migration workspace root.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd); WS=$(pwd)
KIT=${KIT:-$([ -d "$REPO/skills/osb-camel-agent-kit" ] && echo "$REPO/skills/osb-camel-agent-kit" || echo "$WS")}
REPLAY=${REPLAY:-$([ -d "$REPO/osb-log-replay" ] && echo "$REPO/osb-log-replay" || echo "$WS/log-replay")}
fail=0
row() { printf '  %-6s %-28s %s\n' "$1" "$2" "$3"; [ "$1" = "FAIL" ] && fail=$((fail+1)); }
has() { command -v "$1" >/dev/null 2>&1; }

echo "VDI preflight ($WS)"
has python3 || has python || has py; [ $? -eq 0 ] && row OK python "$(command -v python3 || command -v python || command -v py)" || row FAIL python "phases 1-5 need Python 3"
if has java; then v=$(java -version 2>&1 | head -1); case "$v" in *\"21*|*\"2[2-9]*) row OK "java" "$v";; *) row FAIL "java" "$v (JDK 21 needed for the Camel 4 module)";; esac; else row FAIL java "not on PATH (G1-G5)"; fi
has mvn && row OK maven "$(mvn -v 2>/dev/null | head -1)" || row FAIL maven "not on PATH (G1-G5)"
if has docker && docker info >/dev/null 2>&1; then row OK containers docker; elif has podman && podman info >/dev/null 2>&1; then row OK containers podman; else row WARN containers "none reachable: G5 and L3 replay NOT_RUN (run them on Jenkins)"; fi
has pi && row OK pi "$(pi --version 2>/dev/null | head -1)" || row FAIL pi "agent not on PATH (phases 6-7)"
[ -n "${MASK_KEY:-}" ] && row OK MASK_KEY "set (${#MASK_KEY} chars)" || row WARN MASK_KEY "not set: needed when a Splunk CSV is processed"
[ -f "$KIT/pi/run_flow.sh" ] && row OK kit "$KIT" || row FAIL kit "run_flow.sh not found (KIT=$KIT)"
S=$([ -d "$KIT/skills/osb-to-camel" ] && echo "$KIT/skills/osb-to-camel" || echo "$KIT/.pi/skills/osb-to-camel")
[ -f "$S/SKILL.md" ] && row OK skill "$S" || row FAIL skill "osb-to-camel not installed"
[ -f "$REPLAY/tools/osb_log_traces.py" ] && row OK log-replay "$REPLAY" || row FAIL log-replay "tools missing (REPLAY=$REPLAY)"
[ -f "$KIT/tools/golden_runner.py" ] && row OK golden-runner "$KIT/tools/golden_runner.py" || row FAIL golden-runner "missing (G10)"
j=$(ls ~/.m2/repository/net/sf/saxon/Saxon-HE/*/Saxon-HE-*.jar 2>/dev/null | tail -1); [ -n "${SAXON_JAR:-}" ] && j=$SAXON_JAR
[ -n "$j" ] && row OK saxon "$j" || row WARN saxon "no Saxon-HE jar: mvn dependency:get -Dartifact=net.sf.saxon:Saxon-HE:12.9 (golden oracle)"
ls .pi/prompts/osb-*.md >/dev/null 2>&1 && row OK pi-prompts ".pi/prompts/osb-*.md" || row WARN pi-prompts "copy $KIT/pi/prompts/*.md to .pi/prompts and trust the project (pi --approve)"
[ -f "$KIT/pi/preflight.sh" ] && { echo "  --- kit preflight"; bash "$KIT/pi/preflight.sh" 2>&1 | sed 's/^/  /' | tail -15; }
echo "$fail blocking gaps"
exit 0
KIT_EOF_BIN_PREFLIGHT_VDI_SH
mkdir -p "$(dirname "bin/replay_config_from_inventory.py")"
cat > 'bin/replay_config_from_inventory.py' <<'KIT_EOF_BIN_REPLAY_CONFIG_FROM_INVENTORY_PY'
#!/usr/bin/env python3
"""Draft the replay-config entry of a flow from its inventory JSON (osb_inventory.py output).

    replay_config_from_inventory.py <flows/Project__Proxy.json> -o replay-config.json [--project <name>]
                                    [--correlation-header traceId] [--subscription <name>]

Reads the proxy transport (JMS address, queue/topic, selector) and the business services the pipeline routes or
publishes to, and writes/merges the entry `flows.<project>/<proxy>` in the replay config. Everything that cannot be
derived from the export is marked in `_todo`: TARGET broker names (the export holds WebLogic JNDI names), the
correlation header, the error-queue headers. HTTP inbound flows get an `_unsupported` note (replay is JMS-only;
the contract tests cover them). Negative cases are generated from the selector's equality terms. Stdlib only."""
import argparse
import json
import re
import sys
from pathlib import Path


def jndi_name(uri: str) -> str:
    """jms://host:port/jndi.CF/jndi.Queue -> Queue  (last segment, jndi. prefix stripped)."""
    last = uri.rstrip("/").split("/")[-1]
    return re.sub(r"^jndi\.", "", last)


def selector_terms(selector: str) -> list[tuple[str, str]]:
    return re.findall(r"([A-Za-z_][\w.]*)\s*=\s*'([^']*)'", selector or "")


def negative_cases(selector: str) -> list[dict]:
    terms = selector_terms(selector)
    if not terms:
        return []
    first = {}
    for k, v in terms:
        first.setdefault(k, v)
    cases = []
    for k in first:
        headers = dict(first)
        headers[k] = "not-" + first[k]
        cases.append({"name": f"{k} outside the selector is filtered out", "headers": headers})
    return cases


def entry_for(flow: dict, project: str, corr: str, subscription: str | None) -> tuple[str, dict]:
    proxy, pipe = flow["proxy"], flow["pipeline"]
    proxy_name = Path(proxy["ref"]).name
    key = f"{project}/{proxy_name}"
    todo = []
    if proxy.get("transport") != "jms":
        return key, {"_unsupported": f"inbound transport '{proxy.get('transport')}': replay is JMS-only; use the route/contract tests (L1/L2)",
                     "input": {"type": proxy.get("transport"), "uris": proxy.get("uris", [])}}
    props = proxy.get("transport_props", {})
    is_queue = str(props.get("is-queue", "true")).lower() == "true"
    address = jndi_name(proxy["uris"][0]) if proxy.get("uris") else "<input-address>"
    todo.append("input.address and outputs.*.destination are JNDI-derived: replace with the TARGET broker names from the queue register")
    targets = [b for b in flow.get("business", []) if b.get("transport") == "jms" and b.get("uris")]
    refs = pipe.get("routes_to", []) + pipe.get("publishes_to", [])
    ordered = sorted(targets, key=lambda b: refs.index(b["ref"]) if b["ref"] in refs else 99)
    err = next((b for b in ordered if re.search(r"error|dlq|fault|dead", b["ref"], re.I)), None)
    succ = next((b for b in ordered if b is not err), None)
    outputs = {}
    if succ:
        outputs["success"] = {"destination": jndi_name(succ["uris"][0]), "type": "anycast"}
    else:
        outputs["success"] = {"destination": "<success-queue>", "type": "anycast"}
        todo.append("no JMS success target found in routes_to/publishes_to: set outputs.success.destination")
    if err:
        outputs["error"] = {"destination": jndi_name(err["uris"][0]), "type": "anycast",
                            "expect_headers": ["errorCode", "errorMessage", corr]}
        todo.append("outputs.error.expect_headers: confirm against the error handler's transport headers on the flow card")
    else:
        todo.append("no error queue found: confirm from the error handler scopes " + json.dumps(pipe.get("error_handler_scopes", [])))
    e = {
        "input": {"address": address, "type": "anycast" if is_queue else "multicast",
                  "subscription": subscription or f"{proxy_name}-sub", "filter": props.get("message-selector", "")},
        "correlation_header": corr,
        "outputs": outputs,
        "negative_cases": negative_cases(props.get("message-selector", "")),
        "timeout_s": 15,
        "_source": {"proxy": proxy.get("path"), "durable": props.get("durable-subscription"),
                    "xa": props.get("XA-required"), "distribution": props.get("topic-messages-distribution")},
        "_todo": todo + [f"correlation_header '{corr}' is a default: confirm the header the flow logs"],
    }
    return key, e


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("flow_json", type=Path)
    ap.add_argument("-o", "--out", type=Path, required=True, help="replay-config.json to create or merge into")
    ap.add_argument("--project", help="project name used in the flow id (default: from the file name Project__...)")
    ap.add_argument("--correlation-header", default="traceId")
    ap.add_argument("--subscription")
    a = ap.parse_args()
    flow = json.loads(a.flow_json.read_text(encoding="utf-8"))
    stem = a.flow_json.stem
    project = a.project or (stem.split("__")[0] if "__" in stem else a.flow_json.parent.parent.name)
    key, entry = entry_for(flow, project, a.correlation_header, a.subscription)
    cfg = json.loads(a.out.read_text(encoding="utf-8")) if a.out.is_file() else {
        "_comment": "One entry per OSB flow under test. Destinations are TARGET broker names.",
        "broker": {"host": "localhost", "stomp_port": 61613, "user": "artemis", "password_env": "ARTEMIS_PASSWORD"},
        "flows": {}}
    existing = cfg.setdefault("flows", {}).get(key)
    if existing and "_todo" not in existing:
        print(json.dumps({"flow": key, "status": "kept", "detail": "entry exists and was completed by hand; not overwritten"}))
        return 0
    cfg["flows"][key] = entry
    a.out.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"flow": key, "status": "drafted", "todo": entry.get("_todo", []), "unsupported": entry.get("_unsupported")}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_BIN_REPLAY_CONFIG_FROM_INVENTORY_PY
mkdir -p "$(dirname "bin/start_flow.sh")"
cat > 'bin/start_flow.sh' <<'KIT_EOF_BIN_START_FLOW_SH'
#!/usr/bin/env bash
# One entry point per OSB flow on the VDI: OSB source export + Splunk log CSV in, verified Camel module out.
#
#   bin/start_flow.sh <osb-project-dir> <flow> <module-dir> [events.csv] [--transform <orig.xqy|xsl>] [--from <step>]
#
# Deterministic steps (no AI):  inventory -> card scaffold -> log signatures + Splunk queries -> traces (keyed masking,
# residue check) -> replay-config draft -> fixtures -> golden oracle (original transform, ORACLE.lock)
# Agent steps (pi, one fresh process per role): analyse -> GATE A (human approves the card) -> test -> implement
# -> verify (gates G1-G10, fix loops) -> review -> GATE B (human).
#
# Steps for --from: inventory | signatures | traces | fixtures | golden | pi | pi-test
# Env: MASK_KEY (required when events.csv is given), KIT (kit root: git layout <repo>/skills/osb-camel-agent-kit or the
#      paste-installed workspace), REPLAY (osb-log-replay root), SPLUNK_INDEX / SPLUNK_SOURCETYPE (for the generated
#      queries), PER_SCENARIO (default 3), OSB_PI_MODEL / PI_THINKING (passed to the kit runner), DELETE_INPUT=1 to
#      remove events.csv after masking, EXTRA_MASK_ARGS='--mask-json-key x --mask-key-pattern y' for extra personal fields.
set -euo pipefail

PROJECT=${1:?usage: start_flow.sh <osb-project-dir> <flow> <module-dir> [events.csv] [--transform f] [--from step]}
FLOW=${2:?flow name (proxy service name)}
MODULE=${3:?module dir}
shift 3
EVENTS=""; TRANSFORM=""; FROM=inventory
while [ $# -gt 0 ]; do
  case "$1" in
    --transform) TRANSFORM=${2:?}; shift 2;;
    --from) FROM=${2:?}; shift 2;;
    *) EVENTS=$1; shift;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WS=$(pwd)
KIT=${KIT:-$([ -d "$REPO/skills/osb-camel-agent-kit" ] && echo "$REPO/skills/osb-camel-agent-kit" || echo "$WS")}
REPLAY=${REPLAY:-$([ -d "$REPO/osb-log-replay" ] && echo "$REPO/osb-log-replay" || echo "$WS/log-replay")}
SKILL=$([ -d "$KIT/skills/osb-to-camel" ] && echo "$KIT/skills/osb-to-camel" || echo "$KIT/.pi/skills/osb-to-camel")
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
INV="migration/osb-inventory"; OUT="migration/$FLOW"; WORK="work/$FLOW"
mkdir -p "$OUT" "$WORK"
export KIT

step_reached() {  # steps in order; returns 0 when $1 is at or after $FROM
  local order="inventory signatures traces fixtures golden pi pi-test" seen=0 s
  for s in $order; do [ "$s" = "$FROM" ] && seen=1; [ "$s" = "$1" ] && { [ $seen -eq 1 ] && return 0 || return 1; }; done
  return 1
}
say() { printf '\n== %s\n' "$*"; }
need() { [ -e "$1" ] || { echo "missing: $1 ($2)"; exit 1; }; }

need "$SKILL/scripts/osb_inventory.py" "kit skill osb-to-camel"
need "$REPLAY/tools/osb_log_traces.py" "osb-log-replay tools (REPLAY=$REPLAY)"
need "$KIT/tools/golden_runner.py" "kit gate tools"

# ---------------------------------------------------------------- 1 inventory + card scaffold
if step_reached inventory; then
  say "1 inventory of $PROJECT"
  "$PY" "$SKILL/scripts/osb_inventory.py" "$PROJECT" -o "$INV"
  FLOW_JSON=$(ls "$INV"/flows/*__"$FLOW".json "$INV"/flows/*"$FLOW".json 2>/dev/null | head -1 || true)
  [ -n "$FLOW_JSON" ] || { echo "flow '$FLOW' not in $INV/flows (names: $(ls "$INV/flows" | tr '\n' ' '))"; exit 1; }
  if [ -f "$OUT/FLOW_CARD.md" ]; then echo "card exists, not re-scaffolded: $OUT/FLOW_CARD.md"
  else "$PY" "$SKILL/scripts/scaffold_flow.py" "$FLOW_JSON" -o "$OUT" --module "$(basename "$MODULE")"; fi
  echo "$FLOW_JSON" > "$WORK/flow.json.path"
fi
FLOW_JSON=$(cat "$WORK/flow.json.path" 2>/dev/null || ls "$INV"/flows/*"$FLOW".json | head -1)

# ---------------------------------------------------------------- 2 log signatures + Splunk queries
if step_reached signatures; then
  say "2 log signatures from the OSB Log actions"
  "$PY" "$REPLAY/tools/osb_log_signatures.py" "$PROJECT" -o "$WORK/signatures.json"
  "$PY" "$REPLAY/tools/spl_from_signatures.py" "$WORK/signatures.json" \
     --index "${SPLUNK_INDEX:-<osb_index>}" --sourcetype "${SPLUNK_SOURCETYPE:-<osb_sourcetype>}" -o "$WORK/queries.spl"
  echo "Splunk searches: $WORK/queries.spl (run the EXPORT search in Splunk, save CSV with _time,_raw)"
fi

# ---------------------------------------------------------------- 3 traces: keyed masking + residue check
if step_reached traces; then
  if [ -z "$EVENTS" ]; then
    say "3 no events.csv given: skipping traces/fixtures (run again with the Splunk CSV, --from traces)"
  else
    if [ -f "$EVENTS.report.json" ]; then
      say "3 traces from $EVENTS (already anonymised by anonymize_logs.py)"
      "$PY" "$REPLAY/tools/osb_log_traces.py" "$WORK/signatures.json" "$EVENTS" -o "$WORK/traces" --already-masked
    else
      say "3 traces from $EVENTS (masking key: ${MASK_KEY:+set}${MASK_KEY:-MISSING})"
      [ -n "${MASK_KEY:-}" ] || { echo "export MASK_KEY=<key held by the data owner> first (or anonymise first: tools/anonymize_logs.py)"; exit 1; }
      # shellcheck disable=SC2086
      "$PY" "$REPLAY/tools/osb_log_traces.py" "$WORK/signatures.json" "$EVENTS" -o "$WORK/traces" ${DELETE_INPUT:+--delete-input} ${EXTRA_MASK_ARGS:-}
    fi
    "$PY" "$REPLAY/tools/mask_residue_check.py" "$WORK/traces" || { echo "residue check failed: add --mask-json-key/--mask-key-pattern (see RUNBOOK) and rerun --from traces"; exit 1; }
    "$PY" - "$WORK/traces/coverage.json" <<'PY'
import json,sys; c=json.load(open(sys.argv[1]))
print(f"events {c['events_read']}, matched {c['events_matched']}, traces {c['traces']}, without payload {c.get('traces_without_payload')}, "
      f"never-seen signatures {len(c.get('signatures_never_seen',[]))}, masked values {c['masked_values']}, keyed {c['masking']['keyed']}")
assert c["events_matched"] > 0, "no event matched a signature: wrong project or CSV"
PY
  fi
fi

# ---------------------------------------------------------------- 4 replay-config draft + fixtures
if step_reached fixtures && [ -n "$EVENTS" -o -f "$WORK/traces/traces.jsonl" ]; then
  say "4 replay-config draft + fixtures"
  "$PY" "$HERE/replay_config_from_inventory.py" "$FLOW_JSON" -o "$WS/replay-config.json"
  echo "   check the _todo items in replay-config.json (target broker names, error headers) before the replay (L3)"
  "$PY" "$REPLAY/tools/fixtures_from_traces.py" "$WORK/traces/traces.jsonl" "$WS/replay-config.json" -o "$WORK/fixtures" --per-scenario "${PER_SCENARIO:-3}"
  mkdir -p "$MODULE/src/test/resources/golden"
  cp -r "$WORK/fixtures/parity" "$MODULE/src/test/resources/"
  cp "$WORK/fixtures/golden/MANIFEST.csv" "$MODULE/src/test/resources/golden/MANIFEST.csv"
  "$PY" "$REPLAY/tools/mask_residue_check.py" "$MODULE/src/test/resources" > /dev/null || { echo "residue in module resources"; exit 1; }
fi

# ---------------------------------------------------------------- 5 golden oracle (original transform, before any route)
if step_reached golden && [ -d "$MODULE/src/test/resources/parity" ]; then
  say "5 golden oracle"
  if [ -z "$TRANSFORM" ]; then
    TRANSFORM=$("$PY" - "$FLOW_JSON" "$PROJECT" <<'PY'
import json,sys,pathlib
d=json.load(open(sys.argv[1])); refs=d["pipeline"].get("xquery_refs",[])+d["pipeline"].get("xslt_refs",[])
root=pathlib.Path(sys.argv[2]); hits=[]
for r in refs:
    name=r.split("/")[-1]
    hits+=[p for p in root.rglob(name+".*") if p.suffix.lower() in (".xqy",".xquery",".xq",".xsl",".xslt")]
print(hits[0] if len(hits)==1 else "")
PY
)
  fi
  if [ -z "$TRANSFORM" ]; then
    echo "   more than one (or no) transform in the flow: pass --transform <the one that builds the outbound body> (see the card)"
  else
    "$PY" "$KIT/tools/golden_runner.py" run "$MODULE/src/test/resources" --transform "$TRANSFORM" \
       --shim "$SKILL/assets/templates/xquery/fn-bea-shim.xqy" --flow "$(basename "$(dirname "$(ls -d "$MODULE"/src/test/resources/parity/*/ | head -1)")")" || true
    echo "   oracle-blocked cases (if any) -> OSB Test Console, source osb-test-console; never a hand-written file"
  fi
fi

# ---------------------------------------------------------------- 6 agent steps
if step_reached pi; then
  say "6 pi: analyst writes the flow card, then GATE A"
  "$KIT/pi/run_flow.sh" "$PROJECT" "$FLOW" "$MODULE"
  echo "After approving $OUT/FLOW_CARD.md (Status approved + name): bin/start_flow.sh $PROJECT $FLOW $MODULE --from pi-test"
fi
if step_reached pi-test; then
  say "7 pi: tests first, then the route, gates, review"
  "$KIT/pi/run_flow.sh" "$PROJECT" "$FLOW" "$MODULE" --from test
fi
KIT_EOF_BIN_START_FLOW_SH
mkdir -p "$(dirname "bin/task1_log_only.sh")"
cat > 'bin/task1_log_only.sh' <<'KIT_EOF_BIN_TASK1_LOG_ONLY_SH'
#!/usr/bin/env bash
# TASK 1: from a Splunk export alone (no OSB source, no Camel code) to masked test cases, replayed through the mock
# environment against a stand-in flow. Proves the data chain and the mocks before any migration work.
#
#   bin/task1_log_only.sh <events.csv> [work-dir] [--replay]
#
#   1 anonymise (MASK_KEY)           -> <work>/events.masked.csv + .report.json   (raw CSV untouched; delete it yourself)
#   2 signature from the example line -> <work>/signatures.json                    (stands in for the OSB source)
#   3 traces + scenarios              -> <work>/traces/
#   4 replay-config draft + fixtures  -> <work>/replay-config.json, <work>/fixtures/parity/**
#   5 --replay: Artemis + WireMock + stub flow in Docker Compose, replay every case -> <work>/report/report.json
# Env: MASK_KEY (required), REPLAY (osb-log-replay root), EXAMPLE_LINE (which event is the example, default 1),
#      FLOW (<project>/<proxy> if the line does not name them), SUCCESS_QUEUE / ERROR_QUEUE (stand-in output names).
set -euo pipefail
EVENTS=${1:?usage: task1_log_only.sh <events.csv> [work-dir] [--replay]}
WORK=${2:-work/task1}; [ "${2:-}" = "--replay" ] && WORK=work/task1
DO_REPLAY=0; for a in "$@"; do [ "$a" = "--replay" ] && DO_REPLAY=1; done
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
REPLAY=${REPLAY:-$([ -d "$REPO/osb-log-replay" ] && echo "$REPO/osb-log-replay" || echo "$(pwd)/log-replay")}
PY=${PYTHON:-$(command -v python3 || command -v python || command -v py)}
T="$REPLAY/tools"; mkdir -p "$WORK"
[ -n "${MASK_KEY:-}" ] || { echo "export MASK_KEY=<key> first (real key from the data owner; any value for a private trial)"; exit 1; }

echo "== 1 anonymise"
"$PY" "$T/anonymize_logs.py" "$EVENTS" -o "$WORK/events.masked.csv" || { echo "residue found: see $WORK/events.masked.csv.report.json, add --mask-json-key and rerun"; exit 1; }

echo "== 2 signature from example line ${EXAMPLE_LINE:-1}"
"$PY" "$T/signature_from_example.py" "$WORK/events.masked.csv" -o "$WORK/signatures.json" --line "${EXAMPLE_LINE:-1}" ${FLOW:+--flow "$FLOW"}

echo "== 3 traces"
"$PY" "$T/osb_log_traces.py" "$WORK/signatures.json" "$WORK/events.masked.csv" -o "$WORK/traces" --already-masked

echo "== 4 replay-config draft + fixtures"
"$PY" - "$WORK/signatures.json" "$WORK/events.masked.csv" "$WORK/replay-config.json" <<'PY'
import csv, io, json, re, sys
sig = json.load(open(sys.argv[1]))["signatures"][0]
text = open(sys.argv[2], encoding="utf-8").read()
raw = next(r["_raw"] for r in csv.DictReader(io.StringIO(text, newline="")))
m = re.search(r"from\s+JMS\s+(\S+)", raw)
address = m.group(1) if m else "input-address"
flow = sig["flow"]; slug = re.sub(r"[^A-Za-z0-9]+", "-", flow.split("/")[-1]).strip("-")
import os
cfg = {"_comment": "TASK 1 draft: stand-in names for the mock environment; the real names come from the OSB export (task 2).",
       "broker": {"host": "localhost", "stomp_port": 61613, "user": "artemis", "password_env": "ARTEMIS_PASSWORD"},
       "flows": {flow: {
           "input": {"address": address, "type": "multicast" if "topic" in address.lower() else "anycast",
                     "subscription": f"{slug}-sub", "filter": ""},
           "correlation_header": "traceId",
           "outputs": {"success": {"destination": os.environ.get("SUCCESS_QUEUE", f"{slug}-success"), "type": "anycast"},
                       "error": {"destination": os.environ.get("ERROR_QUEUE", f"{slug}-error"), "type": "anycast",
                                 "expect_headers": ["errorCode", "errorMessage", "traceId"]}},
           "negative_cases": [], "timeout_s": 15,
           "_todo": ["selector (filter), output queue names and error headers come from the OSB export in task 2"]}}}
json.dump(cfg, open(sys.argv[3], "w"), indent=2)
print(f"flow {flow}: input {address}, outputs {cfg['flows'][flow]['outputs']['success']['destination']} / {cfg['flows'][flow]['outputs']['error']['destination']}")
PY
rm -rf "$WORK/fixtures"
"$PY" "$T/fixtures_from_traces.py" "$WORK/traces/traces.jsonl" "$WORK/replay-config.json" -o "$WORK/fixtures" --per-scenario "${PER_SCENARIO:-3}"
"$PY" "$T/mask_residue_check.py" "$WORK/fixtures" | tail -1
echo "Scenarios:"; "$PY" -c "import json,sys; [print(f\"  {s['count']:4d}  payload {s['with_payload']:3d}  {s['scenario']}\") for s in json.load(open(sys.argv[1]))]" "$WORK/traces/scenarios.json"

if [ "$DO_REPLAY" = 1 ]; then
  echo "== 5 replay through the mock environment (stand-in flow)"
  ABS=$(cd "$WORK" && pwd); RW="$REPLAY/work/task1"; rm -rf "$RW"; mkdir -p "$RW"
  cp -r "$ABS/fixtures" "$RW/fixtures"; cp "$ABS/replay-config.json" "$RW/replay-config.json"
  cd "$REPLAY/mock"
  [ -f .env ] || printf 'ARTEMIS_PASSWORD=%s\n' "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)" > .env
  export REPLAY_CONFIG=../work/task1/replay-config.json REPLAY_CONFIG_IN_WORK=work/task1/replay-config.json \
         FIXTURES_DIR=work/task1/fixtures REPORT_DIR=work/task1/report
  docker compose up -d artemis wiremock && ./setup_broker.sh
  docker compose --profile selftest up -d sut-stub
  docker compose --profile replay run --rm replay || true
  docker compose --profile selftest down >/dev/null 2>&1 || true
  cp -r "$REPLAY/work/task1/report" "$ABS/report" 2>/dev/null || true
  echo "report: $ABS/report/report.json (stop the stack: cd $REPLAY/mock && docker compose down -v)"
fi
echo "done: $WORK"
KIT_EOF_BIN_TASK1_LOG_ONLY_SH
mkdir -p "$(dirname "RUNBOOK.md")"
cat > 'RUNBOOK.md' <<'KIT_EOF_RUNBOOK_MD'
# VDI runbook: one OSB flow from source + Splunk log to a verified Camel module, with the pi agent

Inputs you always have: the **OSB project source** (sbconfig export unzipped, or the JDeveloper project folder) and a
**Splunk CSV** of the flow's log lines (`_time,_raw`). Everything below runs on the VDI; nothing unmasked leaves it.
Deterministic steps run as scripts; the agent (pi) only does the four role steps, each in a fresh process.

```
OSB source ──► 1 inventory + card ──► 2 log signatures + Splunk queries
Splunk CSV ──► 3 traces (keyed masking, residue check) ──► 4 replay-config draft + fixtures ──► 5 golden oracle (ORACLE.lock)
           ──► 6 pi analyst → GATE A (you approve the card) ──► 7 pi tester → implementer → gates G1-G10 → reviewer → GATE B
```

> **Starting out?** Follow [TASKS.md](TASKS.md): task 1 works on the Splunk export alone (anonymise, test cases, mock replay), task 2 adds the OSB source.

## Map: how the parts fit together

**Two kinds of directories.** The repository holds code only; the workspace holds the data of each flow. Nothing from
the workspace goes into the public repository.

```
REPOSITORY  ~/Projects/P1  (git pull; or paste-installed into the workspace root with bootstrap 1-7)
├── skills/osb-camel-agent-kit/     the agent kit
│   ├── agents/*.md                 role prompts: analyst, tester, implementer, reviewer
│   ├── pi/run_flow.sh, pi/prompts  pi runner (one process per role) and the /osb-* commands
│   ├── tools/                      gates: verify_flow.sh (G1-G10), check_matrix, check_oracle, golden_runner, mutate_transforms, compare_shadow
│   ├── skills/osb-to-camel/        the skill: scripts/osb_inventory.py + scaffold_flow.py, references (mapping tables),
│   │                               assets/templates (route, tests, interface mocks, fn-bea shim)
│   └── bootstrap/1..7_install_*.sh paste-install for a VDI without file transfer
├── osb-log-replay/                 Splunk logs -> masked test cases: tools/ (signatures, queries, traces, fixtures, residue check,
│                                   replay runner), mock/ (Artemis + WireMock compose stack for L3), docs/
└── vdi-osb-migration/              THIS workflow: bin/start_flow.sh (calls the two above in order), preflight, replay-config generator

WORKSPACE  ~/work/osb-migration  (one per engineer; run every command from here)
├── osb-src/<project>/              INPUT 1: the OSB export (sbconfig.jar unzipped, or the JDeveloper project)
├── work/<flow>/                    INPUT 2 + derived: events.csv (Splunk CSV), signatures.json, queries.spl, traces/, fixtures/
├── migration/osb-inventory/        INVENTORY.md, flows/<project>__...__<flow>.json       (step 1)
├── migration/<flow>/               FLOW_CARD.md, test-matrix.json, verify-report.json, REVIEW.md, MIGRATION_RECORD.md, agent-logs/
├── modules/<flow>/                 OUTPUT: the Camel module. src/test first (tests + resources/parity, golden/MANIFEST.csv,
│                                   golden/ORACLE.lock, fixtures/<flow>/backend stubs), src/main after
└── replay-config.json              target broker names per flow (only for the L3 replay)
```

**The process, with what each step reads and writes**

| # | Step | Tool (repository) | Reads | Writes (workspace) | Mock involved |
|---|---|---|---|---|---|
| 1 | Inventory + flow card | `skill/scripts/osb_inventory.py`, `scaffold_flow.py` | `osb-src/<project>` | `migration/osb-inventory/`, `migration/<flow>/FLOW_CARD.md`, `test-matrix.json` | none; the card lists every interface that will be mocked |
| 2 | Log signatures + Splunk searches | `osb-log-replay/tools/osb_log_signatures.py`, `spl_from_signatures.py` | the Log actions in `osb-src` | `work/<flow>/signatures.json`, `queries.spl` | none |
| 3 | Traces, keyed masking, residue check | `osb_log_traces.py`, `mask_residue_check.py` | `work/<flow>/events.csv` + `MASK_KEY` | `work/<flow>/traces/` | none (raw CSV deleted afterwards) |
| 4 | Replay-config draft + fixtures | `vdi/bin/replay_config_from_inventory.py`, `fixtures_from_traces.py` | `flows/<flow>.json`, `traces.jsonl` | `replay-config.json`, `modules/<flow>/src/test/resources/parity/**` (input.payload, headers.json, expected.json), `golden/MANIFEST.csv` | the recorded inputs every mock level replays |
| 5 | Golden oracle | `kit/tools/golden_runner.py` + the skill's `fn-bea-shim.xqy` | the ORIGINAL `.xqy`/`.xsl` from `osb-src`, `parity/**/input.payload` | `parity/**/expected-output.xml`, `golden/ORACLE.lock` | none: this is the reference the mocks are judged against |
| 6 | pi analyst → gate A | `kit/pi/run_flow.sh` (role analyst) | export, inventory | `FLOW_CARD.md` completed; **you approve it** | — |
| 7a | pi tester | role tester + `skill/assets/templates/java/*Test*.java` | the approved card, `parity/**`, `.bix`/WSDL | `modules/<flow>/src/test/**`: route test (**L1 mocks**), golden test, contract test (**WireMock**), broker IT (**Testcontainers**), recorded-cases test; WireMock stubs under `src/test/resources/fixtures/<flow>/backend/` | **the mocks are written here, before any route exists** |
| 7b | pi implementer | role implementer + `skill/assets/templates/java/OsbRouteTemplate.java` | the card, the tests | `modules/<flow>/src/main/**` | the route must satisfy the mocks |
| 7c | gates | `kit/tools/verify_flow.sh` | module | `migration/<flow>/verify-report.json` | G4 runs L1 (Maven only), G5 runs L2 (containers), G10 checks the oracle lock |
| 7d | pi reviewer → gate B | role reviewer | everything above | `REVIEW.md`, `MIGRATION_RECORD.md`; **a second engineer signs** | — |
| 8 | Optional end-to-end replay (L3) | `osb-log-replay/mock/docker-compose.yml`, `replay_runner.py` | `replay-config.json`, `parity/**`, the built image | `work/report/` | **the whole environment is a mock**: Artemis + WireMock + the image |

**Where the mocks live, by level**

| Level | What is real | What stands in | Where it is | Needs |
|---|---|---|---|---|
| L1 unit (gate G4) | the Camel route and its transforms | input `direct:in`, outputs `mock:success`/`mock:error`, backends `mock:backend` (AdviceWith) | `modules/<flow>/src/test/java/*RouteTest.java`, `*GoldenTest.java`, `RecordedCasesRouteTest` | Maven only |
| L2 component (gate G5) | route + a real Artemis + a real WireMock, both as throwaway containers | backend replies, faults, delays (WireMock stubs); the selector as a broker-side filter | `*BackendContractTest.java`, `*IT.java`; stubs in `src/test/resources/fixtures/<flow>/backend/`, replies from the response-stage log or the WSDL | Docker or Podman |
| L3 replay (gate G9, optional) | the built image, as deployed | Artemis + WireMock + the replay runner | `osb-log-replay/mock/`, `replay-config.json` | Docker Compose + the image |
| Other interfaces (DB, DVM, Java callout, file/SFTP, email, security) | — | templates `DatabaseMockTestTemplate`, `DvmLookup`, `JavaCalloutMockTestTemplate`, `FileSftpMockTestTemplate`, `EmailMockTestTemplate`, `SecurityMockTestTemplate` | `skill/assets/templates/java/`, support files in `assets/templates/mocks/` | per template |

**So "start testing" means:** after step 7a the tests exist and fail (no route); after 7b `mvn -q -f modules/<flow>/pom.xml verify`
runs L1 + L2 against the mocks; `tools/verify_flow.sh modules/<flow> <flow>` turns that into the gate report. Nothing
outside the workspace is contacted at any point.

## 0. One-time setup

| Git checkout | Paste install (no file transfer) |
|---|---|
| `git clone git@github.com:PawelWaj/Projects.git ~/Projects && cd ~/Projects/P1` then work in a workspace folder, e.g. `mkdir -p ~/work/osb-migration && cd ~/work/osb-migration`; scripts find the kit and tools in the repo automatically (`KIT`, `REPLAY` can override) | In the workspace root paste and run `bootstrap/1_…7_install_*.sh` from `skills/osb-camel-agent-kit/bootstrap/` in order; the kit lands in the workspace root, the skills in `.pi/skills`, the log tools in `log-replay/`, this workflow in `bin/` |

Then:

```bash
bash bin/preflight_vdi.sh          # 0 blocking gaps expected; WARN lines tell you which gate they affect
pi --approve                       # trust the project once so .pi/prompts and .pi/skills are loaded; "/" must list /osb-*
export MASK_KEY='<key from the data owner>'      # only when you process a Splunk CSV; never write it to a file
export SPLUNK_INDEX=<index> SPLUNK_SOURCETYPE=<sourcetype>   # optional, used in the generated searches
```

Needed on the VDI: Python 3, JDK 21, Maven with the internal mirror, Docker or Podman (otherwise gate G5 and the L3
replay report NOT_RUN), pi with the gateway, a Saxon-HE jar in `~/.m2` (`mvn dependency:get -Dartifact=net.sf.saxon:Saxon-HE:12.9`).

## 0a. Anonymise the Splunk export first (before anything else touches it)

Needs only the CSV and the key; no OSB source. Everything after this step works on the masked file.

```bash
export MASK_KEY='<key from the data owner>'          # never written to a file
python3 ~/Projects/P1/osb-log-replay/tools/anonymize_logs.py work/<flow>/events.csv -o work/<flow>/events.masked.csv
#  -> work/<flow>/events.masked.csv            same columns, personal values replaced
#  -> work/<flow>/events.masked.csv.report.json  counts, key id, residue result, key inventory (no values)
```

1. The command must end with `residue findings 0` (exit 0). Otherwise it lists `file:line: check` (never a value).
2. Open the report's `key_inventory`. Every key with `masked: false` that could identify a person (a short ID, a name,
   a date, an address, free text) is added and the command rerun:
   `--mask-json-key <exactKey>` or `--mask-key-pattern '<regex>'`. Numbers with 9+ digits are always masked.
3. The data owner's reviewer checks a sample of `events.masked.csv` and signs off.
4. Delete the raw file: rerun with `--delete-input` or `rm work/<flow>/events.csv`.
5. Use the masked file from now on: `bin/start_flow.sh … work/<flow>/events.masked.csv`. It sees the report next to it
   and does not mask a second time (`--already-masked`).

## 1. Run a flow

```bash
# A. without logs yet: inventory, card, signatures and the Splunk searches to hand to the Splunk owner
bin/start_flow.sh osb-src/<project> <proxy-name> modules/<proxy-name>
#    -> migration/osb-inventory/, migration/<flow>/FLOW_CARD.md (draft), work/<flow>/queries.spl

# B. with the Splunk CSV: masked test cases, fixtures, golden oracle, then the agent steps up to gate A
export MASK_KEY='…'
bin/start_flow.sh osb-src/<project> <proxy-name> modules/<proxy-name> work/<flow>/events.csv [--transform <orig.xqy>]

# C. approve the card: set "| **Status** | approved" + your name in migration/<flow>/FLOW_CARD.md, then
bin/start_flow.sh osb-src/<project> <proxy-name> modules/<proxy-name> --from pi-test
#    -> tests first (fail for the right reason), route, gates with up to 3 fix loops, review -> gate B (you)
```

`--from <step>` resumes at `inventory | signatures | traces | fixtures | golden | pi | pi-test`.
`DELETE_INPUT=1` removes the raw CSV after masking (do this on the VDI once the residue check is clean).

## 2. What each step produces and what you check

| Step | Output | Check before going on |
|---|---|---|
| 1 inventory + card | `migration/osb-inventory/INVENTORY.md`, `flows/*.json`; `migration/<flow>/FLOW_CARD.md`, `test-matrix.json` | "Referenced but missing from the export" list is empty or each item is requested from the OSB owner |
| 2 signatures | `work/<flow>/signatures.json`, `queries.spl` | The EXPORT search names the right project; run the coverage search first (counts per resource/name) |
| 3 traces | `work/<flow>/traces/{traces.jsonl,scenarios.json,coverage.json}` | `events_matched > 0`; `masking.keyed: true`; residue check `0 findings`; every branch of the card has a scenario, or note "no traffic in window" |
| 4 fixtures | `replay-config.json` (flow entry drafted, `_todo` items), `modules/<flow>/src/test/resources/parity/…`, `golden/MANIFEST.csv` (sha256, key_id) | Resolve the `_todo` items (target broker names, error headers) before any L3 replay; the manifest source of every file is `osb-recording` |
| 5 golden oracle | `parity/**/expected-output.xml`, `golden/ORACLE.lock`, manifest rows `original-transform` | `oracle-blocked` entries (JSON input before nXSD, unshimmed fn-bea function, unbound variable) go to the OSB Test Console, source `osb-test-console`; **never hand-write an expected file** |
| 6 analyst | `FLOW_CARD.md` completed, status draft | You read it against the OSB console/export and approve it (gate A) |
| 7 tester → implementer → verify → reviewer | `src/test` (before `src/main`), `src/main`, `migration/<flow>/verify-report.json` (G1–G10), `REVIEW.md`, `MIGRATION_RECORD.md` | All gates PASS or NOT_APPLICABLE; NOT_RUN (no Docker) is not green: run `tools/verify_flow.sh` on Jenkins; no BLOCKER in the review; a second engineer signs gate B |

## 3. Masking (step 3) in one minute

- The key: generated and held by the data owner, exported as `MASK_KEY` at run time only. Same key → same masked
  value across flows and extracts (reusable test data); different key → different values; no key → not reversible.
- What is masked: JSON fields and XML elements whose name matches the personal-data rules (names incl. Arabic/English
  variants, address/remarks/notes, birth dates, e-mail/phone/mobile, NIN/iqama/passport/national id/social insurance
  no/IBAN/account), plus digit runs of 9+, e-mails and Saudi IBANs in free text. Names → `masked_<hex>`, identifiers →
  same length, birth dates → shifted ≤183 days, e-mails → `@example.invalid`.
- Add a field the rules miss: `--mask-json-key <exact>` or `--mask-key-pattern '<regex>'` on `osb_log_traces.py`
  (the orchestrator passes extra args through `EXTRA_MASK_ARGS`, see `bin/start_flow.sh`), rerun `--from traces`.
- `log-replay/tools/mask_residue_check.py <dir>` prints file, line and check name only, never a value; it must report
  `0 findings` before anything leaves the VDI. Digit identifiers cannot be judged by the scan: the reviewer's sample
  covers them.

## 4. Gates (tools/verify_flow.sh)

G1 build · G2 endpoint URIs · G3 no hosts/secrets · G4 unit/route/golden/contract tests · G5 container tests
(NOT_RUN without Docker, never green) · G6 every test-matrix row has a test · G7 every expected file has an OSB
source (`osb-recording`, `original-transform`, `osb-test-console`; `card-rule` and `source-derived` need reason +
approver) · G8 mutation of transforms · G10 golden outputs unchanged since the runner (`ORACLE.lock`).

## 5. If something stops

| Symptom | Do |
|---|---|
| `flow '<name>' not in migration/osb-inventory/flows` | Use the proxy service name as in the export (`ls migration/osb-inventory/flows`) |
| `no event matched a signature` | Wrong project or CSV; check one raw line is ODL and contains the project/pipeline name |
| residue check finding | Add the reported key with `--mask-json-key`/`--mask-key-pattern`, rerun `--from traces` |
| `more than one (or no) transform in the flow` | Pass `--transform <the XQuery/XSLT that builds the outbound body>` (named on the card) |
| `oracle-blocked` | JSON/nXSD input or unshimmed function: OSB Test Console run, store the file with source `osb-test-console` + reason + approver in MANIFEST |
| `STOP: FLOW_CARD.md is not approved` | Gate A: review, set Status approved + your name, rerun `--from pi-test` |
| `VIOLATION: implementer changed src/test` | The agent broke its lane; restart `--from pi-test` with a fresh tester |
| G5 NOT_RUN | No container runtime for Testcontainers: run `tools/verify_flow.sh modules/<flow> <flow>` on a Jenkins agent with Docker |
| G10 FAIL | An `expected-output.xml` changed after the runner (or was never locked): rerun `tools/golden_runner.py run …`, never edit by hand |
| pi does not list `/osb-*` | `cp pi/prompts/*.md .pi/prompts/` (git layout: `<kit>/pi/prompts`), then `/reload`; trust the project |

## 6. Definition of done per flow

- [ ] Card approved by a named engineer (gate A); every matrix row has a recorded case or a `source-derived` one with reason + approver.
- [ ] Residue check 0 findings; masked sample reviewed by the data owner's reviewer; raw CSV deleted.
- [ ] `verify-report.json`: all gates PASS/NOT_APPLICABLE; G5 run with Docker somewhere; G10 PASS.
- [ ] Review without BLOCKER; gate B signed by a second engineer; `MIGRATION_RECORD.md` lists deviations and the delivery-semantics delta.
- [ ] Time per step noted in `TRIAL_RESULTS_TEMPLATE.csv`.
KIT_EOF_RUNBOOK_MD
chmod +x bin/*.sh bin/*.py 2>/dev/null || true
echo "next: bash bin/preflight_vdi.sh, then read RUNBOOK.md"
echo "installed: 6 files (VDI workflow)"
