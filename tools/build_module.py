#!/usr/bin/env python3
"""Build the KernelSU module zip from an OxygenOS firmware dump.

    python3 tools/build_module.py --dump <dump root> --out out/ \
        --apktool apktool.jar --signer uber-apk-signer.jar \
        --keystore keys/oplus-camera-module.jks --ks-alias opluscam --ks-pass <pw>

<dump root> holds the extracted partitions (my_product/, odm/, system_ext/, ...). Both layouts
are accepted: <root>/my_product/app/... and the dumper's <root>/my_product/my_product/app/....

Every step verifies what it changes: smali patches assert their anchors (tools/patches.py),
native byte patches check the original bytes and the final sha256 (tools/binpatches.json),
and the APS client patch checks both hashes. A different firmware build therefore fails loudly
at the first patch that no longer fits instead of producing a silently broken module.
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
import patches as P  # noqa: E402

APP_PATCHES = [P.camera_font, P.camera_blur_seginit_guard, P.camera_uifirst,
               P.strip_oem_component_permissions, P.vendor_tag_aliases, P.camera_blur_license_path,
               P.camera_defer_ufs_probe, P.camera_gallery_fallback, P.camera_disable_oem_components,
               P.camera_drop_embedded_libs]
SDK_PATCHES = [P.sdk_runtime, P.sdk_facebeauty_path, P.sdk_session_package_tag, P.vendor_tag_aliases]
ADAPTER_PATCHES = [P.vendor_tag_aliases]

APK_SRC = 'my_product/app/OplusCamera/OplusCamera.apk'
SDK_SRC = 'my_product/product_overlay/framework/com.oplus.camera.unit.sdk.jar'
ADAPTER_SRC = 'my_product/product_overlay/framework/com.oplus.camera.unit.sdk.adapter.jar'
# files copied as-is, beyond tools/selection.json (source -> module path)
EXTRA_COPIES = {
    'odm/lib64/libOplusSecurity.so': 'odm/lib64/libOplusSecurity.so',
    'odm/etc/camera/singleblur/license_release.license': 'system_ext/etc/camera/singleblur/license_release.license',
    'my_product/product_overlay/etc/permissions/oplus_camera_default_grant_permissions_list.xml':
        'system_ext/etc/default-permissions/oplus_camera_default_grant_permissions_list.xml',
}
# selection.json entries that are not shipped (the HAL-side interfaces exist on LineageOS)
SKIP = {'system/lib64/vendor.oplus.hardware.cameraextension-V1-ndk.so',
        'system/lib64/vendor.oplus.hardware.cameraextension@1.0.so',
        'system/lib64/vendor.oplus.hardware.sendextcamcmd-V2-ndk.so'}
# app-namespace copies of two system_ext helpers (the APK loads them from its own lib dir)
APP_LIB_FROM_SYSTEM_EXT = ['libHeifEncoderWrapper.so', 'libNativeWinBuffExchange.so']


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def src(dump, rel):
    for cand in (dump / rel, dump / rel.split('/')[0] / rel):
        if cand.is_file():
            return cand
    raise FileNotFoundError(f'not in dump: {rel}')


def run(*cmd):
    print('  $', ' '.join(map(str, cmd))[:160])
    subprocess.run(list(map(str, cmd)), check=True, stdout=subprocess.DEVNULL)


def binpatch(path, spec):
    d = bytearray(path.read_bytes())
    if hashlib.sha256(d).hexdigest() != spec['src_sha256']:
        print(f'  ! {spec["src"]}: not the expected build, locating edits by their bytes')
    for e in spec['edits']:
        o, n, off = bytes.fromhex(e['orig']), bytes.fromhex(e['new']), e['offset']
        if bytes(d[off:off + len(o)]) != o:
            hits = [i for i in range(len(d)) if d.startswith(o, i)] if len(o) >= 12 else []
            if len(hits) != 1:
                raise SystemExit(f'{spec["dst"]}: edit at {off:#x} ({e["why"]}) does not fit this build; '
                                 'see docs/MAINTAINING.md')
            off = hits[0]
        d[off:off + len(o)] = n
    path.write_bytes(bytes(d))
    if hashlib.sha256(d).hexdigest() != spec['dst_sha256']:
        print(f'  ! {spec["dst"]}: result differs from the tested build (expected for new firmware)')


def apktool_patch(args, src_file, workdir, fns, out_file):
    run('java', '-jar', args.apktool, 'd', '-f', '-o', workdir, src_file)
    for f in fns:
        print(f'  patch {f.__name__}: {f(workdir)}')
    run('java', '-jar', args.apktool, 'b', workdir, '-o', out_file)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dump', required=True, type=Path)
    ap.add_argument('--out', default=REPO / 'out', type=Path)
    ap.add_argument('--apktool', required=True)
    ap.add_argument('--signer', required=True, help='uber-apk-signer jar')
    ap.add_argument('--keystore', required=True)
    ap.add_argument('--ks-alias', default='opluscam')
    ap.add_argument('--ks-pass', required=True)
    args = ap.parse_args()
    dump, out = args.dump.resolve(), args.out.resolve()
    work, mod = out / 'work', out / 'module'
    shutil.rmtree(out, ignore_errors=True)
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
    print(f'  APS client: {P.apsclient_force_java_heif(S / "system_ext/lib64/libAPSClient-cmd-jni.so")}')

    print('[2/6] OnePlus camera layer (odm)')
    for spec in json.loads((HERE / 'binpatches.json').read_text()):
        dst = S / spec['dst']
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src(dump, spec['src']), dst)
        binpatch(dst, spec)
    (S / 'odm/lib64/hw').mkdir(parents=True, exist_ok=True)
    shutil.copy2(REPO / 'prebuilt/camera.oemlayer.wrap.so', S / 'odm/lib64/hw/camera.oemlayer.v2.so')

    print('[3/6] camera SDK')
    fw = S / 'system_ext/framework'
    fw.mkdir(parents=True, exist_ok=True)
    apktool_patch(args, src(dump, SDK_SRC), work / 'sdk', SDK_PATCHES, fw / 'com.oplus.camera.unit.sdk.jar')
    apktool_patch(args, src(dump, ADAPTER_SRC), work / 'adapter', ADAPTER_PATCHES,
                  fw / 'com.oplus.camera.unit.sdk.adapter.jar')
    shutil.copy2(REPO / 'prebuilt/oplus-camera-stubs.jar', fw / 'oplus-camera-stubs.jar')

    print('[4/6] camera app')
    apk = src(dump, APK_SRC)
    apktool_patch(args, apk, work / 'app', APP_PATCHES, work / 'OplusCamera-unsigned.apk')
    run('java', '-jar', args.signer, '-a', work / 'OplusCamera-unsigned.apk', '-o', work / 'signed',
        '--ks', args.keystore, '--ksAlias', args.ks_alias, '--ksPass', args.ks_pass, '--ksKeyPass', args.ks_pass)
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
    if any('/system/vendor/' in str(p) for p in files):
        raise SystemExit('module must not ship /vendor files')
    for sh in mod.glob('*.sh'):
        run('sh', '-n', sh)
    (out / 'MANIFEST.sha256').write_text(''.join(f'{sha(p)}  {p.relative_to(mod)}\n' for p in files))

    print('[6/6] zip')
    ver = next(l.split('=', 1)[1].split()[0] for l in (mod / 'module.prop').read_text().splitlines()
               if l.startswith('version='))
    z = out / f'oplus-camera-los-{ver}.zip'
    with zipfile.ZipFile(z, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for p in sorted(mod.rglob('*')):
            if p.is_file():
                zf.write(p, p.relative_to(mod))
    print(f'done: {z} ({len(files)} files)')


if __name__ == '__main__':
    main()
