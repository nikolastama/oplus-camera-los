#!/system/bin/sh
# OnePlus Camera for LineageOS - early boot. Only creates/labels paths this module owns.
MODDIR=${0%/*}

. "$MODDIR/common.sh"

# The Action button's debug run keeps its state in /data/local/tmp. Its props, log size and the
# 20-second snapshot job don't survive a reboot, so neither does that state: a pending marker left
# by a reboot during those 20 s would otherwise block the button for good.
rm -f /data/local/tmp/ocam-snapshot.pending /data/local/tmp/ocam-session-snapshot.txt \
      /data/local/tmp/ocam-session-snapshot.txt.tmp /data/local/tmp/ocam-debug-props.txt
# the installer's mount point for the odm partition, left by an install that stopped early or by
# v0.39 test builds before the fix (nothing is mounted there at boot)
rmdir /data/local/tmp/ocam-odm-ro 2>/dev/null

# Fixed copies of ROM files: after a LineageOS update that changed a ROM file, make its copy again
# from the new file (common.sh, refresh_fixes; logged in fixes.log). This runs before KernelSU's
# metamodule mounts any module file, so /vendor and /odm show the ROM's own files. The metamodule
# mounts its own copy of the module: bring that up to date too, now if it is reachable, otherwise
# from service.sh once it is (then effective from the next boot).
# First add fixes a LineageOS update made necessary (common.sh, adapt_to_rom), then remake copies
# whose ROM file changed.
ADAPTED=$(adapt_to_rom "$MODDIR")
set -- $(refresh_fixes "$MODDIR")
if [ "${ADAPTED:-0}" != 0 ] || [ "${1:-0}" != 0 ] || [ "${2:-0}" != 0 ]; then
  { [ "${ADAPTED:-0}" != 0 ] || [ "${2:-0}" != 0 ]; } && rm -f "$MODDIR/.pruned"   # removed files leave the metamodule's copy too
  # the copy must be current before it is mounted below (otherwise this boot would mount the old
  # files, e.g. the module's previous layer on an updated camera HAL)
  sync_mirror "$MODDIR" || { mount_metamodule_image && sync_mirror "$MODDIR"; } || touch "$MODDIR/.sync_mirror"
fi

# Clear files of older versions out of the metamodule's copy (e.g. v0.35-v0.36's camera service
# copy). Needed once per install, or after the watchdog or the check above removed files. If the
# copy isn't reachable yet, service.sh does it.
if [ ! -f "$MODDIR/.pruned" ]; then
  prune_mirror "$MODDIR" && touch "$MODDIR/.pruned"
fi

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
  # (re)label only when needed: a recursive relabel walks every log file in the directory.
  # A new folder starts open (0777) until tighten_dirs below can give it to the camera app.
  if [ -f "$m" ] && [ "$(ls -dZ "$d" 2>/dev/null | awk '{print $1}')" != "u:object_r:$ctx:s0" ]; then
    [ "$(stat -c %a "$d")" = 2770 ] || { chown "$owner:$owner" "$d"; chmod 0777 "$d"; }
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

# Give the folders above to the camera app (common.sh). No-op once done, or before the app exists.
tighten_dirs "$MODDIR"

# LineageOS creates /data/vendor/cam_alog, /data/vendor/camera_process and camera_remote_dump itself but leaves them
# vendor_data_file, which the camera app may not write (ColorOS/Infinity X label them
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
  [ "$(ls -dZ "$d" 2>/dev/null | awk '{print $1}')" = u:object_r:vendor_camera_data_file:s0 ] ||
    chcon -R u:object_r:vendor_camera_data_file:s0 "$d" 2>/dev/null
done
