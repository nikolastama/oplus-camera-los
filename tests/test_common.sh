#!/bin/sh
# prune_mirror (module/common.sh) on a simulated metamodule copy. POSIX sh, like KernelSU's.
#   sh tests/test_common.sh
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
. "$REPO/module/common.sh"
METAMODULE_MNTS="$T/mm1 $T/mm2 $T/absent"

# the current module ships system/system_ext/a and system/odm/lib64/x
mkdir -p "$T/mod/system/system_ext" "$T/mod/system/odm/lib64"
touch "$T/mod/system/system_ext/a" "$T/mod/system/odm/lib64/x"
# metamodule copy: a stale /vendor partition, a stale file and a stale folder next to current files
C="$T/mm1/$MODID"
mkdir -p "$C/system/system_ext/old" "$C/vendor/lib64" "$C/odm/lib64"
touch "$C/system/system_ext/a" "$C/system/system_ext/old/f" "$C/vendor/lib64/v" "$C/odm/lib64/x" "$C/odm/lib64/stale"
ln -s ../odm "$C/system/odm"
# a copy that is the module itself (symlink) must be left alone
mkdir -p "$T/mm2"; ln -s "$T/mod" "$T/mm2/$MODID"; touch "$T/mod/system/keep"

prune_mirror "$T/mod"

fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "stale partition removed"   '[ ! -e "$C/vendor" ]'
check "stale file removed"        '[ ! -e "$C/odm/lib64/stale" ]'
check "stale folder removed"      '[ ! -e "$C/system/system_ext/old" ]'
check "current files kept"        '[ -f "$C/odm/lib64/x" ] && [ -f "$C/system/system_ext/a" ]'
check "symlinks kept"             '[ -L "$C/system/odm" ]'
check "module itself untouched"   '[ -f "$T/mod/system/keep" ] && [ -f "$T/mod/system/odm/lib64/x" ]'
check "marker names"              '[ "$(marker /data/vendor/cam_alog)" = _data_vendor_cam_alog ]'

# update from v0.35/v0.36: their camera service copy left in the metamodule's copy is removed
C2="$T/mm1/$MODID"; mkdir -p "$C2/system/bin"; touch "$C2/system/bin/cameraserver"
prune_mirror "$T/mod"
check "old camera service copy removed" '[ ! -e "$C2/system/bin" ]'

# tighten_dirs: module-created data folders are given to the camera app (needs root for chown)
if [ "$(id -u)" = 0 ]; then
  M="$T/tmod"; mkdir -p "$M/.created"
  DATA_DIRS="$T/data/system/camera_rus:shared $T/data/system/camera_rus/jobSize:shared
$T/data/vendor/camera_rus:1006 $T/data/vendor/cam_alog:1006"
  mkdir -p "$T/data/system/camera_rus/jobSize" "$T/data/vendor/camera_rus" "$T/data/vendor/cam_alog"
  chmod 0777 "$T/data/system/camera_rus" "$T/data/system/camera_rus/jobSize" "$T/data/vendor/camera_rus" "$T/data/vendor/cam_alog"
  touch "$M/.created/$(marker "$T/data/system/camera_rus")" "$M/.created/$(marker "$T/data/vendor/camera_rus")"
  PACKAGES_LIST="$T/packages.list"
  printf 'com.other.app 10100 0 /data/user/0/x default:targetSdkVersion=36 3003\n' > "$PACKAGES_LIST"
  tighten_dirs "$M"
  check "app not installed yet: folders unchanged" '[ "$(stat -c %a "$T/data/system/camera_rus")" = 777 ]'
  printf 'com.oplus.camera 10248 0 /data/user/0/com.oplus.camera platform:privapp:targetSdkVersion=36 3003\n' >> "$PACKAGES_LIST"
  tighten_dirs "$M"
  check "camera_rus: app owner, shared group, 2770" '[ "$(stat -c %u:%g:%a "$T/data/system/camera_rus")" = 10248:50248:2770 ]'
  check "jobSize follows camera_rus"               '[ "$(stat -c %u:%g:%a "$T/data/system/camera_rus/jobSize")" = 10248:50248:2770 ]'
  check "vendor folder: camera group"              '[ "$(stat -c %u:%g:%a "$T/data/vendor/camera_rus")" = 10248:1006:2770 ]'
  check "LineageOS folder untouched"               '[ "$(stat -c %a "$T/data/vendor/cam_alog")" = 777 ]'
  printf 'com.oplus.camera 99999x 0\n' > "$PACKAGES_LIST"; chmod 00777 "$T/data/vendor/camera_rus"
  tighten_dirs "$M"
  check "bad app id ignored"                       '[ "$(stat -c %a "$T/data/vendor/camera_rus")" = 777 ]'
else
  echo "skip tighten_dirs (needs root)"
fi
exit $fail
