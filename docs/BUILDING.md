# Building the module

## You need

- Linux (or WSL) with `python3`, `java` (17+), `readelf`, `zip`. Windows works too (Git Bash, a `readelf` on `PATH`); the tools write LF line endings there as well.
- [apktool](https://apktool.org) 2.12+ (`apktool.jar`)
- [uber-apk-signer](https://github.com/patrickfav/uber-apk-signer) 1.3.0 (`uber-apk-signer.jar`)
- [erofs-utils](https://github.com/erofs/erofs-utils) 1.8+ (`mkfs.erofs` on `PATH`, or `--mkfs-erofs <path>`) for the image of the camera app's files
- the signing keystore (not in the repo). Keep using the same key: a different key means the old app must be removed before the new one installs.
- the extracted ColorOS firmware for the OnePlus 15 the LineageOS build takes its blobs from (`CPH2745_11.C.80`, ColorOS `CPH2745_17.0.1.201(EX01)`): the `my_product`, `odm`, `system_ext` and `system` partitions, extracted with their SELinux labels. `extract.erofs` (erofs-utils) writes them to `<partition>/config/<partition>_file_contexts`; the build needs `odm/config/odm_file_contexts` to label the camera app's files. Any payload dumper that extracts the images works.
- optional: `clang` + `lld` to rebuild the wrapper (`tools/oemwrap/build.sh`)

## Build

```sh
python3 tools/build_module.py \
  --dump /path/to/firmware/fs \
  --out out \
  --apktool /path/to/apktool.jar \
  --signer /path/to/uber-apk-signer-1.3.0.jar \
  --keystore /path/to/oplus-camera-module.jks --ks-alias opluscam
```

The keystore password comes from the environment variable `OPLUS_CAMERA_KS_PASS` (for example `read -rs OPLUS_CAMERA_KS_PASS; export OPLUS_CAMERA_KS_PASS`), so it doesn't end up in your shell history. `--out` may be an existing folder: only the build's own `work/` and `module/` inside it are replaced.

The result is `out/oplus-camera-los-<version>.zip`, with `out/MANIFEST.sha256` listing every file in it.

What the script does:

1. Copies the module scripts (`module/`) and our config files (`overlay/`).
2. Copies the firmware libraries and configs listed in `tools/selection.json` and `EXTRA_COPIES`, and puts the camera app's own libraries, models and configs on `/odm` that LineageOS no longer ships into the read-only erofs image `blobs.img` with their odm labels (`tools/app_blobs.txt`, with LineageOS's former fixups and the P010 fix, `tools/app_blobs.py`), then patches the APS client. Making the image takes minutes, so the build keeps the last one in `<out>/cache` and reuses it while its inputs are unchanged (the source files, `tools/app_blobs.txt`, `tools/app_blobs.py` and `mkfs.erofs`); delete that folder to force a new one. The image stores identical data once, which keeps the zip under GitHub's 2 GiB limit for a release file but makes `mkfs.erofs` run on one thread; `--no-dedupe` makes it on all cores in about half the time, for test builds (the zip is about 0.2 GB larger).
3. Adds the wrapper of the OnePlus camera layer (the installer makes the private copies of LineageOS's layer).
4. Decodes, patches and rebuilds both SDK jars and the stubs jar.
5. Decodes, patches, rebuilds and signs the app. Its native libraries are extracted from the stock APK into `priv-app/OplusCamera/lib/arm64`.
6. Verifies: no `/vendor` files, script syntax, checksums. Then zips.

## Leaving changes out

`--list-patches` shows every patch. `--skip <name>` leaves one out, and `--enable-component <class>` keeps a disabled component enabled. Details: REVERTING.md.

## Checks without firmware

`python3 -m unittest discover -s tests` and `sh tests/test_common.sh` run the patches against the recorded `diffs/`, the module's shared shell functions on a simulated metamodule copy, the build script's options and zip writer, and (with clang/lld 18.1.3) rebuild the wrapper and compare it with `prebuilt/`. GitHub runs them, plus `black`/`ruff` and a syntax check of every script, on each push (`.github/workflows/checks.yml`).

## Reproducibility

Built from the same firmware, every file matches the released module byte for byte, except the APK and the two SDK jars. Those three have identical contents and differ only in zip metadata and the signature. The module zip itself is written with fixed timestamps and order, so the same files always give the same zip.
