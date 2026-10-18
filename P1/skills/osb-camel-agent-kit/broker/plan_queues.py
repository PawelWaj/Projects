#!/usr/bin/env python3
"""The broker objects ONE flow needs on a local Artemis, derived from <module>/env/local.properties. Stdlib only.

    plan_queues.py <module> [--tsv]

  flow.input=amqp:queue:<address>::<subscription>           -> multicast queue <subscription> on <address>
  flow.input=amqp:topic:<address>?...subscriptionName=<s>   -> the same (JMS durable subscription)
  flow.input=amqp:queue:<queue>                              -> anycast queue
  flow.input.selector=<text>                                 -> filter of that subscription queue (the OSB message selector)
  out.* / backend.* = amqp:queue:<queue>                     -> anycast queue;   amqp:topic:<address> -> multicast address
Prints a JSON list of {name, address, routing (multicast|anycast|address), filter}; --tsv prints one line per object
(name, address, routing, filter) for the shell. HTTP backends and non-AMQP values are ignored."""
import argparse
import json
import re
import sys
from pathlib import Path


def plan(props: dict) -> list[dict]:
    out, seen = [], set()

    def add(o: dict):
        if o["name"] not in seen:
            seen.add(o["name"])
            out.append(o)

    sel = props.get("flow.input.selector", "").strip() or None
    for k, v in props.items():
        if not v.startswith("amqp:"):
            continue
        m = re.match(r"amqp:(queue|topic):([^?]+)(?:\?(.*))?$", v)
        if not m:
            continue
        kind, name, query = m.group(1), m.group(2), m.group(3) or ""
        if k == "flow.input":
            if "::" in name:
                addr, sub = name.split("::", 1)
                add({"name": sub, "address": addr, "routing": "multicast", "filter": sel})
            elif kind == "topic":
                q = dict(p.split("=", 1) for p in query.split("&") if "=" in p)
                sub = q.get("subscriptionName") or q.get("durableSubscriptionName")
                if sub:
                    add({"name": sub, "address": name, "routing": "multicast", "filter": sel})
                else:
                    add({"name": name, "address": name, "routing": "address", "filter": None})
            else:
                add({"name": name, "address": name, "routing": "anycast", "filter": None})
        elif k.startswith(("out.", "backend.")):
            if kind == "topic":
                add({"name": name, "address": name, "routing": "address", "filter": None})
            else:
                add({"name": name, "address": name, "routing": "anycast", "filter": None})
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--tsv", action="store_true")
    a = ap.parse_args()
    f = a.module / "env/local.properties"
    if not f.is_file():
        sys.exit(f"missing {f}")
    props = {}
    for ln in f.read_text(encoding="utf-8").splitlines():
        if ln.strip() and not ln.lstrip().startswith(("#", "!")) and "=" in ln:
            k, v = ln.split("=", 1)
            props[k.strip()] = v.strip()
    objs = plan(props)
    if a.tsv:
        for o in objs:
            print("\t".join([o["name"], o["address"], o["routing"], o["filter"] or ""]))
    else:
        print(json.dumps(objs, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
