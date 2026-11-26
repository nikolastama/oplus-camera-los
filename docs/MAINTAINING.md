# Maintaining: new blobs, new LineageOS builds

There are two kinds of update:

- **A new camera firmware** (new app/SDK). You rebuild the module from the ColorOS firmware LineageOS takes its blobs from; app, libraries and HAL should come from one build.
- **A new LineageOS build**, especially when LineageOS moves `infiniti` to newer ColorOS vendor blobs. The module may need its install-time fixes, layer edits or dependency lists checked against the new ROM.

Most problems show up at build or install time, because every patch checks what it patches.

---

## A. New ColorOS camera firmware

1. **Extract** the new firmware (`my_product`, `odm`, `system_ext`, `system`, `vendor`) with SELinux labels (`odm/config/odm_file_contexts`, BUILDING.md). Check that its build fingerprint matches LineageOS's blob source (`lineage_infiniti.mk`, `BuildFingerprint`).
2. **See what still fits:** `python3 tools/check_firmware.py --dump <dump> --apktool apktool.jar` checks every part without building: firmware files, the camera app's files with their fixups and labels, the APS edit, install-time fixes, the symbols the wrapper needs, and every app/SDK patch on a fresh decode. `OK` items need nothing; fix each `FAIL` as below.
3. **Run the build** (docs/BUILDING.md). For each failure:
   - **Smali patch fails** (`anchor not found …`): the app was re-obfuscated. Each function in `tools/patches.py` documents what it patches and searches by a stable string (a log tag, a file path, a method signature). Find the new location with `grep -rn '<anchor string>' work/app/smali*`, then update the anchor or register names. Re-run.
   - **`camera_gallery_fallback`** finds the gallery check in `GalleryHelper` (`Util.<x>(Activity, String)Z` with `v3, v2`, then the `r1.a` flag before the method's return) and the deferred-save log in `CameraManager` (the supplier class that logs `onCaptureDeferPictureSaved, mbCreated: `). The URI must be in the register the hook uses. Check it in the smali.
   - **Native edits in the camera app's files** (`tools/app_blobs.py`, `BYTE_EDITS`): the P010 fix in `libAlgoProcess` sits after `AHardwareBuffer_lockPlanes()` in the `0x7fa30c0a` case; re-derive it with the planes and buffer descriptor offsets of the new build.
   - **APS client hash mismatch**: find the two dlopen strings `libHeifEncoderWrapper.so` and `libNativeWinBuffExchange.so` in the new `libAPSClient-cmd-jni.so`, then update `APS_TARGETS` and both hashes.
4. **Check the library set.** New camera builds can pull in new JNI libraries:
   ```sh
   python3 tools/deps.py …           # smali class/method references not satisfied by the framework
                                     # (LineageOS's oplus-fwk: hardware/oplus; add missing classes the app calls
                                     #  outside a try/catch to tools/smali-stubs/fwk/, never to LineageOS)
   python3 tools/linkcheck.py …      # undefined native symbols per library (BFS over DT_NEEDED)
   python3 tools/jnitab.py lib.so    # JNI tables, to map a Java native method to its library
   ```
   Add new libraries to `tools/selection.json` (firmware path → module path; app-side libraries go to `system_ext/lib64`), and check their DT_NEEDED closure: everything must be on LineageOS (its vendor/odm blobs, AOSP, APEX) or in the module.
5. **Permissions:** compare the new manifest's `uses-permission` list with `overlay/system_ext/etc/permissions/privapp-permissions-com.oplus.camera.xml`. A missing privileged permission stops boot (privapp enforcement), and the installer can't catch that.
6. **Diffs**: run `python3 tools/make_diffs.py --dump … --apktool …` and commit `diffs/` together with any patch change, so every modification stays reviewable and reversible. Add new changes to docs/REVERTING.md.
7. **Checks**: `python3 -m unittest discover -s tests` must pass (it replays every recorded diff).
8. **Version**: bump `version`/`versionCode` in `module/module.prop` (the ColorOS build in brackets).
9. Test with the checklist below.

## B. New LineageOS build / new vendor blobs

The module depends on these parts of the ROM. Check each after LineageOS changes blobs:

| Dependency | How it shows up if it changed | What to do |
|---|---|---|
| `ro.hardware.camera=oemlayer.v2` set by the device tree | installer: "ro.hardware.camera is not oemlayer.v2" (layer not installed) | Check `device/oneplus/infiniti`. Without it the layer can't be loaded. |
| LineageOS's `camera.oemlayer.v2.so` (required since v0.39) | installer: "This version needs a LineageOS build with ColorOS camera blobs" if it's missing | Nothing while it's there. If the layer's or UI library's edits stop fitting a newer build (installer: "OnePlus camera layer (LineageOS's): expected code not found", or `fixes.log`), re-derive them in `module/common.sh` (`LAYER_FIX_*`, `UILAYER_FIX_*`): the UI library's name and dlopen path are strings; for the zoom edit find `ZoomDivisionV2::Initialize`'s `stp wN, wzr, [x19, #0xf4]` and the load of wN before it. Run `tools/check_firmware.py` on the new files. |
| Qualcomm's camera3 structs change (new HAL blobs) | shutter hangs after portrait shots again; no `shutter … sent as` lines, or wrong values in them | Re-check the shutter/request/result offsets in `oemwrap.c` against `camera.qcom.so`'s logging (ARCHITECTURE.md, out-of-order frames), and the device-op slot of `process_capture_request` (`OP_PROCESS_CAPTURE_REQUEST`, 5 on this platform): disassemble `CameraDeviceSession::processOneCaptureRequest` in `camx.device-impl.so` and read the offset it loads from the device's ops table (`ldr xN, [ops, #0x28]` = slot 5). A wrong slot shows as no `sent as` lines ever. |
| `offlinecamera-service-impl.so` changes | installer: "… expected code not found, fix not applied"; `fixes.log`: "no longer has the expected code" | Find the `ldr wN,[xM,#0x1c]` that feeds `CamX::OsUtils::MemMap` after `HandleImporter::importBuffer` (size at `+0x1c`, fd at `+0xc`) and add a variant to the fixlib call in `customize.sh`. Without the fix: black photos. |
| LineageOS ships fewer or other camera app files | build: "N camera app files not in the dump"; app crashes loading a library | `tools/app_blobs.txt` is LineageOS's list from `ce5065b`; compare with the new firmware (`tools/check_firmware.py` → `appblobs`). Every file must sit under `odm/lib64` or `odm/etc/camera` (the two mounted folders, `MOUNTS`). |
| The camera app's files aren't mounted | self-test: "camera app files NOT mounted"; `mount.log` in the module folder | `post-mount.sh` loop-mounts `blobs.img` and lays its folders over `/odm` with overlayfs at KernelSU's post-mount stage. Check that KernelSU still runs module `post-mount.sh` scripts and the error in `mount.log` (the kernel's reason is in `dmesg`, `overlay:` or `erofs:`). |
| `libEIS` changes | installer: "libEIS SnapAlloc format: expected code not found" | Find the five `ldr w4,[xN,#0x2c]` that feed `ShareBuffer_CreateFromNativeHandle` and update `EIS_FIX_*` in `module/common.sh`. Without it: green/empty time-lapse videos. |
| `CameraHWConfiguration.config` changes (or LineageOS stops disabling FD) | installer: "Camera face detection (FDManager): expected code not found" | If the ROM already has `fdSupport = TRUE;`, drop the fix. Otherwise update the offset in `customize.sh` (`grep -b -o 'fdSupport *= FALSE;'`). |
| Any LineageOS update that changes a file the module keeps a fixed copy of | nothing for the user; `fixes.log` in the module folder (and the debug bundle) says "remade from the updated …" | Nothing: the copy is remade at boot. If it says "no longer has the expected code", that fix is off: re-derive it as above. |
| snapalloc handle layout | photos black again even though the fix applied | Re-check the width offset in the snapalloc private handle. |
| cameraserver starts stamping `com.oplus.packageName` (like Infinity X) | nothing breaks | The tag is then added twice with the same value; the SDK/wrapper patches become redundant. |
| SELinux policy changes | new `avc: denied` lines for `priv_app_36`/`hal_camera_default` in the debug bundle | Add narrow rules to `module/sepolicy.rule`, for `priv_app_36` only (the camera's domain; check `scontext` in the denial). |

## Test checklist (each release)

- [ ] Fresh install on a clean ROM, reboot: camera opens, Action-button bundle shows `OnePlus camera layer: LineageOS's, wrapped`, the `blobs.img` mount and both `oplus_camera_blobs` mounts with `same_process_hal_file` on `libAlgoProcess.so`, no `/vendor` overlay, `library fixes` all applied (offline service, face detection, libEIS, layer); data dirs owned by the camera app (`2770`) after the second boot.
- [ ] Self-test (Action button, volume up): every check passes, including both mounts.
- [ ] Update over the previous version: same as above; `metamodule copy` lists only `odm` and `system_ext` (no `bin`).
- [ ] About a minute after the first boot: debug bundle → `compiled code` shows `status=speed-profile`; logcat has no `OplusTrack` event lines.
- [ ] Portrait photo (and a multi-frame night shot): the shutter is ready again right after the shot; logcat may show `OplusCamLosWrap … sent as`.
- [ ] Photo in auto mode at each zoom preset, and pinch zoom; the thumbnail opens the final (sharp) image.
- [ ] Portrait, night, video (1080p/4K), front camera, mode switching.
- [ ] A third-party camera app (e.g. Instagram) and a Chromium browser (GPU process) still work.
- [ ] Remove the module, reboot twice: nothing `oplus`/`ocam` left in `/data` apart from photos (see INSTALL.md); browser and other cameras work.

## Signing key

The app is signed with the module key (`alias opluscam`). Keep the keystore and password safe and out of the repository (`.gitignore` blocks `*.jks`). Losing it only means users have to remove the old module before installing a build signed with a new key.
