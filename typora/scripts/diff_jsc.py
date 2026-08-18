import sys

a = open(sys.argv[1], 'rb').read()
b = open(sys.argv[2], 'rb').read()
print('A', len(a), 'B', len(b))
n = min(len(a), len(b))
runs = []
start = None
for i in range(n):
    if a[i] != b[i]:
        if start is None:
            start = i
    else:
        if start is not None:
            runs.append((start, i))
            start = None
if start is not None:
    runs.append((start, n))
print('diff runs:', len(runs))
for s, e in runs[:80]:
    ctx_a = a[max(0, s-8):e+8].hex()
    ctx_b = b[max(0, s-8):e+8].hex()
    print('0x%06x-%06x len=%d' % (s, e, e-s))
    print('  A: ...%s...' % ctx_a)
    print('  B: ...%s...' % ctx_b)
if len(a) != len(b):
    print('size mismatch: extra tail in', 'A' if len(a) > len(b) else 'B',
          len(a) - len(b) if len(a) > len(b) else len(b) - len(a))
