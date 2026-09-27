#!/usr/bin/env python3
"""LUT-level timing analysis of a flattened, LUT-mapped Yosys netlist (write_json).

Every register output and top-level input is at depth 0; a LUT output is 1 + the max
depth of its inputs. Reports the deepest paths per endpoint group (a register, named by
its Q net with the bit index stripped, or an output port) and traces the critical path.

    python3 scripts/depth_report.py netlist.json [--top 12] [--trace 3]
"""
import argparse
import json
import re
from collections import defaultdict

FF_RE = re.compile(r"^\$_(S?DFF|DFFE|SDFFE|SDFFCE|DFFSR|DFFSRE|ALDFF|ALDFFE|DLATCH)")


def group(name: str) -> str:
    name = name.lstrip("\\")
    return re.sub(r"\s*\[\d+\]$", "", name)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("json")
    ap.add_argument("--top", type=int, default=12, help="endpoint groups to list")
    ap.add_argument("--trace", type=int, default=1, help="critical paths to trace")
    a = ap.parse_args()
    mod = next(iter(json.load(open(a.json))["modules"].values()))

    # Best human-readable name per net bit (prefer names without '$').
    bitname: dict[int, str] = {}
    for n, info in mod["netnames"].items():
        for i, b in enumerate(info["bits"]):
            if not isinstance(b, int):
                continue
            nm = n if len(info["bits"]) == 1 else f"{n} [{i}]"
            old = bitname.get(b)
            if old is None or (old.startswith("$") and not n.startswith("$")):
                bitname[b] = nm

    driver: dict[int, tuple[str, list[int]]] = {}     # bit -> (cell, input bits)
    endpoints: list[tuple[int, str]] = []           # (bit, endpoint group)
    for cname, c in mod["cells"].items():
        conns, dirs = c["connections"], c.get("port_directions", {})
        if FF_RE.match(c["type"]):
            q = conns["Q"][0]
            g = group(bitname.get(q, cname))
            for p, bits in conns.items():
                if p != "Q":
                    endpoints += [(b, f"{g} <{p}>") for b in bits if isinstance(b, int)]
            continue
        ins = [b for p, bits in conns.items() if dirs.get(p) == "input" for b in bits if isinstance(b, int)]
        for p, bits in conns.items():
            if dirs.get(p) == "output":
                for b in bits:
                    if isinstance(b, int):
                        driver[b] = (cname, ins)
    for pname, p in mod["ports"].items():
        if p["direction"] == "output":
            endpoints += [(b, f"port {pname}") for b in p["bits"] if isinstance(b, int)]

    depth: dict[int, int] = {}
    pred: dict[int, int | None] = {}

    def d(b: int) -> int:
        stack = [b]
        while stack:
            x = stack[-1]
            if x in depth:
                stack.pop()
                continue
            if x not in driver:
                depth[x], pred[x] = 0, None
                stack.pop()
                continue
            pending = [i for i in driver[x][1] if i not in depth]
            if pending:
                stack += pending
                continue
            ins = driver[x][1]
            best = max(ins, key=lambda i: depth[i], default=None)
            depth[x] = 1 + (depth[best] if best is not None else 0)
            pred[x] = best
            stack.pop()
        return depth[b]

    worst: dict[str, tuple[int, int]] = {}
    for b, g in endpoints:
        v = d(b)
        if g not in worst or v > worst[g][0]:
            worst[g] = (v, b)
    ranked = sorted(worst.items(), key=lambda kv: -kv[1][0])
    print(f"max LUT depth: {ranked[0][1][0] if ranked else 0}")
    print("deepest endpoint groups:")
    for g, (v, _) in ranked[: a.top]:
        print(f"  {v:3d}  {g}")
    for g, (v, b) in ranked[: a.trace]:
        path, x = [], b
        while x is not None:
            path.append(x)
            x = pred[x]
        path.reverse()
        print(f"critical path to {g} ({v} LUTs):")
        start = bitname.get(path[0], "?")
        print(f"    start: {start}")
        for x in path[1:]:
            nm = bitname.get(x, "")
            if nm and not nm.startswith("$"):
                print(f"    {depth[x]:3d}: {nm}")


if __name__ == "__main__":
    main()
