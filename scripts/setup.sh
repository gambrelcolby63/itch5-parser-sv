#!/usr/bin/env bash
# One-time toolchain setup on Debian/Ubuntu (tested on Debian 13 "trixie").
#   * Verilator 5.052 built from source into /opt/verilator-5.052 (cocotb 2.x needs >= 5.036;
#     Debian 13 ships 5.032)
#   * Icarus Verilog, Yosys, sv2v, Python venv with cocotb
set -euo pipefail
VLT_VER=${VLT_VER:-v5.052}

sudo apt-get update
sudo apt-get install -y git make g++ autoconf flex bison libfl-dev help2man perl zlib1g-dev ccache \
    python3 python3-venv libpython3-dev iverilog yosys unzip curl

if [ ! -x /opt/verilator-${VLT_VER#v}/bin/verilator ]; then
  tmp=$(mktemp -d)
  git clone --depth 1 --branch "$VLT_VER" https://github.com/verilator/verilator "$tmp/verilator"
  (cd "$tmp/verilator" && autoconf && ./configure --prefix=/opt/verilator-${VLT_VER#v} && make -j"$(nproc)" && sudo make install)
fi

if ! command -v sv2v >/dev/null; then
  tmp=$(mktemp -d)
  curl -sSL -o "$tmp/sv2v.zip" https://github.com/zachjs/sv2v/releases/latest/download/sv2v-Linux.zip
  (cd "$tmp" && unzip -q sv2v.zip && sudo install sv2v-Linux/sv2v /usr/local/bin/sv2v)
fi

cd "$(dirname "$0")/.."
python3 -m venv .venv
.venv/bin/pip install -q "cocotb>=2.0" pytest
echo "Setup done. Try: make lint test"
