# Changelog

## v0.35 (no more hang after a shot)
- Fix: the shutter could stay busy after a portrait or other multi-frame photo until the app was paused. OnePlus's HAL reuses frames from just before the shutter, so one frame's timestamp goes backwards; stock Android's camera service then drops that frame's buffers and the app waited for the 7th of 7 frames. An install-time fixed copy of the ROM's `cameraserver` returns those buffers, as Android already does for ZSL captures (ARCHITECTURE.md, "Out-of-order frames").
- The fixed `cameraserver` is tied to the ROM build it was made from: after a LineageOS update the module drops it and asks to be flashed again.
- Debug bundle: shows the camera service fix state.

## v0.34 (clean-up)
- Wrapper: the session parameters with the package tag were one buffer shared by every camera, so two cameras configuring at the same time could free each other's. Each device now keeps its own copy (freed on its next configure or on close), and the HAL callback registration shared by all devices changes under a lock.
- Scripts: module paths and the metamodule clean-up live in one shared `common.sh` instead of three copies.
- Security: the seven components the camera only uses itself (`EponaProvider` and six more) are no longer reachable by other apps (`restrict_exported_components`, SECURITY.md). The release APK has these seven values changed in its compiled manifest and is signed again with the module key (same certificate: it updates in place, settings are kept).
- Build: `--out` no longer deletes the whole folder it's given, the keystore password comes from `OPLUS_CAMERA_KS_PASS` instead of the command line, and the zip is reproducible (fixed timestamps and order).
- Build: patches read and write files byte for byte (bytes that aren't valid UTF-8 were silently dropped before); an unused zoom patch superseded by `binpatches.json` is removed.
- Repository: `tests/` (patches replayed against `diffs/`, shell helpers, wrapper rebuilt byte for byte), a GitHub check on every push, and `.gitattributes` so a Windows checkout can't break the scripts with CRLF line endings.

## v0.33 (debug bundle)
- Debug bundle: the camera's own processing logs (`cam_alog`) were left out whenever the newest file was over 40 MB, which debug logging reaches within a minute. The newest part of the file is now included.
- Debug bundle: the Action button's first press also sets 16 MB log buffers (until reboot), so the whole test session is kept instead of the last ~15 seconds.
- SELinux: two harmless probes from the camera app (`/sys/fs/selinux/enforce` reads during preview, a suspend-HAL lookup) are no longer logged as denials. Nothing new is allowed.
- Troubleshooting: the start-up crash seen with "Umount modules" on, and the remaining harmless log lines from a full mode tour, are documented.

## v0.32 (isolation)
- Other camera apps no longer run through OnePlus's camera layer: the wrapper reopens their sessions directly on Qualcomm's HAL (the stock LineageOS path) and clears the layer's HAL callbacks while they run. This fixes Instagram's shutter hanging (its JPEG was taken over by the layer's snapshot path) and Aperture failing after it. Kill switch: `persist.vendor.camera.oplus_los.route=0`.
- The OnePlus camera's props are answered inside its own process (`LosProps`) instead of being set system-wide; `system.prop` keeps only the capture-result queue size.
- Larger log buffers only in debug mode (`touch /data/adb/modules/oplus_camera_los/debug`).

## v0.31
- Video: switching resolution or frame rate could leave a black preview. OnePlus's HAL asked for 64 buffers on the video-encoder stream (1080p60 / stabilisation), more than a LineageOS encoder surface can hold with cameraserver's extra buffers, so the session was refused (−38, then −22 on retries). The wrapper caps encoder streams at 40 buffers.
- The wrapper is now built from `tools/oemwrap/build.sh` (same imports and behaviour, plus the cap).

## v0.30
- Debloat: the unused native-library copies inside the APK are dropped (APK 180 → 134 MB, zip 109 → 93 MB). OnePlus Gallery connection and multi-device remote services disabled.
- Removal also deletes the Action button's debug bundles from Download.
- Removal fully re-verified in a chroot simulation (app data, created dirs, labels, settings, persist props, UID-owned files, metamodule copy).

## v0.29
- Fix: the installer could take a stale copy of the OnePlus layer (from an old metamodule copy) for a ROM file and skip installing the layer. Zoom buttons broke and CHI recovery restarted the HAL. A layer file now counts as the ROM's only if no module provides it.

## v0.28
- Fix: meta-overlayfs keeps partitions at the top level of its module copy (`<copy>/vendor`). The cleanup now prunes those too, so the old `/vendor` overlay is gone and browsers/GPU apps work with the module installed.

## v0.27
- Diagnostics: the debug bundle lists mountinfo, overlay layers, hw-dir labels and modules shipping vendor/odm files. (A temporary SELinux workaround was removed again in v0.28.)

## v0.26
- Author and description updated.

## v0.25
- Prune files left in the metamodule copy by older versions (first pass, `system/` only).

## v0.24
- All HAL-side files moved from `/vendor` to `/odm` (search order) so `/vendor` is never overlaid; merged directories get the ROM's SELinux label.
- Capture-result queue set to 8 MB (v0.23's value of 1 made every result go through binder: `-28` overflows, 13 s stalls).
- OnePlus-only receivers/services disabled; maintainer README; patch library extended.

## v0.23
- Thumbnail waits for the final deferred image (the quick JPEG looked blurry until zoomed).
- Portrait-mode crash: result-queue sizing (refined in v0.24). DSP library watch SELinux rule.

## v0.22
- Viewfinder zoom: OemLayer follows `ANDROID_CONTROL_ZOOM_RATIO`.

## v0.21
- HDR / 10-bit processing: libAlgoProcess P010 chroma-plane fix (blurry fallback shots, IPE crash).
- Thumbnail opens photos in the default gallery.

## v0.20
- Black photos: offline camera service reads the buffer size from LineageOS's snapalloc handle layout.

## v0.1 – v0.19
- Initial port from the OP15InfinityX trees retargeted to OxygenOS 16.0.10.601: app/SDK patches, framework stubs, shared-library setup, privapp permissions, data directories and labels, the OnePlus camera layer and its dependencies, the session package-tag wrapper, the install-time fix mechanism, uninstall cleanup and the debug bundle.
