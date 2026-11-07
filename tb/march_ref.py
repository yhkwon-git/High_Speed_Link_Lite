"""Reference March simulator for the HSL MBIST detection table.

Word memory of N words, solid background (0 = all zeros, 1 = all ones).
Fault semantics (the same as the array faults in tb/models/dram_channel_behav.sv):
  write(i, W): O = M[i]
     TF up   on (i,k): O[k]=0 and W[k]=1 -> W[k]=0
     TF down on (i,k): O[k]=1 and W[k]=0 -> W[k]=1
     SA s    on (i,k): W[k]=s
     M[i] = W
     CF with aggressor (i,ka) and victim (v,kv), trigger dir d:
        transition t of bit ka from O to M[i]
        CFin: t == d -> M[v][kv] ^= 1
        CFid: t == d -> M[v][kv] = val
  read(i): R = M[i]; SA on (i,k): R[k]=s;
     CFst (aggressor state s, victim value val), victim i: M[a][ka]==s -> R[kv]=val
Element ops: (write?, value). Directions: 'u' up, 'd' down, 'a' any (= up).
"""

ALGOS = {
    'MATS+':   [('a', [(1, 0)]), ('u', [(0, 0), (1, 1)]), ('d', [(0, 1), (1, 0)])],
    'March X': [('a', [(1, 0)]), ('u', [(0, 0), (1, 1)]), ('d', [(0, 1), (1, 0)]), ('a', [(0, 0)])],
    "March C-": [('a', [(1, 0)]), ('u', [(0, 0), (1, 1)]), ('u', [(0, 1), (1, 0)]),
                 ('d', [(0, 0), (1, 1)]), ('d', [(0, 1), (1, 0)]), ('a', [(0, 0)])],
}

N = 8
KV = 3        # victim bit
KA = 7        # aggressor bit
MASK = 0xFFFFFFFF


def run(algo, fault):
    M = [0] * N
    kind = fault['kind']

    def bit(x, k):
        return (x >> k) & 1

    def write(i, W):
        O = M[i]
        if kind == 'TF' and fault['v'] == i:
            k = KV
            if fault['dir'] == 1 and bit(O, k) == 0 and bit(W, k) == 1:
                W &= ~(1 << k)
            if fault['dir'] == 0 and bit(O, k) == 1 and bit(W, k) == 0:
                W |= (1 << k)
        if kind == 'SA' and fault['v'] == i:
            W = (W & ~(1 << KV)) | (fault['val'] << KV)
        M[i] = W & MASK
        if kind in ('CFin', 'CFid') and fault['a'] == i:
            o, n = bit(O, KA), bit(M[i], KA)
            t = 1 if (o == 0 and n == 1) else (0 if (o == 1 and n == 0) else None)
            if t is not None and t == fault['dir']:
                v = fault['v']
                if kind == 'CFin':
                    M[v] ^= (1 << KV)
                else:
                    M[v] = (M[v] & ~(1 << KV)) | (fault['val'] << KV)

    def read(i):
        R = M[i]
        if kind == 'SA' and fault['v'] == i:
            R = (R & ~(1 << KV)) | (fault['val'] << KV)
        if kind == 'CFst' and fault['v'] == i:
            if bit(M[fault['a']], KA) == fault['s']:
                R = (R & ~(1 << KV)) | (fault['val'] << KV)
        return R

    detected = False
    for d, ops in ALGOS[algo]:
        order = range(N) if d in ('u', 'a') else range(N - 1, -1, -1)
        for i in order:
            for (wr, val) in ops:
                data = MASK if val else 0
                if wr:
                    write(i, data)
                elif read(i) != data:
                    detected = True
    return detected


def faults():
    lo, hi = 2, 5
    out = [
        ('SA0', dict(kind='SA', v=lo, val=0)),
        ('SA1', dict(kind='SA', v=lo, val=1)),
        ('TF up', dict(kind='TF', v=lo, dir=1)),
        ('TF down', dict(kind='TF', v=lo, dir=0)),
    ]
    for dname, dv in (('up', 1), ('down', 0)):
        for oname, (a, v) in (('a<v', (lo, hi)), ('a>v', (hi, lo))):
            out.append(('CFin %s %s' % (dname, oname), dict(kind='CFin', a=a, v=v, dir=dv)))
    for dname, dv in (('up', 1), ('down', 0)):
        for val in (0, 1):
            for oname, (a, v) in (('a<v', (lo, hi)), ('a>v', (hi, lo))):
                out.append(('CFid %s->%d %s' % (dname, val, oname),
                            dict(kind='CFid', a=a, v=v, dir=dv, val=val)))
    for s in (0, 1):
        for val in (0, 1):
            for oname, (a, v) in (('a<v', (lo, hi)), ('a>v', (hi, lo))):
                out.append(('CFst <%d;%d> %s' % (s, val, oname),
                            dict(kind='CFst', a=a, v=v, s=s, val=val)))
    return out


if __name__ == '__main__':
    fl = faults()
    print('%-22s %6s %8s %9s' % ('fault', 'MATS+', 'March X', 'March C-'))
    masks = {a: 0 for a in ALGOS}
    for idx, (name, f) in enumerate(fl):
        row = [run(a, f) for a in ALGOS]
        for a, r in zip(ALGOS, row):
            if r:
                masks[a] |= 1 << idx
        print('%-22s %6s %8s %9s' % (name, *['Y' if r else '-' for r in row]))
    for a in ALGOS:
        print('%-9s detected %2d/%d mask %08X' % (a, bin(masks[a]).count('1'), len(fl), masks[a]))
