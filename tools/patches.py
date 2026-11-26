"""Smali / manifest / binary patches for the OnePlus camera on LineageOS 24.

Ported from OP15InfinityX/android_device_oneplus_infiniti-camera (OxygenOS 16 era,
commit c137d20), retargeted to OxygenOS 16.0.10.601 and, since v0.39, to the ColorOS 11.C.80
camera (CPH2745_17.0.1.201(EX01), app 7.006.295) whose blobs LineageOS ships.
Every patch locates its target by a content anchor and fails loudly if the anchor
is missing, so a different camera build can never be patched silently.
"""

import re
import shutil
from hashlib import sha256
from pathlib import Path


def _read(path):
    # surrogateescape round-trips any byte apktool writes, so a file is never changed by accident
    with open(path, encoding='utf-8', errors='surrogateescape', newline='') as f:
        return f.read()


def _write(path, text):
    # newline='': no CRLF translation on Windows, bytes stay exactly as apktool wrote them
    with open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='') as f:
        f.write(text)


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
    # (ColorOS builds the path from ModelStorage.getAlgoModelPartitionRoot() + this suffix)
    p, t = _find(root, 'smali*/**/*.smali', '/etc/camera/singleblur/personseg.bin"')
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
    if not n:
        raise ValueError('no OEM permission attributes found in the manifest')
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
    """Face-beauty preview JNI: the SDK (and the adapter's copy of the class) look for it in
    ApsUtils.getCameraAppLibDirectory(), which falls back to /product/lib64 without the camera
    APEX; the module ships it in /system_ext/lib64."""
    p, t = _find(
        root, 'smali*/**/ApsUtils.smali', '.method public static getCameraAppLibDirectory()Ljava/lang/String;'
    )
    m = re.search(
        r'\.method public static getCameraAppLibDirectory\(\)Ljava/lang/String;\n(.*?)\.end method', t, re.S
    )
    old = 'const-string v0, "/product/lib64"'
    if not m or m.group(1).count(old) != 1 or '"/apex/com.oplus.camera.app/lib64"' not in m.group(1):
        raise ValueError('ApsUtils.getCameraAppLibDirectory not as expected')
    body = m.group(1).replace(old, 'const-string v0, "/system_ext/lib64"')
    _write(p, t[: m.start(1)] + body + t[m.end(1) :])
    return str(p.name)


# ---------------------------------------------------------------- libAPSClient-cmd-jni.so

APS_STOCK = '559cd5e9fc533cbce3cc3390cecad74127167daaf3e964e0cec424fcbc3eff9c'
APS_PATCHED = '035e700948d392be9471ea91afcbb0082863f5c53394480086f004265b7f6d5f'
APS_TARGETS = (
    (0x4F418, b'libHeifEncoderWrapper.so', b'xibHeifEncoderWrapper.so'),
    (0x4BE60, b'libNativeWinBuffExchange.so', b'xibNativeWinBuffExchange.so'),
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
    p, t = _find(root, 'smali*/**/*.smali', '"/proc/devinfo/ufs"')
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


# GalleryHelper's open-in-gallery method: it asks Util whether the OnePlus gallery (Util.H()) is
# installed and returns false when it isn't (unless a debug flag in Util r1 is set). The item
# (uri b, mime c, capture time f) is the method's second parameter, moved into v0.
GALLERY_CHECK = re.compile(
    r'invoke-static \{v3, v2\}, Lcom/oplus/camera/util/Util;->\w+\(Landroid/app/Activity;Ljava/lang/String;\)Z\n'
)
DEFER_SAVED_LOG = re.compile(
    r'    invoke-direct/range \{v1 \.\. v7\}, (L[\w/$]+;)-><init>\(Lcom/oplus/camera/CameraManager;Landroid/net/Uri;'
    r'Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Z\)V\n'
)


def camera_gallery_fallback(root):
    """No OnePlus gallery on LineageOS: GalleryHelper's open method returns early when it is
    missing. Open the photo in the default viewer instead, and only once its processed (deferred)
    image is saved, otherwise other galleries keep showing the quick preview JPEG. Adds
    LosGalleryFallback(+$Fire), calls it from that early return, and reports saved images from
    CameraManager's defer-save handler (the one logging "onCaptureDeferPictureSaved, mbCreated")."""
    gh = next(Path(root).glob('smali*/com/oplus/camera/helper/GalleryHelper.smali'), None)
    if gh is None:
        raise ValueError('GalleryHelper not found')
    t = _read(gh)
    hits = [m for m in GALLERY_CHECK.finditer(t)]
    if len(hits) != 1:
        raise ValueError(f'gallery-installed check: {len(hits)} candidates')
    i = hits[0].start()
    head = t[t.rindex('\n.method ', 0, i) : i]
    sig = re.match(r'\n\.method public final \w+\(L[\w/$]+;(L[\w/$]+;)Z\)Z\n', head)
    if not sig or 'move-object/from16 v0, p2\n' not in head or 'move-object/from16 v8, p0\n' not in head:
        raise ValueError('GalleryHelper open method changed (item must be p2 -> v0, this in v8)')
    item = sig.group(1)
    m = re.compile(r'\n\s*return (v\d+)\n').search(t, i)
    if 'Lcom/oplus/camera/util/r1;->a:Z' not in t[i : m.start()]:
        raise ValueError('GalleryHelper early return not where expected')
    if 'LosGalleryFallback' not in t:
        t = (
            t[: m.start()]
            + '\n\n    iget-object v3, v8, Lcom/oplus/camera/helper/GalleryHelper;->a:Landroid/app/Activity;\n\n'
            + f'    invoke-static {{v3, v0}}, Lcom/oplus/camera/helper/LosGalleryFallback;->open(Landroid/app/Activity;{item})V\n'
            + t[m.start() :]
        )
        _write(gh, t)
    for f in ('LosGalleryFallback.smali', 'LosGalleryFallback$Fire.smali'):
        _write(gh.parent / f, _read(SMALI_DIR / f).replace('Lxm/i;', item))
    cm = next(Path(root).glob('smali*/com/oplus/camera/CameraManager.smali'), None)
    t = _read(cm)
    hits = [m for m in DEFER_SAVED_LOG.finditer(t)]
    if len(hits) != 1:
        raise ValueError(f'defer-save log supplier: {len(hits)} candidates')
    m = hits[0]
    sup = next(Path(root).glob('smali*/' + m.group(1)[1:-1] + '.smali'))
    if '"onCaptureDeferPictureSaved, mbCreated: "' not in _read(sup):
        raise ValueError('defer-save log supplier changed')
    if 'move-object v3, v0\n' not in t[m.start() - 400 : m.start()]:
        raise ValueError('defer-save anchor changed (uri must be in v0)')
    if 'LosGalleryFallback;->onFinalSaved' not in t:
        log = re.compile(
            r'invoke-static \{v\d+, v\d+\}, L[\w/$]+;->\w+\(Ljava/lang/String;Ljava/util/function/Supplier;\)V\n'
        )
        n = log.search(t, m.end())
        if not n or re.sub(r'\.line \d+', '', t[m.end() : n.start()]).strip():
            raise ValueError('defer-save log call not right after the supplier')
        t = (
            t[: n.end()]
            + '\n    invoke-static {v0}, Lcom/oplus/camera/helper/LosGalleryFallback;->onFinalSaved(Landroid/net/Uri;)V\n'
            + t[n.end() :]
        )
        _write(cm, t)
    return f'{gh.name} (item {item})'


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


# Components the OnePlus camera only uses from its own processes, or that only ColorOS system
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


# Settings that do nothing (or fail) on LineageOS, hidden the way the app hides its own unused
# items (oplusos:isPreferenceVisible="false"). The preferences still exist, so every code path that
# looks them up keeps working; no code makes them visible again.
DEAD_SETTINGS = {
    # Quick launch writes Settings.Secure "com.oplus.camera quick launch", which only ColorOS's
    # system services read. LineageOS: Settings > System > Gestures > double-press power.
    'camera_setting_preferences.xml': [
        'pref_camera_quick_launch_key',
        'pref_camera_quick_launch_V2_setting_key',
    ],
    'camera_setting_sub_preferences.xml': [
        # opens ColorOS's bootreg statement page; returns without doing anything when it's absent
        'pref_privacy_setting_privacy_policy',
        # starts com.oplus.action.user.agreement.page in the camera's own package, which has no
        # activity for it (unguarded startActivity: ActivityNotFoundException)
        'pref_privacy_setting_user_agreement',
    ],
}


def camera_hide_dead_settings(root):
    """Hide the settings in DEAD_SETTINGS."""
    n = 0
    for name, keys in DEAD_SETTINGS.items():
        p = Path(root) / 'res/xml' / name
        t = _read(p)
        if 'xmlns:oplusos="http://schemas.android.com/apk/res-auto"' not in t:
            raise ValueError(f'{name}: oplusos namespace missing')
        for k in keys:
            m = re.search(r'<[\w.]+ [^>]*android:key="' + re.escape(k) + r'"[^>]*?(/?)>', t)
            if not m:
                raise ValueError(f'{name}: {k} missing')
            tag = m.group(0)
            if 'isPreferenceVisible' in tag:
                raise ValueError(f'{name}: {k} already has a visibility')
            end = len(tag) - (2 if tag.endswith('/>') else 1)
            new = tag[:end].rstrip() + ' oplusos:isPreferenceVisible="false" ' + tag[end:]
            t = t[: m.start()] + new + t[m.end() :]
            n += 1
        _write(p, t)
    return f'{n} settings'


def camera_no_telemetry(root):
    """Turn off OPPO's usage statistics (OplusTrack). The camera tracks shutter presses, zoom,
    menu taps, filters and more, builds each event on its report thread and hands it to
    ColorOS's statistics provider (content://com.oplus.statistics.provider/track_event), which
    LineageOS doesn't have: every event failed after a provider lookup. OplusTrack also adds a
    crash-report handler in front of Android's. Three cuts, each one an exit the code already has:
      1. DcsReporter.init always takes its existing test-mode exit (after storing the app context,
         which other code reads): no OplusTrack session, activity tracking or crash handler.
         DcsReporter.onResume/onPause take the same exit: OplusTrack's page tracking throws
         without a session.
      2. BaseEvent.report returns false (not sent) right away, as it does when the report thread
         is missing: events are no longer assembled or queued.
      3. OplusTrack.onCommon's sender returns false (its failure result) for the callers that
         bypass BaseEvent (Super Text and a synthetic class)."""
    done = []
    # 1. DcsReporter.init: "if-nez p1, :cond_N" after TestUtil.f() -> "goto :cond_N"
    p, t = _find(
        root,
        'smali*/com/oplus/camera/statistics/events/DcsReporter.smali',
        '.method public init(Landroid/content/Context;)V',
    )
    pat = re.compile(
        r'(\.method public init\(Landroid/content/Context;\)V\n.*?'
        r'iput-object p1, p0, Lcom/oplus/camera/statistics/events/DcsReporter;->mAppContext:Landroid/content/Context;\n'
        r'(?:\s*\.line \d+\n|\s*\n)*\s*invoke-static \{\}, Lcom/oplus/camera/common/utils/TestUtil;->\w+\(\)Z\n'
        r'(?:\s*\.line \d+\n|\s*\n)*\s*move-result p1\n(?:\s*\.line \d+\n|\s*\n)*\s*)'
        r'if-nez p1, (:cond_\w+)',
        re.S,
    )
    t, n = pat.subn(lambda m: m.group(1) + 'goto ' + m.group(2), t, count=1)
    if n != 1:
        raise ValueError('DcsReporter.init test-mode exit not found')
    # 1b. DcsReporter.onResume/onPause: the same exit (TestUtil check -> "goto :cond_N"), or they
    #     call OplusTrack.onResume/onPause, whose page tracking throws "call OplusTrack.init for
    #     appId[20009] first." on its own thread and kills the app
    for name in ('onResume', 'onPause'):
        pat = re.compile(
            rf'(\.method public {name}\(\)V\n(?:\s*\.locals \d+\n|\s*\.line \d+\n|\s*\n)*'
            r'\s*invoke-static \{\}, Lcom/oplus/camera/common/utils/TestUtil;->\w+\(\)Z\n'
            r'(?:\s*\.line \d+\n|\s*\n)*\s*move-result v0\n(?:\s*\.line \d+\n|\s*\n)*\s*)'
            r'if-nez v0, (:cond_\w+)'
        )
        t, n = pat.subn(lambda m: m.group(1) + 'goto ' + m.group(2), t, count=1)
        if n != 1:
            raise ValueError(f'DcsReporter.{name} test-mode exit not found')
    _write(p, t)
    done.append(p.name)
    # 2. BaseEvent.report(Map): return false, signature annotation kept
    p, t = _find(
        root,
        'smali*/com/oplus/camera/statistics/events/BaseEvent.smali',
        '.method public report(Ljava/util/Map;)Z',
    )
    m = re.search(r'\.method public report\(Ljava/util/Map;\)Z\n(.*?)\.end method', t, re.S)
    ann = re.search(
        r'    \.annotation system Ldalvik/annotation/Signature;\n.*?    \.end annotation\n', m.group(1), re.S
    )
    if not m or not ann or 'ReportThread;->getDataReportHandler' not in m.group(1):
        raise ValueError('BaseEvent.report not as expected')
    body = '    .locals 1\n' + ann.group(0) + '\n    const/4 v0, 0x0\n\n    return v0\n'
    t = t[: m.start(1)] + body + t[m.end(1) :]
    _write(p, t)
    done.append(p.name)
    # 3. OplusTrack sender: the static (bean[, flags])Z method logging "onCommon logTag is ",
    #    itself (OxygenOS, obfuscated) or through its log lambda lambda$<name>$N (ColorOS)
    hits = []
    for p in _smali(root):
        t = _read(p)
        if '.source "OplusTrack.java"' not in t or '"onCommon logTag is ' not in t:
            continue
        logged = set()
        for m in re.finditer(
            r'\.method private static synthetic lambda\$(\w+)\$\d+\(([^)]*)\)Ljava/lang/String;\n(.*?)\.end method',
            t,
            re.S,
        ):
            if '"onCommon logTag is ' in m.group(3):
                logged.add((m.group(1), m.group(2)))
        for m in re.finditer(r'\.method public static (\w+)\((L[\w/$]+;I?)\)Z\n(.*?)\.end method', t, re.S):
            if '"onCommon logTag is ' in m.group(3) or (m.group(1), m.group(2)) in logged:
                hits.append((p, t, m))
    if len(hits) != 1:
        raise ValueError(f'OplusTrack sender: {len(hits)} candidates')
    p, t, m = hits[0]
    t = t[: m.start(3)] + '    .locals 1\n\n    const/4 v0, 0x0\n\n    return v0\n' + t[m.end(3) :]
    _write(p, t)
    done.append(p.name)
    return ', '.join(done)


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


def stubs_framework_classes(root):
    """oplus-camera-stubs.jar: add the OnePlus framework classes the ColorOS camera calls outside
    any try/catch that neither LineageOS (oplus-fwk) nor the jar has, as "feature absent" no-ops
    (tools/smali-stubs/fwk): OplusHansFreezeManager.getInstance() on a camera thread, and COUI's
    OplusMaterialUtil effects. Without them the call throws NoClassDefFoundError."""
    src = SMALI_STUBS_DIR / 'fwk'
    added = []
    for f in sorted(src.rglob('*.smali')):
        rel = f.relative_to(src)
        dst = Path(root) / 'smali' / rel
        if dst.exists():
            raise ValueError(f'{rel.with_suffix("")} is in the stubs jar now: drop its shim')
        dst.parent.mkdir(parents=True, exist_ok=True)
        _write(dst, _read(f))
        added.append(f.stem)
    if not added:
        raise ValueError('no framework shims found')
    return ', '.join(added)


_SURFACE_EXT_NATIVE = '.method public native nativeSetMaxDequeuedBufferCount(JI)V\n.end method\n'
_SURFACE_EXT_FIXED = (
    '.method private native nativeSetMaxDequeuedBufferCount(JI)I\n'
    '.end method\n'
    '\n'
    '.method public nativeSetMaxDequeuedBufferCount(JI)V\n'
    '    .registers 4\n'
    '\n'
    '    invoke-direct {p0, p1, p2, p3}, Landroid/view/SurfaceExtImpl;->nativeSetMaxDequeuedBufferCount(JI)I\n'
    '\n'
    '    return-void\n'
    '.end method\n'
)


def stubs_surfaceext_jni(root):
    """oplus-camera-stubs.jar: ColorOS's liboplusgui_jni.so registers
    SurfaceExtImpl.nativeSetMaxDequeuedBufferCount as (JI)I, the jar declares it (JI)V. JNI_OnLoad
    then fails with NoSuchMethodError and aborts the camera as soon as COUI loads the class. Declare
    the native with the library's signature and keep the (JI)V method ISurfaceExt calls as a
    wrapper that drops the result."""
    p = Path(root) / 'smali/android/view/SurfaceExtImpl.smali'
    t = _read(p)
    if t.count(_SURFACE_EXT_NATIVE) != 1:
        raise ValueError('SurfaceExtImpl: (JI)V native declaration not found')
    _write(p, t.replace(_SURFACE_EXT_NATIVE, _SURFACE_EXT_FIXED))
    return 'nativeSetMaxDequeuedBufferCount(JI)I'


def camera_scoped_props(root):
    """App: the UI helpers (COUI and others) read persist.sys.oplus.anim_level by reflection on
    android.os.SystemProperties.get(String); point them at LosProps, which answers its own keys
    and passes any other key through (the app's other reads already go through
    com.oplus.wrapper.os.SystemProperties in the stubs jar). Every file that names the property
    must read it one of the two ways, or the build stops."""
    done, missed = [], []
    for f in _smali(root):
        t = _read(f)
        if '"persist.sys.oplus.anim_level"' not in t:
            continue
        t, n = REFLECTIVE_SP.subn(r'\1"com.oplus.camera.los.LosProps"\3', t)
        if n:
            _write(f, t)
            done.append(f'{f.parent.name}/{f.stem}')
        elif 'Lcom/oplus/wrapper/os/SystemProperties;->' not in t:
            missed.append(f.name)
    if missed or not done:
        raise ValueError(f'anim_level reads not redirected: {missed or "none found"}')
    return ', '.join(sorted(done))


# const-string vN, "android.os.SystemProperties" ... Class.forName(vN)
REFLECTIVE_SP = re.compile(
    r'(const-string (v\d+), )"android\.os\.SystemProperties"(\n(?:\s*\.line \d+\n|\s*\n)*'
    r'\s*invoke-static \{\2\}, Ljava/lang/Class;->forName\(Ljava/lang/String;\)Ljava/lang/Class;\n)'
)
