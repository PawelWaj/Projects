#!/usr/bin/env python3
"""Step 2b: export raw OSB events from Splunk through the REST export endpoint (JSON lines).

The token comes from the environment (SPLUNK_TOKEN), never from a file in the repository. Only _raw and _time are kept.
Alternative without API access: run the search in the Splunk UI and export CSV (keep the _raw column);
osb_log_traces.py reads both formats.

Usage:
  SPLUNK_TOKEN=... splunk_export.py --url https://splunk.example:8089 --search 'index=osb sourcetype=... "anchor"' \
      --earliest -30d --latest now -o events.jsonl [--insecure]
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.parse
import urllib.request
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True, help="Splunk management URL, usually port 8089")
    ap.add_argument("--search", required=True)
    ap.add_argument("--earliest", default="-7d")
    ap.add_argument("--latest", default="now")
    ap.add_argument("--max", type=int, default=0, help="stop after this many events (0 = no limit)")
    ap.add_argument("-o", "--out", type=Path, default=Path("events.jsonl"))
    ap.add_argument("--insecure", action="store_true", help="skip TLS verification (test instances only)")
    args = ap.parse_args()
    token = os.environ.get("SPLUNK_TOKEN")
    if not token:
        print("SPLUNK_TOKEN is not set", file=sys.stderr)
        return 2
    search = args.search if args.search.lstrip().startswith(("search ", "|")) else "search " + args.search
    data = urllib.parse.urlencode({"search": search, "earliest_time": args.earliest, "latest_time": args.latest,
                                   "output_mode": "json"}).encode()
    req = urllib.request.Request(args.url.rstrip("/") + "/services/search/jobs/export", data=data,
                                 headers={"Authorization": f"Bearer {token}"})
    ctx = ssl._create_unverified_context() if args.insecure else ssl.create_default_context()
    n = 0
    with urllib.request.urlopen(req, context=ctx, timeout=600) as resp, args.out.open("w", encoding="utf-8") as fh:
        for raw in resp:
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            obj = json.loads(line)
            res = obj.get("result")
            if not res or "_raw" not in res:
                continue
            fh.write(json.dumps({"result": {"_raw": res["_raw"], "_time": res.get("_time")}}, ensure_ascii=False) + "\n")
            n += 1
            if args.max and n >= args.max:
                break
    print(f"{n} events -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
