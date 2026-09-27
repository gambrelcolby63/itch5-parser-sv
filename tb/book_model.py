"""
Reference models for itch_book.

* BookModel  : bit-exact mirror of the RTL semantics (direct-mapped order table with
               insert-collision drops, LEVELS-deep sorted levels with truncation).
               Every DUT book event is compared against it.
* IdealBook  : unbounded order book (dict of orders, all price levels). Used only to
               *measure* how often the bounded hardware book differs from the truth.
* Market     : generator of a self-consistent ITCH order flow (executes/cancels/deletes/
               replaces only reference live orders).
"""
from __future__ import annotations

import random
from collections import Counter

from itch_model import SUPPORTED, make_supported, make_unsupported

MASK32 = 0xFFFFFFFF
BOOK_TYPES = set(b"AFECXDU")


class BookModel:
    def __init__(self, num_symbols=256, levels=8, ord_bits=16, locate_bits=14):
        self.L = levels
        self.ord_bits = ord_bits
        self.locate_bits = locate_bits
        self.sub: dict[int, int] = {}                 # locate -> slot
        self.ord: list[list | None] = [None] * (1 << ord_bits)   # [ref, slot, side, price, shares]
        self.books: dict[tuple, dict] = {}            # (slot, side) -> {"trunc", "lv": [[p, q], ...]}
        self.stats = Counter()

    def subscribe(self, locate: int, slot: int):
        self.sub[locate] = slot

    def _book(self, slot, side):
        return self.books.setdefault((slot, side), {"trunc": 0, "lv": []})

    @staticmethod
    def _better(side, a, b):
        return a < b if side else a > b

    def _lvl_sub(self, b, price, q):
        for i, (p, qty) in enumerate(b["lv"]):
            if p == price:
                if qty > q:
                    b["lv"][i][1] = qty - q
                else:
                    del b["lv"][i]
                return
        self.stats["lvl_miss"] += 1

    def _lvl_add(self, b, side, price, q):
        lv = b["lv"]
        for i, (p, qty) in enumerate(lv):
            if p == price:
                lv[i][1] = (qty + q) & MASK32
                return
        k = sum(1 for p, _ in lv if self._better(side, p, price))
        if k == self.L:
            self.stats["lvl_drop"] += 1
            b["trunc"] = 1
            return
        lv.insert(k, [price, q])
        if len(lv) > self.L:
            lv.pop()
            self.stats["lvl_drop"] += 1
            b["trunc"] = 1

    def process(self, m: dict):
        """Apply one decoded message; return the book event tuple or None."""
        t = m["msg_type"]
        if t not in BOOK_TYPES:
            return None
        loc = m["stock_locate"]
        if loc >= (1 << self.locate_bits) or loc not in self.sub:
            self.stats["unsub"] += 1
            return None
        mask = (1 << self.ord_bits) - 1
        ref = m["order_ref"]
        idx_a = ref & mask
        if t in b"AF":
            side = 1 if m["side"] == ord("S") else 0
            slot = self.sub[loc]
            if self.ord[idx_a] is not None:
                self.stats["collide"] += 1
                return None
            self.ord[idx_a] = [ref, slot, side, m["price"], m["shares"]]
            b = self._book(slot, side)
            self._lvl_add(b, side, m["price"], m["shares"])
            return self._event(m, slot, side, b)
        e = self.ord[idx_a]
        if e is None or e[0] != ref:
            self.stats["miss"] += 1
            return None
        eref, slot, side, price, shares = e
        b = self._book(slot, side)
        if t in b"ECX":
            n = m["shares"]
            if shares > n:
                e[4] = shares - n
                q = n
            else:
                self.ord[idx_a] = None
                q = shares
            self._lvl_sub(b, price, q)
        elif t == ord("D"):
            self.ord[idx_a] = None
            self._lvl_sub(b, price, shares)
        else:  # 'U'
            new_ref = m["new_order_ref"]
            idx_b = new_ref & mask
            free_b = self.ord[idx_b] is None or idx_b == idx_a
            self._lvl_sub(b, price, shares)
            self.ord[idx_a] = None
            if free_b:
                self.ord[idx_b] = [new_ref, slot, side, m["price"], m["shares"]]
                self._lvl_add(b, side, m["price"], m["shares"])
            else:
                self.stats["collide"] += 1
        return self._event(m, slot, side, b)

    def _event(self, m, slot, side, b):
        lv = b["lv"] + [[0, 0]] * (self.L - len(b["lv"]))
        self.stats["events"] += 1
        return (slot, side, len(b["lv"]), b["trunc"], tuple(p for p, _ in lv), tuple(q for _, q in lv),
                m["msg_type"], m["stock_locate"], m["timestamp"])


class IdealBook:
    """Unbounded book: exact truth to compare the bounded hardware book against."""

    def __init__(self, subscribed: set[int]):
        self.subscribed = subscribed
        self.orders: dict[int, list] = {}              # ref -> [locate, side, price, shares]
        self.levels: dict[tuple, Counter] = {}         # (locate, side) -> Counter(price -> qty)

    def _lv(self, loc, side):
        return self.levels.setdefault((loc, side), Counter())

    def process(self, m: dict):
        t = m["msg_type"]
        if t not in BOOK_TYPES or m["stock_locate"] not in self.subscribed:
            return
        ref = m["order_ref"]
        if t in b"AF":
            side = 1 if m["side"] == ord("S") else 0
            self.orders[ref] = [m["stock_locate"], side, m["price"], m["shares"]]
            self._lv(m["stock_locate"], side)[m["price"]] += m["shares"]
            return
        o = self.orders.get(ref)
        if o is None:
            return
        loc, side, price, shares = o
        lv = self._lv(loc, side)
        if t in b"ECX":
            q = min(shares, m["shares"])
            o[3] -= q
            if o[3] == 0:
                del self.orders[ref]
        else:
            q = shares
            del self.orders[ref]
        lv[price] -= q
        if lv[price] <= 0:
            del lv[price]
        if t == ord("U"):
            self.orders[m["new_order_ref"]] = [loc, side, m["price"], m["shares"]]
            lv[m["price"]] += m["shares"]

    def top(self, loc, side, n):
        lv = self.levels.get((loc, side), Counter())
        prices = sorted(lv, reverse=(side == 0))[:n]
        return [(p, lv[p]) for p in prices]


class Market:
    """Self-consistent synthetic order flow over a set of stock locates."""

    TICK = 100  # $0.01 in Price(4)

    def __init__(self, rng: random.Random, locates: list[int], target_live=600, max_depth_ticks=14):
        self.rng = rng
        self.locates = locates
        self.mid = {l: rng.randrange(5_0000, 500_0000) // self.TICK * self.TICK for l in locates}
        self.live: dict[int, list] = {}      # ref -> [locate, side, price, shares]
        self.refs: list[int] = []            # for O(1) random choice
        self.pos: dict[int, int] = {}
        self.next_ref = rng.randrange(1, 2**36)
        self.target_live = target_live
        self.max_depth_ticks = max_depth_ticks
        self.ts = rng.randrange(9 * 3600 * 10**9, 10 * 3600 * 10**9)

    def _new_ref(self):
        self.next_ref += self.rng.randint(1, 4)
        return self.next_ref

    def _add_live(self, ref, rec):
        self.live[ref] = rec
        self.pos[ref] = len(self.refs)
        self.refs.append(ref)

    def _del_live(self, ref):
        i = self.pos.pop(ref)
        last = self.refs.pop()
        if last != ref:
            self.refs[i] = last
            self.pos[last] = i
        del self.live[ref]

    def _price(self, loc, side):
        k = min(int(self.rng.expovariate(0.35)), self.max_depth_ticks)
        return max(self.TICK, self.mid[loc] + (k + 1) * self.TICK * (1 if side else -1))

    def _shares(self):
        return self.rng.choice([100, 100, 100, 200, 300, 500, 1000]) if self.rng.random() < 0.8 \
            else self.rng.randint(1, 5000)

    def _base(self, t, loc):
        self.ts += self.rng.randint(1, 20_000)
        return {"msg_type": ord(t), "stock_locate": loc, "tracking_num": self.rng.getrandbits(16),
                "timestamp": self.ts % (86_400 * 10**9)}

    def next_message(self, p_unsupported=0.05) -> bytes:
        rng = self.rng
        r = rng.random()
        if r < p_unsupported:
            return make_unsupported(rng)
        if r < p_unsupported + 0.01:
            return make_supported(rng, "S")
        n_live = len(self.live)
        p_add = 0.75 if n_live < self.target_live * 0.8 else (0.25 if n_live > self.target_live * 1.2 else 0.4)
        if n_live == 0 or rng.random() < p_add:
            t = "F" if rng.random() < 0.12 else "A"
            loc = rng.choice(self.locates)
            side = rng.random() < 0.5
            ref = self._new_ref()
            f = self._base(t, loc)
            f.update(order_ref=ref, side=ord("S" if side else "B"), shares=self._shares(),
                     stock=b"SYM%05d" % loc, price=self._price(loc, side), attribution=b"NSDQ")
            self._add_live(ref, [loc, side, f["price"], f["shares"]])
            return encode(t, f)
        ref = rng.choice(self.refs)
        loc, side, price, shares = self.live[ref]
        t = rng.choices("DEXCU", weights=[40, 18, 15, 5, 22])[0]
        f = self._base(t, loc)
        f["order_ref"] = ref
        if t == "D":
            self._del_live(ref)
        elif t in "EXC":
            n = shares if rng.random() < 0.35 else rng.randint(1, shares)
            f["shares"] = n
            if t in "EC":
                f["match_number"] = rng.getrandbits(40)
            if t == "C":
                f["printable"] = ord(rng.choice("YN"))
                f["price"] = self._price(loc, side)
            if n >= shares:
                self._del_live(ref)
            else:
                self.live[ref][3] = shares - n
        else:  # U
            new = self._new_ref()
            f.update(new_order_ref=new, shares=self._shares(), price=self._price(loc, side))
            self._del_live(ref)
            self._add_live(new, [loc, side, f["price"], f["shares"]])
        return encode(t, f)


def encode(t: str, fields: dict) -> bytes:
    """Build a spec-exact message from a field dict (missing fields = 0)."""
    ln, layout = SUPPORTED[t]
    msg = bytearray(ln)
    msg[0] = ord(t)
    for name, off, flen, _ in layout:
        v = fields.get(name, 0)
        if isinstance(v, (bytes, bytearray)):
            msg[off:off + flen] = bytes(v)[:flen].ljust(flen, b" ")
        else:
            msg[off:off + flen] = int(v).to_bytes(flen, "big")
    return bytes(msg)
