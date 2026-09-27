// -----------------------------------------------------------------------------
// timing_harness.sv  (place-and-route timing only; not part of the design)
//
// The parser has ~1000 I/O bits, far more than any package, so for an in-context
// timing estimate every parser input is driven from a serial-in shift register and
// every parser output is folded into one pin through a registered XOR tree (one LUT per
// stage). All parser logic stays observable (nothing can be optimized away) and every
// timing path through the parser is register to register.
// -----------------------------------------------------------------------------
`default_nettype none

module timing_harness
  import itch_pkg::*;
#(
  parameter int unsigned PIPE_STAGES = 0
) (
  input  wire logic clk,
  input  wire logic rst_in,
  input  wire logic sin,
  output logic      sout
);

  localparam int unsigned NIN = 64 + 8 + 3;     // tdata, tkeep, tvalid, tlast, m_ready

  logic [NIN-1:0] sh;
  logic           rst;
  always_ff @(posedge clk) begin
    sh  <= {sh[NIN-2:0], sin};
    rst <= rst_in;
  end

  itch_msg_t   m_msg;
  mold_hdr_t   hdr;
  logic        tready, m_valid, e_valid, hdr_valid;
  logic [7:0]  e_msg_type;
  logic [15:0] e_stock_locate;
  logic [63:0] e_order_ref;
  logic [31:0] c0, c1, c2, c3, c4, c5, c6;

  itch_parser #(.MOLD_HDR(1'b1), .PIPE_STAGES(PIPE_STAGES)) dut (
    .clk, .rst,
    .s_axis_tdata(sh[63:0]), .s_axis_tkeep(sh[71:64]), .s_axis_tvalid(sh[72]),
    .s_axis_tready(tready), .s_axis_tlast(sh[73]),
    .m_msg, .m_valid, .m_ready(sh[74]),
    .e_valid, .e_msg_type, .e_stock_locate, .e_order_ref,
    .hdr_valid, .hdr,
    .cnt_pkts(c0), .cnt_msgs(c1), .cnt_skipped(c2), .cnt_err_len(c3),
    .cnt_err_short(c4), .cnt_err_trunc(c5), .cnt_err_count(c6)
  );

  localparam int unsigned NO = $bits(itch_msg_t) + $bits(mold_hdr_t) + 4 + 8 + 16 + 64 + 7*32;
  localparam int unsigned W1 = (NO + 5) / 6;
  localparam int unsigned W2 = (W1 + 5) / 6;
  localparam int unsigned W3 = (W2 + 5) / 6;

  logic [6*W1-1:0] p0;
  logic [6*W2-1:0] p1;
  logic [6*W3-1:0] p2;
  logic [W1-1:0]   o1;
  logic [W2-1:0]   o2;
  logic [W3-1:0]   o3;
  assign p0 = (6*W1)'({m_msg, hdr, tready, m_valid, e_valid, hdr_valid, e_msg_type,
                        e_stock_locate, e_order_ref, c0, c1, c2, c3, c4, c5, c6});
  assign p1 = (6*W2)'(o1);
  assign p2 = (6*W3)'(o2);

  always_ff @(posedge clk) begin
    for (int i = 0; i < W1; i++) o1[i] <= ^p0[6*i +: 6];
    for (int i = 0; i < W2; i++) o2[i] <= ^p1[6*i +: 6];
    for (int i = 0; i < W3; i++) o3[i] <= ^p2[6*i +: 6];
    sout <= ^o3;
  end

endmodule

`default_nettype wire
