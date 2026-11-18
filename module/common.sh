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
