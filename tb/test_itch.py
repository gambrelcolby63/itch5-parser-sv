"""
cocotb testbench for itch_top.

A single cycle-accurate coroutine drives the AXI-Stream input (random tvalid gaps,
random junk on the bus while tvalid=0), drives m_ready (random backpressure, which
propagates to s_axis_tready), and monitors every output. Each cycle:

    FallingEdge -> drive inputs -> ReadOnly -> sample handshakes/outputs -> RisingEdge

Every decoded message, early strobe and MoldUDP64 header is compared against the
golden model, and the latency from "beat carrying the last byte accepted" to
"m_valid first seen" is measured for every message.
"""
from __future__ import annotations

import os
import random
from collections import Counter

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from itch_model import (OUT_FIELDS, SUPPORTED, UNSUPPORTED_ITCH, StreamBuilder, make_supported,
                        make_unsupported, random_message)

MOLD = int(os.environ.get("ITCH_MOLD_HDR", "1"))
SEED = int(os.environ.get("ITCH_SEED", "20260927"))
N_RANDOM = int(os.environ.get("ITCH_N_MSGS", "20000"))

SUMMARY: list[str] = []


def u(sig) -> int:
    return int(sig.value)


class Harness:
    def __init__(self, dut):
        self.dut = dut
        self.stats = Counter()

    async def start(self):
        d = self.dut
        cocotb.start_soon(Clock(d.clk, 4, unit="ns").start())  # 250 MHz nominal
        d.rst.value = 1
        d.s_axis_tvalid.value = 0
        d.s_axis_tdata.value = 0
        d.s_axis_tkeep.value = 0
        d.s_axis_tlast.value = 0
        d.m_ready.value = 1
        for _ in range(5):
            await RisingEdge(d.clk)
        await FallingEdge(d.clk)
        d.rst.value = 0

    def read_msg(self) -> dict:
        d = self.dut
        return {f: u(getattr(d, "m_" + f)) for f in OUT_FIELDS}

    async def run(self, sb: StreamBuilder, rng: random.Random, p_valid=1.0, p_ready=1.0,
                  name="", check_counters: dict | None = None, expect_no_stall=False):
        d = self.dut
        beats = sb.beats
        bi = 0
        driving = False
        cycle = 0
        got, got_early, got_hdr = [], [], []
        first_seen: list[int] = []
        pending_new = True
        accept_cycle: dict[int, int] = {}
        early_accept: dict[int, int] = {}
        early_seen: list[int] = []
        in_beats = 0
        stall_cycles = 0  # cycles where tvalid=1 but tready=0
        drain = 0
        max_cycles = 50 * len(beats) + 1000
        c0 = {k: u(getattr(d, k)) for k in ("cnt_pkts", "cnt_msgs", "cnt_skipped", "cnt_err_len",
                                             "cnt_err_short", "cnt_err_trunc", "cnt_err_count")}
        while True:
            await FallingEdge(d.clk)
            if not driving and bi < len(beats) and rng.random() < p_valid:
                b = beats[bi]
                d.s_axis_tdata.value = b.data
                d.s_axis_tkeep.value = b.keep
                d.s_axis_tlast.value = b.last
                d.s_axis_tvalid.value = 1
                driving = True
            elif not driving:
                # Idle: put junk on the bus to prove the DUT ignores it.
                d.s_axis_tvalid.value = 0
                d.s_axis_tdata.value = rng.getrandbits(64)
                d.s_axis_tkeep.value = rng.getrandbits(8)
                d.s_axis_tlast.value = rng.getrandbits(1)
            m_ready = 1 if rng.random() < p_ready else 0
            d.m_ready.value = m_ready

            await ReadOnly()
            in_fire = driving and u(d.s_axis_tready) == 1
            if driving and not in_fire:
                stall_cycles += 1
            mv = u(d.m_valid)
            if mv and pending_new:
                first_seen.append(cycle)
                pending_new = False
            if mv and m_ready:
                got.append(self.read_msg())
                pending_new = True
            if u(d.e_valid):
                got_early.append((u(d.e_msg_type), u(d.e_stock_locate), u(d.e_order_ref)))
                early_seen.append(cycle)
            if u(d.hdr_valid):
                got_hdr.append((u(d.hdr_session), u(d.hdr_seq_num), u(d.hdr_msg_count)))
            if in_fire:
                for idx in beats[bi].ends:
                    accept_cycle[idx] = cycle
                for idx in beats[bi].early:
                    early_accept[idx] = cycle
                bi += 1
                in_beats += 1
                driving = False

            await RisingEdge(d.clk)
            cycle += 1
            if bi == len(beats) and not driving and len(got) >= len(sb.expected):
                drain += 1
                if drain > 8:
                    break
            assert cycle < max_cycles, f"{name}: timeout (got {len(got)}/{len(sb.expected)} msgs)"

        # --- Scoreboard -------------------------------------------------------
        assert len(got) == len(sb.expected), f"{name}: got {len(got)} msgs, expected {len(sb.expected)}"
        mism = 0
        for i, (g, e) in enumerate(zip(got, sb.expected)):
            if g != e:
                mism += 1
                if mism <= 5:
                    diffs = {k: (hex(g[k]), hex(e[k])) for k in OUT_FIELDS if g[k] != e[k]}
                    d._log.error("%s: msg %d type %s mismatch (got, exp): %s", name, i, chr(e["msg_type"]), diffs)
        assert mism == 0, f"{name}: {mism} field mismatches"
        assert got_early == sb.expected_early, f"{name}: early strobe mismatch ({len(got_early)} vs {len(sb.expected_early)})"
        if MOLD:
            assert got_hdr == sb.expected_hdrs, f"{name}: MoldUDP64 header mismatch ({len(got_hdr)} vs {len(sb.expected_hdrs)})"

        lat = Counter(first_seen[i] - accept_cycle[i] for i in range(len(sb.expected)))
        elat = Counter(early_seen[i] - early_accept[i] for i in range(len(sb.expected_early)))
        # With a free output register the latency must be exactly 1 cycle; if the output
        # register was still occupied, the input was stalled so the beat was not accepted.
        assert set(lat) <= {1}, f"{name}: unexpected msg latency histogram {dict(lat)}"
        assert set(elat) <= {1}, f"{name}: unexpected early latency histogram {dict(elat)}"

        if expect_no_stall:
            assert stall_cycles == 0, f"{name}: {stall_cycles} input stall cycles at full rate"
        c1 = {k: u(getattr(d, k)) - v for k, v in c0.items()}
        exp_c = {"cnt_pkts": sb.n_frames, "cnt_msgs": len(sb.expected)}
        if check_counters is None:
            exp_c.update(cnt_skipped=sb.n_unsupported, cnt_err_len=0, cnt_err_short=0,
                         cnt_err_trunc=0, cnt_err_count=0)
        else:
            exp_c.update(check_counters)
        for k, v in exp_c.items():
            assert c1[k] == v, f"{name}: counter {k} = {c1[k]}, expected {v}"

        types = Counter(chr(e["msg_type"]) for e in sb.expected)
        line = (f"{name}: PASS  frames={sb.n_frames} blocks={sb.n_blocks} decoded={len(got)} "
                f"skipped={c1['cnt_skipped']} early={len(got_early)} hdrs={len(got_hdr)} "
                f"beats={in_beats} stalls={stall_cycles} cycles={cycle} bytes={sb.n_bytes} "
                f"latency_cycles={dict(lat)} early_latency={dict(elat)} types={dict(sorted(types.items()))}")
        d._log.info(line)
        SUMMARY.append(line)
        return c1


def build_random(rng: random.Random, n_msgs: int, mold: bool, p_unsup=0.2, max_per_frame=20) -> StreamBuilder:
    sb = StreamBuilder(mold=mold, session=b"%010d" % rng.randrange(10**10), seq=rng.randrange(1, 2**40))
    left = n_msgs
    while left > 0:
        r = rng.random()
        if mold and r < 0.03:
            sb.add_frame([])                      # heartbeat (count = 0)
            continue
        k = min(left, rng.randint(1, max_per_frame))
        sb.add_frame([random_message(rng, p_unsup) for _ in range(k)])
        left -= k
    return sb


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_directed_straddle(dut):
    """Every supported type, starting at every byte lane 0..7 (and so with the length
    prefix and every field straddling beat boundaries in all possible ways), plus
    every undecoded ITCH 5.0 type."""
    h = Harness(dut)
    await h.start()
    rng = random.Random(SEED)
    sb = StreamBuilder(mold=bool(MOLD))
    base = 20 if MOLD else 0
    for t in SUPPORTED:
        for lane in range(8):
            # Filler block (unsupported, >= 7 bytes) shifts the target to start at `lane`.
            filler_len = 7 + ((lane - (base + 9)) % 8)   # block = len + 2
            filler = bytes([ord("R")]) + bytes(rng.getrandbits(8) for _ in range(filler_len - 1))
            msgs = [filler, make_supported(rng, t), make_supported(rng, t)]
            sb.add_frame(msgs)
    # Every undecoded ITCH type at its spec length, back to back
    sb.add_frame([bytes([ord(t)]) + bytes(rng.getrandbits(8) for _ in range(ln - 1))
                  for t, ln in UNSUPPORTED_ITCH.items()] + [make_supported(rng, "A")])
    # All supported types back-to-back in one frame, then with p_valid/p_ready stress
    sb.add_frame([make_supported(rng, t) for t in SUPPORTED] * 4)
    await h.run(sb, rng, name="directed_straddle", expect_no_stall=True)


@cocotb.test()
async def test_line_rate(dut):
    """No gaps, no backpressure: the parser must accept one beat every clock."""
    h = Harness(dut)
    await h.start()
    rng = random.Random(SEED + 1)
    sb = build_random(rng, 2000, bool(MOLD), p_unsup=0.1)
    await h.run(sb, rng, p_valid=1.0, p_ready=1.0, name="line_rate", expect_no_stall=True)


@cocotb.test()
async def test_random_backpressure(dut):
    """Thousands of random messages with random tvalid gaps and m_ready backpressure."""
    h = Harness(dut)
    await h.start()
    rng = random.Random(SEED + 2)
    per = N_RANDOM // 4
    for i, (pv, pr) in enumerate([(0.9, 0.9), (0.5, 0.7), (0.8, 0.3), (1.0, 0.95)]):
        sb = build_random(rng, per, bool(MOLD))
        await h.run(sb, rng, p_valid=pv, p_ready=pr, name=f"random[p_valid={pv},p_ready={pr}]")


@cocotb.test()
async def test_errors_and_recovery(dut):
    """Wrong-length supported types, short lengths, truncated frames and (Mold) count
    mismatches must be flagged, and the parser must resynchronize on the next frame.
    Good messages that precede a corrupt block in the same frame are still decoded."""
    h = Harness(dut)
    await h.start()
    rng = random.Random(SEED + 3)
    sb = StreamBuilder(mold=bool(MOLD))
    exp = dict(cnt_skipped=0, cnt_err_len=0, cnt_err_short=0, cnt_err_trunc=0, cnt_err_count=0)

    def good(k):
        return [make_supported(rng, rng.choice(list(SUPPORTED))) for _ in range(k)]

    def junk(n):
        return bytes(rng.getrandbits(8) for _ in range(n))

    for _ in range(50):
        sb.add_frame(good(3))
        # 1) supported type with a non-spec length -> skipped, err_len; neighbours decode
        bad = make_supported(rng, rng.choice(list(SUPPORTED))) + junk(rng.randint(1, 5))
        sb.add_frame(good(1) + [bad] + good(1))
        exp["cnt_err_len"] += 1
        # 2) length field < 7 -> framing lost, rest of frame dropped, err_short
        sb.add_frame(good(2), raw_tail=b"\x00" + bytes([rng.randrange(0, 7)]) + junk(rng.randrange(3, 40)))
        exp["cnt_err_short"] += 1
        # 3) frame ends in the middle of a block -> err_trunc
        sb.add_frame(good(1), raw_tail=b"\x00\x24A" + junk(rng.randrange(0, 30)))
        exp["cnt_err_trunc"] += 1
        if MOLD:
            # 4) header message count disagrees with the blocks present -> err_count
            sb.add_frame(good(2), count=5)
            exp["cnt_err_count"] += 1
            # end-of-session packet (count 0xFFFF, no blocks) is legal
            sb.add_frame([], count=0xFFFF)
        sb.add_frame(good(3))
    await h.run(sb, rng, p_valid=0.8, p_ready=0.8, name="errors_and_recovery", check_counters=exp)


@cocotb.test()
async def test_summary(dut):
    """Print a summary of all previous tests."""
    for line in SUMMARY:
        dut._log.info("SUMMARY %s", line)
    total = sum(int(l.split("decoded=")[1].split()[0]) for l in SUMMARY)
    dut._log.info("SUMMARY TOTAL decoded messages checked (MOLD_HDR=%d): %d", MOLD, total)
