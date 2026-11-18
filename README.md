<div align="center">

# 📷 OnePlus Camera for LineageOS

**The stock OnePlus 15 camera on official LineageOS 24.**

[![Download](https://img.shields.io/github/v/release/nikolastama/oplus-camera-los?label=download&style=for-the-badge)](https://github.com/nikolastama/oplus-camera-los/releases/latest)
![Device](https://img.shields.io/badge/OnePlus_15-infiniti-F5010C?style=for-the-badge)
![ROM](https://img.shields.io/badge/LineageOS-24-167C80?style=for-the-badge)

</div>

A systemless KernelSU module that brings the OxygenOS camera app, with OnePlus's full image processing, to LineageOS. Remove the module and everything it added is gone.

- OnePlus HDR and multi-frame processing
- All rear lenses, portrait, video and front camera
- Your gallery and other camera apps keep working

## Requirements

OnePlus 15 (`infiniti`) · official LineageOS 24 · KernelSU or KernelSU-Next · [meta-overlayfs](https://github.com/KernelSU-Modules-Repo/meta-overlayfs/releases/tag/v1.3.1) metamodule

## Install

1. Install [**meta-overlayfs**](https://github.com/KernelSU-Modules-Repo/meta-overlayfs/releases/tag/v1.3.1) in KernelSU → Modules, then reboot.
2. Download the zip from **[Releases](https://github.com/nikolastama/oplus-camera-los/releases/latest)**, install it in KernelSU → Modules, then reboot.
3. In KernelSU → Superuser, open the ⋮ menu and turn on **Show system apps**. Open **Camera** and turn **Umount modules** off. Do the same for your launcher if *Umount modules by default* is on.

**Update:** install the new zip over the old one. **Remove:** delete the module and reboot.

Problems? Press the module's **Action** button to save a debug bundle, then see [Troubleshooting](docs/TROUBLESHOOTING.md).

## Docs

[Install](docs/INSTALL.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Architecture](docs/ARCHITECTURE.md) · [Patches](docs/PATCHES.md) · [Building](docs/BUILDING.md) · [Changelog](docs/CHANGELOG.md) · [Security](SECURITY.md)

## License

Scripts, tools and docs: [Apache 2.0](LICENSE). The OnePlus camera app and libraries in the release zip belong to OnePlus/OPPO (from OxygenOS `CPH2745_16.0.10.601`) and are not part of this repository.

Based on the OP15InfinityX camera port. Thanks to LineageOS and the KernelSU developers.

Maintained by **Nikola**.
