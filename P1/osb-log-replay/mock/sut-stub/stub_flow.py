"""Harness self-test stub, NOT a migration: consumes each flow's subscription queue (FQQN address::queue) and forwards
valid JSON payloads to the flow's success queue, invalid ones to the error queue with error headers. Lets you prove the
mock architecture and the replay runner before the real Camel flow exists."""
import json
import os
import sys
import time

import stomp

cfg = json.load(open(sys.argv[1]))
b = cfg["broker"]
conn = stomp.Connection([(os.environ.get("BROKER_HOST", b["host"]), int(b["stomp_port"]))])


class Forward(stomp.ConnectionListener):
    def __init__(self, fc):
        self.fc = fc

    def on_message(self, frame):
        out, extra = self.fc["outputs"]["success"], {}
        try:
            json.loads(frame.body)
        except ValueError as exc:
            out = self.fc["outputs"]["error"]
            extra = {"errorCode": "STUB-PARSE", "errorMessage": str(exc)[:200], "debugInfo": "stub"}
        keep = {k: v for k, v in frame.headers.items() if k in ("traceId", "resource", "eventType")}
        conn.send(destination=out["destination"], body=frame.body,
                  headers={**keep, **extra, "destination-type": out.get("type", "anycast").upper()})


for i, (flow, fc) in enumerate(cfg["flows"].items(), start=1):
    conn.set_listener(f"f{i}", Forward(fc))
connect_ok = False
for _ in range(30):
    try:
        conn.connect(b["user"], os.environ.get(b.get("password_env", "ARTEMIS_PASSWORD"), ""), wait=True)
        connect_ok = True
        break
    except Exception:
        time.sleep(2)
if not connect_ok:
    sys.exit("broker not reachable")
for i, (flow, fc) in enumerate(cfg["flows"].items(), start=1):
    inp = fc["input"]
    conn.subscribe(destination=f"{inp['address']}::{inp['subscription']}", id=str(i), ack="auto",
                   headers={"destination-type": "MULTICAST"})
    print("stub consuming", f"{inp['address']}::{inp['subscription']}", flush=True)
while True:
    time.sleep(60)
