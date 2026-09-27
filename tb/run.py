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
SOURCES = [ROOT / "rtl" / f for f in ("itch_pkg.sv", "itch_parser.sv", "itch_top.sv")]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", default=os.environ.get("SIM", "verilator"))
    ap.add_argument("--mold", type=int, default=1)
    ap.add_argument("--msgs", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=20260927)
    ap.add_argument("--waves", action="store_true")
    args = ap.parse_args()

    build_dir = ROOT / "build" / f"{args.sim}_mold{args.mold}"
    build_args = []
    if args.sim == "verilator":
        build_args = ["-Wall", "-Wno-fatal", "--x-assign", "unique", "--x-initial", "unique"]
    runner = get_runner(args.sim)
    runner.build(
        sources=SOURCES,
        hdl_toplevel="itch_top",
        parameters={"MOLD_HDR": args.mold},
        build_args=build_args,
        build_dir=build_dir,
        waves=args.waves,
        always=True,
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
