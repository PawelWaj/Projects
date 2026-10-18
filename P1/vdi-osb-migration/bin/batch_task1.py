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
    # a scenario field found in NO message means the research named the wrong path: every case would be labelled
    # '?', no scenario row would match, and the route's helper bean would read the same wrong path
    tj = d / "traces/traces.jsonl"
    if tj.is_file():
        seen = Counter()
        n = 0
        for ln in tj.read_text(encoding="utf-8").splitlines():
            try:
                br = json.loads(ln).get("branch") or {}
            except ValueError:
                continue
            n += 1
            for k, v in br.items():
                if v not in ("", "?", None):
                    seen[k] += 1
        missing = [k for k in dims if not k.startswith("hdr_") and n and seen[k.split(":")[-1].split(".")[-1]] == 0 and seen[k] == 0]
        if missing:
            row["problems"].append(f"scenario field {', '.join(missing)} found in none of {n} messages: check scenario_dims in "
                                   "research.json (wrong path?) before building tests")
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
