#!/usr/bin/env bash
# Install the prebuilt openXC7 toolchain (nextpnr-xilinx + prjxray database) and the
# xc7a200t chip database used by scripts/pnr_xc7.sh. Linux x86-64 only. No root needed.
#
#   scripts/setup_openxc7.sh            installs into $OPENXC7 (default: $HOME/tools/openxc7)
#
# Source: https://github.com/FPGAwars/tools-openxc7 release 2026-09-25 (nextpnr-xilinx
# e860c9c8, prjxray-db a90f27c1). The asset hashes are pinned below.
set -euo pipefail
TAG=2026-09-25
DATE=20260925
OPENXC7="${OPENXC7:-$HOME/tools/openxc7}"
URL="https://github.com/FPGAwars/tools-openxc7/releases/download/$TAG"
TOOLS="apio-openxc7-linux-x86-64-$DATE.tgz"
CHIPDB="apio-xilinx-chipdb-xc7a200t-$DATE.bin.tgz"
SUMS="54984280d57f7f7b1a8bd066ca727120373dbddc580a5af49cc6d7d715dcec85  $TOOLS
f5d966f78ede0473778524f09c901e794a4a18146ab02f81d8c12d05014bff76  $CHIPDB"

DL="$(mktemp -d)"; trap 'rm -rf "$DL"' EXIT
for f in "$TOOLS" "$CHIPDB"; do
  echo "downloading $f"
  curl -fsSL -o "$DL/$f" "$URL/$f"
done
(cd "$DL" && echo "$SUMS" | sha256sum -c -)
mkdir -p "$OPENXC7"
tar xzf "$DL/$TOOLS" -C "$OPENXC7"
mkdir -p "$OPENXC7/chipdb"
tar xzf "$DL/$CHIPDB" -C "$OPENXC7/chipdb"
"$OPENXC7/bin/nextpnr-xilinx" --version || true
echo "openXC7 installed in $OPENXC7 (chipdb: $OPENXC7/chipdb/chipdb-xc7a200t.bin)"
