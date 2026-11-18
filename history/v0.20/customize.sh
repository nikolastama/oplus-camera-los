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
OEMLAYER="$MODPATH/system/vendor/lib64/hw/camera.oemlayer.v2.so"
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
    rm -f "$OEMLAYER" "$MODPATH/system/vendor/lib64/camera.oemlayer.v2.so" "$MODPATH/system/vendor/lib64/libsensorbridg2.so" "$MODPATH/system/vendor/lib64/camera.oemlayer.uilaye2.so"; rmdir "$MODPATH/system/vendor/lib64/hw" "$MODPATH/system/vendor/lib64" "$MODPATH/system/vendor" 2>/dev/null
    ui_print "! OnePlus camera layer NOT installed, missing:$MISSING"
    ui_print "! The camera app will not identify its lenses without it."
  else
    ui_print "- OnePlus camera layer: all dependencies present"
  fi
fi

# Offline camera service metadata fix.
# The OnePlus blob reads the metadata buffer size from a fixed offset (0x1c) inside the
# graphics buffer handle. OxygenOS's gralloc keeps the width there; LineageOS's open-source
# snapalloc keeps the handle flags there (512), so the service copies only 512 bytes of the
# capture metadata and every offline JPEG comes out black. Make a copy of the ROM's own file
# with that one instruction changed to read the buffer's width (offset 0x2c on LineageOS).
# The copy lives only inside the module, the ROM file itself is never touched, and nothing is
# patched unless the exact expected instruction sequence is found exactly once.
OFFSVC=vendor.qti.hardware.camera.offlinecamera-service-impl.so
OFFSRC=/vendor/lib64/$OFFSVC
OFFDST="$MODPATH/system/vendor/lib64/$OFFSVC"
rm -f "$OFFDST"
if [ -f "$OFFSRC" ] && [ -d "$MODPATH/system/vendor/lib64" ]; then
  # ldr x24,[x20,#0x30]; mov x2,xzr; ldr w27,[x24,#0x1c]; ldr w0,[x24,#0xc]
  # (on a module update /vendor already shows the previously fixed copy, ...#0x2c..., which is accepted as is)
  HITS=$(od -An -v -tx1 "$OFFSRC" | awk '{for(i=1;i<=NF;i++){b[n%16]=$i;n++;if(n>=16){s="";for(k=0;k<16;k++)s=s b[(n+k)%16];if(s=="981a40f9e2031faa1b1f40b9000f40b9"||s=="981a40f9e2031faa1b2f40b9000f40b9")print n-16}}}')
  if [ -n "$HITS" ] && [ "$(echo "$HITS" | wc -l)" = 1 ]; then
    cp -p "$OFFSRC" "$OFFDST" && printf '\057' | dd of="$OFFDST" bs=1 seek=$((HITS + 9)) conv=notrunc 2>/dev/null
    CHK=$(od -An -v -tx1 -j $((HITS + 8)) -N 4 "$OFFDST" | tr -d ' \n')
    if [ "$CHK" = 1b2f40b9 ] && [ "$(stat -c %s "$OFFDST")" = "$(stat -c %s "$OFFSRC")" ]; then
      OFFCTX=$(ls -Z "$OFFSRC" | awk '{print $1}')
      echo "$OFFCTX" > "$MODPATH/.offsvc_ctx"
      ui_print "- Offline camera service: metadata size fix applied (offset $HITS)"
    else
      rm -f "$OFFDST"; ui_print "! Offline camera service: patch verification failed, not applied"
    fi
  else
    ui_print "! Offline camera service: expected code not found (${HITS:-0} matches), fix not applied"
  fi
fi

# Refuse if another copy of the OnePlus camera is already installed (ROM or other module)
if pm path $PKG >/dev/null 2>&1 && [ ! -d /data/adb/modules/oplus_camera_los ]; then
  abort "! $PKG is already installed on this system. Remove it first."
fi

# Never shadow a file the ROM ships: every file in this module must be new to the system.
for f in $(cd "$MODPATH/system" && find . -type f | sed 's|^\./||'); do
  [ "$f" = "vendor/lib64/$OFFSVC" ] && continue   # created below from the ROM's own copy
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

set_perm_recursive "$MODPATH" 0 0 0755 0644
for d in system/system_ext/lib64 system/system_ext/priv-app/OplusCamera/lib/arm64; do
  [ -d "$MODPATH/$d" ] && set_perm_recursive "$MODPATH/$d" 0 0 0755 0644 u:object_r:system_lib_file:s0
done
[ -d "$MODPATH/system/vendor" ] && set_perm_recursive "$MODPATH/system/vendor" 0 0 0755 0644 u:object_r:vendor_file:s0
[ -f "$OFFDST" ] && [ -f "$MODPATH/.offsvc_ctx" ] && chcon "$(cat "$MODPATH/.offsvc_ctx")" "$OFFDST" 
# decoder for the camera SDK's encrypted algorithm config; loaded by the app through the
# same-process-HAL namespace, so it needs the SP-HAL label (as on OxygenOS / Infinity X)
# It lives on /odm because libAlgoProcess (on LineageOS's /odm) dlopens it by that absolute path.
[ -d "$MODPATH/system/odm" ] && set_perm_recursive "$MODPATH/system/odm" 0 0 0755 0644 u:object_r:vendor_file:s0
[ -f "$MODPATH/system/odm/lib64/libOplusSecurity.so" ] && chcon u:object_r:same_process_hal_file:s0 "$MODPATH/system/odm/lib64/libOplusSecurity.so"

ui_print "- Installed. Reboot, then open 'Camera' (com.oplus.camera)."
ui_print "- KernelSU: modules must stay mounted for com.oplus.camera and your launcher."
ui_print "  If 'Umount modules' is on by default, exclude those two apps (App Profile)."
ui_print "- Action button saves a debug log to /sdcard/Download."
