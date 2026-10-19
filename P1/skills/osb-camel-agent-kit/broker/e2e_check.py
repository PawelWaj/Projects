#!/usr/bin/env python3
"""Helper of e2e_local.sh (one-window broker test of a module or a flat delivery project). Stdlib only.

    e2e_check.py plan   <folder> [--flow <proxy>]           one case per scenario folder: flow <TAB> case dir <TAB> expected outputs
    e2e_check.py report <folder> <plan.tsv> <before.txt> <after.txt> <raw-errors-per-flow>

plan: every scenario folder of every flow (real cases first, synthetic where a scenario has no real one); the expected
outputs come from flow-test.json scenario_mapping exactly as the parity test computes them.
report: MESSAGES ADDED of each output queue after minus before (`artemis queue stat` tables), next to the expected
count; error queue expected = error cases + the raw messages sent. Prints OK / DIFF per queue and exits 1 on a DIFF."""
from __future__ import annotations

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


TOKEN = re.compile(r"\s*(?:(\()|(\))|('(?:[^']|'')*')|(<>|=|,)|([A-Za-z_][\w.]*)|(-?\d+(?:\.\d+)?))")


def tokens(sel: str) -> list[tuple[str, str]] | None:
    out, i = [], 0
    while i < len(sel.rstrip()):
        m = TOKEN.match(sel, i)
        if not m or m.end() == i:
            return None
        lp, rp, lit, op, ident, num = m.groups()
        out.append(("(", "(") if lp else (")", ")") if rp else ("lit", lit[1:-1].replace("''", "'")) if lit
                   else ("op", op) if op else ("num", num) if num else
                   (ident.upper(), ident.upper()) if ident.upper() in ("AND", "OR", "NOT", "IN") else ("id", ident))
        i = m.end()
    return out


def evaluate(sel: str, headers: dict):
    """JMS selector subset of OSB proxies: = <> IN, AND OR NOT, parentheses. A missing property is never equal.
    Returns True/False, or None when the selector uses anything else (then it is not judged)."""
    t = tokens(sel)
    if t is None:
        return None
    pos = [0]

    def peek():
        return t[pos[0]] if pos[0] < len(t) else ("end", "")

    def take(kind=None):
        tok = peek()
        if kind and tok[0] != kind:
            raise ValueError(tok)
        pos[0] += 1
        return tok

    def factor():
        if peek()[0] == "NOT":
            take()
            return not factor()
        if peek()[0] == "(":
            take()
            v = expr()
            take(")")
            return v
        name = take("id")[1]
        have = headers.get(name)
        if peek()[0] == "IN":
            take(); take("(")
            vals = [take()[1]]
            while peek() == ("op", ","):
                take(); vals.append(take()[1])
            take(")")
            return have is not None and str(have) in vals
        op = take("op")[1]
        val = take()[1]
        if have is None:
            return False
        return (str(have) == val) if op == "=" else (str(have) != val)

    def term():
        v = factor()
        while peek()[0] == "AND":
            take()
            v = factor() and v
        return v

    def expr():
        v = term()
        while peek()[0] == "OR":
            take()
            v = term() or v
        return v

    try:
        v = expr()
        return v if pos[0] == len(t) else None
    except (ValueError, IndexError):
        return None


def passes(selector: str, headers: dict) -> bool:
    if not selector:
        return True
    v = evaluate(selector, headers)
    return True if v is None else v


def fill_for_selector(selector: str, headers: dict) -> dict:
    """Properties the selector needs but the case does not carry (OSB does not log them, e.g. eventType): each gets the
    first value named in the selector that lets the message pass; the case's own properties are never changed."""
    if not selector:
        return {}
    t = tokens(selector) or []
    missing = [n for k, n in t if k == "id" and n not in headers]
    added = {}
    for name in dict.fromkeys(missing):
        vals = [t[i + 2][1] for i in range(len(t) - 2) if t[i] == ("id", name) and t[i + 1] == ("op", "=")]
        for v in vals or [""]:
            if evaluate(selector, {**headers, **added, name: v}) is not False:
                added[name] = v
                break
        else:
            added[name] = vals[0] if vals else ""
    return added


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
            hdr = {**hdr, **fill_for_selector(sel, hdr)}       # what e2e_local sends (send_case --fill-selector)
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


def input_queue(folder: Path, flow: str) -> str:
    for f in (folder / "src/env/local.properties", folder / "env/local.properties"):
        for ln in f.read_text(encoding="utf-8").splitlines() if f.is_file() else []:
            k, _, v = ln.partition("=")
            if k.strip() in (f"{flow}.flow.input", "flow.input"):
                m = re.search(r"::([^?&\s]+)", v) or re.search(r"subscriptionName=([^&\s]+)", v) or re.search(r"queue:([^?&\s]+)", v)
                return m.group(1) if m else ""
    return ""


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
    sent = {}
    for ln in plan_file.read_text(encoding="utf-8").splitlines():
        flow, _, outs = ln.split("\t")
        sent[flow] = sent.get(flow, 0) + (0 if outs.startswith("(filtered") else 1)
    for flow in sorted(flows):                     # the subscription queue: what got past the selector
        sub = input_queue(folder, flow)
        if sub:
            got = a.get(sub, 0) - b.get(sub, 0) if sub in a else None
            print(f"input of {flow}: subscription queue {sub}: {sent[flow] + raw} expected past the selector, "
                  f"{'missing' if got is None else got} arrived; selector: {selector_of(folder, flow) or '(none)'}")
            if got == 0:
                print("   nothing passed the selector: the message properties (headers.json) do not match it, see above")
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
