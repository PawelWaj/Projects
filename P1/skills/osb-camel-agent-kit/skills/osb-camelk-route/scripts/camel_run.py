#!/usr/bin/env python3
"""Start a work module with Camel JBang the way Camel K runs it (no Maven build of the module).

    camel_run.py modules/<project>/<proxy> [--overrides env/local.properties] [--port N] [--timeout S] [--print]

Route YAML + Java sources (compiled by Camel, as on Camel K) + resources, the Camel K variant of
application.properties with the override lines applied (local addresses of the queues, stub backends), and the
dependency list camelk_manifests.py writes into integration.yaml. Connection values ({{env:BROKER_URL}} ...) come
from the environment, as on the cluster. `--print` shows the command instead of running it. Used by
broker/run_local.sh with ENGINE=jbang (JMS flows on the local Artemis) and by local_acceptance.sh.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_http import jbang_command, read_properties, win_path  # noqa: E402


def overrides(path: Path | None) -> dict[str, str]:
    """key=value lines of a local.properties; the selector stays on the broker (artemis_prepare.sh), not in the route."""
    if not path or not path.is_file():
        return {}
    return {k: v for k, v in read_properties(path).items() if not k.endswith(".selector")}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", type=Path)
    ap.add_argument("--overrides", type=Path, help="properties that replace the ones of application.properties")
    ap.add_argument("--port", type=int, default=0, help="platform-http port (0 = no HTTP server)")
    ap.add_argument("--timeout", type=int, default=3600, help="the route stops by itself after this many seconds + 600")
    ap.add_argument("--print", action="store_true", help="print the command, do not run it")
    a = ap.parse_args()
    mod = Path(win_path(str(a.module))).resolve()
    mvn = os.environ.get("VERIFY_MVN", "mvn -B " + os.environ.get("MVN_ARGS", ""))
    cmd = jbang_command(mod, a.port, a.timeout, overrides(a.overrides), mvn)
    if a.print:
        print(" ".join(cmd))
        return 0
    sys.stdout.flush()
    if os.name == "nt":                     # no exec on Windows: wait, so the caller's kill of the tree reaches java
        return subprocess.call(cmd, cwd=str(mod))
    os.chdir(mod)
    os.execv(cmd[0], cmd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
