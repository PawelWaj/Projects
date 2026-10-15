#!/usr/bin/env bash
# Paste into the migration workspace root on the VDI and run: bash 7_install_vdi_workflow.sh
# VDI workflow: bin/start_flow.sh (one entry point per flow), preflight, replay-config generator, RUNBOOK.md.
set -euo pipefail
mkdir -p "$(dirname "bin/batch_task1.py")"
cat > 'bin/batch_task1.py' <<'KIT_EOF_BIN_BATCH_TASK1_PY'
#!/usr/bin/env python3
"""Task 1 for MANY flows at once: one Splunk export in, masked test cases + test catalogue per flow out.

    batch_task1.py <events.csv|events.jsonl> -o <out-dir> [--flows flows.csv] [--per-scenario 5] [--max-dims 2]
                   [--mask-json-key <field>]... [--already-masked] [--min-events 1]

Fully automatic per flow (no per-domain settings needed):
  1 anonymise the whole export once (MASK_KEY)                       -> <out>/events.masked.csv + report
  2 split by flow ("Project <p> :: for PS <proxy>", else [APP: ...])  -> <out>/flows/<flow>/events.masked.csv
  3 log signatures, auto example lines                               -> signatures.json
  4 scenario fields chosen from the payload itself (low-cardinality code fields such as businessTransaction)
  5 traces + scenarios, replay-config draft, test cases, residue check
  6 selector negatives and fan-out partners from the export: flows reading the same topic
  7 test catalogue per flow, then <out>/SUMMARY.md + summary.csv over all flows
flows.csv (optional) columns: flow,domain[,dims] — restricts the run to those flows, names their domain and can
override the scenario fields (dims separated by ';', e.g. hdr_resource;body:data.businessTransaction).
Exit code 0 only when every flow ends without problems; one failing flow never stops the others. Stdlib only;
works the same in Git Bash and PowerShell."""
import argparse
import csv
import io
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPLAY = Path(os.environ.get("REPLAY") or HERE.parents[1] / "osb-log-replay")
TOOLS = REPLAY / "tools"
sys.path.insert(0, str(TOOLS))
from osb_log_traces import find_payload, osb_message  # noqa: E402

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))
LENIENT = json.JSONDecoder(strict=False)
FLOW_RE = re.compile(r"Project\s+(\S+)\s+::\s+for\s+PS\s+(\S+)")
APP_RE = re.compile(r"\[APP: ([^\]]+)\]")
TOPIC_RE = re.compile(r"from\s+JMS\s+(\S+)")
BS_RE = re.compile(r"Project\s+(\S+)\s+::\s+for\s+BS\s+(\S+)")          # outbound log line: "... for BS x ... ::$body"
UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
RESOURCE_RE = re.compile(r"Resource Name:\s*(.+?)\s+event\b")
CODE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9 _.\-]{0,48}$")
HINT_RE = re.compile(r"transaction|type|event|action|status|decision|approv|operation|category|reason|channel|mode|kind",
                     re.I)


def run(args: list, **kw) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable] + [str(a) for a in args], capture_output=True, text=True, **kw)


def slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-").lower()[:80]


def to_csv(src: Path, dst: Path) -> None:
    """JSON lines from splunk_export.py -> CSV with _time,_raw (what every task-1 tool reads)."""
    with src.open(encoding="utf-8") as fh, dst.open("w", encoding="utf-8", newline="") as out:
        w = csv.writer(out, quoting=csv.QUOTE_ALL)
        w.writerow(["_time", "_raw"])
        for line in fh:
            if line.strip():
                res = json.loads(line).get("result", {})
                if res.get("_raw"):
                    w.writerow([res.get("_time", ""), res["_raw"]])


def read_rows(path: Path) -> list[dict]:
    return list(csv.DictReader(io.StringIO(path.read_text(encoding="utf-8-sig"), newline="")))


def flow_of(raw: str) -> tuple[str | None, str | None, str | None]:
    msg = osb_message(raw)[0]
    m = FLOW_RE.search(msg)
    flow = f"{m.group(1)}/{m.group(2)}" if m else (f"app/{APP_RE.search(raw).group(1)}" if APP_RE.search(raw) else None)
    t, r = TOPIC_RE.search(msg), RESOURCE_RE.search(msg)
    return flow, (t.group(1) if t else None), (r.group(1) if r else None)


def payload_obj(raw: str):
    msg = osb_message(raw)[0]
    start, state = find_payload(msg)
    if start is None or state == "xml":
        return None
    try:
        return LENIENT.raw_decode(msg[start:].strip())[0]
    except ValueError:
        return None


def scalar_paths(node, prefix="", depth=0):
    if isinstance(node, dict) and depth < 4:
        for k, v in node.items():
            yield from scalar_paths(v, f"{prefix}.{k}" if prefix else k, depth + 1)
    elif isinstance(node, str) and prefix:
        yield prefix, node


def choose_dims(raws: list[str], max_dims: int) -> tuple[list[str], list[dict]]:
    """Scenario fields from the payload: present in >= 90 % of events, 2-25 distinct code-like values, not masked."""
    values, n = defaultdict(Counter), 0
    for raw in raws:
        obj = payload_obj(raw)
        if obj is None:
            continue
        n += 1
        for path, v in scalar_paths(obj):
            values[path][v] += 1
    cands = []
    for path, cnt in values.items():
        seen = sum(cnt.values())
        if n == 0 or seen < 0.9 * n or not 2 <= len(cnt) <= 25:
            continue
        if any(v.startswith("masked_") or not CODE_RE.match(v) for v in cnt):
            continue
        hint = bool(HINT_RE.search(path.rsplit(".", 1)[-1]))
        cands.append({"field": "body:" + path, "distinct": len(cnt), "coverage": round(seen / n, 3), "hint": hint})
    cands.sort(key=lambda c: (not c["hint"], c["distinct"], c["field"]))
    hinted = [c["field"] for c in cands if c["hint"]][:max_dims]          # business codes first (businessTransaction ...)
    return hinted or [c["field"] for c in cands[:1]], cands[:10]


def replay_config(flow: str, topic: str | None) -> dict:
    s = slug(flow.split("/")[-1])
    address = topic or "input-address"
    return {"_comment": "TASK 1 draft: stand-in names; the real ones come from the OSB export (task 2).",
            "broker": {"host": "localhost", "stomp_port": 61613, "user": "artemis", "password_env": "ARTEMIS_PASSWORD"},
            "flows": {flow: {"input": {"address": address, "type": "multicast" if "topic" in address.lower() else "anycast",
                                       "subscription": f"{s}-sub", "filter": ""},
                             "correlation_header": "traceId",
                             "outputs": {"success": {"destination": f"{s}-success", "type": "anycast"},
                                         "error": {"destination": f"{s}-error", "type": "anycast",
                                                   "expect_headers": ["errorCode", "errorMessage", "traceId"]}},
                             "negative_cases": [], "timeout_s": 15,
                             "_todo": ["selector, output queues and error headers come from the OSB export in task 2"]}}}


def process_flow(flow: str, info: dict, d: Path, a, peers: dict, base_report: dict) -> dict:
    row = {"domain": info["domain"], "flow": flow, "events": len(info["rows"]), "topic": info["topic"] or "-",
           "status": "OK", "problems": []}
    d.mkdir(parents=True, exist_ok=True)
    ev = d / "events.masked.csv"
    with ev.open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["_time", "_raw"], quoting=csv.QUOTE_ALL, extrasaction="ignore")
        w.writeheader()
        w.writerows(info["rows"])
    raws = [r["_raw"] for r in info["rows"]]
    states = Counter(find_payload(osb_message(r)[0])[1] for r in raws)
    report = {**{k: base_report[k] for k in ("masking", "residue_check") if k in base_report},
              "split_from": base_report.get("output", "events.masked.csv"), "events": len(raws),
              "payloads": {"after_masking": dict(states)}}
    (d / "events.masked.csv.report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    row["payloads"] = dict(states)
    sig = run([TOOLS / "signature_from_example.py", ev, "-o", d / "signatures.json", "--flow", flow])
    if sig.returncode:
        row.update(status="FAIL", problems=[f"signatures: {sig.stderr.strip()[-200:]}"])
        return row
    row["lines_matched"] = json.loads(sig.stdout.strip().splitlines()[-1])["lines_matched"]
    auto, cands = choose_dims(raws, a.max_dims)
    dims = info["dims"] or (["hdr_resource"] if info["resources"] else []) + auto
    row["dims"] = ";".join(dims) or "(hdr_* only)"
    (d / "dims.json").write_text(json.dumps({"chosen": dims, "candidates": cands}, indent=2), encoding="utf-8")
    tr = run([TOOLS / "osb_log_traces.py", d / "signatures.json", ev, "-o", d / "traces", "--already-masked"]
             + (["--dims", ",".join(dims)] if dims else []))
    if tr.returncode:
        row.update(status="FAIL", problems=[f"traces: {tr.stderr.strip()[-200:]}"])
        return row
    (d / "replay-config.json").write_text(json.dumps(replay_config(flow, info["topic"]), indent=2), encoding="utf-8")
    fx = run([TOOLS / "fixtures_from_traces.py", d / "traces/traces.jsonl", d / "replay-config.json", "-o", d / "fixtures",
              "--per-scenario", a.per_scenario])
    if fx.returncode:
        row.update(status="FAIL", problems=[f"fixtures: {fx.stderr.strip()[-200:]}"])
        return row
    res = run([TOOLS / "mask_residue_check.py", d / "fixtures"])
    row["residue"] = int(m.group(1)) if (m := re.search(r"(\d+) findings", res.stdout)) else -1
    args = [HERE / "test_catalog.py", d]
    for r in sorted(peers["negatives"]):
        args += ["--negative-resource", r]
    for p in sorted(peers["fanout"]):
        args += ["--fanout-peer", p]
    cat = run(args)
    try:
        c = json.loads(cat.stdout.strip().splitlines()[-1])
        row.update(scenarios=c["parity"], test_cases=c["test_cases"], folder_problems=c["case_folders_with_problems"])
    except (ValueError, IndexError):
        row["problems"].append(f"catalogue: {cat.stderr.strip()[-200:]}")
    if row["residue"] != 0:
        row["problems"].append(f"residue findings {row['residue']}")
    if row.get("folder_problems"):
        row["problems"].append(f"{row['folder_problems']} case folders with problems")
    if not row["lines_matched"].startswith(str(len(raws)) + "/"):
        row["problems"].append(f"only {row['lines_matched']} lines matched")
    if row["problems"]:
        row["status"] = "CHECK"
    return row


def topic_peers(flows: dict) -> dict:
    """Same topic = same input: other flows' resources are this flow's negatives; shared resources mean fan-out."""
    by_topic = defaultdict(list)
    for f, i in flows.items():
        if i["topic"]:
            by_topic[i["topic"]].append(f)
    out = {}
    for f, i in flows.items():
        others = [o for o in by_topic.get(i["topic"], []) if o != f]
        neg = set().union(*(flows[o]["resources"] for o in others)) - i["resources"] if others else set()
        fan = {o.split("/")[-1] for o in others if flows[o]["resources"] & i["resources"]}
        out[f] = {"negatives": neg, "fanout": fan}
    return out


def write_summary(out: Path, rows: list[dict], skipped: Counter) -> None:
    cols = ["domain", "flow", "status", "events", "lines_matched", "scenarios", "test_cases", "residue", "dims", "topic",
            "problems"]
    with (out / "summary.csv").open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({**r, "problems": "; ".join(r["problems"])})
    with (out / "flows-found.csv").open("w", encoding="utf-8", newline="") as fh:     # template for --flows
        w = csv.writer(fh)
        w.writerow(["flow", "domain", "dims", "events"])
        for r in rows:
            w.writerow([r["flow"], r["domain"], r.get("dims", "").replace("(hdr_* only)", ""), r["events"]])
    md = ["# Task 1 — all flows", "",
          f"{len(rows)} flows: {sum(r['status'] == 'OK' for r in rows)} OK, {sum(r['status'] == 'CHECK' for r in rows)} CHECK, "
          f"{sum(r['status'] == 'FAIL' for r in rows)} FAIL. Test cases: {sum(r.get('test_cases', 0) for r in rows)}.", "",
          "| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    for r in rows:
        md.append("| " + " | ".join(str("; ".join(r["problems"]) if c == "problems" else r.get(c, "")).replace("|", "/")
                                    for c in cols) + " |")
    if skipped:
        md += ["", "Not processed: " + ", ".join(f"{k} ({v} events)" for k, v in skipped.most_common())]
    md += ["", "Per flow: `flows/<flow>/TEST_CATALOG.md`, `dims.json` (why these scenario fields), `fixtures/parity/**`."]
    (out / "SUMMARY.md").write_text("\n".join(md) + "\n", encoding="utf-8")


def load_flow_list(path: Path | None) -> dict:
    if not path:
        return {}
    rows = read_rows(path)
    return {r["flow"].strip(): {"domain": (r.get("domain") or "").strip(),
                                "dims": [x for x in (r.get("dims") or "").split(";") if x.strip()]} for r in rows}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("events", type=Path, help="Splunk export: CSV (_time,_raw) or JSON lines from splunk_export.py")
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--flows", type=Path, help="optional flows.csv: flow,domain[,dims]")
    ap.add_argument("--per-scenario", type=int, default=5)
    ap.add_argument("--max-dims", type=int, default=2, help="payload fields used to split scenarios (auto)")
    ap.add_argument("--min-events", type=int, default=1, help="skip flows with fewer events")
    ap.add_argument("--mask-json-key", action="append", default=[])
    ap.add_argument("--already-masked", action="store_true", help="input is already the masked CSV")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    src = a.events
    if src.suffix.lower() in (".jsonl", ".json"):
        src = a.out / "events.csv"
        to_csv(a.events, src)
    masked = a.out / "events.masked.csv"
    if a.already_masked:
        masked = src
    else:
        if not os.environ.get("MASK_KEY"):
            sys.exit("export MASK_KEY=<key> first (real key from the data owner; any value for a private trial)")
        r = run([TOOLS / "anonymize_logs.py", src, "-o", masked] + sum((["--mask-json-key", k] for k in a.mask_json_key), []))
        print(r.stdout.strip())
        if r.returncode:
            print(r.stderr.strip()[-500:])
            sys.exit("anonymise: residue found or error; see the report next to " + str(masked))
    rep = masked.with_name(masked.name + ".report.json")
    if not rep.is_file():
        sys.exit(f"{rep} missing: the masked input must come with its anonymisation report")
    base_report = json.loads(rep.read_text(encoding="utf-8"))
    if base_report.get("residue_check", {}).get("findings") != 0:
        sys.exit(f"{rep}: residue findings are not 0; fix the masking first")
    wanted = load_flow_list(a.flows)
    flows, skipped = {}, Counter()
    rows_all = read_rows(masked)
    by_trace = {}                                  # (project, trace id) -> flow, from the proxy's own lines
    for row in rows_all:
        msg = osb_message(row.get("_raw", ""))[0]
        m, u = FLOW_RE.search(msg), UUID_RE.search(msg)
        if m and u:
            by_trace[(m.group(1), u.group(0).lower())] = f"{m.group(1)}/{m.group(2)}"
    for row in rows_all:
        f, topic, res = flow_of(row.get("_raw", ""))
        msg = osb_message(row.get("_raw", ""))[0]
        b, u = BS_RE.search(msg), UUID_RE.search(msg)
        if b and u and (b.group(1), u.group(0).lower()) in by_trace:   # outbound line belongs to the proxy that sent it
            f, topic, res = by_trace[(b.group(1), u.group(0).lower())], None, None
        if not f:
            skipped["(no flow id)"] += 1
            continue
        i = flows.setdefault(f, {"rows": [], "topic": topic, "resources": set(),
                                 "domain": (wanted.get(f, {}).get("domain") or f.split("/")[0]),
                                 "dims": wanted.get(f, {}).get("dims", [])})
        i["rows"].append(row)
        i["topic"] = i["topic"] or topic
        if res:
            i["resources"].add(res)
    for f in [f for f, i in flows.items() if len(i["rows"]) < a.min_events]:
        skipped[f] += len(flows.pop(f)["rows"])
    peers = topic_peers(flows)                     # over ALL flows in the export, so negatives stay complete
    for f in [f for f in flows if wanted and f not in wanted]:
        skipped[f + " (not in --flows)"] += len(flows.pop(f)["rows"])
    (a.out / "topics.json").write_text(json.dumps({f: {"topic": i["topic"], "resources": sorted(i["resources"]),
                                                       "negatives": sorted(peers[f]["negatives"]),
                                                       "fanout": sorted(peers[f]["fanout"])} for f, i in sorted(flows.items())},
                                                  indent=2, ensure_ascii=False), encoding="utf-8")
    rows = []
    for f in sorted(flows):
        print(f"== {f} ({len(flows[f]['rows'])} events)", flush=True)
        r = process_flow(f, flows[f], a.out / "flows" / slug(f), a, peers[f], base_report)
        print(f"   {r['status']}: {r.get('scenarios', 0)} scenarios, {r.get('test_cases', 0)} test cases, dims {r.get('dims', '-')}"
              + (f"; {'; '.join(r['problems'])}" if r["problems"] else ""), flush=True)
        rows.append(r)
    write_summary(a.out, rows, skipped)
    print(json.dumps({"flows": len(rows), "ok": sum(r["status"] == "OK" for r in rows),
                      "check": sum(r["status"] == "CHECK" for r in rows), "fail": sum(r["status"] == "FAIL" for r in rows),
                      "test_cases": sum(r.get("test_cases", 0) for r in rows), "summary": str(a.out / "SUMMARY.md")}))
    return 0 if rows and all(r["status"] == "OK" for r in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_BIN_BATCH_TASK1_PY
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
    rs = KIT / "skills" / "osb-research"
    emit("8_install_skill_osb_research.sh", "Skill osb-research (shareable research pack) under .pi/skills/ + researcher role + pi runner.",
         [(p, ".pi/skills/osb-research/" + rel(rs, p)) for p in files_under(rs, ["SKILL.md", "scripts/*.py", "references/*", "assets/*"])]
         + [(KIT / "agents/researcher.md", "agents/researcher.md"), (KIT / "pi/run_research.sh", "pi/run_research.sh"), (KIT / "pi/pi_call.sh", "pi/pi_call.sh"), (KIT / "pi/osb-kit.env.example", "pi/osb-kit.env.example"), (KIT / "pi/init_env.sh", "pi/init_env.sh"),
            (KIT / "pi/prompts/osb-research.md", ".pi/prompts/osb-research.md")],
         ["chmod +x .pi/skills/osb-research/scripts/*.py pi/run_research.sh 2>/dev/null || true"], "skill osb-research")
    ck = KIT / "skills" / "osb-camelk-route"
    emit("9_install_skill_osb_camelk.sh", "Skill osb-camelk-route (research pack -> Camel K YAML module + tests + gates) under .pi/skills/ + implementer role + pi runners (one flow, whole domain).",
         [(p, ".pi/skills/osb-camelk-route/" + rel(ck, p)) for p in files_under(ck, ["SKILL.md", "scripts/*.py", "references/*", "assets/templates/*"])]
         + [(KIT / "agents/implementer-camelk.md", "agents/implementer-camelk.md"), (KIT / "agents/tester-camelk.md", "agents/tester-camelk.md"), (KIT / "pi/run_camelk.sh", "pi/run_camelk.sh"),
            (KIT / "pi/run_domain.sh", "pi/run_domain.sh"), (KIT / "pi/run_tests.sh", "pi/run_tests.sh"), (KIT / "pi/pi_call.sh", "pi/pi_call.sh"), (KIT / "pi/run_research.sh", "pi/run_research.sh"),
            (KIT / "pi/preflight.sh", "pi/preflight.sh"), (KIT / "AGENTS.md", "AGENTS.md"),
            (KIT / "pi/prompts/osb-camelk.md", ".pi/prompts/osb-camelk.md")]
         + [(p, ".pi/skills/osb-research/" + rel(rs, p)) for p in files_under(rs, ["references/*", "assets/*"])],
         ["chmod +x .pi/skills/osb-camelk-route/scripts/*.py pi/*.sh 2>/dev/null || true"], "skill osb-camelk-route + domain runner")
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
    wf = files_under(VDI, ["bin/*", "RUNBOOK.md", "TASKS.md", "LOGS_END_TO_END.md", "ALL_FLOWS.md", "RESEARCH_PACK.md", "DOMAIN_RUN.md", "HOW_IT_WORKS.md", "CODEGEN_RUNBOOK.md", "FUNCTIONAL_TESTING.md"])
    emit("7_install_vdi_workflow.sh", "VDI workflow: bin/start_flow.sh (one entry point per flow), preflight, replay-config generator, RUNBOOK.md.",
         [(p, rel(VDI, p)) for p in wf], ["chmod +x bin/*.sh bin/*.py 2>/dev/null || true",
                                          'echo "next: bash bin/preflight_vdi.sh, then read RUNBOOK.md"'], "VDI workflow")


if __name__ == "__main__":
    main()
KIT_EOF_BIN_BUILD_BOOTSTRAP_PY
mkdir -p "$(dirname "bin/compare_codegen.py")"
cat > 'bin/compare_codegen.py' <<'KIT_EOF_BIN_COMPARE_CODEGEN_PY'
#!/usr/bin/env python3
"""Compare Camel K routes generated by different skills against ONE frozen test pack. Stdlib only.

    compare_codegen.py <module> --candidate <name>=<route-dir>[,map=<endpoint-map.properties>] ... [-o compare/<flow>]
                       [--mvn "mvn -B -q -s ~/.m2/settings.xml"] [--mutate]

<module>      a module made by run_tests.sh / run_camelk.sh: its src/test/** (generated tests, frozen cases, stubs,
              FlowErrorTest) is the judge for every candidate
<route-dir>   what a skill generated: *.camel.yaml (+ optional *.java helper beans, application.properties)
endpoint map  only when a candidate does not use the endpoint contract (flow.input, out.<business-service>,
              backend.<name>): lines '<uri in their route> = {{out.x}}' replace their URIs before the run
Per candidate: copy of the module with ITS route and beans, `mvn test`, gates K2-K9 (K1 approval and K3 route ids
are reported but do not decide: another skill uses other ids), test matrix, optional mutation check.
Writes COMPARISON.md + comparison.csv: tests run / failed / skipped, scenarios passed, error tests, gates, mutations
caught, route size. Same tests, same inputs, so the numbers are comparable."""
import argparse
import csv
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SK = next((p for p in (Path(__file__).resolve().parents[2] / "skills/osb-camel-agent-kit/skills/osb-camelk-route/scripts",
                       Path(__file__).resolve().parents[1] / ".pi/skills/osb-camelk-route/scripts") if p.is_dir()), None)


def surefire(mod: Path) -> dict:
    t = f = e = s = 0
    for rep in (mod / "target/surefire-reports").glob("TEST-*.xml"):
        r = ET.parse(rep).getroot()
        t, f, e, s = t + int(r.get("tests", 0)), f + int(r.get("failures", 0)), e + int(r.get("errors", 0)), s + int(r.get("skipped", 0))
    return {"tests": t, "failed": f + e, "skipped": s}


def prepare(module: Path, name: str, src: Path, mapping: Path | None, out: Path) -> Path:
    d = out / name
    if d.exists():
        shutil.rmtree(d)
    shutil.copytree(module, d, ignore=shutil.ignore_patterns("target", ".agent-logs", "GATES.json", "MUTATION.json", "TEST_MATRIX.md",
                                                               "test-matrix.csv"))
    routes = d / "src/main/resources/routes"
    for f in routes.glob("*.camel.yaml"):
        f.unlink()
    pairs = []
    if mapping:
        for line in mapping.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.split("=", 1)
                pairs.append((k.strip(), v.strip()))
    yamls = sorted(src.rglob("*.camel.yaml")) + sorted(p for p in src.rglob("*.yaml") if not p.name.endswith(".camel.yaml"))
    java_routes = [j for j in src.rglob("*.java") if "extends RouteBuilder" in j.read_text(encoding="utf-8", errors="replace")]
    if not yamls and not java_routes:
        sys.exit(f"{name}: no *.yaml route and no Java RouteBuilder in {src}")
    for y in yamls:
        text = y.read_text(encoding="utf-8")
        for k, v in sorted(pairs, key=lambda kv: -len(kv[0])):
            text = text.replace(k, v)
        (routes / (y.stem.replace(".camel", "") + ".camel.yaml")).write_text(text, encoding="utf-8")
    for j in src.rglob("*.java"):                       # their helper beans / Java routes, same package path as in their tree
        text = j.read_text(encoding="utf-8")
        for k, v in sorted(pairs, key=lambda kv: -len(kv[0])):
            text = text.replace(k, v)
        pkg = re.search(r"^\s*package\s+([\w.]+)\s*;", text, re.M)
        dest = d / "src/main/java" / (pkg.group(1).replace(".", "/") if pkg else "") / j.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text, encoding="utf-8")
    if java_routes:                                     # Java DSL candidate: register its RouteBuilders by class name
        fqn = []
        for j in java_routes:
            pkg = re.search(r"^\s*package\s+([\w.]+)\s*;", j.read_text(encoding="utf-8"), re.M)
            fqn.append((pkg.group(1) + "." if pkg else "") + j.stem)
        with (d / "src/main/resources/application.properties").open("a", encoding="utf-8") as fh:
            fh.write("\ncamel.main.routes-builder-classes=" + ",".join(fqn) + "\n")
    props = next(iter(src.rglob("application.properties")), None)
    if props:                                           # keep the contract keys the tests rely on, add theirs
        base = (d / "src/main/resources/application.properties").read_text(encoding="utf-8")
        (d / "src/main/resources/application.properties").write_text(base + "\n# --- candidate " + name + "\n" +
                                                                     props.read_text(encoding="utf-8"), encoding="utf-8")
    return d


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--candidate", action="append", required=True, help="name=route-dir[,map=file]")
    ap.add_argument("-o", "--out", type=Path)
    ap.add_argument("--mvn", default="mvn -B -q")
    ap.add_argument("--mutate", action="store_true")
    a = ap.parse_args()
    if not SK:
        sys.exit("skill osb-camelk-route scripts not found")
    mvn = [os.path.expanduser(x) for x in shlex.split(a.mvn)]
    out = a.out or Path("compare") / a.module.name
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    for c in a.candidate:
        name, rest = c.split("=", 1)
        parts = rest.split(",map=")
        src, mapping = Path(parts[0]), (Path(parts[1]) if len(parts) > 1 else None)
        d = prepare(a.module, name, src, mapping, out)
        print(f"== {name}: mvn test", flush=True)
        r = subprocess.run(mvn + ["-f", str(d / "pom.xml"), "test"], capture_output=True, text=True)
        (d / "mvn.log").write_text(r.stdout + r.stderr, encoding="utf-8")
        st = surefire(d)
        subprocess.run([sys.executable, str(SK / "check_camelk.py"), str(d)], capture_output=True)
        gates = json.loads((d / "GATES.json").read_text(encoding="utf-8"))["gates"] if (d / "GATES.json").is_file() else {}
        deciding = {k: g["ok"] for k, g in gates.items() if not k.startswith(("K1_", "K3_"))}
        mut = "-"
        if a.mutate and r.returncode == 0:
            subprocess.run([sys.executable, str(SK / "mutate_route.py"), str(d), "--mvn", a.mvn], capture_output=True)
            mj = d / "MUTATION.json"
            if mj.is_file():
                m = json.loads(mj.read_text(encoding="utf-8"))
                mut = f"{m['killed']}/{m['total']}"
        mx = subprocess.run([sys.executable, str(SK / "test_matrix.py"), str(d)], capture_output=True, text=True).stdout.strip()
        s = json.loads(mx) if mx.startswith("{") else {}
        lines = sum(len(p.read_text(encoding="utf-8").splitlines()) for p in (d / "src/main/resources/routes").glob("*.yaml"))
        java = sum(len(p.read_text(encoding="utf-8").splitlines()) for p in (d / "src/main/java").rglob("*.java"))
        rows.append({"candidate": name, "build": "ok" if st["tests"] else "FAILED (see mvn.log)", "tests": st["tests"],
                     "failed": st["failed"], "skipped": st["skipped"],
                     "scenarios_pass": f"{s.get('scenarios_pass', 0)}/{s.get('scenarios', 0)}",
                     "error_tests_failed": s.get("error_tests_failed", "-"),
                     "gates_K2_K9": "PASS" if deciding and all(deciding.values()) else
                                    "FAIL: " + ", ".join(k for k, ok in deciding.items() if not ok),
                     "mutations_caught": mut, "route_lines": lines, "java_lines": java})
        print("   " + json.dumps(rows[-1]), flush=True)
    cols = list(rows[0])
    with (out / "comparison.csv").open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    md = [f"# Code generation comparison: {a.module.name}", "",
          "Same frozen test pack (real + synthetic cases, generated parity tests, error tests) for every candidate. "
          "Lower failed, higher scenarios_pass and mutations_caught = closer to OSB. Gates K1 (approval) and K3 (route ids) "
          "are not counted: candidates use their own ids.", "",
          "| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    md += ["| " + " | ".join(str(r[c]) for c in cols) + " |" for r in rows]
    (out / "COMPARISON.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print(f"written {out / 'COMPARISON.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_BIN_COMPARE_CODEGEN_PY
mkdir -p "$(dirname "bin/domain_coverage.py")"
cat > 'bin/domain_coverage.py' <<'KIT_EOF_BIN_DOMAIN_COVERAGE_PY'
#!/usr/bin/env python3
"""Which flows of one OSB application can get REAL test messages from Splunk, and which need synthetic ones. Stdlib only.

    domain_coverage.py <inventory-dir> <splunk-payload.csv> [-o domain/COVERAGE.md]

inventory-dir       output of osb_inventory.py on the application (flows/*.json)
splunk-payload.csv  the Splunk table "stats count by project, proxy, payload" (DOMAIN_RUN.md), any OSB domain
Groups every proxy of the application:
  A real inputs     the proxy logs its payload (json/xml): test messages from Splunk, like the pilot
  B no payload      the proxy logs, but without the message: Splunk gives volumes only; synthetic test messages
  C not in Splunk   no log line in the window (no Log action, pollers, no traffic): synthetic test messages
plus transport (jms / http / jca / local) and complexity, so the batches can be planned. Writes COVERAGE.md +
coverage.csv (names and counts only, shareable)."""
import argparse
import csv
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inventory", type=Path)
    ap.add_argument("splunk", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=Path("domain/COVERAGE.md"))
    a = ap.parse_args()
    logs = defaultdict(lambda: Counter())
    with a.splunk.open(encoding="utf-8-sig") as fh:
        sample = fh.read(2048)
        fh.seek(0)
        dialect = csv.Sniffer().sniff(sample, delimiters=",;\t")
        for r in csv.DictReader(fh, dialect=dialect):
            r = {k.strip().lower(): (v or "").strip() for k, v in r.items() if k}
            if r.get("proxy"):
                logs[(r.get("project", ""), r["proxy"])][r.get("payload", "none")] += int(float(r.get("count") or 0))
    by_proxy = defaultdict(list)
    for (p, x), c in logs.items():
        by_proxy[x].append((p, c))
    rows = []
    for f in sorted(a.inventory.glob("flows/*.json")):
        d = json.loads(f.read_text(encoding="utf-8"))
        ref = d["proxy"].get("ref") or f.stem
        parts = ref.split("/")
        proxy = parts[-1]
        project = next((s for s in parts[:-1] if s not in ("Proxy_Service", "Proxy", "ProxyService")), "") or f.stem.split("__")[0]
        c = logs.get((project, proxy)) or (by_proxy[proxy][0][1] if len(by_proxy.get(proxy, [])) == 1 else None)
        c = c or Counter()
        real = c.get("json", 0) + c.get("xml", 0)
        group = "A real inputs" if real else ("B no payload" if c.get("none") else "C not in Splunk")
        rows.append({"project": project, "proxy": proxy, "transport": d["proxy"].get("transport") or "?",
                     "tier": (d.get("triage") or {}).get("tier", "?"), "missing_refs": len(d.get("missing_refs") or []),
                     "logged_with_payload": real, "logged_without_payload": c.get("none", 0), "group": group})
    a.out.parent.mkdir(parents=True, exist_ok=True)
    cols = list(rows[0]) if rows else ["project"]
    with a.out.with_name("coverage.csv").open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    grp = Counter(r["group"] for r in rows)
    cross = Counter((r["group"], r["transport"]) for r in rows)
    transports = sorted({r["transport"] for r in rows})
    md = [f"# Test-input coverage: {len(rows)} proxies", "",
          "A = payload logged in Splunk (real masked test messages, like the pilot). B = logged without payload, C = not in "
          "Splunk: these get synthetic test messages (fake values, from the message schema, written before the route).", "",
          "| Group | " + " | ".join(transports) + " | Total |", "|---|" + "---|" * (len(transports) + 1)]
    for g in sorted(grp):
        md.append(f"| {g} | " + " | ".join(str(cross[(g, t)]) for t in transports) + f" | {grp[g]} |")
    md += ["", "| Project | Proxy | Transport | Tier | Missing refs | Logged with payload | Logged without | Group |",
           "|---|---|---|---|---|---|---|---|"]
    md += [f"| {r['project']} | {r['proxy']} | {r['transport']} | {r['tier']} | {r['missing_refs']} | {r['logged_with_payload']} | "
           f"{r['logged_without_payload']} | {r['group']} |" for r in sorted(rows, key=lambda r: (r["group"], r["project"], r["proxy"]))]
    a.out.write_text("\n".join(md) + "\n", encoding="utf-8")
    print(json.dumps({"proxies": len(rows), **{k: v for k, v in sorted(grp.items())}, "out": str(a.out)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_BIN_DOMAIN_COVERAGE_PY
mkdir -p "$(dirname "bin/estimate_pi_load.py")"
cat > 'bin/estimate_pi_load.py' <<'KIT_EOF_BIN_ESTIMATE_PI_LOAD_PY'
#!/usr/bin/env python3
"""Estimate the model load (calls, tokens) and run time of the pi steps per flow, from the size of each flow's OSB source.

    estimate_pi_load.py <inventory-dir> <osb-application-folder> [--coverage domain/coverage.csv]
                        [--rpm 20] [--tpm 200000] [--timings domain/timings.csv] [-o domain/PI_LOAD_ESTIMATE.md]

An agent re-sends its whole conversation on every call, so the tokens of a step grow with the number of calls times
the material it has read. Per flow (assumptions, all in one place below and printed in the report):
  research     calls = files read + 6 (skill, facts, writing two files, share check); context = instructions + half the
               source on average over the step
  tester       only for flows without real Splunk messages (coverage B/C): calls = 8; context = instructions + schemas
  implementer  calls = 20 (route, error tests, mvn runs, gates); context = instructions + research pack + tests + XQuery
Time per step = the larger of (calls x seconds per call) and (tokens / tokens-per-minute, calls / requests-per-minute):
the second term is the quota. --timings (written by run_domain.sh) replaces estimates with measured times where present.
Names and counts only; no source content is printed. Stdlib only."""
import argparse
import csv
import json
import math
import sys
from pathlib import Path

CHARS_PER_TOKEN = 3.5          # XML/XQuery are token-dense
PI_SYSTEM = 2500               # pi's own system prompt: NOT measured, an estimate
BASE = {"research": 6400 + PI_SYSTEM,     # role + skill + questions + template + schema + AGENTS.md (kit files, measured)
        "tester": 1800 + PI_SYSTEM,       # role + AGENTS.md (measured)
        "implementer": 4200 + PI_SYSTEM}  # role + skill + YAML patterns + AGENTS.md (measured)
OUT_TOKENS = {"research": 6000, "tester": 2500, "implementer": 8000}
SEC_PER_CALL = 12              # model latency incl. reasoning, without queueing
TRANSFORM_EXT = {".xqy", ".xq", ".xquery", ".xsl", ".xslt"}
SCHEMA_EXT = {".xsd", ".wsdl"}


def files_of(app: Path, flow: dict) -> tuple[list[Path], list[Path]]:
    refs = [flow["proxy"].get("path")] + [(flow.get("pipeline") or {}).get("path")] + [b.get("path") for b in flow.get("business") or []]
    main = [app / r for r in refs if r and (app / r).is_file()]
    names = {(t.get("ref") or "").split("/")[-1].lower() for t in flow.get("transforms") or []}
    prj = app / (flow["proxy"].get("ref") or "").split("/")[0]
    extra, schemas = [], []
    if prj.is_dir():
        for p in prj.rglob("*"):
            if p.is_file() and p.suffix.lower() in TRANSFORM_EXT and p.stem.split(".")[0].lower() in names:
                extra.append(p)
            elif p.is_file() and p.suffix.lower() in SCHEMA_EXT:
                schemas.append(p)
    return main + extra, schemas


def tokens(paths: list[Path]) -> int:
    return int(sum(p.stat().st_size for p in paths) / CHARS_PER_TOKEN)


def step(calls: int, ctx: int, out: int, rpm: float, tpm: float) -> dict:
    tok_in = calls * ctx
    work = calls * SEC_PER_CALL
    quota = max(60 * calls / rpm, 60 * (tok_in + out) / tpm)
    return {"calls": calls, "tokens": tok_in + out, "minutes": round(max(work, quota) / 60, 1)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inventory", type=Path)
    ap.add_argument("app", type=Path)
    ap.add_argument("--coverage", type=Path)
    ap.add_argument("--rpm", type=float, default=20, help="requests per minute allowed by the endpoint (ask the owner)")
    ap.add_argument("--tpm", type=float, default=200000, help="tokens per minute allowed by the endpoint (ask the owner)")
    ap.add_argument("--timings", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=Path("domain/PI_LOAD_ESTIMATE.md"))
    a = ap.parse_args()
    cov = {}
    if a.coverage and a.coverage.is_file():
        cov = {(r["project"], r["proxy"]): r["group"].split(" ")[0] for r in csv.DictReader(a.coverage.open(encoding="utf-8"))}
    measured = {}
    if a.timings and a.timings.is_file():
        for r in csv.DictReader(a.timings.open(encoding="utf-8")):
            if r.get("exit", "0") == "0":          # only successful runs are a measurement (the last one wins)
                measured[(r["project"], r["proxy"], r["stage"])] = round(int(r["seconds"]) / 60, 1)
    rows = []
    for f in sorted(a.inventory.glob("flows/*.json")):
        d = json.loads(f.read_text(encoding="utf-8"))
        ref = (d["proxy"].get("ref") or "").split("/")
        project, proxy = ref[0], ref[-1]
        src, schemas = files_of(a.app, d)
        src_t, sch_t = tokens(src), tokens(schemas)
        group = cov.get((project, proxy), "?")
        r = step(len(src) + 6, BASE["research"] + src_t // 2, OUT_TOKENS["research"], a.rpm, a.tpm)
        t = step(8, BASE["tester"] + min(sch_t, 40000), OUT_TOKENS["tester"], a.rpm, a.tpm) if group in ("B", "C", "?") else \
            {"calls": 0, "tokens": 0, "minutes": 0.0}
        xq = tokens([p for p in src if p.suffix.lower() in TRANSFORM_EXT])
        i = step(20, BASE["implementer"] + 6000 + 8000 + xq, OUT_TOKENS["implementer"], a.rpm, a.tpm)
        for name, s in (("research", r), ("tests", t), ("build", i)):
            if (project, proxy, name) in measured:
                s["minutes"] = measured[(project, proxy, name)]
                s["measured"] = True
        rows.append({"project": project, "proxy": proxy, "group": group, "tier": (d.get("triage") or {}).get("tier", "?"),
                     "source_files": len(src), "source_tokens": src_t,
                     "research_calls": r["calls"], "research_tokens": r["tokens"], "research_min": r["minutes"],
                     "tester_calls": t["calls"], "tester_tokens": t["tokens"], "tester_min": t["minutes"],
                     "build_calls": i["calls"], "build_tokens": i["tokens"], "build_min": i["minutes"],
                     "total_calls": r["calls"] + t["calls"] + i["calls"], "total_tokens": r["tokens"] + t["tokens"] + i["tokens"],
                     "total_min": round(r["minutes"] + t["minutes"] + i["minutes"], 1),
                     "measured": "yes" if any(s.get("measured") for s in (r, t, i)) else "no"})
    a.out.parent.mkdir(parents=True, exist_ok=True)
    cols = list(rows[0]) if rows else ["project"]
    with a.out.with_name("pi-load-estimate.csv").open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    tc, tt, tm = (sum(r[k] for r in rows) for k in ("total_calls", "total_tokens", "total_min"))
    md = [f"# pi load estimate: {len(rows)} flows", "",
          f"Quota assumed: {a.rpm:g} requests/min, {a.tpm:,.0f} tokens/min (replace with the endpoint owner's numbers: --rpm --tpm).",
          f"Assumptions: {CHARS_PER_TOKEN} characters per token; instructions per call research {BASE['research']:,} / tester {BASE['tester']:,} / build {BASE['implementer']:,} tokens (kit files measured, pi's own {PI_SYSTEM:,} estimated); {SEC_PER_CALL} s per call "
          "without queueing; an agent re-sends its context on every call. Rows marked measured use run times from domain/timings.csv.", "",
          "| Total | Calls | Tokens | Hours (sequential) |", "|---|---|---|---|",
          f"| all flows | {tc:,} | {tt:,} | {tm / 60:.1f} |",
          f"| per flow, average | {tc // max(len(rows), 1):,} | {tt // max(len(rows), 1):,} | {tm / 60 / max(len(rows), 1):.2f} |", "",
          "| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    md += ["| " + " | ".join(f"{r[c]:,}" if isinstance(r[c], int) else str(r[c]) for c in cols) + " |"
           for r in sorted(rows, key=lambda r: -r["total_tokens"])]
    a.out.write_text("\n".join(md) + "\n", encoding="utf-8")
    print(json.dumps({"flows": len(rows), "calls": tc, "tokens": tt, "hours": round(tm / 60, 1), "out": str(a.out)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_BIN_ESTIMATE_PI_LOAD_PY
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
      "$PY" "$REPLAY/tools/osb_log_traces.py" "$WORK/signatures.json" "$EVENTS" -o "$WORK/traces" --already-masked ${SCENARIO_DIMS:+--dims "$SCENARIO_DIMS"}
    else
      say "3 traces from $EVENTS (masking key: ${MASK_KEY:+set}${MASK_KEY:-MISSING})"
      [ -n "${MASK_KEY:-}" ] || { echo "export MASK_KEY=<key held by the data owner> first (or anonymise first: tools/anonymize_logs.py)"; exit 1; }
      # shellcheck disable=SC2086
      "$PY" "$REPLAY/tools/osb_log_traces.py" "$WORK/signatures.json" "$EVENTS" -o "$WORK/traces" ${DELETE_INPUT:+--delete-input} ${EXTRA_MASK_ARGS:-} ${SCENARIO_DIMS:+--dims "$SCENARIO_DIMS"}
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
# Env: MASK_KEY (required), REPLAY (osb-log-replay root), EXAMPLE_LINE (which event is the example; default auto = one signature per kind of line),
#      FLOW (<project>/<proxy> if the line does not name them), SUCCESS_QUEUE / ERROR_QUEUE (stand-in output names),
#      EXTRA_MASK_ARGS (e.g. "--mask-json-key organisationNameArb"),
#      SCENARIO_DIMS (split scenarios by payload fields, e.g. hdr_resource,body:data.businessTransaction), PER_SCENARIO (default 3).
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
"$PY" "$T/anonymize_logs.py" "$EVENTS" -o "$WORK/events.masked.csv" ${EXTRA_MASK_ARGS:-} || { echo "residue found: see $WORK/events.masked.csv.report.json, add --mask-json-key and rerun"; exit 1; }

echo "== 2 signatures from example lines (${EXAMPLE_LINE:-auto})"
"$PY" "$T/signature_from_example.py" "$WORK/events.masked.csv" -o "$WORK/signatures.json" --line "${EXAMPLE_LINE:-0}" ${FLOW:+--flow "$FLOW"}

echo "== 3 traces"
"$PY" "$T/osb_log_traces.py" "$WORK/signatures.json" "$WORK/events.masked.csv" -o "$WORK/traces" --already-masked ${SCENARIO_DIMS:+--dims "$SCENARIO_DIMS"}

echo "== 4 replay-config draft + fixtures"
"$PY" - "$WORK/signatures.json" "$WORK/events.masked.csv" "$WORK/replay-config.json" <<'PY'
import csv, io, json, re, sys
csv.field_size_limit(min(sys.maxsize, 2**31 - 1))
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
echo "== 4b test catalogue"
"$PY" "$HERE/test_catalog.py" "$WORK" || echo "some case folders have problems: see $WORK/TEST_CATALOG.md"
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
mkdir -p "$(dirname "bin/test_catalog.py")"
cat > 'bin/test_catalog.py' <<'KIT_EOF_BIN_TEST_CATALOG_PY'
#!/usr/bin/env python3
"""Test catalogue for one flow, built from the task-1 output (no values from the payloads are written).

    test_catalog.py <task1-dir> [--negative-resource "<resource>"]... [--fanout-peer <proxy>]... [-o TEST_CATALOG.md]

Reads <task1>/traces/scenarios.json, <task1>/fixtures/parity/**, <task1>/replay-config.json and the anonymise report,
checks every test case folder (payload parses, headers carry the correlation id, expected.json complete) and writes:
  TEST_CATALOG.md / test-catalog.csv   one row per test case: id, group, what it proves, input, mocks, expected,
                                       level (L1 Camel mocks / L2 Artemis+WireMock / L3 replay), status
  negative-cases.json                  selector cases ready to merge into replay-config.json once the filter is known
Groups: P parity per logged scenario (real inputs), S selector incl. negatives, F fan-out, E error paths, D delivery.
Stdlib only."""
import argparse
import csv
import json
import re
import sys
from pathlib import Path

LENIENT = json.JSONDecoder(strict=False)


def check_case(case: Path, corr_header: str) -> list[str]:
    problems = []
    for name in ("input.payload", "headers.json", "expected.json"):
        if not (case / name).is_file():
            problems.append(f"missing {name}")
    if problems:
        return problems
    body = (case / "input.payload").read_text(encoding="utf-8").strip()
    if body.startswith("{"):
        try:
            LENIENT.raw_decode(body)
        except ValueError as e:
            problems.append(f"payload does not parse ({getattr(e, 'msg', e)})")
    elif not body.startswith("<"):
        problems.append("payload is neither JSON nor XML")
    headers = json.loads((case / "headers.json").read_text(encoding="utf-8"))
    if not headers.get(corr_header):
        problems.append(f"headers.json without {corr_header}")
    exp = json.loads((case / "expected.json").read_text(encoding="utf-8"))
    for k in ("outcome", "destination", "correlation"):
        if not exp.get(k):
            problems.append(f"expected.json without {k}")
    return problems


def scenario_label(key: str) -> dict:
    parts = key.split("|")
    return {"outcome": parts[1] if len(parts) > 1 else "?",
            **{p.split("=", 1)[0]: p.split("=", 1)[1] for p in parts[2:] if "=" in p}}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("task1", type=Path)
    ap.add_argument("--negative-resource", action="append", default=[], help="resource on the same topic the flow must NOT take")
    ap.add_argument("--fanout-peer", action="append", default=[], help="other proxy that receives the same events")
    ap.add_argument("-o", "--out", type=Path)
    a = ap.parse_args()
    t = a.task1
    scenarios = json.loads((t / "traces/scenarios.json").read_text(encoding="utf-8"))
    cfg = json.loads((t / "replay-config.json").read_text(encoding="utf-8"))
    flow, fc = next(iter(cfg["flows"].items()))
    corr = fc.get("correlation_header", "traceId")
    report = t / "events.masked.csv.report.json"
    payloads = json.loads(report.read_text(encoding="utf-8")).get("payloads", {}) if report.is_file() else {}

    folders = {}
    for sc in sorted((t / "fixtures/parity").glob("*/*/SCENARIO.txt")):
        folders[sc.read_text(encoding="utf-8").strip()] = sc.parent
    rows, broken = [], []
    total = sum(s["count"] for s in scenarios) or 1
    for i, s in enumerate(scenarios, 1):
        lab = scenario_label(s["scenario"])
        folder = folders.get(s["scenario"])
        cases = sorted(p for p in folder.iterdir() if p.is_dir()) if folder else []
        bad = {c.name: check_case(c, corr) for c in cases}
        broken += [f"{folder.name}/{n}: {'; '.join(p)}" for n, p in bad.items() if p]
        golden = all((c / "expected-output.xml").exists() for c in cases) and cases
        what = ", ".join(f"{k}={v}" for k, v in lab.items() if k != "outcome")
        rows.append({"id": f"P{i:02d}", "group": "parity", "proves": f"same result as OSB for {what}",
                     "input": f"{len(cases)} real masked messages ({s['count']} in export, {s['count'] / total:.1%})"
                              + (f" in fixtures/parity/*/{folder.name}" if folder else " (no folder: no payload)"),
                     "mocks": "backends of the flow (from the OSB source)",
                     "expected": f"{lab['outcome']} -> {fc['outputs'][lab['outcome']]['destination']}; body = original XQuery",
                     "level": "L1, L3", "status": "ready" if golden else "inputs ready; expected body after task 2"})
    first_resource = next((scenario_label(s["scenario"]).get("hdr_resource") for s in scenarios), "?")
    rows.append({"id": "S01", "group": "selector", "proves": f"messages for resource '{first_resource}' are consumed",
                 "input": "any P case", "mocks": "-", "expected": "consumed", "level": "L1, L2",
                 "status": "ready (filter itself after task 2)"})
    negatives = []
    for j, r in enumerate(a.negative_resource, 2):
        negatives.append({"name": f"resource '{r}' is filtered out", "headers": {"resource": r}})
        rows.append({"id": f"S{j:02d}", "group": "selector", "proves": f"resource '{r}' is NOT consumed",
                     "input": "headers only (negative-cases.json)", "mocks": "-", "expected": "dropped by the subscription filter",
                     "level": "L2, L3", "status": "needs the selector from task 2"})
    for j, peer in enumerate(a.fanout_peer, 1):
        rows.append({"id": f"F{j:02d}", "group": "fan-out", "proves": f"the same event still reaches '{peer}'",
                     "input": "any P case", "mocks": f"second subscription standing in for {peer}",
                     "expected": "both subscriptions receive one copy", "level": "L2", "status": "ready for L2"})
    trailing = payloads.get("after_masking", {}).get("json-trailing", 0) + payloads.get("after_masking", {}).get("unparsed", 0)
    errors = [
        ("E01", "invalid JSON is routed like OSB routes it", "synthetic broken payload", "error path per OSB error handler"),
        ("E02", f"payloads with text after the JSON ({trailing} in export) are handled like OSB",
         "real masked messages (json-trailing)", "same as OSB: accepted or error"),
        ("E03", "backend timeout", "any P case", "retries / error queue per OSB (.bix + error handler)"),
        ("E04", "backend fault / HTTP 5xx", "any P case", "error queue with errorCode, errorMessage, traceId"),
        ("E05", "message without businessTransaction", "P case with businessTransaction=none, if present", "same as OSB"),
    ]
    for eid, proves, inp, exp in errors:
        rows.append({"id": eid, "group": "error", "proves": proves, "input": inp, "mocks": "WireMock fault / delay",
                     "expected": exp, "level": "L1, L2", "status": "needs the error handler from task 2"})
    rows.append({"id": "D01", "group": "delivery", "proves": "the same message twice gives the same result, once",
                 "input": "any P case sent twice", "mocks": "-", "expected": "per OSB (no dedup known)", "level": "L2",
                 "status": "ready for L2"})

    out = a.out or t / "TEST_CATALOG.md"
    cols = ["id", "group", "proves", "input", "mocks", "expected", "level", "status"]
    with (out.with_name("test-catalog.csv")).open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    (out.with_name("negative-cases.json")).write_text(json.dumps(negatives, indent=2, ensure_ascii=False), encoding="utf-8")
    md = [f"# Test catalogue — {flow}", "",
          f"{len(rows)} test cases: {sum(r['group'] == 'parity' for r in rows)} parity from the logs, the rest from the flow's "
          "contract. Levels: L1 Camel test with mock endpoints (Maven only), L2 real Artemis + WireMock in containers, "
          "L3 replay of the built integration.", "",
          "| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    md += ["| " + " | ".join(re.sub(r"\|", "/", str(r[c])) for c in cols) + " |" for r in rows]
    md += ["", f"Case folders checked: {sum(1 for _ in (t / 'fixtures/parity').glob('*/*/*/expected.json'))}, "
               f"problems: {len(broken)}"] + [f"- {b}" for b in broken[:30]]
    out.write_text("\n".join(md) + "\n", encoding="utf-8")
    print(json.dumps({"flow": flow, "test_cases": len(rows), "parity": sum(r["group"] == "parity" for r in rows),
                      "case_folders_with_problems": len(broken), "out": str(out)}))
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_BIN_TEST_CATALOG_PY
mkdir -p "$(dirname "bin/time_projection.py")"
cat > 'bin/time_projection.py' <<'KIT_EOF_BIN_TIME_PROJECTION_PY'
#!/usr/bin/env python3
"""How long will N flows take? From MEASURED step times, not from estimates. Stdlib only.

    time_projection.py domain/timings.csv [--flows 450] [--coverage domain/coverage.csv] [--parallel 1] [-o TIME_PROJECTION.md]

timings.csv is written by run_domain.sh for every pi step of every flow: seconds in total and seconds spent waiting on
the model endpoint's rate limit (429). Per step (research, tests, build) it takes the median and the 90th percentile of
the successful runs and projects:
  test packs only   research + tests            (what is needed for the functional tests)
  with routes       research + tests + build    (to prove the tests against a Camel K route)
each "as measured" (today's quota) and "without rate-limit waiting" (what a raised quota would give), sequential and
with --parallel runs. The tests step needs pi only where Splunk has no messages; --coverage gives that share.
Prints a warning when fewer than 5 runs of a step were measured: the projection is then a first indication only."""
import argparse
import csv
import json
import statistics
import sys
from pathlib import Path


def pct(xs: list[float], q: float) -> float:
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))] if xs else 0.0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("timings", type=Path)
    ap.add_argument("--flows", type=int, default=450)
    ap.add_argument("--coverage", type=Path)
    ap.add_argument("--parallel", type=int, default=1, help="flows run at the same time (only helps if the quota allows)")
    ap.add_argument("-o", "--out", type=Path, default=Path("domain/TIME_PROJECTION.md"))
    a = ap.parse_args()
    if not a.timings.is_file():
        sys.exit(f"{a.timings} missing: run a domain stage first (research / tests / build write it)")
    runs = {}
    for r in csv.DictReader(a.timings.open(encoding="utf-8")):
        if r.get("exit", "0") != "0":
            continue
        sec, wait = float(r["seconds"]), float(r.get("waited") or 0)
        runs.setdefault(r["stage"], []).append((sec / 60, max(sec - wait, 0) / 60))
    share_synth = 1.0
    if a.coverage and a.coverage.is_file():
        g = [r["group"].split(" ")[0] for r in csv.DictReader(a.coverage.open(encoding="utf-8"))]
        share_synth = sum(x in ("B", "C") for x in g) / max(len(g), 1)
    stats, warn = {}, []
    for st in ("research", "tests", "build"):
        xs = runs.get(st, [])
        if len(xs) < 5:
            warn.append(f"{st}: only {len(xs)} measured runs")
        stats[st] = {"n": len(xs), "median": statistics.median([t for t, _ in xs]) if xs else 0.0,
                     "p90": pct([t for t, _ in xs], 0.9), "median_work": statistics.median([w for _, w in xs]) if xs else 0.0}
    # the tests step is short without pi (real data only); measured runs mix both, so scale by the synthetic share
    def per_flow(key: str, steps: tuple) -> float:
        return sum(stats[s][key] for s in steps)

    rows = []
    for label, steps in (("test packs only (research + tests)", ("research", "tests")),
                         ("with routes (research + tests + build)", ("research", "tests", "build"))):
        for basis, key in (("as measured (today's quota)", "median"), ("90% of flows done within", "p90"),
                           ("without rate-limit waiting", "median_work")):
            m = per_flow(key, steps)
            hours = m * a.flows / 60 / max(a.parallel, 1)
            rows.append({"scope": label, "basis": basis, "min_per_flow": round(m, 1), "hours": round(hours, 1),
                         "days_24h": round(hours / 24, 1), "workdays_8h": round(hours / 8, 1)})
    a.out.parent.mkdir(parents=True, exist_ok=True)
    md = [f"# Time projection: {a.flows} flows", "",
          f"From {sum(s['n'] for s in stats.values())} measured pi steps (successful runs) in {a.timings.name}; "
          f"{a.parallel} flow(s) at a time; share of flows needing synthetic messages: {share_synth:.0%}.", "",
          "| Step | Runs measured | Median min | 90% within min | Median min without waiting |", "|---|---|---|---|---|"]
    md += [f"| {st} | {s['n']} | {s['median']:.1f} | {s['p90']:.1f} | {s['median_work']:.1f} |" for st, s in stats.items()]
    md += ["", "| Scope | Basis | Min per flow | Hours | Days (24 h) | Workdays (8 h) |", "|---|---|---|---|---|---|"]
    md += [f"| {r['scope']} | {r['basis']} | {r['min_per_flow']} | {r['hours']} | {r['days_24h']} | {r['workdays_8h']} |" for r in rows]
    if warn:
        md += ["", "**First indication only:** " + "; ".join(warn) + ". Rerun after more flows have run."]
    md += ["", "Waiting = time the model endpoint refused calls (429) and the runner paused. The difference between the "
               "first and the third basis is what a raised quota would save."]
    a.out.write_text("\n".join(md) + "\n", encoding="utf-8")
    print(json.dumps({"measured_steps": {k: v["n"] for k, v in stats.items()},
                      "hours_tests_only": rows[0]["hours"], "hours_with_routes": rows[3]["hours"], "out": str(a.out)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KIT_EOF_BIN_TIME_PROJECTION_PY
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
mkdir -p "$(dirname "TASKS.md")"
cat > 'TASKS.md' <<'KIT_EOF_TASKS_MD'
# First two tasks on the VDI (one flow, start small)

![workflow](docs/OSB_CamelK_Workflow.png)

Two separate tracks: **A** migrates the OSB code to a Camel K route in YAML DSL (pi implementer), **B** builds the tests and mocks from OSB logs and OSB logic (pi tester). They meet only at verification. Source: `docs/OSB_CamelK_Workflow.drawio`.

Work in a workspace folder, e.g. `~/work/osb-migration`. Tools: `~/Projects/P1` (`git clone git@github.com:PawelWaj/Projects.git ~/Projects`).
Nothing unmasked leaves the VDI. Send only reports and file lists, never CSVs or payloads.

**Start here: [FUNCTIONAL_TESTING.md](FUNCTIONAL_TESTING.md) (approach, mocks, proof, one command per domain).** Step-by-step with the Splunk searches (index `<e2e_index>`): [LOGS_END_TO_END.md](LOGS_END_TO_END.md). All flows in one run: [ALL_FLOWS.md](ALL_FLOWS.md). Source cannot leave the VDI: [RESEARCH_PACK.md](RESEARCH_PACK.md). All proxies of an OSB application, research → Camel K route → green tests: [DOMAIN_RUN.md](DOMAIN_RUN.md). Code generation and comparing skills: [CODEGEN_RUNBOOK.md](CODEGEN_RUNBOOK.md).**

---

## Task 1 — logs only: anonymise, build test cases, replay them through the mocks

**Goal:** prove the data chain and the mock environment on one real flow, before any OSB source or Camel code.
**Input:** a Splunk export of the flow (CSV, columns `_time,_raw`).
**Output:** masked log, test cases, and (with Docker) a replay report.

1. Export from Splunk (2–4 weeks incl. a month-end; one line is enough to start):
   ```
   index=<osb_index> sourcetype=<osb_sourcetype> earliest=-28d@d ("<osb-project>" OR <osb-project-pipeline>*) | sort 0 _time | table _time _raw
   ```
   Save as `work/<flow>/events.csv`.
2. Run:
   ```bash
   export MASK_KEY='<key>'     # private trial: any value; real key: from the data owner
   ~/Projects/P1/vdi-osb-migration/bin/task1_log_only.sh work/<flow>/events.csv work/<flow>/task1
   ```
   It does, in order:
   - **anonymise:** `events.masked.csv` plus a report with no values; must end with `residue findings 0`;
   - **signature from the example line:** stands in for the OSB source;
   - **traces and scenarios:** one scenario per resource type and outcome;
   - **test cases:** `fixtures/parity/<flow>/<scenario>/<traceId>/{input.payload, headers.json, expected.json}`.
3. Check:
   - `task1/events.masked.csv.report.json` → `residue_check.findings` is 0.
   - In `key_inventory`, every key with `masked: false` that could identify a person is added with `--mask-json-key` and the script is rerun (edit `anonymize_logs.py` args in the script, or anonymise by hand first; see RUNBOOK 0a).
   - `task1/traces/scenarios.json` lists the scenarios you expect.
   - `task1/fixtures/**/input.payload` contains no real names or IDs.
4. With Docker/Podman: rerun with `--replay`:
   - It starts Artemis + WireMock + a **stand-in flow** (forwards valid JSON to the success queue) and replays every case.
   - Report: `task1/report/report.json`, one line per case (PASS/FAIL).
   - This proves the mock environment, not the migration.
5. Send back:
   - `events.masked.csv.report.json`
   - `traces/scenarios.json`
   - the fields you added to the masking
   - `report/report.json`, if you ran the replay
   - errors, if any

**Limits of task 1:**
- The signature comes from one example line, not from the OSB source.
- The selector, output queue names and error headers are stand-ins (`_todo` in `replay-config.json`).
- No expected output body yet. That comes from the original XQuery in task 2.

---

## Task 2 — with the OSB source: flow card, real test cases, expected results

**Goal:** the full test basis for the flow, ready for the agent to write the tests and the route.
**Input:**
- the OSB project export from the running OSB (sbconfig `.jar` unzipped, or the JDeveloper project), with shared projects and JARs it uses;
- the **masked** CSV from task 1.

1. Put the export in `osb-src/<project>/`.
2. Preflight:
   ```bash
   bash ~/Projects/P1/vdi-osb-migration/bin/preflight_vdi.sh
   ```
   Fix FAIL lines. Saxon comes from `mvn dependency:get -Dartifact=net.sf.saxon:Saxon-HE:12.9`.
3. Run (the masked file is recognised; no second masking):
   ```bash
   ~/Projects/P1/vdi-osb-migration/bin/start_flow.sh osb-src/<project> <proxy> modules/<proxy> work/<flow>/task1/events.masked.csv
   ```
   - **Inventory and flow card:** `migration/osb-inventory/`, `migration/<proxy>/FLOW_CARD.md`. Every branch, interface and error path is listed, and there's a "referenced but missing" list.
   - **Signatures from the real Log actions:** these replace task 1's example; `work/<proxy>/queries.spl` holds the exact Splunk searches.
   - **Test cases:** `modules/<proxy>/src/test/resources/parity/**`, with `replay-config.json` drafted from the export (real topic, selector, queues; check the `_todo` items).
   - **Expected outputs:** the original XQuery is run on every input, giving `expected-output.xml` and `golden/ORACLE.lock`.
     - A JSON input is reported `oracle-blocked` unless the export contains the nXSD translation.
     - Never hand-write an expected file.
   - **pi analyst:** completes the flow card and stops at **"card not approved"**.
4. Check:
   - "Referenced but missing" in `INVENTORY.md` is empty, or each item has been requested.
   - Every branch on the card has a scenario, or note "no traffic in window".
   - Note how many `oracle-blocked` cases there are.
5. **Do not approve the card yet.** The test and route templates are being switched to Camel K. After that:
   - approve the card;
   - `start_flow.sh … --from pi-test` → tests first, then the Camel K route, gates G1–G10, review.
6. Send back:
   - `FLOW_CARD.md`
   - `INVENTORY.md`
   - `work/<proxy>/traces/coverage.json`
   - `modules/<proxy>/src/test/resources/golden/ORACLE.lock`
   - the preflight output
   - errors, if any

---

## If something stops

| Message | Do |
|---|---|
| `no masking key` | `export MASK_KEY=…` |
| `residue found` | open the report, add the listed field with `--mask-json-key`, rerun |
| `cannot derive the flow id` | `FLOW=<project>/<proxy> bin/task1_log_only.sh …` |
| `internal check failed` (signature) | send the masked example line's structure (no values) to Paweł; try `EXAMPLE_LINE=2` |
| `flow '<name>' not in .../flows` | use the proxy name from `ls migration/osb-inventory/flows` |
| `oracle-blocked` | expected for JSON input without nXSD; the case stays, the body check uses the OSB Test Console later |
| Docker errors in `--replay` | run without `--replay`; the replay can run on a Jenkins agent with Docker |
KIT_EOF_TASKS_MD
mkdir -p "$(dirname "LOGS_END_TO_END.md")"
cat > 'LOGS_END_TO_END.md' <<'KIT_EOF_LOGS_END_TO_END_MD'
# From Splunk logs to test cases — end to end, one flow

Pilot: project `sample-change-prj`, proxy `sample-adjustment`, topic `sampleTopic`.
Other flows: replace the three names. Everything below runs on the VDI. Never send CSVs, payloads or screenshots of them; only the files listed in step 6.

| Where | What you need |
|---|---|
| Splunk | read access to `<e2e_index>` (E2E) — `<dev_index>` (Dev) runs other code, don't use it for test data |
| VDI | Python 3, Git, this repo at `~/Projects` (`git clone git@github.com:PawelWaj/Projects.git ~/Projects`, later `git pull`) |
| Optional | Docker or Podman for the replay (step 5) |

Folders used below: `~/work/osb-migration/work/sample-adjustment/`.

---

## Step 1 — check the flow in Splunk (counts only, 5 minutes)

Paste each block as ONE search. Time picker does not matter: `earliest=` inside the search wins.

**1a. The flow logs payloads, and how many**
```
index=<e2e_index> sourcetype="<osb_sourcetype>" earliest=-28d "sample-change-prj"
| rex "for PS (?<proxy>\S+)"
| eval payload=case(match(_raw, "::\s*\{"), "json", match(_raw, "::\s*<"), "xml", true(), "none")
| stats count by proxy, payload
```
Expect `sample-adjustment | json | ~800`. If `payload=none`: this flow logs no payload → stop, ask for OSB message tracing.

**1b. Events are complete (not cut by Splunk)**
```
index=<e2e_index> sourcetype="<osb_sourcetype>" earliest=-28d "sample-change-prj" "::{"
| eval size=len(_raw), complete=if(match(_raw, "\}\s*$"), "yes", "no")
| stats count max(size) as max_bytes by complete
```
All `complete=yes` and `max_bytes` well below 10000. Otherwise ask the Splunk admin for the sourcetype's `TRUNCATE`.

**1c. Scenarios (what the tests must cover)**
```
index=<e2e_index> sourcetype="<osb_sourcetype>" earliest=-28d "sample-change-prj" "::{"
| dedup _raw
| rex "::(?<payload>\{.*)$"
| spath input=payload path=data.businessTransaction output=business_transaction
| spath input=payload path=data.approvedOrRejected output=decision
| stats count by business_transaction, decision
| sort - count
```
Keep this table: it is the scenario list; step 4 must show the same scenarios.

**1d. Duplicate lines**
```
index=<e2e_index> sourcetype="<osb_sourcetype>" earliest=-7d "for PS sample-adjustment"
| rex "TraceID - (?<trace>[0-9a-fA-F-]{36})"
| eval rawhash=md5(_raw)
| stats count as lines dc(rawhash) as distinct_raw dc(source) as sources by trace
| where lines>1
| stats count by distinct_raw, sources
```
`distinct_raw=1` = the same line stored twice (the export removes it with `dedup _raw`). `distinct_raw=2` = OSB processed the message twice: tell Paweł (redelivery = error-path test).

---

## Step 2 — export (contains personal data: VDI only)

```
index=<e2e_index> sourcetype="<osb_sourcetype>" earliest=-28d@d "sample-change-prj" ("::{" OR "::<")
| dedup _raw
| sort 0 _time
| table _time _raw
```
1. Run it, then **Export** (arrow icon) → format **CSV** → number of results **Unlimited** → file name `events.csv`.
2. Move it to `~/work/osb-migration/work/sample-adjustment/events.csv`.
3. Check: the first line is `"_time","_raw"`, and the row count matches 1a (minus duplicates).
   ```
   head -c 300 ~/work/osb-migration/work/sample-adjustment/events.csv; echo
   python3 -c "import csv,sys; csv.field_size_limit(2**31-1); print(sum(1 for _ in csv.DictReader(open(sys.argv[1], encoding='utf-8-sig'))), 'events')" ~/work/osb-migration/work/sample-adjustment/events.csv
   ```
   If the CSV is too big for the export: run step 2 per week (`earliest=-28d@d latest=-21d@d`, …) and combine (`tail -n +2` for files 2–4).

---

## Step 3 — anonymise and build the test cases (one command)

```
cd ~/work/osb-migration
export MASK_KEY='<key>'     # trial: any value; real runs: the key from the client data owner, never in a file
export SCENARIO_DIMS='hdr_resource,body:data.businessTransaction,body:data.approvedOrRejected'
export PER_SCENARIO=5       # real inputs kept per scenario
~/Projects/P1/vdi-osb-migration/bin/task1_log_only.sh work/sample-adjustment/events.csv work/sample-adjustment/task1
```

What it prints, in order:

| Output line | Meaning | Must be |
|---|---|---|
| `== 1 anonymise … residue findings 0` | names, IDs, birth dates, passport numbers masked; same value → same mask everywhere | `residue findings 0` |
| `== 2 signatures …` then `lines_matched N/N` | the log pattern, learnt automatically: first from a line with valid JSON, then one more pattern per kind of line still unmatched | N/N (all lines match) |
| `== 3 traces … K scenarios` | one trace per message, grouped by resource × businessTransaction × decision | K = rows of 1c |
| `== 4 … fixtures written` + `0 findings` | test cases written; second residue check on the test files | `0 findings` |
| `Scenarios:` list | count per scenario | same as 1c |

---

## Step 4 — check the result

```
cd ~/work/osb-migration/work/sample-adjustment/task1
python3 -c "import json; r=json.load(open('events.masked.csv.report.json')); print('residue', r['residue_check']['findings']); [print(k, v) for k, v in sorted(r['key_inventory'].items()) if not v.get('masked')]"
ls fixtures/parity/*/
```
1. `residue 0`.
2. The printed list = JSON fields NOT masked by name. Numbers with 9+ digits are masked anyway, whatever the field. Any other field that could identify a person (name, short ID, date, address, free text)? Add it and rerun step 3:
   ```
   export EXTRA_MASK_ARGS='--mask-json-key <field1> --mask-json-key <field2>'
   ```
3. One folder per scenario under `fixtures/parity/<flow>/`, each with up to 5 cases: `input.payload` (masked JSON), `headers.json`, `expected.json`.
4. Open ONE `input.payload`: names must read `masked_…`, numbers must differ from the real ones you saw in Splunk.
5. Then delete the raw export: `rm ../events.csv` (rerun from Splunk if ever needed).

---

## Step 4b — test catalogue (what will be tested)

Task 1 already writes `task1/TEST_CATALOG.md` (+ `test-catalog.csv`). For the pilot, add the selector negatives and the fan-out seen in Splunk:
```
python $P1/vdi-osb-migration/bin/test_catalog.py task1 \
  --negative-resource "Other Resource A" --negative-resource "Other Resource B" \
  --negative-resource "Other Resource C" --negative-resource "Other Resource D" \
  --negative-resource "Other Resource E" --fanout-peer peer-flow
```
| Group | Cases | Input from | Expected from |
|---|---|---|---|
| P parity | one per scenario (businessTransaction × decision) | real masked messages (Splunk) | original XQuery (task 2) |
| S selector | consumed / NOT consumed per resource | headers (`negative-cases.json`) | OSB proxy selector (task 2) |
| F fan-out | the other subscriber still gets the event | any P case | — |
| E errors | invalid JSON, text after JSON, backend timeout / fault, missing field | P cases + WireMock faults | OSB error handler (task 2) |
| D delivery | same message twice | any P case | OSB behaviour |

The command also checks every case folder (payload parses, `traceId` header, `expected.json` complete): `case_folders_with_problems` must be 0.

---

## Step 5 — replay through the mocks (optional, needs Docker/Podman)

```
~/Projects/P1/vdi-osb-migration/bin/task1_log_only.sh work/sample-adjustment/events.csv work/sample-adjustment/task1 --replay
```
Starts Artemis + WireMock + a stand-in flow, sends every case, writes `task1/report/report.json` (PASS/FAIL per case). This proves the mock environment and the test cases, not the migration: the stand-in only forwards valid JSON.
Stop afterwards: `cd ~/Projects/P1/osb-log-replay/mock && docker compose down -v`.

---

## Step 6 — send back (no data inside these files)

- table 1a, 1c, 1d (counts)
- `task1/events.masked.csv.report.json` (incl. its `payloads` block: how many payloads are strict JSON, before and after masking)
- `task1/traces/scenarios.json`
- `task1/TEST_CATALOG.md` (no values in it)
- `task1/report/report.json` (if step 5 ran)
- fields you added to the masking
- any error message

---

## Step 7 — with the OSB source (Task 2, next)

Test inputs alone are not a test: the expected output and the mocks come from the OSB code.
1. OSB project `sample-change-prj` from the OSB repository, **the version deployed in E2E**, into `~/work/osb-migration/osb-src/sample-change-prj/`.
2. `bash ~/Projects/P1/vdi-osb-migration/bin/preflight_vdi.sh`
3. Same `MASK_KEY` and `SCENARIO_DIMS` exported, then:
   ```
   ~/Projects/P1/vdi-osb-migration/bin/start_flow.sh osb-src/sample-change-prj sample-adjustment modules/sample-adjustment work/sample-adjustment/task1/events.masked.csv
   ```
   Gives the flow card (selector, branches, backends, error handler), the real replay config, and the expected outputs from the original XQuery. Stops at "card not approved": don't approve yet (templates are being switched to Camel K YAML).

What the logs cannot give (known for this flow): backend responses and error cases — only REQUEST lines are logged. Those come from the OSB source (WSDL/XSD, error handler) until the client enables message tracing in E2E.

---

## If something stops

| Message | Do |
|---|---|
| `export MASK_KEY=<key> first` | `export MASK_KEY=…` |
| `residue found` | open `events.masked.csv.report.json`, add the listed field with `--mask-json-key`, rerun |
| `matches_in_file` 1/N, no `body` in `groups` | payload not recognised: update the repo (fixed 2026-10-14); then send the `payloads` block of the report |
| `lines_matched` below N/N | more than 5 kinds of line in the export; send the `== 2` output (no values in it) |
| warning `payload is json-lenient` / `json-trailing` / `unparsed` | OSB logged JSON that is not strictly valid (raw tabs/newlines, text after `}`, or cut off). Tests still build; send the `payloads` block of the report: Camel's JSON parser must be configured to accept the same input |
| `cannot derive the flow id` | `FLOW=sample-change-prj/sample-adjustment` before the command |
| 1 scenario only | `SCENARIO_DIMS` not exported in this shell |
| `_csv.Error: field larger than field limit` | old repo version: `git pull`, or download the ZIP again (fixed 2026-10-14) |
| Docker errors in step 5 | skip step 5; replay can run on a Jenkins agent with Docker |
KIT_EOF_LOGS_END_TO_END_MD
mkdir -p "$(dirname "ALL_FLOWS.md")"
cat > 'ALL_FLOWS.md' <<'KIT_EOF_ALL_FLOWS_MD'
# All flows at once — from one Splunk export to test cases per flow

Same chain as [LOGS_END_TO_END.md](LOGS_END_TO_END.md), automated for every OSB flow in the export. Nothing to set per domain:
the log pattern, the scenario fields, the selector negatives and the fan-out partners are derived from the data.
VDI only; never send CSVs or payloads. Python 3.10+, works in Git Bash and PowerShell.

## 1 — which flows log payloads (Splunk, counts only)
```
index=<e2e_index> sourcetype="<osb_sourcetype>" earliest=-28d "oracle.osb.logging.pipeline"
| rex "Project (?<project>\S+) :: for PS (?<proxy>\S+)"
| eval payload=case(match(_raw, "::\s*\{"), "json", match(_raw, "::\s*<"), "xml", true(), "none")
| fillnull value="(other log text)" project proxy
| stats count by project, proxy, payload
| sort project, proxy
```
- `json` / `xml`: test inputs available.
- `none`: the flow logs no payload. Splunk gives scenarios and volumes only, so it needs OSB message tracing.
- `(other log text)`: a different Log text. The batch groups these by `[APP: …]`; check them in the summary.

## 2 — one export for all flows
Splunk UI (CSV, Unlimited). This keeps at most 500 messages per proxy, so the file stays manageable:
```
index=<e2e_index> sourcetype="<osb_sourcetype>" earliest=-28d@d "oracle.osb.logging.pipeline" ("::{" OR "::<")
| dedup _raw
| rex "for PS (?<proxy>\S+)"
| dedup 500 proxy
| sort 0 _time
| table _time _raw
```
`dedup 500 proxy` keeps the newest 500 per proxy, so rare scenarios older than those can be missed. For complete coverage drop that line and export per week. One domain only: add its project names, e.g. `("sample-change-prj" OR "peer-prj")`.

Or, with a Splunk REST token (no UI export, same search):
```
export SPLUNK_TOKEN=<token>          # never in a file
python $P1/osb-log-replay/tools/splunk_export.py --url https://<splunk-host>:8089 --earliest -28d@d --latest now \
  --search '<the search above without the table line>' -o all.jsonl
```

## 3 — one command
```
export MASK_KEY='<key>'
python $P1/vdi-osb-migration/bin/batch_task1.py all.csv -o batch          # or all.jsonl
```
Per flow it prints `OK` / `CHECK` / `FAIL` with its scenarios and test cases. Output:

| File | What |
|---|---|
| `batch/SUMMARY.md`, `summary.csv` | one row per flow: events, lines matched, scenarios, test cases, residue, scenario fields, topic, problems |
| `batch/topics.json` | per flow: topic, resources it reads, selector negatives, fan-out partners (names only) |
| `batch/flows-found.csv` | template for step 4 |
| `batch/flows/<flow>/` | same layout as task 1: `fixtures/parity/**`, `TEST_CATALOG.md`, `dims.json`, `replay-config.json` |
| `batch/events.masked.csv.report.json` | masking report for the whole export (no values) |

## 4 — review and adjust (only where needed)
- **CHECK**: read the `problems` column. Typical causes: lines not matched (another log text), or a case folder problem.
- **Scenario fields**: `flows/<flow>/dims.json` shows the chosen fields and the candidates. A field is chosen when it is present in at least 90% of the messages, has 2–25 code-like values, is not masked, and business-code names come first. To change them:
  1. Copy `flows-found.csv` to `flows.csv`.
  2. Edit the `dims` column, e.g. `hdr_resource;body:data.businessTransaction;body:data.personType`.
  3. Rerun with `--flows flows.csv --already-masked`, using `batch/events.masked.csv` as input. This doesn't mask a second time.
- **Domains**: put the domain name in the `domain` column of `flows.csv` (default: the project name). `--flows` also limits the run to the listed flows.
- **Masking**: check `key_inventory` in the masking report; add a field with `--mask-json-key <field>` and rerun from step 3.

## 5 — send back (no data inside)
`SUMMARY.md`, `summary.csv`, `topics.json`, and `flows/*/TEST_CATALOG.md`.

Next per flow: Task 2 (OSB source → expected outputs, selector, backends), as in TASKS.md.
KIT_EOF_ALL_FLOWS_MD
mkdir -p "$(dirname "RESEARCH_PACK.md")"
cat > 'RESEARCH_PACK.md' <<'KIT_EOF_RESEARCH_PACK_MD'
# Research pack — when the OSB source cannot leave the VDI

The OSB source stays on the VDI. pi reads it and writes a **research pack**: facts plus answers to a fixed
questionnaire, in plain language and mapping tables, with **no code, no hosts, no credentials, no data**. A check
blocks the pack until it is clean. Only the pack is sent out; from it the Camel K route and the tests are designed.

## Once
- pi installed and logged in (`P1/skills/osb-camel-agent-kit/pi/PI_SETUP.md`), Python 3, Git Bash.
- Kit: the repo (`~/Projects/P1/skills/osb-camel-agent-kit`) or bootstrap script `8_install_skill_osb_research.sh`.
- Check: `bash $P1/skills/osb-camel-agent-kit/pi/preflight.sh` shows `skill osb-research discoverable`.

## Per proxy (pilot: sample-adjustment)
1. OSB project on the VDI, the version deployed in E2E: `~/work/osb-migration/osb-src/sample-change-prj/`
   (plus shared projects it references).
2. Run, in `~/work/osb-migration`:
   ```
   bash $P1/skills/osb-camel-agent-kit/pi/run_research.sh osb-src/sample-change-prj sample-adjustment /e/Pawel/sample-adjustment/task1
   ```
   The third argument (task 1 output) lets the pack map the 15 Splunk scenarios to branches.
   - `== 1 facts`: script, sanitised inventory of the proxy (`facts.json`, `SOURCES.txt`).
   - `== 2 questionnaire`: pi answers Q1–Q12 (entry, format, flow, branches, scenario mapping, outputs, transforms,
     backends, errors, logging, dependencies, open questions) into `RESEARCH.md` + `research.json`.
   - `== 3 share check`: must end with `PASS`. On `FAIL` the flagged lines are listed (rule + 3-character preview):
     rerun step 2, or fix the lines by hand (describe instead of quoting, remove the value), then
     `python $P1/skills/osb-camel-agent-kit/skills/osb-research/scripts/research_check.py research/sample-adjustment`.
3. Read `RESEARCH.md` yourself once: is anything in it that must not leave? The check is a safety net, not a licence.
4. Send: `research/sample-adjustment/RESEARCH.md`, `research.json`, `facts.json`, `SHARE_CHECK.json`.
   Never send `SOURCES.txt`-listed files, `research/*.agent-logs` (they may quote source) or anything from `osb-src/`.

## What comes back
From the pack: the flow card, the Camel K YAML route (replacing the stand-in block in `P1/pilot/sample-adjustment`),
the selector/branch/error tests, and the WireMock/Artemis mocks. Expected output bodies are still computed ON the VDI
by running the original XQuery on the masked inputs (task 2, `golden_runner.py`); they never leave the VDI either.

## Interactive alternative
In pi: `/osb-research osb-src/sample-change-prj sample-adjustment /e/Pawel/sample-adjustment/task1`
KIT_EOF_RESEARCH_PACK_MD
mkdir -p "$(dirname "DOMAIN_RUN.md")"
cat > 'DOMAIN_RUN.md' <<'KIT_EOF_DOMAIN_RUN_MD'
# One OSB application, all its flows: research → card → Camel K route → green tests

An OSB application (e.g. `osb-application`) holds many projects (`*-prj`), each with one or more proxies.
`pi/run_domain.sh` runs the per-flow steps for every proxy, keeps going when one fails, and keeps a status table.
Everything runs on the VDI. What may leave it: `research/<project>/<proxy>/{RESEARCH.md,research.json,facts.json,SHARE_CHECK.json}`
and `domain/STATUS.md`. Never: the OSB source, `modules/` (it holds the original XQuery and the masked cases), agent logs.

```
KIT=$P1/skills/osb-camel-agent-kit        # or the workspace where the bootstrap scripts were pasted
APP=/e/osb-application       # Git Bash path: /e/..., not E:\...
cd /e/Pawel/work                          # workspace: research/, modules/, domain/ are created here
```

## Local settings, not in Git

Client-specific values (application folder, Splunk index and sourcetype, Maven settings, pi settings) live only on the
machine: copy `pi/osb-kit.env.example` to `~/.osb-kit.env` and fill it in; every runner reads it (values on the command
line win). The repo stays generic. Before a commit, `tools/check_no_client_names.sh --install` adds a hook that blocks
names listed in the local `~/.osb-kit-denylist` (one regex per line, also never in Git).

## Before the first build: Java 21, Maven 3.6.3+, the client Nexus (found on the pilot VDI, 2026-10-15)

The VDI has no internet, a system Maven 3.5.3 and `JAVA_HOME` on JDK 1.7 (kept for OSB/JDeveloper). Per Git Bash window
(or once in `~/.bashrc`):
```
export JAVA_HOME="/c/Program Files/Eclipse Adoptium/jdk-21.0.11.10-hotspot"     # JDK 21 is installed; Maven reads JAVA_HOME, not PATH
export PATH="/e/Pawel/apache-maven-3.9.9/bin:$JAVA_HOME/bin:$PATH"; hash -r
mvn -v                                                                            # Apache Maven 3.9.x, Java 21
```
Maven 3.9.9 comes from the client Nexus (`<nexus>/repository/maven-public/org/apache/maven/apache-maven/3.9.9/apache-maven-3.9.9-bin.zip`,
unzip to `E:\Pawel\`). `~/.m2/settings.xml` = the team's file with the Nexus mirror (`mirrorOf *`); remove its
`<localRepository>` line or point it at your own user. Never commit it. Run Maven with `-s ~/.m2/settings.xml`.

| Message | Cause |
|---|---|
| `Connect to repo.maven.apache.org ... timed out` | no settings.xml with the Nexus mirror (or Maven reads another file: use `-s`, add `-U` once) |
| `try-with-resources is not supported in -source 1.5` | old pom; update (compiler plugin pinned since c122237) |
| `Unsupported major.minor version 52.0` | Maven runs on Java 7: set `JAVA_HOME` to JDK 21 |
| `requires Maven version 3.6.3` / plugin API errors | Maven 3.5.3 on the PATH: put Maven 3.9.9 first, `hash -r` |

| Stage | Command | Who | Result |
|---|---|---|---|
| 0 list | `bash $KIT/pi/run_domain.sh $APP list` | script | every project/proxy found; check the count |
| 0b coverage | `SPLUNK_COVERAGE=<payload table.csv> … coverage` | script | `domain/COVERAGE.md`: per proxy A = real Splunk messages, B = logged without payload, C = not in Splunk; by transport (jms / http / jca) |
| 1 research | `… research` | pi (researcher) | `research/<project>/<proxy>/` per proxy, share check PASS; packs that passed are skipped on rerun |
| 2 task1 | `EXPORT=<domain export.csv> MASK_KEY=… … task1` | script | Splunk test messages per proxy, split by the fields its branches use (`scenario_dims` from step 1) → `task1/flows/<project>-<proxy>/` + `task1/SUMMARY.md` |
| 3 tests | `… tests` | script + pi (tester) | **the functional test pack per flow, no route needed**: generated tests + mocks, real masked Splunk messages, synthetic messages from the schema where Splunk has none, frozen; `TEST_MATRIX.md` catalogue per flow and `domain/TEST_MATRIX.md` (`scaffold` = same without the tester) |
| 4 approve | open each `FLOW_CARD.md`, compare with `RESEARCH.md`, settle the open questions, set `Status: approved`, `Approver:`, `Date:` | **human** | only approved cards are built |
| 5 build | `MVN_ARGS='-s ~/.m2/settings.xml' … build` | pi (implementer) | route implemented, error tests + stubs, `mvn test`, gates K1–K8 → `GATES.json` |
| 6 matrix | `… matrix` | script | route broken on purpose per green flow (`MUTATION.json`), `TEST_MATRIX.md` per flow + `domain/TEST_MATRIX.md` |
| auto | `… auto` | pi + scripts | 1 + 2 + 3 in one go: the functional test pack for every flow. Steps 4–6 (routes) are the next part |
| status | `… status` | script | `domain/STATUS.md`: research / open questions / test cases / card / gates / tests per proxy |

Domain export for step 2 (Splunk, CSV, Unlimited), all projects of the application:
```
index=<e2e_index> sourcetype="<osb_sourcetype>" earliest=-28d@d "oracle.osb.logging.pipeline" ("::{" OR "::<")
| dedup _raw | rex "for PS (?<proxy>\S+)" | dedup 500 proxy | sort 0 _time | table _time _raw
```
Flows that log no payload (groups B and C) get **synthetic** test messages: in `build`, before the route is written, the pi
tester writes one fake-value message per scenario from the message schema; they are frozen like the generated tests
(gate K5) and every scenario must have a case (gate K9). The matrix lists them as S rows, the real ones as P rows.
Request-response proxies (HTTP) are tested on their reply to the caller as well as on the queues.

Payload table for 0b (Splunk, export as CSV): `index=<e2e_index> sourcetype="<osb_sourcetype>" earliest=-28d "oracle.osb.logging.pipeline"
| rex "Project (?<project>\S+) :: for PS (?<proxy>\S+)" | eval payload=case(match(_raw, "::\s*\{"), "json", match(_raw, "::\s*<"), "xml", true(), "none") | stats count by project, proxy, payload`
What was tested and how: [HOW_IT_WORKS.md](HOW_IT_WORKS.md).

Rate limit: the model endpoint answers `429 Too Many Requests` when calls come too fast. The runners wait and retry
(`PI_RETRIES`, default 5; `PI_BACKOFF`, first pause 60 s, doubled) and pause between flows (`PI_PAUSE`, default 30 s;
raise it, e.g. `PI_PAUSE=120`, if 429s keep coming). A pi stage with more than 10 proxies needs `ALL=1`.

Options: `PROJECTS='beneficiary|cancel-'` limits the run to matching project names (start with 2–3 projects).
`TASK1_ROOT=/e/Pawel` uses `/e/Pawel/<proxy>/task1` (the masked Splunk cases) for research and as test inputs.
`MVN_ARGS='-s <client settings.xml>'` for the Nexus mirror. One flow only: `pi/run_research.sh`, `pi/run_camelk.sh`.

## What the gates mean (check_camelk.py)

K1 card approved · K2 no `TODO(flow-card)` left in the route · K3 every branch/output id present · K4 no hosts, ports,
credentials · K5 generated tests unchanged, nothing disabled · K6 a stub per backend whose response is used ·
K7 at least one error test per error scope · K8 `mvn test` green (skipped = expected outputs from the original XQuery
still pending).

## The tests come from the logs, so the logs must carry the branch fields

The generated parity test reads each case's scenario (from task 1) and expects exactly the outputs that
`scenario_mapping` gives for it. If the branches decide on payload fields, task 1 must use those fields as scenario
dims, or no case can be mapped. `research.json` → `scenario_dims` names them. Pilot example:

```
export SCENARIO_DIMS='hdr_resource,body:data.businessTransaction,body:data.hasPartnerEngagement,body:data.hasMainEngagement'
$P1/vdi-osb-migration/bin/task1_log_only.sh events.csv task1      # same MASK_KEY as before
```

## Pilot `sample-adjustment`: what the research showed, what the card must settle

Route: request log → JSON check → two independent checks: `hasPartnerEngagement='true'` → partner queue,
`hasMainEngagement='true'` → main queue (retry 3 × 10 s); none → consumed, nothing sent; any fault → error queue with
the original body and errorCode / errorMessage / debugInfo / traceId. Reference implementation:
`P1/pilot/sample-adjustment`: **2026-10-15 on the VDI with the real masked E2E cases: 254 tests, 0 failures** (124 skipped = no golden body for this flow); 4 route mutations all caught.

Open points for the card (answer on the VDI, send back counts or yes/no only):
1. **Both flags true: one queue or two?** If the two calls are `route` actions in a route node, OSB sends to the first
   only; if they are `publish` actions (or routes in a stage), both fire. Run and send the output (element names only):
   ```
   grep -o '<[A-Za-z0-9]*:\(route-node\|stage\|route\|publish\|ifThenElse\)\b' /e/osb-application/sample-change-prj/Pipeline/sample-adjustment.pipeline | sort | uniq -c
   ```
   And from task 1 rerun with the flag dims: how many messages have both flags true.
2. **errorCode values.** OSB writes its fault code (e.g. a `BEA-...` / `OSB-...` code); Camel writes the exception
   type. Does the error-queue consumer depend on the code? If yes, list the codes it handles.
3. **JSON with text after the closing brace** (3 messages in the export): does OSB's nXSD accept it or send it to the
   error queue? Look up those 3 traceIds in the error queue / error log. The route accepts them today.
4. **Subscription name and queue names on Artemis:** the JNDI names (`jndi.…`) are placeholders until the queue
   register gives the Artemis addresses; the selector becomes the broker filter (L2 test).
KIT_EOF_DOMAIN_RUN_MD
mkdir -p "$(dirname "HOW_IT_WORKS.md")"
cat > 'HOW_IT_WORKS.md' <<'KIT_EOF_HOW_IT_WORKS_MD'
# OSB → Camel K with pi: how it works, what the tests prove, what was tested

Pilot: OSB application `osb-application`, project `sample-change-prj`, proxy
`sample-adjustment`. Status 2026-10-15: **254 tests, 0 failures on the VDI with 751 real masked E2E messages.**

## 1 The chain, and who does what

```mermaid
flowchart LR
  subgraph VDI["Client VDI (nothing below leaves it, except the research pack and reports)"]
    SPL[("Splunk E2E<br/>OSB request logs")] -->|CSV export| T1["task1 / batch_task1.py<br/>mask (HMAC key) · split by flow<br/>scenarios · test cases"]
    OSB[("OSB source<br/>*-prj folders")] --> RP["research_pack.py<br/>facts.json (script)"]
    RP --> PI1["pi agent<br/>skill osb-research<br/>run_research.sh"]
    PI1 --> PACK["research pack<br/>RESEARCH.md · research.json<br/>share check PASS"]
    PACK --> SC["scaffold_camelk.py<br/>route skeleton · FLOW_CARD.md<br/>GENERATED tests"]
    T1 -->|masked real messages| SC
    SC --> AP{{"human approves<br/>FLOW_CARD.md"}}
    AP --> PI2["pi agent<br/>skill osb-camelk-route<br/>run_camelk.sh"]
    PI2 --> MOD["Camel K module<br/>*.camel.yaml + beans<br/>+ error tests"]
    MOD --> MVN["mvn test<br/>(L1, mocks)"]
    MVN --> GATE["check_camelk.py<br/>gates K1–K8"]
    GATE --> MUT["mutate_route.py<br/>route broken on purpose"]
    MUT --> MAT["test_matrix.py<br/>TEST_MATRIX.md"]
  end
  PACK -.->|shareable: no code, hosts, data| NAG["Nagarro review"]
  MAT -.->|counts only| NAG
```

| Step | Tool | Kind | Pilot |
|---|---|---|---|
| Splunk → masked test messages | `task1_log_only.sh` / `batch_task1.py` (domain) | script | 751 messages, 45,331 values masked, residue 0, 29 scenarios |
| OSB source → facts | `research_pack.py` | script | (found and fixed a parser bug: 12c pipeline file not resolved) |
| Facts + source → research pack | **pi** with skill `osb-research`, started by `pi/run_research.sh` | AI agent | PASS, 12 questions answered, 5 open questions |
| Pack → route skeleton, card, **tests** | `scaffold_camelk.py` | script | the parity tests are generated from `research.json`, **not written by an AI** |
| Card approval | a person | human | pending (2 open points) |
| Skeleton → working route + error tests | **pi** with skill `osb-camelk-route`, started by `pi/run_camelk.sh` | AI agent | **pilot route written by Nagarro (Claude) as the reference**; pi does this for the other flows |
| Run, check, prove | `mvn test`, `check_camelk.py`, `mutate_route.py`, `test_matrix.py` | scripts | 254/254, gates PASS (except approval), 9/9 mutations caught |

Why the tests are generated by a script and frozen (gate K5): the agent that writes the route must not also write or
weaken the tests that judge it. The expected results come from the OSB source (research pack) and the inputs from
production-like traffic (Splunk), never from the new Camel code.

Domain, one command per stage: `pi/run_domain.sh <app> auto` (research → task1 → scaffold), approve the cards,
`build`, `matrix`. See [DOMAIN_RUN.md](DOMAIN_RUN.md).

## 2 Are the tests functional? Yes: black-box behaviour of the flow

They do not test Java methods. They send a real message into the route and check what comes out, the way the
consumers of the queues see it.

```mermaid
flowchart LR
  C["case folder<br/>input.payload (real, masked)<br/>headers.json · SCENARIO.txt"] -->|direct:in| R["the Camel K YAML route<br/>(unchanged production file)"]
  R --> P["mock:out-partner-engagement"]
  R --> G["mock:out-sample-adjustment"]
  R --> E["mock:out-…-error-queue"]
  M["flow-test.json<br/>scenario → expected queues<br/>(from research.json)"] --> A{"assert"}
  P --> A
  G --> A
  E --> A
  A -->|"exactly these queues, no others · traceId kept<br/>body = original XQuery result (if any)"| V["PASS / FAIL per message"]
```

| Test level | What runs | Proves | Status |
|---|---|---|---|
| **L1** route + mocks (`mvn test`) — **scope of the VDI work** | YAML route in-process, queues = mock endpoints, no Artemis | branching, outputs, headers, body, error handler, retries, log line | ✅ pilot green |
| L2 Dev environment | route on the Dev cluster + real Artemis | subscription filter (selector), durable subscription, fan-out to the other subscribers, redelivery | next phase, on Dev (not on the VDI) |
| L3 replay | built integration, all 751 messages | volume, ordering, no message lost | after L2 |
| UAT shadow | Camel next to OSB on the same traffic | outputs compared message by message | before cut-over |

## 3 Test matrix: pilot `sample-adjustment` (evidence)

### 3.1 Data and research checks

| ID | Check | Evidence | Result |
|---|---|---|---|
| D1 | Export complete: payload logged per message | Splunk 1a/1b; 1,212 lines → 751 unique (63 runs logged twice = duplicate ingestion, `dedup _raw`) | ✅ |
| D2 | Masking: no personal data left | 45,331 values masked, residue check 0 findings on CSV and on 169 fixture files | ✅ |
| D3 | Payload readable | 748 strict JSON + 3 `{[[ … ]]` (raw log identical to masked: our tools did not cause it) | ✅ explained |
| D4 | Every scenario has test messages | 29 scenarios × up to 5 messages = 119 real cases | ✅ |
| R1 | Research pack shareable | share check PASS (no code, hosts, secrets, personal data) | ✅ |
| R2 | Routing understood from source | two independent flag checks, error handler, retries (Q4, Q8, Q9) | ✅ |
| R3 | Scenarios mapped to outputs | every logged scenario matches a mapping row (0 unmapped) | ✅ |

### 3.2 Functional tests on the real messages (L1, VDI 2026-10-15)

| ID | Messages (flags) | In export | Expected (from OSB source) | Result |
|---|---|---|---|---|
| P-main | `hasMainEngagement=true` only | 596 | main queue only | ✅ all cases pass |
| P-partner | `hasPartnerEngagement=true` only | 45 | partner queue only | ✅ |
| P-BOTH | both flags true | 86 | partner **and** main queue | ✅ (open point O1: confirm OSB sends to both) |
| P-NONE | both flags false | 21 | nothing sent (consumed) | ✅ |
| P-BAD | unreadable `{[[` | 3 | error queue | ✅ (assumption O3) |
| P-ALL | 29 scenarios: 124 cases (119 real + 5 synthetic) × 2 tests + 2 generic | 751 | — | **250 run, 0 failed, 124 skipped** (the skipped = body check: this flow forwards the input unchanged, no XQuery output) |

### 3.3 Error handler and behaviour tests (fake values)

| ID | Test | Result |
|---|---|---|
| E1 | any fault → error queue with the original body + errorCode, errorMessage, debugInfo, traceId, resource, eventType | ✅ |
| E2 | main queue send retried 3× (business service retry-count 3), then error queue | ✅ |
| E3 | partner queue send not retried (retry-count 0) | ✅ |
| E4 | traceId generated when missing (like fn-bea:uuid), body forwarded byte for byte | ✅ |
| E5 | unreadable payload → error queue with traceId | ✅ |

### 3.4 Gates and test strength

| ID | Check | Result |
|---|---|---|
| K1 | card approved by a person | ⏳ pending O1/O2 |
| K2–K7 | no gaps, route ids, no hosts/credentials, generated tests unchanged, stubs, error tests ≥ error scopes | ✅ |
| K8 | `mvn test` green | ✅ 254/254 |
| M1–M9 | route broken on purpose (both conditions negated, 3 wrong-queue swaps, 3 dropped outputs, retry removed): tests must fail | ✅ 9/9 caught (run here on the synthetic cases; on the VDI `run_domain.sh … matrix` repeats it on the real ones) |

### 3.5 Not tested yet (and why)

| ID | Gap | Needs |
|---|---|---|
| O1 | both flags true: does OSB really send to both queues (publish) or only one (route)? 86 messages depend on it | `grep` of the pipeline element names |
| O2 | errorCode values: OSB fault codes vs Camel exception names | who reads the error queue |
| O3 | the 3 `{[[` messages: error queue in OSB too? | one run on the OSB test console |
| L2 | selector `resource='Sample Resource' AND eventType='approved'`, durable subscription, fan-out to `peer-flow` | next phase on the Dev environment |
| B | body equality vs original XQuery | not applicable here (identity); applies to flows with transforms |

## 4 The same for the whole domain

`pi/run_domain.sh /e/osb-application matrix` writes `modules/<project>/<proxy>/TEST_MATRIX.md` per flow
(P/E/K/M rows as above, generated from the reports) and `domain/TEST_MATRIX.md`: one row per flow with scenarios
covered, real messages run and failed, error tests, gates, mutations caught. `domain/STATUS.md` shows where each flow
is: research, open questions, test cases, card, gates, tests.
KIT_EOF_HOW_IT_WORKS_MD
mkdir -p "$(dirname "CODEGEN_RUNBOOK.md")"
cat > 'CODEGEN_RUNBOOK.md' <<'KIT_EOF_CODEGEN_RUNBOOK_MD'
# Runbook: OSB → Camel K code generation with skill `osb-camelk-route`, and a fair comparison with another skill

Skill: [`P1/skills/osb-camel-agent-kit/skills/osb-camelk-route`](../skills/osb-camel-agent-kit/skills/osb-camelk-route/SKILL.md)
(scripts, templates, [YAML patterns](../skills/osb-camel-agent-kit/skills/osb-camelk-route/references/yaml-patterns.md)).
Reference result: [`P1/pilot/sample-adjustment`](../pilot/sample-adjustment/README.md).
Everything runs on the VDI (Git Bash). Scope here: **generating the route code**. How the tests are created:
[HOW_IT_WORKS.md](HOW_IT_WORKS.md), [DOMAIN_RUN.md](DOMAIN_RUN.md).

## 1 What the skill generates, from what

| Input (must exist first) | Made by |
|---|---|
| `research/<project>/<proxy>/research.json` + `RESEARCH.md` | `pi/run_research.sh` (pi reads the OSB source) |
| frozen test pack `modules/<project>/<proxy>/src/test/**` | `pi/run_tests.sh` (generated tests, real + synthetic cases) |
| `modules/<project>/<proxy>/FLOW_CARD.md` with `Status: approved`, `Approver:`, `Date:` | a person |

| Output (code) | What |
|---|---|
| `src/main/resources/routes/<proxy>.camel.yaml` | the Camel K route, YAML DSL, Camel 4.18.4 (= Camel K runtime 3.33.3) |
| `src/main/java/**` | small helper beans (e.g. `OsbJson`: lenient parse, branch fields as headers) |
| `src/main/resources/application.properties` | endpoints as properties, no hosts or credentials |
| `src/test/java/**/FlowErrorTest.java`, `src/test/resources/stubs/*` | error tests and backend stubs written with the route |
| `MIGRATION_NOTES.md` | differences to OSB that could not be avoided |

## 2 Generate the code for one flow

```
export JAVA_HOME="/c/Program Files/Eclipse Adoptium/jdk-21.0.11.10-hotspot"
export PATH="/e/Pawel/apache-maven-3.9.9/bin:$JAVA_HOME/bin:$PATH"; hash -r
export PI_OFFLINE=1 PI_TELEMETRY=0 MVN_ARGS='-s ~/.m2/settings.xml'
KIT=/e/Pawel/Projects-main/P1/skills/osb-camel-agent-kit
cd /e/Pawel/work
P=sample-transform-prj; X=sample-transform                       # project / proxy
# card approved? then:
OSB_SRC=/e/osb-application/$P bash $KIT/pi/run_camelk.sh research/$P/$X modules/$P/$X $P
```
What happens: (1) test pack refreshed, synthetic cases only where missing; (2) stops with exit 3 if the card is not
approved; (3) **pi implementer** (role `agents/implementer-camelk.md`, skill `osb-camelk-route`) fills the route
skeleton, copies the original XQuery/XSLT/XSD from `OSB_SRC` into the module, writes FlowErrorTest and stubs, runs
`mvn test` and the gates until they pass; (4) `mvn test` + `check_camelk.py` again, independently of pi.
Logs: `modules/$P/$X/.agent-logs/` (stay on the VDI). Rate limits are retried automatically (`PI_PAUSE`, `PI_BACKOFF`).

Then prove the tests bite and write the evidence:
```
python $KIT/skills/osb-camelk-route/scripts/mutate_route.py modules/$P/$X --mvn "mvn -B -q $MVN_ARGS"
python $KIT/skills/osb-camelk-route/scripts/test_matrix.py modules/$P/$X
```
Many flows: `PROJECTS='a-prj|b-prj' bash $KIT/pi/run_domain.sh <app> build`, then `… matrix`.

Interactive alternative (same rules): start `pi` in `$KIT`, then `/osb-camelk modules/$P/$X research/$P/$X`.

### Gates the generated code must pass (`check_camelk.py`)

K1 card approved · K2 no `TODO(flow-card)` left · K3 every branch/output/backend id present · K4 no hosts, ports,
credentials · K5 generated tests and frozen cases unchanged, nothing disabled · K6 stub per used backend reply ·
K7 error test per error scope · K8 `mvn test` green · K9 every scenario has a case. Plus the mutation check
(every deliberate defect must fail a test) and the review list in section 4.

## 3 Compare with another code-generation skill

**Principle:** both skills generate code for the **same flows from the same inputs**, and both are judged by the
**same frozen test pack**, which neither of them wrote or may change. Then the numbers are comparable.

### 3.1 Set-up (once per flow)

1. Pick 3 flows of different kinds, e.g. `sample-adjustment` (branches, retries, error queue),
   `sample-transform` (XQuery transform; expected body = what OSB logged), one HTTP request/reply flow.
2. Build the test pack first: `run_domain.sh <app> auto` (or `run_tests.sh` per flow) and approve the cards.
3. Give both skills the same inputs: the OSB source of the project and/or `RESEARCH.md` + `FLOW_CARD.md`. Record which
   inputs each skill used, the model, and the start/end time.
4. Do not show either skill the test pack's case folders (they are the exam). The test classes may be read.

### 3.2 Generate

- **Ours:** section 2 (`run_camelk.sh`), output in `modules/<p>/<x>/src/main/**`.
- **Colleague's skill:** its own command; copy its output (routes `*.yaml` or Java `RouteBuilder` classes, helper
  beans, `application.properties`) into `compare-input/<x>/colleague/`.
- Endpoint contract the tests use: input `{{flow.input}}`, outputs `{{out.<business-service>}}`, backends
  `{{backend.<name>}}` (names in `src/test/resources/flow-test.json`). If the other skill uses its own URIs, write an
  endpoint map instead of changing its code, e.g. `compare-input/<x>/colleague.map`:
  ```
  amqp:queue:jndi.outboundQueue = {{out.sample-transform}}
  amqp:topic:jndi.sampleTopic = {{flow.input}}
  ```

### 3.3 Run the comparison

```
mkdir -p compare-input/$X/ours && cp modules/$P/$X/src/main/resources/routes/*.yaml compare-input/$X/ours/ \
  && cp -r modules/$P/$X/src/main/java compare-input/$X/ours/ 2>/dev/null
python /e/Pawel/Projects-main/P1/vdi-osb-migration/bin/compare_codegen.py modules/$P/$X \
  --candidate ours=compare-input/$X/ours \
  --candidate colleague=compare-input/$X/colleague,map=compare-input/$X/colleague.map \
  --mvn "mvn -B -q $MVN_ARGS" --mutate -o compare/$X
cat compare/$X/COMPARISON.md
```
Each candidate runs in its own copy of the module (`compare/$X/<name>/`, with `mvn.log`, `GATES.json`,
`TEST_MATRIX.md`); the test pack is identical for all. YAML and Java DSL routes are both supported.

### 3.4 Scoring

| Criterion | Measured by | Weight |
|---|---|---|
| Behaves like OSB | parity tests failed (`failed`), scenarios passed (`scenarios_pass`), body checks | decisive |
| Error handling like OSB | `error_tests_failed` (error queue, headers, retries, invalid input) | decisive |
| Tests bite on this code | `mutations_caught` (n/n expected) | high |
| Safe and complete | gates K2, K4–K9 (`gates_K2_K9`) | high |
| Review list (section 4) | a reviewer, per item yes/no | medium |
| Size and readability | `route_lines`, `java_lines`, reviewer note | low |
| Effort | wall time, model calls, manual fixes needed to reach green | medium |

Decide per flow, then over the 3 flows. A skill that needs manual fixes is scored on the first run and on the fixed run.

## 4 Review list for generated code (both skills)

- [ ] OSB log lines kept with the same text and logName `oracle.osb.logging.pipeline` (tests do not check log text)
- [ ] original XQuery/XSLT files used unchanged, not rewritten in Java or YAML
- [ ] every branch, output, retry and error header from the card present; nothing that is not on the card
- [ ] body forwarded unchanged where OSB forwards it
- [ ] endpoints and values only as properties; no hosts, ports or secrets
- [ ] YAML DSL for Camel K (or a stated reason for Java DSL); helper beans small and tested
- [ ] differences to OSB written in MIGRATION_NOTES.md

## 5 What to send back (no code, no data)

`compare/<x>/COMPARISON.md` per flow, the review list per candidate, and the times. Not the modules or the routes:
they contain the original XQuery and stay on the VDI.
KIT_EOF_CODEGEN_RUNBOOK_MD
mkdir -p "$(dirname "FUNCTIONAL_TESTING.md")"
cat > 'FUNCTIONAL_TESTING.md' <<'KIT_EOF_FUNCTIONAL_TESTING_MD'
# Functional testing of OSB flows: the approach, the mocks, the proof, and how to run it for any domain

One page to follow. Details: [HOW_IT_WORKS.md](HOW_IT_WORKS.md) (diagrams), [DOMAIN_RUN.md](DOMAIN_RUN.md) (all stages),
[CODEGEN_RUNBOOK.md](CODEGEN_RUNBOOK.md) (route generation and comparing skills).

## 1 The approach in five sentences

1. **Inputs** come from production: the OSB log lines in Splunk that carry the message, masked inside the client network.
   Flows whose logs carry no message get **synthetic** messages built from their schema, with fake values.
2. **Expected results** come from the OSB source: which queues (or reply) each kind of message must reach, the error
   handling and retries; for the message body, what OSB itself logged on its way out, or the original XQuery.
3. **Mocks**: every queue, topic and backend is replaced by a Camel mock endpoint that records what it receives;
   backend replies come from stub files. No broker, no cluster, no OSB, only Java and Maven.
4. **Tests** are generated by a script and frozen before any route exists; they send each message into the Camel K
   route and check the outputs. The tests also have to catch defects put into the route on purpose.
5. **Proof** is one report per domain: per flow the inputs, expected outputs, mocks, results and caught defects.

```mermaid
flowchart LR
  S[(Splunk)] --> T1[mask + split<br/>script] --> C[test cases<br/>real]
  O[(OSB source)] --> R[research<br/>pi] --> P[research pack]
  P --> G[generate tests + mocks<br/>script]
  C --> G
  G --> SY[synthetic cases<br/>pi tester, only if needed]
  SY --> F[frozen test pack]
  G --> F
  F --> B[Camel K route<br/>pi implementer]
  B --> M[mvn test + checks<br/>+ mutations<br/>scripts]
  M --> REP[FUNCTIONAL_TEST_REPORT.md<br/>script]
```

## 2 Where pi is used, and where not

| Step | Who | Why |
|---|---|---|
| research: read the OSB source, answer 12 questions | **pi** | every flow is written differently; reading XML pipelines, XQuery and schemas needs judgement |
| synthetic messages for scenarios Splunk cannot supply | **pi** (tester), only when needed | building a valid message from an XSD/nXSD/WSDL with fake values |
| Camel K route that the tests run against | **pi** (implementer) | writing code; needed to prove the tests (and for the migration itself) |
| masking, splitting, scenarios, expected outputs, test classes, mocks | script | deterministic; the same input always gives the same tests |
| running the tests, checks K1–K9, mutation check | script + Maven | the judge must not be an AI |
| reports (STATUS, TEST_MATRIX, COVERAGE, FUNCTIONAL_TEST_REPORT) | script | counts from the files, reproducible |

pi never writes or changes a test, an expected result or a report.

## 3 What is mocked, and how

| OSB element | In the test |
|---|---|
| inbound queue / topic subscription | `direct:in`; the subscription filter itself is tested later with a real broker (Dev environment) |
| outbound queue / topic (business service) | `mock:out-<business-service>`: receives exactly the expected messages, none for other scenarios |
| HTTP / SOAP backend whose reply is used | `mock:backend-<name>` answering with `stubs/<name>.json|xml` (shape from the schema, fake values) |
| reply to the caller (HTTP proxies) | the exchange's reply, checked like an output |
| error queue | `mock:out-<error-service>`: original message + error headers |
| backend down / timeout | the mock throws; retries are counted |

## 4 What counts as proof (per flow)

| # | Proof | Shown in the report as |
|---|---|---|
| 1 | inputs exist for every scenario | `real_cases`, `synthetic_cases`, gap "no test cases" |
| 2 | expected outputs come from OSB, not from the new code | `scenarios`, `body_oracle` |
| 3 | every output and backend is mocked | `mocked_outputs`, `reply` |
| 4 | the Camel K route passes every test | `tests`, `failed` |
| 5 | the tests catch deliberate defects | `mutations` (n/n) |

A flow is **proven** when 4 is green and 5 is n/n. Card approval by a person (gate K1) is required for production;
a proof-of-concept run (`POC=1`) builds without it and marks the card `poc-run (NOT approved)`.

## 5 Run it for a domain (any OSB application)

Once per workspace: put the two Splunk exports there (`splunk-payload.csv`, `domain-export.csv`, see
[DOMAIN_RUN.md](DOMAIN_RUN.md) step 2), then let the kit write the local settings (`.osb-kit.env`, ignored by Git):
```
cd /e/Pawel/work
bash <kit>/pi/init_env.sh <osb-application-folder>     # finds JDK 21, Maven, the kit; check the printed values
```
Every session:
```
cd /e/Pawel/work && . ./.osb-kit.env
export MASK_KEY='<from the data owner>'
bash $KIT/pi/run_domain.sh list            # all flows -> domain/projects.txt, domain/flows.txt
bash $KIT/pi/run_domain.sh coverage        # which flows get real inputs
bash $KIT/pi/run_domain.sh batches         # the domain cut into batches of 10 projects, one command each
BATCH_NO=1 bash $KIT/pi/run_domain.sh functional
BATCH_NO=2 bash $KIT/pi/run_domain.sh functional      # ... up to the last batch, or ALL=1 for everything at once
bash $KIT/pi/run_domain.sh report          # the domain report over everything done so far
```
No project names to type: `list` and `batches` take them from the application folder. `functional` = research →
task1 → tests → build → matrix → report; restartable, one failing flow never stops the others. Result:
`domain/FUNCTIONAL_TEST_REPORT.md` (+ `STATUS.md`, `TEST_MATRIX.md`, `COVERAGE.md`). Only these reports and
`research/*/*` packs that passed the check may leave the VDI.

If a stage stops: masking residue → add the field with `MASK_JSON_KEYS='field'`; `429` → raise `PI_PAUSE`;
`FAILED research` → `research/<p>/<x>/agent-logs/research.err`; tests red → `modules/<p>/<x>/target/surefire-reports`.

## 6 Known limits (and their next step)

- Selector, durable subscription, fan-out and transactions need a real broker: next phase on the Dev environment.
- Flows that transform the body but log neither input nor output (or JSON input with an nXSD translation) have no body
  oracle yet: the report shows `XQuery: expected body pending`; next step is running the original XQuery on the input.
- Log text is not asserted by the tests; it is on the review list (CODEGEN_RUNBOOK.md section 4).
KIT_EOF_FUNCTIONAL_TESTING_MD
chmod +x bin/*.sh bin/*.py 2>/dev/null || true
echo "next: bash bin/preflight_vdi.sh, then read RUNBOOK.md"
echo "installed: 20 files (VDI workflow)"
