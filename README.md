<div align="center">

# 📷 OnePlus Camera for LineageOS

**The stock OnePlus 15 camera, running on official LineageOS 24.**

[![Download](https://img.shields.io/github/v/release/nikolastama/oplus-camera-los?label=download&style=for-the-badge)](https://github.com/nikolastama/oplus-camera-los/releases/latest)
![Device](https://img.shields.io/badge/OnePlus_15-infiniti-F5010C?style=for-the-badge)
![ROM](https://img.shields.io/badge/LineageOS-24-167C80?style=for-the-badge)
![Root](https://img.shields.io/badge/KernelSU-module-555?style=for-the-badge)

</div>

A KernelSU module that adds OnePlus's own camera app from OxygenOS, with its full image processing. It's systemless: nothing on your ROM is modified, and removing the module removes everything it added.

## ✨ Features

- OnePlus photo processing: multi-frame HDR and deferred captures
- Every rear lens with smooth zoom, plus portrait, video and the front camera
- Thumbnails open in your normal gallery app
- Other camera apps keep working as before

> **Not included:** OnePlus-only extras that rely on OxygenOS services (OnePlus Gallery hand-off, HeyTap accessories, cloud AI features).

## 📦 Requirements

| | |
|---|---|
| Phone | OnePlus 15 (`infiniti`) |
| ROM | Official **LineageOS 24** |
| Root | **KernelSU** or **KernelSU-Next** |
| Metamodule | **meta-overlayfs** |

## 🚀 Install

### 1. Install meta-overlayfs

KernelSU needs a *metamodule* to mount module files. This module is tested with **meta-overlayfs**. Skip this step if you already have it.

1. Download the meta-overlayfs zip from the KernelSU project.
2. **KernelSU → Modules → Install** → pick the zip.
3. Reboot.

### 2. Install the camera module

1. Download `oplus-camera-los-vX.Y.zip` from **[Releases](https://github.com/nikolastama/oplus-camera-los/releases/latest)**.
2. **KernelSU → Modules → Install** → pick the zip. The installer checks your phone and ROM, and stops with a message if anything is missing.
3. Reboot.

### 3. Turn off "Umount modules"

If KernelSU unmounts modules for an app, that app can't see the camera. Turn the option off for these two apps:

| App | Where |
|---|---|
| **Camera** (`com.oplus.camera`) | KernelSU → Superuser → Camera → App Profile → **Umount modules: off** |
| **Your launcher** (e.g. Trebuchet) | Same place. Only needed if *Umount modules by default* is on in KernelSU settings |

Using Zygisk Next, Hide My Applist or a denylist? Keep both apps off those lists too.

### 4. Open Camera 🎉

**Update:** flash the new zip over the old one and reboot.
**Remove:** delete the module in KernelSU and reboot. The app and all its changes go away, and your photos stay.

Something wrong? Press the module's **Action** button to save a debug bundle, then see [Troubleshooting](docs/TROUBLESHOOTING.md).

## 📚 Documentation

| | |
|---|---|
| [Install](docs/INSTALL.md) | Full install, update and removal details |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Debug bundle and common problems |
| [Architecture](docs/ARCHITECTURE.md) | How it fits into LineageOS's camera stack |
| [Patches](docs/PATCHES.md) | Every change made to the app, SDK and libraries |
| [Reverting](docs/REVERTING.md) | How to undo each change |
| [Building](docs/BUILDING.md) | Build the zip yourself from a firmware dump |
| [Maintaining](docs/MAINTAINING.md) | Moving to new OxygenOS or LineageOS builds |
| [Changelog](docs/CHANGELOG.md) | What changed in each version |
| [Security](SECURITY.md) | What the module loosens, and debug-bundle privacy |

<details>
<summary><b>Repository layout</b></summary>

```
module/     scripts that run on the phone (install, boot, action button, uninstall)
overlay/    permission and shared-library XMLs
prebuilt/   our own small binaries (camera-layer wrapper, framework stubs)
tools/      build_module.py (firmware dump → zip), patches, analysis helpers
tests/      checks that need no firmware (patches vs diffs/, shell helpers, wrapper build)
diffs/      one diff per app/SDK patch, for review
history/    scripts and config of every released version
docs/       documentation
```

To review the code, start with `module/` and `SECURITY.md`, then `tools/patches.py` next to `diffs/`. `tests/` replays every recorded diff, checks the shared shell functions and rebuilds the wrapper byte for byte; GitHub runs it with `black`, `ruff` and a syntax check of every script on each push.
</details>

## ⚖️ License & credits

The scripts, tools and documentation are under the [Apache License 2.0](LICENSE). The OnePlus camera app, SDK and libraries in the release zip are OnePlus/OPPO property, taken unmodified or patched from OxygenOS `CPH2745_16.0.10.601`. They aren't covered by this license, and they aren't stored in this repository's source.

Based on the camera port in the OP15InfinityX device trees. Thanks to the LineageOS team for `infiniti` and `oplus-fwk`, and to the KernelSU developers for meta-overlayfs.

Maintained by **Nikola**.
