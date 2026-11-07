#!/usr/bin/env bash
# Chip-level STA: sv2v -> Yosys 0.52 (Nangate45, hierarchy kept) -> OpenSTA 3.1
# with syn/constraints/hsl_base_die_lite.sdc.
#   - hsl_phy_clk (the PLL) comes from syn/lib/hsl_phy_clk_stub.lib, so the
#     generated clock clk_phy reaches its flops.
#   - Flops take the name of the register they hold (<reg>[i]_reg), as in a
#     commercial netlist, so the SDC's cell patterns such as
#     u_phy/u_mis/u_rx_fifo/wgray* match.
#   - ABC maps against the controller period with buffering and sizing
#     (abc -D -constr), and syn/fanout_buffer.py builds buffer trees on the
#     nets ABC does not see (a module input reaching hundreds of flop reset
#     pins), as a place-and-route repair step would.
# Ideal clocks and no wires: for finding the limiting paths, not sign-off.
# Run from the repository root:  bash syn/sta_chip.sh
#   SV2V  sv2v binary                 (default: sv2v)
#   LIB   Nangate45 .lib[.gz]         (default: the OpenSTA example typical library)
#   OUT   output directory            (default: build/sta_chip)
set -euo pipefail

OUT=${OUT:-build/sta_chip}
SV2V=${SV2V:-sv2v}
LIB=${LIB:-$HOME/src/OpenSTA/examples/nangate45_typ.lib.gz}
PLL=syn/lib/hsl_phy_clk_stub.lib

mkdir -p "$OUT"
# ABC's view of the boundary, as the STA sets it: BUF_X1 drivers, 2 fF loads.
printf 'set_driving_cell BUF_X1\nset_load 2.0\n' > "$OUT/abc.constr"
case "$LIB" in
  *.gz) gunzip -c "$LIB" > "$OUT/nangate45.lib" ;;
  *)    cp "$LIB" "$OUT/nangate45.lib" ;;
esac

# Every RTL file but the PLL shell; its cell is the stub.
mapfile -t SRCS < <(grep -v -e '^[[:space:]]*$' -e 'hsl_phy_clk' syn/filelist.f)
"$SV2V" -DSYNTHESIS "${SRCS[@]}" > "$OUT/chip.v"

yosys -q -l "$OUT/yosys.log" -p "
  read_liberty -lib $PLL;
  read_verilog $OUT/chip.v;
  hierarchy -check -top hsl_base_die_lite;
  synth -top hsl_base_die_lite;
  rename -wire -suffix _reg t:\$_*DFF*;
  dfflibmap -liberty $OUT/nangate45.lib;
  abc -D 1250 -constr $OUT/abc.constr -liberty $OUT/nangate45.lib;
  opt_clean;
  tee -q -o $OUT/stat.txt stat -liberty $OUT/nangate45.lib -top hsl_base_die_lite;
  write_verilog -noattr -noexpr $OUT/chip_abc.v"

python3 syn/fanout_buffer.py "$OUT/nangate45.lib" "$PLL" -- "$OUT/chip_abc.v" "$OUT/chip_nangate.v"

# Area of the netlist STA sees (buffers included), by block.
yosys -q -p "
  read_liberty -lib $OUT/nangate45.lib;
  read_liberty -lib $PLL;
  read_verilog $OUT/chip_nangate.v;
  hierarchy -top hsl_base_die_lite;
  tee -q -o $OUT/stat_final.txt stat -liberty $OUT/nangate45.lib -top hsl_base_die_lite"
python3 syn/area_by_block.py "$OUT/stat_final.txt" | tee "$OUT/area.txt"

OUT="$OUT" PLL="$PLL" sta -no_splash -exit syn/sta_chip.tcl > "$OUT/sta.log" 2>&1
sed -n '/^== min period/,/^== worst path per capture clock/p' "$OUT/sta.log"
