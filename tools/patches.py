"""Smali / manifest / binary patches for the OnePlus camera on LineageOS 24.

Ported from OP15InfinityX/android_device_oneplus_infiniti-camera (OxygenOS 16 era,
commit c137d20) and retargeted to OxygenOS 16.0.10.601 (CPH2745 EX01) class names.
Every patch locates its target by a content anchor and fails loudly if the anchor
is missing, so a different camera build can never be patched silently.
"""

import re
import shutil
from hashlib import sha256
from pathlib import Path


def _read(path):
    # surrogateescape round-trips any byte apktool writes, so a file is never changed by accident
    return Path(path).read_text(encoding='utf-8', errors='surrogateescape')


def _write(path, text):
    Path(path).write_text(text, encoding='utf-8', errors='surrogateescape')


def _smali(root):
    return Path(root).glob('smali*/**/*.smali')


def _replace_method(data, signature, body):
    pat = re.compile(r'(\.method ' + re.escape(signature) + r'\n)(.*?)(\.end method)', re.S)
    return pat.sub(lambda m: m.group(1) + body + m.group(3), data, count=1)


def _find(root, glob, anchor):
    for p in Path(root).glob(glob):
        t = _read(p)
        if anchor in t:
            return p, t
    raise ValueError(f'anchor not found: {anchor!r}')


# ---------------------------------------------------------------- OplusCamera.apk


def camera_font(root):
    """TypeFaceUtil reads OEM font framework state absent on LineageOS -> Typeface.DEFAULT."""
    sig = 'public static a(Landroid/content/Context;)Landroid/graphics/Typeface;'
    for p in _smali(root):
        t = _read(p)
        if '"TypeFaceUtil"' in t and f'.method {sig}' in t:
            new = _replace_method(
                t,
                sig,
                '    .locals 1\n\n    sget-object v0, Landroid/graphics/Typeface;->DEFAULT:Landroid/graphics/Typeface;\n\n    return-object v0\n',
            )
            _write(p, new)
            return str(p)
    raise ValueError('TypeFaceUtil.a(Context) not found')


SEG = (
    r'Lcom/oplus/ocs/camera/OplusBlurPreviewHelper;->segInit\(Ljava/lang/String;Ljava/lang/String;'
    r'Ljava/lang/String;Ljava/lang/String;II\)\[I'
)


def camera_blur_seginit_guard(root):
    """Portrait blur dereferences segInit()'s int[] without a null check; treat null as 'no blur'."""
    p, t = _find(root, 'smali*/**/*.smali', '/odm/etc/camera/singleblur/personseg.bin')
    cls = re.search(r'^\.class .*?(L[\w/$]+;)', t, re.M).group(1)
    pat = (
        r'(?s)(invoke-virtual/range \{v1 \.\. v7\}, '
        + SEG
        + r'.*?move-result-object v0.*?sput-object v0, '
        + re.escape(cls)
        + r'->(\w+):\[I)'
    )
    # registers verified for this build: synchronized e(II)Z holds the monitor in v10, v12 == false
    if 'monitor-enter v10' not in t or 'const/4 v12, 0x0' not in t:
        raise ValueError('blur init register layout changed')
    t2, n = re.subn(
        pat,
        r'\1\n\n    if-nez v0, :cond_los_blur_seginit_ok\n\n    monitor-exit v10\n\n    return v12\n\n    :cond_los_blur_seginit_ok',
        t,
        count=1,
    )
    if n != 1:
        raise ValueError('blur init segInit not patched')
    _write(p, t2)

    p2, t = _find(root, 'smali*/**/*.smali', 'initSegForSizeChange, segInit, cost: ')
    pat = (
        r'(?s)(invoke-virtual/range \{v3 \.\. v9\}, '
        + SEG
        + r'.*?move-result-object p0.*?sput-object p0, '
        + re.escape(cls)
        + r'->\w+:\[I)'
    )
    t2, n = re.subn(
        pat,
        r'\1\n\n    if-nez p0, :cond_los_blur_size_ok\n\n    return-void\n\n    :cond_los_blur_size_ok',
        t,
        count=1,
    )
    if n != 1:
        raise ValueError('blur size-change segInit not patched')
    _write(p2, t2)
    return f'{p}, {p2}'


def camera_uifirst(root):
    """LineageOS's boot-classpath OplusUIFirstManager lacks setUxThreadValue(IILString;)V."""
    call = re.compile(
        r'^\s*invoke-virtual \{[^}]*\}, Lcom/oplus/uifirst/OplusUIFirstManager;->setUxThreadValue\(IILjava/lang/String;\)V\n',
        re.M,
    )
    hits = []
    for p in _smali(root):
        t = _read(p)
        if 'setUxThreadValue' in t:
            t2, n = call.subn('    nop\n', t)
            if n:
                _write(p, t2)
                hits.append(f'{p.name}x{n}')
    if not hits:
        raise ValueError('setUxThreadValue call sites not found')
    return ', '.join(hits)


def strip_oem_component_permissions(root):
    """Undefined OEM permissions would lock the launcher and other apps out of camera components."""
    m = Path(root) / 'AndroidManifest.xml'
    t = _read(m)
    t2, n = re.subn(
        r'\s+android:permission="(?:oplus|oppo|com\.oplus\.permission|com\.oppo|com\.heytap)[^"]*"', '', t
    )
    _write(m, t2)
    return f'{n} attributes'


# Vendor-tag names the OnePlus SDK asks for that the OP15 HAL only exposes under other
# names. Infinity X resolved these in frameworks/av CameraMetadata::getTagFromName; on stock
# LineageOS we rewrite the names inside the app instead.
VENDOR_TAG_ALIASES = {
    'com.oplus.burst.capture.single': 'com.oplus.burst.capture',
    'com.oplus.full.bining.qbc.enable': 'com.oplus.quad2binning',
    'com.oplus.rear.remosaic.enable': 'com.oplus.QCFARemosaicType',
    'com.oplus.aps.sat.preview.master.pipeline': 'com.oplus.aps.sat.snapshot.master.pipeline',
    'com.oplus.control.face.dr': 'com.oplus.face.occlusion.info',
    'com.oplus.sensor.exposureTime': 'android.sensor.exposureTime',
    'com.oplus.app.filter.type': 'com.oplus.FilterType',
    'com.oplus.pdaf.converge.status': 'com.oplus.is.pdaf.done',
}


def vendor_tag_aliases(root):
    total = 0
    for p in _smali(root):
        t = _read(p)
        if 'com.oplus.' not in t:
            continue
        t2 = t
        for a, b in VENDOR_TAG_ALIASES.items():
            t2, n = re.subn(
                r'(const-string(?:/jumbo)? [vp]\d+, )"' + re.escape(a) + '"', r'\1"' + b + '"', t2
            )
            total += n
        if t2 != t:
            _write(p, t2)
    return f'{total} strings'


# ---------------------------------------------------------------- com.oplus.camera.unit.sdk.jar

SDK_STATIC_DEFAULTS = (
    '.field private static volatile eagerlyParseMessageSets:Z = false',
    '.field private static sAlgoExists:Z = false',
    '.field private static sLibraryLoaded:Z = false',
    '.field private static sThreadUxMap:Landroid/util/SparseArray; = null',
    '.field private static sbHasSetUx:Z = false',
    '.field private static bInit:Z = false',
    '.field private static sOsenseInit:Z = false',
    '.field private static sbUnderWaterVideoStatus:Z = false',
    '.field private static volatile sEnable:Z = false',
    '.field private static volatile sJNILoadFailed:Z = false',
    '.field private static volatile sLogEncryptEnable:Z = false',
    '.field private static isDebug:Z = false',
)


def sdk_runtime(root):
    n = 0
    for p in _smali(root):
        t = _read(p)
        t2 = t
        for line in SDK_STATIC_DEFAULTS:
            t2 = t2.replace(line + '\n', line.rsplit(' = ', 1)[0] + '\n')
        if t2 != t:
            _write(p, t2)
            n += 1
    p, t = _find(
        root,
        'smali*/com/oplus/ocs/camera/producer/mode/BaseMode.smali',
        '.method public isSensorModeNeedWait(II)Z',
    )
    t = _replace_method(
        t, 'public isSensorModeNeedWait(II)Z', '    .locals 1\n\n    const/4 v0, 0x0\n\n    return v0\n'
    )
    _write(p, t)
    return f'{n} static-default files, isSensorModeNeedWait -> false'


def sdk_facebeauty_path(root):
    old, new = (
        '/product/lib64/libApsFaceBeautyPreviewProductJni.so',
        '/system_ext/lib64/libApsFaceBeautyPreviewProductJni.so',
    )
    p, t = _find(root, 'smali*/**/*.smali', old)
    _write(p, t.replace(old, new))
    return str(p.name)


# ---------------------------------------------------------------- libAPSClient-cmd-jni.so

APS_STOCK = 'b6669463a2dbdc22d20d0bb1a565ef9f1cc058f5f34c627a8d49971f7c509bec'
APS_PATCHED = 'fadd66bfe6344294fa0d3055382b1506e8432d01a562849478be82973e5974f8'
APS_TARGETS = (
    (0x4C11B, b'libHeifEncoderWrapper.so', b'xibHeifEncoderWrapper.so'),
    (0x48551, b'libNativeWinBuffExchange.so', b'xibNativeWinBuffExchange.so'),
)


def apsclient_force_java_heif(path):
    """Stock keeps the APS client in /product, where namespace isolation hides the native HEIF
    helpers and the Java fallback is used. Co-locating them in /system_ext would switch to the
    untested native route, so break those two dlopen names exactly as Infinity X does."""
    b = bytearray(Path(path).read_bytes())
    if sha256(b).hexdigest() != APS_STOCK:
        raise ValueError('libAPSClient-cmd-jni.so is not the expected stock build')
    for off, old, new in APS_TARGETS:
        if bytes(b[off : off + len(old)]) != old:
            raise ValueError(f'APS dlopen target mismatch at {off:#x}')
        b[off : off + len(old)] = new
    if sha256(b).hexdigest() != APS_PATCHED:
        raise ValueError('patched APS client hash mismatch')
    Path(path).write_bytes(bytes(b))
    return 'ok'


def camera_blur_license_path(root):
    """LineageOS's odm lacks the portrait-blur license file. Read it from the module's
    /system_ext/etc/camera copy instead (both the existence check and the loader, which
    prefixes '/odm/etc/camera/'), so nothing has to be added to /odm."""
    p, t = _find(root, 'smali*/**/*.smali', '"/odm/etc/camera/singleblur/license_release.license"')
    t2 = t.replace(
        '"/odm/etc/camera/singleblur/license_release.license"',
        '"/system_ext/etc/camera/singleblur/license_release.license"',
    )
    t2, n = re.subn(
        r'(const-string [vp]\d+, )"singleblur/license_release\.license"',
        r'\1"../../../system_ext/etc/camera/singleblur/license_release.license"',
        t2,
    )
    if t2 == t or n != 1:
        raise ValueError('blur license path not patched')
    _write(p, t2)
    return p.name


def camera_defer_ufs_probe(root):
    """CaptureDeferUtils reads /proc/devinfo/ufs only to blacklist one UFS part
    (KLUFG4LHGC-B0E1) for deferred capture. LineageOS labels that proc node so apps get
    EACCES, and the unguarded read kills the app. Treat the node as absent (= not that part)."""
    p, t = _find(root, 'smali*/qc/*.smali', '"/proc/devinfo/ufs"')
    pat = re.compile(
        r'(const-string v1, "/proc/devinfo/ufs"\n.*?invoke-virtual \{v0\}, Ljava/io/File;->exists\(\)Z\n\s*\n?(?:\s*\.line \d+\n)*\s*move-result v1\n(?:\s*\.line \d+\n|\s*\n)*?\s*)if-eqz v1, (:cond_\w+)',
        re.S,
    )
    t2, n = pat.subn(lambda m: m.group(1) + 'goto ' + m.group(2), t, count=1)
    if n != 1:
        raise ValueError('ufs probe not patched')
    _write(p, t2)
    return p.name


def sdk_session_package_tag(root):
    """Infinity X's cameraserver stamps every session's parameters with the client package in the
    vendor tag com.oplus.packageName (camera.package_name soong config); the OnePlus camera layer
    reads it in configure_streams to pick the first-party pipeline, otherwise it configures the
    session as a third-party app. Stock LineageOS cameraserver doesn't, so the SDK sets the tag
    itself (byte string, NUL-terminated like String8) right before building the session params."""
    p, t = _find(
        root,
        'smali*/com/oplus/ocs/camera/producer/device/Camera2Impl.smali',
        'SessionConfiguration;->setSessionParameters',
    )
    cls = 'Lcom/oplus/ocs/camera/producer/device/Camera2Impl;'
    proxy = 'Lcom/oplus/ocs/camera/metadata/parameter/CaptureRequestBuilderProxy;'
    anchor = (
        f'    iget-object v5, v0, {cls}->mPreviewBuilder:{proxy}\n\n'
        f'    invoke-virtual {{v5}}, {proxy}->build()Landroid/hardware/camera2/CaptureRequest;'
    )
    if t.count(anchor) != 1:
        raise ValueError('session builder anchor not unique')
    t = t.replace(
        anchor,
        (
            f'    iget-object v5, v0, {cls}->mPreviewBuilder:{proxy}\n\n'
            f'    invoke-static {{v5}}, {cls}->losAddPackageTag({proxy})V\n\n'
            f'    invoke-virtual {{v5}}, {proxy}->build()Landroid/hardware/camera2/CaptureRequest;'
        ),
    )
    t += f'''
.method private static losAddPackageTag({proxy})V
    .locals 4

    :try_start_0
    new-instance v0, Landroid/hardware/camera2/CaptureRequest$Key;
    const-string v1, "com.oplus.packageName"
    const-class v2, [B
    invoke-direct {{v0, v1, v2}}, Landroid/hardware/camera2/CaptureRequest$Key;-><init>(Ljava/lang/String;Ljava/lang/Class;)V
    const-string v1, "com.oplus.camera"
    invoke-virtual {{v1}}, Ljava/lang/String;->getBytes()[B
    move-result-object v1
    array-length v2, v1
    add-int/lit8 v2, v2, 0x1
    invoke-static {{v1, v2}}, Ljava/util/Arrays;->copyOf([BI)[B
    move-result-object v1
    invoke-virtual {{p0, v0, v1}}, {proxy}->setParameter(Landroid/hardware/camera2/CaptureRequest$Key;Ljava/lang/Object;)Z
    :try_end_0
    .catch Ljava/lang/Throwable; {{:try_start_0 .. :try_end_0}} :catch_0
    :catch_0
    return-void
.end method
'''
    _write(p, t)
    return p.name


# ---------------------------------------------------------------- v0.20+ additions

SMALI_DIR = Path(__file__).parent / 'smali'


def camera_gallery_fallback(root):
    """No OnePlus gallery on LineageOS: GalleryHelper.p() returns early when it is missing. Open the
    photo in the default viewer instead, and only once its processed (deferred) image is saved,
    otherwise other galleries keep showing the quick preview JPEG. Adds LosGalleryFallback(+$Fire),
    calls it from GalleryHelper.p(), and reports saved images from CameraManager's defer-save
    handler (the method logging "onCaptureDeferPictureSaved, mbCreated")."""
    gh, t = _find(
        root,
        'smali*/com/oplus/camera/helper/GalleryHelper.smali',
        'invoke-static {v3, v2}, Lcom/oplus/camera/util/Util;->u0(Landroid/app/Activity;Ljava/lang/String;)Z',
    )
    if 'LosGalleryFallback' not in t:
        i = t.index(
            'invoke-static {v3, v2}, Lcom/oplus/camera/util/Util;->u0(Landroid/app/Activity;Ljava/lang/String;)Z'
        )
        j = t.index('return v12', i)
        if 'Lmo/r1;->a:Z' not in t[i:j] or 'return' in t[i:j]:
            raise ValueError('GalleryHelper early return not where expected')
        t = (
            t[:j]
            + (
                'iget-object v3, v8, Lcom/oplus/camera/helper/GalleryHelper;->a:Landroid/app/Activity;\n\n'
                '    invoke-static {v3, v0}, Lcom/oplus/camera/helper/LosGalleryFallback;->open(Landroid/app/Activity;Lxm/i;)V\n\n'
                '    return v12'
            )
            + t[j + len('return v12') :]
        )
        _write(gh, t)
    for f in ('LosGalleryFallback.smali', 'LosGalleryFallback$Fire.smali'):
        _write(gh.parent / f, _read(SMALI_DIR / f))
    cm, t = _find(
        root,
        'smali*/com/oplus/camera/CameraManager.smali',
        'Ll6/i8;-><init>(Lcom/oplus/camera/CameraManager;Landroid/net/Uri;',
    )
    if 'LosGalleryFallback;->onFinalSaved' not in t:
        anchor = (
            '    invoke-direct/range {v1 .. v7}, Ll6/i8;-><init>(Lcom/oplus/camera/CameraManager;Landroid/net/Uri;'
            'Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Z)V\n'
        )
        if t.count(anchor) != 1 or 'move-object v3, v0' not in t[t.index(anchor) - 400 : t.index(anchor)]:
            raise ValueError('defer-save anchor changed (uri must be in v0)')
        i = t.index(anchor) + len(anchor)
        k = t.index('\n', t.index('Lm8/c;->C(Ljava/lang/String;Ljava/util/function/Supplier;)V', i)) + 1
        t = (
            t[:k]
            + '\n    invoke-static {v0}, Lcom/oplus/camera/helper/LosGalleryFallback;->onFinalSaved(Landroid/net/Uri;)V\n'
            + t[k:]
        )
        _write(cm, t)
    return gh.name


OEM_ONLY_COMPONENTS = [
    # HeyTap accessory framework (OPPO wearables), never present on LineageOS
    'com.heytap.accessory.platform.RegisterUponInstallReceiver',
    'com.heytap.accessory.platform.ServiceConnectionIndicationReceiver',
    'com.heytap.accessory.stream.StreamConnReceiver',
    # OPPO SAU tuning-parameter downloads and backup/restore plugin
    'com.oplus.camera.upgrade.tunning.TuningParameterUpgradeReceiver',
    'com.oplus.camera.upgrade.tunning.TuningParameterUpgradeService',
    'com.oplus.camera.migration.CameraBRPluginService',
    # engineer-mode broadcast hook (exported)
    'com.oplus.camera.debug.DebugBroadcastReceiver',
    # exported services for OnePlus Gallery / OnePlus multi-device remote control (absent on LineageOS)
    'com.oplus.camera.feature.aiMasterWatermark.GalleryConnectionService',
    'com.oplus.camera.remote.RemoteService',
]


def camera_disable_oem_components(root):
    """Disable exported receivers/services that only answer OnePlus/HeyTap system broadcasts."""
    p = Path(root) / 'AndroidManifest.xml'
    t = _read(p)
    for n in OEM_ONLY_COMPONENTS:
        m = re.search(r'<(receiver|service)([^>]*?)android:name="' + re.escape(n) + '"', t)
        if not m:
            raise ValueError('component missing: ' + n)
        tag = m.group(0)
        if 'android:enabled="false"' in tag:
            continue
        new = tag.replace('android:enabled="true" ', '').replace(
            '<' + m.group(1), '<' + m.group(1) + ' android:enabled="false"', 1
        )
        t = t.replace(tag, new, 1)
    _write(p, t)
    return p.name


# Components the OnePlus camera only uses from its own processes, or that only OxygenOS system
# apps call. strip_oem_component_permissions removes their OnePlus-only permission guards (the
# permissions don't exist on LineageOS); without a guard any app could reach them, so they are
# made private to the camera instead. The camera's own processes share its UID and keep access.
INTERNAL_COMPONENTS = [
    'com.oplus.epona.internal.EponaProvider',  # OPPO's inter-app call bridge
    'com.oplus.camera.component.CameraInfoProvider',
    'com.oplus.camera.setting.AiCameraVisibleProvider',
    'com.oplus.camera.feature.aicloudhd.provider.AiCloudHdProvider',
    'com.oplus.camera.feature.basic.fluid.FluidCardWidgetProvider',
    'com.oplus.camera.feature.keymagic.KeyMagicService',
    'com.oplus.camera.bluetooth.BlueToothScanService',
]


def restrict_exported_components(root):
    """Make the components in INTERNAL_COMPONENTS android:exported="false"."""
    p = Path(root) / 'AndroidManifest.xml'
    t = _read(p)
    for n in INTERNAL_COMPONENTS:
        m = re.search(
            r'<(?:activity|provider|receiver|service)\b[^>]*?android:name="' + re.escape(n) + r'"[^>]*>', t
        )
        if not m:
            raise ValueError('component missing: ' + n)
        tag = m.group(0)
        if 'android:exported="false"' in tag:
            continue
        if 'android:exported="true"' not in tag:
            raise ValueError('component not exported as expected: ' + n)
        t = (
            t[: m.start()]
            + tag.replace('android:exported="true"', 'android:exported="false"', 1)
            + t[m.end() :]
        )
    _write(p, t)
    return f'{len(INTERNAL_COMPONENTS)} components'


# Install-time patches of ROM blobs (offlinecamera-service-impl, libAlgoProcess) live in
# module/customize.sh (fixlib) so they always apply to the exact file on the user's ROM.


def camera_drop_embedded_libs(root):
    """The module installs the app as a preinstalled system app, which loads native code from
    priv-app/OplusCamera/lib/arm64 (shipped next to the APK). The copies inside the APK (lib/) are
    never used; dropping them saves ~46 MB. Keep lib/arm64 in the module in sync with the APK's libs."""
    d = Path(root) / 'lib'
    if d.exists():
        shutil.rmtree(d)
    return 'lib/'


# ---------------------------------------------------------------- props scoped to the camera (v0.32)

SMALI_STUBS_DIR = Path(__file__).parent / 'smali-stubs'
_SP_METHODS = [
    'get(Ljava/lang/String;)Ljava/lang/String;',
    'get(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;',
    'getInt(Ljava/lang/String;I)I',
    'getLong(Ljava/lang/String;J)J',
    'getBoolean(Ljava/lang/String;Z)Z',
]


def stubs_scoped_props(root):
    """oplus-camera-stubs.jar: route every android.os.SystemProperties read (get/getInt/getLong/
    getBoolean) through com.oplus.camera.los.LosProps, which answers the OnePlus camera's own keys
    (tools/gen_losprops.py) and passes every other key through. The props therefore no longer
    have to be set system-wide in system.prop."""
    root = Path(root)
    dst = root / 'smali/com/oplus/camera/los'
    dst.mkdir(parents=True, exist_ok=True)
    _write(dst / 'LosProps.smali', _read(SMALI_STUBS_DIR / 'LosProps.smali'))
    n = 0
    for f in _smali(root):
        if f.name == 'LosProps.smali':
            continue
        t = _read(f)
        u = t
        for m in _SP_METHODS:
            u = u.replace('Landroid/os/SystemProperties;->' + m, 'Lcom/oplus/camera/los/LosProps;->' + m)
        if u != t:
            n += 1
            _write(f, u)
    if not n:
        raise ValueError('no SystemProperties reads found in the stubs jar')
    return f'{n} classes'


def camera_scoped_props(root):
    """App: two helpers read persist.sys.oplus.anim_level by reflection on
    android.os.SystemProperties.get(String); point them at LosProps (the app's other reads already
    go through com.oplus.wrapper.os.SystemProperties in the stubs jar)."""
    done = 0
    for f in _smali(root):
        t = _read(f)
        if '"persist.sys.oplus.anim_level"' not in t and 'Ld3/a;' not in t:
            continue
        if f.as_posix().endswith(('/s3/i.smali', '/d3/a.smali')) and '"android.os.SystemProperties"' in t:
            t = t.replace(
                'const-string v1, "android.os.SystemProperties"',
                'const-string v1, "com.oplus.camera.los.LosProps"',
            )
            _write(f, t)
            done += 1
    if done != 2:
        raise ValueError(f'expected 2 reflective SystemProperties reads, patched {done}')
    return 's3/i, d3/a'
