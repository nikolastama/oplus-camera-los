# Patches

The exact change each patch makes is saved in `diffs/`. How to leave any of them out: [REVERTING.md](REVERTING.md).

Every patch locates its target by content (a smali anchor, the exact original bytes, or a file hash) and fails loudly if it isn't there. A different firmware build therefore stops the build at the first patch that no longer fits, and never produces a silently broken module.

## Camera app (`OplusCamera.apk`), `tools/patches.py`

Applied in this order by `build_module.py` to an apktool decode of the stock APK. Applied to the stock 16.0.10.601 APK, they reproduce the shipped app with zero differences.

| Function | Why |
|---|---|
| `camera_font` | `TypeFaceUtil` reads OnePlus font-framework state that doesn't exist on LineageOS → use `Typeface.DEFAULT`. |
| `camera_blur_seginit_guard` | Portrait blur dereferences `segInit()`'s result without a null check → treat null as "no blur" instead of crashing. |
| `camera_uifirst` | LineageOS's `OplusUIFirstManager` lacks `setUxThreadValue(IILString;)V` → calls become `nop`. |
| `strip_oem_component_permissions` | Components guarded by undefined OEM permissions would lock the launcher out → remove those attributes. |
| `vendor_tag_aliases` | The app asks for vendor tags the OP15 HAL exposes under other names (Infinity X aliased them in `frameworks/av`) → rename them in the app. |
| `camera_blur_license_path` | Portrait-blur license is read from `/odm/etc/camera`, which LineageOS lacks → read the module's `/system_ext/etc/camera` copy. |
| `camera_defer_ufs_probe` | Deferred capture reads `/proc/devinfo/ufs` (EACCES on LineageOS → crash) to blacklist one UFS part → treat it as absent. |
| `camera_gallery_fallback` | No OnePlus Gallery → the thumbnail opens `ACTION_VIEW`, but waits (≤ 8 s) for the final deferred image so the gallery doesn't cache the quick JPEG. Adds `tools/smali/LosGalleryFallback*.smali` and hooks `GalleryHelper.p()` and the defer-save handler in `CameraManager`. |
| `camera_disable_oem_components` | Disables receivers and services that only answer OnePlus system broadcasts or OnePlus apps: HeyTap accessory, SAU tuning download, backup plugin, debug receiver, Gallery connection and multi-device remote services. All exported; nothing in the app calls them. |
| `camera_drop_embedded_libs` | The app runs as a preinstalled system app and loads native code from `priv-app/OplusCamera/lib/arm64` → drop the unused copies inside the APK (−46 MB). |

## Camera SDK (`com.oplus.camera.unit.sdk.jar` / `.adapter.jar`)

| Function | Why |
|---|---|
| `sdk_runtime` | Carried over from the Infinity X port: drops the explicit `= false` / `= null` defaults of a set of static fields (the runtime default is the same), and makes `BaseMode.isSensorModeNeedWait` return false so mode switches don't wait for a sensor-mode signal. |
| `sdk_facebeauty_path` | Face-beauty JNI moved from `/product` to `/system_ext`. |
| `sdk_session_package_tag` | Sets `com.oplus.packageName` on the session (see ARCHITECTURE.md). |
| `vendor_tag_aliases` | Same tag aliases as the app (SDK and adapter). |

## Native libraries

### `libAPSClient-cmd-jni.so`: `apsclient_force_java_heif`
On OxygenOS the processing client sits in `/product`, where namespace isolation hides the native HEIF helpers, so the Java fallback runs. Co-located in `/system_ext` it would switch to the untested native route. Two dlopen names are broken exactly as Infinity X does. Verified by sha256 before and after.

### OnePlus camera layer: `tools/binpatches.json`
Each edit lists its offset, original bytes, new bytes and reason. The build verifies the original bytes (or searches for them uniquely if the offset moved) and the final sha256.

| File | Edit |
|---|---|
| `camera.oemlayer.v2.so` (from `odm/lib64/hw/`) | DT_NEEDED renames: `libsensorbridge` → `libsensorbridg2`, `camera.oemlayer.uilayer` → `uilaye2` (private copies; LineageOS ships incompatible ones), `charger-V8-ndk` → `V9` (LineageOS has V9). **Zoom:** `ZoomDivisionV2::Initialize` forces the SAT config flag that makes the layer ignore `ANDROID_CONTROL_ZOOM_RATIO` to 0 (`ldr w9,[x9,#0x11c]` → `mov w9,wzr` at 0x35fe28); without it the viewfinder never zooms. |
| `camera.oemlayer.uilaye2.so` (from `camera.oemlayer.uilayer.so`) | SONAME rename, `charger-V8` → `V9`, dlopen path `/odm/lib64/hw/camera.oemlayer.v2.so` → `camera.oemlayer.v2.so` (the hw path is now the wrapper), and the `InitPackageName` fallback (ARCHITECTURE.md). |
| `libsensorbridg2.so` (from `libsensorbridge.so`) | SONAME rename. |

### Wrapper: `prebuilt/camera.oemlayer.wrap.so`
Our own code (`tools/oemwrap/oemwrap.c`). It exposes a copy of the real layer's HAL module with `open` replaced, and redirects each device's `configure_streams` for OnePlus operation modes: it adds the session package tag, sets the picture-metadata stream's use case, and caps video-encoder streams at 40 buffers (ARCHITECTURE.md). `tools/oemwrap/build.sh` rebuilds it with clang + lld; no NDK needed.

## Install-time fixes (`module/customize.sh`, `fixlib`)

These patch the **user's own ROM file** into a copy inside the module, so they always match the ROM installed. A fix is applied only if the expected bytes occur exactly once. It's checked byte for byte afterwards, and recorded in `.fixed` with the original file's SELinux label.

| Target | Edit |
|---|---|
| `/vendor/lib64/vendor.qti.hardware.camera.offlinecamera-service-impl.so` → copy at `/odm/lib64/` (shadows by search order) | `ldr w27,[x24,#0x1c]` → `#0x2c`: read the buffer width where snapalloc keeps it (black photos otherwise). Pattern `981a40f9e2031faa1b1f40b9000f40b9`, expected offset 111500. |
| `/odm/lib64/libAlgoProcess.so` (overlaid) | P010_VENUS chroma plane = luma base + stride × align(height, 32), chroma stride = luma stride (HDR crash otherwise). Pattern in `customize.sh`, expected offset 1875764. |

## Framework stubs: `prebuilt/oplus-camera-stubs.jar`
OnePlus framework classes the app and SDK link against that LineageOS lacks. Built from LineageOS's open-source `oplus-fwk` classes plus our overrides in `tools/stubs-src/` (e.g. `OplusSystemProperties`, `OplusActivityManager`, `FlexibleWindowManager`). It's declared as the shared library `oplus.camera.stubs` (`overlay/.../com.oplus.camera.libraries.xml`), so the boot classpath is never touched.
