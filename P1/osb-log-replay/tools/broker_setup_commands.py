#!/usr/bin/env python3
"""Print the Artemis CLI commands that create the mock broker's addresses and queues from replay-config.json:
the input multicast address, the named durable subscription queue with the proxy's selector as its filter, and the
anycast output queues. mock/setup_broker.sh runs them inside the broker container.

Usage: broker_setup_commands.py replay-config.json [--cli /var/lib/artemis-instance/bin/artemis]
"""
from __future__ import annotations

import argparse
import json
import shlex
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("config", type=Path)
    ap.add_argument("--cli", default="/var/lib/artemis-instance/bin/artemis")
    args = ap.parse_args()
    cfg = json.loads(args.config.read_text(encoding="utf-8"))
    auth = '--user "$ARTEMIS_USER" --password "$ARTEMIS_PASSWORD" --silent'
    seen = set()
    for flow, fc in cfg["flows"].items():
        inp = fc["input"]
        if inp["address"] not in seen:
            seen.add(inp["address"])
            print(f"{args.cli} address create --name {shlex.quote(inp['address'])} --multicast --no-anycast {auth}")
        if inp.get("subscription"):
            filt = f" --filter {shlex.quote(inp['filter'])}" if inp.get("filter") else ""
            print(f"{args.cli} queue create --name {shlex.quote(inp['subscription'])} --address {shlex.quote(inp['address'])} "
                  f"--multicast --durable --preserve-on-no-consumers{filt} {auth}")
        for out in fc["outputs"].values():
            if out["destination"] in seen:
                continue
            seen.add(out["destination"])
            print(f"{args.cli} queue create --name {shlex.quote(out['destination'])} --address {shlex.quote(out['destination'])} "
                  f"--anycast --durable --preserve-on-no-consumers --auto-create-address {auth}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
