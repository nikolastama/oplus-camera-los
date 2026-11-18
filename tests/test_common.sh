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

# post-fs-data.sh: the fixed camera service copy is dropped after a ROM update, and only then
GUARD=$(sed -n '/^if \[ -f "\$MODDIR\/system\/bin\/cameraserver" \]/,/^fi$/p' "$REPO/module/post-fs-data.sh")
[ -n "$GUARD" ] || { echo "FAIL guard block not found in post-fs-data.sh"; exit 1; }
MODDIR="$T/inst"; mkdir -p "$MODDIR/system/bin" "$MODDIR/system/odm"
touch "$MODDIR/system/bin/cameraserver"
printf 'bin/cameraserver u:object_r:cameraserver_exec:s0\nodm/lib64/libAlgoProcess.so x\n' > "$MODDIR/.fixed"
rom_build() { echo "build-A"; }
echo "build-A" > "$MODDIR/.rom_build"
eval "$GUARD"
check "same build: copy kept"     '[ -f "$MODDIR/system/bin/cameraserver" ] && [ ! -e "$MODDIR/rom_updated" ]'
rom_build() { echo "build-B"; }
eval "$GUARD"
check "new build: copy dropped"   '[ ! -e "$MODDIR/system/bin" ] && [ -f "$MODDIR/rom_updated" ]'
check "new build: other fixes kept" '! grep -q "^bin/" "$MODDIR/.fixed" && grep -q "^odm/" "$MODDIR/.fixed"'
exit $fail
