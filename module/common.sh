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
prune_mirror() {  # <current module dir>; status 1 if no metamodule copy was reachable
  [ -d "$1/system" ] || return 0
  _pm_found=1
  for _pm_root in $METAMODULE_MNTS; do
    _pm_copy="$_pm_root/$MODID"
    [ -d "$_pm_copy" ] || continue
    [ "$(readlink -f "$_pm_copy")" = "$(readlink -f "$1")" ] && continue
    _pm_found=0
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
  return $_pm_found
}

# Byte offsets (decimal, one per line, ascending) where hex string <a> or <b> occurs in <file>.
# Used by customize.sh's fixlib when an edit isn't at its expected offset. The file is turned into
# one hex string and searched with index(), so the cost is one pass over the file, not one pass
# per byte as with a sliding window (minutes on a 30 MB library in awk).
find_hex() {  # <file> <hex a> <hex b>
  od -An -v -tx1 "$1" 2>/dev/null | tr -d ' \n' | awk -v a="$2" -v b="$3" '{
    for (k = 1; k <= 2; k++) {
      p = (k == 1) ? a : b
      if (p == "" || (k == 2 && b == a)) continue
      t = $0; base = 0
      while ((i = index(t, p)) > 0) {
        pos = base + i - 1
        if (pos % 2 == 0) print pos / 2   # only whole bytes, not a match across a byte boundary
        base += i; t = substr(t, i + 1)
      }
    }
  }' | sort -n | uniq
}

# The ODM build the module's copies were made from (customize.sh saves it in <module>/.rom_fp; used
# only when the installer can't read the ROM's own /odm file). Never overlaid by the module.
odm_fp() { grep -m1 '^ro.odm.build.fingerprint=' "${ODM_BUILD_PROP:-/odm/etc/build.prop}" 2>/dev/null | cut -d= -f2-; }

hexat() { od -An -v -tx1 -j "$2" -N "$3" "$1" 2>/dev/null | tr -d ' \n'; }

# Copy <src> to <dst> with byte edits applied. <orig> and <new> list the edits, joined by "+"; an
# edit may have variants for different builds of the file, joined by "|" (the same number in both
# lists). Each edit is taken at its offset from <offsets> ("+"-joined, "-" for none) if its bytes are
# there, otherwise at the one place in the file where exactly one of its variants occurs (a newer
# build). Bytes that already carry the fixed value are left as they are, so a fixed copy can be
# copied again. Applied only if every edit is found exactly once, and checked byte for byte
# afterwards (same size, only the intended bytes differ). Prints the offsets used ("+"-joined); on
# any failure <dst> is removed and the status is 1.
_pc_field() { echo "$1" | awk -F"$3" -v k="$2" '{ print (k <= NF) ? $k : "" }'; }
_pc_count() { echo "$1" | awk -F"$2" '{ print NF }'; }
patch_copy() {  # <src> <dst> <offsets> <orig> <new>
  _pc_src=$1; _pc_dst=$2; _pc_plan=; _pc_used=
  rm -f "$_pc_dst"
  [ -f "$_pc_src" ] || return 1
  _pc_ne=$(_pc_count "$4" +)
  [ "$_pc_ne" = "$(_pc_count "$5" +)" ] || return 1
  _pc_k=1
  while [ $_pc_k -le $_pc_ne ]; do
    _pc_os=$(_pc_field "$4" $_pc_k +); _pc_ns=$(_pc_field "$5" $_pc_k +); _pc_hint=$(_pc_field "$3" $_pc_k +)
    _pc_na=$(_pc_count "$_pc_os" '|')
    [ "$_pc_na" = "$(_pc_count "$_pc_ns" '|')" ] || return 1
    _pc_found=; _pc_j=1
    while [ $_pc_j -le $_pc_na ]; do
      _pc_o=$(_pc_field "$_pc_os" $_pc_j '|'); _pc_n=$(_pc_field "$_pc_ns" $_pc_j '|')
      [ ${#_pc_o} = ${#_pc_n} ] && [ -n "$_pc_o" ] || return 1
      _pc_cur=
      case "$_pc_hint" in ''|-|*[!0-9]*) ;; *) _pc_cur=$(hexat "$_pc_src" "$_pc_hint" $((${#_pc_o} / 2))) ;; esac
      if [ -n "$_pc_cur" ] && { [ "$_pc_cur" = "$_pc_o" ] || [ "$_pc_cur" = "$_pc_n" ]; }; then
        _pc_found="$_pc_found$_pc_hint $_pc_o $_pc_n
"
      else
        for _pc_p in $(find_hex "$_pc_src" "$_pc_o" "$_pc_n"); do
          _pc_found="$_pc_found$_pc_p $_pc_o $_pc_n
"
        done
      fi
      _pc_j=$((_pc_j + 1))
    done
    [ "$(printf '%s' "$_pc_found" | grep -c .)" = 1 ] || return 1
    _pc_plan="$_pc_plan$_pc_found"
    _pc_used="$_pc_used${_pc_used:++}${_pc_found%% *}"
    _pc_k=$((_pc_k + 1))
  done
  mkdir -p "${_pc_dst%/*}"; cp -p "$_pc_src" "$_pc_dst" || { rm -f "$_pc_dst"; return 1; }
  _pc_want=0
  printf '%s' "$_pc_plan" | {
    while read -r _pc_off _pc_o _pc_n; do
      _pc_cur=$(hexat "$_pc_src" "$_pc_off" $((${#_pc_o} / 2)))
      [ "$_pc_cur" = "$_pc_n" ] && continue
      _pc_i=0
      while [ $_pc_i -lt $((${#_pc_o} / 2)) ]; do
        _pc_ob=$(echo "$_pc_o" | cut -c$((_pc_i * 2 + 1))-$((_pc_i * 2 + 2)))
        _pc_nb=$(echo "$_pc_n" | cut -c$((_pc_i * 2 + 1))-$((_pc_i * 2 + 2)))
        if [ "$_pc_ob" != "$_pc_nb" ]; then
          _pc_want=$((_pc_want + 1))
          if [ "$_pc_nb" = 00 ]; then head -c 1 /dev/zero; else printf "\\$(printf %o 0x$_pc_nb)"; fi \
            | dd of="$_pc_dst" bs=1 seek=$((_pc_off + _pc_i)) conv=notrunc 2>/dev/null
        fi
        _pc_i=$((_pc_i + 1))
      done
    done
    echo $_pc_want > "$_pc_dst.want"
  }
  _pc_want=$(cat "$_pc_dst.want" 2>/dev/null); rm -f "$_pc_dst.want"
  _pc_ok=1
  [ -n "$_pc_want" ] && [ "$(stat -c %s "$_pc_dst")" = "$(stat -c %s "$_pc_src")" ] \
    && [ "$(cmp -l "$_pc_src" "$_pc_dst" 2>/dev/null | wc -l)" = "$_pc_want" ] || _pc_ok=0
  if [ $_pc_ok = 1 ]; then
    while read -r _pc_off _pc_o _pc_n; do
      [ -n "$_pc_off" ] || continue
      [ "$(hexat "$_pc_dst" "$_pc_off" $((${#_pc_n} / 2)))" = "$_pc_n" ] || _pc_ok=0
    done <<EOF
$_pc_plan
EOF
  fi
  if [ $_pc_ok = 1 ]; then echo "$_pc_used"; return 0; fi
  rm -f "$_pc_dst"; return 1
}

# ---- Edits of LineageOS's own camera files (used by customize.sh at install and adapt_to_rom /
# refresh_fixes at boot; patch_copy syntax: edits joined by "+", build variants by "|")
# OnePlus camera layer. LineageOS ships it since its ColorOS-blob builds, at the path the wrapper
# takes (/odm/lib64/hw/camera.oemlayer.v2.so). Its private copy (/odm/lib64/camera.oemlayer.v2.so,
# loaded by the wrapper):
#   1. loads the private UI library camera.oemlayer.uilaye2.so instead of the ROM's (DT_NEEDED)
#   2. ZoomDivisionV2::Initialize: the SAT config flag that makes the layer ignore
#      ANDROID_CONTROL_ZOOM_RATIO is forced to 0 (ldr w8,[x9,#0x124] -> mov w8,wzr); without it the
#      viewfinder never zooms
LAYER_FIX_ORIG="0063616d6572612e6f656d6c617965722e75696c617965722e736f00+681600b9e103142a282541b9690e40f968fe1e29691200f9"
LAYER_FIX_NEW="0063616d6572612e6f656d6c617965722e75696c617965322e736f00+681600b9e103142ae8031f2a690e40f968fe1e29691200f9"
# Its UI library's private copy (/odm/lib64/camera.oemlayer.uilaye2.so): 1. its own name (SONAME);
# 2. dlopen("/odm/lib64/hw/camera.oemlayer.v2.so") -> dlopen("camera.oemlayer.v2.so"), because the
#    hw/ path is the wrapper; by name it finds the layer copy already loaded
UILAYER_FIX_ORIG="0063616d6572612e6f656d6c617965722e75696c617965722e736f00+2f6f646d2f6c696236342f68772f63616d6572612e6f656d6c617965722e76322e736f00"
UILAYER_FIX_NEW="0063616d6572612e6f656d6c617965722e75696c617965322e736f00+63616d6572612e6f656d6c617965722e76322e736f000000000000000000000000000000"
# libEIS (ColorOS build): its five native-handle format reads for ShareBuffer use a legacy
# private_handle_t offset (+0x2c), which in LineageOS's SnapAlloc handle is the unaligned width; the
# format is at +0x34. Passing the width as a pixel format makes EGL buffer imports fail (empty,
# green time-lapse recordings). Found and verified by Infinity X (camera_eis_compat.py) on code
# identical to LineageOS's libEIS.
EIS_FIX_ORIG="400300b461884029042c40b9052080524500a072+081d40f955010014842e40b9e18b4429e32f40b9+62000014ff6f00b9042f40b9052080524500a072+ff0300f9281040f9042c40b90189402986c2ff97+ff0300f9281040f9042c40b90189402939c2ff97"
EIS_FIX_NEW="400300b461884029043440b9052080524500a072+081d40f955010014843640b9e18b4429e32f40b9+62000014ff6f00b9043740b9052080524500a072+ff0300f9281040f9043440b90189402986c2ff97+ff0300f9281040f9043440b90189402939c2ff97"
LAYER_FILES="odm/lib64/hw/camera.oemlayer.v2.so odm/lib64/camera.oemlayer.v2.so odm/lib64/camera.oemlayer.uilaye2.so"

# The ROM's own OnePlus camera layer at <path> (not this module's wrapper from an older install)
is_rom_layer() { [ -f "$1" ] && ! grep -q OplusCamLosWrap "$1" 2>/dev/null; }

# Remove <files> (module paths) from the module and their lines from .fixed
drop_files() {  # <module dir> <files...>
  _df_m=$1; shift
  for _df_f in "$@"; do
    rm -f "$_df_m/system/$_df_f"
    [ -f "$_df_m/.fixed" ] && { grep -v "^$_df_f " "$_df_m/.fixed" > "$_df_m/.fixed.d" || true; mv -f "$_df_m/.fixed.d" "$_df_m/.fixed"; }
  done
  rmdir "$_df_m/system/odm/lib64/hw" 2>/dev/null || true
  return 0
}

# Add a fixed copy of the ROM file <rom> as <dst> and record it in .fixed. Status 1 if it doesn't fit.
add_fix() {  # <module dir> <rom path> <dst> <orig> <new>
  _af_f="${ROM_ROOT:-}$2"
  _af_o=$(patch_copy "$_af_f" "$1/system/$3" - "$4" "$5") || return 1
  _af_ctx=$(ls -Z "$_af_f" 2>/dev/null | awk '{print $1}')
  case "$_af_ctx" in u:object_r:*) chcon "$_af_ctx" "$1/system/$3" 2>/dev/null ;; *) _af_ctx=u:object_r:vendor_file:s0 ;; esac
  echo "$3 $_af_ctx $2 $(sha256sum "$_af_f" | cut -d' ' -f1) $_af_o $4 $5" >> "$1/.fixed"
}

# Follow LineageOS's changes to its camera blobs without a reinstall. Run from post-fs-data.sh
# before anything is mounted (ROM files are the ROM's own). Logged in fixes.log; prints the number
# of changes.
#  - LineageOS's libEIS has the SnapAlloc format bug above and no fixed copy exists yet: add it.
adapt_to_rom() {  # <module dir>
  _ar_m=$1; _ar_n=0; _ar_r=${ROM_ROOT:-}
  if [ -f "$_ar_r/odm/lib64/libEIS.so" ] && [ ! -f "$_ar_m/system/odm/lib64/libEIS.so" ] \
     && add_fix "$_ar_m" /odm/lib64/libEIS.so odm/lib64/libEIS.so "$EIS_FIX_ORIG" "$EIS_FIX_NEW"; then
    echo "$(date) libEIS: SnapAlloc format fix added" >> "$_ar_m/fixes.log"
    _ar_n=$((_ar_n + 1))
  fi
  echo $_ar_n
}

# Fixed copies of ROM files (customize.sh) are made from the ROM installed at the time. Each line of
# <module>/.fixed is
#   <module path> <SELinux label> <ROM path> <sha256 of that ROM file> <offset> <orig hex> <new hex>
# (offset/orig/new are "-" for a plain copy). Run from post-fs-data.sh, before any module file is
# mounted, so /vendor and /odm show the ROM's own files. When a LineageOS update changed one, the
# copy is made again from the new file, the same way the installer makes it, so no reinstall is
# needed. If the new file no longer has the expected bytes, the copy is removed (with the files that
# only work together with it) and the ROM's file is used. Both are logged in <module>/fixes.log.
# Prints "<remade> <removed>". (ROM_ROOT prefixes the ROM paths; empty on the phone, a fake ROM in
# tests/test_common.sh.)
refresh_fixes() {  # <module dir>
  _rf_m=$1; _rf_made=0; _rf_gone=0
  [ -f "$_rf_m/.fixed" ] || { echo "0 0"; return 0; }
  : > "$_rf_m/.fixed.tmp"
  while read -r _rf_dst _rf_ctx _rf_rom _rf_sha _rf_off _rf_orig _rf_new; do
    [ -n "$_rf_dst" ] || continue
    _rf_line="$_rf_dst $_rf_ctx${_rf_rom:+ $_rf_rom $_rf_sha $_rf_off $_rf_orig $_rf_new}"
    _rf_f="${ROM_ROOT:-}$_rf_rom"; _rf_copy="$_rf_m/system/$_rf_dst"
    # lines from older versions have no ROM path, and a copy whose module file is already gone
    # (watchdog) has nothing to refresh
    if [ -z "$_rf_new" ] || [ ! -f "$_rf_copy" ]; then
      echo "$_rf_line" >> "$_rf_m/.fixed.tmp"; continue
    fi
    _rf_now=$(sha256sum "$_rf_f" 2>/dev/null | cut -d' ' -f1)
    # unchanged, or the path shows our own copy (something is already mounted): nothing to do
    if [ "$_rf_now" = "$_rf_sha" ] || cmp -s "$_rf_f" "$_rf_copy"; then
      echo "$_rf_line" >> "$_rf_m/.fixed.tmp"; continue
    fi
    if [ "$_rf_orig" = - ]; then
      cp -p "$_rf_f" "$_rf_copy.new" 2>/dev/null && cmp -s "$_rf_f" "$_rf_copy.new" && _rf_o=- || _rf_o=
    else
      _rf_o=$(patch_copy "$_rf_f" "$_rf_copy.new" "$_rf_off" "$_rf_orig" "$_rf_new") || _rf_o=
    fi
    if [ -n "$_rf_o" ]; then
      chcon "$_rf_ctx" "$_rf_copy.new" 2>/dev/null
      mv -f "$_rf_copy.new" "$_rf_copy"
      echo "$_rf_dst $_rf_ctx $_rf_rom $_rf_now $_rf_o $_rf_orig $_rf_new" >> "$_rf_m/.fixed.tmp"
      echo "$(date) $_rf_dst: remade from the updated $_rf_rom" >> "$_rf_m/fixes.log"
      _rf_made=$((_rf_made + 1))
    else
      rm -f "$_rf_copy.new" "$_rf_copy"
      case "$_rf_dst" in   # files that only work together
        # the wrapper needs the layer copy (DT_NEEDED): without it the camera HAL couldn't load
        # at all; the ROM's own layer is then used as is
        odm/lib64/camera.oemlayer.v2.so|odm/lib64/camera.oemlayer.uilaye2.so)
          for _rf_g in $LAYER_FILES; do rm -f "$_rf_m/system/$_rf_g"; done ;;
      esac
      echo "$(date) $_rf_dst: the updated $_rf_rom no longer has the expected code; fix off, the ROM's file is used" >> "$_rf_m/fixes.log"
      _rf_gone=$((_rf_gone + 1))
    fi
  done < "$_rf_m/.fixed"
  # a removed copy takes its partners' lines with it
  if [ ! -f "$_rf_m/system/odm/lib64/hw/camera.oemlayer.v2.so" ]; then
    grep -vE '^odm/lib64/camera\.oemlayer\.(v2|uilaye2)\.so ' "$_rf_m/.fixed.tmp" > "$_rf_m/.fixed.tmp2" || true
    mv -f "$_rf_m/.fixed.tmp2" "$_rf_m/.fixed.tmp"
    rmdir "$_rf_m/system/odm/lib64/hw" 2>/dev/null || true
  fi
  if [ $_rf_made -gt 0 ] || [ $_rf_gone -gt 0 ]; then
    mv -f "$_rf_m/.fixed.tmp" "$_rf_m/.fixed"
  else
    rm -f "$_rf_m/.fixed.tmp"
  fi
  echo "$_rf_made $_rf_gone"
}

# meta-overlayfs keeps its copies of all modules in an ext4 image that its metamount.sh mounts only
# after the modules' post-fs-data scripts. When this module's copy must change before it is mounted
# (post-fs-data.sh), mount the image the same way metamount.sh does; metamount.sh then sees it
# mounted and uses it as is. Status 1 if there is no such image or it can't be mounted.
METAMODULE_IMG=/data/adb/metamodule/modules.img
mount_metamodule_image() {
  _mi_mnt=${METAMODULE_IMG%/*}/mnt
  [ -f "$METAMODULE_IMG" ] || return 1
  mountpoint -q "$_mi_mnt" 2>/dev/null && return 0
  mkdir -p "$_mi_mnt"
  chcon u:object_r:ksu_file:s0 "$METAMODULE_IMG" 2>/dev/null
  mount -t ext4 -o loop,rw,noatime "$METAMODULE_IMG" "$_mi_mnt" 2>/dev/null
}

# meta-overlayfs mounts its own copy of the module's files (made at install), not the module folder.
# Bring the fixed copies in that copy up to date with the module folder (refresh_fixes,
# adapt_to_rom), adding ones it doesn't have yet; removed ones are taken out by prune_mirror. Status
# 1 if no metamodule copy of this module is reachable (meta-overlayfs mounts its image only after
# post-fs-data.sh: service.sh tries again).
sync_mirror() {  # <module dir>
  _sm_found=1
  for _sm_root in $METAMODULE_MNTS; do
    _sm_copy="$_sm_root/$MODID"
    [ -d "$_sm_copy" ] || continue
    [ "$(readlink -f "$_sm_copy")" = "$(readlink -f "$1")" ] && continue
    _sm_found=0
    while read -r _sm_dst _sm_ctx _sm_rest; do
      [ -f "$1/system/$_sm_dst" ] || continue
      _sm_have=
      for _sm_t in "$_sm_copy/$_sm_dst" "$_sm_copy/system/$_sm_dst"; do
        [ -f "$_sm_t" ] && _sm_have="$_sm_have $_sm_t"
      done
      if [ -z "$_sm_have" ]; then   # new file (adapt_to_rom): where the copy keeps that partition
        if [ -d "$_sm_copy/${_sm_dst%%/*}" ] && [ ! -L "$_sm_copy/${_sm_dst%%/*}" ]; then _sm_have="$_sm_copy/$_sm_dst"
        else _sm_have="$_sm_copy/system/$_sm_dst"; fi
        mkdir -p "${_sm_have%/*}"
      fi
      for _sm_t in $_sm_have; do
        cmp -s "$1/system/$_sm_dst" "$_sm_t" && continue
        cp -p "$1/system/$_sm_dst" "$_sm_t.new" && chcon "$_sm_ctx" "$_sm_t.new" 2>/dev/null
        mv -f "$_sm_t.new" "$_sm_t"
      done
    done < "$1/.fixed"
  done
  return $_sm_found
}

# The camera app's own libraries and models (about 2.3 GB) don't fit in the metamodule's image, so
# they stay in the module folder, in their own read-only erofs image (<module>/blobs.img, built with
# the ColorOS odm image's labels; overlayfs refuses layers on /data itself, whose f2fs supports
# case-insensitive names). post-mount.sh, which KernelSU runs once the metamodule has mounted every
# module, mounts the image on <module>/blobs and lays each of its folders over the ROM's (and module
# files already mounted there) as a read-only overlay. Nothing is written anywhere: the mounts are
# gone at the next boot, and removing the module removes the image. Status 1 if something could not
# be mounted; each mount is logged in <module>/mount.log. (ROM_ROOT prefixes the mount points and
# PROC_MOUNTS replaces /proc/mounts in tests.)
BLOB_IMAGE=blobs.img
BLOB_MOUNTS="odm/lib64 odm/etc/camera"
BLOB_SOURCE=oplus_camera_blobs
blobs_mounted() {  # <folder>: is our overlay on /<folder>?
  awk -v s="$BLOB_SOURCE" -v d="${ROM_ROOT:-}/$1" '$1 == s && $2 == d { f = 1 } END { exit !f }' "${PROC_MOUNTS:-/proc/mounts}"
}
mount_blobs() {  # <module dir>
  [ -f "$1/$BLOB_IMAGE" ] || return 0
  _mb_img="$1/blobs"
  if ! awk -v d="$_mb_img" '$2 == d { f = 1 } END { exit !f }' "${PROC_MOUNTS:-/proc/mounts}"; then
    mkdir -p "$_mb_img"
    if ! _mb_err=$(mount -t erofs -o loop,ro "$1/$BLOB_IMAGE" "$_mb_img" 2>&1); then
      echo "$(date) $BLOB_IMAGE: mount failed: $_mb_err" >> "$1/mount.log"
      return 1
    fi
  fi
  _mb_rc=0
  for _mb_d in $BLOB_MOUNTS; do
    _mb_t="${ROM_ROOT:-}/$_mb_d"
    [ -d "$_mb_img/$_mb_d" ] && [ -d "$_mb_t" ] || continue
    blobs_mounted "$_mb_d" && continue
    if _mb_err=$(mount -t overlay -o "lowerdir=$_mb_img/$_mb_d:$_mb_t" "$BLOB_SOURCE" "$_mb_t" 2>&1); then
      echo "$(date) /$_mb_d: camera app files mounted" >> "$1/mount.log"
    else
      echo "$(date) /$_mb_d: mount failed: $_mb_err" >> "$1/mount.log"
      _mb_rc=1
    fi
  done
  return $_mb_rc
}
