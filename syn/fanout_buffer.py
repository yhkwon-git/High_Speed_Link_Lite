#!/usr/bin/env python3
"""Buffer high-fanout nets in a Yosys gate-level netlist, module by module.

Yosys and ABC do not build fanout trees for nets that leave ABC's view, such
as a module input that reaches hundreds of flop reset pins. One gate then
drives every load and its delay is read far off the cell's tables. This is a
small stand-in for a place-and-route repair step: every net with more than
MAX_FANOUT leaf-cell input loads gets a tree of buffers, each driving at most
MAX_FANOUT loads. A module input with more than PORT_FANOUT loads (more than
one, if it reaches flop reset pins) goes behind one buffer, so the parent sees
a single load per module: a net that crosses the hierarchy, like the reset
that reaches every block, stays small at the top.
Clock nets (any load on a clock pin) are left to clock tree synthesis.

usage: fanout_buffer.py <liberty> [<liberty> ...] -- <netlist in> <netlist out>
  MAX_FANOUT (env, default 16), BUF_CELL (env, default BUF_X2)
"""
import os
import re
import sys

MAX_FANOUT = int(os.environ.get('MAX_FANOUT', '16'))
PORT_FANOUT = int(os.environ.get('PORT_FANOUT', '4'))
BUF_CELL = os.environ.get('BUF_CELL', 'BUF_X2')


def read_liberty(path):
    """cell -> {pin: (direction, is_clock)}"""
    cells = {}
    cur_cell = None
    cur_pin = None
    depth = 0
    cell_depth = pin_depth = -1
    text = open(path, encoding='utf-8', errors='replace').read()
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    for tok in re.finditer(r'(\bcell\s*\(\s*"?([\w$]+)"?\s*\))|(\bpin\s*\(\s*"?([\w\[\]$]+)"?\s*\))|'
                           r'(\bdirection\s*:\s*(\w+))|(\bclock\s*:\s*true)|(\{)|(\})', text):
        if tok.group(1):
            cur_cell = tok.group(2)
            cells[cur_cell] = {}
            cell_depth = depth
        elif tok.group(3) and cur_cell is not None:
            cur_pin = tok.group(4)
            cells[cur_cell][cur_pin] = ['input', False]
            pin_depth = depth
        elif tok.group(5) and cur_pin is not None:
            cells[cur_cell][cur_pin][0] = tok.group(6)
        elif tok.group(7) and cur_pin is not None:
            cells[cur_cell][cur_pin][1] = True
        elif tok.group(8):
            depth += 1
        elif tok.group(9):
            depth -= 1
            if cur_pin is not None and depth == pin_depth:
                cur_pin = None
            if cur_cell is not None and depth == cell_depth:
                cur_cell = None
    return cells


CONN = re.compile(r'^\s*\.(\w+)\((.*)\),?\s*$')


def main():
    args = sys.argv[1:]
    sep = args.index('--')
    libs, (src, dst) = args[:sep], args[sep + 1:]
    cells = {}
    for lib in libs:
        cells.update(read_liberty(lib))

    lines = open(src, encoding='utf-8').read().split('\n')
    out = []
    i = 0
    total_bufs = 0
    total_nets = 0
    worst_before = 0
    while i < len(lines):
        line = lines[i]
        if not line.startswith('module '):
            out.append(line)
            i += 1
            continue
        # One module: collect its lines up to endmodule.
        j = i
        while lines[j].strip() != 'endmodule':
            j += 1
        body = lines[i:j]
        # Instances: "  TYPE NAME (" then ".PIN(EXPR)," lines, then "  );"
        insts = []          # [type, name, start, end, {pin: line index}]
        k = 0
        while k < len(body):
            m = re.match(r'^  (\S+) (\S+)\s*\($', body[k])
            if m and not body[k].lstrip().startswith(('module', 'input', 'output', 'wire', 'assign', 'reg')):
                start = k
                pins = {}
                k += 1
                while body[k].strip() != ');':
                    c = CONN.match(body[k])
                    if c:
                        pins[c.group(1)] = k
                    k += 1
                insts.append([m.group(1), m.group(2), start, k, pins])
            k += 1
        inputs = set(re.findall(r'^\s*input\s+(?:\[[^\]]+\]\s*)?(\\\S+|[\w$]+)\s*;',
                                '\n'.join(body), flags=re.M))
        # Loads per net expression (leaf cells only).
        loads = {}
        clock_nets = set()
        reset_nets = set()
        for idx, (ctype, _, _, _, pins) in enumerate(insts):
            if ctype not in cells:
                continue
            for pin, li in pins.items():
                info = cells[ctype].get(pin)
                if info is None or info[0] != 'input':
                    continue
                expr = CONN.match(body[li]).group(2).strip()
                if not expr or re.match(r"^\d+'[hbd]", expr) or expr.startswith('{'):
                    continue
                if info[1]:
                    clock_nets.add(expr)
                if ctype.startswith('DFF') and pin in ('RN', 'SN'):
                    reset_nets.add(expr)
                loads.setdefault(expr, []).append((idx, pin))
        new_lines = []
        new_wires = []
        for expr, lst in loads.items():
            is_port = re.match(r'^(\\\S+|[\w$]+)', expr).group(1) in inputs
            port_limit = 1 if expr in reset_nets else PORT_FANOUT
            if expr in clock_nets or len(lst) <= (port_limit if is_port else MAX_FANOUT):
                continue
            total_nets += 1
            worst_before = max(worst_before, len(lst))
            level = lst
            while len(level) > (1 if is_port else MAX_FANOUT):
                nxt = []
                for g in range(0, len(level), MAX_FANOUT):
                    total_bufs += 1
                    bname = '_fo%d_' % total_bufs
                    nname = '_fo%d_z' % total_bufs
                    new_wires.append('  wire %s;' % nname)
                    new_lines.append('  %s %s (' % (BUF_CELL, bname))
                    new_lines.append('    .A(%s),' % expr)
                    new_lines.append('    .Z(%s)' % nname)
                    new_lines.append('  );')
                    a_line = len(new_lines) - 3     # the .A line, rewritten if this buffer is regrouped
                    for (idx, pin) in level[g:g + MAX_FANOUT]:
                        if idx == 'buf':
                            new_lines[pin] = '    .A(%s),' % nname
                        else:
                            li = insts[idx][4][pin]
                            body[li] = re.sub(r'\((.*)\)', '(%s)' % nname, body[li], count=1)
                    nxt.append(('buf', a_line))
                level = nxt
        # The port list can wrap over several lines; declarations go after it.
        h = 0
        while not body[h].rstrip().endswith(');'):
            h += 1
        out.extend(body[:h + 1])
        out.extend(new_wires)
        out.extend(body[h + 1:])
        out.extend(new_lines)
        out.append('endmodule')
        i = j + 1
    open(dst, 'w', encoding='utf-8').write('\n'.join(out))
    print('fanout_buffer: %d nets buffered, %d %s inserted (largest fanout was %d)'
          % (total_nets, total_bufs, BUF_CELL, worst_before))


if __name__ == '__main__':
    main()
