#!/system/bin/sh
# Module action button: save one complete debug bundle to Download (nothing on the system is changed),
# or run the self-test (selftest.sh).
# Everything is unfiltered so a single run answers as many questions as possible.
MODDIR=${0%/*}
TS=$(date +%Y%m%d-%H%M%S)

# Press 1: schedule a snapshot of the live camera session (stream sizes/formats the HAL was given),
# taken 20 s later while the OnePlus camera is open. Press 2: collect everything.
SNAP=/data/local/tmp/ocam-session-snapshot.txt
# Debug settings changed by the first press, with their previous values (restored by the second).
DBG=/data/local/tmp/ocam-debug-props.txt
# A pending marker older than a minute belongs to a snapshot job that never finished (the 20-second
# job was killed); post-fs-data.sh also clears it at boot.
PENDING=/data/local/tmp/ocam-snapshot.pending
[ -n "$(find "$PENDING" -mmin +1 2>/dev/null)" ] && rm -f "$PENDING"
DEBUG_PROPS="persist.camera.aps.core.infoMask persist.camera.aps.core.debugMask persist.camera.aps.core.warningMask
  persist.vendor.camera.oplus.enableLogging persist.camera.logWarningMask oplus.autotest.camera.debug.forcelog
  persist.camera.assert.panic persist.sys.assert.panic"
# A fresh press offers the self-test (selftest.sh) instead of a debug run. Volume up: self-test.
# Volume down, no key within 10 s, or no key reader: the debug bundle, as before.
if [ ! -f "$SNAP" ] && [ ! -f "$PENDING" ] && [ -f "$MODDIR/selftest.sh" ] \
   && command -v getevent >/dev/null; then
  echo "Volume up: self-test (about 2 minutes, phone unlocked)"
  echo "Volume down, or wait 10 seconds: debug bundle"
  KEY=$(timeout 10 getevent -lq 2>/dev/null | grep -m1 -oE 'KEY_VOLUME(UP|DOWN)')
  if [ "$KEY" = KEY_VOLUMEUP ]; then
    sh "$MODDIR/selftest.sh"
    exit 0
  fi
  echo ""
fi
if [ ! -f "$SNAP" ] && [ ! -f "$PENDING" ]; then
  touch "$PENDING"
  # Turn on the camera app's own processing (APS) logs and the HAL's logs for this debug run
  # (runtime values only; nothing is written to persistent storage), then restart both so they
  # pick the settings up. The previous values are saved and put back by the second press, since
  # verbose camera logging and raw frame dumps cost battery and storage on every shot.
  : > "$DBG"
  for p in $DEBUG_PROPS; do echo "$p=$(getprop "$p")" >> "$DBG"; done
  echo "logd=$(logcat -g -b main 2>/dev/null | sed -n 's/.*ring buffer is \([0-9]*\) *\([KM]\).*/\1\2/p' | head -1)" >> "$DBG"
  for k in infoMask debugMask warningMask; do resetprop -n persist.camera.aps.core.$k 0xffffffff; done
  resetprop -n persist.vendor.camera.oplus.enableLogging true
  resetprop -n persist.camera.logWarningMask 0xffffffff
  # The OnePlus camera layer (OemLayer) only logs when it believes it runs on a test build.
  resetprop -n oplus.autotest.camera.debug.forcelog true
  resetprop -n persist.camera.assert.panic true
  resetprop -n persist.sys.assert.panic true
  # The default 256 KB log buffers hold only ~15 s of a verbose camera session; 16 MB holds
  # ~15 min. Runtime-only; restored by the second press (or the next boot).
  logcat -G 16M >/dev/null 2>&1
  am force-stop com.oplus.camera >/dev/null 2>&1
  pkill -f camera.provider-service >/dev/null 2>&1
  ( sleep 20; dumpsys media.camera > "$SNAP.tmp" 2>&1; mv "$SNAP.tmp" "$SNAP"
    rm -f "$PENDING" ) >/dev/null 2>&1 &
  echo "Step 1 done. Now, within 20 seconds: open the OnePlus camera and leave it on the preview."
  echo "Stay on the preview for about 30 seconds, then take a photo."
  echo "Afterwards come back here and press the action button again to save the bundle."
  exit 0
fi
[ -f "$PENDING" ] && { echo "The session snapshot is still pending (20 s after the first press). Try again in a few seconds."; exit 0; }
W=/data/local/tmp/ocam-debug-$TS
mkdir -p "$W"
OUT=/sdcard/Download/oplus-camera-debug-$TS.tar.gz

{
  echo "== module $(grep ^version= "$MODDIR/module.prop")"
  echo "== kernel $(uname -r)"; getprop ro.lineage.version; getprop ro.build.fingerprint
  echo "== layer"; ls -laZ /odm/lib64/hw/camera.oemlayer.v2.so /odm/lib64/camera.oemlayer.v2.so /odm/lib64/camera.oemlayer.uilaye2.so /odm/lib64/libOplusSecurity.so 2>&1
  echo "== mounts on /vendor /odm /system_ext (mountinfo)"; grep -E " /(vendor|odm|system_ext)(/| )" /proc/self/mountinfo | cut -c1-400
  echo "== overlay mounts"; grep -E " overlay " /proc/self/mountinfo | cut -c1-500
  echo "== hw dirs"; for d in /vendor/lib64/hw /odm/lib64/hw /vendor/odm /odm; do ls -ldZi "$d" 2>&1; stat -f -c "%T %i" "$d" 2>&1; done
  echo "== metamodule copy labels"; for r in /data/adb/metamodule/mnt /data/adb/modules/meta-overlayfs/mnt; do ls -RlZ "$r/oplus_camera_los/system/odm" 2>/dev/null | head -20; done
  echo "== every module that ships vendor or odm files"; for m in /data/adb/modules/*/ /data/adb/metamodule/mnt/*/; do for p in system/vendor vendor system/odm odm; do [ -e "$m$p" ] && echo "$m$p"; done; done
  echo "== directory labels (must match the ROM: lib64 vendor_file, hw vendor_hal_file)"; ls -dZ /odm/lib64 /odm/lib64/hw /vendor/lib64/hw /system_ext/lib64 /system_ext/priv-app 2>&1
  echo "== metamodule copy of this module (must not contain system/vendor)"; for r in /data/adb/metamodule/mnt /data/adb/modules/meta-overlayfs/mnt; do [ -d "$r/oplus_camera_los/system" ] && ls "$r/oplus_camera_los/system" | sed "s|^|$r: |"; done
  echo "== recent denials touching module paths"; logcat -d -b all 2>/dev/null | grep "avc: *denied" | grep -E 'dev="overlay"|name="hw"|oemlayer|OplusCamera' | tail -20
  [ -f "$MODDIR/oemlayer_disabled" ] && { echo "!! watchdog disabled the layer:"; cat "$MODDIR/oemlayer_disabled"; }
  [ -f "$MODDIR/fixes.log" ] && { echo "== library fixes remade or switched off after LineageOS updates:"; cat "$MODDIR/fixes.log"; }
  [ -f "$MODDIR/.sync_mirror" ] && echo "!! metamodule copy not yet updated (done at the next boot's service stage)"
  echo "== data dirs"; ls -ldZ /data/vendor/cam_alog /data/vendor/camera_process /data/vendor/camera_rus /data/system/camera_rus 2>&1
  echo "== relabeled"; cat "$MODDIR"/.relabeled/* 2>/dev/null
  echo "== camera_remote_dump"; ls -laZR /data/vendor/camera_remote_dump 2>&1 | head -60
  echo "== camera_process"; ls -laZ /data/vendor/camera_process 2>&1 | head -40
  echo "== cam_alog"; ls -laZ /data/vendor/cam_alog 2>&1 | head -40
  echo "== logd buffer"; logcat -g 2>&1 | head -6
  echo "== app uid"; stat -c %u /data/data/com.oplus.camera 2>&1
  echo "== compiled code (precompile: $(cat "$MODDIR/.precompiled" 2>/dev/null || echo not run))"; dumpsys package com.oplus.camera 2>/dev/null | grep -m2 "status="
  echo "== library fixes (module copies of ROM files: copy, label, ROM file, its sha256, offset, original, fixed)"
  cat "$MODDIR/.fixed" 2>&1
  # each fixed copy: is it in place, and is the ROM file still the one it was made from?
  . "$MODDIR/common.sh" 2>/dev/null
  while read -r f ctx rom sha off o n; do
    [ -n "$rom" ] || { echo "$f: (no ROM record)"; continue; }
    if [ ! -f "$MODDIR/system/$f" ]; then st="copy missing"
    elif [ "$(sha256sum "$MODDIR/system/$f" | cut -d' ' -f1)" = "$(sha256sum "/$f" 2>/dev/null | cut -d' ' -f1)" ]; then st="mounted"
    else st="NOT the mounted file (metamodule copy outdated?)"; fi
    echo "$f: $st, edits at $off, made from $rom"
  done < "$MODDIR/.fixed" 2>/dev/null
  echo "module ships the camera app's own files (LineageOS no longer does): $(wc -l < "$MODDIR/.app_blobs" 2>/dev/null || echo no)"
  echo "== camera app files (module blobs.img, mounted by post-mount.sh)"; grep -E "oplus_camera_blobs|$MODDIR/blobs" /proc/mounts; cat "$MODDIR/mount.log" 2>&1 | tail -6
  ls -lZ /odm/lib64/libAlgoProcess.so /odm/etc/camera/singleblur/personseg.bin 2>&1
  echo "OnePlus camera layer: $(if grep -q '^odm/lib64/camera.oemlayer.v2.so .* /odm/lib64/hw/' "$MODDIR/.fixed" 2>/dev/null; then echo "LineageOS's, wrapped"; else echo "LineageOS's, not wrapped"; fi)"
  ls -lZ /vendor/lib64/libdscaalgo.so 2>&1
  grep -h "libcamxofehwl\|libdscaalgo\|libcamxtintless\|libEIS\|oemlayer" /proc/$(pidof vendor.qti.camera.provider-service_64 | cut -d" " -f1)/maps 2>/dev/null | awk '{print $6}' | sort -u
  echo "face detection (HW config): $(grep -m1 -E 'fdSupport *=' /odm/etc/camera/CameraHWConfiguration.config 2>&1 | tr -s ' ') (TRUE = fixed, FALSE = LineageOS)"
  echo "encoder buffer cap (wrapper): persist.vendor.camera.oplus_los.encbuf=$(getprop persist.vendor.camera.oplus_los.encbuf) (empty = 40, 0 = no cap)"
  echo "frame-timestamp fix (wrapper): persist.vendor.camera.oplus_los.tsfix=$(getprop persist.vendor.camera.oplus_los.tsfix) (empty = on)"
  ls -lZ /system/bin/cameraserver   # the ROM's own; the module doesn't replace it since v0.37
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
# the device's own camera service binaries, so fixes can be checked against the exact build
mkdir -p "$W/bin"
for f in /system/lib64/libcameraservice.so /system/bin/cameraserver /system/lib64/libcamera_client.so \
         /system/lib64/libcamera2ndk.so /system/lib64/libcamera_metadata.so; do
  [ -f "$f" ] && cp "$f" "$W/bin/" 2>/dev/null
done
sha256sum "$W"/bin/* > "$W/bin/SHA256SUMS" 2>/dev/null
# hashes of the vendor graphics-buffer and camera service files, to compare with ColorOS
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
# the processing (APS) log files the camera writes itself: the newest ones, ~40 MB in total. With
# debug logging a single file reaches 50 MB in a minute, so a file larger than what is left of the
# budget is cut to its last part (the most recent lines) instead of being skipped.
mkdir -p "$W/cam_alog"; left=41943040
for f in $(ls -t /data/vendor/cam_alog 2>/dev/null | head -4); do
  F=/data/vendor/cam_alog/$f
  [ -f "$F" ] || continue
  s=$(stat -c %s "$F")
  if [ "$s" -le "$left" ]; then
    cp "$F" "$W/cam_alog/" 2>/dev/null; left=$((left - s))
  else
    tail -c "$left" "$F" > "$W/cam_alog/$f.tail" 2>/dev/null; break
  fi
done
[ -f "$SNAP" ] && mv "$SNAP" "$W/dumpsys-media.camera-live-session.txt"

tar -czf "$OUT" -C /data/local/tmp "ocam-debug-$TS" 2>/dev/null
rm -rf "$W"

# Put the debug settings of the first press back, and restart the camera app and HAL (only when
# the camera isn't in use) so they stop verbose logging and raw frame dumps right away.
if [ -f "$DBG" ]; then
  while IFS='=' read -r p v; do
    case "$p" in
      logd) [ -f "$MODDIR/debug" ] || [ -z "$v" ] || logcat -G "$v" >/dev/null 2>&1 ;;
      *) if [ -n "$v" ]; then resetprop -n "$p" "$v"; else resetprop -d "$p" >/dev/null 2>&1; fi ;;
    esac
  done < "$DBG"
  rm -f "$DBG"
  if ! dumpsys media.camera 2>/dev/null | grep -q "Device .* is open"; then
    am force-stop com.oplus.camera >/dev/null 2>&1
    pkill -f camera.provider-service >/dev/null 2>&1
  fi
  echo "Debug logging switched back off."
fi
echo "Debug bundle saved: $OUT"
echo "Delete it when you no longer need it."
