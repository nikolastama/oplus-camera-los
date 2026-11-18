#!/bin/sh
# Builds the session-tag wrapper (installed as /odm/lib64/hw/camera.oemlayer.v2.so).
# Needs only clang + lld; links against tiny stub libraries so no NDK/sysroot is required.
set -e
cd "$(dirname "$0")"
T="--target=aarch64-linux-android30"
mkdir -p out/stubs
for s in c:libc.so dl:libdl.so log:liblog.so cm:libcamera_metadata.so ol:camera.oemlayer.v2.so; do
  src=${s%%:*}; so=${s#*:}
  clang $T -shared -fPIC -nostdlib -fuse-ld=lld -Wl,-soname,$so -o out/stubs/$so stubs/$src.c
done
clang $T -O2 -fPIC -shared -nostdlib -fuse-ld=lld -fno-stack-protector -ffreestanding \
  -Wl,-soname,camera.oemlayer.wrap.so -Wl,--no-undefined \
  -o out/camera.oemlayer.wrap.so oemwrap.c \
  out/stubs/camera.oemlayer.v2.so out/stubs/libdl.so out/stubs/libc.so out/stubs/liblog.so out/stubs/libcamera_metadata.so
echo "built out/camera.oemlayer.wrap.so"
