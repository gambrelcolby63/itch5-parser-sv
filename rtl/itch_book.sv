// -----------------------------------------------------------------------------
// itch_book.sv
//
// Order-level to price-level book builder for a subscribed set of symbols.
// Consumes decoded ITCH messages (itch_msg_t, valid/ready) from itch_parser.
//
//   * Subscription table  : stock locate -> {enable, slot}. Software writes it through
//                           the cfg_* port before the session. Unsubscribed locates are
//                           ignored.
//   * Order table         : direct-mapped hash table, index = order_ref[ORD_BITS-1:0],
//                           entry = {valid, order_ref, slot, side, price, shares}.
//                           True dual port: port A = existing order (lookup/update/
//                           delete), port B = new order (insert for A/F/U).
//   * Level table         : one wide word per (slot, side) holding the best LEVELS price
//                           levels, sorted best-first, plus a count and a sticky
//                           "truncated" flag. It is updated by read-modify-write with a
//                           fully parallel compare/insert/shift.
//
// Message handling (only for subscribed locates):
//   A/F : insert order (port B), level += shares
//   E/C/X : shares -= n (saturating); level -= min(n, shares); delete order if 0 left
//           (for C the resting order's own price is used, not the execution price)
//   D   : delete order, level -= remaining shares
//   U   : delete original (port A), insert new ref (port B) with the same slot/side;
//         level -= old shares @ old price, then level += new shares @ new price
//         (same (slot, side) word, so both steps happen in one read-modify-write)
//
// Invariant: a level only contains quantity from orders present in the order table.
// Insert collisions (bucket already holds a different live order) drop the new order
// and leave the book untouched (cnt_ord_collide). Later messages for that order miss
// (cnt_ord_miss).
//
// Depth: when a side already holds LEVELS levels and a new level is inserted, the worst
// level falls off (or the new one is dropped if it is the worst). The side's `trunc` flag
// goes sticky from then on: deeper levels may be missing, and a level that
// re-forms at a dropped price can be under-counted. Top levels stay exact while
// the side still holds more levels than were dropped.
//
// Timing (see README): accept -> LOOK (order/sub read data) -> UPD (level read data,
// write back, register event). Book messages take 2 cycles, others 1 cycle.
// Last ITCH byte in -> bk_valid is 4 cycles when the book is idle.
// -----------------------------------------------------------------------------
`default_nettype none

module itch_book
  import itch_pkg::*;
#(
  parameter int unsigned NUM_SYMBOLS = 256,  // subscribed symbols (slots)
  parameter int unsigned LEVELS      = 8,    // price levels kept per side
  parameter int unsigned ORD_BITS    = 16,   // order table = 2**ORD_BITS entries
  parameter int unsigned LOCATE_BITS = 14,   // subscription table = 2**LOCATE_BITS entries
  localparam int unsigned SLOT_BITS  = $clog2(NUM_SYMBOLS),
  localparam int unsigned CNT_BITS   = $clog2(LEVELS + 1)
) (
  input  wire logic                    clk,
  input  wire logic                    rst,
  output logic                         init_done,   // memories cleared after reset

  // Subscription configuration (write only, apply before traffic)
  input  wire logic                    cfg_we,
  input  wire logic [15:0]             cfg_locate,
  input  wire logic                    cfg_enable,
  input  wire logic [SLOT_BITS-1:0]    cfg_slot,

  // Decoded messages from itch_parser
  input  itch_pkg::itch_msg_t          in_msg,
  input  wire logic                    in_valid,
  output logic                         in_ready,

  // Book update event: the full post-update side book (no backpressure)
  output logic                         bk_valid,
  output logic [SLOT_BITS-1:0]         bk_slot,
  output logic                         bk_side,       // 0 = bid, 1 = ask
  output logic [CNT_BITS-1:0]          bk_count,      // valid levels
  output logic                         bk_trunc,      // sticky: a level was dropped
  output logic [LEVELS*32-1:0]         bk_price,      // level i at [32*i +: 32], i=0 best
  output logic [LEVELS*32-1:0]         bk_qty,
  output logic [7:0]                   bk_msg_type,
  output logic [15:0]                  bk_locate,
  output logic [47:0]                  bk_timestamp,

  // Statistics
  output logic [31:0]                  cnt_in_msgs,      // messages accepted (all types)
  output logic [31:0]                  cnt_bk_events,
  output logic [31:0]                  cnt_unsub,
  output logic [31:0]                  cnt_ord_collide,
  output logic [31:0]                  cnt_ord_miss,
  output logic [31:0]                  cnt_lvl_miss,
  output logic [31:0]                  cnt_lvl_drop
);

  // ---------------------------------------------------------------------------
  // Types
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic                 valid;
    logic [63:0]          order_ref;
    logic [SLOT_BITS-1:0] slot;
    logic                 side;      // 0 = bid ('B'), 1 = ask ('S')
    logic [31:0]          price;
    logic [31:0]          shares;
  } order_t;

  typedef struct packed {
    logic                 enable;
    logic [SLOT_BITS-1:0] slot;
  } sub_t;

  typedef struct packed {
    logic [31:0] price;
    logic [31:0] qty;
  } level_t;

  typedef struct packed {
    logic                      trunc;
    logic [CNT_BITS-1:0]       count;
    level_t [LEVELS-1:0]       lv;      // lv[0] = best
  } side_book_t;

  localparam int unsigned ORD_DEPTH = 2 ** ORD_BITS;
  localparam int unsigned SUB_DEPTH = 2 ** LOCATE_BITS;
  localparam int unsigned LVL_DEPTH = 2 * NUM_SYMBOLS;
  localparam int unsigned LVL_BITS  = SLOT_BITS + 1;
  localparam int unsigned CLR_BITS  = (ORD_BITS > LOCATE_BITS ? ORD_BITS : LOCATE_BITS) + 1;

  // ---------------------------------------------------------------------------
  // Memories (synchronous read, inferable as block RAM / URAM)
  // ---------------------------------------------------------------------------
  sub_t       sub_mem [0:SUB_DEPTH-1];
  order_t     ord_mem [0:ORD_DEPTH-1];
  side_book_t lvl_mem [0:LVL_DEPTH-1];

  // ---------------------------------------------------------------------------
  // Control
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {S_INIT, S_IDLE, S_LOOK, S_UPD} state_t;
  state_t state_q;

  logic [CLR_BITS-1:0] clr_idx_q;
  logic                accept;
  logic                in_is_book;

  function automatic logic is_book_type(input logic [7:0] t);
    case (t)
      MT_ADD_ORDER, MT_ADD_ORDER_MPID, MT_ORDER_EXECUTED, MT_ORDER_EXECUTED_PX,
      MT_ORDER_CANCEL, MT_ORDER_DELETE, MT_ORDER_REPLACE: is_book_type = 1'b1;
      default:                                            is_book_type = 1'b0;
    endcase
  endfunction

  assign in_ready   = (state_q == S_IDLE) || (state_q == S_UPD);
  assign accept     = in_valid && in_ready;
  assign in_is_book = is_book_type(in_msg.msg_type);
  assign init_done  = (state_q != S_INIT);

  // ---------------------------------------------------------------------------
  // Stage 1 (accept edge): register the message, read subscription + order table
  // ---------------------------------------------------------------------------
  // Only the fields the book needs are registered.
  typedef struct packed {
    logic [7:0]  msg_type;
    logic [15:0] stock_locate;
    logic [47:0] timestamp;
    logic [63:0] order_ref;
    logic [63:0] new_order_ref;
    logic [7:0]  side;
    logic [31:0] shares;
    logic [31:0] price;
  } book_msg_t;

  book_msg_t           msg_q;
  sub_t                sub_rd;
  logic                loc_hi_q;       // locate outside the subscription table
  order_t              ordA_rd;
  logic                ordB_valid;         // port B only needs occupancy
  logic [ORD_BITS-1:0] idxA_q, idxB_q;
  logic [ORD_BITS-1:0] idxA_in, idxB_in;
  logic [LOCATE_BITS-1:0] loc_in;
  logic                loc_hi_in;

  always_comb begin
    idxA_in = in_msg.order_ref[ORD_BITS-1:0];
    idxB_in = (in_msg.msg_type == MT_ORDER_REPLACE) ? in_msg.new_order_ref[ORD_BITS-1:0]
                                                    : in_msg.order_ref[ORD_BITS-1:0];
    loc_in  = in_msg.stock_locate[LOCATE_BITS-1:0];
    loc_hi_in = (32'(in_msg.stock_locate) >> LOCATE_BITS) != 32'd0;
  end

  always_ff @(posedge clk) begin
    if (accept) begin
      msg_q    <= '{msg_type: in_msg.msg_type, stock_locate: in_msg.stock_locate,
                    timestamp: in_msg.timestamp, order_ref: in_msg.order_ref,
                    new_order_ref: in_msg.new_order_ref, side: in_msg.side,
                    shares: in_msg.shares, price: in_msg.price};
      idxA_q   <= idxA_in;
      idxB_q   <= idxB_in;
      loc_hi_q <= loc_hi_in;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 2 (LOOK): decide the order-table and level operations
  // ---------------------------------------------------------------------------
  logic        subscribed, is_add, is_exec, is_del, is_rep, hitA, freeB;
  logic        look_unsub, look_collide, look_miss, look_go;
  logic        ordA_we, ordB_we;
  order_t      ordA_wd, ordB_wd;
  logic        op_sub, op_add;
  logic [31:0] sub_px, sub_q, add_px, add_q;
  logic [LVL_BITS-1:0] lvl_addr;

  always_comb begin
    subscribed = sub_rd.enable && !loc_hi_q;
    is_add     = (msg_q.msg_type == MT_ADD_ORDER) || (msg_q.msg_type == MT_ADD_ORDER_MPID);
    is_exec    = (msg_q.msg_type == MT_ORDER_EXECUTED) || (msg_q.msg_type == MT_ORDER_EXECUTED_PX) ||
                 (msg_q.msg_type == MT_ORDER_CANCEL);
    is_del     = (msg_q.msg_type == MT_ORDER_DELETE);
    is_rep     = (msg_q.msg_type == MT_ORDER_REPLACE);
    hitA       = ordA_rd.valid && (ordA_rd.order_ref == msg_q.order_ref);
    // For U, the new bucket may be the one the original order is leaving.
    freeB      = !ordB_valid || (is_rep && hitA && (idxA_q == idxB_q));

    look_unsub   = 1'b0;
    look_collide = 1'b0;
    look_miss    = 1'b0;
    look_go      = 1'b0;
    ordA_we = 1'b0;  ordA_wd = ordA_rd;
    ordB_we = 1'b0;  ordB_wd = '0;
    op_sub  = 1'b0;  sub_px = ordA_rd.price;  sub_q = 32'd0;
    op_add  = 1'b0;  add_px = msg_q.price;    add_q = msg_q.shares;
    lvl_addr = {ordA_rd.slot, ordA_rd.side};

    if (state_q == S_LOOK) begin
      if (!subscribed) begin
        look_unsub = 1'b1;
      end else if (is_add) begin
        lvl_addr = {sub_rd.slot, (msg_q.side == 8'h53)};   // 'S' = sell = ask
        if (freeB) begin
          ordB_we = 1'b1;
          ordB_wd = '{valid: 1'b1, order_ref: msg_q.order_ref, slot: sub_rd.slot,
                      side: (msg_q.side == 8'h53), price: msg_q.price, shares: msg_q.shares};
          op_add  = 1'b1;
          look_go = 1'b1;
        end else begin
          look_collide = 1'b1;
        end
      end else if (!hitA) begin
        look_miss = 1'b1;
      end else if (is_exec) begin
        look_go = 1'b1;
        op_sub  = 1'b1;
        ordA_we = 1'b1;
        if (ordA_rd.shares > msg_q.shares) begin
          sub_q          = msg_q.shares;
          ordA_wd.shares = ordA_rd.shares - msg_q.shares;
        end else begin
          sub_q          = ordA_rd.shares;
          ordA_wd        = '0;                       // fully executed: delete
        end
      end else if (is_del) begin
        look_go = 1'b1;
        op_sub  = 1'b1;
        sub_q   = ordA_rd.shares;
        ordA_we = 1'b1;
        ordA_wd = '0;
      end else if (is_rep) begin
        look_go = 1'b1;
        op_sub  = 1'b1;
        sub_q   = ordA_rd.shares;
        // Delete the original unless port B rewrites the same bucket this cycle.
        ordA_we = !(freeB && (idxA_q == idxB_q));
        ordA_wd = '0;
        if (freeB) begin
          ordB_we = 1'b1;
          ordB_wd = '{valid: 1'b1, order_ref: msg_q.new_order_ref, slot: ordA_rd.slot,
                      side: ordA_rd.side, price: msg_q.price, shares: msg_q.shares};
          op_add  = 1'b1;
        end else begin
          look_collide = 1'b1;
        end
      end
    end
  end

  // Registered LOOK results used in UPD
  logic                op_sub_q, op_add_q;
  logic [31:0]         sub_px_q, sub_q_q, add_px_q, add_q_q;
  logic [LVL_BITS-1:0] lvl_addr_q;
  logic                lvl_side_q;
  side_book_t          lvl_rd;

  always_ff @(posedge clk) begin
    if (state_q == S_LOOK) begin
      op_sub_q   <= op_sub;
      op_add_q   <= op_add;
      sub_px_q   <= sub_px;
      sub_q_q    <= sub_q;
      add_px_q   <= add_px;
      add_q_q    <= add_q;
      lvl_addr_q <= lvl_addr;
      lvl_side_q <= lvl_addr[0];
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 3 (UPD): parallel level update, step 1 = remove quantity, step 2 = add
  // ---------------------------------------------------------------------------
  // "a is better than b" for the side: bids descending, asks ascending.
  function automatic logic better(input logic side, input logic [31:0] a, input logic [31:0] b);
    return side ? (a < b) : (a > b);
  endfunction

  side_book_t b1, b2;
  logic       sub_miss, add_drop;

  always_comb begin : level_sub
    logic                      found;
    logic [CNT_BITS-1:0]       fi;
    b1       = lvl_rd;
    sub_miss = 1'b0;
    found    = 1'b0;
    fi       = '0;
    for (int i = 0; i < LEVELS; i++) begin
      if (!found && (CNT_BITS'(i) < lvl_rd.count) && (lvl_rd.lv[i].price == sub_px_q)) begin
        found = 1'b1;
        fi    = CNT_BITS'(i);
      end
    end
    if (op_sub_q) begin
      if (!found) begin
        sub_miss = 1'b1;
      end else if (lvl_rd.lv[fi].qty > sub_q_q) begin
        b1.lv[fi].qty = lvl_rd.lv[fi].qty - sub_q_q;
      end else begin
        // Level empties: shift the worse levels up by one.
        for (int i = 0; i < LEVELS - 1; i++) begin
          if (CNT_BITS'(i) >= fi) b1.lv[i] = lvl_rd.lv[i + 1];
        end
        b1.lv[LEVELS-1] = '0;
        b1.count        = lvl_rd.count - CNT_BITS'(1);
      end
    end
  end

  always_comb begin : level_add
    logic                found;
    logic [CNT_BITS-1:0] fi;
    logic [CNT_BITS-1:0] k;    // insertion index = number of strictly better levels
    b2       = b1;
    add_drop = 1'b0;
    found    = 1'b0;
    fi       = '0;
    k        = '0;
    for (int i = 0; i < LEVELS; i++) begin
      if (CNT_BITS'(i) < b1.count) begin
        if (!found && (b1.lv[i].price == add_px_q)) begin
          found = 1'b1;
          fi    = CNT_BITS'(i);
        end
        if (better(lvl_side_q, b1.lv[i].price, add_px_q)) k = k + CNT_BITS'(1);
      end
    end
    if (op_add_q) begin
      if (found) begin
        b2.lv[fi].qty = b1.lv[fi].qty + add_q_q;
      end else if (k == CNT_BITS'(LEVELS)) begin
        add_drop = 1'b1;                               // worse than a full book
        b2.trunc = 1'b1;
      end else begin
        for (int i = 1; i < LEVELS; i++) begin
          if (CNT_BITS'(i) > k) b2.lv[i] = b1.lv[i - 1];
        end
        for (int i = 0; i < LEVELS; i++) begin
          if (CNT_BITS'(i) == k) b2.lv[i] = '{price: add_px_q, qty: add_q_q};
        end
        if (b1.count == CNT_BITS'(LEVELS)) begin
          add_drop = 1'b1;                             // worst level fell off
          b2.trunc = 1'b1;
        end else begin
          b2.count = b1.count + CNT_BITS'(1);
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // State machine, memory writes, outputs
  // ---------------------------------------------------------------------------
  logic clr_last;
  assign clr_last = (clr_idx_q == CLR_BITS'((ORD_DEPTH > SUB_DEPTH ? ORD_DEPTH : SUB_DEPTH) - 1));

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q   <= S_INIT;
      clr_idx_q <= '0;
    end else begin
      case (state_q)
        S_INIT: begin
          clr_idx_q <= clr_idx_q + CLR_BITS'(1);
          if (clr_last) state_q <= S_IDLE;
        end
        S_IDLE, S_UPD: begin
          if (accept && in_is_book) state_q <= S_LOOK;
          else                      state_q <= S_IDLE;
        end
        S_LOOK: begin
          state_q <= look_go ? S_UPD : S_IDLE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  // Memory ports. Each port uses one address, so the tables map onto true/simple
  // dual-port block RAM: reads happen on the accept edge (order/sub) or in LOOK
  // (level), writes happen in INIT (clear sweep), LOOK (order) or UPD (level), and a
  // port never reads and writes in the same cycle.
  logic                   init;
  logic [LOCATE_BITS-1:0] sub_waddr;
  logic                   sub_we;
  sub_t                   sub_wd;
  logic [ORD_BITS-1:0]    ordA_addr, ordB_addr;
  logic                   ordA_wen, ordB_wen;
  order_t                 ordA_wdat;
  logic [LVL_BITS-1:0]    lvl_port_addr;
  logic                   lvl_we;

  always_comb begin
    init      = (state_q == S_INIT);
    // Subscription table (simple dual port: write = clear/cfg, read = accept)
    sub_we    = init ? (clr_idx_q < CLR_BITS'(SUB_DEPTH))
                     : (cfg_we && ((32'(cfg_locate) >> LOCATE_BITS) == 32'd0));
    sub_waddr = init ? clr_idx_q[LOCATE_BITS-1:0] : cfg_locate[LOCATE_BITS-1:0];
    sub_wd    = init ? '0 : '{enable: cfg_enable, slot: cfg_slot};
    // Order table (true dual port)
    ordA_addr = init ? clr_idx_q[ORD_BITS-1:0] : ((state_q == S_LOOK) ? idxA_q : idxA_in);
    ordA_wen  = init ? (clr_idx_q < CLR_BITS'(ORD_DEPTH)) : ordA_we;
    ordA_wdat = init ? '0 : ordA_wd;
    ordB_addr = (state_q == S_LOOK) ? idxB_q : idxB_in;
    ordB_wen  = ordB_we;
    // Level table (single port: read in LOOK, write in UPD/INIT)
    lvl_port_addr = init ? clr_idx_q[LVL_BITS-1:0]
                         : ((state_q == S_UPD) ? lvl_addr_q : lvl_addr);
    lvl_we        = init ? (clr_idx_q < CLR_BITS'(LVL_DEPTH)) : (state_q == S_UPD);
  end

  always_ff @(posedge clk) begin
    if (sub_we) sub_mem[sub_waddr] <= sub_wd;
    if (accept) sub_rd <= sub_mem[loc_in];
  end

  always_ff @(posedge clk) begin
    if (ordA_wen) ord_mem[ordA_addr] <= ordA_wdat;
    if (accept)   ordA_rd <= ord_mem[ordA_addr];
  end

  always_ff @(posedge clk) begin
    if (ordB_wen) ord_mem[ordB_addr] <= ordB_wd;
    if (accept)   ordB_valid <= ord_mem[ordB_addr].valid;
  end

  always_ff @(posedge clk) begin
    if (lvl_we)               lvl_mem[lvl_port_addr] <= init ? '0 : b2;
    if (state_q == S_LOOK)    lvl_rd <= lvl_mem[lvl_port_addr];
  end

  // Book event
  always_ff @(posedge clk) begin
    if (rst) begin
      bk_valid <= 1'b0;
    end else begin
      bk_valid <= (state_q == S_UPD);
    end
    if (state_q == S_UPD) begin
      bk_slot      <= lvl_addr_q[LVL_BITS-1:1];
      bk_side      <= lvl_side_q;
      bk_count     <= b2.count;
      bk_trunc     <= b2.trunc;
      bk_msg_type  <= msg_q.msg_type;
      bk_locate    <= msg_q.stock_locate;
      bk_timestamp <= msg_q.timestamp;
      for (int i = 0; i < LEVELS; i++) begin
        bk_price[32*i +: 32] <= b2.lv[i].price;
        bk_qty[32*i +: 32]   <= b2.lv[i].qty;
      end
    end
  end

  // Statistics
  always_ff @(posedge clk) begin
    if (rst) begin
      cnt_in_msgs     <= '0;
      cnt_bk_events   <= '0;
      cnt_unsub       <= '0;
      cnt_ord_collide <= '0;
      cnt_ord_miss    <= '0;
      cnt_lvl_miss    <= '0;
      cnt_lvl_drop    <= '0;
    end else begin
      cnt_in_msgs     <= cnt_in_msgs     + 32'(accept);
      cnt_bk_events   <= cnt_bk_events   + 32'(state_q == S_UPD);
      cnt_unsub       <= cnt_unsub       + 32'(look_unsub);
      cnt_ord_collide <= cnt_ord_collide + 32'(look_collide);
      cnt_ord_miss    <= cnt_ord_miss    + 32'(look_miss);
      cnt_lvl_miss    <= cnt_lvl_miss    + 32'((state_q == S_UPD) && sub_miss);
      cnt_lvl_drop    <= cnt_lvl_drop    + 32'((state_q == S_UPD) && add_drop);
    end
  end

  // Fields of the decoded message the book does not use.
  logic unused_ok;
  assign unused_ok = ^{1'b0, in_msg.tracking_num, in_msg.stock, in_msg.attribution,
                       in_msg.match_number, in_msg.printable, in_msg.event_code, 1'b0};

endmodule

`default_nettype wire
