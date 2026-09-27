#!/usr/bin/env python3
"""Build and run the cocotb testbench with Verilator (or Icarus) via the cocotb runner.

    python tb/run.py [--sim verilator|icarus] [--mold 0|1] [--msgs N] [--seed S] [--waves]
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
    args = ap.parse_args()

    rtl = Path(args.rtl_dir)
    sources = [rtl / f for f in ("itch_pkg.sv", "itch_parser.sv", "itch_top.sv")]
    build_dir = Path(args.build_dir) if args.build_dir else ROOT / "build" / f"{args.sim}_mold{args.mold}"
    build_args = []
    if args.sim == "verilator":
        build_args = ["-Wall", "-Wno-fatal", "--x-assign", "unique", "--x-initial", "unique"]
    runner = get_runner(args.sim)
    runner.build(
        sources=sources,
        hdl_toplevel="itch_top",
        parameters={"MOLD_HDR": args.mold},
        build_args=build_args,
        build_dir=build_dir,
        waves=args.waves,
        always=True,
        timescale=("1ns", "1ps"),
    )
    results = runner.test(
        hdl_toplevel="itch_top",
        test_module="test_itch",
        test_dir=ROOT / "tb",
        build_dir=build_dir,
        extra_env={"ITCH_MOLD_HDR": str(args.mold), "ITCH_N_MSGS": str(args.msgs),
                   "ITCH_SEED": str(args.seed), "PYTHONPATH": str(ROOT / "tb")},
        waves=args.waves,
    )
    print(f"results: {results}")
    return 1 if "<failure" in Path(results).read_text() else 0


if __name__ == "__main__":
    sys.exit(main())
