# Security notes

This module runs a vendor camera app outside the system it was built for. Making that work
needs a few changes that loosen Android's defaults. They are listed here so reviewers and
users can judge them; each one can be found in the file named.

## What the module changes

| Area | Change | Where | Effect |
|---|---|---|---|
| Exported components | `strip_oem_component_permissions` removes OnePlus-only `android:permission` guards (the permissions don't exist on LineageOS, so the launcher couldn't start the camera). Components only OnePlus services use are disabled (`camera_disable_oem_components`); the ones the camera only uses itself are made private (`restrict_exported_components`, from v0.34). | `tools/patches.py`, `diffs/app/` | Only the camera's activities stay open to other apps. See the list below. |
| SELinux | Adds rules for `priv_app` and `priv_app_36` (DSP/FastRPC, camera HAL binder, camera data dirs), and read/map/execute on `vendor_file`. | `module/sepolicy.rule` | Rules apply to **every** privileged app, not only the camera, because the camera has no domain of its own on LineageOS. `vendor_file` read/execute is the broadest of them. |
| Data directories | Creates `/data/system/camera_rus`, `/data/vendor/cam_alog`, `camera_process`, `camera_rus` with mode `0777`, and relabels three existing LineageOS dirs to `vendor_camera_data_file` (`mlstrustedobject`). | `module/post-fs-data.sh` | Access is still limited by SELinux labels; the original labels are restored on removal. |
| System property | Sets `ro.vendor.camera.res.fmq.size` and adds `com.oplus.camera` to `persist.vendor.camera.privapp.list` (in memory only). | `module/system.prop`, `module/service.sh` | Affects the camera HAL for all camera apps (larger result queue). |
| Camera service | A copy of the ROM's `cameraserver` returns camera buffers whose timestamp goes backwards instead of marking them as errors (stock Android already does this for ZSL captures). | `module/customize.sh`, docs/ARCHITECTURE.md | Applies to every app's camera session; only OnePlus's multi-frame captures produce such timestamps. Dropped automatically after a LineageOS update. |
| Native libraries | Ships byte-patched copies of two ROM libraries on `/odm`; the ROM files are never modified. | `module/customize.sh` | Each patch is applied only if the exact original bytes are found once, then verified. |

### Exported components

Left open without a permission, because the launcher and other apps start them:
`component.OplusCameraActivity`, `component.CameraOplusImageActivity`, `setting.CameraSettingActivity`,
`setting.AiCameraActivity`, `feature.keymagic.KeyMagicSettingActivity`.

Made private to the camera (`restrict_exported_components`, `INTERNAL_COMPONENTS`):
`com.oplus.epona.internal.EponaProvider` (OPPO's inter-app call bridge), `component.CameraInfoProvider`,
`setting.AiCameraVisibleProvider`, `feature.aicloudhd.provider.AiCloudHdProvider`,
`feature.basic.fluid.FluidCardWidgetProvider`, `feature.keymagic.KeyMagicService`,
`bluetooth.BlueToothScanService`. Included from v0.34. The v0.34 release APK is the v0.32 build with
these seven values changed in its compiled manifest and signed again with the module key (same
certificate, so it updates in place); a build from source gets the same change from `tools/patches.py`.

## Debug bundle privacy

The Action button saves a full `logcat`, `getprop`, tombstones and camera dumps to
`Download/`. These can contain device identifiers (build fingerprint, serial-derived
values) and information about other apps. Review a bundle before sharing it publicly.

The first press also turns on verbose camera logging until the next reboot, including
`persist.camera.assert.panic` / `persist.sys.assert.panic`, which can make the camera
service abort on internal assertions while debugging. Reboot to return to normal.

## Removal

`module/uninstall.sh` deletes the app's data, crash reports that mention `com.oplus.camera`,
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
