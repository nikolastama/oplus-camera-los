#!/system/bin/sh
# OnePlus Camera for LineageOS - early boot. Only creates/labels paths this module owns.
MODDIR=${0%/*}

. "$MODDIR/common.sh"

# The fixed camera service copy belongs to the ROM build it was made from. After a LineageOS update
# it would shadow the new build's cameraserver, so drop it (the stock camera service is used until
# the module is flashed again) and let service.sh tell the user.
if [ -f "$MODDIR/system/bin/cameraserver" ] && [ "$(cat "$MODDIR/.rom_build" 2>/dev/null)" != "$(rom_build)" ]; then
  rm -f "$MODDIR/system/bin/cameraserver"; rmdir "$MODDIR/system/bin" 2>/dev/null
  sed -i '/^bin\/cameraserver /d' "$MODDIR/.fixed" 2>/dev/null
  echo "$(date) $(rom_build)" > "$MODDIR/rom_updated"
fi

# Clear files of older versions (and the copy dropped above) out of the metamodule's copy.
prune_mirror "$MODDIR"

# Data dirs the OnePlus camera/APS expect. Each is created only if absent and recorded in the
# module's own .created list (nothing is written inside them). A directory that already existed
# (i.e. belongs to LineageOS) is never chowned or removed; see below for its label.
for spec in /data/system/camera_rus:1047:oplus_camera_rus_file \
            /data/vendor/cam_alog:1006:vendor_camera_data_file \
            /data/vendor/camera_process:1006:vendor_camera_data_file \
            /data/vendor/camera_rus:1006:vendor_camera_data_file; do
  d=${spec%%:*}; rest=${spec#*:}; owner=${rest%%:*}; ctx=${rest#*:}
  m="$MODDIR/.created/$(marker "$d")"
  if [ ! -e "$d" ]; then
    mkdir -p "$MODDIR/.created" && mkdir "$d" && touch "$m"
  fi
  if [ -f "$m" ]; then
    chown "$owner:$owner" "$d"; chmod 0777 "$d"
    chcon -R "u:object_r:$ctx:s0" "$d" 2>/dev/null
  fi
done

# The processing stage keeps per-job size records in camera_rus/jobSize; create it inside the
# module-created camera_rus only (removed with it on uninstall).
if [ -f "$MODDIR/.created/_data_system_camera_rus" ] && [ ! -d /data/system/camera_rus/jobSize ]; then
  mkdir /data/system/camera_rus/jobSize && chown 1047:1047 /data/system/camera_rus/jobSize &&
    chmod 0777 /data/system/camera_rus/jobSize &&
    chcon u:object_r:oplus_camera_rus_file:s0 /data/system/camera_rus/jobSize 2>/dev/null
fi

# LineageOS creates /data/vendor/cam_alog, /data/vendor/camera_process and camera_remote_dump itself but leaves them
# vendor_data_file, which the camera app may not write (OxygenOS/Infinity X label them
# vendor_camera_data_file). Relabel those three, saving the original label first in the module's
# .relabeled list; uninstall.sh puts the saved label back.
for d in /data/vendor/cam_alog /data/vendor/camera_process /data/vendor/camera_remote_dump; do
  [ -d "$d" ] || continue
  m="$MODDIR/.created/$(marker "$d")"; [ -f "$m" ] && continue
  r="$MODDIR/.relabeled/$(marker "$d")"
  if [ ! -f "$r" ]; then
    orig=$(ls -dZ "$d" 2>/dev/null | awk '{print $1}')
    case "$orig" in u:object_r:*:s0) mkdir -p "$MODDIR/.relabeled" && echo "$d $orig" > "$r" ;; *) continue ;; esac
  fi
  chcon -R u:object_r:vendor_camera_data_file:s0 "$d" 2>/dev/null
done
