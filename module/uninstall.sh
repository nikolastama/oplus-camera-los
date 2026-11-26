#!/system/bin/sh
# Runs once, early in the first boot after the module is removed (before PackageManager starts).
# Goal: the system ends up exactly as it was before installation. Your photos/videos are kept.
MODDIR=${0%/*}
. "$MODDIR/common.sh"
C=/data/adb/oplus_camera_cleanup

APPUID=$(awk -v p=$PKG '$1==p {print $2}' /data/system/packages.list 2>/dev/null)

# 1) app data, caches, compiled code, profiles (PackageManager also forgets the package this boot)
for d in /data/user/*/$PKG /data/user_de/*/$PKG /data/data/$PKG \
         /data/misc/profiles/cur/*/$PKG /data/misc/profiles/ref/$PKG \
         /data/media/*/Android/data/$PKG /data/media/*/Android/media/$PKG /data/media/*/Android/obb/$PKG \
         /data/media/*/Download/$PKG /data/system/graphicsstats/*/$PKG \
         /data/media/*/Pictures/.camera_cache; do   # the app's thumbnail cache (photos stay in DCIM)
  [ -e "$d" ] && rm -rf "$d"
done
for f in /data/dalvik-cache/*/*OplusCamera* /data/dalvik-cache/*/*com.oplus.camera.unit.sdk* \
         /data/dalvik-cache/*/*oplus-camera-stubs* /data/system/package_cache/*/OplusCamera*; do
  [ -e "$f" ] && rm -rf "$f"
done

# 1a) leftovers of the debug button (session snapshot / scratch dirs)
rm -rf /data/local/tmp/ocam-debug-* /data/local/tmp/ocam-selftest-* /data/local/tmp/ocam-session-snapshot.txt* /data/local/tmp/ocam-snapshot.pending
rmdir /data/local/tmp/ocam-odm-ro 2>/dev/null   # the installer's odm mount point
# debug bundles the Action button saved to Download
rm -f /data/media/*/Download/oplus-camera-debug-*.tar.gz /data/media/*/Download/oplus-camera-selftest-*.txt \
      /data/media/*/Download/oplus-camera-selftest-*.log.gz
# 1b) LineageOS directories this module relabelled: put their original label back
for r in "$MODDIR"/.relabeled/*; do
  [ -f "$r" ] || continue
  read -r d ctx < "$r"
  [ -d "$d" ] || continue
  # restorecon gives every file inside the label LineageOS's file_contexts assigns it; the folder
  # itself gets back exactly the label it had
  restorecon -RF "$d" 2>/dev/null || chcon -R "$ctx" "$d" 2>/dev/null
  [ "$(ls -dZ "$d" 2>/dev/null | awk '{print $1}')" = "$ctx" ] || chcon "$ctx" "$d" 2>/dev/null
done
# 2) directories this module created (recorded in .created; LineageOS's own are never touched)
for d in /data/system/camera_rus /data/vendor/cam_alog /data/vendor/camera_process /data/vendor/camera_rus; do
  [ -f "$MODDIR/.created/$(marker "$d")" ] && rm -rf "$d"
done

# 2a) this module's copy inside the metamodule image (normally removed by the metamodule too)
for root in $METAMODULE_MNTS; do
  [ -d "$root/$MODID" ] && [ "$(readlink -f "$root/$MODID")" != "$(readlink -f "$MODDIR")" ] && rm -rf "$root/$MODID"
done

# 3) crash reports of the camera's own processes (com.oplus.camera and com.oplus.camera:<name>).
#    Reports of other processes that merely mention the package (system-wide traces) are kept.
#    Text tombstones name the process as ">>> name <<<", ANR traces as "Cmd line: name", app crash
#    and ANR dropbox entries as "Process: name"; a tombstone's .pb twin goes with its text form.
OWN='(>>> com\.oplus\.camera(:[^ ]*)? <<<|^Cmd line: com\.oplus\.camera(:.*)?$|^Process: com\.oplus\.camera(:.*)?$)'
for f in /data/tombstones/* /data/anr/*; do
  case "$f" in *.pb) continue ;; esac
  [ -f "$f" ] && grep -qE "$OWN" "$f" 2>/dev/null && rm -f "$f" "$f.pb"
done
for f in /data/system/dropbox/*; do
  case "$f" in
    *.gz) zcat "$f" 2>/dev/null | grep -qE "$OWN" && rm -f "$f" ;;
    *)    grep -qE "$OWN" "$f" 2>/dev/null && rm -f "$f" ;;
  esac
done

# 4) things that need the full system running (settings, persistent props, leftover files owned by
#    the camera's UID): handed to a one-shot late-boot script that deletes itself afterwards.
mkdir -p $C
cp -f "$MODDIR"/.snapshot/* $C/ 2>/dev/null
echo "$APPUID" > $C/uid
[ -d /data/adb/service.d ] || { mkdir -p /data/adb/service.d && touch $C/created_serviced; }
cat > /data/adb/service.d/oplus_camera_cleanup.sh <<'EOS'
#!/system/bin/sh
PKG=com.oplus.camera
C=/data/adb/oplus_camera_cleanup
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
sleep 5
RP=$(command -v resetprop)
for c in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop /debug_ramdisk/resetprop /sbin/resetprop; do [ -z "$RP" ] && [ -x "$c" ] && RP=$c; done
# still installed (e.g. module re-added before this ran): keep this script for a later boot
[ -n "$(pm path $PKG 2>/dev/null)" ] && exit 0
if [ -d $C ]; then
  # settings keys the camera writes, only if they did not exist before installation
  # (every key the camera's code writes, found by scanning all Settings.put* call sites)
  for t in global system secure; do
    [ -f $C/settings_$t ] || continue
    printf '%s\n' oplus.camera.flash temperature_o_camera_flash_status under_water_camera_status \
      oplus_customize_eye_protect_enable temperature_o_camera_open temperature_o_camera_video_scene \
      oplus_camera_continue_page_state oplus_outcamera_state mag_handle_gatt_connected \
      customize_breath_light_master_switch oplus_camera_record_dolby oplus_camera_mode_state \
      "com.oplus.camera quick launch" |
    while read -r k; do
      grep -qxF "$k" $C/settings_$t && continue
      [ "$(settings get $t "$k")" != null ] && settings delete $t "$k" >/dev/null 2>&1
    done
  done
  # persistent props the camera can create, only if new since installation (skipped without snapshot)
  if [ -s $C/persist ]; then
    getprop | sed -n 's/^\[\(persist\.[^]]*\)\].*/\1/p' | sort > $C/persist_now
    comm -13 $C/persist $C/persist_now | grep -E '^persist\.(oplus\.aps\.|otest\.|sys\.oplus\.camera|oplus\.camera|vendor\.camera\.autoImageDump)' |
      while read -r p; do [ -n "$RP" ] && "$RP" -p -d "$p"; done
  fi
  # any file still owned by the camera's old UID (outside your media), e.g. HAL-side dumps
  U=$(cat $C/uid 2>/dev/null)
  # never sweep a UID that PackageManager has since given to another app
  if [ -n "$U" ] && [ "$U" -ge 10000 ] 2>/dev/null && ! awk -v u="$U" '$2==u {f=1} END {exit !f}' /data/system/packages.list; then
    find /data -xdev \( -path /data/media -o -path /data/adb \) -prune -o -user "$U" -print 2>/dev/null |
      while read -r f; do rm -rf "$f"; done
  fi
fi
CREATED=0; [ -f $C/created_serviced ] && CREATED=1
rm -rf $C
rm -f /data/adb/service.d/oplus_camera_cleanup.sh
[ $CREATED = 1 ] && rmdir /data/adb/service.d 2>/dev/null
EOS
chmod 0755 /data/adb/service.d/oplus_camera_cleanup.sh
