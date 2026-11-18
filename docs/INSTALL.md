# Installing, updating and removing

## Requirements

- OnePlus 15 (`infiniti`) on **official LineageOS 24**. The installer checks the device and ROM from the build.prop files and refuses anything else.
- **KernelSU or KernelSU-Next** with a metamodule that mounts module files. The module is developed and tested with **meta-overlayfs** (the official reference metamodule).
- About 230 MB free in `/data/adb`.

## Install

1. Install the metamodule (meta-overlayfs) if you don't have one yet, and reboot.
2. KernelSU manager → Modules → Install → choose `oplus-camera-los-vX.Y.zip`.
   The installer:
   - verifies the device, the ROM and that the OnePlus HAL libraries it needs are present;
   - installs the OnePlus camera layer only if all of its dependencies exist on the ROM;
   - makes fixed copies of two ROM libraries inside the module (the ROM files are never touched);
   - snapshots your persistent props and settings so removal can delete only what the camera adds.
3. Reboot.
4. **KernelSU → Superuser → Camera (`com.oplus.camera`) → turn off "Umount modules".**
   If "Umount modules" is on for an app, KernelSU hides every module from it. The camera then can't find its own APK and crashes on start. Do the same for your launcher if your default profile unmounts modules (otherwise the launcher can't show the camera icon).
5. Open **Camera**.

Zygisk/denylist tools (Zygisk Next, HMA, etc.) can also hide modules. Keep the camera off those lists.

## Update

Flash the new zip over the installed one and reboot. Your camera settings are kept. The install also clears out any files from older versions that the metamodule still has in its own copy of the module (see ARCHITECTURE.md, "Metamodule copy").

The app is signed with the module key, so it updates in place. Changing the signing key (for example by building with your own key) means removing the old version first.

## Remove

Remove the module in the KernelSU manager and reboot. On that boot:

- **Early (uninstall.sh):** the app's data, caches, compiled code and profiles; directories the module created; labels the module changed on LineageOS directories are put back; crash reports mentioning the camera; the module's copy inside the metamodule image; the debug bundles the Action button saved to Download.
- **Late (one-shot service script, which deletes itself):** settings keys and persistent props the camera created since installation (compared against the install-time snapshot), and any file still owned by the camera's old UID outside your media.

**Kept on purpose:** photos and videos in `DCIM`. Your KernelSU app profile for `com.oplus.camera` is KernelSU configuration you made, so delete it in the manager if you want it gone too.

## What the module changes while installed

All of it disappears with the module:

| Area | Change |
|---|---|
| Files | New files on `/system_ext` (app, SDK, libraries, configs) and `/odm` (OnePlus camera layer). Two ROM libraries are replaced by fixed copies inside the module (`/odm/lib64/libAlgoProcess.so` overlaid; the offline camera service shadowed via `/odm/lib64`). Nothing under `/vendor`. |
| Properties | `system.prop`: OnePlus API/ROM version and deferred-capture props the app requires, and a larger camera result queue (`ro.vendor.camera.res.fmq.size`). `service.sh`: `persist.vendor.camera.privapp.list` in memory only, plus larger logd buffers (runtime only). |
| SELinux | `sepolicy.rule`: a few rules for the camera app's data dirs, the DSP library watch, and the camera HAL reading system props. |
| Data | `/data/system/camera_rus`, `/data/vendor/camera_rus` (created if absent); `/data/vendor/cam_alog`, `camera_process` and `camera_remote_dump` relabelled for the camera (original labels saved and restored on removal). |
| Camera HAL | LineageOS already sets `ro.hardware.camera=oemlayer.v2` without shipping that layer. With the module the layer exists, so **all** camera apps go through OnePlus's camera layer, the same as on OxygenOS. |
