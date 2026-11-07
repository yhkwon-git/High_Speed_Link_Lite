"""Repair rate of the HSL BIRA against a greedy pass and an exhaustive search.

A fault map is k failing words, uniform over one 16 x 16 block. A spare row
covers a row, a spare column covers a column.
  must-repair: passes until one changes nothing; a row with more uncovered
     failing words than spare columns left takes a spare row, a column with
     more than spare rows left takes a spare column (out of spares: fail).
  greedy (the first hsl_bira): then one pass where each uncovered word takes
     a spare row if its row has at least as many uncovered words as its
     column, or no column is left, else a spare column.
  spare-order search (hsl_bira): after must-repair, try every order of the
     spares left (row or column for the 1st, 2nd, ... spare taken); each
     uncovered word in log order takes the next spare of the order. Every
     repair solution is one such order, so this equals the exhaustive search.
The log order is the MBIST visiting order (row-major). The exhaustive search
tries every set of at most R failing rows and checks that the rest fits in
C columns.

usage: python tb/bira_ref.py [maps per point]
"""
import itertools
import random
import sys


def bira_greedy(keys, R, C):
    n = len(keys)
    cov = [False] * n
    rows, cols = [], []
    greedy = False
    while True:
        changed = False
        for i in range(n):
            if cov[i]:
                continue
            r, c = keys[i]
            rc = sum(1 for e in range(n) if not cov[e] and keys[e][0] == r)
            cc = sum(1 for e in range(n) if not cov[e] and keys[e][1] == c)
            take = None
            if not greedy:
                if rc > C - len(cols):
                    if len(rows) < R:
                        take = 'r'
                    else:
                        return False, rows, cols
                elif cc > R - len(rows):
                    if len(cols) < C:
                        take = 'c'
                    else:
                        return False, rows, cols
            else:
                if len(rows) < R and (rc >= cc or len(cols) == C):
                    take = 'r'
                elif len(cols) < C:
                    take = 'c'
                else:
                    return False, rows, cols
            if take == 'r':
                rows.append(r)
            elif take == 'c':
                cols.append(c)
            if take:
                changed = True
                for e in range(n):
                    if (take == 'r' and keys[e][0] == r) or (take == 'c' and keys[e][1] == c):
                        cov[e] = True
        if greedy:
            return True, rows, cols
        if not changed:
            greedy = True


def bira_search(keys, R, C):
    """hsl_bira: must-repair, then try spare orders. Order bits, LSB first: bit t
    is 1 if the t-th spare taken is a row. Orders 0..15 in turn, only those with
    exactly the rows left; each uncovered word (log order) takes the next spare."""
    n = len(keys)
    cov = [False] * n
    rows, cols = [], []
    while True:
        changed = False
        for i in range(n):
            if cov[i]:
                continue
            r, c = keys[i]
            rc = sum(1 for e in range(n) if not cov[e] and keys[e][0] == r)
            cc = sum(1 for e in range(n) if not cov[e] and keys[e][1] == c)
            take = None
            if rc > C - len(cols):
                if len(rows) == R:
                    return False, rows, cols
                take = 'r'
            elif cc > R - len(rows):
                if len(cols) == C:
                    return False, rows, cols
                take = 'c'
            if take:
                changed = True
                if take == 'r':
                    rows.append(r)
                else:
                    cols.append(c)
                for e in range(n):
                    if (take == 'r' and keys[e][0] == r) or (take == 'c' and keys[e][1] == c):
                        cov[e] = True
        if not changed:
            break
    rl, cl = R - len(rows), C - len(cols)
    L = rl + cl
    for order in range(16):
        if order >> L or bin(order).count('1') != rl:
            continue
        cv, rr, cc_, t, ok = list(cov), list(rows), list(cols), 0, True
        for i in range(n):
            if cv[i]:
                continue
            if t == L:
                ok = False
                break
            r, c = keys[i]
            if (order >> t) & 1:
                rr.append(r)
                for e in range(n):
                    if keys[e][0] == r:
                        cv[e] = True
            else:
                cc_.append(c)
                for e in range(n):
                    if keys[e][1] == c:
                        cv[e] = True
            t += 1
        if ok:
            return True, rr, cc_
    return False, rows, cols


def repairable(keys, R, C):
    frows = sorted(set(r for r, _ in keys))
    for k in range(min(R, len(frows)) + 1):
        for sel in itertools.combinations(frows, k):
            left = set(c for r, c in keys if r not in sel)
            if len(left) <= C:
                return True
    return False


def main():
    maps = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    rnd = random.Random(1)
    spares = [(1, 1), (2, 2), (3, 3)]
    ks = [2, 3, 4, 5, 6, 8, 10]
    print('failing words, then repair rate: greedy / spare-order search (hsl_bira) / exhaustive')
    print('(%d maps each, uniform in a 16 x 16 block)' % maps)
    print('%-6s' % 'words' + ''.join('%26s' % ('%d row + %d col (%%)' % s) for s in spares))
    for k in ks:
        line = '%-6d' % k
        for (R, C) in spares:
            g = q = o = 0
            for _ in range(maps):
                cells = rnd.sample(range(256), k)
                keys = sorted((x // 16, x % 16) for x in cells)
                ok_g = bira_greedy(keys, R, C)[0]
                ok_q = bira_search(keys, R, C)[0] if R + C <= 4 else ok_g
                ok_o = repairable(keys, R, C)
                assert ok_o or not ok_g
                assert R + C > 4 or ok_q == ok_o
                g += ok_g
                q += ok_q
                o += ok_o
            if R + C <= 4:
                line += '%26s' % ('%.1f / %.1f / %.1f' % (100.0 * g / maps, 100.0 * q / maps, 100.0 * o / maps))
            else:
                line += '%26s' % ('%.1f / - / %.1f' % (100.0 * g / maps, 100.0 * o / maps))
        print(line)


if __name__ == '__main__':
    main()
