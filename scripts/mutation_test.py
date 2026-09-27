#!/usr/bin/env python3
"""Mutation testing: inject realistic RTL bugs one at a time and check that the
cocotb regression catches every one of them (i.e. the testbench is not vacuous)."""
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable

# (description, file, exact original text, mutated text)
MUTATIONS = [
    ("Cancel shares read from offset 20 instead of 19", "itch_parser.sv",
     "      MT_ORDER_CANCEL: begin\n        dec.order_ref     = `ITCH_FLD(11, 8);\n        dec.shares        = `ITCH_FLD(19, 4);",
     "      MT_ORDER_CANCEL: begin\n        dec.order_ref     = `ITCH_FLD(11, 8);\n        dec.shares        = `ITCH_FLD(20, 4);"),
    ("Replace price read from offset 32 instead of 31", "itch_parser.sv",
     "dec.price         = `ITCH_FLD(31, 4);", "dec.price         = `ITCH_FLD(32, 4);"),
    ("Timestamp truncated to 5 bytes", "itch_parser.sv",
     "dec.timestamp    = `ITCH_FLD(5, 6);", "dec.timestamp    = 48'(`ITCH_FLD(5, 5));"),
    ("Next-block head off by one lane", "itch_parser.sv",
     "((rem_l + 4'(p)) == 4'(i))", "((rem_l + 4'(p) + 4'd1) == 4'(i))"),
    ("Block ending on last lane treated as not ending", "itch_parser.sv",
     "cur_ends    = cur_known && (rem <= BW'(nb));", "cur_ends    = cur_known && (rem < BW'(nb));"),
    ("Length prefix split across beats uses wrong byte", "itch_parser.sv",
     "cur_len   = {buf_q[0], lane[0]};", "cur_len   = {buf_q[1], lane[0]};"),
    ("tkeep ignored (always 8 bytes)", "itch_parser.sv",
     "if (s_axis_tkeep[i]) nb = 4'(i + 1);", "nb = 4'(i + 1);"),
    ("Output register ignores m_ready (drops messages)", "itch_parser.sv",
     "assign s_axis_tready = !m_valid || m_ready;", "assign s_axis_tready = 1'b1;"),
    ("Wrong spec length for Order Executed (30)", "itch_pkg.sv",
     "LEN_ORDER_EXECUTED    = 16'd31;", "LEN_ORDER_EXECUTED    = 16'd30;"),
    ("MoldUDP64 header treated as 18 bytes", "itch_pkg.sv",
     "MOLD_HDR_BYTES = 20;", "MOLD_HDR_BYTES = 18;"),
]


def main() -> int:
    caught = 0
    for i, (desc, fname, old, new) in enumerate(MUTATIONS):
        mdir = ROOT / "build" / "mutants" / f"m{i}"
        if mdir.exists():
            shutil.rmtree(mdir)
        shutil.copytree(ROOT / "rtl", mdir / "rtl")
        f = mdir / "rtl" / fname
        src = f.read_text()
        assert src.count(old) == 1, f"mutation {i} pattern not found uniquely: {desc}"
        f.write_text(src.replace(old, new))
        r = subprocess.run([PY, str(ROOT / "tb" / "run.py"), "--mold", "1", "--msgs", "2000",
                            "--rtl-dir", str(mdir / "rtl"), "--build-dir", str(mdir / "sim")],
                           capture_output=True, text=True)
        out = r.stdout + r.stderr
        m = re.search(r"TESTS=(\d+) PASS=(\d+) FAIL=(\d+)", out)
        killed = (m is None) or int(m.group(3)) > 0
        caught += killed
        status = "KILLED" if killed else "SURVIVED"
        detail = m.group(0) if m else "build/run error"
        print(f"[{status:8}] {desc:55} ({detail})", flush=True)
    print(f"MUTATION SCORE: {caught}/{len(MUTATIONS)} mutants killed")
    return 0 if caught == len(MUTATIONS) else 1


if __name__ == "__main__":
    sys.exit(main())
