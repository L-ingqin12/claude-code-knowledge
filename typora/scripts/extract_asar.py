import struct, json, io, hashlib, sys

def extract(asar_path, out_dir):
    data = io.open(asar_path, 'rb').read()
    d, b, c, json_len = struct.unpack('<IIII', data[0:16])
    j = json.loads(data[16:16+json_len])
    base = (16 + json_len + 3) & ~3
    print(asar_path, 'base', base, 'files:', len(j['files']))
    for name, e in j['files'].items():
        off = base + int(e['offset'])
        blob = data[off:off+e['size']]
        h = hashlib.md5(blob).hexdigest()
        print('  %-28s %8d  md5=%s' % (name, len(blob), h))
        if 'jsc' in name or name.endswith('.js') or name.endswith('.json'):
            out = out_dir + '/' + name.replace('/', '__')
            io.open(out, 'wb').write(blob)
    return j

if __name__ == '__main__':
    outdir = sys.argv[1]
    for p in sys.argv[2:]:
        extract(p, outdir)
        print()
