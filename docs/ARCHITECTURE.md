# Architecture

## The camera stack

```
com.oplus.camera (app)  ──  com.oplus.camera.unit.sdk (OCS camera SDK, shared library)
        │                          │  + oplus-camera-stubs.jar (OnePlus framework classes LineageOS lacks)
        ▼ Camera2 / binder
cameraserver (LineageOS, stock AOSP)
        ▼ AIDL camera provider
vendor.qti.camera.provider-service_64 (camx)
        │  hw_get_module("camera", ro.hardware.camera = "oemlayer.v2")
        ▼
/odm/lib64/hw/camera.oemlayer.v2.so      ← our wrapper (SONAME camera.oemlayer.wrap.so)
        │  DT_NEEDED
        ▼
/odm/lib64/camera.oemlayer.v2.so          ← OnePlus "OemLayer" (patched)
        ├─ camera.oemlayer.uilaye2.so     ← OnePlus UI layer (private, renamed copy)
        ├─ libsensorbridg2.so             ← OnePlus sensor bridge (private, renamed copy)
        └─ ROM's camera.qcom / CHI (com.qti.chi.override.so) …
```

On OxygenOS the framework (`frameworks/av`, `frameworks/base`) is modified in several places the OnePlus camera relies on. On LineageOS it's stock AOSP, so the module makes up the difference in the app, the SDK, the layer and a few ROM libraries, never in LineageOS's framework.

## Isolation: other camera apps use LineageOS's own path

LineageOS already sets `ro.hardware.camera=oemlayer.v2`, so once the layer exists the camera provider loads it for every app. OnePlus's layer depends on OxygenOS's camera service in ways LineageOS can't match: on OxygenOS every session carries the client's package name. Third-party apps ran into its first-party code: Instagram's photo request had its JPEG taken over by the layer's snapshot path, which never produced it, so the shutter hung, and the next app (Aperture) then opened a stuck device.

Since v0.32 the wrapper hands the camera provider a small **proxy** for every device it opens:

- The device starts on the OnePlus layer, so the OnePlus camera's behaviour is unchanged.
- When a session is configured in a standard operation mode (every app except the OnePlus camera, which uses its private modes ≥ 0x8000), the proxy closes that device and reopens the camera **directly on Qualcomm's HAL** (`camera.qcom`). That is the path LineageOS uses when the module isn't installed. Requests, results and buffers then never pass through OnePlus code.
- The OnePlus layer registers callbacks inside Qualcomm's HAL at load time (`pSetOplusCallback(&g_camx_oplus_callback_ops)`). While only directly opened devices exist, the wrapper clears them, as on LineageOS without the module, and restores them when a OnePlus-layer device opens.
- Kill switch: `setprop persist.vendor.camera.oplus_los.route 0` keeps every session on the OnePlus layer (the pre-v0.32 behaviour), effective from the next camera open.

What third-party apps still see from the module: the camera **characteristics** the provider read at boot come from the layer (one table for all apps), and the capture-result queue size (`system.prop`).

## Properties stay inside the camera's process

The OnePlus camera expects about a dozen OxygenOS properties (ROM API level, deferred capture, HDR flags …). Instead of setting them system-wide, where any app could see a "ColorOS" device, every property read in the stubs jar and the app's two reflective reads go through `com.oplus.camera.los.LosProps` (`tools/gen_losprops.py`). It answers those keys with the module's values and passes every other key through. The only system-wide property left is the result-queue size.

## Why files live where they do

- **Nothing under `/vendor`.** With meta-overlayfs, any module file under `system/vendor` turns all of `/vendor` into an overlay. On this device that made `/vendor/lib64/hw` show the module's label (`vendor_file`) instead of `vendor_hal_file`. Zygote preloads the GPU driver at boot and was denied reading that folder, which broke OpenGL ES 3 in **every** app (Chromium browsers: "GPU process isn't usable"), even apps that had modules unmounted.
- **`/odm` instead.** libhardware searches `/odm/lib64/hw` before `/vendor/lib64/hw`, and the vendor linker searches `/odm/lib64` before `/vendor/lib64`. So files placed on `/odm` take precedence by search order without overlaying `/vendor`.
- **Directory labels.** `customize.sh` gives every merged directory the ROM's own SELinux label, and `*/lib64/hw` always gets `vendor_hal_file` (from `plat_file_contexts`). A wrong directory label on a merged folder is visible to every process.
- **`/system_ext`** holds everything app-side. The installer refuses to overlay any file the ROM already ships there.

### Metamodule copy

meta-overlayfs doesn't mount the module folder itself. It keeps a copy of each module in its own ext4 image (`/data/adb/modules/meta-overlayfs/mnt/<id>/`, also reachable as `/data/adb/metamodule/mnt/<id>/`). Partitions sit at the top level of that copy (`<id>/odm`, `<id>/system_ext`, `<id>/vendor` …), next to `<id>/system`. **Some versions only add files to that copy on update**, so files an older module version shipped stay mounted. `prune_mirror` (in `customize.sh` and `post-fs-data.sh`) deletes anything in our copy that the current module doesn't ship, and `uninstall.sh` removes the copy.

## The session package tag

OnePlus's HAL decides per session whether the client is its own camera app, using the vendor tag `com.oplus.packageName` in the session parameters. Only then does it configure the first-party pipelines: ZSL RAW queue, SAT multi-camera, deferred capture. Infinity X's cameraserver stamps that tag; LineageOS's doesn't. Three layers add it, so one missing doesn't break photos:

1. **SDK** (`sdk_session_package_tag`): sets `com.oplus.packageName = "com.oplus.camera"` on its own session builder.
2. **Wrapper** (`prebuilt/camera.oemlayer.wrap.so`, source in `tools/oemwrap/`): in `configure_streams`, for OnePlus's private operation modes (≥ 0x8000, used only by the OnePlus app), adds the tag if absent. Every other session passes through untouched.
3. **UI layer** (`binpatches.json`, `InitPackageName`): if the tag is still missing but OnePlus tag 0x45 is present, treats the client as `com.oplus.camera`.

Third-party apps never get the tag, so they keep the generic pipeline.

## What the wrapper does (OnePlus operation modes ≥ 0x8000 only)

1. Adds the session package tag (above).
2. Gives the app's picture-metadata surface (RAW16, consumer usage 0x40) the stream use case 0x10002, so the HAL writes each frame's metadata into it.
3. **Caps video-encoder streams at 40 buffers.** A LineageOS video-encoder surface has no BufferQueue slot expansion, so it holds at most 64 buffers. In some video modes (1080p60, stabilisation) OnePlus's HAL asks for 64, and cameraserver also needs the encoder's own spare buffers on top. It then refused the whole session ("Unable to set buffer count", −38), leaving a black preview, followed by −22 on retries because the encoder surface was still connected. 42 is known to work at 1080p.

Any other session passes straight through.

## Deferred capture

`ro.oplus.camera.defercap.support=1` is mandatory: the app throws on start without it. The app first saves a quick JPEG, then the processing service (APS) replaces it with the multi-frame result, triggered when you open the thumbnail or close the camera. The gallery hand-off (`LosGalleryFallback`) waits up to 8 s for that final image before opening the photo, so other galleries don't cache the quick JPEG.

## Capture-result queue (FMQ)

The camx HAL sends results to cameraserver over a fast message queue, sized from `ro.vendor.camera.res.fmq.size` (default 1 MB). OnePlus results are 0.5–1.2 MB. With 1 MB, large results fall back to binder, which is capped at about 1 MB per process: transactions fail (`-28`), metadata gets corrupted and portrait mode crashes. cameraserver also sizes each app's result queue from the same value. The module sets 8 MB.

## Graphics-buffer handle mismatch

LineageOS's open-source snapalloc lays out the private handle differently from OxygenOS's proprietary gralloc: the buffer width is at `+0x2c` instead of `+0x1c`. OnePlus's offline camera service read `+0x1c` (the flags, 512) as the metadata size, so photos came out black. The install-time fix reads `+0x2c` (see PATCHES.md, install-time fixes).

AOSP's `AHardwareBuffer_lockPlanes` only returns one plane for Qualcomm's `YCbCr_420_P010_VENUS`, while OxygenOS's framework returns three. `libAlgoProcess` took the chroma plane from plane 1 and crashed in HDR. The fix computes the chroma plane the way the allocator lays it out.

## Out-of-order frames in multi-frame shots

For portrait and other multi-frame shots (7 frames per camera), OnePlus's HAL builds part of the burst from frames it captured just before the shutter, re-stamped a few nanoseconds after the original (`80319044658` → `80319044667`). Their timestamps are older than the frame returned before them. Stock Android's `Camera3Stream::returnBuffer` marks such a buffer as an error (`timestamp … is not increasing`) unless the request is a ZSL still capture or a reprocess, so the app received 6 of 7 frames (`onCaptureBufferLost`), and its processing stage waited up to 20 s for the 7th: the shutter stayed busy until the app was paused. The install-time `cameraserver` fix keeps the warning but returns the buffer normally, as Android does for ZSL captures. Other apps' sessions run on Qualcomm's stock path, which doesn't produce out-of-order timestamps, so nothing changes for them.

The fixed copy is made from the installed ROM's own `cameraserver` and is only valid for that build. `post-fs-data.sh` compares the ROM build recorded at install (`.rom_build`, from `/system/build.prop`) with the current one and drops the copy after a LineageOS update; `service.sh` then posts a notification to flash the module again.

## Watchdog

`service.sh` watches the first 10 minutes after boot. If two or more camera-HAL crashes run through the OnePlus layer, or the layer fails to load, it removes the layer from the module and posts a notification. The next boot then falls back to LineageOS's own camera path.
