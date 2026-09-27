# ITCH 5.0 FPGA parser - lint / simulation / synthesis
#
#   make lint        Verilator -Wall lint (both MOLD_HDR configurations)
#   make test        cocotb regression, MoldUDP64 mode and raw-block mode
#   make test-mold   cocotb regression, MOLD_HDR=1 only
#   make test-raw    cocotb regression, MOLD_HDR=0 only
#   make synth       Yosys generic + Xilinx (synth_xilinx) synthesis, reports in syn/
#   make clean
#
# Override tools:  make VERILATOR=/path/to/verilator PYTHON=/path/to/python
# Knobs:           make test MSGS=20000 SEED=123

VERILATOR_ROOT_BIN ?= /opt/verilator-5.052/bin
export PATH := $(VERILATOR_ROOT_BIN):$(PATH)
VERILATOR ?= verilator
PYTHON    ?= $(if $(wildcard .venv/bin/python),.venv/bin/python,python3)
YOSYS     ?= yosys
MSGS      ?= 20000
SEED      ?= 20260927

RTL := rtl/itch_pkg.sv rtl/itch_parser.sv rtl/itch_top.sv

.PHONY: all lint test test-mold test-raw synth clean

all: lint test

lint:
	@$(VERILATOR) --version
	$(VERILATOR) --lint-only -Wall -GMOLD_HDR=1 --top-module itch_top $(RTL)
	$(VERILATOR) --lint-only -Wall -GMOLD_HDR=0 --top-module itch_top $(RTL)
	@echo "LINT: PASS (verilator -Wall, 0 warnings)"

test: test-mold test-raw

test-mold:
	$(PYTHON) tb/run.py --mold 1 --msgs $(MSGS) --seed $(SEED) 2>&1 | tee build/test_mold.log
	@grep -q "TESTS=5 PASS=5 FAIL=0" build/test_mold.log

test-raw:
	$(PYTHON) tb/run.py --mold 0 --msgs $(MSGS) --seed $(SEED) 2>&1 | tee build/test_raw.log
	@grep -q "TESTS=5 PASS=5 FAIL=0" build/test_raw.log

synth:
	@mkdir -p syn/out
	$(YOSYS) -q -l syn/out/yosys_generic.log -s syn/synth_generic.ys
	$(YOSYS) -q -l syn/out/yosys_xilinx.log  -s syn/synth_xilinx.ys
	@echo "Reports: syn/out/yosys_generic.log syn/out/yosys_xilinx.log"

clean:
	rm -rf build obj_dir tb/results.xml tb/__pycache__ syn/out *.vcd *.fst

build:
	@mkdir -p build

test-mold test-raw: | build
