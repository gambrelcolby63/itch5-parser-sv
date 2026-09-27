# itch-fpga: a low-latency Nasdaq TotalView-ITCH 5.0 parser in SystemVerilog

A synthesizable, vendor-neutral SystemVerilog parser for **Nasdaq TotalView-ITCH 5.0** market data
carried in **MoldUDP64**. It takes a 64-bit AXI4-Stream and produces one fully decoded message per
clock, with a **1-cycle** latency from the last message byte to `m_valid`. The verification is a
Python golden model driving a cocotb testbench, run on both Verilator and Icarus.

This is the first slice of a larger feed-handler project (parser → order book → strategy hooks).

| | |
|---|---|
| Language | SystemVerilog (IEEE 1800-2017 synthesizable subset), no vendor primitives |
| Input | AXI4-Stream, 64-bit `tdata`, `tkeep`, `tvalid`, `tready`, `tlast` |
| Framing | MoldUDP64 packet header (optional, in-line) + message blocks (`len[2]` + message) |
| Throughput | 8 bytes/clock sustained, no bubbles (verified: 0 stall cycles at full rate) |
| Latency | last byte accepted → `m_valid`: **1 clock** (registered output), for every message |
| Early strobe | `e_valid` (type, stock locate, order ref) 1 clock after message byte 18, before the message completes |
| Lint | `verilator --lint-only -Wall`: **0 warnings** (both parameterizations) |
| Verification | cocotb and a Python golden model, ~42k decoded messages per `make test` (Verilator), also passes on Icarus, 10/10 mutants killed |

## Architecture

```
            AXI4-Stream 64b (lane 0 = first wire byte)
                         │
          ┌──────────────▼───────────────────────────────────────────────┐
          │ itch_parser                                                  │
          │                                                              │
          │  nb = popcount-ish(tkeep)       boff_q: offset of lane 0     │
          │  cur_len / rem / cur_ends  ◄──  inside current block         │
          │           │                     (MoldUDP64 header = a fixed  │
          │           ▼                      20-byte "block")            │
          │  ┌─────────────────────┐   ┌──────────────────────────┐      │
          │  │ lane steering       │──►│ block buffer buf_q[0:41] │      │
          │  │ lane i -> boff+i    │   │ (len[2] + 40 B max msg)  │      │
          │  │ next-blk head -> 0.. │   └────────────┬─────────────┘      │
          │  └─────────┬───────────┘                │                    │
          │            └────► merged view (buffer ∪ this beat) ◄─┘       │
          │                          │                                   │
          │        ┌─────────────────┼──────────────────┐                │
          │        ▼                 ▼                  ▼                │
          │   MoldUDP64 hdr     field decode       early decode          │
          │   (session/seq/    (type-indexed       (byte 18 seen:        │
          │    count)           big-endian mux)     type/locate/ref)     │
          │        │                 │                  │                │
          │      [reg]        [output reg, v/r]       [reg]              │
          └────────┼─────────────────┼──────────────────┼────────────────┘
                hdr_valid          m_valid            e_valid
```

**How straddling is handled.** A block-offset counter `boff_q` holds the position of lane 0 of the
incoming beat within the current block (the 2 length bytes count as offsets 0 and 1). Every valid
lane is steered to buffer position `boff_q + lane`. Every ITCH 5.0 message is at least 12 bytes, so a
block is at least 14 bytes and **a beat can contain at most one block boundary**: the tail of the
current block and the head of the next. The design relies on that:

* The tail bytes are merged combinationally with the buffer (the "merged view"), and the complete
  message is decoded and registered on the **same clock edge** that accepts its last byte. So
  there's no extra pipeline stage between the last byte and the output.
* The head of the next block (length bytes and possibly its first message bytes) goes to buffer
  positions 0..7 in the same cycle. It can't collide with the tail positions (proved by the
  minimum-length argument and checked in the directed tests).
* The length prefix may itself be split across beats (`boff_q == 1`). It's reassembled from
  `buf_q[0]` and lane 0.

**MoldUDP64 without a realignment shifter.** The usual approach strips the 20-byte header with a
byte shifter plus a residual register. That delays any byte in lanes 4–7 until the *next* beat
arrives, which is an unbounded wait if the link goes idle. Here the header is treated as a
fixed-length 20-byte "block" in the same offset tracker, so the first message block just starts at
lane 4 and pays no alignment penalty. `MOLD_HDR=0` parses a raw stream of blocks instead.

**Flow control.** The only stall source is the output register:
`s_axis_tready = !m_valid || m_ready`. With `m_ready=1` the parser takes a beat every clock. The
early strobe and header outputs are fire-and-forget pulses.

## Supported messages

Decoded into a normalized `itch_msg_t` (fields that don't apply to a type are driven to 0). Every
type below has Stock Locate (1,2), Tracking Number (3,2) and Timestamp (5,6). Offsets and lengths
are in bytes and big-endian. They were checked against the Nasdaq spec PDF (see
[Spec sources](#spec-sources)).

| Type | Name | Len | Decoded fields (offset, length) |
|---|---|---|---|
| `S` | System Event | 12 | Event Code (11,1) |
| `A` | Add Order – No MPID | 36 | Order Ref (11,8), Buy/Sell (19,1), Shares (20,4), Stock (24,8), Price(4) (32,4) |
| `F` | Add Order – MPID | 40 | as `A` + Attribution (36,4) |
| `E` | Order Executed | 31 | Order Ref (11,8), Executed Shares (19,4), Match Number (23,8) |
| `C` | Order Executed w/ Price | 36 | Order Ref (11,8), Executed Shares (19,4), Match Number (23,8), Printable (31,1), Execution Price (32,4) |
| `X` | Order Cancel | 23 | Order Ref (11,8), Cancelled Shares (19,4) |
| `D` | Order Delete | 19 | Order Ref (11,8) |
| `U` | Order Replace | 35 | Original Order Ref (11,8) → `order_ref`, New Order Ref (19,8), Shares (27,4), Price (31,4) |

All other types (`R H Y L V W K J h P Q B I N O`, and any unknown code) are **skipped using the
block length**, with no decoding and no stall. A supported type whose length field disagrees with
the spec is skipped too, and counted in `cnt_err_len`.

## Latency

Measured by the testbench for **every** decoded message. A "cycle" here is one clock period. The
beat carrying the last byte is accepted at a rising edge, and the output is visible in the next
cycle.

| Output | Trigger | Latency |
|---|---|---|
| `m_valid` + all fields | beat containing the message's last byte accepted | **1 cycle** (all 42,115 messages in `make test`) |
| `e_valid` (type, locate, order ref) | beat containing message byte 18 accepted | **1 cycle**, 0–3 beats *before* `m_valid` depending on type |
| `hdr_valid` (session, seq, count) | beat containing header byte 19 accepted | 1 cycle |

At 156.25 MHz (10GbE, 64-bit), 1 cycle is 6.4 ns. Byte 18 closes the Order Reference Number. In an
Add Order (36 bytes) it arrives 17 bytes before the last byte, so the early strobe leads `m_valid`
by 2–3 beats (12.8–19.2 ns at 156.25 MHz) depending on alignment. That lets a downstream order book
start its hash/lookup early. For Order Delete (19 bytes) byte 18 *is* the last byte, so both fire
together. The early strobe is **speculative**: if the frame is later truncated, the
strobe has already fired and `m_valid` never follows. Consumers must commit only on `m_valid`. The
testbench models and checks this.

## Error handling / robustness

All errors increment a 32-bit counter, and the parser always resynchronizes on the next `tlast`.

| Condition | Behaviour | Counter |
|---|---|---|
| Unsupported type | skipped by length | `cnt_skipped` |
| Supported type, wrong length | skipped by length, neighbours still decoded | `cnt_err_len` |
| Length < 7 (can't be ITCH, framing lost) | rest of frame dropped | `cnt_err_short` |
| `tlast` mid-block or mid-header | block discarded | `cnt_err_trunc` |
| Mold message count ≠ blocks seen | flagged (heartbeat `0` and end-of-session `0xFFFF` are legal) | `cnt_err_count` |

Junk on `tdata`/`tkeep`/`tlast` while `tvalid=0` is ignored. The testbench drives random junk
during every idle cycle.

## Verification

`tb/itch_model.py` is an independent golden model. It builds byte-exact messages from a field
table that mirrors the spec, decodes them back with Python, frames them as MoldUDP64, and packs
them into AXI-Stream beats. `tb/test_itch.py` runs one cycle-accurate cocotb coroutine that drives
random `tvalid` gaps and random `m_ready` backpressure (which propagates to `s_axis_tready`), and
checks:

* every decoded field of every message, in order,
* every early strobe and every MoldUDP64 header,
* the latency of every message and early strobe (it asserts exactly 1 cycle),
* all statistics counters,
* zero input stall cycles when running at full rate.

| Test | What it covers |
|---|---|
| `test_directed_straddle` | each of the 8 types starting at **every byte lane 0–7** (so the length prefix and every field straddle beats in every possible way), plus all 15 undecoded ITCH types at spec length |
| `test_line_rate` | 2,000 random messages, no gaps and no backpressure; asserts 1 beat/clock |
| `test_random_backpressure` | 20,000 random messages over 4 `(p_valid, p_ready)` corners: (0.9,0.9), (0.5,0.7), (0.8,0.3), (1.0,0.95) |
| `test_partial_beats` | 3,000 messages with beats carrying a random 1–8 bytes anywhere in a frame (junk in unused lanes), plus gaps and backpressure |
| `test_errors_and_recovery` | wrong lengths, short lengths, truncated frames, count mismatch, end-of-session, recovery |

Random streams are about 80% supported types (an HFT-like mix: adds, deletes, executes,
replaces...) and about 20% unsupported. The unsupported ones are either real ITCH types at spec
length or synthetic codes of length 7–600 bytes, which exercise long skips. Integer fields are
biased toward 0, all-ones, and single-nonzero-byte values to catch lane swaps.

**Mutation testing** (`make mutation`) injects 10 realistic bugs: wrong field offsets, a truncated
timestamp, off-by-one lane steering, a boundary compare error, a split-length bug, ignored
`tkeep`/`m_ready`, a wrong spec length, and a wrong Mold header size. The regression catches
**10/10**.

### Results (`make test`, seed 20260927)

```
MOLD_HDR=1  TESTS=6 PASS=6 FAIL=0   decoded messages checked: 21,125  (latency histogram {1: 21125})
MOLD_HDR=0  TESTS=6 PASS=6 FAIL=0   decoded messages checked: 20,990  (latency histogram {1: 20990})
line_rate (MOLD_HDR=1): beats=8928 stalls=0 cycles=8937  -> 1 beat/clock (+9 drain cycles)
```

`make soak` (5 seeds × 2 modes × 100k-message configuration) checked **848,951** decoded messages,
10/10 runs with `TESTS=6 PASS=6 FAIL=0`, and every latency histogram exactly `{1: N}`.

The same regression also passes on **Icarus Verilog 12** (`make test-icarus`, 2,000-message
configuration: 6,614 decoded messages, `TESTS=6 PASS=6 FAIL=0`), which gives a two-simulator
cross-check.

## Lint / static analysis

```
$ make lint
verilator --lint-only -Wall -GMOLD_HDR=1 --top-module itch_top rtl/*.sv   -> 0 warnings
verilator --lint-only -Wall -GMOLD_HDR=0 --top-module itch_top rtl/*.sv   -> 0 warnings
```

There are no `lint_off` pragmas anywhere in the RTL.

## Synthesis (Yosys estimates, not vendor place-and-route)

`make synth` converts the RTL with sv2v (Yosys's native SV frontend doesn't accept package imports
in the module header) and runs Yosys 0.52. Configuration: `MOLD_HDR=1`, all statistics counters
included.

| Flow | LUTs | FFs | Other |
|---|---|---|---|
| `synth_xilinx -family xcup` (UltraScale+) | 5,143 LUT cells (Yosys "estimated LCs": 3,796) | 1,326 | 1,073 MUXF7 / 393 MUXF8 / 104 MUXF9, 101 CARRY4 |
| `synth` + `abc -lut 6` (generic) | 2,622 LUT6 | 1,326 | n/a |

About 465 of the flops are the registered output message (`itch_msg_t` is 464 bits). The 42-byte block buffer is 336 flops.
The 7 × 32-bit statistics counters are 224.

**Timing caveat (honest).** Yosys `ltp` on the generic LUT6 netlist reports a longest path of 22
LUT levels. That path is `boff_q` → block-end compare → length-sanity check → a 32-bit stats
counter increment, and the last 8 levels are the counter's ripple carry, an artifact of generic
mapping with no carry chain. Even so, the core `boff_q → rem → cur_ends → lane-steer → decode`
cone is deep for 322 MHz. Closing timing on a real part is the top next step (see below). No Fmax
is claimed here.

## Running it

```bash
./scripts/setup.sh          # apt deps, Verilator 5.052 from source, sv2v, .venv with cocotb 2.x
make lint                   # Verilator -Wall
make test                   # cocotb regression, MoldUDP64 + raw modes (MSGS=20000 SEED=...)
make test-icarus            # same tests on Icarus Verilog
make soak                   # 5 seeds x 2 modes x 100k messages
make mutation               # testbench-strength check
make synth                  # Yosys reports in syn/out/
python tb/run.py --mold 1 --msgs 5000 --waves   # FST waves in build/
```

## Repository layout

```
rtl/itch_pkg.sv        constants, spec lengths, itch_msg_t / mold_hdr_t
rtl/itch_parser.sv     the parser (MOLD_HDR parameter)
rtl/itch_top.sv        flat-port wrapper (sim/synth top)
tb/itch_model.py       golden model: spec tables, generators, MoldUDP64 + AXIS packing
tb/test_itch.py        cocotb tests + scoreboard + latency measurement
tb/run.py              cocotb runner (Verilator or Icarus)
scripts/setup.sh       toolchain setup
scripts/mutation_test.py  mutation testing
syn/*.ys               Yosys scripts
```

## Limitations / shortcuts in this slice

* `tkeep` must be contiguous from lane 0. Standard packed AXIS is fine, and partial beats are
  allowed anywhere, not just on `tlast` (covered by `test_partial_beats`). Non-contiguous `tkeep`
  isn't supported.
* Messages shorter than 7 bytes are treated as framing errors. ITCH 5.0's shortest message is 12
  bytes, but generic MoldUDP64 allows 0-length blocks.
* A message block may not span two MoldUDP64 packets, which matches the MoldUDP64 spec. `tlast`
  mid-block is an error.
* The early strobe is speculative (see Latency).
* No sequence-gap detection or retransmit request yet. The header is only reported.
* Synthesis numbers are Yosys estimates. They haven't been through Vivado/Quartus or timing closure.
* Stock/MPID fields are output as raw ASCII (space padded), and prices as raw Price(4) integers.

## Next steps

1. **Timing closure on a real part** (e.g. Alveo U55C / VU9P, or Agilex): Vivado OOC run and a
   real Fmax. Then shorten the critical cone by precomputing `rem`/`cur_ends` for the next beat
   from `boff_q + nb` (known a cycle early except when the length straddles), registering the
   stats-counter enables, and optionally moving to a 2-stage version with an explicit latency
   knob.
2. **Order book**: an `order_ref` → (locate, side, price, shares) table in URAM/BRAM with
   hash-based lookup kicked off by the early strobe, and per-symbol top-of-book (price levels)
   with best-bid/offer change events.
3. **MoldUDP64 session layer**: sequence tracking (`seq + count`), gap detection, heartbeat and
   end-of-session handling, and hooks for a retransmit (request-server) path and A/B feed
   arbitration.
4. **Network front end**: an Ethernet/IPv4/UDP header stripper with multicast group filter in
   front of the parser, and a 10G/25G MAC integration example.
5. **Formal**: SymbiYosys properties (no message lost/duplicated, `boff_q` invariants,
   AXIS-compliance of `s_axis_tready`), plus functional coverage (types × start lane ×
   backpressure).
6. **Replay**: feed real Nasdaq ITCH sample files (from `emi.nasdaq.com`) through the model
   and the DUT.

## Spec sources

* Nasdaq TotalView-ITCH 5.0 specification:
  <https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHspecification.pdf>
  (PDF dated 2024-02-28). Checked: data types (big-endian unsigned integers, space-padded alpha,
  Price(4) with max 200,000.0000 = `0x77359400`, ns-since-midnight timestamps); field
  offsets/lengths for S (§1.1), A/F (§1.3.1–1.3.2), E/C/X/D/U (§1.4.1–1.4.5); and the lengths of
  every other message type, which the testbench uses to skip them.
* MoldUDP64 protocol specification:
  <https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/moldudp64.pdf>.
  Checked: header Session(10) @0, Sequence Number(8) @10, Message Count(2) @18; message block =
  2-byte big-endian length (excluding itself) + data; count 0 = heartbeat, 0xFFFF = end of session.
