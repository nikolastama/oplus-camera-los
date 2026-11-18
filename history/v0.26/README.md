# OnePlus Camera for LineageOS 24 (infiniti) — maintainer notes

Source: OxygenOS CPH2745_16.0.10.601 EX01 (OnePlus 15). Target: official LineageOS 24 (infiniti).

## Layout (nothing under /vendor is overlaid)
| Path | What | Why there |
|---|---|---|
| system_ext/priv-app/OplusCamera | patched, re-signed app | new package |
| system_ext/lib64, framework, etc | OnePlus SDK libs/jars/permissions | all new files (customize.sh refuses to shadow any ROM file) |
| odm/lib64/hw/camera.oemlayer.v2.so | wrapper (oemwrap.c, SONAME camera.oemlayer.wrap.so) | LineageOS sets ro.hardware.camera=oemlayer.v2 but ships no layer. libhardware checks /odm/lib64/hw first. The wrapper adds com.oplus.packageName for OnePlus op modes (≥0x8000) and forwards to the real layer |
| odm/lib64/camera.oemlayer.v2.so | real OnePlus layer, zoom patch | vendor linker searches /odm/lib64 before /vendor/lib64 |
| odm/lib64/camera.oemlayer.uilaye2.so, libsensorbridg2.so | layer deps missing on LineageOS | |
| odm/lib64/libOplusSecurity.so | SDK config decoder (same_process_hal_file) | libAlgoProcess dlopens it from /odm |
| odm/lib64/<install-time copies> | see "ROM blob fixes" | shadow the ROM file by search order, never overlay it |

customize.sh gives every merged directory the ROM's own SELinux label. /odm/lib64/hw MUST stay
vendor_hal_file. With vendor_file, zygote/apps can't read it, so every app's GPU driver loader breaks
(this is what broke browsers and other camera apps).

meta-overlayfs mounts its own copy of module files. Some versions only add files to that copy on update,
so files an older version shipped stay mounted. customize.sh and post-fs-data.sh therefore
`prune_mirror` our copy down to what the module currently ships. v0.4–v0.24 left a stale /vendor/lib64/hw
overlay there, which denied zygote and broke OpenGL ES 3 in every app.

## Patches to recheck when LineageOS moves to new ColorOS/OxygenOS blobs
All native patches are matched by byte pattern and fail safe: if the pattern is missing, the fix
is skipped and the install says so.

1. **offlinecamera-service-impl** (install time, customize.sh `fixlib`): `ldr w27,[x24,#0x1c]` → `#0x2c`.
   Snapalloc on LineageOS keeps flags at handle+0x1c and the width at +0x2c (OxygenOS gralloc has
   the width at +0x1c). Without the fix, metadata is truncated to 512 bytes and photos come out black.
   Pattern `981a40f9e2031faa1b1f40b9000f40b9`, expected offset 111500.
   Recheck: if snapalloc's handle layout or this library changes, re-derive from
   `ExtractMetaDataFromBuffer`.
2. **libAlgoProcess** (install time): P010_VENUS chroma plane is computed from luma
   (scanline = align(height, 32), chroma stride = luma stride) instead of reading
   AHardwareBuffer_lockPlanes plane 1, which stock Android doesn't fill for QTI formats.
   Without the fix, turbo HDR / IPE crash. Pattern in customize.sh, expected offset 1875764.
3. **camera.oemlayer.v2.so** (prebuilt, `tools/py/patches.py: oemlayer_follow_app_zoom`):
   ZoomDivisionV2 config flag forced to 0, so viewfinder zoom follows ANDROID_CONTROL_ZOOM_RATIO.
   Pattern `099141f9291d41b909f500b91ff900b9` → `099141f9e9031f2a09f500b91ff900b9`.
4. **App smali** (`tools/py/patches.py`, each one asserts its anchor):
   - `camera_gallery_fallback`: no OnePlus gallery. The thumbnail opens ACTION_VIEW, but only once the
     deferred (multi-frame) image is saved. Adds `LosGalleryFallback` and hooks GalleryHelper.p and
     CameraManager's defer-save handler.
   - `camera_disable_oem_components`: HeyTap accessory receivers, SAU tuning download,
     backup/restore plugin, debug receiver.
   - Plus the earlier set: font, blur seg-init guard, uifirst, component permissions, vendor tag aliases,
     SDK runtime/facebeauty/license paths, java HEIF, UFS probe, session package tag.
   - Rebuild: `apktool b`, then sign with the module key (`oplus-camera-module.jks`, alias
     opluscam). Keeping the same key lets the app update in place.

## Properties (system.prop)
- `ro.oplus.camera.defercap.support=1` is mandatory: the app throws if it's missing.
- `ro.vendor.camera.res.fmq.size=8388608`: results are 0.5–1.2 MB. With the default 1 MB FMQ, large
  results fall back to binder (~1 MB cap) and corrupt metadata. Setting it to 1 forces every
  result through binder, which overflows (-28) and stalls apps. Cameraserver also sizes each app's
  result queue from this value.

## Known harmless log noise (no fix possible from a module)
ToF sysfs (/sys/kernel/tof_control) missing, color sensor NCS handle NULL, ORMS/perf paths,
ASD vdlib init_mask 0, gyro/OIS absent in SAT reprocess, DynamicMarginInfo vendor tag.

## Removal
uninstall.sh deletes app data, dex, directories the module created (.created), restores relabelled
directories (.relabeled), and removes persist props and settings added since install (.snapshot).
Your photos are kept.
