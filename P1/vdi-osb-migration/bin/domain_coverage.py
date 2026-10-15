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
