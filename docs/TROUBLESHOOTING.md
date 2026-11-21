# Troubleshooting

## Self-test

Tap **Action** on the module in the KernelSU manager and press **volume up** within 10 seconds, with the phone unlocked. In about 2 minutes the self-test opens the camera, takes a photo, two portrait shots in a row (the shutter must be ready again), a front-camera photo and a short video, then checks the log for crashes, camera HAL restarts, lost frames and wrapper errors. The test shots are deleted again; the result is saved as `Download/oplus-camera-selftest-<time>.txt`. It uses the volume key as the shutter (the camera's default; if you changed **Volume button action**, set it back to **Shutter** for the test). Lens switching and zoom aren't covered.

## Debug bundle

Reproduce the problem, then tap **Action** on the module in the KernelSU manager (volume down, or wait 10 seconds). That saves `Download/oplus-camera-debug-<time>.tar.gz` without changing anything on the system. It contains:

- `summary.txt`: module version, layer files, mounts on `/vendor`, `/odm` and `/system_ext`, overlay layers, directory labels, metamodule copy contents, recent SELinux denials touching module paths, library-fix status, data-dir labels;
- `logcat-all.txt`, `logcat-crash.txt`, tombstones, `dumpsys media.camera`, `getprop`, package dump, the HAL's camera log (`cam_alog`) and hashes of the relevant vendor libraries.

Removing the module deletes these bundles. A bundle can contain device identifiers and details about other apps, so look through it before posting it publicly (see [SECURITY.md](../SECURITY.md)).

## Common problems

| Symptom | Cause / fix |
|---|---|
| Camera closes immediately; log shows `Unable to open '/system_ext/priv-app/OplusCamera/OplusCamera.apk'`, or a crash in `handleBindApplication` with `Resources.getConfiguration()` on a null object | KernelSU unmounts modules for the camera. Turn off **Umount modules** for `com.oplus.camera` (and check Zygisk denylists). |
| No camera icon | Same for your launcher. |
| Zoom buttons do nothing / glitchy lens switching; log full of `m_pOplusCbOps is NULL` | The OnePlus layer isn't loaded. Check `summary.txt` → `layer`. If files are missing, look at the install log (dependency missing?) or `oemlayer_disabled` (watchdog). Reinstall the module. |
| Black photos | Offline-service fix not applied (`summary.txt` → library fixes). See MAINTAINING.md B. |
| HDR photos blurry / IPE crash | libAlgoProcess fix not applied. |
| Log shows `Failed to open DSCA library` / `Handle is NULL for DSCA Library loading` | The OFE helper-library fix isn't active: `summary.txt` → `OFE helper path` must show `2f6f646d`, and `/odm/lib64/libdscaalgo.so` and `libcamxtintlessalgo.so` must exist. Check the install log ("OFE helper libraries (DSCA)") and `ofe_dsca_disabled` (watchdog). Without it the camera works as before, without Qualcomm's DSCA tone-mapping stage. |
| Shutter stays busy after a portrait or multi-frame photo until you leave and reopen the app; log shows `Camera3-Stream: returnBuffer: … is not increasing` and `onCaptureBufferLost` | The wrapper's timestamp fix is off or not active: `summary.txt` → `frame-timestamp fix` must not show `0`, and the OnePlus layer must be installed. If logcat shows `… is not increasing` without `OplusCamLosWrap … sent as` lines, send a debug bundle (ARCHITECTURE.md, out-of-order frames). |
| Browser (Chromium) won't open, "GPU process isn't usable"; other apps' camera flaky | Something overlays `/vendor`. `summary.txt` → overlay mounts must have no `/vendor` line. Old module versions left files in the metamodule copy; v0.28+ removes them. Another module shipping `system/vendor` causes the same. |
| Thumbnail opens a blurry photo | The gallery opened the quick JPEG; the final image replaces it a few seconds later. The hand-off waits up to 8 s; very heavy shots can take longer. |
| Black preview after switching video resolution/frame rate; log: `Unable to set buffer count for stream N … (-38)`, then `Unable to connect to native window … (-22)` | Encoder buffer request too large (fixed in v0.31). If it comes back, look for `max_buffers … -> 40` from `OplusCamLosWrap` in the log and compare it with the HAL's request. If you raised `persist.vendor.camera.oplus_los.encbuf`, lower it again (`setprop persist.vendor.camera.oplus_los.encbuf ""`). |
| Stutter or dropped frames in 4K60 / stabilised video | Try a larger encoder cap: `setprop persist.vendor.camera.oplus_los.encbuf 48` (then 56), restart recording, and compare the dropped-frame counters in `dumpsys media.camera` and the frame timestamps of the file (e.g. `ffprobe -show_frames`). A black preview means the value is too high. |
| Other camera app (Instagram, Aperture …) misbehaves | Check the log for `OplusCamLosWrap: camera N: session moved to Qualcomm's HAL (stock path)`. If it's missing, routing is off (`persist.vendor.camera.oplus_los.route`) or the layer's symbols weren't found (`stock path symbols missing`). |
| Camera log floods (about 5,000 `I Chi` lines per second, `logd` busy) | Leftover debug settings, saved permanently: `persist.vendor.camera.oplus.enableLogging=true` and/or `persist.camera.logWarningMask=0xffffffff` (the module's debug run only sets them until the next boot). Remove them as root: `resetprop -p -d persist.vendor.camera.oplus.enableLogging` and `resetprop -p -d persist.camera.logWarningMask`, then reopen the camera. Normal is about 600 lines per second with the camera open. |
| Photo missing, or the gallery shows only the quick JPEG (Hi-Res at 12 MP), after the app was killed (swiped away, force-stopped, debug scripts) | The final image is produced when the camera closes normally or the thumbnail is opened. Killing the app drops the unfinished job; its leftovers stay in `Pictures/.camera_cache` (`*_tmp.jpg`, `*_quick.jpg`). Close the camera with Home before killing it. |
| Camera HAL restarts (tombstone in `vendor.qti.camera.provider-service_64`, `ExtensionModule::RecoveryThread`) | CHI's own recovery after a stuck request. Send the bundle. |

## Known log noise (harmless)

These come from the vendor blobs expecting OxygenOS hardware or services. They don't affect photos:

- `camxncsintftofsensor … Invalid State`, `RequestNCSService() Failed`: camx can't load a ToF library through its NCS interface. Autofocus still gets the ToF distance another way (`ALGO_AF … tofdistance`).
- `NCS ColorSensor front handle is NULL`, `PopulateFlickerSensorFrontData … NULL`: there is no front color/flicker sensor. The vendor config disables NCS types 33 and 36.
- `ALGO_AWB … IsCsDataValid() data of color sensor is zero!` on the first 15–25 requests after the camera opens: the rear color sensor (tcs3449 `rgb_rear`, NCS type 34) is registered at open and streams at 10 Hz, so its first sample arrives about 1 s later. After that the message stops. Rear color, flicker and spectral data (types 34/35/40) reach AWB on LineageOS (verified 2026-11-20). The sensor reads near zero in a dark room or with the phone camera-down, so test in light.
- `GetDataAsync() Unsupported sensor type`, OIS/gyro queries in SAT reprocess.
- First camera launch after a reboot only: `remote_handle_open_domain: dynamic loading failed for file:///libQnnHtpV81Skel.so … 0x80000406` and `QnnDsp <E> Failed to load skel, error: 1002`. Three of the app's NPU (QNN HTP) sessions start in the same millisecond while the DSP process is still being created, and all three fail. A session 0.2 s later loads the same library normally, and every later launch is clean. The skel files in `/odm/lib/rfsa/adsp` are byte-identical to OxygenOS. LineageOS's FastRPC client (`libcdsprpc.so`) is from a different OnePlus build; whether stock shows the same race is unverified. Photos and video are unaffected (verified 2026-11-21).
- `coupleHdrLoadLibrary() can not find function hdrApiSetInputMode / hdrApiSetNaturalToneTag`: OxygenOS's `libarcsoft_hdr_couple_api.so` lacks them too.
- App: `VendorTagDescriptor: lookupTag … does not exist`, `Failed to find provider info for com.oplus.customize…`, `Access denied finding property "vendor.…"`, `A resource failed to call HardwareBuffer.close` (OnePlus app behaviour, reported only on builds with CloseGuard enabled), `Expect face scores and rectangles to be non-null`.
- ArcSoft libraries log ordinary progress at error level (`ArcSoft_C_LN`). OnePlus's own algorithms do the same: `NAManager … OCCEInit()/OCCERelease()`, `ALGO_CS … camCSInit()`, `MVG`, `LibHIS`, `hybridraw: GLEngine::destroy`.
- HAL: `OsenseNativeProxyUx: could not get service(osensemanager)` (OxygenOS performance service), `IsGenericCamera() Vendor tag GenericCamera is null`, `MultispectralSensorConfig … missing`, `ReleaseOFESingleActionManagerInstance() No Instance to release`, `OplusRemoveUadThread() Not SetUadThread`.
- App when it closes or switches mode: `ConsumerBase … abandonLocked`, `adspmsgd … 0x8000040d … exiting` (DSP log reader stopping), `Failed to find provider info for com.color.provider.removableapp`.
