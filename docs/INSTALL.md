# Installing, updating and removing

## Requirements

- OnePlus 15 (`infiniti`) on **official LineageOS 24**. The installer checks the device and ROM from the build.prop files and refuses anything else. It needs a build with **ColorOS 11.C.80 blobs** (from late November 2026): the camera app comes from that same ColorOS firmware and works with its camera HAL and layer. Older builds with OxygenOS 11.A blobs are refused (use v0.38 there).
- **KernelSU or KernelSU-Next** with a metamodule that mounts module files. The module is developed and tested with **meta-overlayfs** (the official reference metamodule).
- Free space: about **2.2 GB in `/data/adb`** for the module, of which about 0.3 GB also go into the metamodule's image. Since LineageOS stopped shipping the camera app's own models and libraries, the module carries them (2.4 GB: ≈0.9 GB of libraries, ≈1.5 GB of models; the largest, `hybridraw_models/unet.bix`, is 514 MB) in a compressed read-only image of 1.66 GB. It stays in the module folder and is mounted at boot, so they don't count against meta-overlayfs's image (2 GB by default for all modules). The installer checks the image's free space for the rest before anything is copied and stops with a message if it doesn't fit.

## Install

1. Install the metamodule ([meta-overlayfs](https://github.com/KernelSU-Modules-Repo/meta-overlayfs/releases/tag/v1.3.1)) if you don't have one yet, and reboot.
2. KernelSU manager → Modules → Install → choose `oplus-camera-los-vX.Y.zip`.
   The installer:
   - verifies the device, the ROM and that the OnePlus HAL libraries it needs are present;
   - wraps LineageOS's own OnePlus camera layer (private copies with a few edits; LineageOS's files stay untouched);
   - keeps the camera app's own files in a read-only image (with the ColorOS odm image's labels) that is mounted over `/odm/lib64` and `/odm/etc/camera` at every boot (`post-mount.sh`);
   - makes fixed copies of a few ROM files inside the module (the ROM files are never touched), and remakes them by itself after LineageOS updates;
   - snapshots your persistent props and settings so removal can delete only what the camera adds.
3. Reboot.
4. **KernelSU → Superuser → ⋮ → Show system apps → Camera → turn off "Umount modules".**
   The camera is a system app, so it only appears in the list once system apps are shown.
   If "Umount modules" is on for an app, KernelSU hides every module from it. The camera then can't find its own APK and crashes on start. Do the same for your launcher if your default profile unmounts modules (otherwise the launcher can't show the camera icon).
5. Open **Camera**.

Zygisk/denylist tools (Zygisk Next, HMA, etc.) can also hide modules. Keep the camera off those lists.

## Make it your default camera

The camera handles all of Android's standard camera intents, including the lock-screen ones, so
LineageOS's shortcuts open it like any camera app:

- **Double-press power:** turn it on in Settings → System → Gestures. The first time, if Aperture
  (LineageOS's camera) is also installed, Android asks which camera to use: pick **Camera** and
  **Always**. Do it once unlocked and once from the lock screen (the locked shortcut is a separate
  choice).
- **Lock-screen camera shortcut** and apps that ask for "take a photo": same choice, same answer.
- Changed your mind: Settings → Apps → Camera (or Aperture) → Open by default → Clear defaults.

The OnePlus camera's own "Quick launch" setting is hidden: it only works with ColorOS's system
services. The gesture above replaces it.

## Update

**After a LineageOS update** nothing needs to be done. If the update changed one of the ROM files the module keeps a fixed copy of, the module makes that copy again from the new file during boot, without any message (see ARCHITECTURE.md, Watchdog). With meta-overlayfs the remade copy can take effect one boot later.

**Module update:** flash the new zip over the installed one and reboot. Your camera settings are kept. The install also clears out any files from older versions that the metamodule still has in its own copy of the module (see ARCHITECTURE.md, "Metamodule copy").

The app is signed with the module key, so it updates in place. Changing the signing key (for example by building with your own key) means removing the old version first.

## Remove

Remove the module in the KernelSU manager and reboot. On that boot:

- **Early (uninstall.sh):** the app's data, caches, compiled code and profiles; directories the module created; labels the module changed on LineageOS directories are put back; crash reports of the camera's own processes; the module's copy inside the metamodule image; the debug bundles the Action button saved to Download.
- **Late (one-shot service script, which deletes itself):** settings keys and persistent props the camera created since installation (compared against the install-time snapshot), and any file still owned by the camera's old UID outside your media.

**Kept on purpose:** photos and videos in `DCIM`. Your KernelSU app profile for `com.oplus.camera` is KernelSU configuration you made, so delete it in the manager if you want it gone too.

## What the module changes while installed

All of it disappears with the module:

| Area | Change |
|---|---|
| Files | New files on `/system_ext` (app, SDK, libraries, configs) and `/odm` (the wrapper of the OnePlus camera layer). The camera app's own ~90 libraries and ~700 models/configs, which LineageOS no longer ships, are mounted from an image in the module folder over `/odm/lib64` and `/odm/etc/camera` (read-only overlays, gone at the next boot after removal). Fixed copies of ROM files, each made from the ROM's own file at install and remade after LineageOS updates: the offline camera service (shadowed via `/odm/lib64`), `CameraHWConfiguration.config`, `libEIS`, and private copies of LineageOS's camera layer and its UI library. |
| Properties | One system-wide: a larger camera result queue (`ro.vendor.camera.res.fmq.size`). The OnePlus camera's own props are answered inside its process. `service.sh` adds `com.oplus.camera` to `persist.vendor.camera.privapp.list` (in memory; LineageOS's camera service applies it only to that package). Larger log buffers (16 MB, until the next reboot) only in debug mode: the Action button's first press, or `touch …/oplus_camera_los/debug` for every boot. |
| SELinux | `sepolicy.rule`: a few rules for the camera app's data dirs, the DSP library watch, and the camera HAL reading system props. |
| Data | `/data/system/camera_rus`, `/data/vendor/camera_rus` (created if absent); `/data/vendor/cam_alog`, `camera_process` and `camera_remote_dump` relabelled for the camera (original labels saved and restored on removal). |
| Camera HAL | The provider loads the module's camera layer for every app, but only the OnePlus camera's sessions run through it. Every other app's session is reopened directly on Qualcomm's HAL, the stock LineageOS path (ARCHITECTURE.md, Isolation). |
