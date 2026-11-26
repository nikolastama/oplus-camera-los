#!/system/bin/sh
# OnePlus Camera for LineageOS - late boot.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

# Let LineageOS's camera service treat com.oplus.camera as a privileged client (all lenses). Only
# this package is affected. In memory only (-n): never written to persistent storage, so it is
# gone on the next boot after removal. Set before boot completes (persistent props are loaded by
# this stage), so a camera opened right after boot already gets every lens.
CUR=$(getprop persist.vendor.camera.privapp.list)
case ",$CUR," in
  *,com.oplus.camera,*) ;;
  *) resetprop -n persist.vendor.camera.privapp.list "${CUR:+$CUR,}com.oplus.camera" ;;
esac

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
# Metamodule copy work post-fs-data.sh couldn't do because the copy wasn't mounted yet (common.sh)
# This boot then runs on outdated module files: the crash watchdogs below would judge those, not
# the files the next boot mounts, so they sit this boot out.
STALE=0
if [ -f "$MODDIR/.sync_mirror" ]; then
  STALE=1
  sync_mirror "$MODDIR" && rm -f "$MODDIR/.sync_mirror"
fi
if [ ! -f "$MODDIR/.pruned" ]; then
  prune_mirror "$MODDIR" && touch "$MODDIR/.pruned"
fi
# First boot after install: the camera app now exists, so its data folders can be given to it
# (common.sh; a no-op on later boots, post-fs-data.sh already did it).
tighten_dirs "$MODDIR"

# Precompile the camera once (v0.37). LineageOS only verifies preinstalled apps at boot, so the
# camera ran interpreted/JIT until Android's idle-and-charging job compiled it. Jetpack's documented
# sequence: ProfileInstaller (inside the app) installs the app's bundled baseline profile, then
# ART compiles just the code that profile lists (speed-profile: small, quick). Only while the
# camera is still at "verify" (left alone if Android already compiled it), once per ROM build and
# APK, a minute after boot in the background. The compiled code and profile are Android's usual
# files for the app; uninstall.sh removes them with the app.
precompile() {
  _pc_key="$(getprop ro.build.fingerprint) $(stat -c %Y /system_ext/priv-app/OplusCamera/OplusCamera.apk 2>/dev/null)"
  [ "$(cat "$MODDIR/.precompiled" 2>/dev/null)" = "$_pc_key" ] && return 0
  sleep 60
  dumpsys package "$PKG" 2>/dev/null | grep -m1 -q '\[status=verify\]' || return 0
  echo "$_pc_key" > "$MODDIR/.precompiled"   # one attempt, even if it fails
  am broadcast -f 0x20 -a androidx.profileinstaller.action.INSTALL_PROFILE \
    -n "$PKG/androidx.profileinstaller.ProfileInstallReceiver" >/dev/null 2>&1
  sleep 5
  cmd package compile -m speed-profile -f "$PKG" >/dev/null 2>&1
}
precompile &
# Debug mode (opt-in, off by default so the module changes nothing outside the camera): create
# $MODDIR/debug to get 16 MB log buffers, so a camera failure isn't pushed out of the log before
# the Action button saves the debug bundle. Runtime-only; gone on the next boot without the file.
[ -f "$MODDIR/debug" ] && logcat -G 16M >/dev/null 2>&1

# Watchdog for the OnePlus camera layer: if the camera HAL keeps dying after boot, take the wrapper
# and layer copies out of the module so the next boot uses LineageOS's layer without the wrapper,
# and tell the user.
L="$MODDIR/system/odm/lib64/hw/camera.oemlayer.v2.so"
if [ -f "$L" ] && [ $STALE = 0 ]; then
  # check for 10 minutes after boot (covers the first camera launches), every 30 s. Cheap on
  # purpose: only the small crash buffer is read each time; the large main buffer only when the
  # camera HAL has (re)started and loaded the layer.
  i=0; PP=
  while [ $i -lt 20 ] && [ -f "$L" ]; do
    sleep 30; i=$((i+1))
    # distinct crashed processes whose backtrace runs through the layer or its private libs
    N=$(logcat -d -b crash 2>/dev/null | grep -E " F DEBUG +: +#[0-9]+ pc .*camera\.oemlayer" | awk '{print $3}' | sort -u | wc -l)
    P=$(pidof vendor.qti.camera.provider-service_64); BAD=0
    if [ "$P" != "$PP" ]; then
      PP=$P
      BAD=$(logcat -d -b main 2>/dev/null | grep -cE "oemlayer\.v2\.so.*(dlopen failed|cannot locate symbol)")
    fi
    if [ "${N:-0}" -ge 2 ] || [ "${BAD:-0}" -ge 1 ]; then
      drop_files "$MODDIR" $LAYER_FILES   # wrapper and layer copies (common.sh); also off the refresh list
      echo "$(date) provider_crashes=$N load_errors=$BAD" > "$MODDIR/oemlayer_disabled"
      rm -f "$MODDIR/.pruned"   # next boot removes the layer from the metamodule's copy too
      cmd notification post -S bigtext -t "OnePlus Camera module" oplus_camera_los \
        "The OnePlus camera layer made the camera HAL crash, so it has been switched off. Reboot to restore all cameras." >/dev/null 2>&1
    fi
  done
fi
