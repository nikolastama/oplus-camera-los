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

# find_hex: byte offsets of either pattern, whole bytes only, ascending
printf 'xx\001\002\003yy\001\002\004zz\020\020' > "$T/bin"
check "find_hex: both patterns"   '[ "$(find_hex "$T/bin" 010203 010204 | tr "\n" " ")" = "2 7 " ]'
check "find_hex: one pattern"     '[ "$(find_hex "$T/bin" 010204 010204)" = 7 ]'
# bytes 10 10 read as hex text are "1010", which holds "0101" only across a byte boundary
check "find_hex: no half bytes"   '[ -z "$(find_hex "$T/bin" 0101 0101)" ] && [ "$(find_hex "$T/bin" 1010 1010)" = 12 ]'
check "find_hex: absent"          '[ -z "$(find_hex "$T/bin" aabb ccdd)" ]'

# refresh_fixes: after a LineageOS update, a fixed copy is made again from the changed ROM file
F="$T/fix"; R="$T/rom"; mkdir -p "$F/system/odm/lib64" "$R/vendor/lib64" "$R/odm/lib64"
ORIG=e86f40f9e97740f98b00; NEW=e86f40f9e93341b98b00
CODE='\350\157\100\371\351\167\100\371\213\000'   # $ORIG as bytes
rom() { head -c "$2" /dev/zero > "$R$1"; printf "$CODE" | dd of="$R$1" bs=1 seek="$3" conv=notrunc 2>/dev/null; }
h() { sha256sum "$R$1" | cut -d' ' -f1; }
ROM_ROOT=$R; L=u:object_r:vendor_file:s0
rom /vendor/lib64/offline.so 4096 100; rom /odm/lib64/algo.so 8192 300
echo plain-1 > "$R/vendor/lib64/plain.so"
patch_copy "$R/vendor/lib64/offline.so" "$F/system/odm/lib64/offline.so" 100 $ORIG $NEW >/dev/null
patch_copy "$R/odm/lib64/algo.so" "$F/system/odm/lib64/libAlgoProcess.so" 300 $ORIG $NEW >/dev/null
cp "$R/vendor/lib64/plain.so" "$F/system/odm/lib64/plain.so"
cat > "$F/.fixed" <<EOF
odm/lib64/offline.so $L /vendor/lib64/offline.so $(h /vendor/lib64/offline.so) 100 $ORIG $NEW
odm/lib64/plain.so $L /vendor/lib64/plain.so $(h /vendor/lib64/plain.so) - - -
odm/lib64/libAlgoProcess.so $L /odm/lib64/algo.so $(h /odm/lib64/algo.so) 300 $ORIG $NEW
odm/lib64/legacy.so $L
EOF
echo old > "$F/system/odm/lib64/legacy.so"
check "patch_copy: only the edit differs"   '[ "$(cmp -l "$R/odm/lib64/algo.so" "$F/system/odm/lib64/libAlgoProcess.so" | wc -l)" = 3 ]'
cp "$F/.fixed" "$T/fixed.orig"
check "nothing changed: nothing done"       '[ "$(refresh_fixes "$F")" = "0 0" ] && cmp -s "$F/.fixed" "$T/fixed.orig" && [ ! -e "$F/fixes.log" ]'
rom /odm/lib64/algo.so 9000 4321              # LineageOS update: new build of the file, edit moved
check "changed /odm file: remade"           '[ "$(refresh_fixes "$F")" = "1 0" ]'
check "remade from the new file"            '[ "$(hexat "$F/system/odm/lib64/libAlgoProcess.so" 4321 10)" = $NEW ] && [ "$(stat -c %s "$F/system/odm/lib64/libAlgoProcess.so")" = 9000 ]'
check "record updated (hash, offset)"       'grep -q "^odm/lib64/libAlgoProcess.so $L /odm/lib64/algo.so $(h /odm/lib64/algo.so) 4321 $ORIG $NEW$" "$F/.fixed"'
check "remake logged, nothing else changed" 'grep -q "libAlgoProcess.so: remade" "$F/fixes.log" && [ "$(wc -l < "$F/.fixed")" = 4 ]'
check "second boot: nothing to do"          '[ "$(refresh_fixes "$F")" = "0 0" ]'
echo plain-2 > "$R/vendor/lib64/plain.so"
check "changed plain copy: copied again"    '[ "$(refresh_fixes "$F")" = "1 0" ] && cmp -s "$R/vendor/lib64/plain.so" "$F/system/odm/lib64/plain.so"'
cp "$F/system/odm/lib64/libAlgoProcess.so" "$T/mine"; cp "$T/mine" "$R/odm/lib64/algo.so"
check "path shows our own copy: kept"       '[ "$(refresh_fixes "$F")" = "0 0" ] && cmp -s "$T/mine" "$F/system/odm/lib64/libAlgoProcess.so"'
rom /odm/lib64/algo.so 9000 4321
head -c 4096 /dev/zero > "$R/vendor/lib64/offline.so"   # update without the expected code
check "code gone: fix switched off"         '[ "$(refresh_fixes "$F")" = "0 1" ] && [ ! -e "$F/system/odm/lib64/offline.so" ]'
check "its line gone, rest kept"            '! grep -q offline "$F/.fixed" && [ "$(wc -l < "$F/.fixed")" = 3 ] && [ -f "$F/system/odm/lib64/plain.so" ]'
check "switch-off logged"                   'grep -q "offline.so: the updated /vendor/lib64/offline.so no longer has the expected code" "$F/fixes.log"'
check "old-format line kept as is"          'grep -qx "odm/lib64/legacy.so $L" "$F/.fixed"'
rm -f "$R/vendor/lib64/plain.so"
check "ROM file removed: copy removed"      '[ "$(refresh_fixes "$F")" = "0 1" ] && [ ! -e "$F/system/odm/lib64/plain.so" ]'
check "no .fixed: nothing to do"            '[ "$(refresh_fixes "$T/nothing")" = "0 0" ]'
unset ROM_ROOT

# sync_mirror: the metamodule's copy (what is actually mounted) gets the remade files
MM="$T/mmsync"; METAMODULE_MNTS="$MM"
check "no metamodule copy: status 1"        '! sync_mirror "$F" && ! prune_mirror "$F"'
mkdir -p "$MM/$MODID/odm/lib64"; echo stale > "$MM/$MODID/odm/lib64/libAlgoProcess.so"; echo x > "$MM/$MODID/odm/lib64/extra"
mkdir -p "$F/system/system_ext"
check "copy reachable: status 0"            'sync_mirror "$F"'
check "remade file synced"                  'cmp -s "$F/system/odm/lib64/libAlgoProcess.so" "$MM/$MODID/odm/lib64/libAlgoProcess.so"'
check "files it doesn't have are not added" '[ ! -e "$MM/$MODID/odm/lib64/offline.so" ]'
check "prune takes out removed copies"      'prune_mirror "$F" && [ ! -e "$MM/$MODID/odm/lib64/extra" ] && [ -f "$MM/$MODID/odm/lib64/libAlgoProcess.so" ]'

# hex -> bytes for the synthetic ROM files below (POSIX printf octal escapes)
hex2bin() { printf "$(echo "$1" | awk '{h="0123456789abcdef"; for (i = 1; i <= length($0); i += 2) printf "\\%03o", (index(h, substr($0, i, 1)) - 1) * 16 + index(h, substr($0, i + 1, 1)) - 1}')"; }
# a file of <n> filler bytes with the first variant of every edit in <orig list> spread through it
fake() {  # <file> <orig list>
  : > "$1"; head -c 1000 /dev/zero | tr '\0' '\125' >> "$1"
  for _e in $(echo "$2" | tr '+' ' '); do hex2bin "${_e%%|*}" >> "$1"; head -c 777 /dev/zero | tr '\0' '\125' >> "$1"; done
}

# patch_copy: several edits per file, build variants per edit
P="$T/pc"; mkdir -p "$P"
fake "$P/a" "aabbccdd0011+ffeeddcc9988"
check "multi-edit: each edit applied"       'o=$(patch_copy "$P/a" "$P/b" - "aabbccdd0011+ffeeddcc9988" "aabbccdd0022+ffeedd009988") && [ "$(cmp -l "$P/a" "$P/b" | wc -l)" = 2 ] && [ "$o" = "1000+1783" ]'
check "variant: the one present is used"    'patch_copy "$P/a" "$P/c" - "1234567890ab|aabbccdd0011" "1234567890ac|aabbccdd0033" >/dev/null && [ "$(hexat "$P/c" 1000 6)" = aabbccdd0033 ]'
check "already fixed copy: accepted as is"  'patch_copy "$P/b" "$P/d" - "aabbccdd0011+ffeeddcc9988" "aabbccdd0022+ffeedd009988" >/dev/null && cmp -s "$P/b" "$P/d"'
check "one edit missing: nothing written"   '! patch_copy "$P/a" "$P/e" - "aabbccdd0011+0102030405" "aabbccdd0022+0102030406" && [ ! -e "$P/e" ]'
check "edit found twice: refused"           'cat "$P/a" "$P/a" > "$P/aa" && ! patch_copy "$P/aa" "$P/e" - "aabbccdd0011" "aabbccdd0022"'
check "offset hint used"                    '[ "$(patch_copy "$P/a" "$P/f" 1000+1783 "aabbccdd0011+ffeeddcc9988" "aabbccdd0022+ffeedd009988")" = "1000+1783" ]'

# The installer's copies of LineageOS's layer (customize.sh fix 5, the same edits as add_fix), then
# adapt_to_rom after a LineageOS update brought a libEIS the module has no fixed copy of yet
A="$T/adapt"; AR="$A/rom"; AM="$A/mod"
mkdir -p "$AR/vendor/lib64" "$AR/odm/lib64/hw" "$AM/system/odm/lib64/hw"
fake "$AR/odm/lib64/hw/camera.oemlayer.v2.so" "$LAYER_FIX_ORIG"; fake "$AR/odm/lib64/camera.oemlayer.uilayer.so" "$UILAYER_FIX_ORIG"
echo wrap-OplusCamLosWrap > "$AM/system/odm/lib64/hw/camera.oemlayer.v2.so"
ROM_ROOT=$AR
check "layer copies made from the ROM"      'add_fix "$AM" /odm/lib64/hw/camera.oemlayer.v2.so odm/lib64/camera.oemlayer.v2.so "$LAYER_FIX_ORIG" "$LAYER_FIX_NEW" && add_fix "$AM" /odm/lib64/camera.oemlayer.uilayer.so odm/lib64/camera.oemlayer.uilaye2.so "$UILAYER_FIX_ORIG" "$UILAYER_FIX_NEW"'
check "layer copy has both edits"           '[ "$(cmp -l "$AR/odm/lib64/hw/camera.oemlayer.v2.so" "$AM/system/odm/lib64/camera.oemlayer.v2.so" | wc -l)" = 5 ]'
check "no libEIS on the ROM: nothing to do" '[ "$(adapt_to_rom "$AM")" = 0 ]'
fake "$AR/odm/lib64/libEIS.so" "$EIS_FIX_ORIG"
check "libEIS fix added"                    '[ "$(adapt_to_rom "$AM")" = 1 ] && [ "$(cmp -l "$AR/odm/lib64/libEIS.so" "$AM/system/odm/lib64/libEIS.so" | wc -l)" = 5 ]'
check "second boot: nothing more"           '[ "$(adapt_to_rom "$AM")" = 0 ] && [ "$(refresh_fixes "$AM")" = "0 0" ]'
check "logged"                              '[ "$(wc -l < "$AM/fixes.log")" = 1 ]'
# a later LineageOS update whose layer no longer fits: wrapper and copies go, the ROM's layer is used
fake "$AR/odm/lib64/hw/camera.oemlayer.v2.so" "0063616d6572612e6f656d6c617965722e75696c617965722e736f00"
check "layer no longer fits: all removed"   '[ "$(refresh_fixes "$AM")" = "0 1" ] && [ ! -e "$AM/system/odm/lib64/hw/camera.oemlayer.v2.so" ] && [ ! -e "$AM/system/odm/lib64/camera.oemlayer.uilaye2.so" ] && ! grep -q oemlayer "$AM/.fixed"'
check "libEIS copy kept"                    'grep -q "^odm/lib64/libEIS.so " "$AM/.fixed" && [ -f "$AM/system/odm/lib64/libEIS.so" ]'
check "own wrapper isn't taken for a layer" '! is_rom_layer "$AM/nothing" && echo x-OplusCamLosWrap > "$A/w" && ! is_rom_layer "$A/w" && is_rom_layer "$AR/odm/lib64/libEIS.so"'
unset ROM_ROOT
# sync_mirror puts files the metamodule copy doesn't have yet where it keeps that partition
AMM="$A/mm"; mkdir -p "$AMM/$MODID/odm/lib64"; METAMODULE_MNTS="$AMM"
check "new file added to the copy"          'sync_mirror "$AM" && cmp -s "$AM/system/odm/lib64/libEIS.so" "$AMM/$MODID/odm/lib64/libEIS.so"'

# mount_blobs: the image is mounted once on <module>/blobs, then each of its folders once over the
# ROM's folder. A fake mount records the calls; "mounting" the image creates its folders.
BM="$T/bm"; BR="$T/brom"; mkdir -p "$BM" "$BR/odm/lib64" "$BR/odm/etc/camera"
PROC_MOUNTS="$T/mounts"; : > "$PROC_MOUNTS"; ROM_ROOT=$BR
mount() {
  echo "$*" >> "$T/mount.calls"
  case "$2" in erofs) [ -n "${IMG_FAIL:-}" ] ;; *) [ -n "${MOUNT_FAIL:-}" ] ;; esac && { echo "Invalid argument" >&2; return 1; }
  [ "$2" = erofs ] && mkdir -p "$6/odm/lib64" "$6/odm/etc/camera"
  echo "$5 $6 $2 ro 0 0" >> "$PROC_MOUNTS"
}
check "no image: nothing mounted"           'mount_blobs "$BM" && [ ! -e "$T/mount.calls" ]'
: > "$BM/blobs.img"
check "image and both folders mounted"      'mount_blobs "$BM" && [ "$(wc -l < "$T/mount.calls")" = 3 ] && grep -q "^-t erofs -o loop,ro $BM/blobs.img $BM/blobs$" "$T/mount.calls" && grep -q "^-t overlay -o lowerdir=$BM/blobs/odm/lib64:$BR/odm/lib64 oplus_camera_blobs $BR/odm/lib64$" "$T/mount.calls"'
check "mounted ones are not mounted again"  'mount_blobs "$BM" && [ "$(wc -l < "$T/mount.calls")" = 3 ] && [ "$(grep -c mounted "$BM/mount.log")" = 2 ]'
: > "$PROC_MOUNTS"; rm -rf "$T/mount.calls" "$BM/blobs"
check "image failure: no overlay, logged"   '! IMG_FAIL=1 mount_blobs "$BM" && [ "$(wc -l < "$T/mount.calls")" = 1 ] && grep -q "blobs.img: mount failed: Invalid argument" "$BM/mount.log"'
: > "$PROC_MOUNTS"; rm -rf "$T/mount.calls" "$BM/blobs"
check "overlay failure reported and logged" '! MOUNT_FAIL=1 mount_blobs "$BM" && grep -q "/odm/lib64: mount failed: Invalid argument" "$BM/mount.log"'
unset ROM_ROOT PROC_MOUNTS; unset -f mount
exit $fail
