// -----------------------------------------------------------------------------
// itch_feed_top.sv
// MoldUDP64/ITCH parser + price-level book: AXI-Stream in, book update events out.
// -----------------------------------------------------------------------------
`default_nettype none

module itch_feed_top #(
  parameter bit          MOLD_HDR    = 1'b1,
  parameter int unsigned NUM_SYMBOLS = 256,
  parameter int unsigned LEVELS      = 8,
  parameter int unsigned ORD_BITS    = 16,
  parameter int unsigned LOCATE_BITS = 14,
  parameter int unsigned MSG_FIFO_DEPTH = 2,   // peak backlog is 1 message (see README)
  localparam int unsigned SLOT_BITS  = $clog2(NUM_SYMBOLS),
  localparam int unsigned CNT_BITS   = $clog2(LEVELS + 1)
) (
  input  wire logic                 clk,
  input  wire logic                 rst,
  output logic                      init_done,

  input  wire logic [63:0]          s_axis_tdata,
  input  wire logic [7:0]           s_axis_tkeep,
  input  wire logic                 s_axis_tvalid,
  output logic                      s_axis_tready,
  input  wire logic                 s_axis_tlast,

  input  wire logic                 cfg_we,
  input  wire logic [15:0]          cfg_locate,
  input  wire logic                 cfg_enable,
  input  wire logic [SLOT_BITS-1:0] cfg_slot,

  output logic                      msg_valid,     // parser output handshake (debug/latency tap)

  output logic                      bk_valid,
  output logic [SLOT_BITS-1:0]      bk_slot,
  output logic                      bk_side,
  output logic [CNT_BITS-1:0]       bk_count,
  output logic                      bk_trunc,
  output logic [LEVELS*32-1:0]      bk_price,
  output logic [LEVELS*32-1:0]      bk_qty,
  output logic [7:0]                bk_msg_type,
  output logic [15:0]               bk_locate,
  output logic [47:0]               bk_timestamp,

  output logic [31:0]               cnt_msgs,
  output logic [31:0]               cnt_parse_errs,
  output logic [31:0]               cnt_book_in,
  output logic [31:0]               cnt_bk_events,
  output logic [31:0]               cnt_unsub,
  output logic [31:0]               cnt_ord_collide,
  output logic [31:0]               cnt_ord_miss,
  output logic [31:0]               cnt_lvl_miss,
  output logic [31:0]               cnt_lvl_drop
);

  itch_pkg::itch_msg_t msg, book_msg;
  logic                msg_ready, book_valid, book_ready;
  logic [$clog2(MSG_FIFO_DEPTH):0] fifo_level;
  logic [31:0]         cnt_pkts, cnt_skipped, cnt_err_len, cnt_err_short, cnt_err_trunc, cnt_err_count;
  logic                e_valid, hdr_valid;
  logic [7:0]          e_msg_type;
  logic [15:0]         e_stock_locate;
  logic [63:0]         e_order_ref;
  itch_pkg::mold_hdr_t hdr;

  itch_parser #(.MOLD_HDR(MOLD_HDR)) u_parser (
    .clk, .rst,
    .s_axis_tdata, .s_axis_tkeep, .s_axis_tvalid, .s_axis_tready, .s_axis_tlast,
    .m_msg (msg), .m_valid (msg_valid), .m_ready (msg_ready),
    .e_valid, .e_msg_type, .e_stock_locate, .e_order_ref,
    .hdr_valid, .hdr,
    .cnt_pkts, .cnt_msgs, .cnt_skipped, .cnt_err_len, .cnt_err_short, .cnt_err_trunc, .cnt_err_count
  );

  // Parser -> book decoupling. Book messages take 2 cycles in the book but are >= 21 bytes
  // (>= 2 beats) apart on the wire, so the book keeps up on average. This FIFO absorbs
  // the short windows where a small message (e.g. 14-byte 'S' block) lands while
  // the book is busy, so the parser never has to stall the input.
  stream_fifo #(.WIDTH($bits(itch_pkg::itch_msg_t)), .DEPTH(MSG_FIFO_DEPTH)) u_msg_fifo (
    .clk, .rst,
    .in_data (msg), .in_valid (msg_valid), .in_ready (msg_ready),
    .out_data (book_msg), .out_valid (book_valid), .out_ready (book_ready),
    .level (fifo_level)
  );

  itch_book #(
    .NUM_SYMBOLS (NUM_SYMBOLS), .LEVELS (LEVELS), .ORD_BITS (ORD_BITS), .LOCATE_BITS (LOCATE_BITS)
  ) u_book (
    .clk, .rst, .init_done,
    .cfg_we, .cfg_locate, .cfg_enable, .cfg_slot,
    .in_msg (book_msg), .in_valid (book_valid), .in_ready (book_ready),
    .bk_valid, .bk_slot, .bk_side, .bk_count, .bk_trunc, .bk_price, .bk_qty,
    .bk_msg_type, .bk_locate, .bk_timestamp,
    .cnt_in_msgs (cnt_book_in), .cnt_bk_events, .cnt_unsub, .cnt_ord_collide, .cnt_ord_miss, .cnt_lvl_miss, .cnt_lvl_drop
  );

  assign cnt_parse_errs = cnt_err_len + cnt_err_short + cnt_err_trunc + cnt_err_count;

  // The early strobe and Mold header are not used by the book yet (future: prefetch).
  logic unused_ok;
  assign unused_ok = ^{1'b0, cnt_pkts, cnt_skipped, e_valid, e_msg_type, e_stock_locate, e_order_ref,
                       hdr_valid, hdr, fifo_level, 1'b0};

endmodule

`default_nettype wire
