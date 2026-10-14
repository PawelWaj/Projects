#!/usr/bin/env python3
"""Step 4: pick representative traces per scenario and write test fixtures.

For each scenario, up to N traces with a payload are written as one fixture each:
  <out>/parity/<flow>/<scenario-slug>/<correlation>/input.payload   the logged request body (masked)
  <out>/parity/<flow>/<scenario-slug>/<correlation>/headers.json    JMS/HTTP headers reconstructed from the log fields
  <out>/parity/<flow>/<scenario-slug>/<correlation>/expected.json   outcome, destination, fault code, business keys
and every file is registered in <out>/golden/MANIFEST.csv with source 'osb-recording', which is what gate G7 of the
agent kit accepts. The expected OUTPUT body is not in the logs: produce it with the original XQuery (golden test,
source 'original-transform'), never with the new Camel code.

Usage: fixtures_from_traces.py traces.jsonl replay-config.json -o fixtures/ [--per-scenario 3]
"""
from __future__ import annotations

import argparse
import csv
import datetime
import hashlib
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))


def slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-").lower()[:80]


def scenario_dir(t: dict) -> str:
    """Readable scenario folder: outcome + branch VALUES only ('none' when absent); a hash keeps cut names unique."""
    vals = [t["outcome"]] + [v if v not in ("", "?") else "none" for v in t["branch"].values()]
    if t.get("fault_code"):
        vals.append("err-" + str(t["fault_code"]))
    name = re.sub(r"[^A-Za-z0-9]+", "-", "_".join(vals)).strip("-").lower()
    return name if len(name) <= 80 else name[:71] + "-" + hashlib.sha1(t["scenario"].encode()).hexdigest()[:8]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("traces", type=Path)
    ap.add_argument("config", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=Path("fixtures"))
    ap.add_argument("--per-scenario", type=int, default=3)
    ap.add_argument("--captured-by", default="osb-log-replay")
    args = ap.parse_args()

    cfg = json.loads(args.config.read_text(encoding="utf-8"))
    flows_cfg = cfg["flows"]
    by_scen = defaultdict(list)
    for line in args.traces.read_text(encoding="utf-8").splitlines():
        if line.strip():
            t = json.loads(line)
            by_scen[t["scenario"]].append(t)

    manifest_path = args.out / "golden" / "MANIFEST.csv"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    cols = ["file", "source", "flow", "captured_by", "date", "sha256", "key_id", "source_ref", "reason", "approved_by"]
    rows = []
    if manifest_path.exists():                      # rewrite, never append: re-runs replace this flow's rows
        with manifest_path.open(encoding="utf-8", newline="") as mf:
            rows = [r for r in csv.DictReader(mf)]
    cov_path = args.traces.with_name("coverage.json")
    key_id, source_ref = "", args.traces.name
    if cov_path.is_file():
        cov = json.loads(cov_path.read_text(encoding="utf-8"))
        key_id = cov.get("masking", {}).get("key_id", "")
        source_ref = f"{args.traces.name}; events {cov.get('events_read')}; signatures {len(cov.get('signatures_seen', {}) or {})}"
    written, skipped, flows_written = 0, [], set()
    today = datetime.date.today().isoformat()
    if True:
        def w_row(path, flow):
            rows.append({"file": path.relative_to(args.out).as_posix(), "source": "osb-recording", "flow": flow,
                         "captured_by": args.captured_by, "date": today,
                         "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "key_id": key_id,
                         "source_ref": source_ref, "reason": "", "approved_by": ""})
        for scen, traces in sorted(by_scen.items()):
            flow = traces[0]["flow"]
            fc = flows_cfg.get(flow)
            if not fc:
                skipped.append(f"{scen}: flow not in config")
                continue
            usable = [t for t in traces if t["has_payload"]]
            if not usable:
                skipped.append(f"{scen}: no trace with a payload (debug logging off?)")
                continue
            for t in usable[: args.per_scenario]:
                merged = {}
                for e in t["events"]:
                    for k, v in e["fields"].items():
                        merged.setdefault(k, v)
                d = args.out / "parity" / slug(flow) / scenario_dir(t) / slug(t["correlation"])
                d.mkdir(parents=True, exist_ok=True)
                (d.parent / "SCENARIO.txt").write_text(scen + "\n", encoding="utf-8")
                headers = {k[4:]: v for k, v in merged.items() if k.startswith("hdr_")}
                headers[fc.get("correlation_header", "traceId")] = t["correlation"]
                out_cfg = fc["outputs"][t["outcome"]]
                expected = {"outcome": t["outcome"], "destination": out_cfg["destination"],
                            "destination_type": out_cfg.get("type", "anycast"), "correlation": t["correlation"],
                            "fault_code": t["fault_code"],
                            "business_keys": {k: v for k, v in merged.items() if k.startswith("body_")},
                            "expected_headers": out_cfg.get("expect_headers", []),
                            "body_oracle": "original XQuery on input.payload (golden test), not the logs"}
                files = {"input.payload": merged["body"], "headers.json": json.dumps(headers, indent=2, ensure_ascii=False),
                         "expected.json": json.dumps(expected, indent=2, ensure_ascii=False)}
                if flow not in flows_written:
                    rows = [r for r in rows if r.get("flow") != flow]
                    flows_written.add(flow)
                for name, content in files.items():
                    (d / name).write_text(content, encoding="utf-8")
                    w_row(d / name, flow)
                written += 1
    with manifest_path.open("w", newline="", encoding="utf-8") as mf:
        w = csv.DictWriter(mf, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({c: r.get(c, "") for c in cols})
    print(f"{written} fixtures written to {args.out}/parity; manifest {manifest_path} ({len(rows)} rows, key_id {key_id or 'n/a'})")
    for s in skipped:
        print("SKIPPED", s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
