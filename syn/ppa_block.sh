#!/usr/bin/env bash
# Area and worst path of one block: sv2v -> Yosys 0.52 (Nangate45 typical)
# -> OpenSTA 3.1. A block with a clk port gets a 10 ns clock on it (the
# worst path is then reg-to-reg or port-to-reg); a combinational block gets a
# virtual clock and the worst input-to-output delay.
# Run from the repository root, e.g. the DBI encoder in both AC structures:
#   TOP=hsl_dbi SRCS="rtl/include/hsl_pkg.sv rtl/phy/hsl_dbi.sv" bash syn/ppa_block.sh
#   TOP=hsl_dbi SRCS="rtl/include/hsl_pkg.sv rtl/phy/hsl_dbi.sv" PARAMS="AC_SERIAL=1" bash syn/ppa_block.sh
#   SV2V   sv2v binary                 (default: sv2v)
#   LIB    Nangate45 typical .lib[.gz] (default: the OpenSTA example library)
#   PARAMS parameter overrides on TOP (Yosys chparam)
# Inputs are driven by BUF_X1, outputs carry 2 fF, no wires: for comparing
# structures, not a sign-off number.
set -euo pipefail

TOP=${TOP:?TOP is required}
SRCS=${SRCS:?SRCS is required}
OUT=${OUT:-build/ppa_$TOP}
SV2V=${SV2V:-sv2v}
LIB=${LIB:-$HOME/src/OpenSTA/examples/nangate45_typ.lib.gz}

mkdir -p "$OUT"
case "$LIB" in
  *.gz) gunzip -c "$LIB" > "$OUT/nangate45_typ.lib" ;;
  *)    cp "$LIB" "$OUT/nangate45_typ.lib" ;;
esac

read -r -a SRC_LIST <<< "$SRCS"
"$SV2V" "${SRC_LIST[@]}" > "$OUT/$TOP.v"

CHPARAM=""
for kv in ${PARAMS:-}; do CHPARAM="$CHPARAM -set ${kv%%=*} ${kv#*=}"; done
[ -n "$CHPARAM" ] && CHPARAM="chparam$CHPARAM $TOP;"

yosys -q -l "$OUT/yosys.log" -p "
  read_verilog $OUT/$TOP.v;
  $CHPARAM
  hierarchy -check -top $TOP;
  synth -top $TOP -flatten;
  dfflibmap -liberty $OUT/nangate45_typ.lib;
  abc -liberty $OUT/nangate45_typ.lib;
  opt_clean -purge;
  tee -q -o $OUT/stat.txt stat -liberty $OUT/nangate45_typ.lib;
  write_verilog -noattr -noexpr $OUT/${TOP}_nangate.v"

cat > "$OUT/sta.tcl" <<EOF
read_liberty $OUT/nangate45_typ.lib
read_verilog $OUT/${TOP}_nangate.v
link_design $TOP
if {[llength [get_ports -quiet clk]]} {
  create_clock -name clk -period 10 [get_ports clk]
  set ck clk
} else {
  create_clock -name vclk -period 10
  set ck vclk
}
set_input_delay 0 -clock \$ck [all_inputs]
if {[llength [get_ports -quiet rst_n]]} {
  set_false_path -from [get_ports rst_n]
}
set_output_delay 0 -clock \$ck [all_outputs]
set_driving_cell -lib_cell BUF_X1 [all_inputs]
set_load 0.002 [all_outputs]
report_checks -path_delay max -digits 3
EOF
sta -no_splash -exit "$OUT/sta.tcl" > "$OUT/sta.log" 2>&1

area=$(grep -m1 "Chip area" "$OUT/stat.txt" | awk '{print $NF}')
cells=$(grep -m1 "Number of cells" "$OUT/stat.txt" | awk '{print $NF}')
# A block whose clocks are not on a clk port has no timed path here: "-".
delay=$( (grep -m1 "data arrival time" "$OUT/sta.log" || echo "-") | awk '{print $1}')
from=$( (grep -m1 "^Startpoint" "$OUT/sta.log" || echo "x -") | awk '{print $2}')
to=$( (grep -m1 "^Endpoint" "$OUT/sta.log" || echo "x -") | awk '{print $2}')
ffs=$( (grep -E '^ +DFF[A-Z]*_X[0-9]+ ' "$OUT/stat.txt" || true) | awk '{s += $2} END {print s + 0}')
echo "top,params,area_um2,cells,ff,delay_ns,path" > "$OUT/ppa.csv"
echo "$TOP,${PARAMS:-},$area,$cells,$ffs,$delay,$from -> $to" >> "$OUT/ppa.csv"
column -s, -t "$OUT/ppa.csv"
