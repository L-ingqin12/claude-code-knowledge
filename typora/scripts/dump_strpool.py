# dump_strpool.py — dump readable strings from the jsc constant pool with context
import re, sys

path = r'C:\Users\28064\AppData\Local\Temp\asar_out\cur\atom.compiled.dist.jsc'
data = open(path, 'rb').read()

strs = re.findall(rb'[ -~]{4,}', data)
dec = [s.decode('latin1') for s in strs]
print('total strings:', len(dec))

keys = sys.argv[1:] if len(sys.argv) > 1 else ['renew', 'unfill', 'license']
hits = set()
for i, s in enumerate(dec):
    sl = s.lower()
    if any(k in sl for k in keys):
        hits.add(i)
print('hits:', len(hits))

for i in sorted(hits):
    lo = max(0, i - 8); hi = min(len(dec), i + 9)
    print('--- context around #%d: %r' % (i, dec[i][:140]))
    for j in range(lo, hi):
        print('  %6d: %r' % (j, dec[j][:120]))
