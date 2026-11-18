# Troubleshooting

## Debug bundle

Reproduce the problem, then tap **Action** on the module in the KernelSU manager. That saves `Download/oplus-camera-debug-<time>.tar.gz` without changing anything on the system. It contains:

- `summary.txt`: module version, layer files, mounts on `/vendor`, `/odm` and `/system_ext`, overlay layers, directory labels, metamodule copy contents, recent SELinux denials touching module paths, library-fix status, data-dir labels;
- `logcat-all.txt`, `logcat-crash.txt`, tombstones, `dumpsys media.camera`, `getprop`, package dump, the HAL's camera log (`cam_alog`) and hashes of the relevant vendor libraries.

Removing the module deletes these bundles. A bundle can contain device identifiers and details about other apps, so look through it before posting it publicly (see [SECURITY.md](../SECURITY.md)).

## Common problems

| Symptom | Cause / fix |
|---|---|
| Camera closes immediately; log shows `Unable to open '/system_ext/priv-app/OplusCamera/OplusCamera.apk'` | KernelSU unmounts modules for the camera. Turn off **Umount modules** for `com.oplus.camera` (and check Zygisk denylists). |
| No camera icon | Same for your launcher. |
| Zoom buttons do nothing / glitchy lens switching; log full of `m_pOplusCbOps is NULL` | The OnePlus layer isn't loaded. Check `summary.txt` → `layer`. If files are missing, look at the install log (dependency missing?) or `oemlayer_disabled` (watchdog). Reinstall the module. |
| Black photos | Offline-service fix not applied (`summary.txt` → library fixes). See MAINTAINING.md B. |
| HDR photos blurry / IPE crash | libAlgoProcess fix not applied. |
| Browser (Chromium) won't open, "GPU process isn't usable"; other apps' camera flaky | Something overlays `/vendor`. `summary.txt` → overlay mounts must have no `/vendor` line. Old module versions left files in the metamodule copy; v0.28+ removes them. Another module shipping `system/vendor` causes the same. |
| Thumbnail opens a blurry photo | The gallery opened the quick JPEG; the final image replaces it a few seconds later. The hand-off waits up to 8 s; very heavy shots can take longer. |
| Black preview after switching video resolution/frame rate; log: `Unable to set buffer count for stream N … (-38)`, then `Unable to connect to native window … (-22)` | Encoder buffer request too large (fixed in v0.31). If it comes back, look for `max_buffers … -> 40` from `OplusCamLosWrap` in the log and compare it with the HAL's request. |
| Other camera app (Instagram, Aperture …) misbehaves | Check the log for `OplusCamLosWrap: camera N: session moved to Qualcomm's HAL (stock path)`. If it's missing, routing is off (`persist.vendor.camera.oplus_los.route`) or the layer's symbols weren't found (`stock path symbols missing`). |
| Camera HAL restarts (tombstone in `vendor.qti.camera.provider-service_64`, `ExtensionModule::RecoveryThread`) | CHI's own recovery after a stuck request. Send the bundle. |

## Known log noise (harmless)

These come from the vendor blobs expecting OxygenOS hardware or services. They don't affect photos:

- `camxncsintftofsensor … Invalid State`, `RequestNCSService() Failed`, `NCS ColorSensor front handle is NULL`: the ToF and color sensors aren't exposed on LineageOS.
- `GetDataAsync() Unsupported sensor type`, OIS/gyro queries in SAT reprocess.
- `libdscaalgo.so not found`: an optional OnePlus algorithm loaded by absolute `/vendor` path; skipped.
- App: `VendorTagDescriptor: lookupTag … does not exist`, `Failed to find provider info for com.oplus.customize…`, `Access denied finding property "vendor.…"`, `A resource failed to call HardwareBuffer.close` (OnePlus app behaviour, reported only on builds with CloseGuard enabled), `Expect face scores and rectangles to be non-null`.
- ArcSoft libraries log ordinary progress at error level (`ArcSoft_C_LN`).
