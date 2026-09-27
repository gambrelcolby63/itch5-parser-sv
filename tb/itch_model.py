"""
Golden model for the Nasdaq TotalView-ITCH 5.0 parser.

* Message layouts follow the Nasdaq TotalView-ITCH 5.0 specification
  (https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHspecification.pdf).
* Framing follows MoldUDP64 1.00
  (https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/moldudp64.pdf).

The model is intentionally written independently of the RTL: it builds byte-accurate
messages from a field table, decodes them back with `struct`, and packs them into
64-bit AXI-Stream beats (lane 0 = first byte on the wire).
"""
from __future__ import annotations

import random
import struct
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Spec tables: (name, offset, length, kind) ; kind in {"int", "alpha", "price"}
# Offsets include the 1-byte Message Type at offset 0.
# ---------------------------------------------------------------------------
HDR = [("stock_locate", 1, 2, "int"), ("tracking_num", 3, 2, "int"), ("timestamp", 5, 6, "int")]

SUPPORTED = {
    "S": (12, HDR + [("event_code", 11, 1, "alpha")]),
    "A": (36, HDR + [("order_ref", 11, 8, "int"), ("side", 19, 1, "alpha"), ("shares", 20, 4, "int"),
                     ("stock", 24, 8, "alpha"), ("price", 32, 4, "price")]),
    "F": (40, HDR + [("order_ref", 11, 8, "int"), ("side", 19, 1, "alpha"), ("shares", 20, 4, "int"),
                     ("stock", 24, 8, "alpha"), ("price", 32, 4, "price"), ("attribution", 36, 4, "alpha")]),
    "E": (31, HDR + [("order_ref", 11, 8, "int"), ("shares", 19, 4, "int"), ("match_number", 23, 8, "int")]),
    "C": (36, HDR + [("order_ref", 11, 8, "int"), ("shares", 19, 4, "int"), ("match_number", 23, 8, "int"),
                     ("printable", 31, 1, "alpha"), ("price", 32, 4, "price")]),
    "X": (23, HDR + [("order_ref", 11, 8, "int"), ("shares", 19, 4, "int")]),
    "D": (19, HDR + [("order_ref", 11, 8, "int")]),
    # 'U': Original Order Reference Number is reported on order_ref.
    "U": (35, HDR + [("order_ref", 11, 8, "int"), ("new_order_ref", 19, 8, "int"), ("shares", 27, 4, "int"),
                     ("price", 31, 4, "price")]),
}

# Other ITCH 5.0 message types (not decoded by the RTL, must be skipped by length).
# Lengths computed from the spec field tables (last offset + length).
UNSUPPORTED_ITCH = {
    "R": 39, "H": 25, "Y": 20, "L": 26, "V": 35, "W": 12, "K": 28, "J": 35, "h": 21,
    "P": 44, "Q": 40, "B": 19, "I": 50, "N": 20, "O": 48,
}

OUT_FIELDS = ["msg_type", "stock_locate", "tracking_num", "timestamp", "order_ref", "new_order_ref",
              "side", "shares", "stock", "price", "attribution", "match_number", "printable", "event_code"]

MIN_MSG_LEN = 7  # RTL requirement (see itch_pkg.sv)

SYMBOLS = [b"AAPL    ", b"MSFT    ", b"NVDA    ", b"SPY     ", b"QQQ     ", b"TSLA    ", b"AMZN    ",
           b"GOOGL   ", b"META    ", b"IWM     ", b"ZVZZT   "]
MPIDS = [b"NSDQ", b"GSCO", b"MSCO", b"CDRG", b"VIRT", b"JPMS"]


def decode(msg: bytes) -> dict | None:
    """Decode a message into the RTL's normalized output (non-applicable fields = 0).
    Returns None for types the RTL does not decode or when the length is wrong."""
    t = chr(msg[0])
    if t not in SUPPORTED or len(msg) != SUPPORTED[t][0]:
        return None
    out = {k: 0 for k in OUT_FIELDS}
    out["msg_type"] = msg[0]
    for name, off, ln, _ in SUPPORTED[t][1]:
        out[name] = int.from_bytes(msg[off:off + ln], "big")
    return out


def _field_bytes(rng: random.Random, name: str, ln: int, t: str) -> bytes:
    if name == "timestamp":
        return rng.randrange(0, 86_400 * 10**9).to_bytes(6, "big")
    if name == "side":
        return rng.choice([b"B", b"S"])
    if name == "stock":
        return rng.choice(SYMBOLS)
    if name == "attribution":
        return rng.choice(MPIDS)
    if name == "printable":
        return rng.choice([b"Y", b"N"])
    if name == "event_code":
        return rng.choice([b"O", b"S", b"Q", b"M", b"E", b"C"])
    if name == "price":
        return rng.randrange(0, 0x77359400 + 1).to_bytes(4, "big")  # max price(4) per spec
    # Integers: bias toward interesting values (0, all-ones, single bytes) to catch lane bugs.
    r = rng.random()
    if r < 0.05:
        return bytes(ln)
    if r < 0.10:
        return b"\xff" * ln
    if r < 0.15:
        v = bytearray(ln)
        v[rng.randrange(ln)] = rng.randrange(1, 256)
        return bytes(v)
    return rng.getrandbits(8 * ln).to_bytes(ln, "big")


def make_supported(rng: random.Random, t: str) -> bytes:
    ln, fields = SUPPORTED[t]
    msg = bytearray(ln)
    msg[0] = ord(t)
    for name, off, flen, _ in fields:
        msg[off:off + flen] = _field_bytes(rng, name, flen, t)
    return bytes(msg)


def make_unsupported(rng: random.Random) -> bytes:
    """Either a real (undecoded) ITCH type with its spec length, or a synthetic type
    code with an arbitrary length to exercise long skips."""
    if rng.random() < 0.7:
        t = rng.choice(list(UNSUPPORTED_ITCH))
        ln = UNSUPPORTED_ITCH[t]
        code = ord(t)
    else:
        code = rng.choice([c for c in range(256) if chr(c) not in SUPPORTED])
        ln = rng.choice([MIN_MSG_LEN, 8, 9, 15, 16, 17, 63, 64, 65, rng.randrange(MIN_MSG_LEN, 600)])
    return bytes([code]) + bytes(rng.getrandbits(8) for _ in range(ln - 1))


def random_message(rng: random.Random, p_unsupported: float = 0.2) -> bytes:
    if rng.random() < p_unsupported:
        return make_unsupported(rng)
    # Rough HFT-like mix: adds / deletes / executes dominate.
    t = rng.choices("AFECXDUS", weights=[30, 6, 10, 4, 8, 22, 12, 2])[0]
    return make_supported(rng, t)


def block(msg: bytes) -> bytes:
    """MoldUDP64 message block: 2-byte big-endian length + message."""
    return struct.pack(">H", len(msg)) + msg


def mold_packet(session: bytes, seq: int, msgs: list[bytes], count: int | None = None) -> bytes:
    assert len(session) == 10
    cnt = len(msgs) if count is None else count
    return session + struct.pack(">QH", seq, cnt) + b"".join(block(m) for m in msgs)


# ---------------------------------------------------------------------------
# AXI-Stream packing
# ---------------------------------------------------------------------------
@dataclass
class Beat:
    data: int
    keep: int
    last: int
    # indices (into the global expected list) of messages whose LAST byte is in this beat
    ends: list[int] = field(default_factory=list)
    # indices of messages whose byte 18 (end of order ref) is in this beat
    early: list[int] = field(default_factory=list)


def pack_frame(frame: bytes, byte_tags: dict[int, tuple[str, int]] | None = None,
               sparse_rng: random.Random | None = None, null_last: bool = False) -> list[Beat]:
    """Pack one tlast-delimited frame into beats. byte_tags maps a byte index in the frame
    to ("end"|"early", expected_msg_index). Normally beats are full (8 bytes) except the
    last; with sparse_rng, beats carry a random 1..8 bytes (tkeep contiguous from lane 0)
    and the unused upper lanes are filled with junk. With null_last, the frame ends with an
    extra beat that carries no bytes (tkeep = 0, tlast = 1), which AXI4-Stream allows."""
    beats = []
    i = 0
    while i < len(frame):
        n = 8 if sparse_rng is None or sparse_rng.random() < 0.5 else sparse_rng.randint(1, 8)
        chunk = frame[i:i + n]
        data = int.from_bytes(chunk, "little")
        if sparse_rng is not None and len(chunk) < 8:
            data |= sparse_rng.getrandbits(64) & ~((1 << (8 * len(chunk))) - 1) & (2**64 - 1)
        b = Beat(data=data, keep=(1 << len(chunk)) - 1, last=int(i + n >= len(frame)))
        if byte_tags:
            for j in range(i, i + len(chunk)):
                if j in byte_tags:
                    for kind, idx in byte_tags[j]:
                        (b.ends if kind == "end" else b.early).append(idx)
        beats.append(b)
        i += n
    if null_last:
        if beats:
            beats[-1].last = 0
        beats.append(Beat(data=(sparse_rng or random.Random(len(frame))).getrandbits(64), keep=0, last=1))
    return beats


class StreamBuilder:
    """Accumulates frames and the expected decoder output."""

    def __init__(self, mold: bool, session: bytes = b"ITCHSESS01", seq: int = 1,
                 sparse_rng: random.Random | None = None):
        self.mold = mold
        self.sparse_rng = sparse_rng
        self.session = session
        self.seq = seq
        self.beats: list[Beat] = []
        self.expected: list[dict] = []        # decoded messages, in order
        self.expected_early: list[tuple] = [] # (type, locate, order_ref)
        self.expected_hdrs: list[tuple] = []  # (session, seq, count)
        self.n_blocks = 0
        self.n_unsupported = 0
        self.n_frames = 0
        self.n_bytes = 0

    def add_frame(self, msgs: list[bytes], count: int | None = None, raw_tail: bytes = b"",
                  expect: bool = True, null_last: bool | None = None):
        """Add one frame. With mold=True a MoldUDP64 header is prepended. null_last ends the
        frame with an empty (tkeep = 0) tlast beat; by default 10% of sparse frames do."""
        if self.mold:
            prefix = self.session + struct.pack(">QH", self.seq, len(msgs) if count is None else count)
            if expect:
                self.expected_hdrs.append((int.from_bytes(self.session, "big"), self.seq,
                                           len(msgs) if count is None else count))
            self.seq += len(msgs)
        else:
            prefix = b""
        tags: dict[int, list] = {}
        pos = len(prefix)
        body = bytearray()
        for m in msgs:
            blk = block(m)
            d = decode(m)
            if expect and d is not None:
                idx = len(self.expected)
                self.expected.append(d)
                tags.setdefault(pos + len(blk) - 1, []).append(("end", idx))
                if chr(m[0]) in "AFECXDU":
                    eidx = len(self.expected_early)
                    self.expected_early.append((d["msg_type"], d["stock_locate"], d["order_ref"]))
                    tags.setdefault(pos + 2 + 18, []).append(("early", eidx))
            elif expect:
                self.n_unsupported += 1
            body += blk
            pos += len(blk)
            self.n_blocks += 1
        # A raw (corrupt/truncated) tail that still starts with a valid-looking block
        # header for an order-ref type produces a *speculative* early strobe as soon as
        # its message byte 18 arrives, exactly like the RTL. Mirror that here.
        if expect and len(raw_tail) >= 2 + 19:
            tl = int.from_bytes(raw_tail[0:2], "big")
            tt = chr(raw_tail[2])
            if tt in "AFECXDU" and tl == SUPPORTED[tt][0]:
                m = raw_tail[2:]
                eidx = len(self.expected_early)
                self.expected_early.append((m[0], int.from_bytes(m[1:3], "big"),
                                            int.from_bytes(m[11:19], "big")))
                tags.setdefault(pos + 2 + 18, []).append(("early", eidx))
        frame = prefix + bytes(body) + raw_tail
        if null_last is None:
            null_last = self.sparse_rng is not None and self.sparse_rng.random() < 0.1
        self.beats += pack_frame(frame, tags, self.sparse_rng, null_last)
        self.n_frames += 1
        self.n_bytes += len(frame)
        return frame
