#!/system/bin/sh
# Module action button: save a debug bundle (nothing on the system is changed).
MODDIR=${0%/*}
OUT=/sdcard/Download/oplus-camera-debug-$(date +%Y%m%d-%H%M%S).txt
{
  echo "== module $(grep ^version= "$MODDIR/module.prop")"; getprop ro.lineage.version
  echo "== privapp list: $(getprop persist.vendor.camera.privapp.list)"
  echo "== package"; dumpsys package com.oplus.camera | grep -E "versionName|codePath|usesLibraries|usesOptionalLibraries|granted=false" | head -60
  echo "== avc denials"; logcat -d 2>/dev/null | grep -i "avc:" | grep -iE "priv_app|camera" | tail -200
  echo "== crashes"; logcat -b crash -d 2>/dev/null | tail -300
  echo "== camera log"; logcat -d 2>/dev/null | grep -iE "oplus\.camera|OplusCamera|APS|CameraService|camx|NoSuch(Method|Field)|ClassNotFound|UnsatisfiedLink" | tail -1500
} > "$OUT" 2>&1
echo "Debug log saved: $OUT"
echo "Delete it when you no longer need it."
