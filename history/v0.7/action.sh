#!/system/bin/sh
# Module action button: save a debug bundle (nothing on the system is changed).
MODDIR=${0%/*}
OUT=/sdcard/Download/oplus-camera-debug-$(date +%Y%m%d-%H%M%S).txt
{
  echo "== module $(grep ^version= "$MODDIR/module.prop")"; getprop ro.lineage.version
  echo "== privapp list: $(getprop persist.vendor.camera.privapp.list)"
  echo "== OnePlus camera layer"; ls -la /vendor/lib64/hw/camera.oemlayer.v2.so 2>&1; getprop ro.hardware.camera
  logcat -d 2>/dev/null | grep -iE "oemlayer|OemLayer|hw_get_module|camera.provider" | tail -60
  dumpsys media.camera 2>/dev/null | grep -iE "supported.cameraid.type|cameraIdMapInfo" | head -10
  echo "== sphal lib"; ls -laZ /vendor/lib64/libOplusSecurity.so 2>&1
  echo "== package"; dumpsys package com.oplus.camera | grep -E "versionName|codePath|usesLibraries|usesOptionalLibraries|granted=false" | head -60
  echo "== avc denials"; logcat -d 2>/dev/null | grep -i "avc:" | grep -iE "priv_app|camera" | tail -200
  echo "== crashes"; logcat -b crash -d 2>/dev/null | tail -300
  echo "== camera log"; logcat -d 2>/dev/null | grep -iE "oplus\.camera|OplusCamera|APS|CameraService|camx|NoSuch(Method|Field)|ClassNotFound|UnsatisfiedLink" | tail -1500
  U=$(stat -c %u /data/data/com.oplus.camera 2>/dev/null)
  echo "== app uid $U: full log"; [ -n "$U" ] && logcat -d -b main,system,crash --uid="$U" 2>/dev/null | tail -4000
  echo "== graphics"; logcat -d 2>/dev/null | grep -iE "SurfaceFlinger|BufferQueue|gralloc|libEGL|GLES|adreno|HWComposer|ImageReader" | tail -400
} > "$OUT" 2>&1
echo "Debug log saved: $OUT"
echo "Delete it when you no longer need it."
