# itch-fpga: lint / simulation / synthesis. One command each:
#
#   make lint         Verilator -Wall on every top and parameterization (static analysis)
#   make test         cocotb regression, every parser pipeline config (PIPE_STAGES 0/1/2):
#                     parser (MoldUDP64 + raw), parser+book, stat_counter unit test
#   make test-icarus  same regressions (reduced size) on Icarus Verilog
#   make soak         long randomized regression: 5 seeds x 2 modes x 3 pipeline configs x
#                     100k parser messages, plus 5 seeds x 3 configs x 200k book messages
#   make mutation     inject RTL bugs, require the testbench to catch every one
#   make synth        sv2v + Yosys: generic LUT6 depth per PIPE_STAGES, UltraScale+ and feed
#   make pnr          optional: nextpnr-xilinx post-route Fmax on xc7a200t (needs openXC7,
#                     scripts/setup_openxc7.sh); not part of CI
#   make ci           lint + test + test-icarus (what GitHub Actions runs)
#   make clean
#
# Knobs: make test MSGS=20000 BOOK_MSGS=30000 SEED=123 PIPES="0 2"  |  PYTHON=... VERILATOR=...

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
PIPES     ?= 0 1 2
# stat_counter unit-test configurations (W:SEG), small so the count wraps many times
CNT_CFGS  ?= 10:2 9:3 8:4

RTL_PARSER := rtl/itch_pkg.sv rtl/stat_counter.sv rtl/itch_parser.sv rtl/itch_top.sv
RTL_FEED   := rtl/itch_pkg.sv rtl/stat_counter.sv rtl/itch_parser.sv rtl/stream_fifo.sv rtl/itch_book.sv rtl/itch_feed_top.sv
RTL_HARN   := rtl/itch_pkg.sv rtl/stat_counter.sv rtl/itch_parser.sv syn/timing_harness.sv
LINT       := $(VERILATOR) --lint-only -Wall

.PHONY: all ci lint test test-mold test-raw test-book test-counter test-icarus soak mutation synth pnr clean

all: lint test
ci: lint test test-icarus

lint:
	@$(VERILATOR) --version
	@n=0; for p in 0 1 2; do for m in 1 0; do \
	  echo "lint itch_top PIPE_STAGES=$$p MOLD_HDR=$$m"; \
	  $(LINT) -GPIPE_STAGES=$$p -GMOLD_HDR=$$m --top-module itch_top $(RTL_PARSER); n=$$((n+1)); \
	done; done; \
	for p in 0 1 2; do \
	  echo "lint itch_feed_top PARSER_PIPE=$$p"; \
	  $(LINT) -GPARSER_PIPE=$$p --top-module itch_feed_top $(RTL_FEED); n=$$((n+1)); \
	done; \
	echo "lint itch_feed_top small (LEVELS=4 NUM_SYMBOLS=64 ORD_BITS=12 MSG_FIFO_DEPTH=4 PARSER_PIPE=2)"; \
	$(LINT) -GLEVELS=4 -GNUM_SYMBOLS=64 -GORD_BITS=12 -GMSG_FIFO_DEPTH=4 -GPARSER_PIPE=2 --top-module itch_feed_top $(RTL_FEED); n=$$((n+1)); \
	for c in $(CNT_CFGS) 32:8; do \
	  echo "lint stat_counter W=$${c%:*} SEG=$${c#*:}"; \
	  $(LINT) -GW=$${c%:*} -GSEG=$${c#*:} --top-module stat_counter rtl/stat_counter.sv; n=$$((n+1)); \
	done; \
	for p in 0 2; do \
	  echo "lint timing_harness PIPE_STAGES=$$p"; \
	  $(LINT) -GPIPE_STAGES=$$p --top-module timing_harness $(RTL_HARN); n=$$((n+1)); \
	done; \
	echo "LINT: PASS (verilator -Wall, 0 warnings, $$n configurations)"

test: test-mold test-raw test-book test-counter
	@echo "TEST: PASS (PIPE_STAGES $(PIPES): parser MoldUDP64, parser raw, parser+book; stat_counter)"

build:
	@mkdir -p build

test-mold: | build
	@for p in $(PIPES); do \
	  $(PYTHON) tb/run.py --top parser --mold 1 --pipe $$p --msgs $(MSGS) --seed $(SEED) 2>&1 | tee build/test_mold_p$$p.log; \
	done

test-raw: | build
	@for p in $(PIPES); do \
	  $(PYTHON) tb/run.py --top parser --mold 0 --pipe $$p --msgs $(MSGS) --seed $(SEED) 2>&1 | tee build/test_raw_p$$p.log; \
	done

test-book: | build
	@for p in $(PIPES); do \
	  $(PYTHON) tb/run.py --top feed --pipe $$p --book-msgs $(BOOK_MSGS) --seed $(SEED) 2>&1 | tee build/test_book_p$$p.log; \
	done

test-counter: | build
	@for c in $(CNT_CFGS); do \
	  $(PYTHON) tb/run.py --top counter --cnt-w $${c%:*} --cnt-seg $${c#*:} --cycles 20000 --seed $(SEED) 2>&1 \
	    | tee build/test_counter_$${c/:/_}.log; \
	done

test-icarus: | build
	@for p in $(PIPES); do \
	  $(PYTHON) tb/run.py --sim icarus --top parser --mold 1 --pipe $$p --msgs 2000 --seed $(SEED) 2>&1 | tee build/test_icarus_parser_p$$p.log; \
	  $(PYTHON) tb/run.py --sim icarus --top feed --pipe $$p --book-msgs 3000 --seed $(SEED) 2>&1 | tee build/test_icarus_book_p$$p.log; \
	done
	$(PYTHON) tb/run.py --sim icarus --top parser --mold 0 --pipe 2 --msgs 2000 --seed $(SEED) 2>&1 | tee build/test_icarus_raw_p2.log
	$(PYTHON) tb/run.py --sim icarus --top counter --cnt-w 10 --cnt-seg 2 --cycles 20000 --seed $(SEED) 2>&1 | tee build/test_icarus_counter.log

soak: | build
	@for s in $(SOAK_SEEDS); do for p in $(PIPES); do for m in 1 0; do \
	  $(PYTHON) tb/run.py --top parser --mold $$m --pipe $$p --msgs 100000 --seed $$s > build/soak_s$${s}_p$${p}_m$${m}.log 2>&1 \
	    || { echo "SOAK FAIL seed=$$s pipe=$$p mold=$$m (build/soak_s$${s}_p$${p}_m$${m}.log)"; exit 1; }; \
	  grep "SUMMARY TOTAL" build/soak_s$${s}_p$${p}_m$${m}.log | sed "s/.*SUMMARY/seed=$$s pipe=$$p mold=$$m:/"; \
	done; \
	$(PYTHON) tb/run.py --top feed --pipe $$p --book-msgs 200000 --seed $$s > build/soak_book_s$${s}_p$${p}.log 2>&1 \
	  || { echo "SOAK FAIL book seed=$$s pipe=$$p"; exit 1; }; \
	grep "SUMMARY book_random" build/soak_book_s$${s}_p$${p}.log | sed "s/.*SUMMARY/seed=$$s pipe=$$p:/" | cut -c1-200; \
	done; done

mutation: | build
	$(PYTHON) scripts/mutation_test.py

synth:
	@mkdir -p syn/out
	$(SV2V) $(RTL_PARSER) > syn/out/itch_top_sv2v.v
	$(SV2V) $(RTL_FEED) > syn/out/itch_feed_top_sv2v.v
	@for p in 0 1 2; do \
	  echo "yosys: itch_top MOLD_HDR=1 PIPE_STAGES=$$p (generic LUT6 depth, UltraScale+)"; \
	  $(YOSYS) -q -l syn/out/yosys_generic_p$$p.log -p "read_verilog syn/out/itch_top_sv2v.v; chparam -set MOLD_HDR 1 -set PIPE_STAGES $$p itch_top; script syn/synth_generic.ys"; \
	  for f in stat_lut6.txt ltp_lut6.txt lut6.json; do mv syn/out/$$f syn/out/$${f%.*}_p$$p.$${f##*.}; done; \
	  python3 scripts/depth_report.py syn/out/lut6_p$$p.json --top 12 --trace 1 > syn/out/depth_p$$p.txt; \
	  $(YOSYS) -q -l syn/out/yosys_xilinx_p$$p.log -p "read_verilog syn/out/itch_top_sv2v.v; chparam -set MOLD_HDR 1 -set PIPE_STAGES $$p itch_top; script syn/synth_xilinx.ys"; \
	  mv syn/out/stat_xilinx.txt syn/out/stat_xilinx_p$$p.txt; \
	done
	$(YOSYS) -q -l syn/out/yosys_feed_xilinx.log -s syn/synth_feed_xilinx.ys
	@python3 scripts/synth_report.py | tee syn/out/summary.md

pnr:
	@for p in 0 1 2; do scripts/pnr_xc7.sh $$p 1 2 3; done

clean:
	rm -rf build obj_dir tb/results.xml tb/__pycache__ syn/out *.vcd *.fst
