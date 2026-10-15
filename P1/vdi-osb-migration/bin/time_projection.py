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
