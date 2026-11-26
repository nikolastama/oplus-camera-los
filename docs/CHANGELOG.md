# Changelog

## v0.39 (stable: ColorOS camera app, for LineageOS's ColorOS 11.C.80 builds)
LineageOS's builds for `infiniti` moved to ColorOS 11.C.80 blobs (`CPH2745_17.0.1.201(EX01)`, new camx HAL): they ship the OnePlus camera layer themselves and no longer ship the camera app's own libraries and data. The module now brings the **ColorOS camera app from that same firmware** (7.006.295), so the app, its SDK, its libraries and LineageOS's camera HAL all come from one build. Tested on a phone in every mode.
- Requires a LineageOS build with ColorOS blobs: the installer stops with a message if the ROM doesn't ship `/odm/lib64/hw/camera.oemlayer.v2.so`. The module's own OxygenOS layer, its byte edits (`tools/binpatches.json`) and the OFE/DSCA fix are gone (LineageOS ships `libdscaalgo` itself).
- Camera layer: the module wraps **LineageOS's layer**. Private copies of the ROM's layer and UI library are made at install with four edits (UI library name and dlopen path, the layer's dependency on it, and the zoom fix re-derived for this build: `ldr w8,[x9,#0x124]` → `mov w8,wzr`); the wrapper takes the `hw/` path. The wrapper's assumptions about Qualcomm's HAL were re-checked on the new blobs (device-op slot 5, notify/request/result offsets, layer symbols, `HMI` size): unchanged. The UI layer's `InitPackageName` fallback isn't carried over (the SDK and the wrapper add the package tag).
- Camera app files: the ~90 OnePlus/ArcSoft libraries (`libAlgoProcess`, the `com.oplus.node.*` APS nodes …) and ~700 models/LUTs/configs on `/odm` that LineageOS dropped (`ce5065b`) come from the ColorOS firmware (`tools/app_blobs.txt`), with the fixups LineageOS applied to them; the portrait-blur license is one of them (the `camera_blur_license_path` patch is gone). The `libAlgoProcess` P010 fix is made at build time, re-derived for ColorOS's library (offset `0x21d2f8`). `libAlgoProcess` and `libAlgoInterface` link the offline camera service's client library at V2; LineageOS ships only V3 (and runs ColorOS's V2-built service on it), so both are pointed at V3: without it `libAlgoProcess` didn't load and the camera crashed in `APSClient.createClient`.
- Size: those files are 2.4 GB, more than meta-overlayfs's default 2 GB image for all modules holds. They now stay **in the module folder**, in a read-only erofs image (`blobs.img`, 1.66 GB: lz4hc, tails packed, duplicates stored once) that meta-overlayfs doesn't copy into its image; `post-mount.sh` loop-mounts it and lays its folders over `/odm/lib64` and `/odm/etc/camera` as read-only overlays once the metamodule has mounted everything (`mount.log`). A folder can't be used: Android 16's kernel refuses overlay layers on `/data`'s case-insensitive-capable f2fs. The installer's image check counts only what meta-overlayfs copies (about 0.3 GB). Each file carries its label from the ColorOS odm image inside the image: most libraries are `same_process_hal_file` there (the app loads them through the SP-HAL namespace), the models `vendor_configs_file`.
- Install: about 15 s. The zip stores the image, the APK and the jars uncompressed, so the installer copies them instead of inflating them, and labels nothing file by file.
- Not shipped: `odm/etc/camera/livephoto_coverenhancer/` (37 MB), which ColorOS's Gallery uses and nothing in the camera names.
- App and SDK patches re-derived for the ColorOS app: the gallery fallback, telemetry, scoped-props and face-beauty patches now find their places by code shape instead of obfuscated names (`camera_scoped_props` covers three COUI helpers; `sdk_facebeauty_path` points `ApsUtils.getCameraAppLibDirectory()`'s fallback at `/system_ext/lib64` in the SDK and the adapter).
- Framework: `OplusHansFreezeManager` and `OplusMaterialUtil` are added to the stubs jar as no-ops (the ColorOS app calls them outside any try/catch; LineageOS's `oplus-fwk` has neither). Every other OnePlus framework class the app, SDK and adapter use is in `oplus-fwk` with the members they call. `SurfaceExtImpl.nativeSetMaxDequeuedBufferCount` is declared with the signature ColorOS's `liboplusgui_jni` registers (`(JI)I`, not `(JI)V`): with the old one its `JNI_OnLoad` failed and aborted the camera at launch (`stubs_surfaceext_jni`). The other JNI libraries the module ships register signatures the jar declares.
- Libraries: new `libApsAICompositionJni`, `libApsAITranslateJni` and `libPalette-Jni`; `liboplus_10bitHeif` and `liboplusHeifDecoderImpl` complete the HEIF converter's dependencies (`libatlasservice`'s `libostatslog` is LineageOS's own, the same file as ColorOS's). Dolby effect 5.0.
- `LosProps`: ColorOS 17 values (`ro.build.version.oplus.api` 40, `sub_api` 25, `oplusrom` V17.0.0).
- Offline camera service: the black-photo fix (`+0x1c` → `+0x2c`) re-derived for ColorOS's build (different code, same bug).
- New fix for ColorOS's `libEIS`: five format reads from snapalloc handles at `+0x34` instead of `+0x2c` (green/empty time-lapse videos). Found by Infinity X; LineageOS's `libEIS` has exactly the code their fix was made for.
- After a LineageOS update, `post-fs-data.sh` adapts the installed module before anything is mounted (`adapt_to_rom`: adds the `libEIS` fix when needed); the remaining copies are remade from the new files (`refresh_fixes`). meta-overlayfs's image is mounted early if needed, so that boot already uses the new files; the crash watchdogs skip a boot that runs on outdated files.
- Self-test: checks that both mounts are in place. Debug bundle: the mounts, `mount.log` and two sample labels.
- Build: tools write LF line endings on Windows too (apktool runs with an LF line separator).

## Review fixes (also in v0.39)
- LineageOS updates: the module's fixed copies of ROM files (offline camera service, `libAlgoProcess`, `libcamxofehwl` with its tintless helper, `CameraHWConfiguration.config`) were snapshots of the ROM installed at the time and kept hiding the ROM's files after a LineageOS update; installing the module again didn't help, because it copied the previous version's copies. Each copy now records its ROM file, that file's sha256 and the edit. At boot, before anything is mounted, `post-fs-data.sh` compares the ROM files and remakes a copy whose file changed, with the same edit and checks, without asking anything of the user (`fixes.log` records it); a fix whose bytes are gone from the new file is switched off. The remade files also go into meta-overlayfs's own copy of the module, which was never updated after install. The installer always patches the ROM's own file: `/vendor` is read directly, and `/odm` files hidden by the module are read from a second read-only mount of the odm partition.
- Wrapper: the HAL's buffer callbacks (`request_stream_buffers`, `return_stream_buffers`) are always passed through to the provider. The provider fills them in only after `initialize()`; the wrapper copied their empty value at that moment, the OnePlus layer offers both to the HAL regardless, and the provider crashed in `HALDevice::RequestStreamBuffers` at the first preview of the ColorOS camera. Rebuilt with LLVM 18.1.3's official release (`build.sh` now leaves out the build ID and sets inline atomics explicitly, so any clang/lld 18.1.3 gives the same loaded bytes).
- Wrapper, frame-timestamp fix: exempt (ZSL still / reprocess) and unknown frames now move the "newest timestamp" mark forward too. The camera service remembers every buffer's timestamp, so an ordinary frame after a newer exempt frame was still dropped as "not increasing". Host test added.
- Wrapper: a device whose backend switch could reopen neither side refuses calls with an error instead of crashing the camera HAL on the next request, flush or `dumpsys`. Callback slots the camera service leaves empty are no longer offered to the OnePlus layer as implemented. The package-tag lookup is safe when two cameras configure at once. Shutter-message copies use the full `camera3_notify_msg_t` size (40 bytes). Host tests added; `prebuilt/camera.oemlayer.wrap.so` rebuilt (clang/lld 18.1.3).
- Metamodule copy: removals (watchdog) are also pruned from `service.sh` when meta-overlayfs hasn't mounted its image yet during `post-fs-data.sh`; before, the prune could be marked done without ever reaching the copy (meta-overlayfs mounts its image only after module `post-fs-data` scripts).
- The installer also recognises a ROM that ships the OnePlus layer on `/odm`, and its fallback byte search takes seconds instead of minutes (`find_hex`, common.sh).
- Gallery hand-off: tapping the thumbnail no longer discards an already-queued "final image saved" notice (which made it wait the full 8 s); only its own timeout is cancelled.
- `LosProps.getInt`/`getLong` return the default for a value that isn't a number, as `SystemProperties` does.
- Action button: a debug run interrupted by a reboot no longer blocks the button ("still pending" forever).
- Installer: the read-only second mount of the odm partition (`/data/local/tmp/ocam-odm-ro`) is unmounted and its folder removed at the end of the install. It was looked up in `$(...)` subshells, so the installer never saw that it had mounted it: the mount stayed until the next reboot and the empty folder stayed for good. `post-fs-data.sh` and `uninstall.sh` remove a folder left by an earlier build.
- Removal also deletes the camera app's thumbnail cache, `Pictures/.camera_cache` (photos and videos in `DCIM` are kept).
- Removal: deletes the self-test's `.log.gz` too; only crash reports of the camera's own processes are deleted (not system-wide traces that mention it); relabelled LineageOS folders are restored with `restorecon`.
- SELinux: dropped the two `cameraserver` rules for `/data/system/camera_rus` (only Infinity X's modified camera service read it).
- Self-test: test media are also removed from MediaStore by their real path.
- Build: the keystore password is masked in printed commands; `MANIFEST.sha256` lists every file in the zip. `strip_oem_component_permissions` and `camera_scoped_props` fail when they change nothing.

## v0.38 (stable: v0.38-beta and beta2)
Everything from the two betas below, unchanged since v0.38-beta2. Tested on a phone in every mode.
- Build: `prebuilt/camera.oemlayer.wrap.so` is now byte-identical to what `tools/oemwrap/build.sh` produces with Ubuntu 24.04's clang/lld 18.1.3, so the CI byte check passes again (same code as beta2; only `.comment`, one symbol-table value and the build-id changed). Self-test test: its start-up wait no longer depends on the CI machine's uptime or a stray `pidof` match.

## v0.38-beta2 (frame-timestamp fix actually active)
- Fix: the front camera froze after a photo with a face (v0.38-beta). With face detection on, a front face shot becomes a 7-frame burst built from frames taken just before the shutter, so its shutter timestamps go backwards (seen on the phone: frames 58–64, two of them re-stamped +9 ns by the layer); cameraserver dropped the last frames ("timestamp … is not increasing") and the app waited forever. The wrapper's frame-timestamp fix (v0.37) exists for exactly this, but it hooked `process_capture_request` in AOSP's device-op slot 4. Qualcomm's `camera3_device_ops` has one entry more before it, so requests arrive in slot 5 (`camx.device-impl.so` calls `ops+0x28`); the hook never ran, no request was ever recorded, and every shutter passed through as "unknown" (a diagnostic build on the phone showed `known=0`, `last_ts=0` for every frame). The hook now sits in slot 5. This also makes the fix work for the rear multi-frame shots it was written for. Host test: requests go through the ops table as the provider does, the slot is checked, and the burst captured on the phone is replayed.
- Tested on a phone: front face shots save again, and every mode was run (photo at each zoom, portrait, night, master/pro, hi-res 50 MP, text, tilt-shift, long exposure, 1080p120 video without dropped frames, slo-mo, pro video, dual-view, time-lapse).
- Docs (TROUBLESHOOTING.md): the rear color sensor does reach AWB (the "color sensor is zero" lines are only the first second); a log flood from permanently saved debug properties and how to remove them; killing the app drops the shot still being processed; the first-launch-after-boot NPU (`libQnnHtpV81Skel.so`) message and the CoupleHDR warning are harmless.

## v0.38-beta (face detection back on, DSCA, tunable encoder cap)
- Image quality: OnePlus's face-detection manager is back on. LineageOS's blob extraction sets `[FDManager] fdSupport = FALSE` in `CameraHWConfiguration.config`, so the OnePlus camera had no face-priority exposure, focus or white balance and no face data for portrait / multi-subject modes (`AdjustFaceRectangle failed` on every frame, seen on a phone). An install-time fix of the ROM's file (overlaid copy on `/odm/etc/camera`) restores OxygenOS's `TRUE`. It applies to every camera app; see REVERTING.md to keep LineageOS's setting. Not yet tested on a phone.
- Image quality: Qualcomm's offline front end now finds its SWDSCA library (the DSCA stage of its multi-pass HDR tone mapping). LineageOS doesn't ship `libdscaalgo.so` and the OFE loads it from a hard-coded `/vendor/lib64` path, so the stage never ran ("Handle is NULL for DSCA Library loading", formerly listed as harmless). The module ships OxygenOS's copy on `/odm/lib64`, and an install-time fix of the ROM's `libcamxofehwl.so` (copy on `/odm/lib64`, shadowing by search order) points that path prefix at `/odm/lib64`, with a copy of the ROM's own `libcamxtintlessalgo.so` beside it (the prefix's only other user). All three or none; a boot watchdog removes them after two HAL crashes through them (`ofe_dsca_disabled`). Self-test and debug bundle report it. Not yet tested on a phone.
- Video: the wrapper's encoder buffer cap (40) can be tuned for testing 4K60 / stabilised video without a rebuild: `persist.vendor.camera.oplus_los.encbuf` (8–63, `0` = no cap). Each encoder stream logs its request and the cap. Host test added. `prebuilt/camera.oemlayer.wrap.so` for this beta was built with clang/lld 18.1.6 (the toolchain bundled in zig 0.13, used as plain clang with the flags Ubuntu's driver passes); built from the v0.37 source it gives the same code, data, symbols and relocations as the 18.1.3 build, only `.comment` and the build-id differ, so `tests/test_build.py`'s byte comparison fails until it is rebuilt with `tools/oemwrap/build.sh` on Ubuntu 24.04.

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
