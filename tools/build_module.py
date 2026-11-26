#!/usr/bin/env python3
"""Build the KernelSU module zip from a ColorOS firmware dump.

    python3 tools/build_module.py --dump <dump root> --out out/ \
        --apktool apktool.jar --signer uber-apk-signer.jar \
        --keystore keys/oplus-camera-module.jks --ks-alias opluscam

The keystore password is read from the environment variable OPLUS_CAMERA_KS_PASS (or --ks-pass,
which leaves it in your shell history).

<dump root> holds the extracted partitions (my_product/, odm/, system_ext/, ...). Both layouts
are accepted: <root>/my_product/app/... and the dumper's <root>/my_product/my_product/app/....

Every step verifies what it changes: smali patches assert their anchors (tools/patches.py),
app-blob fixups check their bytes (tools/app_blobs.py), and the APS client patch checks both
hashes. A different firmware build therefore fails loudly
at the first patch that no longer fits instead of producing a silently broken module.

Every change can be left out for testing or reverting (see docs/REVERTING.md):
    --list-patches                     show every patch / edit id
    --skip <name>                      skip a smali patch function, apsclient_force_java_heif
                                       or app_blobs (repeatable)
    --enable-component <class>         keep one of the components camera_disable_oem_components
                                       would disable (repeatable)
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
import app_blobs as A  # noqa: E402
import patches as P  # noqa: E402

APP_PATCHES = [
    P.camera_font,
    P.camera_blur_seginit_guard,
    P.camera_uifirst,
    P.strip_oem_component_permissions,
    P.vendor_tag_aliases,
    P.camera_defer_ufs_probe,
    P.camera_gallery_fallback,
    P.camera_disable_oem_components,
    P.restrict_exported_components,
    P.camera_no_telemetry,
    P.camera_hide_dead_settings,
    P.camera_scoped_props,
    P.camera_drop_embedded_libs,
]
SDK_PATCHES = [P.sdk_runtime, P.sdk_facebeauty_path, P.sdk_session_package_tag, P.vendor_tag_aliases]
ADAPTER_PATCHES = [P.sdk_facebeauty_path, P.vendor_tag_aliases]
STUBS_PATCHES = [P.stubs_scoped_props, P.stubs_framework_classes, P.stubs_surfaceext_jni]

APK_SRC = 'my_product/app/OplusCamera/OplusCamera.apk'
SDK_SRC = 'my_product/product_overlay/framework/com.oplus.camera.unit.sdk.jar'
ADAPTER_SRC = 'my_product/product_overlay/framework/com.oplus.camera.unit.sdk.adapter.jar'
# files copied as-is, beyond tools/selection.json (source -> module path)
EXTRA_COPIES = {
    'odm/lib64/libOplusSecurity.so': 'odm/lib64/libOplusSecurity.so',
    'my_product/product_overlay/etc/permissions/oplus_camera_default_grant_permissions_list.xml': 'system_ext/etc/default-permissions/oplus_camera_default_grant_permissions_list.xml',
}
# selection.json entries that are not shipped (the HAL-side interfaces exist on LineageOS)
SKIP = {
    'system/lib64/vendor.oplus.hardware.cameraextension-V1-ndk.so',
    'system/lib64/vendor.oplus.hardware.cameraextension@1.0.so',
    'system/lib64/vendor.oplus.hardware.sendextcamcmd-V2-ndk.so',
}
# app-namespace copies of two system_ext helpers (the APK loads them from its own lib dir)
APP_LIB_FROM_SYSTEM_EXT = ['libHeifEncoderWrapper.so', 'libNativeWinBuffExchange.so']


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def src(dump, rel):
    top = rel.split('/')[0]
    # system-as-root dumps keep system's files one level deeper: <root>/system/system/system/lib64
    for cand in (dump / rel, dump / top / rel, dump / top / top / rel):
        if cand.is_file():
            return cand
    raise FileNotFoundError(f'not in dump: {rel}')


def _link_or_copy(a, b):
    """Hard link (no second 1.6 GB on disk), or copy where links aren't possible."""
    try:
        os.link(a, b)
    except OSError:
        shutil.copyfile(a, b)


SECRET_FLAGS = ('--ksPass', '--ksKeyPass')


def shown(cmd):
    """The command as printed: the value after a password flag is masked."""
    out = [str(a).replace('\n', '\\n') for a in cmd]
    for i, a in enumerate(out[:-1]):
        if a in SECRET_FLAGS:
            out[i + 1] = '***'
    return ' '.join(out)


# apktool writes smali/XML with the JVM's line separator: LF everywhere, so the patches' anchors and
# the recorded diffs match on Windows too
JAVA = ('java', '-Dline.separator=\n')


def run(*cmd, env=None):
    print('  $', shown(cmd)[:160])
    subprocess.run(
        list(map(str, cmd)), check=True, stdout=subprocess.DEVNULL, env={**os.environ, **env} if env else None
    )


STORED_SUFFIXES = ('.img', '.apk', '.jar')


def write_zip(root, path):
    """Zip <root>'s files in a fixed order with fixed timestamps, so the same inputs always give
    the same zip (KernelSU sets the permissions itself, so none are stored). Files that are already
    compressed (STORED_SUFFIXES: the erofs image, the APK, the jars) are stored as they are, so the
    installer only copies them instead of inflating them."""
    with zipfile.ZipFile(path, 'w') as zf:
        for p in sorted(p for p in root.rglob('*') if p.is_file()):
            info = zipfile.ZipInfo(p.relative_to(root).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            if p.suffix in STORED_SUFFIXES:
                info.compress_type = zipfile.ZIP_STORED
            else:
                info.compress_type, info.compress_level = zipfile.ZIP_DEFLATED, 9
            with p.open('rb') as src, zf.open(info, 'w') as dst:
                shutil.copyfileobj(src, dst, 2**24)


def apktool_patch(args, src_file, workdir, fns, out_file):
    run(*JAVA, '-jar', args.apktool, 'd', '-f', '-o', workdir, src_file)
    for f in fns:
        if f.__name__ in args.skip:
            print(f'  SKIPPED {f.__name__}')
            continue
        print(f'  patch {f.__name__}: {f(workdir)}')
    run(*JAVA, '-jar', args.apktool, 'b', workdir, '-o', out_file)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--list-patches', action='store_true')
    ap.add_argument('--skip', action='append', default=[])
    ap.add_argument('--enable-component', action='append', default=[])
    ap.add_argument('--dump', type=Path)
    ap.add_argument('--out', default=REPO / 'out', type=Path)
    ap.add_argument('--apktool')
    ap.add_argument('--signer', help='uber-apk-signer jar')
    ap.add_argument('--keystore')
    ap.add_argument('--ks-alias', default='opluscam')
    ap.add_argument('--mkfs-erofs', default=shutil.which('mkfs.erofs'), help='mkfs.erofs (erofs-utils 1.7+)')
    ap.add_argument(
        '--no-dedupe',
        action='store_true',
        help='make blobs.img on all cores without dedupe (test builds: faster, ~0.2 GB larger)',
    )
    ap.add_argument('--ks-pass', default=os.environ.get('OPLUS_CAMERA_KS_PASS'), help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.list_patches:
        print('app:     ', ' '.join(f.__name__ for f in APP_PATCHES))
        print('sdk:     ', ' '.join(f.__name__ for f in SDK_PATCHES))
        print('adapter: ', ' '.join(f.__name__ for f in ADAPTER_PATCHES))
        print('stubs:   ', ' '.join(f.__name__ for f in STUBS_PATCHES))
        print('native:   apsclient_force_java_heif')
        print(f'app_blobs: {len(A.paths())} files from tools/app_blobs.txt; fixups:', ' '.join(A.fixups()))
        print('components disabled:', ' '.join(P.OEM_ONLY_COMPONENTS))
        return
    for need in ('dump', 'apktool', 'signer', 'keystore'):
        if not getattr(args, need):
            ap.error(f'--{need.replace("_", "-")} is required')
    if not args.ks_pass:
        ap.error('set the keystore password in OPLUS_CAMERA_KS_PASS')
    known = {f.__name__ for f in APP_PATCHES + SDK_PATCHES + ADAPTER_PATCHES + STUBS_PATCHES} | {
        'apsclient_force_java_heif',
        'app_blobs',
    }
    bad = [s for s in args.skip if s not in known]
    if bad:
        ap.error(f'unknown --skip {bad}; see --list-patches')
    args.skip = set(args.skip)
    if 'app_blobs' not in args.skip and not args.mkfs_erofs:
        ap.error('mkfs.erofs not found: put it on PATH or pass --mkfs-erofs (or --skip app_blobs)')
    for c in args.enable_component:
        if c not in P.OEM_ONLY_COMPONENTS:
            ap.error(f'{c} is not in OEM_ONLY_COMPONENTS')
        P.OEM_ONLY_COMPONENTS.remove(c)
    dump, out = args.dump.resolve(), args.out.resolve()
    work, mod = out / 'work', out / 'module'
    # only ever delete what an earlier build put there, never the --out folder itself
    for old in (work, mod):
        shutil.rmtree(old, ignore_errors=True)
    work.mkdir(parents=True)
    shutil.copytree(REPO / 'module', mod)
    shutil.copytree(REPO / 'overlay', mod / 'system', dirs_exist_ok=True)
    S = mod / 'system'

    print('[1/6] copy firmware files')
    for s, d, _ in json.loads((HERE / 'selection.json').read_text()):
        if s in SKIP or d in SKIP:
            continue
        (S / d).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src(dump, s), S / d)
    for s, d in EXTRA_COPIES.items():
        (S / d).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src(dump, s), S / d)
    # the camera app's own libraries and data, which LineageOS no longer ships (tools/app_blobs.py)
    if 'app_blobs' in args.skip:
        print('  SKIPPED app_blobs')
    else:
        missing = [r for r in A.paths() if not (dump / r).is_file() and not (dump / 'odm' / r).is_file()]
        if missing:
            raise SystemExit(
                f'{len(missing)} camera app files not in the dump, e.g. {missing[:3]}; see tools/app_blobs.txt'
            )
        # kept out of system/: the metamodule copies only partition folders into its image, which
        # these don't fit in. They go into their own read-only erofs image with the odm image's
        # labels, which post-mount.sh mounts (tools/app_blobs.py, IMAGE and MOUNTS).
        A.check_mounts(A.paths())
        (mod / '.app_blobs').write_text(''.join(r + '\n' for r in A.paths()), newline='\n')
        # the image takes minutes to make: reuse the last one while its inputs are unchanged
        cache, key_file = out / 'cache', out / 'cache/blobs.key'
        key = A.image_key(
            [(r, src(dump, r)) for r in A.paths()] + [(A.CONTEXTS, src(dump, A.CONTEXTS))],
            Path(args.mkfs_erofs),
            dedupe=not args.no_dedupe,
        )
        if (cache / A.IMAGE).is_file() and key_file.is_file() and key_file.read_text() == key:
            _link_or_copy(cache / A.IMAGE, mod / A.IMAGE)
            print(
                f'  {A.IMAGE}: inputs unchanged, reused out/cache/{A.IMAGE} (delete out/cache to remake it)'
            )
        else:
            blobs = work / 'blobs'
            for r in A.paths():
                (blobs / r).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src(dump, r), blobs / r)
            for r in A.fixups():
                print(f'  {r}: {", ".join(A.fix(r, blobs / r))}')
            contexts = A.read_contexts(src(dump, A.CONTEXTS).read_text(encoding='utf-8'))
            (work / 'blobs.file_contexts').write_text(
                A.image_file_contexts(A.labels(contexts, A.paths())), newline='\n'
            )
            (work / 'blobs.fs_config').write_text(A.image_fs_config(A.paths()), newline='\n')
            run(
                *A.mkfs_command(args.mkfs_erofs, work, blobs, mod / A.IMAGE, dedupe=not args.no_dedupe),
                env={'TMPDIR': work.as_posix()},
            )
            size = sum(f.stat().st_size for f in blobs.rglob('*') if f.is_file())
            print(
                f'  {len(A.paths())} camera app files, {size // 2**20} MB in {A.IMAGE} of '
                f'{(mod / A.IMAGE).stat().st_size // 2**20} MB (outside the metamodule image)'
            )
            shutil.rmtree(cache, ignore_errors=True)
            cache.mkdir()
            _link_or_copy(mod / A.IMAGE, cache / A.IMAGE)
            key_file.write_text(key)
    if 'apsclient_force_java_heif' in args.skip:
        print('  SKIPPED apsclient_force_java_heif')
    else:
        print(f'  APS client: {P.apsclient_force_java_heif(S / "system_ext/lib64/libAPSClient-cmd-jni.so")}')

    print('[2/6] OnePlus camera layer wrapper (the installer adds copies of LineageOS\'s layer)')
    (S / 'odm/lib64/hw').mkdir(parents=True, exist_ok=True)
    shutil.copy2(REPO / 'prebuilt/camera.oemlayer.wrap.so', S / 'odm/lib64/hw/camera.oemlayer.v2.so')

    print('[3/6] camera SDK')
    fw = S / 'system_ext/framework'
    fw.mkdir(parents=True, exist_ok=True)
    apktool_patch(args, src(dump, SDK_SRC), work / 'sdk', SDK_PATCHES, fw / 'com.oplus.camera.unit.sdk.jar')
    apktool_patch(
        args,
        src(dump, ADAPTER_SRC),
        work / 'adapter',
        ADAPTER_PATCHES,
        fw / 'com.oplus.camera.unit.sdk.adapter.jar',
    )
    apktool_patch(
        args,
        REPO / 'prebuilt/oplus-camera-stubs.jar',
        work / 'stubs',
        STUBS_PATCHES,
        fw / 'oplus-camera-stubs.jar',
    )

    print('[4/6] camera app')
    apk = src(dump, APK_SRC)
    apktool_patch(args, apk, work / 'app', APP_PATCHES, work / 'OplusCamera-unsigned.apk')
    run(
        'java',
        '-jar',
        args.signer,
        '-a',
        work / 'OplusCamera-unsigned.apk',
        '-o',
        work / 'signed',
        '--ks',
        args.keystore,
        '--ksAlias',
        args.ks_alias,
        '--ksPass',
        args.ks_pass,
        '--ksKeyPass',
        args.ks_pass,
    )
    app = S / 'system_ext/priv-app/OplusCamera'
    (app / 'lib/arm64').mkdir(parents=True, exist_ok=True)
    shutil.copy2(next((work / 'signed').glob('*-aligned-signed.apk')), app / 'OplusCamera.apk')
    with zipfile.ZipFile(apk) as z:  # native libs live next to the APK (system-app layout)
        for n in z.namelist():
            if n.startswith('lib/arm64-v8a/') and n.endswith('.so'):
                (app / 'lib/arm64' / Path(n).name).write_bytes(z.read(n))
    for n in APP_LIB_FROM_SYSTEM_EXT:
        shutil.copy2(S / 'system_ext/lib64' / n, app / 'lib/arm64' / n)

    print('[5/6] verify')
    files = sorted(p for p in S.rglob('*') if p.is_file())
    if any('/system/vendor/' in p.as_posix() for p in files):
        raise SystemExit('module must not ship /vendor files')
    for sh in mod.glob('*.sh'):
        run('sh', '-n', sh)
    every = sorted(p for p in mod.rglob('*') if p.is_file())  # the zip's contents, scripts included
    (out / 'MANIFEST.sha256').write_text(
        ''.join(f'{sha(p)}  {p.relative_to(mod).as_posix()}\n' for p in every),
        newline='\n',
    )

    print('[6/6] zip')
    ver = next(
        line.split('=', 1)[1].split()[0]
        for line in (mod / 'module.prop').read_text().splitlines()
        if line.startswith('version=')
    )
    z = out / f'oplus-camera-los-{ver}.zip'
    write_zip(mod, z)
    print(f'done: {z} ({len(every)} files)')


if __name__ == '__main__':
    main()
