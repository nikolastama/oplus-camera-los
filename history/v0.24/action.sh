#!/system/bin/sh
# Module action button: save one complete debug bundle to Download (nothing on the system is changed).
# Everything is unfiltered so a single run answers as many questions as possible.
MODDIR=${0%/*}
TS=$(date +%Y%m%d-%H%M%S)

# Press 1: schedule a snapshot of the live camera session (stream sizes/formats the HAL was given),
# taken 20 s later while the OnePlus camera is open. Press 2: collect everything.
SNAP=/data/local/tmp/ocam-session-snapshot.txt
if [ ! -f "$SNAP" ] && [ ! -f /data/local/tmp/ocam-snapshot.pending ]; then
  touch /data/local/tmp/ocam-snapshot.pending
  # Turn on the camera app's own processing (APS) logs and the HAL's logs until the next reboot
  # (runtime values only; nothing is written to persistent storage), then restart both so they
  # pick the settings up.
  for k in infoMask debugMask warningMask; do resetprop -n persist.camera.aps.core.$k 0xffffffff; done
  resetprop -n persist.vendor.camera.oplus.enableLogging true
  resetprop -n persist.camera.logWarningMask 0xffffffff
  # The OnePlus camera layer (OemLayer) only logs when it believes it runs on a test build.
  resetprop -n oplus.autotest.camera.debug.forcelog true
  resetprop -n persist.camera.assert.panic true
  resetprop -n persist.sys.assert.panic true
  am force-stop com.oplus.camera >/dev/null 2>&1
  pkill -f camera.provider-service >/dev/null 2>&1
  ( sleep 20; dumpsys media.camera > "$SNAP.tmp" 2>&1; mv "$SNAP.tmp" "$SNAP"
    rm -f /data/local/tmp/ocam-snapshot.pending ) >/dev/null 2>&1 &
  echo "Step 1 done. Now, within 20 seconds: open the OnePlus camera and leave it on the preview."
  echo "Stay on the preview for about 30 seconds, then take a photo."
  echo "Afterwards come back here and press the action button again to save the bundle."
  exit 0
fi
[ -f /data/local/tmp/ocam-snapshot.pending ] && { echo "The session snapshot is still pending (20 s after the first press). Try again in a few seconds."; exit 0; }
W=/data/local/tmp/ocam-debug-$TS
mkdir -p "$W"
OUT=/sdcard/Download/oplus-camera-debug-$TS.tar.gz

{
  echo "== module $(grep ^version= "$MODDIR/module.prop")"
  echo "== kernel $(uname -r)"; getprop ro.lineage.version; getprop ro.build.fingerprint
  echo "== layer"; ls -laZ /odm/lib64/hw/camera.oemlayer.v2.so /odm/lib64/camera.oemlayer.v2.so /odm/lib64/camera.oemlayer.uilaye2.so /odm/lib64/libsensorbridg2.so /odm/lib64/libOplusSecurity.so 2>&1
  echo "== /vendor must be untouched by the module:"; grep -c " /vendor" /proc/mounts; grep " /vendor\| /odm\| /system_ext" /proc/mounts | cut -c1-160
  echo "== directory labels (must match the ROM: lib64 vendor_file, hw vendor_hal_file)"; ls -dZ /odm/lib64 /odm/lib64/hw /vendor/lib64/hw /system_ext/lib64 /system_ext/priv-app 2>&1
  echo "== recent denials touching module paths"; logcat -d -b all 2>/dev/null | grep "avc: *denied" | grep -E 'dev="overlay"|name="hw"|oemlayer|OplusCamera' | tail -20
  [ -f "$MODDIR/oemlayer_disabled" ] && { echo "!! watchdog disabled the layer:"; cat "$MODDIR/oemlayer_disabled"; }
  echo "== data dirs"; ls -ldZ /data/vendor/cam_alog /data/vendor/camera_process /data/vendor/camera_rus /data/system/camera_rus 2>&1
  echo "== relabeled"; cat "$MODDIR"/.relabeled/* 2>/dev/null
  echo "== camera_remote_dump"; ls -laZR /data/vendor/camera_remote_dump 2>&1 | head -60
  echo "== camera_process"; ls -laZ /data/vendor/camera_process 2>&1 | head -40
  echo "== cam_alog"; ls -laZ /data/vendor/cam_alog 2>&1 | head -40
  echo "== logd buffer"; logcat -g 2>&1 | head -6
  echo "== app uid"; stat -c %u /data/data/com.oplus.camera 2>&1
  echo "== library fixes (module copies of ROM files)"
  cat "$MODDIR/.fixed" 2>&1
  F=/odm/lib64/vendor.qti.hardware.camera.offlinecamera-service-impl.so
  echo "offline service @0x1b394: $(od -An -tx1 -j 111508 -N 4 "$F" | tr -d ' \n') (1b2f40b9 = fixed, 1b1f40b9 = stock)"
  F=/odm/lib64/libAlgoProcess.so
  echo "libAlgoProcess @0x1c9f38: $(od -An -tx1 -j 1875768 -N 4 "$F" | tr -d ' \n') (e93341b9 = fixed, e97740f9 = stock)"
  ls -lZ /odm/lib64/vendor.qti.hardware.camera.offlinecamera-service-impl.so /vendor/lib64/vendor.qti.hardware.camera.offlinecamera-service-impl.so /odm/lib64/libAlgoProcess.so 2>&1
  grep -h "offlinecamera-service-impl\|camera.oemlayer" /proc/$(pidof vendor.qti.camera.provider-service_64 | cut -d" " -f1)/maps 2>/dev/null | awk '{print $6}' | sort -u
} > "$W/summary.txt" 2>&1

logcat -d -b all -v threadtime > "$W/logcat-all.txt" 2>&1
logcat -d -b crash > "$W/logcat-crash.txt" 2>&1
dumpsys media.camera > "$W/dumpsys-media.camera.txt" 2>&1
dumpsys media.camera.proxy > "$W/dumpsys-camera-proxy.txt" 2>&1
dumpsys package com.oplus.camera > "$W/dumpsys-package.txt" 2>&1
getprop > "$W/getprop.txt" 2>&1
ls -la /data/tombstones > "$W/tombstones-list.txt" 2>&1
# newest few tombstones (text form), they carry full register/stack info for native crashes
for t in $(ls -t /data/tombstones/tombstone_[0-9][0-9] 2>/dev/null | head -4); do cp "$t" "$W/" 2>/dev/null; done
# the device's own camera service binaries, unmodified, so fixes can be checked against the exact build
mkdir -p "$W/bin"
for f in /system/lib64/libcameraservice.so /system/bin/cameraserver /system/lib64/libcamera_client.so \
         /system/lib64/libcamera2ndk.so /system/lib64/libcamera_metadata.so; do
  [ -f "$f" ] && cp "$f" "$W/bin/" 2>/dev/null
done
sha256sum "$W"/bin/* > "$W/bin/SHA256SUMS" 2>/dev/null
# hashes of the vendor graphics-buffer and camera service files, to compare with OxygenOS
{
  for f in /vendor/bin/hw/vendor.qti.hardware.display.allocator-service /vendor/bin/hw/vendor.qti.camera.provider-service_64 \
           /vendor/lib64/hw/mapper.qti.so /vendor/lib64/libgralloccore.so /vendor/lib64/libgrallocutils.so \
           /vendor/lib64/libgralloc.qti.so /vendor/lib64/libgralloctypes.so /vendor/lib64/libsnapalloc.so \
           /vendor/lib64/vendor.qti.hardware.camera.offlinecamera-service-impl.so /vendor/lib64/camx.device-impl.so \
           /vendor/lib64/camx.provider-impl.so /vendor/lib64/hw/com.qti.chi.override.so /vendor/lib64/hw/camera.qcom.so \
           /odm/lib64/libAlgoProcess.so /odm/lib64/libAlgoInterface.so /system/lib64/libui.so; do
    [ -e "$f" ] && sha256sum "$f" || echo "missing $f"
  done
  ls -la /vendor/lib64/hw | grep -i "mapper\|gralloc\|alloc"
  ls -la /vendor/lib64 | grep -i "snap\|gralloc"
} > "$W/vendor-hashes.txt" 2>&1
# the processing (APS) log files the camera writes itself: newest four, at most ~40 MB in total
mkdir -p "$W/cam_alog"; n=0
for f in $(ls -t /data/vendor/cam_alog 2>/dev/null | head -4); do
  [ -f "/data/vendor/cam_alog/$f" ] || continue
  n=$((n + $(stat -c %s "/data/vendor/cam_alog/$f")))
  [ $n -gt 41943040 ] && break
  cp "/data/vendor/cam_alog/$f" "$W/cam_alog/" 2>/dev/null
done
[ -f "$SNAP" ] && mv "$SNAP" "$W/dumpsys-media.camera-live-session.txt"

tar -czf "$OUT" -C /data/local/tmp "ocam-debug-$TS" 2>/dev/null
rm -rf "$W"
echo "Debug bundle saved: $OUT"
echo "Delete it when you no longer need it."
