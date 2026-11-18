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

## Watchdog

`service.sh` watches the first 10 minutes after boot. If two or more camera-HAL crashes run through the OnePlus layer, or the layer fails to load, it removes the layer from the module and posts a notification. The next boot then falls back to LineageOS's own camera path.
