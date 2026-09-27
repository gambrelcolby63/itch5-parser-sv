# itch-fpga: lint / simulation / synthesis. One command each:
#
#   make lint         Verilator -Wall on every top and parameterization (static analysis)
#   make test         cocotb regression: parser (MoldUDP64 + raw) and parser+book
#   make test-icarus  same regressions (reduced size) on Icarus Verilog
#   make soak         long randomized parser regression, 5 seeds x 2 modes x 100k messages
#   make mutation     inject 20 RTL bugs, require the testbench to catch every one
#   make synth        sv2v + Yosys: parser (generic, LUT6 depth, UltraScale+) and feed (UltraScale+)
#   make ci           lint + test + test-icarus (what GitHub Actions runs)
#   make clean
#
# Knobs: make test MSGS=20000 BOOK_MSGS=30000 SEED=123   |   PYTHON=... VERILATOR=...

SHELL       := /bin/bash
.SHELLFLAGS := -eo pipefail -c

# Prefer a locally built Verilator >= 5.036 (cocotb 2.x requirement) if present.
VERILATOR_BIN_DIR ?= /opt/verilator-5.052/bin
ifneq ($(wildcard $(VERILATOR_BIN_DIR)/verilator),)
export PATH := $(VERILATOR_BIN_DIR):$(PATH)
endif
VERILATOR ?= verilator
PYTHON    ?= $(if $(wildcard .venv/bin/python),.venv/bin/python,python3)
YOSYS     ?= yosys
SV2V      ?= sv2v
MSGS      ?= 20000
BOOK_MSGS ?= 30000
SEED      ?= 20260927
SOAK_SEEDS ?= 1 2 3 4 5

RTL_PARSER := rtl/itch_pkg.sv rtl/itch_parser.sv rtl/itch_top.sv
RTL_FEED   := rtl/itch_pkg.sv rtl/itch_parser.sv rtl/stream_fifo.sv rtl/itch_book.sv rtl/itch_feed_top.sv
LINT       := $(VERILATOR) --lint-only -Wall

.PHONY: all ci lint test test-mold test-raw test-book test-icarus soak mutation synth clean

all: lint test
ci: lint test test-icarus

lint:
	@$(VERILATOR) --version
	$(LINT) -GMOLD_HDR=1 --top-module itch_top $(RTL_PARSER)
	$(LINT) -GMOLD_HDR=0 --top-module itch_top $(RTL_PARSER)
	$(LINT) --top-module itch_feed_top $(RTL_FEED)
	$(LINT) -GLEVELS=4 -GNUM_SYMBOLS=64 -GORD_BITS=12 -GMSG_FIFO_DEPTH=4 --top-module itch_feed_top $(RTL_FEED)
	@echo "LINT: PASS (verilator -Wall, 0 warnings, 4 configurations)"

test: test-mold test-raw test-book
	@echo "TEST: PASS (parser MoldUDP64, parser raw, parser+book)"

build:
	@mkdir -p build

test-mold: | build
	$(PYTHON) tb/run.py --top parser --mold 1 --msgs $(MSGS) --seed $(SEED) 2>&1 | tee build/test_mold.log

test-raw: | build
	$(PYTHON) tb/run.py --top parser --mold 0 --msgs $(MSGS) --seed $(SEED) 2>&1 | tee build/test_raw.log

test-book: | build
	$(PYTHON) tb/run.py --top feed --book-msgs $(BOOK_MSGS) --seed $(SEED) 2>&1 | tee build/test_book.log

test-icarus: | build
	$(PYTHON) tb/run.py --sim icarus --top parser --mold 1 --msgs 2000 --seed $(SEED) 2>&1 | tee build/test_icarus_parser.log
	$(PYTHON) tb/run.py --sim icarus --top feed --book-msgs 3000 --seed $(SEED) 2>&1 | tee build/test_icarus_book.log

soak: | build
	@for s in $(SOAK_SEEDS); do for m in 1 0; do \
	  $(PYTHON) tb/run.py --top parser --mold $$m --msgs 100000 --seed $$s > build/soak_s$${s}_m$${m}.log 2>&1 \
	    || { echo "SOAK FAIL seed=$$s mold=$$m (build/soak_s$${s}_m$${m}.log)"; exit 1; }; \
	  grep "SUMMARY TOTAL" build/soak_s$${s}_m$${m}.log | sed "s/.*SUMMARY/seed=$$s:/"; \
	done; \
	$(PYTHON) tb/run.py --top feed --book-msgs 200000 --seed $$s > build/soak_book_s$${s}.log 2>&1 \
	  || { echo "SOAK FAIL book seed=$$s"; exit 1; }; \
	grep "SUMMARY book_random" build/soak_book_s$${s}.log | sed "s/.*SUMMARY/seed=$$s:/" | cut -c1-200; \
	done

mutation: | build
	$(PYTHON) scripts/mutation_test.py

synth:
	@mkdir -p syn/out
	$(SV2V) $(RTL_PARSER) > syn/out/itch_top_sv2v.v
	$(SV2V) $(RTL_FEED) > syn/out/itch_feed_top_sv2v.v
	$(YOSYS) -q -l syn/out/yosys_generic.log -s syn/synth_generic.ys
	$(YOSYS) -q -l syn/out/yosys_xilinx.log  -s syn/synth_xilinx.ys
	$(YOSYS) -q -l syn/out/yosys_feed_xilinx.log -s syn/synth_feed_xilinx.ys
	@python3 scripts/synth_report.py | tee syn/out/summary.md

clean:
	rm -rf build obj_dir tb/results.xml tb/__pycache__ syn/out *.vcd *.fst
