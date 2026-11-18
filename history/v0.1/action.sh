#!/system/bin/sh
# Module action button: toggle ODM extras, and save a debug bundle for troubleshooting.
MODDIR=${0%/*}
if [ -f "$MODDIR/enable_odm_extras" ]; then
  rm -f "$MODDIR/enable_odm_extras"; echo "ODM extras: OFF (takes effect after reboot)"
else
  touch "$MODDIR/enable_odm_extras"; echo "ODM extras: ON (takes effect after reboot)"
fi
OUT=/sdcard/Download/oplus-camera-debug-$(date +%Y%m%d-%H%M%S).txt
{
  echo "== module $(grep ^version= "$MODDIR/module.prop")"; getprop ro.lineage.version
  echo "== odm extras: $([ -f "$MODDIR/enable_odm_extras" ] && echo on || echo off)"; cat "$MODDIR/boot.log" 2>/dev/null
  echo "== package"; dumpsys package com.oplus.camera | grep -E "versionName|codePath|usesLibraries|usesOptionalLibraries|granted=false" | head -60
  echo "== avc denials (camera)"; logcat -b events,main,system -d 2>/dev/null | grep -i "avc:.*\(priv_app\|camera\)" | tail -200
  echo "== crashes"; logcat -b crash -d 2>/dev/null | tail -300
  echo "== camera log"; logcat -d 2>/dev/null | grep -iE "oplus\.camera|OplusCamera|APS|CameraService|camx|NoSuch(Method|Field)|ClassNotFound|UnsatisfiedLink" | tail -1500
} > "$OUT" 2>&1
echo "Debug log saved: $OUT"
