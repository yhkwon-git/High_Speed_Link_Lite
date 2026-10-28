#!/usr/bin/env bash
# Verilator smoke flow. Run from WSL or any environment that has verilator.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p sim/build/obj
verilator --binary --timing -j 0 \
  --top-module tb_hsl_smoke \
  -f sim/filelist.f \
  --Mdir sim/build/obj \
  -o smoke
./sim/build/obj/smoke
