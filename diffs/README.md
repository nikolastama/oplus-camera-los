# diffs

One unified diff per patch, against a fresh apktool decode of the stock file, written by
`tools/make_diffs.py`. Each diff is applied on top of the previous ones, in the order the build
runs them (`python3 tools/build_module.py --list-patches`).

| Folder | Patched file |
|---|---|
| `app/` | `OplusCamera.apk` |
| `sdk/` | `com.oplus.camera.unit.sdk.jar` |
| `sdk-adapter/` | `com.oplus.camera.unit.sdk.adapter.jar` |
| `stubs/` | `oplus-camera-stubs.jar` (from `prebuilt/`) |

`app/*-camera_drop_embedded_libs.txt` lists the native libraries removed from the APK instead of a diff.

Regenerate after any change to `tools/patches.py` and commit the result with it:

```sh
python3 tools/make_diffs.py --dump <firmware dump root> --apktool apktool.jar
```

**Not yet recorded** (added after the last regeneration; the next run adds them and renumbers
`app/`): `camera_scoped_props` (v0.32), `restrict_exported_components` (v0.34) and
`stubs/stubs_scoped_props` (v0.32). What each changes is described in docs/PATCHES.md.
