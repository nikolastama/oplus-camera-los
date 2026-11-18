# OnePlus Camera for LineageOS (OnePlus 15)

A KernelSU module that runs the stock OnePlus camera app from OxygenOS on **official LineageOS 24** on the **OnePlus 15 (`infiniti`, SM8850)**. It ships OnePlus's full image processing: multi-frame HDR, deferred multi-frame captures, portrait, zoom across all lenses, and the OnePlus video pipeline. The module is systemless and fully reversible: removing it leaves no trace of the app, and nothing on the ROM is ever modified.

| | |
|---|---|
| Camera build | OxygenOS `CPH2745_16.0.10.601` (EX01), OplusCamera 6.070.230 |
| Target ROM | Official LineageOS 24 for `infiniti` |
| Root | KernelSU / KernelSU-Next with the **meta-overlayfs** metamodule |
| Module ID | `oplus_camera_los` |

> **No proprietary binaries are in this repository.** The scripts, patches, documentation and two small artifacts of our own live here. Every OnePlus file is taken from an OxygenOS firmware dump by `tools/build_module.py` (see [docs/BUILDING.md](docs/BUILDING.md)).

## What works

- Photo with OnePlus's processing (turbo HDR, multi-frame, quick JPEG that is then replaced by the final image).
- All rear lenses and zoom (the viewfinder follows the zoom buttons and pinch).
- Portrait mode, video, front camera.
- Thumbnail opens the photo in your gallery app (there is no OnePlus Gallery on LineageOS).
- Other camera apps keep working.

**Known limitations:** OnePlus-only extras that depend on OnePlus system services are absent: the OnePlus Gallery hand-off, HeyTap/OPPO accessories, cloud "AI" features, and SAU tuning updates. The ToF and color-spectrum sensors aren't exposed by LineageOS's kernel, so the HAL logs harmless errors about them.

## Quick start

1. Install KernelSU (or KernelSU-Next) and the **meta-overlayfs** metamodule.
2. Flash `oplus-camera-los-vX.Y.zip` in the KernelSU manager and reboot.
3. KernelSU → Superuser → **Camera (com.oplus.camera)** → turn **"Umount modules" off**. Do the same for your launcher if your default is to unmount.
4. Open **Camera**.

Full guide: [docs/INSTALL.md](docs/INSTALL.md). Removal is described there too.

## Documentation

| Document | For |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | Installing, updating, removing, KernelSU settings |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Debug bundle (Action button), known log noise, common problems |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the camera stack fits together on LineageOS and why every file is where it is |
| [docs/PATCHES.md](docs/PATCHES.md) | Every patch: app, SDK, native libraries, install-time fixes |
| [docs/BUILDING.md](docs/BUILDING.md) | Building the module zip from a firmware dump |
| [docs/MAINTAINING.md](docs/MAINTAINING.md) | **Updating to new OxygenOS/ColorOS blobs** and new LineageOS builds, test checklist |
| [docs/REVERTING.md](docs/REVERTING.md) | **Every modification and debloat step, its saved original, and how to undo it** |
| [docs/CHANGELOG.md](docs/CHANGELOG.md) | Version history and what each version fixed |

## Repository layout

```
module/            module scripts and config (customize, post-fs-data, service, action, uninstall,
                   system.prop, sepolicy.rule, module.prop, META-INF)
overlay/           text config files we author (shared-library, privapp and hidden-API XMLs)
prebuilt/          our own binaries: the camera-layer session-tag wrapper and the framework stub jar
tools/
  build_module.py  firmware dump -> module zip (patch, rebuild, sign, verify, zip)
  patches.py       anchored smali/manifest patches for the app and SDK, plus binary patch helpers
  binpatches.json  verified byte edits for the OnePlus camera layer libraries
  selection.json   firmware path -> module path for the copied libraries and configs
  smali/           smali classes added to the app (gallery hand-off)
  oemwrap/         source + build script for the camera-layer wrapper
  stubs-src/       source of the OnePlus framework stubs (oplus-camera-stubs.jar)
  make_diffs.py    regenerates diffs/ after a patch changes
  deps.py, linkcheck.py, jnitab.py   analysis helpers used when updating blobs
diffs/             one unified diff per app/SDK patch against the stock decode (for review and reversal)
history/           scripts and config of every released version (v0.1 to now) and each zip's file list
docs/
```

## Credits

The original port was in the OP15InfinityX device trees (`android_device_oneplus_infiniti-camera`). Thanks to the LineageOS team for `infiniti` and for `oplus-fwk`, and to the KernelSU developers for meta-overlayfs. The OnePlus camera, its SDK and libraries are OnePlus/OPPO property and are not distributed here.

Maintainer: Nikola
