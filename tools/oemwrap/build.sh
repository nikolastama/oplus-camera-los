#!/bin/sh
# Builds the session-tag wrapper (installed as /odm/lib64/hw/camera.oemlayer.v2.so).
# Needs only clang + lld; links against tiny stub libraries so no NDK/sysroot is required.
# prebuilt/camera.oemlayer.wrap.so is built with clang/lld 18.1.3 (LLVM's Windows release); any
# 18.1.3 build (Ubuntu 24.04's too) gives the same loaded bytes (checked by tests/test_build.py);
# only the unmapped .comment version string differs. No build ID (lld would hash that string into
# it) and inline atomics are set explicitly, as distributions differ in their defaults.
set -e
cd "$(dirname "$0")"
T="--target=aarch64-linux-android30"
mkdir -p out/stubs
for s in c:libc.so dl:libdl.so log:liblog.so cm:libcamera_metadata.so ol:camera.oemlayer.v2.so; do
  src=${s%%:*}; so=${s#*:}
  clang $T -shared -fPIC -nostdlib -fuse-ld=lld -Wl,-soname,$so -o out/stubs/$so stubs/$src.c
done
clang $T -O2 -fPIC -shared -nostdlib -fuse-ld=lld -fno-stack-protector -ffreestanding -mno-outline-atomics \
  -Wl,-soname,camera.oemlayer.wrap.so -Wl,--no-undefined -Wl,--build-id=none \
  -o out/camera.oemlayer.wrap.so oemwrap.c \
  out/stubs/camera.oemlayer.v2.so out/stubs/libdl.so out/stubs/libc.so out/stubs/liblog.so out/stubs/libcamera_metadata.so
echo "built out/camera.oemlayer.wrap.so"
