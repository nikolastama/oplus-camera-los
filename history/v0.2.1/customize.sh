# OnePlus Camera for LineageOS - install-time checks and pre-install snapshots
SKIPUNZIP=0
PKG=com.oplus.camera

ui_print "- OnePlus Camera for LineageOS (OnePlus 15)"
# Read identity from the ROM's build.prop files, not runtime props: Play Integrity / prop-spoofing
# modules commonly hide ro.lineage.* and replace device names at runtime.
fileprop() {
  for f in /system/build.prop /system_ext/etc/build.prop /product/etc/build.prop /vendor/build.prop /odm/etc/build.prop; do
    [ -f "$f" ] && v=$(grep -m1 "^$1=" "$f" | cut -d= -f2-) && [ -n "$v" ] && { echo "$v"; return; }
  done
}
DEVICE=$(fileprop ro.lineage.device)
LOSVER=$(fileprop ro.lineage.build.version)
PRODDEV=$(cat /system/build.prop /system_ext/etc/build.prop /product/etc/build.prop /vendor/build.prop /odm/etc/build.prop 2>/dev/null \
  | grep -m1 -oE '^ro\.product\.([a-z_]+\.)?device=OP611FL1' | cut -d= -f2)
ui_print "  device: ${DEVICE:-?} ($PRODDEV)  LineageOS: ${LOSVER:-none}  SDK: $API"

[ "$DEVICE" = infiniti ] || [ "$PRODDEV" = OP611FL1 ] || abort "! This module is only for the OnePlus 15 (infiniti)."
case "$LOSVER" in 24.*) ;; *) abort "! This module is built for LineageOS 24 only (found '${LOSVER:-none}')." ;; esac
[ "$ARCH" = arm64 ] || abort "! arm64 only"
[ -e /odm/lib64/libAlgoProcess.so ] && [ -e /vendor/lib64/hw/camera.qcom.core.so ] \
  || abort "! OnePlus camera HAL libraries not found on this ROM"

# Refuse if another copy of the OnePlus camera is already installed (ROM or other module)
if pm path $PKG >/dev/null 2>&1 && [ ! -d /data/adb/modules/oplus_camera_los ]; then
  abort "! $PKG is already installed on this system. Remove it first."
fi

# Never shadow a file the ROM ships: every file in this module must be new to the system.
for f in $(cd "$MODPATH/system" && find . -type f | sed 's|^\./||'); do
  [ -e "/system/$f" ] && [ ! -d /data/adb/modules/oplus_camera_los ] && abort "! ROM already has /system/$f - refusing to overlay it."
done

# A fresh install supersedes any cleanup still pending from an earlier removal
rm -rf /data/adb/oplus_camera_cleanup /data/adb/service.d/oplus_camera_cleanup.sh

# Snapshots used by uninstall to remove only what the camera added (kept inside the module dir).
S="$MODPATH/.snapshot"; mkdir -p "$S"
if [ ! -f /data/adb/modules/oplus_camera_los/.snapshot/persist ]; then
  getprop | sed -n 's/^\[\(persist\.[^]]*\)\].*/\1/p' | sort > "$S/persist"
  for t in global system secure; do settings list $t 2>/dev/null | cut -d= -f1 | sort > "$S/settings_$t"; done
else
  cp -f /data/adb/modules/oplus_camera_los/.snapshot/* "$S/"   # module update: keep the original snapshot
fi
# module update: carry over the record of directories this module created
[ -d /data/adb/modules/oplus_camera_los/.created ] && cp -rf /data/adb/modules/oplus_camera_los/.created "$MODPATH/"

set_perm_recursive "$MODPATH" 0 0 0755 0644
for d in system/system_ext/lib64 system/system_ext/priv-app/OplusCamera/lib/arm64; do
  [ -d "$MODPATH/$d" ] && set_perm_recursive "$MODPATH/$d" 0 0 0755 0644 u:object_r:system_lib_file:s0
done

ui_print "- Installed. Reboot, then open 'Camera' (com.oplus.camera)."
ui_print "- Action button saves a debug log to /sdcard/Download."
