# Maintaining: new blobs, new LineageOS builds

There are two kinds of update:

- **A new OxygenOS camera** (new app/SDK/layer). You rebuild the module from a newer OxygenOS firmware.
- **A new LineageOS build**, especially when LineageOS moves `infiniti` to newer ColorOS/OxygenOS vendor blobs. The module may need its install-time fixes, layer edits or dependency lists checked against the new ROM.

Most problems show up at build or install time, because every patch checks what it patches.

---

## A. New OxygenOS camera firmware

1. **Extract** the new firmware (`my_product`, `odm`, `system_ext`, `vendor`).
2. **See what still fits:** `python3 tools/check_firmware.py --dump <dump> --apktool apktool.jar` checks every part without building: firmware files, the layer's byte edits, the APS edit, install-time fixes, the symbols the wrapper needs, and every app/SDK patch on a fresh decode. `OK` and `MOVED` items need nothing (a moved byte edit is found by its stored context window); fix each `FAIL` as below.
3. **Run the build** (docs/BUILDING.md). For each failure:
   - **Smali patch fails** (`anchor not found …`): the app was re-obfuscated. Each function in `tools/patches.py` documents what it patches and searches by a stable string (a log tag, a file path, a method signature). Find the new location with `grep -rn '<anchor string>' work/app/smali*`, then update the anchor or register names. Re-run.
   - **`camera_gallery_fallback`** anchors on `GalleryHelper.p()` (the early return when OnePlus Gallery is missing) and on the defer-save handler in `CameraManager` (the method that logs `onCaptureDeferPictureSaved`). The URI must be in the register the hook uses. Check it in the smali.
   - **binpatch fails** (`does not fit this build`): open the new library in a disassembler. The `why` text in `tools/binpatches.json` names the function and instruction:
     - renames: find the same strings in `.dynstr` and make the same 1-byte edit;
     - zoom: in `OemLayer::ZoomDivisionV2::Initialize`, find the load of the SAT config flag (`ldr w9,[x9,#0x11c]` in 16.0.10.601) and replace it with `mov w9,wzr`;
     - `InitPackageName`: re-create the fallback or drop it (the SDK and wrapper already add the tag).

     Then update `offset`/`orig`/`new` and the two hashes, and store the new context windows with `python3 tools/build_module.py --refresh-binpatch-context --dump <dump>`.
   - **APS client hash mismatch**: find the two dlopen strings `libHeifEncoderWrapper.so` and `libNativeWinBuffExchange.so` in the new `libAPSClient-cmd-jni.so`, then update `APS_TARGETS` and both hashes.
4. **Check the library set.** New camera builds can pull in new JNI libraries:
   ```sh
   python3 tools/deps.py …           # smali class/method references not satisfied by the framework
   python3 tools/linkcheck.py …      # undefined native symbols per library (BFS over DT_NEEDED)
   python3 tools/jnitab.py lib.so    # JNI tables, to map a Java native method to its library
   ```
   Add new libraries to `tools/selection.json` (firmware path → module path; app-side libraries go to `system_ext/lib64`).
5. **Permissions:** compare the new manifest's `uses-permission` list with `overlay/system_ext/etc/permissions/privapp-permissions-com.oplus.camera.xml`. A missing privileged permission stops boot (privapp enforcement), and the installer can't catch that.
6. **Diffs**: run `python3 tools/make_diffs.py --dump … --apktool …` and commit `diffs/` together with any patch change, so every modification stays reviewable and reversible. Add new changes to docs/REVERTING.md.
7. **Checks**: `python3 -m unittest discover -s tests` must pass (it replays every recorded diff).
8. **Version**: bump `version`/`versionCode` in `module/module.prop` (the OxygenOS build in brackets).
8. Test with the checklist below.

## B. New LineageOS build / new vendor blobs

The module depends on these parts of the ROM. Check each after LineageOS changes blobs:

| Dependency | How it shows up if it changed | What to do |
|---|---|---|
| `ro.hardware.camera=oemlayer.v2` set by the device tree | installer: "ro.hardware.camera is not oemlayer.v2" (layer not installed) | Check `device/oneplus/infiniti`. Without it the layer can't be loaded. |
| Layer dependencies present in `/vendor`/`/odm` (list in `customize.sh`) | installer: "OnePlus camera layer NOT installed, missing: …" | Ship the missing library on `/odm/lib64`, renamed if LineageOS has an incompatible one with the same name. |
| LineageOS starts shipping `camera.oemlayer.v2.so` itself | installer: "This ROM ships the OnePlus camera layer itself" | Our layer is skipped automatically; check the wrapper is still needed. |
| Qualcomm's camera3 structs change (new HAL blobs) | shutter hangs after portrait shots again; no `shutter … sent as` lines, or wrong values in them | Re-check the shutter/request/result offsets in `oemwrap.c` against `camera.qcom.so`'s logging (ARCHITECTURE.md, out-of-order frames), and the device-op slot of `process_capture_request` (`OP_PROCESS_CAPTURE_REQUEST`, 5 on this platform): disassemble `CameraDeviceSession::processOneCaptureRequest` in `camx.device-impl.so` and read the offset it loads from the device's ops table (`ldr xN, [ops, #0x28]` = slot 5). A wrong slot shows as no `sent as` lines ever. |
| `offlinecamera-service-impl.so` / `libAlgoProcess.so` change | installer: "… expected code not found, fix not applied" | Re-derive the fix (PATCHES.md, install-time fixes): find the same instruction sequence in the new file and update the pattern and offset in `customize.sh`. Without the fixes: black photos / HDR crash. |
| `libcamxofehwl.so` changes | installer: "OFE helper libraries (DSCA): expected code not found" | Find `"%s%s%s.%s\0/vendor/lib64\0"` in the new file, check by disassembly that it is still used only by the tintless and DSCA loads, and update the offset in `customize.sh`. Without the fix DSCA stays off (as on stock LineageOS); nothing breaks. |
| `CameraHWConfiguration.config` changes (or LineageOS stops disabling FD) | installer: "Camera face detection (FDManager): expected code not found" | If the ROM already has `fdSupport = TRUE;`, drop the fix. Otherwise update the offset in `customize.sh` (`grep -b -o 'fdSupport *= FALSE;'`). |
| snapalloc handle layout | photos black again even though the fix applied | Re-check the width offset in the snapalloc private handle. |
| `charger` / `sensorservice` AIDL versions | layer fails to load (`dlopen failed`, watchdog notification) | Adjust the DT_NEEDED version edit in `binpatches.json`. |
| cameraserver starts stamping `com.oplus.packageName` (like Infinity X) | nothing breaks | The tag is then added twice with the same value; the SDK/wrapper patches become redundant. |
| SELinux policy changes | new `avc: denied` lines for `priv_app_36`/`hal_camera_default` in the debug bundle | Add narrow rules to `module/sepolicy.rule`, for `priv_app_36` only (the camera's domain; check `scontext` in the denial). |

## Test checklist (each release)

- [ ] Fresh install on a clean ROM, reboot: camera opens, Action-button bundle shows the layer's 5 files, no `/vendor` overlay, `library fixes` both applied; data dirs owned by the camera app (`2770`) after the second boot.
- [ ] Update over the previous version: same as above; `metamodule copy` lists only `odm` and `system_ext` (no `bin`).
- [ ] About a minute after the first boot: debug bundle → `compiled code` shows `status=speed-profile`; logcat has no `OplusTrack` event lines.
- [ ] Portrait photo (and a multi-frame night shot): the shutter is ready again right after the shot; logcat may show `OplusCamLosWrap … sent as`.
- [ ] Photo in auto mode at each zoom preset, and pinch zoom; the thumbnail opens the final (sharp) image.
- [ ] Portrait, night, video (1080p/4K), front camera, mode switching.
- [ ] A third-party camera app (e.g. Instagram) and a Chromium browser (GPU process) still work.
- [ ] Remove the module, reboot twice: nothing `oplus`/`ocam` left in `/data` apart from photos (see INSTALL.md); browser and other cameras work.

## Signing key

The app is signed with the module key (`alias opluscam`). Keep the keystore and password safe and out of the repository (`.gitignore` blocks `*.jks`). Losing it only means users have to remove the old module before installing a build signed with a new key.
