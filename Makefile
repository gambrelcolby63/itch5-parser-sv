# ITCH 5.0 FPGA parser - lint / simulation / synthesis
#
#   make lint        Verilator -Wall lint (both MOLD_HDR configurations)
#   make test        cocotb regression, MoldUDP64 mode and raw-block mode
#   make test-mold   cocotb regression, MOLD_HDR=1 only
#   make test-raw    cocotb regression, MOLD_HDR=0 only
#   make test-icarus Same regression on Icarus Verilog (cross-simulator check, slower)
#   make soak        Longer randomized regression over several seeds (both modes)
#   make mutation    Inject RTL bugs and check the testbench catches all of them
#   make synth       sv2v + Yosys generic / LUT6 / Xilinx UltraScale+ synthesis -> syn/out/
#   make clean
#
# Override tools:  make VERILATOR=/path/to/verilator PYTHON=/path/to/python
# Knobs:           make test MSGS=20000 SEED=123

VERILATOR_ROOT_BIN ?= /opt/verilator-5.052/bin
export PATH := $(VERILATOR_ROOT_BIN):$(PATH)
VERILATOR ?= verilator
PYTHON    ?= $(if $(wildcard .venv/bin/python),.venv/bin/python,python3)
YOSYS     ?= yosys
SV2V      ?= sv2v
SOAK_SEEDS ?= 1 2 3 4 5
MSGS      ?= 20000
SEED      ?= 20260927

RTL := rtl/itch_pkg.sv rtl/itch_parser.sv rtl/itch_top.sv

.PHONY: all lint test test-mold test-raw test-icarus soak mutation synth clean

all: lint test

lint:
	@$(VERILATOR) --version
	$(VERILATOR) --lint-only -Wall -GMOLD_HDR=1 --top-module itch_top $(RTL)
	$(VERILATOR) --lint-only -Wall -GMOLD_HDR=0 --top-module itch_top $(RTL)
	@echo "LINT: PASS (verilator -Wall, 0 warnings)"

test: test-mold test-raw

test-mold:
	$(PYTHON) tb/run.py --mold 1 --msgs $(MSGS) --seed $(SEED) 2>&1 | tee build/test_mold.log
	@grep -q "TESTS=6 PASS=6 FAIL=0" build/test_mold.log

test-raw:
	$(PYTHON) tb/run.py --mold 0 --msgs $(MSGS) --seed $(SEED) 2>&1 | tee build/test_raw.log
	@grep -q "TESTS=6 PASS=6 FAIL=0" build/test_raw.log

test-icarus: | build
	$(PYTHON) tb/run.py --sim icarus --mold 1 --msgs 2000 --seed $(SEED) 2>&1 | tee build/test_icarus.log
	@grep -q "TESTS=6 PASS=6 FAIL=0" build/test_icarus.log

soak: | build
	@set -e; for s in $(SOAK_SEEDS); do for m in 1 0; do \
	  $(PYTHON) tb/run.py --mold $$m --msgs 100000 --seed $$s > build/soak_s$${s}_m$${m}.log 2>&1; \
	  grep -q "TESTS=6 PASS=6 FAIL=0" build/soak_s$${s}_m$${m}.log || { echo "SOAK FAIL seed=$$s mold=$$m"; exit 1; }; \
	  grep "SUMMARY TOTAL" build/soak_s$${s}_m$${m}.log | sed "s/.*SUMMARY/seed=$$s:/"; \
	done; done

mutation: | build
	$(PYTHON) scripts/mutation_test.py

synth:
	@mkdir -p syn/out
	$(SV2V) $(RTL) > syn/out/itch_top_sv2v.v
	$(YOSYS) -q -l syn/out/yosys_generic.log -s syn/synth_generic.ys
	$(YOSYS) -q -l syn/out/yosys_xilinx.log  -s syn/synth_xilinx.ys
	@echo "Reports: syn/out/yosys_generic.log syn/out/yosys_xilinx.log"

clean:
	rm -rf build obj_dir tb/results.xml tb/__pycache__ syn/out *.vcd *.fst

build:
	@mkdir -p build

test-mold test-raw: | build
