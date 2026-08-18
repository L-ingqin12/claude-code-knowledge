import hashlib

SRC = r'C:\Users\28064\AppData\Local\Temp\asar_out\cur\atom.compiled.dist.jsc'
OUT = SRC + '.reverted'
OFFICIAL_MD5 = '59b3b4b58a177b4fe57d9d9d801038f3'

# Revert the crack's 4 bytes: cracked -> official.
# NOTE: values verified by od/cmp on 2026-08-09. The CHECKPOINT/brief claimed
# 0x01e30d was 0x02->0x05, but the ACTUAL bytes are 0x12 -> 0x21 (cmp octal
# '22 41'). The first three match the docs.
#   0x01a7b3: 0x02 -> 0x06
#   0x01e27f: 0x80 -> 0x5b
#   0x01e30a: 0x02 -> 0x05
#   0x01e30d: 0x12 -> 0x21   (docs said 0x02->0x05 -- WRONG, fixed here)
PATCHES = [
    (0x01A7B3, 0x02, 0x06),
    (0x01E27F, 0x80, 0x5B),
    (0x01E30A, 0x02, 0x05),
    (0x01E30D, 0x12, 0x21),
]

def md5(b):
    return hashlib.md5(b).hexdigest()

data = bytearray(open(SRC, 'rb').read())
print('cracked md5  :', md5(data), '(%d bytes)' % len(data))

for off, expect, new in PATCHES:
    got = data[off]
    assert got == expect, 'offset 0x%06x: expected 0x%02x but found 0x%02x' % (off, expect, got)
    data[off] = new
    print('0x%06x: 0x%02x -> 0x%02x ok' % (off, expect, new))

print('reverted md5 :', md5(bytes(data)))
assert md5(bytes(data)) == OFFICIAL_MD5, 'REVERTED MD5 DOES NOT MATCH OFFICIAL FILE!'
open(OUT, 'wb').write(bytes(data))
print('PASS: [已脱敏] md5 == official 59b3b4b58a177b4fe57d9d9d801038f3')
print('wrote:', OUT, len(data), 'bytes')
