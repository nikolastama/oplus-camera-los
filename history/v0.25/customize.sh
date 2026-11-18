# OnePlus Camera for LineageOS - install-time checks and pre-install snapshots
SKIPUNZIP=0
PKG=com.oplus.camera

ui_print "- OnePlus Camera for LineageOS (OnePlus 15)"
# Read identity from the ROM's build.prop files, not runtime props: Play Integrity / prop-spoofing
# modules commonly hide ro.lineage.* and replace device names at runtime.
fileprop() {
  for f in /system/build.prop /system_ext/etc/build.prop /product/etc/build.prop /vendor/build.prop /odm/etc/build.prop; do
    [ -f "$f" ] && v=$(grep -m1 "^$1=" "$f" | cut -d= -f2-) && [ -n "$v" ] && { echo "$v"; return; }
  done
}
DEVICE=$(fileprop ro.lineage.device)
LOSVER=$(fileprop ro.lineage.build.version)
PRODDEV=$(cat /system/build.prop /system_ext/etc/build.prop /product/etc/build.prop /vendor/build.prop /odm/etc/build.prop 2>/dev/null \
  | grep -m1 -oE '^ro\.product\.([a-z_]+\.)?device=OP611FL1' | cut -d= -f2)
ui_print "  device: ${DEVICE:-?} ($PRODDEV)  LineageOS: ${LOSVER:-none}  SDK: $API"

[ "$DEVICE" = infiniti ] || [ "$PRODDEV" = OP611FL1 ] || abort "! This module is only for the OnePlus 15 (infiniti)."
case "$LOSVER" in 24.*) ;; *) abort "! This module is built for LineageOS 24 only (found '${LOSVER:-none}')." ;; esac
[ "$ARCH" = arm64 ] || abort "! arm64 only"
[ -e /odm/lib64/libAlgoProcess.so ] && [ -e /vendor/lib64/hw/camera.qcom.core.so ] \
  || abort "! OnePlus camera HAL libraries not found on this ROM"

# OnePlus camera layer (camera.oemlayer.v2): LineageOS already points the camera HAL at it
# (ro.hardware.camera=oemlayer.v2) but doesn't ship it. If the HAL finds it but cannot load it,
# every camera app breaks, so only ship it when all of its libraries exist on this ROM.
# All of the module's HAL-side files live on /odm (searched before /vendor by both libhardware
# and the vendor linker), so nothing under /vendor is ever overlaid.
OEMLAYER="$MODPATH/system/odm/lib64/hw/camera.oemlayer.v2.so"
drop_layer() {
  rm -f "$OEMLAYER" "$MODPATH/system/odm/lib64/camera.oemlayer.v2.so" "$MODPATH/system/odm/lib64/libsensorbridg2.so" \
        "$MODPATH/system/odm/lib64/camera.oemlayer.uilaye2.so"
  rmdir "$MODPATH/system/odm/lib64/hw" 2>/dev/null
}
OLD=/data/adb/modules/oplus_camera_los/system
rom_has() { [ -e "$1" ] && [ ! -e "$OLD$1" ] && [ ! -e "$OLD/vendor${1#/vendor}" ]; }
if [ -f "$OEMLAYER" ] && { rom_has /vendor/lib64/hw/camera.oemlayer.v2.so || rom_has /vendor/lib64/camera.oemlayer.v2.so; }; then
  drop_layer
  ui_print "- This ROM ships the OnePlus camera layer itself; using the ROM's copy"
fi
if [ -f "$OEMLAYER" ]; then
  MISSING=""
  for l in android.frameworks.sensorservice-V1-ndk.so android.frameworks.sensorservice@1.0.so android.hardware.graphics.common@1.0.so android.hardware.graphics.common@1.1.so android.hardware.graphics.common@1.2.so android.hardware.sensors-V3-ndk.so camera.oemlayer.healthmonitor.so camera.oemlayer.logger.so camera.oemlayer.uilayer.so camera.oemlayer.adapter.so libhwconfigurationutil.so libmidasserviceintf_aidl.so libocompression.so libopluscameraframeboost.so liboplusdfx.so libosenseaidlhalclient.so libosensenativeproxy_client.so liboutils.so vendor.oplus.hardware.camera.aon-service-impl.so vendor.oplus.hardware.camera_rfi-V1-service-impl.so vendor.oplus.hardware.cammidasservice-V1-ndk.so vendor.oplus.hardware.charger-V9-ndk.so vendor.oplus.hardware.commondcs-V1-ndk.so vendor.oplus.hardware.osense.client-V1-ndk.so vendor.oplus.hardware.sendextcamcmd-V1-service-impl.so; do
    found=0
    for d in /vendor/lib64 /odm/lib64 /vendor/lib64/hw /odm/lib64/hw /system/lib64 /apex/*/lib64; do
      [ -e "$d/$l" ] && { found=1; break; }
    done
    [ $found = 1 ] || MISSING="$MISSING $l"
  done
  if [ "$(getprop ro.hardware.camera)" != oemlayer.v2 ] && ! grep -qs '^ro.hardware.camera=oemlayer.v2' /vendor/build.prop /odm/etc/build.prop /vendor/etc/build.prop; then
    MISSING="$MISSING (ro.hardware.camera is not oemlayer.v2)"
  fi
  if [ -n "$MISSING" ]; then
    drop_layer
    ui_print "! OnePlus camera layer NOT installed, missing:$MISSING"
    ui_print "! The camera app will not identify its lenses without it."
  else
    ui_print "- OnePlus camera layer: all dependencies present"
  fi
fi

# ---- Fixes for two OnePlus libraries that assume OxygenOS's graphics stack ----
# Each fix makes a copy of the ROM's own file inside the module with a few instruction bytes
# changed. The ROM file itself is never modified; removing the module removes the copy.
# Nothing is applied unless the exact expected bytes are found exactly once, and the result is
# checked byte-for-byte afterwards. (On a module update /vendor and /odm already show the
# previously fixed copy, which is recognised and copied as is.)
FIXED="$MODPATH/.fixed"; rm -f "$FIXED"
hexat() { od -An -v -tx1 -j "$2" -N "$3" "$1" 2>/dev/null | tr -d ' \n'; }
fixlib() {  # <ROM file> <module copy> <expected offset> <original hex> <fixed hex> <label>
  src=$1; dst=$2; off=$3; orig=$4; new=$5; label=$6; n=$((${#orig} / 2))
  rm -f "$dst"
  [ -f "$src" ] || { ui_print "! $label: $src not found, fix not applied"; return 1; }
  cur=$(hexat "$src" "$off" "$n")
  if [ "$cur" != "$orig" ] && [ "$cur" != "$new" ]; then
    off=$(od -An -v -tx1 "$src" | awk -v a="$orig" -v b="$new" -v n="$n" '{for(i=1;i<=NF;i++){q[c%n]=$i;c++;if(c>=n){s="";for(k=0;k<n;k++)s=s q[(c+k)%n];if(s==a||s==b)print c-n}}}')
    if [ -z "$off" ] || [ "$(echo "$off" | wc -l)" != 1 ]; then
      ui_print "! $label: expected code not found, fix not applied"; return 1
    fi
    cur=$(hexat "$src" "$off" "$n")
  fi
  mkdir -p "${dst%/*}"; cp -p "$src" "$dst" || { rm -f "$dst"; return 1; }
  i=0; want=0
  while [ $i -lt $n ]; do
    ob=$(echo "$orig" | cut -c$((i * 2 + 1))-$((i * 2 + 2))); nb=$(echo "$new" | cut -c$((i * 2 + 1))-$((i * 2 + 2)))
    if [ "$ob" != "$nb" ] && [ "$cur" != "$new" ]; then
      want=$((want + 1))
      if [ "$nb" = 00 ]; then head -c 1 /dev/zero; else printf "\\$(printf %o 0x$nb)"; fi \
        | dd of="$dst" bs=1 seek=$((off + i)) conv=notrunc 2>/dev/null
    fi
    i=$((i + 1))
  done
  if [ "$(hexat "$dst" "$off" "$n")" = "$new" ] && [ "$(stat -c %s "$dst")" = "$(stat -c %s "$src")" ] \
     && [ "$(cmp -l "$src" "$dst" 2>/dev/null | wc -l)" = "$want" ]; then
    echo "${dst#$MODPATH/system/} $(ls -Z "$src" | awk '{print $1}')" >> "$FIXED"
    ui_print "- $label: fix applied"
  else
    rm -f "$dst"; ui_print "! $label: verification failed, fix not applied"; return 1
  fi
}

# 1) Offline camera service (vendor). It reads the capture-metadata buffer size from offset
#    0x1c of the graphics buffer handle. OxygenOS's gralloc keeps the buffer width there,
#    LineageOS's open-source snapalloc keeps the handle flags there (512), so only 512 bytes of
#    metadata were copied and photos came out black. Read the width from 0x2c instead.
#    ldr x24,[x20,#0x30]; mov x2,xzr; ldr w27,[x24,#0x1c -> 0x2c]; ldr w0,[x24,#0xc]
#    The fixed copy goes to /odm/lib64, which the camera HAL searches before /vendor/lib64 when it
#    loads this library by name, so the ROM's /vendor copy is shadowed, not overlaid.
OFFSRC=/vendor/lib64/vendor.qti.hardware.camera.offlinecamera-service-impl.so
[ -f "/data/adb/modules/oplus_camera_los/system/odm/lib64/${OFFSRC##*/}" ] && OFFSRC="/data/adb/modules/oplus_camera_los/system/odm/lib64/${OFFSRC##*/}"
fixlib "$OFFSRC" \
  "$MODPATH/system/odm/lib64/vendor.qti.hardware.camera.offlinecamera-service-impl.so" 111500 \
  981a40f9e2031faa1b1f40b9000f40b9 981a40f9e2031faa1b2f40b9000f40b9 "Offline camera service"

# 2) Camera processing library (odm). For Qualcomm's 10-bit format (YCbCr_420_P010_VENUS) it
#    takes the chroma plane from AHardwareBuffer_lockPlanes(). OxygenOS's framework returns all
#    three planes for that format; stock Android (LineageOS) returns only the luma plane, so
#    the chroma pointer was garbage and HDR / 10-bit processing crashed (blurry fallback shots).
#    Compute the chroma plane like the allocator lays it out: luma rows padded to 32, chroma
#    stride = luma stride.
fixlib /odm/lib64/libAlgoProcess.so "$MODPATH/system/odm/lib64/libAlgoProcess.so" 1875764 \
  e86f40f9e97740f98b008052eae740b9ecf740b9ed0741b9290108cb880e00f9290dca9a8b320a29 \
  e86f40f9e93341b98b008052eae740b9ec030a2aed030a2a297d0011880e00f929691b128b320a29 "Camera processing library"

# Refuse if another copy of the OnePlus camera is already installed (ROM or other module)
if pm path $PKG >/dev/null 2>&1 && [ ! -d /data/adb/modules/oplus_camera_los ]; then
  abort "! $PKG is already installed on this system. Remove it first."
fi

# Never shadow a file the ROM ships: every file in this module must be new to the system.
for f in $(cd "$MODPATH/system" && find . -type f | sed 's|^\./||'); do
  [ -f "$FIXED" ] && grep -q "^$f " "$FIXED" && continue   # fixed copy of the ROM's own file (above)
  [ -e "/system/$f" ] && [ ! -d /data/adb/modules/oplus_camera_los ] && abort "! ROM already has /system/$f - refusing to overlay it."
done

# A fresh install supersedes any cleanup still pending from an earlier removal
rm -rf /data/adb/oplus_camera_cleanup /data/adb/service.d/oplus_camera_cleanup.sh

# Snapshots used by uninstall to remove only what the camera added (kept inside the module dir).
S="$MODPATH/.snapshot"; mkdir -p "$S"
if [ ! -f /data/adb/modules/oplus_camera_los/.snapshot/persist ]; then
  getprop | sed -n 's/^\[\(persist\.[^]]*\)\].*/\1/p' | sort > "$S/persist"
  for t in global system secure; do settings list $t 2>/dev/null | cut -d= -f1 | sort > "$S/settings_$t"; done
else
  cp -f /data/adb/modules/oplus_camera_los/.snapshot/* "$S/"   # module update: keep the original snapshot
fi
# module update: carry over the record of directories this module created
[ -d /data/adb/modules/oplus_camera_los/.created ] && cp -rf /data/adb/modules/oplus_camera_los/.created "$MODPATH/"
[ -d /data/adb/modules/oplus_camera_los/.relabeled ] && cp -rf /data/adb/modules/oplus_camera_los/.relabeled "$MODPATH/"

# meta-overlayfs (and other metamodules) mount a copy of each module's files kept in their own
# image, not the module folder itself. On some versions a module update only adds files to that
# copy, so files an older version of this module shipped (its old /vendor files) stayed mounted.
# Remove from our own copy anything the current module doesn't ship. Only touches
# <metamodule mnt>/oplus_camera_los/system.
prune_mirror() {  # <current module dir>
  [ -d "$1/system" ] || return 0
  for root in /data/adb/metamodule/mnt /data/adb/modules/meta-overlayfs/mnt /data/adb/modules/meta-mountify/mnt; do
    M="$root/oplus_camera_los/system"
    [ -d "$M" ] || continue
    [ "$(readlink -f "$M")" = "$(readlink -f "$1/system")" ] && continue
    (cd "$M" && find . -mindepth 1 -depth 2>/dev/null) | while read -r p; do
      p=${p#./}
      [ -e "$1/system/$p" ] || [ -L "$1/system/$p" ] || rm -rf "$M/$p"
    done
  done
}
prune_mirror "$MODPATH"

set_perm_recursive "$MODPATH" 0 0 0755 0644
for d in system/system_ext/lib64 system/system_ext/priv-app/OplusCamera/lib/arm64; do
  [ -d "$MODPATH/$d" ] && set_perm_recursive "$MODPATH/$d" 0 0 0755 0644 u:object_r:system_lib_file:s0
done
# decoder for the camera SDK's encrypted algorithm config; loaded by the app through the
# same-process-HAL namespace, so it needs the SP-HAL label (as on OxygenOS / Infinity X)
# It lives on /odm because libAlgoProcess (on LineageOS's /odm) dlopens it by that absolute path.
[ -d "$MODPATH/system/odm" ] && set_perm_recursive "$MODPATH/system/odm" 0 0 0755 0644 u:object_r:vendor_file:s0
[ -f "$MODPATH/system/odm/lib64/libOplusSecurity.so" ] && chcon u:object_r:same_process_hal_file:s0 "$MODPATH/system/odm/lib64/libOplusSecurity.so"
# fixed copies keep the SELinux label of the ROM file they replace
[ -f "$FIXED" ] && while read -r f ctx; do
  case "$ctx" in u:object_r:*) ;; *) case "$f" in odm/*) ctx=u:object_r:same_process_hal_file:s0 ;; *) ctx="" ;; esac ;; esac
  [ -n "$ctx" ] && chcon "$ctx" "$MODPATH/system/$f"
done < "$FIXED"

# Directories are merged over the ROM's own, and the merged directory shows the module's label.
# Give every directory the exact label the ROM's directory has (from file_contexts for new ones),
# otherwise other processes lose access to it: an /odm/lib64/hw labeled vendor_file instead of
# vendor_hal_file stops every app's GPU driver loader (browsers' GPU process, camera apps).
(cd "$MODPATH/system" && find . -mindepth 1 -type d | sed 's|^\./||') | while read -r d; do
  ctx=$(ls -Zd "/$d" 2>/dev/null | awk '{print $1}')
  case "$ctx" in u:object_r:*) ;; *) ctx="" ;; esac
  case "$d" in */lib64/hw) ctx=u:object_r:vendor_hal_file:s0 ;; esac   # plat_file_contexts
  [ -n "$ctx" ] && chcon "$ctx" "$MODPATH/system/$d"
done

ui_print "- Installed. Reboot, then open 'Camera' (com.oplus.camera)."
ui_print "- KernelSU: modules must stay mounted for com.oplus.camera and your launcher."
ui_print "  If 'Umount modules' is on by default, exclude those two apps (App Profile)."
ui_print "- Action button saves a debug log to /sdcard/Download."
