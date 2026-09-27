// -----------------------------------------------------------------------------
// itch_top.sv
// Flat-port wrapper around itch_parser (simulation / synthesis top).
// -----------------------------------------------------------------------------
`default_nettype none

module itch_top
  import itch_pkg::*;
#(
  parameter bit MOLD_HDR = 1'b1
) (
  input  wire logic        clk,
  input  wire logic        rst,

  input  wire logic [63:0] s_axis_tdata,
  input  wire logic [7:0]  s_axis_tkeep,
  input  wire logic        s_axis_tvalid,
  output logic             s_axis_tready,
  input  wire logic        s_axis_tlast,

  output logic             m_valid,
  input  wire logic        m_ready,
  output logic [7:0]       m_msg_type,
  output logic [15:0]      m_stock_locate,
  output logic [15:0]      m_tracking_num,
  output logic [47:0]      m_timestamp,
  output logic [63:0]      m_order_ref,
  output logic [63:0]      m_new_order_ref,
  output logic [7:0]       m_side,
  output logic [31:0]      m_shares,
  output logic [63:0]      m_stock,
  output logic [31:0]      m_price,
  output logic [31:0]      m_attribution,
  output logic [63:0]      m_match_number,
  output logic [7:0]       m_printable,
  output logic [7:0]       m_event_code,

  output logic             e_valid,
  output logic [7:0]       e_msg_type,
  output logic [15:0]      e_stock_locate,
  output logic [63:0]      e_order_ref,

  output logic             hdr_valid,
  output logic [79:0]      hdr_session,
  output logic [63:0]      hdr_seq_num,
  output logic [15:0]      hdr_msg_count,

  output logic [31:0]      cnt_pkts,
  output logic [31:0]      cnt_msgs,
  output logic [31:0]      cnt_skipped,
  output logic [31:0]      cnt_err_len,
  output logic [31:0]      cnt_err_short,
  output logic [31:0]      cnt_err_trunc,
  output logic [31:0]      cnt_err_count
);

  itch_msg_t msg;
  mold_hdr_t hdr;

  itch_parser #(.MOLD_HDR(MOLD_HDR)) u_parser (
    .clk            (clk),
    .rst            (rst),
    .s_axis_tdata   (s_axis_tdata),
    .s_axis_tkeep   (s_axis_tkeep),
    .s_axis_tvalid  (s_axis_tvalid),
    .s_axis_tready  (s_axis_tready),
    .s_axis_tlast   (s_axis_tlast),
    .m_msg          (msg),
    .m_valid        (m_valid),
    .m_ready        (m_ready),
    .e_valid        (e_valid),
    .e_msg_type     (e_msg_type),
    .e_stock_locate (e_stock_locate),
    .e_order_ref    (e_order_ref),
    .hdr_valid      (hdr_valid),
    .hdr            (hdr),
    .cnt_pkts       (cnt_pkts),
    .cnt_msgs       (cnt_msgs),
    .cnt_skipped    (cnt_skipped),
    .cnt_err_len    (cnt_err_len),
    .cnt_err_short  (cnt_err_short),
    .cnt_err_trunc  (cnt_err_trunc),
    .cnt_err_count  (cnt_err_count)
  );

  assign m_msg_type      = msg.msg_type;
  assign m_stock_locate  = msg.stock_locate;
  assign m_tracking_num  = msg.tracking_num;
  assign m_timestamp     = msg.timestamp;
  assign m_order_ref     = msg.order_ref;
  assign m_new_order_ref = msg.new_order_ref;
  assign m_side          = msg.side;
  assign m_shares        = msg.shares;
  assign m_stock         = msg.stock;
  assign m_price         = msg.price;
  assign m_attribution   = msg.attribution;
  assign m_match_number  = msg.match_number;
  assign m_printable     = msg.printable;
  assign m_event_code    = msg.event_code;

  assign hdr_session     = hdr.session;
  assign hdr_seq_num     = hdr.seq_num;
  assign hdr_msg_count   = hdr.msg_count;

endmodule

`default_nettype wire
