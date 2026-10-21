#!/usr/bin/env python3
r"""Which flows of one OSB application have ENOUGH logged messages in Splunk for functional tests from real data, and
which need synthetic ones. Stdlib only. Names and counts only, the output is shareable.

    domain_coverage.py <inventory-dir> <splunk-readiness.csv> [-o domain/COVERAGE.md]
                       [--ready-min 30] [--ready-days 5] [--thin-min 5]

inventory-dir         output of osb_inventory.py on the application (flows/*.json)
splunk-readiness.csv  the Splunk table below, exported as CSV (counts only). The older table
                      "stats count by project, proxy, payload" is still accepted (no days / distinct columns).

    index=<e2e_index> sourcetype="<osb_sourcetype>" earliest=-90d@d "oracle.osb.logging.pipeline" "for PS"
    | rex "Project (?<project>\S+) :: for PS (?<proxy>\S+)" | where isnotnull(proxy)
    | rex "(?s)TraceID\s*[-:]\s*\S+\s*::(?<body>.*)$"
    | eval payload=case(match(_raw,"::\s*\{\s*\""),"json", match(_raw,"::\s*<[A-Za-z]"),"xml", isnull(body),"none",
        match(body,"^\s*$"),"empty", match(body,"&lt;|&quot;"),"escaped", true(),"glued")
    | eval h=if(in(payload,"json","xml"), md5(body), null()), day=strftime(_time,"%F")
    | stats count dc(day) as days dc(h) as distinct by project, proxy, payload

payload: json / xml = the request is logged and usable; escaped = logged XML/JSON with entities (may be usable, check);
glued = values without structure (Log action concat of $body without fn-bea:serialize); empty / none = no message.

Groups (what Splunk has):    A real inputs | B logged without payload | C not in Splunk (no PS line in the window)
Verdict (what to do next):
  READY      >= ready-min distinct real messages on >= ready-days days: functional tests from Splunk, like the pilots
             (export, task1, review). The pilots had 37 and 47 messages in 90 days.
  THIN       >= thin-min distinct real messages: real cases where they exist, synthetic for the other scenarios
  SYNTHETIC  fewer, or no payload, or not in Splunk: synthetic messages from the schema (synth_from_schema.py)
The thresholds are a starting point, not calibrated; task1 (TEST_CATALOG, K9 uncovered) is the per-scenario truth.
Writes COVERAGE.md + coverage.csv."""
import argparse
import csv
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

REAL = ("json", "xml")
NO_PAYLOAD = ("none", "empty", "glued", "escaped")


def read_splunk(path: Path):
    """(project, proxy) -> {payload: {count, days, distinct}} from the Splunk CSV (old or new columns)."""
    logs = defaultdict(lambda: defaultdict(Counter))
    with path.open(encoding="utf-8-sig") as fh:
        sample = fh.read(2048)
        fh.seek(0)
        dialect = csv.Sniffer().sniff(sample, delimiters=",;\t")
        for r in csv.DictReader(fh, dialect=dialect):
            r = {k.strip().lower(): (v or "").strip() for k, v in r.items() if k}
            if not r.get("proxy"):
                continue
            c = logs[(r.get("project", ""), r["proxy"])][r.get("payload") or "none"]
            for col in ("count", "days", "distinct"):
                if col not in r:
                    continue
                try:
                    c[col] += int(float(r.get(col) or 0))
                except ValueError:
                    pass
    return logs


def verdict(real: int, days: int, distinct: int | None, kinds: Counter, a) -> tuple[str, str]:
    """READY / THIN / SYNTHETIC and the reason in a few words. distinct None = old CSV without that column."""
    n = real if distinct is None else distinct
    if n >= a.ready_min and (days == 0 or days >= a.ready_days):
        return "READY", f"{n} distinct real messages" + (f" on {days} days" if days else "")
    if n >= a.thin_min:
        why = f"{n} distinct real messages" if n < a.ready_min else f"only {days} days"
        return "THIN", why
    if real:
        return "SYNTHETIC", f"only {n} distinct real message(s)"
    if kinds.get("glued"):
        return "SYNTHETIC", "request logged as glued text (Log action without serialize)"
    if kinds.get("escaped"):
        return "SYNTHETIC", "request logged escaped: check, may be usable"
    if sum(kinds.values()):
        return "SYNTHETIC", "request line without message"
    return "SYNTHETIC", "no request line in Splunk"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inventory", type=Path)
    ap.add_argument("splunk", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=Path("domain/COVERAGE.md"))
    ap.add_argument("--ready-min", type=int, default=30, help="distinct real messages for READY")
    ap.add_argument("--ready-days", type=int, default=5, help="days with traffic for READY")
    ap.add_argument("--thin-min", type=int, default=5, help="distinct real messages for THIN")
    a = ap.parse_args()
    logs = read_splunk(a.splunk)
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
        c = logs.get((project, proxy)) or (by_proxy[proxy][0][1] if len(by_proxy.get(proxy, [])) == 1 else None) or {}
        real = sum(c[k]["count"] for k in REAL if k in c)
        has_distinct = any("distinct" in c[k] for k in REAL if k in c)
        distinct = sum(c[k]["distinct"] for k in REAL if k in c) if has_distinct else None
        days = max([c[k]["days"] for k in c] or [0])
        kinds = Counter({k: c[k]["count"] for k in c if k not in REAL})
        without = sum(kinds.values())
        group = "A real inputs" if real else ("B no payload" if without else "C not in Splunk")
        v, why = verdict(real, days, distinct, kinds, a)
        rows.append({"project": project, "proxy": proxy, "transport": d["proxy"].get("transport") or "?",
                     "tier": (d.get("triage") or {}).get("tier", "?"), "score": (d.get("triage") or {}).get("score", ""),
                     "missing_refs": len(d.get("missing_refs") or []),
                     "logged_with_payload": real, "distinct": "" if distinct is None else distinct, "days": days,
                     "logged_without_payload": without, "without_kind": ",".join(sorted(kinds)) or "",
                     "group": group, "verdict": v, "why": why})
    a.out.parent.mkdir(parents=True, exist_ok=True)
    cols = list(rows[0]) if rows else ["project"]
    with a.out.with_name("coverage.csv").open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    grp = Counter(r["group"] for r in rows)
    ver = Counter(r["verdict"] for r in rows)
    cross = Counter((r["group"], r["transport"]) for r in rows)
    transports = sorted({r["transport"] for r in rows})
    order = {"READY": 0, "THIN": 1, "SYNTHETIC": 2}
    md = [f"# Test-input coverage: {len(rows)} proxies", "",
          f"Verdict: READY {ver['READY']} (functional tests from Splunk, like the pilots), THIN {ver['THIN']} (real cases "
          f"plus synthetic), SYNTHETIC {ver['SYNTHETIC']} (messages from the schema). Thresholds: READY >= {a.ready_min} "
          f"distinct real messages on >= {a.ready_days} days, THIN >= {a.thin_min} (uncalibrated; task1 decides per scenario).", "",
          "A = payload logged in Splunk, B = logged without payload, C = not in Splunk.", "",
          "| Group | " + " | ".join(transports) + " | Total |", "|---|" + "---|" * (len(transports) + 1)]
    for g in sorted(grp):
        md.append(f"| {g} | " + " | ".join(str(cross[(g, t)]) for t in transports) + f" | {grp[g]} |")
    md += ["", "| Verdict | Project | Proxy | Transport | Tier (score) | Real msgs | Distinct | Days | Without payload | Group | Why |",
           "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: (order[r["verdict"]], -(r["logged_with_payload"] or 0), -(r["logged_without_payload"] or 0), r["project"], r["proxy"])):
        wk = f" ({r['without_kind']})" if r["without_kind"] else ""
        md.append(f"| {r['verdict']} | {r['project']} | {r['proxy']} | {r['transport']} | {r['tier']} ({r['score']}) | "
                  f"{r['logged_with_payload']} | {r['distinct'] if r['distinct'] != '' else '-'} | {r['days'] or '-'} | "
                  f"{r['logged_without_payload']}{wk} | {r['group']} | {r['why']} |")
    ready = sorted({r["project"] for r in rows if r["verdict"] in ("READY", "THIN")})
    if ready:
        md += ["", "## Next: export for the READY and THIN projects (Splunk, CSV, stays on the VDI, masked by task1)", "", "```",
               '<same index/sourcetype> earliest=-90d@d (' + " OR ".join(f'"{p}"' for p in ready) + ') ("::{" OR "::<")',
               "| dedup _raw | sort 0 _time | head 20000 | table _time _raw", "```",
               "", f"then: PROJECTS='{'|'.join(ready)}' with EXPORT + MASK_KEY -> vdi_session.sh flows"]
    a.out.write_text("\n".join(md) + "\n", encoding="utf-8")
    print(json.dumps({"proxies": len(rows), **{k: v for k, v in sorted(grp.items())}, **dict(sorted(ver.items())), "out": str(a.out)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
