#!/usr/bin/env python3
"""Summarize Yosys `stat` outputs in syn/out/ as a Markdown table."""
import re
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "syn" / "out"


def cells(path: Path) -> dict:
    d = {}
    for m in re.finditer(r"^\s+(\S+)\s+(\d+)\s*$", path.read_text(), re.M):
        d[m.group(1)] = int(m.group(2))
    return d


def xilinx_row(name, path):
    c = cells(path)
    luts = sum(v for k, v in c.items() if re.fullmatch(r"LUT[1-6]", k))
    ffs = sum(v for k, v in c.items() if k.startswith("FD"))
    muxf = "/".join(str(c.get(k, 0)) for k in ("MUXF7", "MUXF8", "MUXF9"))
    return (f"| {name} | {luts:,} | {ffs:,} | {c.get('RAMB36E2', 0)} | {c.get('RAMB18E2', 0)} | "
            f"{sum(v for k, v in c.items() if k.startswith('RAM') and 'RAMB' not in k)} | {muxf} | "
            f"{c.get('CARRY4', 0) + c.get('CARRY8', 0)} |")


def main():
    print("| Design (Yosys synth_xilinx -family xcup) | LUT | FF | RAMB36 | RAMB18 | LUTRAM | MUXF7/8/9 | CARRY |")
    print("|---|---|---|---|---|---|---|---|")
    for name, f in (("itch_top (parser only)", "stat_xilinx.txt"),
                    ("itch_feed_top (parser + FIFO + book, defaults)", "stat_feed_xilinx.txt")):
        if (OUT / f).exists():
            print(xilinx_row(name, OUT / f))
    ltp = OUT / "ltp_lut6.txt"
    if ltp.exists():
        m = re.search(r"length=(\d+)", ltp.read_text())
        c = cells(OUT / "stat_lut6.txt")
        print(f"\nGeneric `abc -lut 6` (parser only): {c.get('$lut', 0):,} LUT6, "
              f"longest path {m.group(1)} LUT levels (see README for what that path is)")


if __name__ == "__main__":
    main()
