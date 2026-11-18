Sources for `prebuilt/oplus-camera-stubs.jar` (shared library `oplus.camera.stubs`).

- `shim_override/`: our implementations of OnePlus framework classes the camera calls
  (`OplusSystemProperties`, `OplusActivityManager`, `OplusActivityTaskManager`, `SurfaceExtImpl`,
  `FlexibleWindowManager`, ...), written to behave like "feature absent".
- `stubs_src/`: compile-time stubs for hidden framework APIs.

The jar = LineageOS `oplus-fwk` classes (open source, hardware/oplus) + `shim_override`,
compiled with javac against the stubs and converted to dex with d8.
