#!/system/bin/sh
# OnePlus Camera for LineageOS - early boot. Only creates/labels paths this module owns.
MODDIR=${0%/*}

# Data dirs the OnePlus camera/APS expect. Each is created only if absent and recorded in the
# module's own .created list (nothing is written inside them); a directory that already existed
# (i.e. belongs to LineageOS) is never chowned, relabelled or removed.
for spec in /data/system/camera_rus:1047:oplus_camera_rus_file \
            /data/vendor/cam_alog:1006:vendor_camera_data_file \
            /data/vendor/camera_process:1006:vendor_camera_data_file \
            /data/vendor/camera_rus:1006:vendor_camera_data_file; do
  d=${spec%%:*}; rest=${spec#*:}; owner=${rest%%:*}; ctx=${rest#*:}
  m="$MODDIR/.created/$(echo "$d" | tr / _)"
  if [ ! -e "$d" ]; then
    mkdir -p "$MODDIR/.created" && mkdir "$d" && touch "$m"
  fi
  if [ -f "$m" ]; then
    chown "$owner:$owner" "$d"; chmod 0777 "$d"
    chcon -R "u:object_r:$ctx:s0" "$d" 2>/dev/null
  fi
done
