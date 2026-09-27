// -----------------------------------------------------------------------------
// itch_parser.sv
//
// Nasdaq TotalView-ITCH 5.0 message parser, 64-bit AXI4-Stream in, one decoded
// message per clock out.
//
// Input framing
//   * Byte lane i is s_axis_tdata[8*i +: 8]; lane 0 is the first byte on the wire.
//   * tkeep must be contiguous from lane 0 (normally all ones except the tlast beat).
//   * The payload is a sequence of MoldUDP64 message blocks:
//       [len_hi][len_lo][len bytes of ITCH message]
//   * MOLD_HDR = 1: every packet (tlast-delimited) starts with the 20-byte MoldUDP64
//     header (session 10, sequence 8, message count 2), which is parsed in-line and
//     reported on hdr/hdr_valid. No realignment shifter is used: the header is treated
//     as a fixed-length "block", so the first message block simply starts at lane 4.
//   * MOLD_HDR = 0: the stream is raw message blocks; tlast just resynchronizes.
//
// Architecture
//   A block-offset counter (boff_q) tracks the position of lane 0 of the incoming beat
//   inside the current block. Each byte lane is steered into a 42-byte block buffer at
//   position (boff + lane). Because every block is >= 9 bytes, a beat holds at most one
//   block boundary: the tail of the current block and the head of the next. The tail is
//   merged combinationally with the buffer ("merged view") and decoded on the same
//   clock edge that accepts the last byte; the head is written to buffer positions 0..7.
//
// Latency (see README)
//   * m_valid     : registered on the clock edge that accepts the beat carrying the
//                   message's last byte -> visible 1 cycle later.
//   * e_valid     : early strobe (type, stock locate, order ref) registered on the edge
//                   that accepts message byte 18, i.e. before the message completes.
//   * hdr_valid   : registered on the edge that accepts MoldUDP64 header byte 19.
//
// Flow control
//   The only stall source is the output register: s_axis_tready = !m_valid | m_ready.
//   With m_ready held high the parser accepts one beat per clock (full line rate).
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
  parameter bit MOLD_HDR = 1'b1
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

  localparam int unsigned BW = 17;             // block offset width (max 65535 + 2)
  localparam int unsigned VW = 8 * BUF_BYTES;  // merged-view vector width

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic [BW-1:0] boff_q;                  // block offset of lane 0 of the next beat
  logic          hdr_phase_q;             // parsing the MoldUDP64 header
  logic          drop_q;                  // framing lost, discard until tlast
  logic [15:0]   blk_cnt_q;               // message blocks seen in this packet
  logic [15:0]   pkt_count_q;             // MoldUDP64 message count of this packet
  logic [7:0]    buf_q [0:BUF_BYTES-1];   // block buffer, indexed by block offset

  // ---------------------------------------------------------------------------
  // Beat decode
  // ---------------------------------------------------------------------------
  logic [7:0] lane [0:BEAT_BYTES-1];
  logic [3:0] nb;                         // valid bytes in beat (tkeep contiguous)

  always_comb begin
    nb = 4'd0;
    for (int i = 0; i < BEAT_BYTES; i++) begin
      lane[i] = s_axis_tdata[8*i +: 8];
      if (s_axis_tkeep[i]) nb = 4'(i + 1);
    end
  end

  logic fire;
  logic in_hdr;
  assign fire   = s_axis_tvalid && s_axis_tready;
  assign in_hdr = MOLD_HDR && hdr_phase_q;

  // Current block length. Only the first two block bytes can be in flight here.
  logic [15:0] cur_len;
  logic        len_known;
  always_comb begin
    if (boff_q >= BW'(2)) begin
      cur_len   = {buf_q[0], buf_q[1]};
      len_known = 1'b1;
    end else if (boff_q == BW'(1)) begin
      cur_len   = {buf_q[0], lane[0]};
      len_known = (nb >= 4'd1);
    end else begin
      cur_len   = {lane[0], lane[1]};
      len_known = (nb >= 4'd2);
    end
  end

  logic [BW-1:0] blk_total;   // header: 20; block: len + 2
  logic [BW-1:0] rem;         // bytes of the current block still to come
  logic          cur_known;
  logic          cur_ends;    // current block ends in this beat
  logic          nxt_present; // next block starts in this beat
  logic [3:0]    rem_l;
  logic [3:0]    nxt_nb;

  always_comb begin
    blk_total   = in_hdr ? BW'(MOLD_HDR_BYTES) : ({1'b0, cur_len} + BW'(2));
    cur_known   = in_hdr || len_known;
    rem         = blk_total - boff_q;
    cur_ends    = cur_known && (rem <= BW'(nb));
    rem_l       = rem[3:0];
    nxt_present = cur_ends && (rem_l < nb);
    nxt_nb      = nb - rem_l;
  end

  // Lanes that belong to the current block
  logic [BEAT_BYTES-1:0] cur_lane_ok;
  always_comb begin
    for (int i = 0; i < BEAT_BYTES; i++) begin
      cur_lane_ok[i] = (4'(i) < nb) && (!cur_ends || (4'(i) < rem_l));
    end
  end

  // Current block: lane -> buffer position (boff + lane)
  logic                 boff_small;
  logic [BUF_BYTES-1:0] cur_we;
  logic [7:0]           cur_byte [0:BUF_BYTES-1];
  logic [7:0]           mv       [0:BUF_BYTES-1];   // merged view (buffer + this beat)
  logic [VW-1:0]        mvp;                        // big-endian packed merged view

  assign boff_small = (boff_q < BW'(BUF_BYTES));

  always_comb begin
    for (int p = 0; p < BUF_BYTES; p++) begin
      cur_we[p]   = 1'b0;
      cur_byte[p] = 8'h00;
      for (int i = 0; i < BEAT_BYTES; i++) begin
        if (boff_small && cur_lane_ok[i] &&
            ((8'(boff_q[5:0]) + 8'(i)) == 8'(p))) begin
          cur_we[p]   = 1'b1;
          cur_byte[p] = lane[i];
        end
      end
      mv[p] = cur_we[p] ? cur_byte[p] : buf_q[p];
      mvp[VW - 1 - 8*p -: 8] = mv[p];
    end
  end

  // Next block head: lane (rem + p) -> buffer position p
  logic [BEAT_BYTES-1:0] nxt_we;
  logic [7:0]            nxt_byte [0:BEAT_BYTES-1];
  always_comb begin
    for (int p = 0; p < BEAT_BYTES; p++) begin
      nxt_we[p]   = 1'b0;
      nxt_byte[p] = 8'h00;
      for (int i = 0; i < BEAT_BYTES; i++) begin
        if (nxt_present && (4'(i) < nb) && ((rem_l + 4'(p)) == 4'(i))) begin
          nxt_we[p]   = 1'b1;
          nxt_byte[p] = lane[i];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Field extraction from the merged view.
  // Message byte m lives at block offset m + 2; header byte h at block offset h.
  // ---------------------------------------------------------------------------
  `define ITCH_FLD(off, nbytes) mvp[VW - 1 - 8*((off) + 2) -: 8*(nbytes)]
  `define MOLD_FLD(off, nbytes) mvp[VW - 1 - 8*(off) -: 8*(nbytes)]

  logic [7:0]  msg_type;
  logic [15:0] exp_len;
  itch_msg_t   dec;

  assign msg_type = `ITCH_FLD(0, 1);
  assign exp_len  = expected_len(msg_type);

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

  mold_hdr_t hdr_dec;
  assign hdr_dec.session   = `MOLD_FLD(0, 10);
  assign hdr_dec.seq_num   = `MOLD_FLD(10, 8);
  assign hdr_dec.msg_count = `MOLD_FLD(18, 2);

  // ---------------------------------------------------------------------------
  // Events for this beat
  // ---------------------------------------------------------------------------
  logic        live;
  logic        cur_short, nxt_short;
  logic        hdr_end, blk_end, emit, skip, bad_len, early_hit;
  logic        clean_end, trunc, cnt_err;
  logic [15:0] exp_count;
  logic [15:0] blk_cnt_now;

  always_comb begin
    live      = fire && !drop_q;
    // Length sanity: checked on the beat where a block's length first becomes known.
    cur_short = live && !in_hdr && (boff_q <= BW'(1)) && len_known &&
                (cur_len < 16'(MIN_MSG_LEN));
    nxt_short = live && nxt_present && (nxt_nb >= 4'd2) &&
                ({nxt_byte[0], nxt_byte[1]} < 16'(MIN_MSG_LEN));

    hdr_end   = live && in_hdr && cur_ends;
    blk_end   = live && !in_hdr && cur_ends && !cur_short;
    emit      = blk_end && (exp_len != 16'd0) && (cur_len == exp_len);
    skip      = blk_end && (exp_len == 16'd0);
    bad_len   = blk_end && (exp_len != 16'd0) && (cur_len != exp_len);

    // Early strobe: message byte 18 (last byte of the order reference) is in this beat.
    early_hit = live && !in_hdr && !cur_short && cur_we[20] &&
                has_order_ref(msg_type) && (cur_len == exp_len);

    // Packet-level checks at tlast
    clean_end   = cur_ends ? !nxt_present
                           : ((nb == 4'd0) && (boff_q == '0) && !in_hdr);
    trunc       = live && s_axis_tlast && !clean_end && !cur_short && !nxt_short;
    exp_count   = hdr_end ? hdr_dec.msg_count : pkt_count_q;
    blk_cnt_now = blk_cnt_q + 16'(blk_end);
    cnt_err     = MOLD_HDR && live && s_axis_tlast && clean_end &&
                  !cur_short && !nxt_short &&
                  (blk_cnt_now != exp_count) &&
                  !((exp_count == 16'hFFFF) && (blk_cnt_now == 16'd0));
  end

  // ---------------------------------------------------------------------------
  // Sequential
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      boff_q      <= '0;
      hdr_phase_q <= MOLD_HDR;
      drop_q      <= 1'b0;
      blk_cnt_q   <= '0;
      pkt_count_q <= '0;
    end else if (fire) begin
      if (s_axis_tlast) begin
        boff_q      <= '0;
        hdr_phase_q <= MOLD_HDR;
        drop_q      <= 1'b0;
        blk_cnt_q   <= '0;
      end else if (!drop_q) begin
        if (cur_short || nxt_short) begin
          drop_q <= 1'b1;
        end
        boff_q <= cur_ends ? (nxt_present ? BW'(nxt_nb) : '0)
                           : (boff_q + BW'(nb));
        if (hdr_end) begin
          hdr_phase_q <= 1'b0;
          pkt_count_q <= hdr_dec.msg_count;
        end
        blk_cnt_q <= blk_cnt_now;
      end
    end
  end

  // Block buffer (no reset needed: every position is written before it is read)
  always_ff @(posedge clk) begin
    if (fire) begin
      for (int p = 0; p < BUF_BYTES; p++) begin
        if (cur_we[p]) begin
          buf_q[p] <= cur_byte[p];
        end else if ((p < BEAT_BYTES) && nxt_we[p % BEAT_BYTES]) begin
          buf_q[p] <= nxt_byte[p % BEAT_BYTES];
        end
      end
    end
  end

  // Output register
  assign s_axis_tready = !m_valid || m_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      m_valid <= 1'b0;
    end else if (emit) begin
      m_valid <= 1'b1;
    end else if (m_ready) begin
      m_valid <= 1'b0;
    end
    if (emit) m_msg <= dec;
  end

  // Early strobe + MoldUDP64 header
  always_ff @(posedge clk) begin
    if (rst) begin
      e_valid   <= 1'b0;
      hdr_valid <= 1'b0;
    end else begin
      e_valid   <= early_hit;
      hdr_valid <= hdr_end;
    end
    if (early_hit) begin
      e_msg_type     <= msg_type;
      e_stock_locate <= `ITCH_FLD(1, 2);
      e_order_ref    <= `ITCH_FLD(11, 8);
    end
    if (hdr_end) hdr <= hdr_dec;
  end

  // Statistics
  always_ff @(posedge clk) begin
    if (rst) begin
      cnt_pkts      <= '0;
      cnt_msgs      <= '0;
      cnt_skipped   <= '0;
      cnt_err_len   <= '0;
      cnt_err_short <= '0;
      cnt_err_trunc <= '0;
      cnt_err_count <= '0;
    end else begin
      cnt_pkts      <= cnt_pkts      + 32'(fire && s_axis_tlast);
      cnt_msgs      <= cnt_msgs      + 32'(emit);
      cnt_skipped   <= cnt_skipped   + 32'(skip);
      cnt_err_len   <= cnt_err_len   + 32'(bad_len);
      cnt_err_short <= cnt_err_short + 32'(cur_short || nxt_short);
      cnt_err_trunc <= cnt_err_trunc + 32'(trunc);
      cnt_err_count <= cnt_err_count + 32'(cnt_err);
    end
  end

  `undef ITCH_FLD
  `undef MOLD_FLD

endmodule

`default_nettype wire
