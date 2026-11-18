#!/system/bin/sh
# Runs once when the module is removed: leave no trace of the camera behind.
MODDIR=${0%/*}
PKG=com.oplus.camera

# App data, caches, profiles and dex artifacts (PackageManager also drops the package on boot)
for d in /data/user/*/$PKG /data/user_de/*/$PKG /data/misc/profiles/cur/*/$PKG /data/misc/profiles/ref/$PKG \
         /data/media/*/Android/data/$PKG /data/media/*/Android/media/$PKG /data/media/*/Android/obb/$PKG \
         /data/dalvik-cache/arm64/*OplusCamera* /data/misc_ce/*/apexdata/*/$PKG; do
  [ -e "$d" ] && rm -rf "$d"
done
rm -rf /data/system/camera_rus
for d in cam_alog camera_process camera_rus; do
  # only remove vendor dirs this module created (marker file), never LineageOS's own
  [ -f /data/vendor/$d/.oplus_camera_module ] && rm -rf /data/vendor/$d
done

# persist.* props the camera created at runtime (anything new since install that is camera/OEM related)
if [ -f "$MODDIR/.persist_before" ]; then
  getprop | sed -n 's/^\[\(persist\.[^]]*\)\].*/\1/p' | sort > /dev/.oplus_cam_after
  comm -13 "$MODDIR/.persist_before" /dev/.oplus_cam_after | grep -iE "oplus|camera|oppo|heytap|coloros" | while read -r p; do
    resetprop -p -d "$p"
  done
  rm -f /dev/.oplus_cam_after
fi
# Photos and videos you took (DCIM) are deliberately kept.
