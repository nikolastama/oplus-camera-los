#!/bin/sh
# module/selftest.sh against fake am/input/dumpsys/logcat/pidof: a healthy run passes every check,
# and a lost frame, a camera HAL restart and a missing video are reported. POSIX sh.
#   sh tests/test_selftest.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/mod" "$T/sdcard/DCIM/Camera" "$T/sdcard/Download" "$T/tmp" "$T/tomb" "$T/state"
cp "$REPO/module/selftest.sh" "$REPO/module/module.prop" "$T/mod/"
sed -i "s|/sdcard|$T/sdcard|g; s|/data/local/tmp|$T/tmp|g; s|/data/tombstones|$T/tomb|g; s|/proc/uptime|$T/uptime|g" "$T/mod/selftest.sh"
echo "3600.00 7200.00" > "$T/uptime"   # past the self-test's start-up wait, whatever the host's uptime
S=$T/state; C=$T/sdcard/DCIM/Camera
cat > "$T/bin/am" <<EOF
#!/bin/sh
case "\$*" in *"start -W"*) echo "TotalTime: 812";; esac
case "\$*" in *VIDEO_CAMERA*) echo video > $S/mode;; *force-stop*) ;; *) echo photo > $S/mode;; esac
EOF
cat > "$T/bin/input" <<EOF
#!/bin/sh
m=\$(cat $S/mode); n=\$(ls $C | wc -l)
if [ "\$m" = video ]; then
  [ "\${NOVIDEO:-0}" = 1 ] && exit 0
  if [ -f $S/rec ]; then rm $S/rec; touch $C/VID_\$n.mp4; else touch $S/rec; fi
else touch $C/IMG_\$n.jpg; fi
EOF
cat > "$T/bin/dumpsys" <<EOF
#!/bin/sh
case "\$1" in power) echo "  mWakefulness=Awake";; media.camera) [ -f $S/open ] && echo "Device 0 is open";; esac
EOF
cat > "$T/bin/pidof" <<EOF
#!/bin/sh
case "\$1" in com.oplus.camera) touch $S/open; echo 4242;;
  *provider*) if [ "\${HALRESTART:-0}" = 1 ] && [ -f $S/p ]; then echo 999; else touch $S/p; echo 777; fi;;
  *) exit 1;; esac   # nothing else runs (no dex2oat compiling)
EOF
cat > "$T/bin/logcat" <<'EOF'
#!/bin/sh
i=0; while [ $i -lt 20 ]; do echo "11-19 10:00:00.000 1 1 I Something: line $i"; i=$((i + 1)); done
[ "${LOSTFRAME:-0}" = 1 ] && echo "11-19 10:00:01.000 1 1 W CameraDevice-JV: onCaptureBufferLost"
echo "11-19 10:00:01.000 1 1 I OplusCamLosWrap: camera 0 frame 9: shutter 1 older than previous 2, sent as 3"
EOF
printf '#!/bin/sh\necho package:/x.apk\n' > "$T/bin/pm"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/content"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*
run() { (cd "$T" && env PATH="$T/bin:$PATH" "$@" sh "$T/mod/selftest.sh" 2>&1); rm -f "$S"/*; }
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
OUT=$(run X=1)
check "healthy run: all pass"        'echo "$OUT" | grep -q "Result: 12 passed, 0 failed"'
check "test media deleted"           '[ -z "$(ls "$C")" ]'
check "report saved"                 '[ -n "$(ls "$T/sdcard/Download")" ]'
OUT=$(run LOSTFRAME=1 HALRESTART=1 NOVIDEO=1)
check "lost frame reported"          'echo "$OUT" | grep -q "FAIL  portrait frames: 1 lost"'
check "HAL restart reported"         'echo "$OUT" | grep -q "FAIL  camera HAL restarted"'
check "missing video reported"       'echo "$OUT" | grep -q "FAIL  video"'
exit $fail
