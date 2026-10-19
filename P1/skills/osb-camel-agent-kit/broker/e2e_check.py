#!/usr/bin/env python3
"""Helper of e2e_local.sh (one-window broker test of a module or a flat delivery project). Stdlib only.

    e2e_check.py plan   <folder> [--flow <proxy>]           one case per scenario folder: flow <TAB> case dir <TAB> expected outputs
    e2e_check.py report <folder> <plan.tsv> <before.txt> <after.txt> <raw-errors-per-flow>

plan: every scenario folder of every flow (real cases first, synthetic where a scenario has no real one); the expected
outputs come from flow-test.json scenario_mapping exactly as the parity test computes them.
report: MESSAGES ADDED of each output queue after minus before (`artemis queue stat` tables), next to the expected
count; error queue expected = error cases + the raw messages sent. Prints OK / DIFF per queue and exits 1 on a DIFF."""
import json
import re
import sys
from pathlib import Path


def resources(folder: Path) -> list[tuple[str, Path]]:
    """(flow, test resources dir): flat project src/test/resources/<proxy>/, module src/test/resources/."""
    base = folder / "src/test/resources"
    if (base / "flow-test.json").is_file():
        return [(folder.name, base)]
    return [(d.name, d) for d in sorted(base.iterdir()) if (d / "flow-test.json").is_file()]


def matches(key: str, values: dict) -> bool:
    if not key.strip():
        return False
    for p in key.split("|"):
        if "!=" in p:
            k, v = p.split("!=", 1)
            if values.get(k) == v:
                return False
        elif "=" in p:
            k, v = p.split("=", 1)
            if values.get(k) != v:
                return False
    return True


def expected(case: Path, cfg: dict) -> list[str]:
    exp = json.loads((case / "expected.json").read_text(encoding="utf-8")) if (case / "expected.json").is_file() else {}
    if exp.get("outcome", "success") != "success":
        return [cfg.get("error_output", "")]
    sc = case.parent / "SCENARIO.txt"
    values = dict(p.split("=", 1) for p in (sc.read_text(encoding="utf-8").strip() if sc.is_file() else "").split("|") if "=" in p)
    for m in cfg.get("scenario_mapping", []):
        if matches(m.get("scenario", ""), values):
            return list(m.get("outputs") or [])
    return ["?unmapped"]


def selector_of(folder: Path, flow: str) -> str:
    for f in (folder / "src/env/local.properties", folder / "env/local.properties"):
        for ln in f.read_text(encoding="utf-8").splitlines() if f.is_file() else []:
            k, _, v = ln.partition("=")
            if k.strip() in (f"{flow}.flow.input.selector", "flow.input.selector"):
                return v.strip()
    return ""


def passes(selector: str, headers: dict) -> bool:
    """The broker-side filter for the simple OSB form (a = 'x' AND b = 'y' ...); anything else is assumed to pass."""
    if not selector or re.search(r"\bOR\b|\bNOT\b|<>|\bLIKE\b|\bIN\b", selector, re.I):
        return True
    return all(str(headers.get(k, "")) == v for k, v in re.findall(r"(\w+)\s*=\s*'([^']*)'", selector))


def plan(folder: Path, only: str | None) -> None:
    for flow, res in resources(folder):
        if only and flow != only:
            continue
        sel = selector_of(folder, flow)
        cfg = json.loads((res / "flow-test.json").read_text(encoding="utf-8"))
        scen = {}
        for inp in sorted((res / "parity").rglob("input.payload")):
            case = inp.parent
            key = case.parent
            synthetic = "-synthetic" in str(case)
            if key not in scen or (scen[key][1] and not synthetic):
                scen[key] = (case, synthetic)
        for case, _ in sorted(scen.values(), key=lambda t: (t[1], str(t[0]))):
            hf = case / "headers.json"
            hdr = json.loads(hf.read_text(encoding="utf-8")) if hf.is_file() else {}
            outs = expected(case, cfg) if passes(sel, hdr) else ["(filtered by the subscription selector)"]
            print(f"{flow}\t{case.as_posix()}\t{','.join(outs)}")


def queue_of(folder: Path, flow: str, output: str, flat: bool) -> str:
    f = folder / ("src/env/local.properties" if flat else "env/local.properties")
    for ln in f.read_text(encoding="utf-8").splitlines() if f.is_file() else []:
        k, _, v = ln.partition("=")
        k = k.strip()
        if (k.endswith(f".{output}") or k == f"out.{output}") and (not flat or k.startswith(f"{flow}.")):
            m = re.search(r"(?:queue|topic):([^?&\s]+)", v)
            if m:
                return m.group(1).split("::")[0]
    return output


def added(table: str) -> dict:
    """MESSAGES ADDED per queue name from an `artemis queue stat` table (one- or two-line header)."""
    head, out = None, {}
    for ln in table.splitlines():
        if not ln.strip().startswith("|"):
            continue
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        if "NAME" in cells:
            head = cells
            continue
        if head and len(cells) == len(head) and any("ADDED" in c for c in cells):     # second header line
            head = [f"{h} {c}".strip() for h, c in zip(head, cells)]
            continue
        if head and len(cells) == len(head) and any("ADDED" in h for h in head):
            try:
                out[cells[head.index("NAME")]] = int(cells[next(i for i, h in enumerate(head) if "ADDED" in h)])
            except ValueError:
                pass
    return out


def report(folder: Path, plan_file: Path, before: Path, after: Path, raw: int) -> int:
    flat = (folder / "src/env/local.properties").is_file() and not (folder / "env/local.properties").is_file()
    want = {}
    flows = set()
    for ln in plan_file.read_text(encoding="utf-8").splitlines():
        flow, _, outs = ln.split("\t")
        flows.add(flow)
        for o in filter(lambda o_: o_ and not o_.startswith("("), outs.split(",")):
            want[(flow, o)] = want.get((flow, o), 0) + 1
    for flow, res in resources(folder):
        if flow in flows:
            err = json.loads((res / "flow-test.json").read_text(encoding="utf-8")).get("error_output", "")
            want[(flow, err)] = want.get((flow, err), 0) + raw
            outs = json.loads((res / "flow-test.json").read_text(encoding="utf-8")).get("outputs", {})
            for o in outs:
                want.setdefault((flow, o), 0)
    b, a = added(before.read_text(encoding="utf-8", errors="replace")), added(after.read_text(encoding="utf-8", errors="replace"))
    bad = 0
    print(f"{'flow':<22} {'output queue':<55} {'expected':>8} {'arrived':>8}")
    for (flow, o), n in sorted(want.items()):
        if o == "reply":
            continue
        q = queue_of(folder, flow, o, flat)
        got = a.get(q, 0) - b.get(q, 0) if q in a else None
        ok = got == n
        bad += not ok
        print(f"{flow:<22} {q[:55]:<55} {n:>8} {('missing' if got is None else got):>8}  {'OK' if ok else 'DIFF'}")
    print("RESULT:", "every output queue got what the tests expect" if not bad else f"{bad} queue(s) differ")
    return 1 if bad else 0


def main() -> int:
    a = sys.argv[1:]
    if len(a) >= 2 and a[0] == "plan":
        plan(Path(a[1]), a[3] if len(a) > 3 and a[2] == "--flow" else None)
        return 0
    if len(a) == 6 and a[0] == "report":
        return report(Path(a[1]), Path(a[2]), Path(a[3]), Path(a[4]), int(a[5]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
