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
/odm/lib64/camera.oemlayer.v2.so          ← OnePlus "OemLayer": private copy, edited (see below)
        ├─ camera.oemlayer.uilaye2.so     ← its UI library (private, renamed copy)
        ├─ libsensorbridge.so             ← ROM's
        └─ ROM's camera.qcom / CHI (com.qti.chi.override.so) …
```

### Which layer

LineageOS's builds with ColorOS 11.C.80 blobs (from late November 2026) ship the layer themselves, at the same `hw/` path, built for their own camx HAL; the module requires such a build. It wraps **LineageOS's layer**: at install (`customize.sh`) it makes private copies of the ROM's layer and UI library with four edits (`common.sh`, `LAYER_FIX_*`, `UILAYER_FIX_*`): the layer loads the private UI library and follows the app's zoom ratio; the UI library has its own name and loads the layer by name instead of by the `hw/` path (which is the wrapper). The wrapper takes the `hw/` path. The ROM's layer, UI library and every other ROM file stay untouched; removing the module gives LineageOS's own setup back. If the copies can't be made (a LineageOS update changed the layer), the layer runs as is, without the wrapper.

The wrapper's assumptions about Qualcomm's HAL were re-checked on the ColorOS 11.C.80 blobs: `camx.device-impl.so` still calls `process_capture_request` through device-op slot 5 (`+0x28`, configure `+0x8`, flush `+0x40`); notify reads type `+0x0`, frame `+0x8`, timestamp/readout `+0x10`/`+0x18`; `camera.qcom.so` logs the request's settings at `+0x8`, input buffer at `+0x10` (private fields from `+0x48`) and the result's input buffer at `+0x20`. The layer exports every symbol the wrapper uses, and `HMI` is still 400 bytes.

On ColorOS the framework (`frameworks/av`, `frameworks/base`) is modified in several places the OnePlus camera relies on. On LineageOS it's stock AOSP, so the module makes up the difference in the app, the SDK, the layer and a few ROM libraries, never in LineageOS's framework.

## Isolation: other camera apps use LineageOS's own path

LineageOS already sets `ro.hardware.camera=oemlayer.v2`, so once the layer exists the camera provider loads it for every app. OnePlus's layer depends on ColorOS's camera service in ways LineageOS can't match: on ColorOS every session carries the client's package name. Third-party apps ran into its first-party code: Instagram's photo request had its JPEG taken over by the layer's snapshot path, which never produced it, so the shutter hung, and the next app (Aperture) then opened a stuck device.

Since v0.32 the wrapper hands the camera provider a small **proxy** for every device it opens:

- The device starts on the OnePlus layer, so the OnePlus camera's behaviour is unchanged.
- When a session is configured in a standard operation mode (every app except the OnePlus camera, which uses its private modes ≥ 0x8000), the proxy closes that device and reopens the camera **directly on Qualcomm's HAL** (`camera.qcom`). That is the path LineageOS uses when the module isn't installed. Requests, results and buffers then never pass through OnePlus code.
- The OnePlus layer registers callbacks inside Qualcomm's HAL at load time (`pSetOplusCallback(&g_camx_oplus_callback_ops)`). While only directly opened devices exist, the wrapper clears them, as on LineageOS without the module, and restores them when a OnePlus-layer device opens.
- Kill switch: `setprop persist.vendor.camera.oplus_los.route 0` keeps every session on the OnePlus layer (the pre-v0.32 behaviour), effective from the next camera open.

What third-party apps still see from the module: the camera **characteristics** the provider read at boot come from the layer (one table for all apps), and the capture-result queue size (`system.prop`).

## Properties stay inside the camera's process

The OnePlus camera expects about a dozen ColorOS properties (ROM API level, deferred capture, HDR flags …). Instead of setting them system-wide, where any app could see a "ColorOS" device, every property read in the stubs jar and the app's reflective `anim_level` reads (three COUI helpers) go through `com.oplus.camera.los.LosProps` (`tools/gen_losprops.py`). It answers those keys with the module's values and passes every other key through. The only system-wide property left is the result-queue size.

## Why files live where they do

- **Nothing under `/vendor`.** With meta-overlayfs, any module file under `system/vendor` turns all of `/vendor` into an overlay. On this device that made `/vendor/lib64/hw` show the module's label (`vendor_file`) instead of `vendor_hal_file`. Zygote preloads the GPU driver at boot and was denied reading that folder, which broke OpenGL ES 3 in **every** app (Chromium browsers: "GPU process isn't usable"), even apps that had modules unmounted.
- **`/odm` instead.** libhardware searches `/odm/lib64/hw` before `/vendor/lib64/hw`, and the vendor linker searches `/odm/lib64` before `/vendor/lib64`. So files placed on `/odm` take precedence by search order without overlaying `/vendor`.
- **Directory labels.** `customize.sh` gives every merged directory the ROM's own SELinux label, and `*/lib64/hw` always gets `vendor_hal_file` (from `plat_file_contexts`). A wrong directory label on a merged folder is visible to every process.
- **`/system_ext`** holds everything app-side. The installer refuses to overlay any file the ROM already ships there.

### Metamodule copy

meta-overlayfs doesn't mount the module folder itself. It keeps a copy of each module in its own ext4 image (`/data/adb/modules/meta-overlayfs/mnt/<id>/`, also reachable as `/data/adb/metamodule/mnt/<id>/`). Partitions sit at the top level of that copy (`<id>/odm`, `<id>/system_ext`, `<id>/vendor` …), next to `<id>/system`. **Some versions only add files to that copy on update**, so files an older module version shipped stay mounted. `prune_mirror` (in `customize.sh`, and at boot in `post-fs-data.sh`, or `service.sh` when meta-overlayfs hasn't mounted its image yet) deletes anything in our copy that the current module doesn't ship, and `uninstall.sh` removes the copy.

## The session package tag

OnePlus's HAL decides per session whether the client is its own camera app, using the vendor tag `com.oplus.packageName` in the session parameters. Only then does it configure the first-party pipelines: ZSL RAW queue, SAT multi-camera, deferred capture. Infinity X's cameraserver stamps that tag; LineageOS's doesn't. Two places add it, so one missing doesn't break photos:

1. **SDK** (`sdk_session_package_tag`): sets `com.oplus.packageName = "com.oplus.camera"` on its own session builder.
2. **Wrapper** (`prebuilt/camera.oemlayer.wrap.so`, source in `tools/oemwrap/`): in `configure_streams`, for OnePlus's private operation modes (≥ 0x8000, used only by the OnePlus app), adds the tag if absent. Every other session passes through untouched.

Third-party apps never get the tag, so they keep the generic pipeline.

## What the wrapper does (OnePlus operation modes ≥ 0x8000 only)

1. Adds the session package tag (above).
2. Gives the app's picture-metadata surface (RAW16, consumer usage 0x40) the stream use case 0x10002, so the HAL writes each frame's metadata into it.
3. **Caps video-encoder streams at 40 buffers.** A LineageOS video-encoder surface has no BufferQueue slot expansion, so it holds at most 64 buffers. In some video modes (1080p60, stabilisation) OnePlus's HAL asks for 64, and cameraserver also needs the encoder's own spare buffers on top. It then refused the whole session ("Unable to set buffer count", −38), leaving a black preview, followed by −22 on retries because the encoder surface was still connected. 42 is known to work at 1080p. Stabilised modes hold frames back for look-ahead, so the cap may cost frames at 4K60 with stabilisation; it can be tuned without a rebuild: `setprop persist.vendor.camera.oplus_los.encbuf N` (8–63, `0` = no cap, read at every configure; the log shows `max_buffers … (cap N)` for each encoder stream).

4. **Keeps frame timestamps increasing** for multi-frame shots ("Out-of-order frames" below).

Any other session passes straight through.

## Deferred capture

`ro.oplus.camera.defercap.support=1` is mandatory: the app throws on start without it. The app first saves a quick JPEG, then the processing service (APS) replaces it with the multi-frame result, triggered when you open the thumbnail or close the camera. The gallery hand-off (`LosGalleryFallback`) waits up to 8 s for that final image before opening the photo, so other galleries don't cache the quick JPEG.

## Capture-result queue (FMQ)

The camx HAL sends results to cameraserver over a fast message queue, sized from `ro.vendor.camera.res.fmq.size` (default 1 MB). OnePlus results are 0.5–1.2 MB. With 1 MB, large results fall back to binder, which is capped at about 1 MB per process: transactions fail (`-28`), metadata gets corrupted and portrait mode crashes. cameraserver also sizes each app's result queue from the same value. The module sets 8 MB.

## Graphics-buffer handle mismatch

LineageOS's open-source snapalloc lays out the private handle differently from ColorOS's proprietary gralloc: the buffer width is at `+0x2c` instead of `+0x1c` (format `+0x34`, size `+0x50`). OnePlus's offline camera service read `+0x1c` (the flags, 512) as the metadata size, so photos came out black. The install-time fix reads `+0x2c`, which for these BLOB buffers is their byte size (see PATCHES.md, install-time fixes). The fix was re-derived for ColorOS 11.C.80's offline service, which has the same read in different code than the older OxygenOS one.

ColorOS's `libEIS` (shipped by LineageOS's ColorOS-blob builds) reads the buffer format from the legacy `+0x2c` for five ShareBuffer imports; with snapalloc that is the width, so EGL imports failed (empty, green time-lapse videos, found by Infinity X on identical code). The install-time fix reads `+0x34`.

AOSP's `AHardwareBuffer_lockPlanes` only returns one plane for Qualcomm's `YCbCr_420_P010_VENUS`, while ColorOS's framework returns three. `libAlgoProcess` took the chroma plane from plane 1 and crashed in HDR. The fix computes the chroma plane the way the allocator lays it out; since the module ships `libAlgoProcess` itself, it is applied at build time (`tools/app_blobs.py`).

## The camera app's own libraries and data

The OnePlus camera's processing stage loads about 90 OnePlus/ArcSoft libraries from `/odm/lib64` (`libAlgoProcess`, `libAlgoInterface`, the `com.oplus.node.*` APS nodes, HDR/night/portrait/beauty algorithms, `libalog` …) and reads ~700 models, LUTs and configs under `/odm/etc/camera`. LineageOS's ColorOS-blob builds dropped them as unused (only the OnePlus camera uses them; LineageOS/android_device_oneplus_infiniti `ce5065b`). The module ships them (`tools/app_blobs.txt`, `.app_blobs` in the module) from the same ColorOS firmware as the app and LineageOS's blobs, with the fixups LineageOS applied to them (symbol versions of `AHardwareBuffer_*`, graphics.common V5→V7) and the P010 fix above.

They are about 2.4 GB, more than meta-overlayfs's image (2 GB by default, shared by all modules) holds. meta-overlayfs copies only a module's partition folders (`system/`, `vendor/` …) into that image, so these files stay in the module folder on `/data`, in their own read-only erofs image, `blobs.img` (1.66 GB: lz4hc like the ROM's odm image, file tails packed together, identical data stored once). An image, not a folder: Android 16's kernel (6.12) refuses overlayfs layers on a filesystem that supports case-insensitive names, which `/data`'s f2fs does (`overlay: case-insensitive capable filesystem … not supported`). `post-mount.sh`, which KernelSU runs after the metamodule has mounted every module and before zygote and the camera HAL start, loop-mounts the image on `blobs/` in the module folder and mounts its `odm/lib64` and `odm/etc/camera` as read-only overlays over `/odm/lib64` and `/odm/etc/camera` (`mount_blobs`, `common.sh`; logged in `mount.log`). Nothing is written outside the module folder: the mounts are gone at the next boot, and removing the module removes the image. The lower layer of each is the folder as already mounted, so the ROM's files and the module's other `/odm` files (layer, wrapper, fixed copies) stay visible below the app's. Two overlays instead of one bind mount per file: most of these files don't exist on LineageOS, and a bind mount needs an existing target.

Each file and folder keeps the label it has in the ColorOS odm image (`odm/config/odm_file_contexts` in the dump; the build writes them into the image, so the installer labels nothing): 80 of the libraries are `same_process_hal_file` (the app loads them through the SP-HAL namespace), 8 are `vendor_file`, and the models and configs `vendor_configs_file`. An overlay shows the label of the underlying file, and each mount point's label is that of its top folder (`vendor_file` for `lib64`, `vendor_configs_file` for `etc/camera`, as on the ROM).

## Out-of-order frames in multi-frame shots

For portrait and other multi-frame shots (7 frames per camera), OnePlus's HAL builds part of the burst from frames it captured just before the shutter, re-stamped a few nanoseconds after the original (`80319044658` → `80319044667`). Their timestamps are older than the frame returned before them. Stock Android's `Camera3Stream::returnBuffer` marks a buffer as an error when its timestamp is not greater than the stream's previous one (`timestamp … is not increasing`), unless the request is a ZSL still capture or a reprocess. The app then received 6 of 7 frames (`onCaptureBufferLost`), and its processing stage waited up to 20 s for the 7th: the shutter stayed busy until the app was paused.

Since v0.37 the wrapper handles this inside the camera HAL process, for OnePlus sessions only (v0.35–v0.36 shipped a fixed copy of the ROM's `cameraserver` instead, which applied to every app and had to be re-made after each LineageOS update):

- The OnePlus layer is initialised with the wrapper's callback table instead of the provider's; every callback is forwarded with the provider's own table pointer, so the provider sees exactly what it would without the wrapper.
- `process_capture_request` (QTI device-op slot 5: Qualcomm's `camera3_device_ops` has one entry more than AOSP's before it, so every later entry is shifted by one; checked against the slots `camx.device-impl.so` calls) notes, per frame, whether the camera service exempts it: an input buffer (reprocess), or `android.control.enableZsl` = true with `android.control.captureIntent` = STILL_CAPTURE. Requests without settings repeat the previous settings, as in the camera service.
- A shutter notification whose timestamp is not greater than the newest one passed on is sent with timestamp = previous + 1 ns (the readout timestamp moves by the same amount); exempt and unknown frames, timestamp 0 and error messages pass unchanged. The camera service remembers the timestamp of every buffer, exempt ones included, so an exempt or unknown frame newer than the previous mark moves the mark forward (it never moves back; raising a frame more than needed is harmless). The HAL's own message isn't modified: a copy is sent.
- That frame's capture result carrying `android.sensor.timestamp` equal to the original value is sent with the same new value, so the image and its result still match. Qualcomm's capture-result struct is longer than AOSP's (private fields at `0x40`/`0x48`), so it is never copied: only its metadata pointer is swapped for the duration of the call, to a copy of the metadata, and restored.
- Each change is logged: `OplusCamLosWrap: camera N frame F: shutter T older than previous P, sent as P+1`.

Struct offsets (shutter message `0x08` frame / `0x10` timestamp / `0x18` readout; request `0x08` settings / `0x10` input buffer; result `0x08` metadata) were read from `camera.qcom.so`'s own logging of these structs. `tests/oemwrap_host_test.c` drives the logic like the provider and the layer do. Kill switch: `setprop persist.vendor.camera.oplus_los.tsfix 0` (read when a session starts). Other apps' sessions run on Qualcomm's HAL with the provider's own callbacks and are never touched.

One difference from the old `cameraserver` fix: a raised frame reaches the app with a timestamp 1 ns after the previous frame instead of its original, older one. OnePlus's per-lens (physical camera) result metadata keeps the original value.

## Watchdog

`service.sh` watches the first 10 minutes after boot. If two or more camera-HAL crashes run through the OnePlus layer, or the layer fails to load, it removes the layer from the module and posts a notification. The next boot then falls back to LineageOS's own camera path.

Before that, `adapt_to_rom` (`module/common.sh`) follows structural changes of LineageOS's camera blobs: when the ROM's `libEIS` is the ColorOS one, its fix is added. If meta-overlayfs hasn't mounted its image yet, `post-fs-data.sh` mounts it the way meta-overlayfs's `metamount.sh` does, so the boot after a LineageOS update already mounts the updated files; if that isn't possible, the crash watchdogs sit that boot out (they would be judging outdated files).

`post-fs-data.sh` compares every fixed copy's ROM file with the sha256 recorded when the copy was made. KernelSU runs it before the metamodule mounts any module file (`ksud`'s `on_post_fs_data`), so `/vendor` and `/odm` show the ROM's own files at that point. After a LineageOS update that changed one, the copy is made again from the new file with the same edit (`refresh_fixes`, `module/common.sh`); if the new file no longer has the expected bytes, that fix is switched off and the ROM's file is used. Nothing is shown to the user; both cases are logged in `fixes.log` in the module folder (also in the debug bundle). meta-overlayfs mounts its own copy of the module (made at install), so the remade files are copied into it too (`sync_mirror`): right away if its image is already mounted, otherwise from `service.sh`, effective from the next boot. The crash watchdogs above are the only notifications.
