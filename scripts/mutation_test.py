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

# (description, file, exact original text, mutated text); target = parser or feed (book)
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

BOOK_MUTATIONS = [
    ("Book: asks sorted like bids", "itch_book.sv",
     "return side ? (a < b) : (a > b);", "return side ? (a > b) : (a > b);"),
    ("Book: fully executed order not deleted", "itch_book.sv",
     "ordA_wd        = '0;                       // fully executed: delete",
     "ordA_wd.shares = '0;"),
    ("Book: replace into its own bucket seen as collision", "itch_book.sv",
     "freeB      = !ordB_valid || (is_rep && hitA && (idxA_q == idxB_q));",
     "freeB      = !ordB_valid;"),
    ("Book: vacated last level not cleared", "itch_book.sv",
     "        px1[LEVELS-1] = '0;\n        qt1[LEVELS-1] = '0;",
     "        px1[LEVELS-1] = px0[LEVELS-1];\n        qt1[LEVELS-1] = qt0[LEVELS-1];"),
    ("Book: trunc flag not set when worst level falls off", "itch_book.sv",
     "          add_drop = 1'b1;                             // worst level fell off\n          trunc2   = 1'b1;",
     "          add_drop = 1'b1;                             // worst level fell off"),
    ("Book: exec/cancel uses message price, not resting price", "itch_book.sv",
     "      end else if (is_exec) begin\n        look_go = 1'b1;",
     "      end else if (is_exec) begin\n        sub_px  = msg_q.price;\n        look_go = 1'b1;"),
    ("Book: Add side decoded as always bid", "itch_book.sv",
     "lvl_addr = {sub_rd.slot, (msg_q.side == 8'h53)};", "lvl_addr = {sub_rd.slot, 1'b0};"),
    ("Book: locate beyond table aliases into it", "itch_book.sv",
     "subscribed = sub_rd.enable && !loc_hi_q;", "subscribed = sub_rd.enable;"),
    ("Book: level qty overwritten instead of accumulated", "itch_book.sv",
     "qt2[fi] = qt1[fi] + add_q_q;", "qt2[fi] = add_q_q;"),
    ("FIFO: bypass ignores consumer ready", "stream_fifo.sv",
     "assign bypass    = empty && in_valid && out_ready;", "assign bypass    = empty && in_valid;"),
]


def main() -> int:
    caught = 0
    jobs = [(m, "parser") for m in MUTATIONS] + [(m, "feed") for m in BOOK_MUTATIONS]
    for i, ((desc, fname, old, new), target) in enumerate(jobs):
        mdir = ROOT / "build" / "mutants" / f"m{i}"
        if mdir.exists():
            shutil.rmtree(mdir)
        shutil.copytree(ROOT / "rtl", mdir / "rtl")
        f = mdir / "rtl" / fname
        src = f.read_text()
        assert src.count(old) == 1, f"mutation {i} pattern not found uniquely: {desc}"
        f.write_text(src.replace(old, new))
        r = subprocess.run([PY, str(ROOT / "tb" / "run.py"), "--top", target, "--mold", "1",
                            "--msgs", "2000", "--book-msgs", "3000",
                            "--rtl-dir", str(mdir / "rtl"), "--build-dir", str(mdir / "sim")],
                           capture_output=True, text=True)
        out = r.stdout + r.stderr
        m = re.search(r"TESTS=(\d+) PASS=(\d+) FAIL=(\d+)", out)
        killed = (m is None) or int(m.group(3)) > 0
        caught += killed
        status = "KILLED" if killed else "SURVIVED"
        detail = m.group(0) if m else "build/run error"
        print(f"[{status:8}] {desc:58} ({detail})", flush=True)
    print(f"MUTATION SCORE: {caught}/{len(jobs)} mutants killed")
    return 0 if caught == len(jobs) else 1


if __name__ == "__main__":
    sys.exit(main())
