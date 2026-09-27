// -----------------------------------------------------------------------------
// stat_counter.sv
//
// Statistics counter whose logic depth does not grow with its width. The count is
// split into SEG-bit segments. Each segment keeps a registered "all ones" flag, so the
// carry into segment s is an AND of at most W/SEG flags, and within a segment a bit
// toggles when the lower bits of that segment are all ones. The count is exact every
// cycle; only the carry lookahead is registered.
//   depth ~ 2-3 LUT6 levels for W = 32, SEG = 8 (a ripple adder maps to 7-8)
// Requirements: SEG >= 2 and SEG divides W. Verified exhaustively through many
// wrap-arounds by tb/test_stat_counter.py with small W/SEG.
// -----------------------------------------------------------------------------
`default_nettype none

module stat_counter #(
  parameter int unsigned W   = 32,
  parameter int unsigned SEG = 8     // must divide W
) (
  input  wire logic         clk,
  input  wire logic         rst,
  input  wire logic         inc,
  output logic [W-1:0]      count
);

  localparam int unsigned NS = W / SEG;

  logic [NS-1:0] full_q;    // segment s is all ones
  logic [NS-1:0] seg_en;    // segment s increments this cycle
  logic [W-1:0]  toggle;

  always_comb begin
    for (int s = 0; s < NS; s++) begin
      seg_en[s] = inc;
      for (int j = 0; j < NS; j++) begin
        if (j < s) seg_en[s] = seg_en[s] && full_q[j];
      end
      for (int i = 0; i < SEG; i++) begin
        toggle[s*SEG + i] = seg_en[s];
        for (int j = 0; j < SEG; j++) begin
          if (j < i) toggle[s*SEG + i] = toggle[s*SEG + i] && count[s*SEG + j];
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      count  <= '0;
      full_q <= '0;
    end else begin
      count <= count ^ toggle;
      for (int s = 0; s < NS; s++) begin
        if (seg_en[s]) full_q[s] <= (count[s*SEG +: SEG] == {{(SEG-1){1'b1}}, 1'b0});
      end
    end
  end

endmodule

`default_nettype wire
