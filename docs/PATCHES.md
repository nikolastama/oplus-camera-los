# Patches

The exact change each patch makes is saved in `diffs/`. How to leave any of them out: [REVERTING.md](REVERTING.md).

Every patch locates its target by content (a smali anchor, the exact original bytes, or a file hash) and fails loudly if it isn't there. A different firmware build therefore stops the build at the first patch that no longer fits, and never produces a silently broken module.

## Camera app (`OplusCamera.apk`), `tools/patches.py`

Applied in this order by `build_module.py` to an apktool decode of the stock APK. Applied to the stock ColorOS 11.C.80 APK (7.006.295), they reproduce the shipped app with zero differences.

| Function | Why |
|---|---|
| `camera_font` | `TypeFaceUtil` reads OnePlus font-framework state that doesn't exist on LineageOS → use `Typeface.DEFAULT`. |
| `camera_blur_seginit_guard` | Portrait blur dereferences `segInit()`'s result without a null check → treat null as "no blur" instead of crashing. |
| `camera_uifirst` | LineageOS's `OplusUIFirstManager` lacks `setUxThreadValue(IILString;)V` → calls become `nop`. |
| `strip_oem_component_permissions` | Components guarded by undefined OEM permissions would lock the launcher out → remove those attributes. |
| `vendor_tag_aliases` | The app asks for vendor tags the OP15 HAL exposes under other names (Infinity X aliased them in `frameworks/av`) → rename them in the app. |
| `camera_defer_ufs_probe` | Deferred capture reads `/proc/devinfo/ufs` (EACCES on LineageOS → crash) to blacklist one UFS part → treat it as absent. |
| `camera_gallery_fallback` | No OnePlus Gallery → the thumbnail opens `ACTION_VIEW`, but waits (≤ 8 s) for the final deferred image so the gallery doesn't cache the quick JPEG. Adds `tools/smali/LosGalleryFallback*.smali` and hooks the gallery check in `GalleryHelper` and the defer-save handler in `CameraManager`, both found by code shape (the item class is taken from the hooked method's signature). |
| `camera_disable_oem_components` | Disables receivers and services that only answer OnePlus system broadcasts or OnePlus apps: HeyTap accessory, SAU tuning download, backup plugin, debug receiver, Gallery connection and multi-device remote services. All exported; nothing in the app calls them. |
| `camera_hide_dead_settings` | Hides four settings that do nothing on LineageOS (`DEAD_SETTINGS`), the way the app hides its own unused items (`oplusos:isPreferenceVisible="false"`): Quick launch and its sub-page (write a setting only ColorOS's system services read), the privacy policy link (ColorOS's statement page) and the user agreement (starts an action no activity handles). The preferences still exist, so code that looks them up is unaffected. |
| `camera_no_telemetry` | Turns off OPPO's usage statistics (OplusTrack): `DcsReporter.init` always takes its existing test-mode exit (no session, activity tracking or crash-report handler), and so do `DcsReporter.onResume`/`onPause` (OplusTrack's page tracking throws without a session and killed the app), `BaseEvent.report` returns "not sent" before building the event, and OplusTrack's sender (`onCommon(CommonBean, int)`, found through its log lambda) returns its failure result for the callers that bypass `BaseEvent`. The events (shutter, zoom, menu taps, filters…) went to ColorOS's statistics provider, which LineageOS doesn't have. |
| `restrict_exported_components` | The components `strip_oem_component_permissions` leaves open and the camera only uses itself (`EponaProvider`, four more providers, two services; `INTERNAL_COMPONENTS`) become `android:exported="false"`, so other apps can't reach them. The camera's own processes keep access. |
| `camera_scoped_props` | Three COUI helpers read `persist.sys.oplus.anim_level` by reflection on `android.os.SystemProperties` → `LosProps` (props stay in-process). Every file that names the property must read it this way or through `com.oplus.wrapper.os.SystemProperties`, or the build stops. |
| `camera_drop_embedded_libs` | The app runs as a preinstalled system app and loads native code from `priv-app/OplusCamera/lib/arm64` → drop the unused copies inside the APK (−46 MB). |

## Camera SDK (`com.oplus.camera.unit.sdk.jar` / `.adapter.jar`)

| Function | Why |
|---|---|
| `sdk_runtime` | Carried over from the Infinity X port: drops the explicit `= false` / `= null` defaults of a set of static fields (the runtime default is the same), and makes `BaseMode.isSensorModeNeedWait` return false so mode switches don't wait for a sensor-mode signal. |
| `sdk_facebeauty_path` | The face-beauty JNI path comes from `ApsUtils.getCameraAppLibDirectory()`, which falls back to `/product/lib64` without the camera APEX → `/system_ext/lib64`, where the module ships it (SDK and adapter). |
| `sdk_session_package_tag` | Sets `com.oplus.packageName` on the session (see ARCHITECTURE.md). |
| `vendor_tag_aliases` | Same tag aliases as the app (SDK and adapter). |

## Native libraries

### `libAPSClient-cmd-jni.so`: `apsclient_force_java_heif`
On ColorOS the processing client sits in `/product`, where namespace isolation hides the native HEIF helpers, so the Java fallback runs. Co-located in `/system_ext` it would switch to the untested native route. Two dlopen names are broken exactly as Infinity X does. Verified by sha256 before and after.

### Wrapper: `prebuilt/camera.oemlayer.wrap.so`
Our own code (`tools/oemwrap/oemwrap.c`). It exposes a copy of the real layer's HAL module with `open` replaced, and redirects each device's `configure_streams` for OnePlus operation modes: it adds the session package tag, sets the picture-metadata stream's use case, and caps video-encoder streams at 40 buffers. It also moves other apps' sessions to Qualcomm's HAL and keeps frame timestamps increasing in OnePlus sessions (ARCHITECTURE.md, Isolation and Out-of-order frames). The tagged session parameters are a per-device copy, freed on that device's next configure or close, and the HAL callback registration shared by all devices changes under a lock. `tools/oemwrap/build.sh` rebuilds it with clang + lld; no NDK needed. With clang/lld 18.1.3 the result matches the committed file byte for byte (`tests/test_build.py`).

## The camera app's own files: `tools/app_blobs.py`

`tools/app_blobs.txt` lists the 791 files on `/odm` (88 libraries in `odm/lib64`, 703 models, LUTs, licenses and configs in `odm/etc/camera`) that only the OnePlus camera uses and LineageOS no longer ships (LineageOS/android_device_oneplus_infiniti `ce5065b`). The build copies them from the ColorOS firmware dump, applies the fixups below, and packs them into the read-only erofs image `blobs.img` with each file's label from the odm image (mounted at boot, ARCHITECTURE.md):

| File(s) | Fixup |
|---|---|
| `libAlgoProcess`, `libEISLive`, `libFaceBeautyJni`, `libFaceDistortionCorrection`, `libOPAlgoCamAiBeautyFaceRetouchCn`, `libOPAlgoCamAiUnifySkin`, `libOPAlgoCamFaceBeautyCap`, `libaiboost_te` | `AHardwareBuffer_*` imports made unversioned (as LineageOS's `clear_symbol_version` did) |
| `libAlgoProcess` | DT_NEEDED `android.hardware.graphics.common-V5-ndk.so` → `V7` (as LineageOS did) and `vendor.qti.hardware.camera.offlinecamera-V2-ndk.so` → `V3` (LineageOS ships only V3; it made the same edit to ColorOS's offline camera service, and `libAlgoInterface` gets it too); P010 chroma plane fix at `0x21d2f8` (40 bytes, after `AHardwareBuffer_lockPlanes()` for format `0x7fa30c0a`): chroma = luma base + stride × align(height, 32), chroma strides = luma stride, height from the buffer descriptor (HDR crash otherwise) |

`--skip app_blobs` leaves them out (the camera app then needs a LineageOS build that still ships them).

## Install-time fixes (`module/customize.sh`, `fixlib`)

These patch the **user's own ROM file** into a copy inside the module, so they always match the ROM installed. A fix is applied only if the expected bytes occur exactly once. It's checked byte for byte afterwards, and recorded in `.fixed` with the original file's SELinux label, its ROM path, the sha256 of the ROM file it was made from, and the edit (offset, original and fixed bytes). The source is always the ROM's own file: `/vendor` is read directly, and an `/odm` file the module's copy hides is read from a second read-only mount of the odm partition. At boot, `post-fs-data.sh` remakes a copy whose ROM file a LineageOS update changed, with the same edit and the same checks (`refresh_fixes`, `module/common.sh`), so the module never has to be installed again for this; a fix whose bytes are gone from the new file is switched off. See `fixes.log` in the module folder.

| Target | Edit |
|---|---|
| `/vendor/lib64/vendor.qti.hardware.camera.offlinecamera-service-impl.so` → copy at `/odm/lib64/` (shadows by search order) | Read the buffer width where snapalloc keeps it, `+0x1c` → `+0x2c` (black photos otherwise). ColorOS 11.C.80: `ldr w21,[x8,#0x1c]` (pattern `a88355f8151d40b9bf020071`, offset 102472). |
| `libAlgoProcess.so` | A build-time fix of the module's own copy (`tools/app_blobs.py`, above): LineageOS no longer ships it. |
| `/odm/etc/camera/CameraHWConfiguration.config` (overlaid) | LineageOS's `extract-files.py` sets `[FDManager] fdSupport = FALSE` ("Disable face detection AE behaviour"), which switches OnePlus's face-detection manager off: no face-priority AE/AF/AWB and no face data for portrait and multi-subject modes (`AdjustFaceRectangle failed` on every frame). ColorOS ships `TRUE`; the fix restores it (`FALSE;` → `TRUE;\n`, same length; the fixed bytes are exactly ColorOS's line). `enableSWfdForThirdCamUnit` stays as LineageOS set it. Applies to every camera client (one HAL config). Pattern `…3d2046414c53453b` → `…3d20545255453b0a`, expected offset 224011 (240984 in ColorOS 11.C.80, found by its bytes). |
| `/odm/lib64/libEIS.so` (overlaid) | Five native-handle format reads for ShareBuffer, `ldr w4,[xN,#0x2c]` → `#0x34`: `+0x2c` is the legacy `private_handle_t::format`, which in snapalloc's handle is the unaligned width (the format is at `+0x34`); EGL imports failed (empty, green time-lapse videos). Found by Infinity X (`camera_eis_compat.py`); LineageOS's `libEIS` has exactly the code their fix was reviewed on (same `.text` hash). Five 20-byte patterns (`EIS_FIX_*` in `module/common.sh`). |
| `/odm/lib64/hw/camera.oemlayer.v2.so` → copy at `/odm/lib64/camera.oemlayer.v2.so`; `/odm/lib64/camera.oemlayer.uilayer.so` → copy `camera.oemlayer.uilaye2.so` | LineageOS's own layer, wrapped (ARCHITECTURE.md, Which layer). Layer: DT_NEEDED `camera.oemlayer.uilayer.so` → `uilaye2`; zoom: `ZoomDivisionV2::Initialize` `ldr w8,[x9,#0x124]` → `mov w8,wzr` (the SAT config flag that makes the layer ignore `ANDROID_CONTROL_ZOOM_RATIO`; without it the viewfinder never zooms). UI library: SONAME → `uilaye2`; `dlopen("/odm/lib64/hw/camera.oemlayer.v2.so")` → `dlopen("camera.oemlayer.v2.so")`. `LAYER_FIX_*` / `UILAYER_FIX_*` in `module/common.sh`. If either copy can't be made, the wrapper is left out and LineageOS's layer runs as is. |

## Framework stubs: `prebuilt/oplus-camera-stubs.jar`

`stubs_scoped_props` (applied at build time) adds `com.oplus.camera.los.LosProps` (generated by `tools/gen_losprops.py`) and routes every `android.os.SystemProperties` read in the jar through it. `stubs_framework_classes` adds `tools/smali-stubs/fwk/`: no-op `com.oplus.app.OplusHansFreezeManager` and `com.oplus.view.material.OplusMaterialUtil`, which the ColorOS app calls outside any try/catch and neither LineageOS's `oplus-fwk` nor the jar has (it stops the build once the jar gets one of them). `stubs_surfaceext_jni` declares `android.view.SurfaceExtImpl.nativeSetMaxDequeuedBufferCount` as `(JI)I`, the signature ColorOS's `liboplusgui_jni.so` registers; the `(JI)V` method `ISurfaceExt` calls stays as a wrapper. With the jar's `(JI)V` native the library's `JNI_OnLoad` throws `NoSuchMethodError`, which aborts the camera as soon as COUI loads the class.

OnePlus framework classes the app and SDK link against that LineageOS lacks. Built from LineageOS's open-source `oplus-fwk` classes plus our overrides in `tools/stubs-src/` (e.g. `OplusSystemProperties`, `OplusActivityManager`, `FlexibleWindowManager`). It's declared as the shared library `oplus.camera.stubs` (`overlay/.../com.oplus.camera.libraries.xml`), so the boot classpath is never touched.
