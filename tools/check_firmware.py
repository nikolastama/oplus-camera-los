#!/usr/bin/env python3
"""Check which patches still fit a (newer) ColorOS firmware dump, without building anything.

    python3 tools/check_firmware.py --dump <firmware dump root> [--apktool apktool.jar]

For every part of the port it reports OK (fits as recorded), MOVED (fits, found by its bytes at a
new place), FAIL (needs re-deriving, see docs/MAINTAINING.md) or NOTE (not checked, with why):
  files      firmware files the module copies (tools/selection.json, EXTRA_COPIES)
  appblobs   the camera app's own files LineageOS no longer ships (tools/app_blobs.txt), and
             their fixups (tools/app_blobs.py)
  aps        the APS client edit (exact-build patch)
  install    install-time fixes of ROM files (fixlib calls in module/customize.sh), for the files the
             dump contains
  wrapper    symbols the wrapper (tools/oemwrap) takes from the OnePlus layer
  smali      every app/SDK patch, run on a fresh apktool decode (needs --apktool)
Exit status 1 if anything FAILs. Nothing in the dump or the repository is changed.
"""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import app_blobs as A  # noqa: E402
import build_module as B  # noqa: E402
import patches as P  # noqa: E402

# what tools/oemwrap/oemwrap.c resolves from the real layer (dlsym) and the HMI size it copies
WRAPPER_SYMBOLS = [
    'HMI',
    'g_camx_camera_module',
    'pSetOplusCallback',
    '_ZN8OemLayer25g_camx_oplus_callback_opsE',
    '_ZN8OemLayer18get_vendor_tag_opsEP14vendor_tag_ops',
]
HMI_SIZE = 400


class Report:
    def __init__(self):
        self.rows = []

    def add(self, status, part, name, detail=''):
        self.rows.append((status, part, name, detail))
        print(f'{status:6} {part:8} {name}' + (f': {detail}' if detail else ''), flush=True)

    def failed(self):
        return any(r[0] == 'FAIL' for r in self.rows)


def find_in_dump(dump, rel):
    try:
        return B.src(dump, rel)
    except FileNotFoundError:
        return None


def check_files(dump, r):
    entries = [(s, d) for s, d, _ in json.loads((HERE / 'selection.json').read_text())]
    entries += list(B.EXTRA_COPIES.items())
    missing = [s for s, d in entries if s not in B.SKIP and d not in B.SKIP and not find_in_dump(dump, s)]
    for s in missing:
        r.add('FAIL', 'files', s, 'not in the dump (renamed or removed?)')
    if not missing:
        r.add('OK', 'files', f'all {len(entries)} firmware files present')


def check_aps(dump, r):
    s = next(
        (
            s
            for s, d, _ in json.loads((HERE / 'selection.json').read_text())
            if d.endswith('libAPSClient-cmd-jni.so')
        ),
        None,
    )
    p = find_in_dump(dump, s) if s else None
    if not p:
        r.add('FAIL', 'aps', 'libAPSClient-cmd-jni.so', 'not in the dump')
    elif hashlib.sha256(p.read_bytes()).hexdigest() == P.APS_STOCK:
        r.add('OK', 'aps', 'apsclient_force_java_heif', 'same file')
    else:
        r.add(
            'FAIL',
            'aps',
            'apsclient_force_java_heif',
            'exact-build patch: re-derive APS_TARGETS for the new file',
        )


FIXLIB = re.compile(r'\bfixlib\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+"([^"]+)"')


def fixlib_calls():
    """(ROM path, [[variant (orig, new), ...] per edit], label) for every fixlib call in customize.sh,
    with the hex lists customize.sh takes from module/common.sh variables."""
    text = (B.REPO / 'module/customize.sh').read_text().replace('\\\n', ' ')
    common = (B.REPO / 'module/common.sh').read_text()
    variables = dict(re.findall(r'^(\w+)=(/\S+)$', text, re.M))
    variables.update(re.findall(r'^(\w+)="([0-9a-f+|]+)"$', common, re.M))

    def value(v):
        v = v.strip("'\"")
        m = re.fullmatch(r'\$\{?(\w+)\}?', v)
        return variables.get(m.group(1), v) if m else v

    calls = []
    for m in FIXLIB.finditer(text):
        src, _dst, _off, orig, new, label = m.groups()
        orig, new = value(orig), value(new)
        if not re.fullmatch(r'[0-9a-f+|]+', orig) or not re.fullmatch(r'[0-9a-f+|]+', new):
            calls.append((value(src), None, label))
            continue
        edits = [list(zip(o.split('|'), n.split('|'))) for o, n in zip(orig.split('+'), new.split('+'))]
        calls.append((value(src), edits, label))
    return calls


def check_install(dump, r):
    for src, edits, label in fixlib_calls():
        if edits is None:
            r.add('NOTE', 'install', label, 'fixlib call not understood')
            continue
        p = find_in_dump(dump, src.lstrip('/')) if src.startswith('/') else None
        if not p:
            r.add(
                'NOTE', 'install', label, f'{src} is a LineageOS file not in this dump (checked at install)'
            )
            continue
        d = p.read_bytes()
        counts = [sum(d.count(bytes.fromhex(o)) + d.count(bytes.fromhex(n)) for o, n in e) for e in edits]
        if all(c == 1 for c in counts):
            r.add('OK', 'install', label, f'{len(edits)} edit(s), each found once')
        else:
            r.add('FAIL', 'install', label, f'edits found {counts} times (each needs exactly 1)')


def check_app_blobs(dump, r):
    missing = [rel for rel in A.paths() if not find_in_dump(dump, rel)]
    for rel in missing[:20]:
        r.add('FAIL', 'appblobs', rel, 'not in the dump (renamed or removed? update tools/app_blobs.txt)')
    if len(missing) > 20:
        r.add('FAIL', 'appblobs', f'{len(missing) - 20} more missing')
    if not missing:
        r.add('OK', 'appblobs', f'all {len(A.paths())} camera app files present')
    ctx = find_in_dump(dump, A.CONTEXTS)
    try:
        A.check_mounts(A.paths())
        if not ctx:
            raise ValueError(f'{A.CONTEXTS} not in the dump (extract the odm image with its labels)')
        n = len(A.labels(A.read_contexts(ctx.read_text(encoding='utf-8')), A.paths()))
        r.add('OK', 'appblobs', f'labels for {n} files and folders')
    except ValueError as e:
        r.add('FAIL', 'appblobs', str(e))
    with tempfile.TemporaryDirectory() as td:
        for rel in A.fixups():
            p = find_in_dump(dump, rel)
            if not p:
                continue
            t = Path(td) / Path(rel).name
            shutil.copy2(p, t)
            try:
                r.add('OK', 'appblobs', rel, ', '.join(A.fix(rel, t)))
            except ValueError as e:
                r.add('FAIL', 'appblobs', rel, str(e))


def dyn_symbols(path):
    tool = shutil.which('llvm-readelf') or shutil.which('readelf')
    if not tool:
        return None
    out = subprocess.run([tool, '--dyn-syms', '-W', str(path)], capture_output=True, text=True).stdout
    syms = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 8 and f[0].rstrip(':').isdigit() and f[6] != 'UND':
            syms[f[7].split('@')[0]] = int(f[2], 0) if f[2].isdigit() else int(f[2], 16)
    return syms


def check_wrapper(dump, r):
    p = find_in_dump(dump, 'odm/lib64/hw/camera.oemlayer.v2.so')
    if not p:
        r.add('FAIL', 'wrapper', 'camera.oemlayer.v2.so', 'not in the dump')
        return
    syms = dyn_symbols(p)
    if syms is None:
        r.add('NOTE', 'wrapper', 'symbols', 'readelf not found, not checked')
        return
    if not syms:
        r.add(
            'FAIL',
            'wrapper',
            'camera.oemlayer.v2.so',
            'no dynamic symbols could be read (not a valid ELF file?)',
        )
        return
    for s in WRAPPER_SYMBOLS:
        if s not in syms:
            r.add('FAIL', 'wrapper', s, 'not exported by the new layer')
        elif s == 'HMI' and syms[s] != HMI_SIZE:
            r.add('FAIL', 'wrapper', s, f'size {syms[s]}, the wrapper copies {HMI_SIZE} (oemwrap.c HMI_SIZE)')
        else:
            r.add('OK', 'wrapper', s)
    r.add(
        'NOTE',
        'wrapper',
        'camera3 struct offsets',
        "re-check against camera.qcom.so's logging if the HAL blobs change (ARCHITECTURE.md)",
    )


def check_smali(dump, apktool, r):
    if not apktool:
        r.add('NOTE', 'smali', 'app/SDK patches', 'pass --apktool to check them')
        return
    jobs = [
        ('app', B.APK_SRC, B.APP_PATCHES),
        ('sdk', B.SDK_SRC, B.SDK_PATCHES),
        ('adapter', B.ADAPTER_SRC, B.ADAPTER_PATCHES),
    ]
    with tempfile.TemporaryDirectory() as td:
        for name, rel, fns in jobs:
            p = find_in_dump(dump, rel)
            if not p:
                r.add('FAIL', 'smali', name, f'{rel} not in the dump')
                continue
            w = Path(td) / name
            subprocess.run(
                [*B.JAVA, '-jar', apktool, 'd', '-f', '-o', str(w), str(p)], check=True, capture_output=True
            )
            for f in fns:
                try:
                    r.add('OK', 'smali', f'{name}: {f.__name__}', str(f(w)))
                except Exception as e:  # report every patch, not just the first that fails
                    r.add('FAIL', 'smali', f'{name}: {f.__name__}', f'{e}' or traceback.format_exc(limit=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--dump', required=True, type=Path)
    ap.add_argument('--apktool')
    args = ap.parse_args()
    dump = args.dump.resolve()
    r = Report()
    check_files(dump, r)
    check_app_blobs(dump, r)
    check_aps(dump, r)
    check_install(dump, r)
    check_wrapper(dump, r)
    check_smali(dump, args.apktool, r)
    counts = {s: sum(1 for x in r.rows if x[0] == s) for s in ('OK', 'MOVED', 'FAIL', 'NOTE')}
    print('\n' + ', '.join(f'{v} {k}' for k, v in counts.items()))
    if r.failed():
        print('Re-derive the FAIL items before building for this firmware (docs/MAINTAINING.md).')
    sys.exit(1 if r.failed() else 0)


if __name__ == '__main__':
    main()
