#!/system/bin/sh
# OnePlus Camera for LineageOS - late boot.
# Let the QTI camera HAL treat com.oplus.camera as a privileged client. In memory only (-n):
# never written to persistent storage, so it disappears on the next boot after removal.
MODDIR=${0%/*}
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
CUR=$(getprop persist.vendor.camera.privapp.list)
case ",$CUR," in
  *,com.oplus.camera,*) ;;
  *) resetprop -n persist.vendor.camera.privapp.list "${CUR:+$CUR,}com.oplus.camera" ;;
esac

# Watchdog for the OnePlus camera layer: if the camera HAL keeps dying after boot, take the layer
# out of the module so the next boot is back to LineageOS's own camera path, and tell the user.
L="$MODDIR/system/vendor/lib64/hw/camera.oemlayer.v2.so"
if [ -f "$L" ]; then
  # check for 10 minutes after boot (covers the first camera launches), every 30 s
  i=0
  while [ $i -lt 20 ] && [ -f "$L" ]; do
    sleep 30; i=$((i+1))
    # distinct crashed processes whose backtrace runs through the layer or its private libs
    N=$(logcat -d -b crash,main 2>/dev/null | grep -E " F DEBUG +: +#[0-9]+ pc .*(camera\.oemlayer|libsensorbridg2)" | awk '{print $3}' | sort -u | wc -l)
    BAD=$(logcat -d 2>/dev/null | grep -cE "oemlayer\.v2\.so.*(dlopen failed|cannot locate symbol)")
    if [ "${N:-0}" -ge 2 ] || [ "${BAD:-0}" -ge 1 ]; then
      rm -f "$L" "$MODDIR/system/vendor/lib64/libsensorbridg2.so" "$MODDIR/system/vendor/lib64/camera.oemlayer.uilaye2.so"
      echo "$(date) provider_crashes=$N load_errors=$BAD" > "$MODDIR/oemlayer_disabled"
      cmd notification post -S bigtext -t "OnePlus Camera module" oplus_camera_los \
        "The OnePlus camera layer made the camera HAL crash, so it has been switched off. Reboot to restore all cameras." >/dev/null 2>&1
    fi
  done
fi
