#!/system/bin/sh
# OnePlus Camera for LineageOS - early boot (before the camera HAL starts)
MODDIR=${0%/*}

# Data directories the stock camera / APS expect (removed again by uninstall.sh)
mkdir -p /data/system/camera_rus
chmod 0777 /data/system/camera_rus
chown 1047:1047 /data/system/camera_rus   # cameraserver
chcon -R u:object_r:oplus_camera_rus_file:s0 /data/system/camera_rus 2>/dev/null
for d in cam_alog camera_process camera_rus; do
  if [ ! -d /data/vendor/$d ]; then
    mkdir -p /data/vendor/$d && touch /data/vendor/$d/.oplus_camera_module
  fi
  chmod 0777 /data/vendor/$d; chown 1006:1006 /data/vendor/$d   # camera
  chcon -R u:object_r:vendor_camera_data_file:s0 /data/vendor/$d 2>/dev/null
done

# Let the QTI HAL treat the OnePlus camera as a privileged client (runtime only, not persisted)
CUR=$(getprop persist.vendor.camera.privapp.list)
case ",$CUR," in
  *,com.oplus.camera,*) ;;
  *) resetprop -n persist.vendor.camera.privapp.list "${CUR:+$CUR,}com.oplus.camera" ;;
esac

# Optional ODM extras (OEM camera layer + HDR/log helpers): overlay, never written to /odm
if [ -f "$MODDIR/enable_odm_extras" ]; then
  for sub in lib64 lib64/hw lib; do
    src="$MODDIR/extras/odm/$sub"; dst="/odm/$sub"
    [ -d "$src" ] && [ -d "$dst" ] || continue
    mount -t overlay -o "ro,lowerdir=$src:$dst" oplus_camera_odm "$dst" \
      && echo "odm overlay: $dst" >> "$MODDIR/boot.log"
  done
fi
