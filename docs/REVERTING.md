# Reverting changes

Every modification and every debloat step this module makes is listed here, with the saved original and how to undo it. Nothing is lost: the firmware dump keeps every stock file, and the repository keeps the exact diff of every change.

Three ways to revert:

1. **Leave a change out of a build.** `python3 tools/build_module.py --list-patches` lists every name, then:
   - `--skip <name>` drops a smali patch, `apsclient_force_java_heif`, or `app_blobs` (repeatable);
   - `--enable-component <class>` keeps one of the disabled app components enabled (repeatable).

   Example: `--skip camera_drop_embedded_libs --enable-component com.oplus.camera.remote.RemoteService`.
2. **Read or reverse-apply the exact diff.** `diffs/` holds one unified diff per patch, recorded against a fresh apktool decode of the stock file. `git apply -R` reverses one inside a decoded tree.
3. **Use the stock file.** The checksums below identify the untouched originals in the firmware dump.

## Stock originals (ColorOS CPH2745_17.0.1.201(EX01), 11.C.80)

| File in the firmware dump | sha256 |
|---|---|
| `my_product/app/OplusCamera/OplusCamera.apk` (7.006.295) | `5d69459b7b2b15fbe7ea3b1912e16bbb0041ef24ce5b3f064bf9d3aba535e4da` |
| `my_product/product_overlay/framework/com.oplus.camera.unit.sdk.jar` | `e1354cb85f6157cf5f094c2617f2e87c2936c5b4f5f40758581fb8878b276215` |
| `my_product/product_overlay/framework/com.oplus.camera.unit.sdk.adapter.jar` | `c33f3a63a868ef632b4a403a669b2b00f2bf7c711c00293edd1f33f6e430ddd3` |
| `my_product/lib64/libAPSClient-cmd-jni.so` | `559cd5e9fc533cbce3cc3390cecad74127167daaf3e964e0cec424fcbc3eff9c` |
| `odm/lib64/libAlgoProcess.so` | `57ed7dcdc53e910753c87046a3270d9d6e00ae46a70114c5cc2ae8327c31de88` |

Byte-level originals of every native edit are stored in `tools/patches.py` (`APS_TARGETS`, `APS_STOCK`), `tools/app_blobs.py` (`BYTE_EDITS`) and in `module/customize.sh` / `module/common.sh` (the `fixlib` calls, `LAYER_FIX_*`, `UILAYER_FIX_*`, `EIS_FIX_*`). LineageOS's own layer is never modified; the module edits private copies.

## 1. Camera app (`OplusCamera.apk`)

| # | Patch (`--skip` name) | Diff | What reverting does |
|---|---|---|---|
| 1 | `camera_font` | `diffs/app/01-camera_font.diff` | App reads OnePlus font state again (absent on LineageOS: wrong/missing typeface or crash). |
| 2 | `camera_blur_seginit_guard` | `diffs/app/02-…` | Portrait blur crashes when segmentation init fails. |
| 3 | `camera_uifirst` | `diffs/app/03-…` | Calls a method LineageOS's `OplusUIFirstManager` lacks (`NoSuchMethodError`). |
| 4 | `strip_oem_component_permissions` | `diffs/app/04-…` | Components guarded by undefined OnePlus permissions again; the launcher can't start them. |
| 5 | `vendor_tag_aliases` (also SDK + adapter) | `diffs/app/05-…` | App asks for vendor tags under names the HAL doesn't expose. |
| 6 | `camera_defer_ufs_probe` | `diffs/app/06-…` | Deferred capture reads `/proc/devinfo/ufs` (EACCES → crash). |
| 7 | `camera_gallery_fallback` | `diffs/app/07-…` (adds `tools/smali/LosGalleryFallback*.smali`) | Thumbnail opens nothing without OnePlus Gallery. |
| 8 | `camera_disable_oem_components` | `diffs/app/08-…` | Re-enables the components below (use `--enable-component` for single ones). |
| 9 | `restrict_exported_components` | `diffs/app/09-…` | `EponaProvider` and six more components are reachable by any app again (`android:exported="true"` without a permission). |
| 10 | `camera_no_telemetry` | `diffs/app/10-…` | OPPO's usage statistics (OplusTrack) run again: events built on the report thread and sent to a statistics provider LineageOS doesn't have, plus OplusTrack's crash-report handler. |
| 11 | `camera_hide_dead_settings` | `diffs/app/11-…` | Shows Quick launch (both entries), the privacy policy link and the user agreement again (`DEAD_SETTINGS` in `tools/patches.py`; on LineageOS they do nothing or fail). |
| 12 | `camera_scoped_props` | `diffs/app/12-…` (adds `tools/smali-stubs/LosProps.smali` via the stubs jar, `diffs/stubs/`) | The app's three reflective `anim_level` reads (COUI helpers) go to the real system property (unset on LineageOS). |
| 13 | `camera_drop_embedded_libs` (debloat) | `diffs/app/13-camera_drop_embedded_libs.txt` (name, size and sha256 of each removed library) | Keeps the 37 native libraries inside the APK too (+46 MB). No functional change: the same files ship in `priv-app/OplusCamera/lib/arm64`. |

### Components disabled (debloat), `tools/patches.py: OEM_ONLY_COMPONENTS`

| Component | Purpose on ColorOS |
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
| `sdk_facebeauty_path` | `diffs/sdk/02-sdk_facebeauty_path.diff`, `diffs/sdk-adapter/01-sdk_facebeauty_path.diff` |
| `sdk_session_package_tag` | `diffs/sdk/03-sdk_session_package_tag.diff` |
| `vendor_tag_aliases` | `diffs/sdk/04-vendor_tag_aliases.diff`, `diffs/sdk-adapter/02-vendor_tag_aliases.diff` |

## 3. Native libraries

| `--skip` id | File | Original → new | Note |
|---|---|---|---|
| `apsclient_force_java_heif` | `libAPSClient-cmd-jni.so` | two dlopen names `lib…` → `xib…` | stock hash in `patches.py` |
| `app_blobs` | the camera app's own files (`tools/app_blobs.py`) | `libAlgoProcess` P010 fix, DT_NEEDED V5 → V7, unversioned `AHardwareBuffer_*` imports | `--skip app_blobs` ships none of the app's files (the app then needs a LineageOS build that still has them) |

**OnePlus camera layer** (LineageOS's): the installer makes private copies with four edits (`LAYER_FIX_*`, `UILAYER_FIX_*` in `module/common.sh`); to run LineageOS's layer as is, without the wrapper, delete `/data/adb/modules/oplus_camera_los/system/odm/lib64/hw/camera.oemlayer.v2.so` and reboot.

**Wrapper behaviour** (`tools/oemwrap/oemwrap.c`): to drop the encoder buffer cap, set `ENCODER_MAX_BUFFERS` to 64 (or remove the call in `configure_and_cap`) and rebuild with `tools/oemwrap/build.sh`. The package tag and the metadata-stream use case are separate functions (`wrap_configure`, `tag_meta_streams`).

**Wrapper** (`prebuilt/camera.oemlayer.wrap.so` at `/odm/lib64/hw/camera.oemlayer.v2.so`): to go without it, see above. Photos then depend only on the SDK's session tag.

## 4. Install-time fixes of ROM files (`module/customize.sh`)

These patch a copy of the user's own ROM file; the ROM file itself is never modified. To revert, comment out the `fixlib` call. The ROM's original is then used and nothing is copied.

| Label | ROM file | Original → fixed bytes |
|---|---|---|
| Offline camera service | `/vendor/lib64/vendor.qti.hardware.camera.offlinecamera-service-impl.so` (copy at `/odm/lib64`) | `a88355f8151d40b9bf020071` → `a88355f8152d40b9bf020071` (ColorOS 11.C.80) |
| libEIS SnapAlloc format | `/odm/lib64/libEIS.so` (overlaid) | five `ldr w4,[xN,#0x2c]` → `#0x34` (`EIS_FIX_*`). On the phone: delete `/data/adb/modules/oplus_camera_los/system/odm/lib64/libEIS.so` and reboot. |
| Camera face detection (FDManager) | `/odm/etc/camera/CameraHWConfiguration.config` (overlaid) | `fdSupport = FALSE;` → `fdSupport = TRUE;\n`. Comment out the `fixlib` call to keep LineageOS's setting (face detection off for every app). On the phone: delete `/data/adb/modules/oplus_camera_los/system/odm/etc/camera/CameraHWConfiguration.config` and reboot. |

## 4b. Isolation (v0.32)

| Change | Revert |
|---|---|
| Third-party sessions reopened on Qualcomm's HAL (wrapper proxy) | at runtime: `setprop persist.vendor.camera.oplus_los.route 0`; permanently: build the wrapper from `history`'s v0.31 `oemwrap.c` (in git history) |
| Camera props answered in-process (`stubs_scoped_props`, `camera_scoped_props`) | `--skip stubs_scoped_props --skip camera_scoped_props` and put the props from `tools/gen_losprops.py` back into `module/system.prop` |
| 16 MB log buffers only in debug mode | `touch /data/adb/modules/oplus_camera_los/debug` |

## 4c. Less system-wide impact (v0.37)

| Change | Revert |
|---|---|
| Frame-timestamp fix moved from a `cameraserver` copy into the wrapper (OnePlus sessions only) | at runtime: `setprop persist.vendor.camera.oplus_los.tsfix 0`; to go back to the `cameraserver` copy, restore step 3 of `customize.sh` and its `post-fs-data.sh`/`service.sh` parts from v0.36 (`history/v0.36`) |
| SELinux rules only for `priv_app_36` (plain `priv_app` duplicates removed) | `history/v0.36/sepolicy.rule` |
| Module-created data dirs owned by the camera app (`2770`) instead of `0777` (`tighten_dirs` in `common.sh`) | remove the two `tighten_dirs` calls; `chmod 0777` the dirs once |
| OplusTrack statistics off (`camera_no_telemetry`, section 1) | `--skip camera_no_telemetry` |
| One-time precompile after boot (`precompile` in `service.sh`) | delete the `precompile` function and its call; `cmd package compile --reset com.oplus.camera` drops the compiled code |
| Self-test on the Action button (`selftest.sh`) | delete `module/selftest.sh` (the button then always saves the debug bundle) |
| `privapp.list` set before boot completes instead of after | move the block below the `sys.boot_completed` wait in `service.sh` |

## 5. System-level settings (module scripts)

| Where | Setting | Effect of removing it |
|---|---|---|
| `tools/gen_losprops.py` (in-process, not system-wide since v0.32) | OnePlus ROM/API props, deferred capture (**required**), HDR and animation flags | edit `PROPS` to change what the camera sees |
| `system.prop` | `ro.vendor.camera.res.fmq.size=8388608` | back to 1 MB: binder overflows, portrait crash |
| `service.sh` | `persist.vendor.camera.privapp.list += com.oplus.camera` (memory only) | the HAL no longer treats the app as a privileged client |
| `service.sh` | `logcat -G 16M`, only when `$MODDIR/debug` exists (since v0.32) | smaller log history in debug bundles |
| `service.sh` | layer watchdog | no automatic fallback if the layer crashes the HAL |
| `sepolicy.rule` | each rule is commented with its reason | the matching denial returns |
| `post-mount.sh` | mounts the camera app's own files (`blobs.img`) over `/odm/lib64` and `/odm/etc/camera` | the app's processing libraries and models are missing: no HDR/portrait/night processing |
| `post-fs-data.sh` | creates `camera_rus` dirs, relabels `cam_alog`, `camera_process`, `camera_remote_dump` (originals saved in `.relabeled`) | the app can't write its processing/log data |

## 6. Not shipped on purpose

- `vendor.oplus.hardware.cameraextension-V1-ndk.so`, `cameraextension@1.0.so`, `sendextcamcmd-V2-ndk.so` (in `selection.json`, skipped via `SKIP`): LineageOS provides these interfaces itself.
- Any file under `/vendor`, from v0.24 on.

## 7. Removed from earlier versions

| Version | Removed | Why |
|---|---|---|
| v0.39 | the module's own OxygenOS layer (`tools/binpatches.json`, `libsensorbridg2`), the OFE/DSCA fix (`libcamxofehwl`, `libdscaalgo`), `camera_blur_license_path` | the module now requires LineageOS's ColorOS-blob builds, which ship the layer and `libdscaalgo`; the blur license is an app file |
| v0.28 | `allow zygote vendor_file dir { … }` (added in v0.27) | it cleared the denial but not the browser problem; the real fix was removing the `/vendor` overlay |
| v0.24 | all `system/vendor/*` files (moved to `/odm`) | `/vendor` overlay broke GPU apps |
| v0.24 | `ro.vendor.camera.res.fmq.size=1` (v0.23) | binder overflows and stalls; replaced by 8 MB |

Scripts and config of every released version (v0.1 to the current version) are kept in `history/`, and each version's full file list in `history/vX.Y/FILES.txt`. `diff -ru history/v0.23 module` shows exactly what changed since then.
