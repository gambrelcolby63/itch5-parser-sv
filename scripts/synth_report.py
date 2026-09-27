#!/usr/bin/env python3
"""Summarize the Yosys outputs in syn/out/ (written by `make synth`) as Markdown tables."""
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
    print("| itch_top MOLD_HDR=1 (Yosys `synth; abc -lut 6`) | LUT6 | FF | LUT levels (ltp) | latency (clk) |")
    print("|---|---|---|---|---|")
    for p in (0, 1, 2):
        st, ltp = OUT / f"stat_lut6_p{p}.txt", OUT / f"ltp_lut6_p{p}.txt"
        if not (st.exists() and ltp.exists()):
            continue
        c = cells(st)
        ffs = sum(v for k, v in c.items() if k.startswith("$_") and "DFF" in k)
        depth = re.search(r"length=(\d+)", ltp.read_text()).group(1)
        print(f"| PIPE_STAGES={p} | {c.get('$lut', 0):,} | {ffs:,} | {depth} | {1 + p} |")
    print()
    print("| Design (Yosys synth_xilinx -family xcup) | LUT | FF | RAMB36 | RAMB18 | LUTRAM | MUXF7/8/9 | CARRY |")
    print("|---|---|---|---|---|---|---|---|")
    for p in (0, 1, 2):
        f = OUT / f"stat_xilinx_p{p}.txt"
        if f.exists():
            print(xilinx_row(f"itch_top (parser only), PIPE_STAGES={p}", f))
    f = OUT / "stat_feed_xilinx.txt"
    if f.exists():
        print(xilinx_row("itch_feed_top (parser + FIFO + book, defaults)", f))
    print("\nPer-endpoint depth breakdown: syn/out/depth_p<N>.txt (scripts/depth_report.py)")


if __name__ == "__main__":
    main()
