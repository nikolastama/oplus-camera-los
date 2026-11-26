#!/usr/bin/env python3
"""Regenerate diffs/: one unified diff per patch, against a fresh apktool decode of the stock file.

    python3 tools/make_diffs.py --dump <firmware dump root> --apktool apktool.jar

Run it after changing any patch in tools/patches.py, and commit the result with the change.
"""

import argparse
import hashlib
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build_module as B  # noqa: E402

GIT = ['git', '-c', 'user.name=x', '-c', 'user.email=x']


def record(args, src, name, fns, out):
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob('*'):
        old.unlink()
    with tempfile.TemporaryDirectory() as td:
        t = Path(td) / name
        subprocess.run(
            [*B.JAVA, '-jar', args.apktool, 'd', '-f', '-o', t, src], check=True, stdout=subprocess.DEVNULL
        )
        subprocess.run(['git', 'init', '-q'], cwd=t, check=True)
        subprocess.run(['git', 'add', '-A'], cwd=t, check=True)
        subprocess.run(GIT + ['commit', '-qm', 'stock'], cwd=t, check=True)
        for i, f in enumerate(fns, 1):
            f(t)
            subprocess.run(['git', 'add', '-A'], cwd=t, check=True)
            if f.__name__ == 'camera_drop_embedded_libs':
                with zipfile.ZipFile(src) as z:
                    lines = [
                        f'{hashlib.sha256(z.read(n)).hexdigest()}  {len(z.read(n))}  {n}'
                        for n in z.namelist()
                        if n.startswith('lib/arm64-v8a/') and n.endswith('.so')
                    ]
                (out / f'{i:02d}-{f.__name__}.txt').write_text(
                    '# removed from the APK (shipped in priv-app/OplusCamera/lib/arm64 instead); '
                    'revert: --skip camera_drop_embedded_libs\n# sha256  size  file\n'
                    + '\n'.join(lines)
                    + '\n',
                    newline='\n',
                )
            else:
                d = subprocess.run(
                    ['git', 'diff', '--cached'], cwd=t, check=True, capture_output=True, text=True
                ).stdout
                (out / f'{i:02d}-{f.__name__}.diff').write_text(d, newline='\n')
            subprocess.run(GIT + ['commit', '-qm', f.__name__, '--allow-empty'], cwd=t, check=True)
            print(f'{name}: {f.__name__}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dump', required=True, type=Path)
    ap.add_argument('--apktool', required=True)
    args = ap.parse_args()
    D = HERE.parent / 'diffs'
    record(args, B.src(args.dump, B.APK_SRC), 'app', B.APP_PATCHES, D / 'app')
    record(args, B.src(args.dump, B.SDK_SRC), 'sdk', B.SDK_PATCHES, D / 'sdk')
    record(args, B.src(args.dump, B.ADAPTER_SRC), 'sdk-adapter', B.ADAPTER_PATCHES, D / 'sdk-adapter')
    record(args, HERE.parent / 'prebuilt/oplus-camera-stubs.jar', 'stubs', B.STUBS_PATCHES, D / 'stubs')


if __name__ == '__main__':
    main()
