#!/usr/bin/env python3
"""Area, cells and flops by block from a Yosys `stat -liberty -top` report.

Yosys reports each module once with its own cells, and the design hierarchy
lists how often each module is instantiated under its parent. Every parent in
this design is instantiated once, so a module's total is its own numbers times
the sum of those counts. The result is grouped by block (controller, PHY, ...).

usage: area_by_block.py <stat.txt>
"""
import re
import sys

GROUPS = [
    ('Memory Controller (mem_ctrl)', ('mem_ctrl', 'mc_')),
    ('PHY digital', ('hsl_phy_top', 'hsl_phy_mis', 'hsl_dbi', 'hsl_lane_shift', 'hsl_tx_gear',
                     'hsl_cdc_fifo', 'hsl_phy_clk')),
    ('Read leveling (hsl_rd_train)', ('hsl_rd_train',)),
    ('DFT', ('hsl_dft_top', 'hsl_prbs', 'hsl_loopback', 'hsl_err_cnt', 'hsl_lane_bist')),
    ('CSR', ('hsl_csr',)),
    ('Other (top, training FSM, reset sync)', ('hsl_base_die_lite', 'hsl_training_fsm', 'hsl_rst_sync')),
]
IS_MODULE = re.compile(r'hsl_|mem_ctrl|mc_')


def short(name):
    """Module name without the $paramod prefix and parameters."""
    m = re.search(r'(hsl_\w+|mem_ctrl|mc_[a-z]+)', name)
    return m.group(1) if m else name


def main():
    text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
    own = {}
    for block in re.split(r'\n=== ', text)[1:]:
        name = block.split(' ===')[0].strip()
        if name == 'design hierarchy':
            continue
        area = re.search(r'Chip area for module .*?: ([0-9.]+)', block)
        cells = re.search(r'Number of cells:\s+([0-9]+)', block)
        ffs = sum(int(n) for n in re.findall(r'\n\s+DFF[A-Z]*_X[0-9]+\s+([0-9]+)', block))
        subs = sum(int(n) for (mod, n) in re.findall(r'\n\s+(\S+)\s+([0-9]+)', block)
                   if IS_MODULE.search(mod))
        own[name] = (float(area.group(1)) if area else 0.0,
                     (int(cells.group(1)) if cells else 0) - subs, ffs)
    hier = re.search(r'=== design hierarchy ===(.*)', text, re.S)
    count = {}
    for mod, n in re.findall(r'\n\s+(\S+)\s+([0-9]+)', hier.group(1) if hier else ''):
        if mod in own:
            count[mod] = count.get(mod, 0) + int(n)
    rows = []
    tot = [0.0, 0, 0]
    for label, prefixes in GROUPS:
        a = c = f = 0
        for mod, (ma, mc, mf) in own.items():
            if short(mod).startswith(prefixes):
                k = count.get(mod, 1)
                a += ma * k
                c += mc * k
                f += mf * k
        rows.append((label, a, c, f))
        tot = [tot[0] + a, tot[1] + c, tot[2] + f]
    print('%-40s %10s %8s %6s %6s' % ('block', 'um2', 'cells', 'FF', 'share'))
    for label, a, c, f in rows:
        print('%-40s %10.0f %8d %6d %5.1f%%' % (label, a, c, f, 100.0 * a / tot[0]))
    print('%-40s %10.0f %8d %6d' % ('Total', tot[0], tot[1], tot[2]))


if __name__ == '__main__':
    main()
