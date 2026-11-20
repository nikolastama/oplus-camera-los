#!/system/bin/sh
# OnePlus Camera for LineageOS - self-test, started from the Action button (volume up).
#
# Drives the camera only the way the system and the app itself do: Android's camera intents, the
# app's own portrait launcher shortcut (action SHORTCUT_TYPE_MENU, mode 2) and the volume key, which
# is the camera's shutter by default. Checks that each shot is saved, then looks through the log for
# crashes, camera HAL restarts, lost frames and wrapper errors. The test photos and video are
# deleted again; a report is saved to Download. Nothing on the system is changed.
MODDIR=${0%/*}
PKG=com.oplus.camera
DCIM=/sdcard/DCIM/Camera
TS=$(date +%Y%m%d-%H%M%S)
REPORT=/sdcard/Download/oplus-camera-selftest-$TS.txt
W=/data/local/tmp/ocam-selftest-$TS
PROVIDER=vendor.qti.camera.provider-service_64
mkdir -p "$W"
PASS=0; FAIL=0; NOTE=0

say() { echo "$*"; echo "$*" >> "$REPORT"; }
result() {  # PASS|FAIL|NOTE <text>
  say "$1  $2"
  case $1 in PASS) PASS=$((PASS + 1)) ;; FAIL) FAIL=$((FAIL + 1)) ;; *) NOTE=$((NOTE + 1)) ;; esac
}
media_list() { ls "$DCIM" 2>/dev/null | sort; }
# wait up to <seconds> for a new file in DCIM/Camera matching <pattern>; prints its name
wait_new() {  # <before list> <pattern> <seconds>
  _i=0
  while [ $_i -lt "$3" ]; do
    _n=$(media_list | comm -13 "$1" - | grep -iE "$2" | grep -v '\.pending' | tail -1)
    [ -n "$_n" ] && { echo "$_n"; return 0; }
    sleep 1; _i=$((_i + 1))
  done
  return 1
}
shutter() { input keyevent KEYCODE_VOLUME_DOWN; }
# press the shutter, and again every 3 s while nothing is saved (the app ignores the key while it
# is still busy with the previous shot); prints "<file> <seconds>" once a photo is saved
shoot_until_saved() {  # <before list> <seconds>
  _s=0
  while [ $_s -lt "$2" ]; do
    [ $((_s % 3)) -eq 0 ] && shutter
    _n=$(media_list | comm -13 "$1" - | grep -iE '\.(jpe?g|heic|heif)$' | grep -v '\.pending' | tail -1)
    [ -n "$_n" ] && { echo "$_n $_s"; return 0; }
    sleep 1; _s=$((_s + 1))
  done
  return 1
}
camera_open() { dumpsys media.camera 2>/dev/null | grep -q "Device .* is open"; }
log_since() { logcat -d -b "${2:-all}" -v threadtime -T "$1" 2>/dev/null; }

: > "$REPORT"
say "OnePlus Camera self-test $(grep ^version= "$MODDIR/module.prop" | cut -d= -f2), $(date)"
ROMV=$(getprop ro.lineage.display.version)
say "ROM ${ROMV:+$ROMV, }build $(getprop ro.build.display.id) ($(getprop ro.build.version.incremental))"
say ""

# ---- preconditions
if ! dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake'; then
  say "The screen must be on and unlocked. Nothing was tested."; rm -rf "$W"; exit 1
fi
if camera_open; then
  say "Another app is using the camera. Close it and try again. Nothing was tested."; rm -rf "$W"; exit 1
fi
# Right after boot Android is still compiling apps (and the module precompiles the camera once,
# a minute after boot): shots are slow then and the results aren't meaningful.
if [ "$(cut -d. -f1 /proc/uptime)" -lt 180 ] || pidof dex2oat64 dex2oat >/dev/null 2>&1; then
  say "The phone is still finishing start-up (compiling apps). Try again in a few minutes. Nothing was tested."
  rm -rf "$W"; exit 1
fi
if [ -z "$(pm path $PKG 2>/dev/null)" ]; then
  say "The OnePlus camera isn't installed (reboot after installing the module)."; rm -rf "$W"; exit 1
fi
say "Leave the phone still and pointed at something (a person for the portrait shot) for about 2 minutes."
say ""
# Keep the whole test in the log (the default 256 KB holds ~15 s of a camera session); the full
# log of the test is saved next to the report, then the buffer size is put back.
LOGD=$(logcat -g -b main 2>/dev/null | sed -n 's/.*ring buffer is \([0-9]*\) *\([KM]\).*/\1\2/p' | head -1)
logcat -G 16M >/dev/null 2>&1
START=$(date '+%m-%d %H:%M:%S.000')
P0=$(pidof $PROVIDER)
touch "$W/start"
media_list > "$W/before"

# ---- 1. photo, main camera
am force-stop $PKG
T=$(am start -W -a android.media.action.STILL_IMAGE_CAMERA 2>/dev/null | sed -n 's/^TotalTime: //p')
sleep 5
if pidof $PKG >/dev/null && camera_open; then
  result PASS "camera opens (${T:-?} ms) and shows the preview"
else
  result FAIL "camera did not open or no camera session started"
fi
media_list > "$W/b1"; shutter
if F=$(wait_new "$W/b1" '\.(jpe?g|heic|heif)$' 15); then
  result PASS "photo (main camera): $F"
else
  result FAIL "photo (main camera): nothing saved within 15 s (Settings > Volume button action must be Shutter)"
fi

# ---- 2. portrait (multi-frame: the shutter must be ready again afterwards)
S2=$(date '+%m-%d %H:%M:%S.000')
am start -n $PKG/.Camera -a com.oplus.camera.action.SHORTCUT_TYPE_MENU --ei mode 2 --ez rear true --ez front false >/dev/null 2>&1
sleep 7
media_list > "$W/b2"; shutter
if F=$(wait_new "$W/b2" '\.(jpe?g|heic|heif)$' 25); then
  result PASS "portrait photo: $F"
else
  result FAIL "portrait photo: nothing saved within 25 s"
fi
media_list > "$W/b2b"
if F=$(shoot_until_saved "$W/b2b" 25); then
  result PASS "second portrait photo: shutter ready again, saved ${F##* } s after the first: ${F% *}"
else
  result FAIL "second portrait photo: nothing saved within 25 s (shutter stayed busy)"
fi
L2=$(log_since "$S2" main)
LOST=$(echo "$L2" | grep -c "onCaptureBufferLost")
NOTINC=$(echo "$L2" | grep -c "is not increasing")
FIXED=$(echo "$L2" | grep -c "OplusCamLosWrap.*sent as")
if [ "$(echo "$L2" | grep -c .)" -lt 10 ]; then
  result NOTE "portrait frames: the log couldn't be read, not checked"
elif [ "$LOST" -eq 0 ] && [ "$NOTINC" -eq 0 ]; then
  result PASS "portrait frames: none lost (timestamps raised by the wrapper: $FIXED)"
else
  result FAIL "portrait frames: $LOST lost, $NOTINC out-of-order warnings (wrapper raised $FIXED)"
fi

# ---- 3. photo, front camera
am start -a android.media.action.STILL_IMAGE_CAMERA --ei android.intent.extras.CAMERA_FACING 1 \
  --ez android.intent.extra.USE_FRONT_CAMERA true >/dev/null 2>&1
sleep 6
media_list > "$W/b3"; shutter
if F=$(wait_new "$W/b3" '\.(jpe?g|heic|heif)$' 15); then
  result PASS "photo (front camera, if the app switched to it): $F"
else
  result FAIL "photo (front camera): nothing saved within 15 s"
fi

# ---- 4. video
am start -a android.media.action.VIDEO_CAMERA >/dev/null 2>&1
sleep 6
media_list > "$W/b4"; shutter; sleep 6; shutter
if F=$(wait_new "$W/b4" '\.(mp4|3gp|mov)$' 15); then
  result PASS "video (about 6 s): $F"
else
  result FAIL "video: nothing saved within 15 s"
fi
sleep 2
am force-stop $PKG
sleep 2

# ---- 5. what happened meanwhile
LA=$(log_since "$START")
if [ "$(echo "$LA" | grep -c .)" -lt 10 ]; then
  result NOTE "the log since the start of the test couldn't be read: the log checks below are incomplete"
fi
N=$(echo "$LA" | grep -c "Process: $PKG,\|>>> $PKG <<<")
[ "$N" -eq 0 ] && result PASS "no camera app crash" || result FAIL "camera app crashed ($N log lines, see report)"
P1=$(pidof $PROVIDER)
if [ -n "$P0" ] && [ "$P0" = "$P1" ]; then
  result PASS "camera HAL kept running"
else
  WHY=$(echo "$LA" | grep -oE "vendor.camera-provider' \(pid $P0\) received SIG[A-Z]+" | head -1 | sed 's/.* received //')
  result FAIL "camera HAL restarted during the test (pid $P0 -> ${P1:-none}${WHY:+, it received $WHY})"
fi
TB=$(find /data/tombstones -newer "$W/start" -type f 2>/dev/null | wc -l)
[ "$TB" -eq 0 ] && result PASS "no native crash (tombstone)" || result FAIL "$TB new tombstone(s) in /data/tombstones"
WE=$(echo "$LA" | grep -c " E OplusCamLosWrap")
[ "$WE" -eq 0 ] && result PASS "no wrapper errors" || result FAIL "$WE wrapper error line(s)"
ROUTE=$(echo "$LA" | grep -c "OplusCamLosWrap.*session moved to Qualcomm")
[ "$ROUTE" -eq 0 ] && result PASS "all sessions stayed on the OnePlus layer" ||
  result NOTE "$ROUTE session(s) were moved to Qualcomm's HAL (expected only for other apps)"
[ -f "$MODDIR/oemlayer_disabled" ] && result FAIL "the boot watchdog has switched the OnePlus layer off: $(cat "$MODDIR/oemlayer_disabled")"

# ---- clean up the test photos and video (and their gallery entries)
media_list | comm -13 "$W/before" - | while read -r f; do
  content delete --uri content://media/external/file --where "_data='$DCIM/$f'" >/dev/null 2>&1
  rm -f "$DCIM/$f"
done

# full log of the test next to the report, then the log buffer back to its size
echo "$LA" | gzip -c > "${REPORT%.txt}.log.gz" 2>/dev/null || rm -f "${REPORT%.txt}.log.gz"
[ -n "$LOGD" ] && [ ! -f "$MODDIR/debug" ] && logcat -G "$LOGD" >/dev/null 2>&1

say ""
say "Lens switching and zoom aren't covered: try them by hand."
say "Result: $PASS passed, $FAIL failed, $NOTE notes. Report: $REPORT"
if [ "$FAIL" -gt 0 ]; then
  { echo; echo "==== log lines from the test"; echo "$LA" | grep -E "OplusCamLosWrap|FATAL|AndroidRuntime|onCaptureBufferLost|is not increasing|$PROVIDER|vendor.camera-provider| F DEBUG" | tail -300; } >> "$REPORT"
  say "Something failed: send this report and $(basename "${REPORT%.txt}.log.gz") (both in Download)."
fi
rm -rf "$W"
