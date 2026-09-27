#!/usr/bin/env python3
"""Mutation testing: inject realistic RTL bugs one at a time and check that the
cocotb regression catches every one of them (i.e. the testbench is not vacuous)."""
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable

# (description, file, exact original text, mutated text[, PIPE configs])
# Parser mutants run on PIPE_STAGES 0 and 2 unless listed otherwise; a mutant counts as
# killed only if the regression fails in *every* configuration it runs on.
MUTATIONS = [
    # --- field extraction / spec constants
    ("Cancel shares read from offset 20 instead of 19", "itch_parser.sv",
     "      MT_ORDER_CANCEL: begin\n        dec.order_ref     = `ITCH_FLD(11, 8);\n        dec.shares        = `ITCH_FLD(19, 4);",
     "      MT_ORDER_CANCEL: begin\n        dec.order_ref     = `ITCH_FLD(11, 8);\n        dec.shares        = `ITCH_FLD(20, 4);"),
    ("Replace price read from offset 32 instead of 31", "itch_parser.sv",
     "dec.price         = `ITCH_FLD(31, 4);", "dec.price         = `ITCH_FLD(32, 4);"),
    ("Timestamp truncated to 5 bytes", "itch_parser.sv",
     "dec.timestamp    = `ITCH_FLD(5, 6);", "dec.timestamp    = 48'(`ITCH_FLD(5, 5));"),
    ("Wrong spec length for Order Executed (30)", "itch_pkg.sv",
     "LEN_ORDER_EXECUTED    = 16'd31;", "LEN_ORDER_EXECUTED    = 16'd30;"),
    ("One-hot length check: Cancel/Delete bits swapped", "itch_pkg.sv",
     "    len_match[5] = (len == LEN_ORDER_CANCEL);\n    len_match[6] = (len == LEN_ORDER_DELETE);",
     "    len_match[5] = (len == LEN_ORDER_DELETE);\n    len_match[6] = (len == LEN_ORDER_CANCEL);"),
    ("MoldUDP64 header treated as 18 bytes", "itch_pkg.sv",
     "MOLD_HDR_BYTES = 20;", "MOLD_HDR_BYTES = 18;"),
    # --- S1 frame tracker
    ("Block ending on last valid lane treated as not ending", "itch_parser.sv",
     "((r == 4'd0) || keep[4'(r - 4'd1)])", "((r == 4'd0) || keep[r])"),
    ("Length prefix split across beats uses wrong byte", "itch_parser.sv",
     "len_l    = {len_hi_q, lane[0]};", "len_l    = {len_hi_q, lane[1]};"),
    ("tkeep thermometer ignored (always 8 bytes)", "itch_parser.sv",
     "keep     = {8'h00, s_axis_tkeep};", "keep     = {8'h00, 8'hFF};"),
    ("Byte count ignores tkeep (arithmetic only)", "itch_parser.sv",
     "if (s_axis_tkeep[i]) nb = 4'(i + 1);", "nb = 4'(i + 1);"),
    ("Thermometer index off by one (next block has >= 2 bytes)", "itch_parser.sv",
     "k_ge2    = keep[4'(r + 4'd1)];", "k_ge2    = keep[4'(r + 4'd2)];"),
    ("Split subtract drops the borrow into the high part", "itch_parser.sv",
     "return {lo[4] ? hi - (BW-4)'(1) : hi, lo[3:0]};", "return {hi, lo[3:0]};"),
    ("Short-length flag taken from the wrong lane", "itch_parser.sv",
     "short_at[r[2:0]];", "short_at[3'(r[2:0] + 3'd1)];"),
    # --- S2 assemble
    ("Next-block head rotated one lane off", "itch_parser.sv",
     "rot_nxt[j] = lane2[3'(3'(j) + tail2)];", "rot_nxt[j] = lane2[3'(3'(j) + tail2 + 3'd1)];"),
    ("Block buffer written on cycles without a beat", "itch_parser.sv",
     "    if (adv && t2.v) begin\n      for (int p = 0; p < BUF_BYTES; p++) begin",
     "    if (adv) begin\n      for (int p = 0; p < BUF_BYTES; p++) begin"),
    # --- pipeline registers / flow control
    ("S1|S2 register loads while stalled (ignores adv)", "itch_parser.sv",
     "      if (adv) t2[$bits(trk_t)-2:0] <= t1[$bits(trk_t)-2:0];",
     "      t2[$bits(trk_t)-2:0] <= t1[$bits(trk_t)-2:0];", (1, 2)),
    ("S2|S3 register loads while stalled (ignores adv)", "itch_parser.sv",
     "      if (adv) v3[$bits(view_t)-2:0] <= v2[$bits(view_t)-2:0];",
     "      v3[$bits(view_t)-2:0] <= v2[$bits(view_t)-2:0];", (2,)),
    ("Output register ignores m_ready (drops messages)", "itch_parser.sv",
     "assign s_axis_tready = adv;", "assign s_axis_tready = 1'b1;"),
    ("m_msg reloads while held (not enabled by adv)", "itch_parser.sv",
     "    if (adv) m_msg <= dec;", "    m_msg <= dec;"),
    # (equivalent at PIPE_STAGES=0, where v3.v is `fire`, which already includes adv)
    ("S3 events not gated by the advance enable", "itch_parser.sv",
     "    go        = adv && v3.v;", "    go        = v3.v;", (1, 2)),
    # --- MoldUDP64 count check
    ("Message-count check off by one (block ending in tlast beat)", "itch_parser.sv",
     ": blk_end_c ? (blk_left_q != 16'd1)", ": blk_end_c ? (blk_left_q != 16'd0)"),
    # needs an empty (tkeep = 0) tlast beat after the blocks to be observable
    ("End-of-session flag not cleared by a block", "itch_parser.sv",
     "        blk_left_q <= blk_left_q - 16'd1;\n        eos_q      <= 1'b0;",
     "        blk_left_q <= blk_left_q - 16'd1;"),
]

# stat_counter mutants: caught by the stat_counter unit test (tb/test_stat_counter.py)
COUNTER_MUTATIONS = [
    ("stat_counter: segment all-ones flag set one count late", "stat_counter.sv",
     "== {{(SEG-1){1'b1}}, 1'b0});", "== {SEG{1'b1}});"),
    ("stat_counter: carry ignores the lowest segment flag", "stat_counter.sv",
     "if (j < s) seg_en[s] = seg_en[s] && full_q[j];",
     "if (j < s && j > 0) seg_en[s] = seg_en[s] && full_q[j];"),
    ("stat_counter: in-segment carry skips bit 0", "stat_counter.sv",
     "if (j < i) toggle[s*SEG + i]", "if (j < i && j > 0) toggle[s*SEG + i]"),
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


def run_one(job):
    i, (desc, fname, old, new), target, pipe = job
    mdir = ROOT / "build" / "mutants" / f"m{i}_{target}_p{pipe}"
    if mdir.exists():
        shutil.rmtree(mdir)
    shutil.copytree(ROOT / "rtl", mdir / "rtl")
    f = mdir / "rtl" / fname
    src = f.read_text()
    assert src.count(old) == 1, f"mutation {i} pattern not found uniquely: {desc}"
    f.write_text(src.replace(old, new))
    cmd = [PY, str(ROOT / "tb" / "run.py"), "--top", target, "--mold", "1", "--pipe", str(pipe),
           "--msgs", "2000", "--book-msgs", "3000",
           "--rtl-dir", str(mdir / "rtl"), "--build-dir", str(mdir / "sim")]
    if target == "counter":
        cmd += ["--cnt-w", "10", "--cnt-seg", "2", "--cycles", "20000"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = r.stdout + r.stderr
    m = re.search(r"TESTS=(\d+) PASS=(\d+) FAIL=(\d+)", out)
    if m is None:
        return job, None, "build/run error"
    return job, int(m.group(3)) > 0, m.group(0)


def main() -> int:
    muts = ([(m, "parser") for m in MUTATIONS] + [(m, "counter") for m in COUNTER_MUTATIONS]
            + [(m, "feed") for m in BOOK_MUTATIONS])
    filt = os.environ.get("MUT_FILTER")             # optional substring: run matching mutants only
    if filt:
        muts = [mt for mt in muts if filt.lower() in mt[0][0].lower()]
    jobs = []
    for i, (m, target) in enumerate(muts):
        pipes = m[4] if len(m) > 4 else ((0, 2) if target == "parser" else (0,))
        for p in pipes:
            jobs.append((i, tuple(m[:4]), target, p))
    workers = int(os.environ.get("MUT_JOBS", str(max(1, min(8, (os.cpu_count() or 2) // 2)))))
    results: dict[int, list] = {}
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for job, killed, detail in ex.map(run_one, jobs):
            results.setdefault(job[0], []).append((job[3], killed, detail))
    caught, errors = 0, 0
    for i, (m, target) in enumerate(muts):
        rs = results[i]
        errors += any(k is None for _, k, _ in rs)
        killed = all(k for _, k, _ in rs)          # a build error is NOT counted as a kill
        caught += killed
        where = ", ".join(f"{target} p{p}: {d}" for p, _, d in rs)
        print(f"[{'KILLED' if killed else 'SURVIVED':8}] {m[0]:60} ({where})", flush=True)
    print(f"MUTATION SCORE: {caught}/{len(muts)} mutants killed ({len(jobs)} simulation runs"
          f"{f', {errors} build/run errors' if errors else ''})")
    return 0 if caught == len(muts) else 1


if __name__ == "__main__":
    sys.exit(main())
