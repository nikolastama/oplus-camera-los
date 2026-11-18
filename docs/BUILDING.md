# Building the module

## You need

- Linux (or WSL) with `python3`, `java` (17+), `readelf`, `zip`
- [apktool](https://apktool.org) 2.12+ (`apktool.jar`)
- [uber-apk-signer](https://github.com/patrickfav/uber-apk-signer) 1.3.0 (`uber-apk-signer.jar`)
- the signing keystore (not in the repo). Keep using the same key: a different key means the old app must be removed before the new one installs.
- an extracted OxygenOS firmware for the OnePlus 15 (`CPH2745`): the `my_product`, `odm` and `system_ext` partitions. Any payload dumper that extracts the images and their files works.
- optional: `clang` + `lld` to rebuild the wrapper (`tools/oemwrap/build.sh`)

## Build

```sh
python3 tools/build_module.py \
  --dump /path/to/firmware/fs \
  --out out \
  --apktool /path/to/apktool.jar \
  --signer /path/to/uber-apk-signer-1.3.0.jar \
  --keystore /path/to/oplus-camera-module.jks --ks-alias opluscam --ks-pass '<password>'
```

The result is `out/oplus-camera-los-<version>.zip`, with `out/MANIFEST.sha256` listing every file in it.

What the script does:

1. Copies the module scripts (`module/`) and our config files (`overlay/`).
2. Copies the firmware libraries and configs listed in `tools/selection.json` and `EXTRA_COPIES`, then patches the APS client.
3. Builds the OnePlus camera layer: copies three OnePlus libraries from `odm/lib64`, applies `tools/binpatches.json`, and adds the wrapper.
4. Decodes, patches and rebuilds both SDK jars, and adds the stubs jar.
5. Decodes, patches, rebuilds and signs the app. Its native libraries are extracted from the stock APK into `priv-app/OplusCamera/lib/arm64`.
6. Verifies: no `/vendor` files, script syntax, checksums. Then zips.

## Leaving changes out

`--list-patches` shows every patch and native edit. `--skip <name>` leaves one out, and `--enable-component <class>` keeps a disabled component enabled. Details: REVERTING.md.

## Reproducibility

Built from the 16.0.10.601 firmware, every file matches the released module byte for byte, except the APK and the two SDK jars. Those three have identical contents and differ only in zip metadata and the signature.
