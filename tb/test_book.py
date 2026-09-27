"""
cocotb testbench for itch_feed_top (itch_parser -> itch_book).

AXI-Stream MoldUDP64 frames go in. Every book event (the full post-update side book) is
compared against BookModel, a bit-exact mirror of the RTL semantics, together with the
statistics counters. An unbounded IdealBook runs alongside to *measure* how often the
bounded hardware book (LEVELS deep, direct-mapped order table) differs from the true book.
"""
from __future__ import annotations

import os
import random
from collections import Counter

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge

from book_model import BookModel, IdealBook, Market, encode
from itch_model import StreamBuilder, make_supported

SEED = int(os.environ.get("ITCH_SEED", "20260927"))
N_BOOK = int(os.environ.get("ITCH_N_BOOK", "30000"))
LEVELS = int(os.environ.get("ITCH_LEVELS", "8"))
ORD_BITS = int(os.environ.get("ITCH_ORD_BITS", "12"))
NUM_SYMBOLS = int(os.environ.get("ITCH_NUM_SYMBOLS", "256"))
LOCATE_BITS = int(os.environ.get("ITCH_LOCATE_BITS", "14"))

SUMMARY: list[str] = []
STAT_MAP = {"cnt_bk_events": "events", "cnt_unsub": "unsub", "cnt_ord_collide": "collide",
            "cnt_ord_miss": "miss", "cnt_lvl_miss": "lvl_miss", "cnt_lvl_drop": "lvl_drop"}


def u(sig) -> int:
    return int(sig.value)


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    dut.rst.value = 1
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tkeep.value = 0
    dut.s_axis_tlast.value = 0
    dut.cfg_we.value = 0
    dut.cfg_locate.value = 0
    dut.cfg_enable.value = 0
    dut.cfg_slot.value = 0
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    for _ in range(200):                       # memory clear sweep
        await ClockCycles(dut.clk, 1024)
        if u(dut.init_done):
            break
    assert u(dut.init_done), "init sweep did not finish"


async def subscribe(dut, model: BookModel, pairs):
    for loc, slot in pairs:
        await FallingEdge(dut.clk)
        dut.cfg_we.value = 1
        dut.cfg_locate.value = loc
        dut.cfg_enable.value = 1
        dut.cfg_slot.value = slot
        if loc < (1 << LOCATE_BITS):
            model.subscribe(loc, slot)
    await FallingEdge(dut.clk)
    dut.cfg_we.value = 0


def read_event(dut):
    L = LEVELS
    pr, qt = u(dut.bk_price), u(dut.bk_qty)
    return (u(dut.bk_slot), u(dut.bk_side), u(dut.bk_count), u(dut.bk_trunc),
            tuple((pr >> (32 * i)) & 0xFFFFFFFF for i in range(L)),
            tuple((qt >> (32 * i)) & 0xFFFFFFFF for i in range(L)),
            u(dut.bk_msg_type), u(dut.bk_locate), u(dut.bk_timestamp))


async def run_stream(dut, sb: StreamBuilder, model: BookModel, rng: random.Random, p_valid=1.0,
                     name="", ideal: IdealBook | None = None, slot2loc=None):
    """Drive the stream, collect book events, compare with the model."""
    stats0 = {k: u(getattr(dut, k)) for k in STAT_MAP}
    mstats0 = Counter(model.stats)
    msgs0 = u(dut.cnt_msgs)
    book_in0 = u(dut.cnt_book_in)
    # Expected events, tagged with the index of the message that produced them.
    exp_events, exp_src = [], []
    match_top1 = match_topn = 0
    for i, m in enumerate(sb.expected):
        ev = model.process(m)
        if ideal is not None:
            ideal.process(m)
        if ev is not None:
            exp_events.append(ev)
            exp_src.append(i)
            if ideal is not None:
                slot, side, cnt, _, prices, qtys = ev[:6]
                truth = ideal.top(slot2loc[slot], side, LEVELS)
                mine = [(prices[j], qtys[j]) for j in range(cnt)]
                match_topn += mine == truth
                match_top1 += mine[:1] == truth[:1]

    beats = sb.beats
    bi, driving, cycle, drain = 0, False, 0, 0
    accept_cycle: dict[int, int] = {}
    got, got_cycle = [], []
    stalls = 0
    fifo_max = 0
    fifo = getattr(dut, "u_msg_fifo", None)     # internal handle (Verilator --public-flat-rw)
    fifo_level = getattr(fifo, "level", None) if fifo is not None else None
    max_cycles = 20 * len(beats) + 2000
    while True:
        await FallingEdge(dut.clk)
        if not driving and bi < len(beats) and rng.random() < p_valid:
            b = beats[bi]
            dut.s_axis_tdata.value = b.data
            dut.s_axis_tkeep.value = b.keep
            dut.s_axis_tlast.value = b.last
            dut.s_axis_tvalid.value = 1
            driving = True
        elif not driving:
            dut.s_axis_tvalid.value = 0
            dut.s_axis_tdata.value = rng.getrandbits(64)
        await ReadOnly()
        fire = driving and u(dut.s_axis_tready) == 1
        if driving and not fire:
            stalls += 1
        if fifo_level is not None:
            fifo_max = max(fifo_max, u(fifo_level))
        if u(dut.bk_valid):
            got.append(read_event(dut))
            got_cycle.append(cycle)
        if fire:
            for idx in beats[bi].ends:
                accept_cycle[idx] = cycle
            bi += 1
            driving = False
        await RisingEdge(dut.clk)
        cycle += 1
        if bi == len(beats) and not driving:
            drain += 1
            if drain > 16:
                break
        assert cycle < max_cycles, f"{name}: timeout"

    assert u(dut.cnt_msgs) - msgs0 == len(sb.expected), f"{name}: parser message count mismatch"
    # Every decoded message (book-relevant or not) must reach the book exactly once.
    assert u(dut.cnt_book_in) - book_in0 == len(sb.expected), \
        f"{name}: book accepted {u(dut.cnt_book_in) - book_in0} msgs, parser emitted {len(sb.expected)}"
    assert len(got) == len(exp_events), f"{name}: got {len(got)} book events, expected {len(exp_events)}"
    bad = 0
    for i, (g, e) in enumerate(zip(got, exp_events)):
        if g != e:
            bad += 1
            if bad <= 3:
                dut._log.error("%s: event %d mismatch\n got %s\n exp %s", name, i, g, e)
    assert bad == 0, f"{name}: {bad} book event mismatches"
    for k, mk in STAT_MAP.items():
        d_dut = u(getattr(dut, k)) - stats0[k]
        d_mod = model.stats[mk] - mstats0[mk]
        assert d_dut == d_mod, f"{name}: {k} dut={d_dut} model={d_mod}"
    lat = Counter(got_cycle[i] - accept_cycle[exp_src[i]] for i in range(len(got)))
    assert min(lat) >= 4 if lat else True
    st = {mk: model.stats[mk] - mstats0[mk] for mk in STAT_MAP.values()}
    line = (f"{name}: PASS msgs={len(sb.expected)} book_events={len(got)} beats={len(beats)} "
            f"cycles={cycle} input_stalls={stalls} fifo_max={fifo_max if fifo_level is not None else 'n/a'} latency_hist={dict(sorted(lat.items()))} stats={st}")
    if ideal is not None and exp_events:
        line += (f" ideal_match_top1={100.0 * match_top1 / len(exp_events):.2f}%"
                 f" ideal_match_top{LEVELS}={100.0 * match_topn / len(exp_events):.2f}%")
    dut._log.info(line)
    SUMMARY.append(line)
    return lat, stalls


def mk(t, **f):
    return encode(t, f)


@cocotb.test()
async def test_book_directed(dut):
    """Hand-built scenarios with explicit expected values plus model comparison."""
    await start(dut)
    rng = random.Random(SEED)
    model = BookModel(NUM_SYMBOLS, LEVELS, ORD_BITS, LOCATE_BITS)
    LOC, LOC2, UNSUB = 10, 11, 12
    # locate 0 is subscribed so that a message for locate 2**LOCATE_BITS (which must be
    # rejected) would be caught if the table index aliased onto entry 0.
    await subscribe(dut, model, [(LOC, 3), (LOC2, NUM_SYMBOLS - 1), (1 << LOCATE_BITS, 5), (0, 7)])
    B, S = ord("B"), ord("S")
    H = 1 << ORD_BITS
    base = 1_000_000 * H
    msgs = [
        mk("A", stock_locate=LOC, order_ref=base + 1, side=B, shares=100, price=1000_0000),
        mk("A", stock_locate=LOC, order_ref=base + 2, side=B, shares=200, price=1002_0000),
        mk("F", stock_locate=LOC, order_ref=base + 3, side=B, shares=300, price=1001_0000, attribution=b"GSCO"),
        mk("A", stock_locate=LOC, order_ref=base + 4, side=B, shares=50, price=1002_0000),   # joins level
        mk("A", stock_locate=LOC, order_ref=base + 5, side=S, shares=10, price=1003_0000),   # ask side
        mk("E", stock_locate=LOC, order_ref=base + 2, shares=150),                           # partial
        mk("C", stock_locate=LOC, order_ref=base + 2, shares=50, price=999_0000, printable=ord("Y")),  # rest, resting px
        mk("X", stock_locate=LOC, order_ref=base + 3, shares=100),
        mk("D", stock_locate=LOC, order_ref=base + 4),                                        # level 1002 empties
        mk("U", stock_locate=LOC, order_ref=base + 1, new_order_ref=base + 1 + H, shares=70, price=1005_0000),  # same bucket
        mk("A", stock_locate=LOC, order_ref=base + 6, side=B, shares=1, price=1_0000),
        mk("U", stock_locate=LOC, order_ref=base + 6, new_order_ref=base + 3 + H, shares=5, price=2_0000),  # collides with ref 3
        mk("E", stock_locate=LOC, order_ref=base + 3 + H, shares=1),                          # -> order miss
        mk("A", stock_locate=LOC, order_ref=base + 3 + 2 * H, side=B, shares=9, price=3_0000),  # insert collision
        mk("A", stock_locate=UNSUB, order_ref=base + 7, side=B, shares=9, price=3_0000),     # unsubscribed
        mk("A", stock_locate=1 << LOCATE_BITS, order_ref=base + 8, side=B, shares=9, price=3_0000),  # out of table
        mk("E", stock_locate=LOC, order_ref=base + 999, shares=1),                            # unknown order
        make_supported(rng, "S"),
    ]
    # Depth overflow on LOC2 asks: LEVELS + 3 distinct prices, best inserted last.
    for j in range(LEVELS + 3):
        msgs.append(mk("A", stock_locate=LOC2, order_ref=base + 100 + j, side=S, shares=10 + j,
                       price=(500 - j) * 100))
    # Delete the best ask levels so the book drains below the dropped depth
    for j in range(LEVELS + 2, LEVELS - 2, -1):
        msgs.append(mk("D", stock_locate=LOC2, order_ref=base + 100 + j))
    sb = StreamBuilder(mold=True)
    for i in range(0, len(msgs), 5):
        sb.add_frame(msgs[i:i + 5])
    await run_stream(dut, sb, model, rng, name="book_directed")

    # Explicit hand-computed checks on the model (which the DUT just matched event-by-event).
    bid = model.books[(3, 0)]
    assert bid["lv"] == [[1005_0000, 70], [1001_0000, 200]], bid
    assert model.books[(3, 1)]["lv"] == [[1003_0000, 10]]
    asks2 = model.books[(NUM_SYMBOLS - 1, 1)]
    assert asks2["trunc"] == 1
    assert model.stats["unsub"] == 2 and model.stats["collide"] == 2 and model.stats["miss"] == 2, model.stats


@cocotb.test()
async def test_book_random(dut):
    """Long self-consistent random order flow across subscribed and unsubscribed symbols."""
    await start(dut)
    rng = random.Random(SEED + 1)
    model = BookModel(NUM_SYMBOLS, LEVELS, ORD_BITS, LOCATE_BITS)
    locates = rng.sample(range(1, 12000), 48)
    subs = locates[:32]
    slots = rng.sample(range(NUM_SYMBOLS), len(subs))
    await subscribe(dut, model, list(zip(subs, slots)))
    ideal = IdealBook(set(subs))
    mkt = Market(rng, locates, target_live=600)
    sb = StreamBuilder(mold=True, seq=rng.randrange(1, 2**40))
    left = N_BOOK
    while left:
        k = min(left, rng.randint(1, 30))
        sb.add_frame([mkt.next_message() for _ in range(k)])
        left -= k
    await run_stream(dut, sb, model, rng, p_valid=0.9, name="book_random", ideal=ideal,
                     slot2loc=dict(zip(slots, subs)))


@cocotb.test()
async def test_book_line_rate(dut):
    """Back-to-back beats with no idle cycles: measures parser+book throughput and latency."""
    await start(dut)
    rng = random.Random(SEED + 2)
    model = BookModel(NUM_SYMBOLS, LEVELS, ORD_BITS, LOCATE_BITS)
    locates = rng.sample(range(1, 12000), 16)
    await subscribe(dut, model, list(zip(locates, range(16))))
    mkt = Market(rng, locates, target_live=300)
    sb = StreamBuilder(mold=True)
    for _ in range(max(20, N_BOOK // 100)):
        sb.add_frame([mkt.next_message(p_unsupported=0.0) for _ in range(rng.randint(10, 40))])
    _, stalls = await run_stream(dut, sb, model, rng, p_valid=1.0, name="book_line_rate")
    assert stalls == 0, f"book_line_rate: {stalls} input stall cycles"


@cocotb.test()
async def test_book_adversarial_rate(dut):
    """Worst-case message rate at full line rate: back-to-back 14-byte 'S' blocks mixed with
    the shortest book messages (D = 21-byte block), unsubscribed messages and misses.
    The parser->book path must never stall the input."""
    await start(dut)
    rng = random.Random(SEED + 3)
    model = BookModel(NUM_SYMBOLS, LEVELS, ORD_BITS, LOCATE_BITS)
    subs = [100, 101, 102, 103]
    await subscribe(dut, model, list(zip(subs, range(4))))
    B = ord("B")
    ref = 5_000_000
    live = []
    sb = StreamBuilder(mold=True)
    for _ in range(max(20, N_BOOK // 75)):
        frame = []
        for _ in range(rng.randint(20, 60)):
            r = rng.random()
            if r < 0.35:
                frame.append(make_supported(rng, "S"))
            elif r < 0.55 or not live:
                ref += 1
                live.append(ref)
                frame.append(mk("A", stock_locate=rng.choice(subs), order_ref=ref, side=B,
                                shares=100, price=rng.randrange(100, 110) * 100))
            elif r < 0.85:
                frame.append(mk("D", stock_locate=subs[0], order_ref=live.pop(rng.randrange(len(live)))))
            elif r < 0.93:
                frame.append(mk("D", stock_locate=999, order_ref=1))            # unsubscribed
            else:
                frame.append(mk("D", stock_locate=subs[0], order_ref=ref + 10**6))  # miss
        sb.add_frame(frame)
    _, stalls = await run_stream(dut, sb, model, rng, p_valid=1.0, name="book_adversarial_rate")
    assert stalls == 0, f"book_adversarial_rate: {stalls} input stall cycles"


@cocotb.test()
async def test_book_summary(dut):
    for line in SUMMARY:
        dut._log.info("SUMMARY %s", line)
