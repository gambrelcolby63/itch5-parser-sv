#!/usr/bin/env python3
"""Build and run the cocotb testbench with Verilator (or Icarus) via the cocotb runner.

    python tb/run.py [--sim verilator|icarus] [--top parser|feed|counter] [--mold 0|1]
                     [--pipe 0|1|2] [--msgs N] [--seed S] [--waves]
"""
import argparse
import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", default=os.environ.get("SIM", "verilator"))
    ap.add_argument("--mold", type=int, default=1)
    ap.add_argument("--msgs", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=20260927)
    ap.add_argument("--waves", action="store_true")
    ap.add_argument("--rtl-dir", default=str(ROOT / "rtl"), help="alternate RTL dir (mutation testing)")
    ap.add_argument("--build-dir", default=None)
    ap.add_argument("--top", choices=["parser", "feed", "counter"], default="parser",
                    help="parser = itch_top/test_itch, feed = itch_feed_top/test_book, "
                         "counter = stat_counter/test_stat_counter")
    ap.add_argument("--cnt-w", type=int, default=10, help="stat_counter W (--top counter)")
    ap.add_argument("--cnt-seg", type=int, default=2, help="stat_counter SEG (--top counter)")
    ap.add_argument("--cycles", type=int, default=20000, help="stat_counter test cycles")
    ap.add_argument("--book-msgs", type=int, default=30000)
    ap.add_argument("--levels", type=int, default=8)
    ap.add_argument("--ord-bits", type=int, default=12)
    ap.add_argument("--num-symbols", type=int, default=256)
    ap.add_argument("--pipe", type=int, default=0, help="parser PIPE_STAGES (0, 1, 2)")
    args = ap.parse_args()

    rtl = Path(args.rtl_dir)
    if args.top == "parser":
        files, top, module = ("itch_pkg.sv", "stat_counter.sv", "itch_parser.sv", "itch_top.sv"), "itch_top", "test_itch"
        params = {"MOLD_HDR": args.mold, "PIPE_STAGES": args.pipe}
        tag = f"mold{args.mold}_p{args.pipe}"
    elif args.top == "counter":
        files, top, module = ("stat_counter.sv",), "stat_counter", "test_stat_counter"
        params = {"W": args.cnt_w, "SEG": args.cnt_seg}
        tag = f"cnt_W{args.cnt_w}_S{args.cnt_seg}"
    else:
        files = ("itch_pkg.sv", "stat_counter.sv", "itch_parser.sv", "stream_fifo.sv", "itch_book.sv", "itch_feed_top.sv")
        top, module = "itch_feed_top", "test_book"
        params = {"MOLD_HDR": 1, "LEVELS": args.levels, "ORD_BITS": args.ord_bits,
                  "NUM_SYMBOLS": args.num_symbols, "LOCATE_BITS": 14, "PARSER_PIPE": args.pipe}
        tag = f"feed_L{args.levels}_O{args.ord_bits}_p{args.pipe}"
    sources = [rtl / f for f in files]
    build_dir = Path(args.build_dir) if args.build_dir else ROOT / "build" / f"{args.sim}_{tag}"
    build_args = []
    if args.sim == "verilator":
        build_args = ["-Wall", "-Wno-fatal", "--x-assign", "unique", "--x-initial", "unique"]
    runner = get_runner(args.sim)
    runner.build(
        sources=sources,
        hdl_toplevel=top,
        parameters=params,
        build_args=build_args,
        build_dir=build_dir,
        waves=args.waves,
        always=True,
        timescale=("1ns", "1ps"),
    )
    results = runner.test(
        hdl_toplevel=top,
        test_module=module,
        test_dir=ROOT / "tb",
        build_dir=build_dir,
        extra_env={"ITCH_MOLD_HDR": str(args.mold), "ITCH_N_MSGS": str(args.msgs),
                   "ITCH_SEED": str(args.seed), "PYTHONPATH": str(ROOT / "tb"),
                   "ITCH_N_BOOK": str(args.book_msgs), "ITCH_LEVELS": str(args.levels),
                   "ITCH_ORD_BITS": str(args.ord_bits), "ITCH_NUM_SYMBOLS": str(args.num_symbols),
                   "ITCH_LOCATE_BITS": "14", "ITCH_PIPE": str(args.pipe),
                   "CNT_W": str(args.cnt_w), "CNT_CYCLES": str(args.cycles)},
        waves=args.waves,
        results_xml=str(build_dir / "results.xml"),
    )
    print(f"results: {results}")
    return 1 if "<failure" in Path(results).read_text() else 0


if __name__ == "__main__":
    sys.exit(main())
