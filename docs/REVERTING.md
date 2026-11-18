# Reverting changes

Every modification and every debloat step this module makes is listed here, with the saved original and how to undo it. Nothing is lost: the firmware dump keeps every stock file, and the repository keeps the exact diff of every change.

Three ways to revert:

1. **Leave a change out of a build.** `python3 tools/build_module.py --list-patches` lists every name, then:
   - `--skip <name>` drops a smali patch, `apsclient_force_java_heif`, or a native edit id (repeatable);
   - `--enable-component <class>` keeps one of the disabled app components enabled (repeatable).

   Example: `--skip camera_drop_embedded_libs --skip layer-zoom-follow-app --enable-component com.oplus.camera.remote.RemoteService`.
2. **Read or reverse-apply the exact diff.** `diffs/` holds one unified diff per patch, recorded against a fresh apktool decode of the stock file. `git apply -R` reverses one inside a decoded tree.
3. **Use the stock file.** The checksums below identify the untouched originals in the firmware dump.

## Stock originals (OxygenOS CPH2745_16.0.10.601 EX01)

| File in the firmware dump | sha256 |
|---|---|
| `my_product/app/OplusCamera/OplusCamera.apk` | `90887340c132c731d251d74c04f18bf37d7276fb142dc4fa23f4ad3b98fdde9a` |
| `my_product/product_overlay/framework/com.oplus.camera.unit.sdk.jar` | `1d5774ba708cb02768ea199f45397ef0b47000c1471ddabf77e9bb14c3080e36` |
| `my_product/product_overlay/framework/com.oplus.camera.unit.sdk.adapter.jar` | `9982987fae9e3f583a02992608330c1fdc646b2c20805282fbd63f421dff4b32` |
| `my_product/lib64/libAPSClient-cmd-jni.so` | `b6669463a2dbdc22d20d0bb1a565ef9f1cc058f5f34c627a8d49971f7c509bec` |
| `odm/lib64/hw/camera.oemlayer.v2.so` | `73177634d1353d29222883570a6864b07d7e0915067d9e5646b9eaceffcfe3d9` |
| `odm/lib64/camera.oemlayer.uilayer.so` | `50fc6b6f61693e2de4c718c33f674cb29cc9a2eea8b29d966f3011a4306c28e6` |
| `odm/lib64/libsensorbridge.so` | `cc8267ce357aecbe60f8981720d791e3932d441cfc1e5c82ae6169cdeefe92e0` |

Byte-level originals of every native edit are stored in `tools/binpatches.json` (`orig`), in `tools/patches.py` (`APS_TARGETS`, `APS_STOCK`) and in `module/customize.sh` (the `fixlib` calls).

## 1. Camera app (`OplusCamera.apk`)

| # | Patch (`--skip` name) | Diff | What reverting does |
|---|---|---|---|
| 1 | `camera_font` | `diffs/app/01-camera_font.diff` | App reads OnePlus font state again (absent on LineageOS: wrong/missing typeface or crash). |
| 2 | `camera_blur_seginit_guard` | `diffs/app/02-…` | Portrait blur crashes when segmentation init fails. |
| 3 | `camera_uifirst` | `diffs/app/03-…` | Calls a method LineageOS's `OplusUIFirstManager` lacks (`NoSuchMethodError`). |
| 4 | `strip_oem_component_permissions` | `diffs/app/04-…` | Components guarded by undefined OnePlus permissions again; the launcher can't start them. |
| 5 | `vendor_tag_aliases` (also SDK + adapter) | `diffs/app/05-…` | App asks for vendor tags under names the HAL doesn't expose. |
| 6 | `camera_blur_license_path` | `diffs/app/06-…` | Portrait blur looks for its license on `/odm` (absent). |
| 7 | `camera_defer_ufs_probe` | `diffs/app/07-…` | Deferred capture reads `/proc/devinfo/ufs` (EACCES → crash). |
| 8 | `camera_gallery_fallback` | `diffs/app/08-…` (adds `tools/smali/LosGalleryFallback*.smali`) | Thumbnail opens nothing without OnePlus Gallery. |
| 9 | `camera_disable_oem_components` | `diffs/app/09-…` | Re-enables the components below (use `--enable-component` for single ones). |
| 10 | `camera_drop_embedded_libs` (debloat) | `diffs/app/10-camera_drop_embedded_libs.txt` (name, size and sha256 of each removed library) | Keeps the 39 native libraries inside the APK too (+46 MB). No functional change: the same files ship in `priv-app/OplusCamera/lib/arm64`. |

### Components disabled (debloat), `tools/patches.py: OEM_ONLY_COMPONENTS`

| Component | Purpose on OxygenOS |
|---|---|
| `com.heytap.accessory.platform.RegisterUponInstallReceiver` | HeyTap/OPPO wearable accessory framework |
| `com.heytap.accessory.platform.ServiceConnectionIndicationReceiver` | same |
| `com.heytap.accessory.stream.StreamConnReceiver` | same |
| `com.oplus.camera.upgrade.tunning.TuningParameterUpgradeReceiver` | OnePlus SAU tuning-parameter downloads |
| `com.oplus.camera.upgrade.tunning.TuningParameterUpgradeService` | same |
| `com.oplus.camera.migration.CameraBRPluginService` | OnePlus backup/restore (Clone Phone) plugin |
| `com.oplus.camera.debug.DebugBroadcastReceiver` | engineering-mode broadcast hook (exported) |
| `com.oplus.camera.feature.aiMasterWatermark.GalleryConnectionService` | bound by OnePlus Gallery (exported) |
| `com.oplus.camera.remote.RemoteService` | OnePlus multi-device remote shutter (exported) |

Disabling only stops the system from starting them. The app's own code still runs (it only reads static fields of two of them).

## 2. Camera SDK jars

| Patch | Diff |
|---|---|
| `sdk_runtime` | `diffs/sdk/01-sdk_runtime.diff` |
| `sdk_facebeauty_path` | `diffs/sdk/02-sdk_facebeauty_path.diff` |
| `sdk_session_package_tag` | `diffs/sdk/03-sdk_session_package_tag.diff` |
| `vendor_tag_aliases` | `diffs/sdk/04-vendor_tag_aliases.diff`, `diffs/sdk-adapter/01-vendor_tag_aliases.diff` |

## 3. Native libraries

| `--skip` id | File | Original → new | Note |
|---|---|---|---|
| `apsclient_force_java_heif` | `libAPSClient-cmd-jni.so` | two dlopen names `lib…` → `xib…` | stock hash in `patches.py` |
| `layer-needed-sensorbridg2` | `camera.oemlayer.v2.so` | `libsensorbridge.so` → `libsensorbridg2.so` | revert together with `sensorbridge-soname`, and ship nothing as `libsensorbridg2.so` |
| `layer-needed-charger-v9` | `camera.oemlayer.v2.so` | charger `V8` → `V9` | needed while LineageOS ships only V9 |
| `layer-needed-uilaye2` | `camera.oemlayer.v2.so` | `camera.oemlayer.uilayer.so` → `uilaye2` | revert together with `uilayer-soname` |
| `layer-zoom-follow-app` | `camera.oemlayer.v2.so` @0x35fe28 | `291d41b9` → `e9031f2a` | without it the viewfinder ignores zoom |
| `uilayer-needed-charger-v9` | `camera.oemlayer.uilaye2.so` | `V8` → `V9` | |
| `uilayer-soname` | `camera.oemlayer.uilaye2.so` | SONAME rename | |
| `uilayer-dlopen-real-layer` | `camera.oemlayer.uilaye2.so` | `/odm/lib64/hw/camera.oemlayer.v2.so` → `camera.oemlayer.v2.so` | only valid together with the wrapper layout |
| `uilayer-packagename-fallback` | `camera.oemlayer.uilaye2.so` @0x33ca0 (148 B) | inverted branch + fallback code | the SDK and wrapper also add the tag |
| `sensorbridge-soname` | `libsensorbridg2.so` | SONAME rename | |

The module ships the two renamed libraries **as private copies** because LineageOS's `libsensorbridge.so` and `camera.oemlayer.uilayer.so` are different, incompatible builds. Reverting the renames means the layer links against LineageOS's versions.

**Wrapper behaviour** (`tools/oemwrap/oemwrap.c`): to drop the encoder buffer cap, set `ENCODER_MAX_BUFFERS` to 64 (or remove the call in `configure_and_cap`) and rebuild with `tools/oemwrap/build.sh`. The package tag and the metadata-stream use case are separate functions (`wrap_configure`, `tag_meta_streams`).

**Wrapper** (`prebuilt/camera.oemlayer.wrap.so` at `/odm/lib64/hw/camera.oemlayer.v2.so`): to go without it, ship the real layer at the hw path instead and skip `uilayer-dlopen-real-layer`. Photos then depend only on the SDK's session tag.

## 4. Install-time fixes of ROM files (`module/customize.sh`)

These patch a copy of the user's own ROM file; the ROM file itself is never modified. To revert, comment out the `fixlib` call. The ROM's original is then used and nothing is copied.

| Label | ROM file | Original → fixed bytes |
|---|---|---|
| Offline camera service | `/vendor/lib64/vendor.qti.hardware.camera.offlinecamera-service-impl.so` (copy at `/odm/lib64`) | `981a40f9e2031faa1b1f40b9000f40b9` → `…1b2f40b9…` |
| Camera processing library | `/odm/lib64/libAlgoProcess.so` | see the two hex strings at the `fixlib` call |

## 5. System-level settings (module scripts)

| Where | Setting | Effect of removing it |
|---|---|---|
| `system.prop` | `ro.build.version.oplus.api`, `.sub_api`, `ro.build.version.oplusrom`, `ro.oplus.system.camera.name` | the app/SDK take the "not OnePlus" path for these checks |
| `system.prop` | `ro.oplus.camera.defercap.support`, `…defercap.all.quick.visible.support` | **required:** the app throws on start without the first |
| `system.prop` | `persist.camera.override_*`, `persist.sys.feature.localhdr_version`, `…uhdr.support`, `persist.sys.oplus.anim_level` | feature flags the app reads; values from OxygenOS (set in memory only) |
| `system.prop` | `ro.vendor.camera.res.fmq.size=8388608` | back to 1 MB: binder overflows, portrait crash |
| `service.sh` | `persist.vendor.camera.privapp.list += com.oplus.camera` (memory only) | the HAL no longer treats the app as a privileged client |
| `service.sh` | `logcat -G 16M` (runtime only) | smaller log history in debug bundles |
| `service.sh` | layer watchdog | no automatic fallback if the layer crashes the HAL |
| `sepolicy.rule` | each rule is commented with its reason | the matching denial returns |
| `post-fs-data.sh` | creates `camera_rus` dirs, relabels `cam_alog`, `camera_process`, `camera_remote_dump` (originals saved in `.relabeled`) | the app can't write its processing/log data |

## 6. Not shipped on purpose

- `vendor.oplus.hardware.cameraextension-V1-ndk.so`, `cameraextension@1.0.so`, `sendextcamcmd-V2-ndk.so` (in `selection.json`, skipped via `SKIP`): LineageOS provides these interfaces itself.
- `libdscaalgo.so`: the HAL loads it by an absolute `/vendor` path. Shipping it would mean overlaying `/vendor`, which breaks GPU apps (ARCHITECTURE.md).
- Any file under `/vendor`, from v0.24 on.

## 7. Removed from earlier versions

| Version | Removed | Why |
|---|---|---|
| v0.28 | `allow zygote vendor_file dir { … }` (added in v0.27) | it cleared the denial but not the browser problem; the real fix was removing the `/vendor` overlay |
| v0.24 | all `system/vendor/*` files (moved to `/odm`) | `/vendor` overlay broke GPU apps |
| v0.24 | `ro.vendor.camera.res.fmq.size=1` (v0.23) | binder overflows and stalls; replaced by 8 MB |

Scripts and config of every released version (v0.1–v0.30) are kept in `history/`, and each version's full file list in `history/vX.Y/FILES.txt`. `diff -ru history/v0.23 module` shows exactly what changed since then.
