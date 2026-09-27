// -----------------------------------------------------------------------------
// itch_pkg.sv
// Constants and types for the Nasdaq TotalView-ITCH 5.0 parser.
//
// Field layouts are taken from "Nasdaq TotalView-ITCH 5.0" (NQTVITCHspecification.pdf,
// nasdaqtrader.com). All integers are big-endian, unsigned. Alpha fields are ASCII,
// left justified, right padded with spaces. Price(4) = 4 implied decimal places.
// Timestamps are nanoseconds since midnight (6 bytes).
// -----------------------------------------------------------------------------
`default_nettype none

package itch_pkg;

  // Datapath geometry
  localparam int unsigned BEAT_BYTES     = 8;   // 64-bit AXI-Stream
  // Block buffer: 2-byte MoldUDP64 length prefix + longest decoded message ('F' = 40 B).
  // Also holds the 20-byte MoldUDP64 packet header while it is being parsed.
  localparam int unsigned BUF_BYTES      = 42;
  localparam int unsigned MOLD_HDR_BYTES = 20;  // session(10) + sequence(8) + count(2)
  // Minimum message length the block tracker accepts. It guarantees a message block
  // (len + 2 >= 9 bytes) can never start and end inside a single 8-byte beat, so each
  // beat contains at most one block boundary. Every ITCH 5.0 message is >= 12 bytes.
  localparam int unsigned MIN_MSG_LEN    = 7;

  // Message type codes (ASCII)
  localparam logic [7:0] MT_SYSTEM_EVENT        = 8'h53; // 'S'
  localparam logic [7:0] MT_ADD_ORDER           = 8'h41; // 'A'
  localparam logic [7:0] MT_ADD_ORDER_MPID      = 8'h46; // 'F'
  localparam logic [7:0] MT_ORDER_EXECUTED      = 8'h45; // 'E'
  localparam logic [7:0] MT_ORDER_EXECUTED_PX   = 8'h43; // 'C'
  localparam logic [7:0] MT_ORDER_CANCEL        = 8'h58; // 'X'
  localparam logic [7:0] MT_ORDER_DELETE        = 8'h44; // 'D'
  localparam logic [7:0] MT_ORDER_REPLACE       = 8'h55; // 'U'

  // Spec message lengths (bytes, including the 1-byte message type)
  localparam logic [15:0] LEN_SYSTEM_EVENT      = 16'd12;
  localparam logic [15:0] LEN_ADD_ORDER         = 16'd36;
  localparam logic [15:0] LEN_ADD_ORDER_MPID    = 16'd40;
  localparam logic [15:0] LEN_ORDER_EXECUTED    = 16'd31;
  localparam logic [15:0] LEN_ORDER_EXECUTED_PX = 16'd36;
  localparam logic [15:0] LEN_ORDER_CANCEL      = 16'd23;
  localparam logic [15:0] LEN_ORDER_DELETE      = 16'd19;
  localparam logic [15:0] LEN_ORDER_REPLACE     = 16'd35;

  // Returns the spec length for a supported type, 0 for unsupported types.
  function automatic logic [15:0] expected_len(input logic [7:0] t);
    case (t)
      MT_SYSTEM_EVENT:      expected_len = LEN_SYSTEM_EVENT;
      MT_ADD_ORDER:         expected_len = LEN_ADD_ORDER;
      MT_ADD_ORDER_MPID:    expected_len = LEN_ADD_ORDER_MPID;
      MT_ORDER_EXECUTED:    expected_len = LEN_ORDER_EXECUTED;
      MT_ORDER_EXECUTED_PX: expected_len = LEN_ORDER_EXECUTED_PX;
      MT_ORDER_CANCEL:      expected_len = LEN_ORDER_CANCEL;
      MT_ORDER_DELETE:      expected_len = LEN_ORDER_DELETE;
      MT_ORDER_REPLACE:     expected_len = LEN_ORDER_REPLACE;
      default:              expected_len = 16'd0;
    endcase
  endfunction

  // True for message types that carry an Order Reference Number at offset 11.
  function automatic logic has_order_ref(input logic [7:0] t);
    case (t)
      MT_ADD_ORDER, MT_ADD_ORDER_MPID, MT_ORDER_EXECUTED, MT_ORDER_EXECUTED_PX,
      MT_ORDER_CANCEL, MT_ORDER_DELETE, MT_ORDER_REPLACE: has_order_ref = 1'b1;
      default:                                            has_order_ref = 1'b0;
    endcase
  endfunction

  // Normalized decoded message. Fields that do not apply to a type are driven to 0.
  //   order_ref     : A,F,E,C,X,D = Order Reference Number; U = Original Order Reference Number
  //   new_order_ref : U
  //   shares        : A,F = Shares; E,C = Executed Shares; X = Cancelled Shares; U = Shares
  //   price         : A,F = Price; C = Execution Price; U = Price          (Price(4))
  //   stock         : A,F, 8 ASCII chars, first character in bits [63:56]
  //   attribution   : F, 4 ASCII chars (MPID)
  //   match_number  : E,C
  //   printable     : C ('Y'/'N')
  //   side          : A,F ('B'/'S')
  //   event_code    : S
  typedef struct packed {
    logic [7:0]  msg_type;
    logic [15:0] stock_locate;
    logic [15:0] tracking_num;
    logic [47:0] timestamp;
    logic [63:0] order_ref;
    logic [63:0] new_order_ref;
    logic [7:0]  side;
    logic [31:0] shares;
    logic [63:0] stock;
    logic [31:0] price;
    logic [31:0] attribution;
    logic [63:0] match_number;
    logic [7:0]  printable;
    logic [7:0]  event_code;
  } itch_msg_t;

  // MoldUDP64 downstream packet header
  typedef struct packed {
    logic [79:0] session;
    logic [63:0] seq_num;
    logic [15:0] msg_count;
  } mold_hdr_t;

endpackage

`default_nettype wire
