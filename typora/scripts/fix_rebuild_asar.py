# fix_rebuild_asar.py — Typora app.asar rebuild v2 (parameterized)
# Usage (git-bash):
#   probe:    D:/ProgramData/Miniconda3/python.exe fix_rebuild_asar.py --mode probe
#   activate: D:/ProgramData/Miniconda3/python.exe fix_rebuild_asar.py --mode activate
#   optional jsc override (e.g. 4-byte-reverted official jsc):
#             ... fix_rebuild_asar.py --mode activate --jsc "C:\\Users\\28064\\AppData\\Local\\Temp\\asar_out\\cur\\atom.compiled.dist.jsc.reverted"
# Preserves the ORIGINAL header integrity hashes EXACTLY (do not recompute): the app's
# integrity check reads package.json / launch.dist.js / page-dist via the fs hook which
# redirects to app.bak, so header hashes must stay the values of the ORIGINAL files.
# The jsc is NOT covered by the integrity check (zero jsc fs reads in fshook.log history),
# therefore swapping the jsc inside the asar is safe and takes effect (asar require mechanism).
import struct, json, io, hashlib, shutil, os, argparse

SRC = r'D:\Program Files\Typora\resources\app.asar'
BAK = r'D:\Program Files\Typora\resources\app.asar.fshook.bak'
OUT = SRC
HOOK_LOG = r'D:\Program Files\Typora\resources\fshook.log'
HERE = os.path.dirname(os.path.abspath(__file__))
HOOK_FILE = os.path.join(HERE, 'fix_hook_block.js')

ap = argparse.ArgumentParser(description='Rebuild Typora app.asar with activation hook (v2)')
ap.add_argument('--mode', choices=['probe', 'activate'], default='probe',
                help="probe = log only (publicDecrypt/ipc/protocol), nothing faked; "
                     "activate = publicDecrypt returns fake plaintext + renew URL intercepted")
ap.add_argument('--jsc', default=None,
                help='optional path to replacement atom.compiled.dist.jsc '
                     '(e.g. the 4-byte-reverted official jsc); None = keep current jsc')
ap.add_argument('--log', default=HOOK_LOG, help='fshook.log path baked into the hook')
args = ap.parse_args()

if os.path.exists(BAK):
    SRC = BAK
    print('rebuilding from pristine backup', BAK)
data = io.open(SRC, 'rb').read()

# --- parse header ---
d = struct.unpack('<I', data[0:4])[0]      # 4
b = struct.unpack('<I', data[4:8])[0]      # 792
c = struct.unpack('<I', data[8:12])[0]     # 788
json_len = struct.unpack('<I', data[12:16])[0]  # 781
assert d == 4, 'unexpected pickle'
j = json.loads(data[16:16 + json_len])
base = (16 + json_len + 3) & ~3
print('base offset:', base)

def get_file(name):
    e = j['files'][name]
    off = base + int(e['offset'])
    return io.BytesIO(data[off:off + e['size']]).read()

jsc = get_file('atom.compiled.dist.jsc')
ld = get_file('launch.dist.js')
pkg = get_file('package.json')
print('jsc %d (md5 %s) ld %d pkg %d' % (len(jsc), hashlib.md5(jsc).hexdigest(), len(ld), len(pkg)))

if args.jsc:
    with io.open(args.jsc, 'rb') as f:
        jsc_new = f.read()
    print('jsc override -> %s (md5 %s)' % (args.jsc, hashlib.md5(jsc_new).hexdigest()))
    print('  NOTE: header integrity hash kept as-is; integrity check does NOT read the jsc (no jsc fs reads logged)')
    jsc = jsc_new
else:
    print('keeping current jsc')

# --- build hooked launch.dist.js from fix_hook_block.js ---
if not os.path.exists(HOOK_FILE):
    raise SystemExit('hook template missing: %s' % HOOK_FILE)
hook = io.open(HOOK_FILE, 'r', encoding='utf-8').read()
hook = hook.replace('__LOG_PATH__', args.log.replace('\\', '\\\\')).replace('__MODE__', args.mode)
assert '__LOG_PATH__' not in hook and '__MODE__' not in hook, 'placeholder replacement failed'
print('hook size:', len(hook), 'mode:', args.mode)

old_tail = '},require("./atom.compiled.dist.jsc");'.encode('utf-8')
assert ld.count(old_tail) == 1, 'tail not found: %d' % ld.count(old_tail)
ld_new = ld.replace(old_tail, ('},' + hook + ',require("./atom.compiled.dist.jsc");').encode('utf-8'))
print('new ld size:', len(ld_new))

# --- rebuild header ---
# CRITICAL: keep the ORIGINAL header integrity values untouched (see module docstring).
files = j['files']
files['launch.dist.js'] = {'size': len(ld_new), 'offset': str(len(jsc)), 'integrity': files['launch.dist.js']['integrity']}
files['atom.compiled.dist.jsc'] = {'size': len(jsc), 'offset': '0', 'integrity': files['atom.compiled.dist.jsc']['integrity']}
files['package.json'] = {'size': len(pkg), 'offset': str(len(jsc) + len(ld_new)), 'integrity': files['package.json']['integrity']}

new_json = json.dumps(j).encode('utf-8')
new_json_len = len(new_json)
base2 = (16 + new_json_len + 3) & ~3
pad_len = base2 - (16 + new_json_len)

# nested pickle header: a=4, b=4+align4(c), c=4+align4(d), d=json_len
d = new_json_len
c = 4 + ((d + 3) & ~3)
b = 4 + ((c + 3) & ~3)
a = 4
hdr = struct.pack('<IIII', a, b, c, d) + new_json + b'\x00' * pad_len

out = hdr + jsc + ld_new + pkg
print('expected total:', len(out), 'old total:', len(data))
print('json len:', new_json_len, 'base:', base2)

if SRC != BAK:
    shutil.copyfile(SRC, BAK)
io.open(OUT, 'wb').write(out)
print('written', OUT, len(out))
print('mode:', args.mode, '| jsc md5:', hashlib.md5(jsc).hexdigest())
print('REMINDER: kill Typora before rebuild; clear fshook.log before next launch;')
print('rollback = copy app.asar.fshook.bak -> app.asar')
