#!/system/bin/sh
# OnePlus Camera for LineageOS - late boot.
# Let the QTI camera HAL treat com.oplus.camera as a privileged client. In memory only (-n):
# never written to persistent storage, so it disappears on the next boot after removal.
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
CUR=$(getprop persist.vendor.camera.privapp.list)
case ",$CUR," in
  *,com.oplus.camera,*) ;;
  *) resetprop -n persist.vendor.camera.privapp.list "${CUR:+$CUR,}com.oplus.camera" ;;
esac
