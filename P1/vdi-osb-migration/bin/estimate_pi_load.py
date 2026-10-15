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
