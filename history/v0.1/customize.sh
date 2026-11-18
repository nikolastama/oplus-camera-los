# OnePlus Camera for LineageOS - install-time checks
SKIPUNZIP=0

ui_print "- OnePlus Camera for LineageOS (OnePlus 15)"
DEVICE=$(getprop ro.lineage.device); [ -z "$DEVICE" ] && DEVICE=$(getprop ro.product.device)
LOSVER=$(getprop ro.lineage.build.version)
ui_print "  device: $DEVICE  LineageOS: ${LOSVER:-none}  SDK: $API"

case "$DEVICE" in
  infiniti) ;;
  *) abort "! This module is only for the OnePlus 15 (infiniti)." ;;
esac
case "$LOSVER" in
  24.*) ;;
  *) ui_print "! Built for LineageOS 24; found '${LOSVER:-unknown}'. Installing anyway." ;;
esac
[ "$ARCH" = "arm64" ] || abort "! arm64 only"

# The camera HAL and its OnePlus libraries must already be on the device (LineageOS ships them).
for f in /odm/lib64/libAlgoProcess.so /vendor/lib64/hw/camera.qcom.core.so; do
  [ -e "$f" ] || ui_print "! missing $f - some OnePlus features may not work"
done
[ -e /odm/lib64/libAlgoProcess.so ] || abort "! OnePlus camera HAL libraries not found on this ROM"

# Never shadow a file the ROM already ships.
CLASH=0
for f in $(cd "$MODPATH/system" && find . -type f | sed 's|^\./||'); do
  if [ -e "/system/$f" ]; then ui_print "! ROM already has /system/$f"; CLASH=1; fi
done
[ $CLASH = 0 ] || abort "! Refusing to overlay ROM files. Report this."

# Remember which persist.* props exist now, so uninstall only removes ones the camera added.
getprop | sed -n 's/^\[\(persist\.[^]]*\)\].*/\1/p' | sort > "$MODPATH/.persist_before"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/system/system_ext/priv-app" 0 0 0755 0644
for d in "$MODPATH/system/system_ext/lib64" "$MODPATH/system/lib64" "$MODPATH/system/vendor/lib64" "$MODPATH/system/system_ext/priv-app/OplusCamera/lib/arm64"; do
  [ -d "$d" ] && set_perm_recursive "$d" 0 0 0755 0644 u:object_r:system_lib_file:s0
done
[ -d "$MODPATH/system/vendor/lib64" ] && set_perm_recursive "$MODPATH/system/vendor/lib64" 0 0 0755 0644 u:object_r:vendor_file:s0
set_perm_recursive "$MODPATH/extras" 0 0 0755 0644 u:object_r:vendor_file:s0
[ -d "$MODPATH/extras/odm/lib64/hw" ] && set_perm_recursive "$MODPATH/extras/odm/lib64/hw" 0 0 0755 0644 u:object_r:vendor_file:s0

ui_print "- Installed. Reboot, then open 'Camera' (com.oplus.camera)."
ui_print "- Module action button: toggles the optional ODM extras and saves a debug log."
