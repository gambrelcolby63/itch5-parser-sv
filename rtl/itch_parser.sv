// -----------------------------------------------------------------------------
// itch_parser.sv
//
// Nasdaq TotalView-ITCH 5.0 message parser, 64-bit AXI4-Stream in, one decoded
// message per clock out.
//
// Input framing
//   * Byte lane i is s_axis_tdata[8*i +: 8]; lane 0 is the first byte on the wire.
//   * tkeep must be contiguous from lane 0 (normally all ones except the tlast beat).
//     Partial beats are allowed anywhere, and a tlast beat may carry no bytes
//     (tkeep = 0). Non-contiguous tkeep is not supported and not detected (the parser
//     reads tkeep as a thermometer code); the next tlast resynchronizes.
//   * The payload is a sequence of MoldUDP64 message blocks:
//       [len_hi][len_lo][len bytes of ITCH message]
//   * MOLD_HDR = 1: every packet (tlast-delimited) starts with the 20-byte MoldUDP64
//     header (session 10, sequence 8, message count 2), which is parsed in-line and
//     reported on hdr/hdr_valid. There is no realignment shifter: the header is treated
//     as a fixed-length "block", so the first message block simply starts at lane 4.
//   * MOLD_HDR = 0: the stream is raw message blocks; tlast just resynchronizes.
//
// Architecture: three logical stages, with optional registers between them
//
//   S1 frame tracker   The only per-beat feedback loop. State is rem_q (bytes of the
//                      current block still to come), so "does the block end in this
//                      beat, and at which lane" is tkeep indexed by a register (tkeep is
//                      a thermometer code), not encode -> add -> subtract -> compare.
//                      Length arithmetic only feeds the next-state registers, and is split
//                      so the wide part does not wait for the byte count.
//   S2 assemble        One shared 8-lane rotator steers the beat into a 42-byte block
//                      buffer at the block offset, and builds the merged view (buffer plus
//                      this beat). Every ITCH block is >= 9 bytes, so a beat holds at most
//                      one block boundary: the tail of the current block (merged view) and
//                      the head of the next (written to buffer positions 0..7).
//   S3 decode          Type decode, spec-length check, field extraction, MoldUDP64 header,
//                      early strobe, packet checks, and the registered outputs.
//
//   PIPE_STAGES = 0    S1 -> S2 -> S3 combinational          latency 1 (last byte -> m_valid)
//   PIPE_STAGES = 1    register between S1 and S2           latency 2
//   PIPE_STAGES = 2    registers between S1/S2 and S2/S3    latency 3
//   Throughput is one 8-byte beat per clock in every configuration.
//
// Latency (clock edges on which the pipeline advances; with m_ready high that is every
// clock)
//   * m_valid     : 1 + PIPE_STAGES after the edge that accepts the message's last byte.
//   * e_valid     : early strobe (type, stock locate, order ref), 1 + PIPE_STAGES after
//                   the edge that accepts message byte 18, before the message completes.
//   * hdr_valid   : 1 + PIPE_STAGES after the edge that accepts MoldUDP64 header byte 19.
//   * counters    : one cycle after the corresponding output (event pulses are
//                   registered, and each counter is a stat_counter with registered
//                   segment carries, so no 32-bit carry chain follows the decode logic).
//
// Flow control
//   One advance enable for the whole pipeline: adv = !m_valid | m_ready, and
//   s_axis_tready = adv. When the output register is full and not being read, every
//   stage holds. With m_ready held high the parser accepts one beat per clock.
//
// Error handling (each error pulses a counter; the parser always recovers on tlast)
//   * Supported type with a length that disagrees with the spec -> skipped, cnt_err_len.
//   * Message length < MIN_MSG_LEN -> framing lost, drop until tlast, cnt_err_short.
//   * tlast in the middle of a block/header -> cnt_err_trunc.
//   * MoldUDP64 message count != blocks seen -> cnt_err_count (count 0xFFFF = end of
//     session and 0 = heartbeat are accepted with no blocks).
// -----------------------------------------------------------------------------
`default_nettype none

module itch_parser
  import itch_pkg::*;
#(
  parameter bit          MOLD_HDR    = 1'b1,
  parameter int unsigned PIPE_STAGES = 0      // 0, 1 or 2 (see above); larger values act as 2
) (
  input  wire logic        clk,
  input  wire logic        rst,

  // AXI4-Stream slave
  input  wire logic [63:0] s_axis_tdata,
  input  wire logic [7:0]  s_axis_tkeep,
  input  wire logic        s_axis_tvalid,
  output logic             s_axis_tready,
  input  wire logic        s_axis_tlast,

  // Decoded message (valid/ready)
  output itch_msg_t        m_msg,
  output logic             m_valid,
  input  wire logic        m_ready,

  // Early order-reference strobe (no backpressure, 1-cycle pulse)
  output logic             e_valid,
  output logic [7:0]       e_msg_type,
  output logic [15:0]      e_stock_locate,
  output logic [63:0]      e_order_ref,

  // MoldUDP64 header (1-cycle pulse per packet, only when MOLD_HDR = 1)
  output logic             hdr_valid,
  output mold_hdr_t        hdr,

  // Statistics
  output logic [31:0]      cnt_pkts,
  output logic [31:0]      cnt_msgs,
  output logic [31:0]      cnt_skipped,
  output logic [31:0]      cnt_err_len,
  output logic [31:0]      cnt_err_short,
  output logic [31:0]      cnt_err_trunc,
  output logic [31:0]      cnt_err_count
);

  localparam int unsigned BW = 17;             // bytes remaining in a block (max 65535 + 2)
  localparam int unsigned VW = 8 * BUF_BYTES;  // merged-view vector width

  // Per-beat record passed from S1 to S2
  typedef struct packed {
    logic        v;            // a beat was accepted
    logic        live;         // ... and the parser is not dropping the rest of the packet
    logic        last;
    logic        in_hdr;       // lane 0 belongs to the MoldUDP64 header
    logic [63:0] data;
    logic [7:0]  lane_ok;      // lanes that carry bytes of the current block
    logic [5:0]  boff;         // block offset of lane 0 (saturates at 63)
    logic        cur_ends;     // the current block (or header) ends in this beat ...
    logic [3:0]  tail;         // ... after this many lanes
    logic [7:0]  nxt_mask;     // bytes of the next block, as a mask from lane `tail`
    logic [7:0]  len_hit;      // current block length == spec length of type i
    logic        cur_short;    // length error on the current block
    logic        nxt_short;    // length error on the next block
    logic        clean_end;    // tlast here would end the packet on a block boundary
  } trk_t;

  // Per-beat record passed from S2 to S3
  typedef struct packed {
    logic          v;
    logic          live;
    logic          last;
    logic          in_hdr;
    logic [VW-1:0] mvp;        // merged view of the current block, big-endian packed
    logic          we20;       // this beat writes block offset 20 (message byte 18)
    logic          cur_ends;
    logic [7:0]    len_hit;
    logic          cur_short;
    logic          nxt_short;
    logic          clean_end;
  } view_t;

  // ---------------------------------------------------------------------------
  // Flow control
  // ---------------------------------------------------------------------------
  logic adv, fire;
  assign adv           = !m_valid || m_ready;
  assign s_axis_tready = adv;
  assign fire          = s_axis_tvalid && adv;

  // ===========================================================================
  // S1: frame tracker
  // ===========================================================================
  logic [7:0] lane [0:BEAT_BYTES-1];
  logic [3:0] nb;

  always_comb begin
    nb = 4'd0;
    for (int i = 0; i < BEAT_BYTES; i++) begin
      lane[i] = s_axis_tdata[8*i +: 8];
      if (s_axis_tkeep[i]) nb = 4'(i + 1);
    end
  end

  // Tracker state. Exactly one of these describes lane 0 of the next beat:
  //   at_start_q            a new block starts at lane 0 (rem_q = 0)
  //   len1_q                one length byte (len_hi_q) seen; lane 0 is the low byte
  //   otherwise             rem_q (>= 1) bytes of the current block/header remain
  logic [BW-1:0] rem_q;
  logic          at_start_q;
  logic          len1_q;
  logic [7:0]    len_hi_q;
  logic [15:0]   len_q;       // length of the current block
  logic [5:0]    boff_q;      // block offset of lane 0, saturating (only < 42 matters)
  logic          hdr_q;       // in the MoldUDP64 header
  logic          drop_q;      // framing lost, discard until tlast

  // tkeep is contiguous from lane 0, so "at least n valid bytes" is simply tkeep[n-1]:
  // every per-beat decision below is a small mux of tkeep indexed by a register, rather
  // than priority-encode -> subtract -> compare. The binary byte count nb only feeds the
  // arithmetic that updates the tracker's own registers.
  logic [15:0]   keep;        // keep[i]: the beat has more than i bytes (0 beyond lane 7)
  logic          in_hdr, live, hi_zero, bnd, end_len1, cur_ends, nxt_present;
  logic          k_ge2, k_eq0, k_eq1;
  logic          cur_short, nxt_short, clean_end;
  logic [3:0]    r, tail, k;
  logic [15:0]   len_f, len_l, cur_len;
  logic [7:0]    nxt_mask;
  logic [7:0]    short_at;    // short_at[i]: a length field at lanes i, i+1 would be < MIN

  // Compare every candidate length position straight from tdata, in parallel with the
  // tracker; the tracker only selects one flag. (Lane 7 pairs with lane 0; that entry is
  // never selected, because a length field starting at lane 7 is split across beats.)
  always_comb begin
    for (int i = 0; i < BEAT_BYTES; i++) begin
      short_at[i] = ({s_axis_tdata[8*i +: 8], s_axis_tdata[8*((i + 1) % BEAT_BYTES) +: 8]}
                     < 16'(MIN_MSG_LEN));
    end
  end

  always_comb begin
    keep     = {8'h00, s_axis_tkeep};
    in_hdr   = MOLD_HDR && hdr_q;
    live     = fire && !drop_q;

    // Block boundary in this beat at lane r (r = 0 when a block starts at lane 0):
    // rem_q <= nb.
    r        = rem_q[3:0];
    hi_zero  = (rem_q[BW-1:4] == '0);
    bnd      = !len1_q && hi_zero && ((r == 4'd0) || keep[4'(r - 4'd1)]);
    k        = nb - r;                                   // next block's bytes (if bnd)
    k_ge2    = keep[4'(r + 4'd1)];
    k_eq1    = keep[r] && !keep[4'(r + 4'd1)];
    k_eq0    = !keep[r];
    len_f    = {lane[r[2:0]], lane[3'(r[2:0] + 3'd1)]};  // next block's length (k >= 2)
    len_l    = {len_hi_q, lane[0]};                      // completes a split length

    // A block whose length was split across beats can end at the end of this beat only
    // if it is 9 bytes long (len 7) and the beat is full.
    end_len1    = len1_q && keep[7] && (len_l == 16'd7);
    cur_ends    = (bnd && !at_start_q) || end_len1;
    tail        = len1_q ? 4'd8 : r;
    nxt_present = cur_ends && keep[tail];
    for (int j = 0; j < BEAT_BYTES; j++) nxt_mask[j] = nxt_present && keep[4'(tail + 4'(j))];
    cur_len     = len1_q ? len_l : len_q;

    cur_short = live && !in_hdr &&
                ((at_start_q && keep[1] && short_at[0]) ||
                 (len1_q     && keep[0] && (len_l < 16'(MIN_MSG_LEN))));
    nxt_short = live && bnd && !at_start_q && k_ge2 && short_at[r[2:0]];
    clean_end = cur_ends ? !nxt_present : (!keep[0] && at_start_q && !in_hdr);
  end

  // x - d for a small d (0..8), split so the long part does not wait for d: the low
  // nibble subtracts d, and its borrow only selects between x_hi and x_hi - 1, both of
  // which depend on x alone. d is derived from tkeep, x from registers or tdata lanes,
  // so the wide decrement runs in parallel with the byte count.
  function automatic logic [BW-1:0] sub_small(input logic [BW-1:0] x, input logic [3:0] d);
    logic [4:0]    lo;
    logic [BW-5:0] hi;
    lo = {1'b0, x[3:0]} - {1'b0, d};
    hi = x[BW-1:4];
    return {lo[4] ? hi - (BW-4)'(1) : hi, lo[3:0]};
  endfunction

  // Next state. While dropping (drop_q) the state is don't-care: nothing is reported
  // and tlast reinitializes everything.
  logic [BW-1:0] rem_d;
  logic          at_start_d, len1_d, hdr_d, drop_d;
  logic [7:0]    len_hi_d;
  logic [15:0]   len_d;
  logic [5:0]    boff_d;
  logic [6:0]    boff_sum;

  always_comb begin
    rem_d      = rem_q;
    at_start_d = at_start_q;
    len1_d     = len1_q;
    len_hi_d   = len_hi_q;
    len_d      = len_q;
    boff_d     = boff_q;
    hdr_d      = hdr_q;
    drop_d     = drop_q || cur_short || nxt_short;
    boff_sum   = 7'(boff_q) + 7'(nb);
    if (s_axis_tlast) begin
      rem_d      = MOLD_HDR ? BW'(MOLD_HDR_BYTES) : '0;
      at_start_d = !MOLD_HDR;
      len1_d     = 1'b0;
      boff_d     = '0;
      hdr_d      = MOLD_HDR;
      drop_d     = 1'b0;
    end else if (len1_q) begin
      if (keep[0]) begin                                 // length completes at lane 0
        len1_d     = 1'b0;
        len_d      = len_l;
        rem_d      = sub_small(BW'(len_l), nb - 4'd1);  // len+2-(nb+1); 0 iff end_len1
        at_start_d = end_len1;
        boff_d     = end_len1 ? 6'd0 : 6'(nb) + 6'd1;
      end
    end else if (bnd) begin                              // block/header ends at lane r
      hdr_d      = 1'b0;
      at_start_d = k_eq0;
      len1_d     = k_eq1;
      len_hi_d   = lane[r[2:0]];
      boff_d     = 6'(k);
      rem_d      = '0;
      if (k_ge2) begin
        len_d = len_f;
        rem_d = sub_small(BW'(len_f), k - 4'd2);       // len + 2 - k
      end
    end else begin                                       // block continues
      rem_d  = sub_small(rem_q, nb);
      boff_d = boff_sum[6] ? 6'h3F : boff_sum[5:0];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      rem_q      <= MOLD_HDR ? BW'(MOLD_HDR_BYTES) : '0;
      at_start_q <= !MOLD_HDR;
      len1_q     <= 1'b0;
      len_hi_q   <= '0;
      len_q      <= '0;
      boff_q     <= '0;
      hdr_q      <= MOLD_HDR;
      drop_q     <= 1'b0;
    end else if (fire) begin
      rem_q      <= rem_d;
      at_start_q <= at_start_d;
      len1_q     <= len1_d;
      len_hi_q   <= len_hi_d;
      len_q      <= len_d;
      boff_q     <= boff_d;
      hdr_q      <= hdr_d;
      drop_q     <= drop_d;
    end
  end

  trk_t       t1, t2;
  logic [7:0] lane_ok;
  always_comb begin
    for (int i = 0; i < BEAT_BYTES; i++) begin
      lane_ok[i] = keep[i] && (!cur_ends || (4'(i) < tail));
    end
  end

  always_comb begin
    t1.v           = fire;
    t1.live        = live;
    t1.last        = s_axis_tlast;
    t1.in_hdr      = in_hdr;
    t1.data        = s_axis_tdata;
    t1.lane_ok     = lane_ok;
    t1.boff        = boff_q;
    t1.cur_ends    = cur_ends;
    t1.tail        = tail;
    t1.nxt_mask    = nxt_mask;
    t1.len_hit     = len_match(cur_len);
    t1.cur_short   = cur_short;
    t1.nxt_short   = nxt_short;
    t1.clean_end   = clean_end;
  end

  if (PIPE_STAGES >= 1) begin : g_s1_reg
    always_ff @(posedge clk) begin
      if (rst)      t2.v <= 1'b0;
      else if (adv) t2.v <= t1.v;
      if (adv) t2[$bits(trk_t)-2:0] <= t1[$bits(trk_t)-2:0];
    end
  end else begin : g_s1_wire
    assign t2 = t1;
  end

  // ===========================================================================
  // S2: assemble (lane steering, block buffer, merged view)
  // ===========================================================================
  logic [7:0]            lane2   [0:BEAT_BYTES-1];
  logic [7:0]            rot     [0:BEAT_BYTES-1];   // lane (j - boff) mod 8
  logic [BEAT_BYTES-1:0] rot_ok;
  logic [7:0]            rot_nxt [0:BEAT_BYTES-1];   // lane (j + tail) mod 8
  logic [BUF_BYTES-1:0]  cur_we;
  logic [BEAT_BYTES-1:0] nxt_we;
  logic [7:0]            buf_q   [0:BUF_BYTES-1];    // block buffer, indexed by block offset
  logic [VW-1:0]         mvp;

  // Plain-vector copies of the S2 record fields that are indexed by variables below
  // (Icarus 12 does not support variable selects of packed-struct members).
  logic [63:0]           data2;
  logic [BEAT_BYTES-1:0] lane_ok2;
  logic [5:0]            boff2;
  logic [2:0]            tail2;
  assign data2    = t2.data;
  assign lane_ok2 = t2.lane_ok;
  assign boff2    = t2.boff;
  assign tail2    = t2.tail[2:0];
  assign nxt_we   = t2.nxt_mask;

  always_comb begin
    for (int i = 0; i < BEAT_BYTES; i++) begin
      lane2[i]   = data2[8*i +: 8];
    end
    // Block offset p takes lane (p - boff), which is rot[p mod 8] when 0 <= p - boff < 8.
    for (int j = 0; j < BEAT_BYTES; j++) begin
      rot[j]     = lane2[3'(3'(j) - boff2[2:0])];
      rot_ok[j]  = lane_ok2[3'(3'(j) - boff2[2:0])];
      rot_nxt[j] = lane2[3'(3'(j) + tail2)];
    end
    for (int p = 0; p < BUF_BYTES; p++) begin
      cur_we[p] = (7'(boff2) <= 7'(p)) && (7'(p) < 7'(boff2) + 7'd8) && rot_ok[p % BEAT_BYTES];
      mvp[VW - 1 - 8*p -: 8] = cur_we[p] ? rot[p % BEAT_BYTES] : buf_q[p];
    end
  end

  // No reset needed: every position is written before it is read.
  always_ff @(posedge clk) begin
    if (adv && t2.v) begin
      for (int p = 0; p < BUF_BYTES; p++) begin
        if (cur_we[p]) begin
          buf_q[p] <= rot[p % BEAT_BYTES];
        end else if ((p < BEAT_BYTES) && nxt_we[p % BEAT_BYTES]) begin
          buf_q[p] <= rot_nxt[p % BEAT_BYTES];
        end
      end
    end
  end

  view_t v2, v3;
  always_comb begin
    v2.v         = t2.v;
    v2.live      = t2.live;
    v2.last      = t2.last;
    v2.in_hdr    = t2.in_hdr;
    v2.mvp       = mvp;
    v2.we20      = cur_we[20];
    v2.cur_ends  = t2.cur_ends;
    v2.len_hit   = t2.len_hit;
    v2.cur_short = t2.cur_short;
    v2.nxt_short = t2.nxt_short;
    v2.clean_end = t2.clean_end;
  end

  if (PIPE_STAGES >= 2) begin : g_s2_reg
    always_ff @(posedge clk) begin
      if (rst)      v3.v <= 1'b0;
      else if (adv) v3.v <= v2.v;
      if (adv) v3[$bits(view_t)-2:0] <= v2[$bits(view_t)-2:0];
    end
  end else begin : g_s2_wire
    assign v3 = v2;
  end

  // ===========================================================================
  // S3: decode. Message byte m lives at block offset m + 2; header byte h at h.
  // ===========================================================================
  // The merged view as a plain vector: field extraction indexes mv3 rather than v3.mvp
  // (Icarus 12 aborts on an indexed part-select of a packed-struct member).
  logic [VW-1:0] mv3;
  assign mv3 = v3.mvp;
  `define ITCH_FLD(off, nbytes) mv3[VW - 1 - 8*((off) + 2) -: 8*(nbytes)]
  `define MOLD_FLD(off, nbytes) mv3[VW - 1 - 8*(off) -: 8*(nbytes)]

  logic [7:0]  msg_type;
  logic [7:0]  type_oh;
  logic        supported, len_ok;
  itch_msg_t   dec;
  mold_hdr_t   hdr_dec;

  assign msg_type          = `ITCH_FLD(0, 1);
  assign type_oh           = type_onehot(msg_type);
  assign supported         = |type_oh;
  assign len_ok            = |(type_oh & v3.len_hit);
  assign hdr_dec.session   = `MOLD_FLD(0, 10);
  assign hdr_dec.seq_num   = `MOLD_FLD(10, 8);
  assign hdr_dec.msg_count = `MOLD_FLD(18, 2);

  always_comb begin
    dec              = '0;
    dec.msg_type     = msg_type;
    dec.stock_locate = `ITCH_FLD(1, 2);
    dec.tracking_num = `ITCH_FLD(3, 2);
    dec.timestamp    = `ITCH_FLD(5, 6);
    case (msg_type)
      MT_SYSTEM_EVENT: begin
        dec.event_code    = `ITCH_FLD(11, 1);
      end
      MT_ADD_ORDER, MT_ADD_ORDER_MPID: begin
        dec.order_ref     = `ITCH_FLD(11, 8);
        dec.side          = `ITCH_FLD(19, 1);
        dec.shares        = `ITCH_FLD(20, 4);
        dec.stock         = `ITCH_FLD(24, 8);
        dec.price         = `ITCH_FLD(32, 4);
        if (msg_type == MT_ADD_ORDER_MPID) dec.attribution = `ITCH_FLD(36, 4);
      end
      MT_ORDER_EXECUTED: begin
        dec.order_ref     = `ITCH_FLD(11, 8);
        dec.shares        = `ITCH_FLD(19, 4);
        dec.match_number  = `ITCH_FLD(23, 8);
      end
      MT_ORDER_EXECUTED_PX: begin
        dec.order_ref     = `ITCH_FLD(11, 8);
        dec.shares        = `ITCH_FLD(19, 4);
        dec.match_number  = `ITCH_FLD(23, 8);
        dec.printable     = `ITCH_FLD(31, 1);
        dec.price         = `ITCH_FLD(32, 4);
      end
      MT_ORDER_CANCEL: begin
        dec.order_ref     = `ITCH_FLD(11, 8);
        dec.shares        = `ITCH_FLD(19, 4);
      end
      MT_ORDER_DELETE: begin
        dec.order_ref     = `ITCH_FLD(11, 8);
      end
      MT_ORDER_REPLACE: begin
        dec.order_ref     = `ITCH_FLD(11, 8);
        dec.new_order_ref = `ITCH_FLD(19, 8);
        dec.shares        = `ITCH_FLD(27, 4);
        dec.price         = `ITCH_FLD(31, 4);
      end
      default: ;
    endcase
  end

  // MoldUDP64 message-count check. blk_left_q counts down from the header's message
  // count as blocks end, so the check at tlast is a compare against 0 (or 1 if a block
  // ends in the tlast beat) instead of increment -> mux -> 16-bit compare.
  // eos_q: the header announced 0xFFFF (end of session) and no block has ended since.
  logic [15:0] blk_left_q;
  logic        eos_q;

  // Event conditions for the beat in S3; each is qualified by `go` at the very end.
  logic go;
  logic hdr_end_c, blk_end_c, emit_c, skip_c, bad_len_c, len_err_c, early_c, trunc_c;
  logic count_bad, cnt_err_c;
  logic hdr_end, emit, early_hit;

  always_comb begin
    hdr_end_c = v3.live && v3.in_hdr && v3.cur_ends;
    blk_end_c = v3.live && !v3.in_hdr && v3.cur_ends && !v3.cur_short;
    emit_c    = blk_end_c && supported && len_ok;
    skip_c    = blk_end_c && !supported;
    bad_len_c = blk_end_c && supported && !len_ok;
    len_err_c = v3.cur_short || v3.nxt_short;
    early_c   = v3.live && !v3.in_hdr && !v3.cur_short && v3.we20 &&
                has_order_ref(msg_type) && len_ok;
    trunc_c   = v3.live && v3.last && !v3.clean_end && !v3.cur_short && !v3.nxt_short;
    // A header and a block can never end in the same beat (blocks are >= 9 bytes).
    count_bad = hdr_end_c ? ((hdr_dec.msg_count != 16'd0) && (hdr_dec.msg_count != 16'hFFFF))
              : blk_end_c ? (blk_left_q != 16'd1)
              :             ((blk_left_q != 16'd0) && !eos_q);
    cnt_err_c = MOLD_HDR && v3.live && v3.last && v3.clean_end &&
                !v3.cur_short && !v3.nxt_short && count_bad;

    go        = adv && v3.v;
    hdr_end   = go && hdr_end_c;
    emit      = go && emit_c;
    early_hit = go && early_c;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      blk_left_q <= '0;
      eos_q      <= 1'b0;
    end else if (go && v3.live && !v3.last) begin
      if (hdr_end_c) begin
        blk_left_q <= hdr_dec.msg_count;
        eos_q      <= (hdr_dec.msg_count == 16'hFFFF);
      end else if (blk_end_c) begin
        blk_left_q <= blk_left_q - 16'd1;
        eos_q      <= 1'b0;
      end
    end
  end

  // Output register. m_msg is don't-care while m_valid is low, so it loads whenever the
  // output register is free (adv) rather than on emit: the deep emit decision then only
  // drives m_valid, instead of fanning out to ~460 clock enables.
  always_ff @(posedge clk) begin
    if (rst) begin
      m_valid <= 1'b0;
    end else if (emit) begin
      m_valid <= 1'b1;
    end else if (m_ready) begin
      m_valid <= 1'b0;
    end
    if (adv) m_msg <= dec;
  end

  // Early strobe + MoldUDP64 header: 1-cycle pulses without backpressure, so the data
  // registers load every cycle and are qualified by e_valid / hdr_valid.
  always_ff @(posedge clk) begin
    if (rst) begin
      e_valid   <= 1'b0;
      hdr_valid <= 1'b0;
    end else begin
      e_valid   <= early_hit;
      hdr_valid <= hdr_end;
    end
    e_msg_type     <= msg_type;
    e_stock_locate <= `ITCH_FLD(1, 2);
    e_order_ref    <= `ITCH_FLD(11, 8);
    hdr            <= hdr_dec;
  end

  // Statistics. Event pulses are registered, and each counter is a stat_counter
  // (segmented carry lookahead), so neither the decode logic nor a 32-bit carry chain
  // sits on the path into the counters.
  logic [6:0] evt_q;
  always_ff @(posedge clk) begin
    if (rst) evt_q <= '0;
    else     evt_q <= {7{go}} & {v3.last, emit_c, skip_c, bad_len_c, len_err_c, trunc_c, cnt_err_c};
  end

  stat_counter u_cnt_pkts      (.clk, .rst, .inc(evt_q[6]), .count(cnt_pkts));
  stat_counter u_cnt_msgs      (.clk, .rst, .inc(evt_q[5]), .count(cnt_msgs));
  stat_counter u_cnt_skipped   (.clk, .rst, .inc(evt_q[4]), .count(cnt_skipped));
  stat_counter u_cnt_err_len   (.clk, .rst, .inc(evt_q[3]), .count(cnt_err_len));
  stat_counter u_cnt_err_short (.clk, .rst, .inc(evt_q[2]), .count(cnt_err_short));
  stat_counter u_cnt_err_trunc (.clk, .rst, .inc(evt_q[1]), .count(cnt_err_trunc));
  stat_counter u_cnt_err_count (.clk, .rst, .inc(evt_q[0]), .count(cnt_err_count));

  `undef ITCH_FLD
  `undef MOLD_FLD

endmodule

`default_nettype wire
