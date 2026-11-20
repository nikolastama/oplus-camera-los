# Changelog

## v0.37 (stable: v0.37-beta to beta3)
Everything from the three betas below, unchanged since v0.37-beta3.

## v0.37-beta3 (OnePlus modes on camera 2 stay on the OnePlus layer)
- Some OnePlus modes open camera 2 (a second ID of the main rear sensor) with standard-mode sessions only. beta2's rule (a device that ran a OnePlus mode stays on the layer) never applied there, so those sessions ran on Qualcomm's HAL without OnePlus processing (seen in the beta2 debug bundle). The wrapper now also recognises the OnePlus camera by its own `com.oplus.*` session settings, which other apps don't set, and logs which ones a standard-mode session carried. Host test added.

## v0.37-beta2 (faster mode switches, self-test fixes)
- Mode switches: the OnePlus camera configures a short standard-mode session (op mode 0) between two of its own modes. The wrapper took that for another app and moved the camera to Qualcomm's HAL and back each time, closing and reopening the camera twice per switch (about 0.4 s, seen in the v0.37-beta debug bundle; the same since v0.32). A device that has run a OnePlus-mode session now stays on the OnePlus layer until it is closed; other apps open their own devices and are still moved. Host test added.
- Self-test: waits until the phone has finished start-up (3 minutes, no app compiling). The v0.37-beta report ran during the one-time precompile.
- Self-test: the second portrait shot presses the shutter again every 3 s until it is saved (the app ignores the key while still busy) and reports how long the shutter took to be ready. One press 2 s after the first shot was dropped and counted as a hang.
- Self-test: keeps the whole test in a 16 MB log buffer and saves it next to the report (`.log.gz`), so a failure can be traced without a second run; the buffer size is put back afterwards. A HAL restart names the signal it died from. The ROM line shows the build.

## v0.37-beta (less system-wide impact, privacy, self-test)
- Camera service no longer replaced: the fix for the shutter hanging after portrait / multi-frame shots moved from a fixed copy of the ROM's `cameraserver` (every app, re-made after each LineageOS update) into the wrapper, for OnePlus sessions only. A frame the HAL re-stamps older than the previous one is passed on 1 ns after it, with its `android.sensor.timestamp` result changed to match; frames Android exempts (reprocess, ZSL still capture) are left alone. No more "LineageOS was updated, flash again". Kill switch: `persist.vendor.camera.oplus_los.tsfix=0` (ARCHITECTURE.md, "Out-of-order frames").
- SELinux: rules only for `priv_app_36`, the domain the camera runs in. The duplicates for plain `priv_app` (34 rules) only reached other privileged apps and are gone; the camera's own rules are unchanged.
- Data folders the module creates are owned by the camera app (mode 2770) instead of open to everyone (0777), from the first boot on which the app exists. A second user's or work profile's camera keeps access (shared app group); the camera HAL keeps access to the vendor folders (camera group). LineageOS's own folders are untouched.
- `persist.vendor.camera.privapp.list` is set before boot completes, so a camera opened right after boot (lock screen) gets every lens.
- Privacy: OPPO's usage statistics (OplusTrack) are off (`camera_no_telemetry`). The camera tracked shutter presses, zoom, menu taps, filters and more, built each event on its report thread and tried to send it to an OxygenOS statistics provider that LineageOS doesn't have; OplusTrack also put its own crash-report handler in front of Android's. Now no session, no event building, no handler.
- Speed: the camera is precompiled once after the first boot (Jetpack ProfileInstaller installs its bundled baseline profile, then `speed-profile` compiles just that code). LineageOS only verifies preinstalled apps at boot, so it used to run interpreted/JIT until Android compiled it while idle and charging. Skipped if Android already compiled it; once per ROM build and APK.
- Settings: four items that do nothing on LineageOS are hidden (`camera_hide_dead_settings`): the two Quick launch entries (only OxygenOS's system services read them; LineageOS's double-press-power gesture replaces them, INSTALL.md), the privacy policy link (opens nothing without OxygenOS's statement page) and the user agreement (its target doesn't exist, so tapping it could crash the settings screen).
- Self-test: the Action button now offers a two-minute self-test (volume up): photo, two portrait shots in a row, front photo and video, then a log check for crashes, HAL restarts, lost frames and wrapper errors; report in Download, test shots deleted (TROUBLESHOOTING.md). Volume down or no key: the debug bundle, as before.
- Release builds come from source again (`tools/build_module.py`): its app decodes identically to the v0.36 release apart from the new patches.
- Maintenance: `tools/check_firmware.py` reports which patches still fit a newer OxygenOS dump without building anything. The layer's byte edits carry a unique context window, so an edit that moved in a newer build is found again (`--refresh-binpatch-context`).
- Install guide: how to make it the default camera for double-press power and the lock screen.
- `diffs/` regenerated from a fresh decode: adds the missing records for `restrict_exported_components`, `camera_scoped_props` and `stubs_scoped_props`, and the new patch.
- Tests: the timestamp fix driven like the provider and the layer do (`tests/oemwrap_host_test.c`), folder ownership, policy scope, update from v0.36 (old `cameraserver` copy removed from the metamodule copy).

## v0.36 (lighter in the background)
- Boot watchdog: reads only the small crash log every 30 s for its 10 minutes, and the full log only when the camera HAL (re)starts, instead of dumping the whole log twice every 30 s.
- Debug button: the second press puts back the logging settings the first press changed (verbose camera/HAL logs, raw frame dumps, 16 MB log buffers) instead of leaving them on until the next reboot.
- Boot: data folders are relabelled, and the metamodule copy cleaned, only when needed instead of on every boot.

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
