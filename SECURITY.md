# Security notes

This module runs a vendor camera app outside the system it was built for. Making that work
needs a few changes that loosen Android's defaults. They are listed here so reviewers and
users can judge them; each one can be found in the file named.

## What the module changes

| Area | Change | Where | Effect |
|---|---|---|---|
| Exported components | `strip_oem_component_permissions` removes OnePlus-only `android:permission` guards (the permissions don't exist on LineageOS, so the launcher couldn't start the camera). Components only OnePlus services use are disabled (`camera_disable_oem_components`); the ones the camera only uses itself are made private (`restrict_exported_components`, from v0.34). | `tools/patches.py`, `diffs/app/` | Only the camera's activities stay open to other apps. See the list below. |
| SELinux | Adds rules for `priv_app_36` (DSP/FastRPC, camera HAL binder, camera data dirs), and read/map/execute on `vendor_file`. Since v0.37 only `priv_app_36`, the domain the camera runs in (LineageOS 24 splits privileged apps by target SDK); earlier versions also granted them to plain `priv_app`. | `module/sepolicy.rule` | Rules apply to every privileged app that targets SDK 36, not only the camera, because the camera has no domain of its own on LineageOS. `vendor_file` read/execute is the broadest of them; the files it covers are the ROM's own on read-only partitions, so they can't get a narrower label. |
| Data directories | Creates `/data/system/camera_rus` (and `jobSize` in it) and `/data/vendor/camera_rus` (plus `cam_alog`/`camera_process` on ROMs that lack them), and relabels three existing LineageOS dirs to `vendor_camera_data_file` (`mlstrustedobject`). Since v0.37 the folders the module created are owned by the camera app, mode `2770` (group: the app's shared group for `/data/system/camera_rus`, `camera` for the vendor ones); they are `0777` only until the app exists (first boot after install). LineageOS's own folders keep their own owner and mode. | `module/post-fs-data.sh`, `module/common.sh` | Access is limited by both owner/mode and SELinux labels; the original labels are restored on removal. |
| System property | Sets `ro.vendor.camera.res.fmq.size` and adds `com.oplus.camera` to `persist.vendor.camera.privapp.list` (in memory only; LineageOS's camera service applies it only to that package). | `module/system.prop`, `module/service.sh` | The result-queue size affects the camera HAL for all camera apps (larger queue). |
| Camera service | Not modified since v0.37. Out-of-order frame timestamps in OnePlus multi-frame shots are raised to stay increasing inside the camera HAL process, for OnePlus sessions only (docs/ARCHITECTURE.md). v0.35–v0.36 shipped a fixed copy of the ROM's `cameraserver` that applied to every app. | `tools/oemwrap/oemwrap.c` | Other apps' sessions are not affected. |
| Native libraries | Ships byte-patched copies of a few ROM files on `/odm` (the offline camera service, the camera HW config, and depending on the LineageOS build Qualcomm's offline front end, `libEIS` and private copies of LineageOS's camera layer and its UI library), plus an unmodified copy of the ROM's tintless library where needed; the ROM files are never modified. Also ships the camera app's own OnePlus/ArcSoft libraries on `/odm`, taken from the OxygenOS firmware (LineageOS no longer ships them). | `module/customize.sh` | Each patch is applied only if the exact original bytes are found once, then verified. A copy whose ROM file a LineageOS update changed is remade from the new file at boot with the same checks, or removed if the edit no longer fits (`refresh_fixes`, `module/common.sh`). |

### Exported components

Left open without a permission, because the launcher and other apps start them:
`component.OplusCameraActivity`, `component.CameraOplusImageActivity`, `setting.CameraSettingActivity`,
`setting.AiCameraActivity`, `feature.keymagic.KeyMagicSettingActivity`.

Made private to the camera (`restrict_exported_components`, `INTERNAL_COMPONENTS`):
`com.oplus.epona.internal.EponaProvider` (OPPO's inter-app call bridge), `component.CameraInfoProvider`,
`setting.AiCameraVisibleProvider`, `feature.aicloudhd.provider.AiCloudHdProvider`,
`feature.basic.fluid.FluidCardWidgetProvider`, `feature.keymagic.KeyMagicService`,
`bluetooth.BlueToothScanService`. Included from v0.34 (v0.34–v0.36 shipped the v0.32 APK with these
seven values changed by hand; from v0.37 the release APK is built from source by
`tools/build_module.py`, which decodes to the same app plus the later patches).

## Usage statistics

The OnePlus camera contains OPPO's statistics SDK (OplusTrack), which records usage events (shutter
presses, zoom, mode and menu use, filters, errors) for OxygenOS's statistics service. Since v0.37 it
is switched off in the app (`camera_no_telemetry`, docs/PATCHES.md); before that the events were
built but could not be delivered, as LineageOS has no such service.

## Debug bundle privacy

The Action button saves a full `logcat`, `getprop`, tombstones and camera dumps to
`Download/`. These can contain device identifiers (build fingerprint, serial-derived
values) and information about other apps. Review a bundle before sharing it publicly.

The first press also turns on verbose camera logging until the next reboot, including
`persist.camera.assert.panic` / `persist.sys.assert.panic`, which can make the camera
service abort on internal assertions while debugging. Reboot to return to normal.

## Removal

`module/uninstall.sh` deletes the app's data, crash reports of the camera's own processes,
debug bundles in `Download/`, and any leftover file under `/data` owned by the camera's old
UID (only if that UID hasn't been given to another app). Your photos and videos are kept.

## Binaries in this repository

- `prebuilt/camera.oemlayer.wrap.so` is built from `tools/oemwrap/` with `tools/oemwrap/build.sh`
  (clang + lld). The build is reproducible: the output matches the committed file byte for byte.
- `prebuilt/oplus-camera-stubs.jar` is LineageOS's open-source `oplus-fwk` classes plus
  `tools/stubs-src/shim_override/`, see `tools/stubs-src/README.md`. It contains only
  framework compatibility classes (`android.*`, `com.oplus.*`, `vendor.oplus.*`), no camera code.

No OnePlus/OPPO firmware files are stored here; `tools/build_module.py` takes them from a
firmware dump you supply.

## Reporting

Open an issue on this repository. Please don't attach a full debug bundle publicly.
