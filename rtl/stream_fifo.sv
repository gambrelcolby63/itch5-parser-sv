// -----------------------------------------------------------------------------
// stream_fifo.sv
// Small valid/ready FIFO with fall-through bypass: when empty and the consumer is
// ready, data passes straight through combinationally (zero added latency). It only
// holds entries while the consumer is busy.
// -----------------------------------------------------------------------------
`default_nettype none

module stream_fifo #(
  parameter int unsigned WIDTH = 8,
  parameter int unsigned DEPTH = 4,           // power of two
  localparam int unsigned AW   = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
  input  wire logic             clk,
  input  wire logic             rst,
  input  wire logic [WIDTH-1:0] in_data,
  input  wire logic             in_valid,
  output logic                  in_ready,
  output logic [WIDTH-1:0]      out_data,
  output logic                  out_valid,
  input  wire logic             out_ready,
  output logic [AW:0]           level        // current occupancy
);

  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [AW-1:0]    rd_q, wr_q;
  logic [AW:0]      cnt_q;
  logic             empty, bypass, push, pop;

  assign empty     = (cnt_q == '0);
  assign in_ready  = (cnt_q != (AW+1)'(DEPTH));
  assign out_valid = !empty || in_valid;
  assign out_data  = empty ? in_data : mem[rd_q];
  assign bypass    = empty && in_valid && out_ready;
  assign push      = in_valid && in_ready && !bypass;
  assign pop       = !empty && out_ready;
  assign level     = cnt_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      rd_q  <= '0;
      wr_q  <= '0;
      cnt_q <= '0;
    end else begin
      if (push) wr_q <= wr_q + AW'(1);
      if (pop)  rd_q <= rd_q + AW'(1);
      cnt_q <= cnt_q + (AW+1)'(push) - (AW+1)'(pop);
    end
  end

  always_ff @(posedge clk) begin
    if (push) mem[wr_q] <= in_data;
  end

endmodule

`default_nettype wire
