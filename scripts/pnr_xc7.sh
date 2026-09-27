#!/usr/bin/env bash
# Place-and-route timing estimate of itch_parser on a Xilinx Artix-7 (xc7a200t) with the
# open-source openXC7 flow: Yosys synth_xilinx -> nextpnr-xilinx (prjxray timing data).
#
#   scripts/pnr_xc7.sh <PIPE_STAGES> [seed ...]           (default seeds: 1 2 3)
#   scripts/pnr_xc7.sh --baseline <rtl_dir> [seed ...]    (an older parser without PIPE_STAGES)
#
# Needs OPENXC7 (default: $HOME/tools/openxc7), see scripts/setup_openxc7.sh.
# Prints one line per seed: Fmax, critical path endpoints, logic/routing split.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENXC7="${OPENXC7:-$HOME/tools/openxc7}"
DEVICE="${DEVICE:-xc7a200tfbg484-1}"
CHIPDB="${CHIPDB:-$OPENXC7/chipdb/chipdb-xc7a200t.bin}"
FREQ="${FREQ:-250}"
NEXTPNR="$OPENXC7/bin/nextpnr-xilinx"
[ -x "$NEXTPNR" ] || { echo "nextpnr-xilinx not found under $OPENXC7 (run scripts/setup_openxc7.sh)"; exit 2; }

RTL="$ROOT/rtl"; PIPE=""; TAG=""
if [ "${1:-}" = "--baseline" ]; then RTL="$2"; TAG="baseline"; shift 2
else PIPE="$1"; TAG="p$PIPE"; shift; fi
SEEDS=("$@"); [ ${#SEEDS[@]} -gt 0 ] || SEEDS=(1 2 3)
OUT="$ROOT/syn/out/pnr_$TAG"; mkdir -p "$OUT"

HARNESS="$ROOT/syn/timing_harness.sv"
if [ -z "$PIPE" ]; then        # older parser: no PIPE_STAGES parameter
  sed 's/, \.PIPE_STAGES(PIPE_STAGES)//' "$HARNESS" > "$OUT/timing_harness.sv"; HARNESS="$OUT/timing_harness.sv"
fi
SRCS=("$RTL/itch_pkg.sv"); [ -f "$RTL/stat_counter.sv" ] && SRCS+=("$RTL/stat_counter.sv")
SRCS+=("$RTL/itch_parser.sv" "$HARNESS")
sv2v "${SRCS[@]}" > "$OUT/harness_sv2v.v"
CHP=""; [ -n "$PIPE" ] && CHP="chparam -set PIPE_STAGES $PIPE timing_harness;"
yosys -q -l "$OUT/yosys.log" -p "read_verilog $OUT/harness_sv2v.v; $CHP synth_xilinx -family xc7 -top timing_harness -flatten -abc9; tee -q -o $OUT/stat.txt stat; write_json $OUT/netlist.json" >/dev/null 2>&1

cat > "$OUT/harness.xdc" <<XDC
set_property PACKAGE_PIN H4 [get_ports clk]
set_property PACKAGE_PIN A1 [get_ports rst_in]
set_property PACKAGE_PIN B1 [get_ports sin]
set_property PACKAGE_PIN B2 [get_ports sout]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports rst_in]
set_property IOSTANDARD LVCMOS33 [get_ports sin]
set_property IOSTANDARD LVCMOS33 [get_ports sout]
XDC

for s in "${SEEDS[@]}"; do
  log="$OUT/nextpnr_seed$s.log"
  "$NEXTPNR" --device "$DEVICE" --chipdb "$CHIPDB" --json "$OUT/netlist.json" \
    --vopt xdc="$OUT/harness.xdc" --freq "$FREQ" --timing-allow-fail --seed "$s" --threads 4 > "$log" 2>&1
  python3 - "$log" "$TAG" "$s" <<'PY'
import re, sys
log, tag, seed = sys.argv[1:]
t = open(log).read()
f = re.findall(r"Max frequency for clock '[^']+': ([\d.]+) MHz", t)
rep = t[t.rfind("Critical path report"):]
split = re.search(r"([\d.]+) ns logic, ([\d.]+) ns routing", rep)
nets = re.findall(r"Net (\S+)", rep)
named = [n for n in nets if not n.startswith("$")]
print(f"{tag} seed={seed} fmax_post_route={f[-1] if f else '?'} MHz "
      f"logic={split.group(1) if split else '?'}ns routing={split.group(2) if split else '?'}ns "
      f"path_from={named[0] if named else '?'} named_nets={named[1:6]}")
PY
done
