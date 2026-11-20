# OnePlus Camera for LineageOS - shared by customize.sh, post-fs-data.sh and uninstall.sh.
# Sourced, never run on its own (KernelSU doesn't run module files with this name).

MODID=oplus_camera_los
PKG=com.oplus.camera
MODULES=/data/adb/modules
# the installed module; during an update this is still the previous version
INSTALLED=$MODULES/$MODID
# where metamodules keep their own copy of each module's files
METAMODULE_MNTS="/data/adb/metamodule/mnt $MODULES/meta-overlayfs/mnt $MODULES/meta-mountify/mnt"

# File name that records a /data path in .created/ and .relabeled/: /data/vendor/x -> _data_vendor_x
marker() { echo "$1" | tr / _; }

# The camera app's user id for user 0, from the package manager's list (empty until the app has
# been installed, i.e. on the first boot after flashing). Only regular app ids are accepted.
app_uid() {
  _au=$(awk -v p="$PKG" '$1 == p { print $2; exit }' "${PACKAGES_LIST:-/data/system/packages.list}" 2>/dev/null)
  case "$_au" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_au" -ge 10000 ] && [ "$_au" -lt 20000 ] && echo "$_au"
}

# Data folders this module created (listed in <module>/.created): owned by the camera app instead
# of open to everyone (they were mode 0777 before v0.37). Folders the HAL may use keep the camera
# group (the camera HAL runs in it); /data/system/camera_rus gets the app's shared group, which
# Android gives the camera in every user, so a second user's or work profile's camera can use it
# too. setgid keeps the group on files and folders created inside. Folders that belong to
# LineageOS are never changed. Until the app id is known (first boot after install) the folders
# keep their creation mode, so the camera never loses access; service.sh calls this again once
# the app is installed.
DATA_DIRS="/data/system/camera_rus:shared /data/system/camera_rus/jobSize:shared
/data/vendor/cam_alog:1006 /data/vendor/camera_process:1006 /data/vendor/camera_rus:1006"
tighten_dirs() {  # <module dir>
  _td_uid=$(app_uid) || return 0
  _td_shared=$((_td_uid - 10000 + 50000))   # UserHandle.getSharedAppGid
  for _td in $DATA_DIRS; do
    _td_d=${_td%:*}; _td_g=${_td##*:}; [ "$_td_g" = shared ] && _td_g=$_td_shared
    # only module-created folders (jobSize lives inside the module-created camera_rus)
    case "$_td_d" in
      */jobSize) [ -f "$1/.created/$(marker "${_td_d%/*}")" ] || continue ;;
      *) [ -f "$1/.created/$(marker "$_td_d")" ] || continue ;;
    esac
    [ -d "$_td_d" ] && [ ! -L "$_td_d" ] || continue
    [ "$(stat -c '%u:%g:%a' "$_td_d" 2>/dev/null)" = "$_td_uid:$_td_g:2770" ] && continue
    chown "$_td_uid:$_td_g" "$_td_d" && chmod 2770 "$_td_d"
  done
}

# Metamodules mount their own copy of each module's files, not the module folder itself. On some
# versions a module update only adds files to that copy, so files an older version of this module
# shipped (its old /vendor files) stayed mounted. Remove from our own copy anything the current
# module <dir> doesn't ship. Only ever touches <metamodule mnt>/oplus_camera_los.
prune_mirror() {  # <current module dir>
  [ -d "$1/system" ] || return 0
  for _pm_root in $METAMODULE_MNTS; do
    _pm_copy="$_pm_root/$MODID"
    [ -d "$_pm_copy" ] || continue
    [ "$(readlink -f "$_pm_copy")" = "$(readlink -f "$1")" ] && continue
    # the metamodule keeps partitions at the top level (<copy>/vendor, <copy>/odm, ...) as well as
    # <copy>/system; in the module they all live under system/
    for _pm_top in system vendor odm product system_ext oem vendor_dlkm odm_dlkm; do
      _pm_have="$_pm_copy/$_pm_top"
      [ -d "$_pm_have" ] && [ ! -L "$_pm_have" ] || continue
      if [ "$_pm_top" = system ]; then _pm_want="$1/system"; else _pm_want="$1/system/$_pm_top"; fi
      if [ ! -d "$_pm_want" ]; then rm -rf "$_pm_have"; continue; fi
      (cd "$_pm_have" && find . -mindepth 1 -depth 2>/dev/null) | while read -r _pm_p; do
        _pm_p=${_pm_p#./}
        [ -e "$_pm_want/$_pm_p" ] || [ -L "$_pm_want/$_pm_p" ] || rm -rf "$_pm_have/$_pm_p"
      done
    done
  done
}
