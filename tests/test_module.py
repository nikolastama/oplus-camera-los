"""Static checks on the module scripts and policy (no device or firmware needed)."""

import re
import sys
import unittest
from pathlib import Path

MODULE = Path(__file__).resolve().parent.parent / 'module'


def policy_rules():
    for line in (MODULE / 'sepolicy.rule').read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            yield line


class Policy(unittest.TestCase):
    def test_rules_only_name_the_cameras_domain(self):
        """The camera runs in priv_app_36; rules for plain priv_app only reach other apps."""
        plain = [r for r in policy_rules() if re.search(r'\bpriv_app\b(?!_)', r)]
        self.assertEqual(plain, [])

    def test_no_permissive_or_neverallow_overrides(self):
        for r in policy_rules():
            self.assertNotRegex(r, r'^(permissive|neverallow)\b', r)
            self.assertNotIn('*', r, r)


class CameraService(unittest.TestCase):
    def test_module_ships_no_cameraserver_copy(self):
        """Since v0.37 the frame-timestamp fix lives in the wrapper, not in a cameraserver copy."""
        for f in ('customize.sh', 'post-fs-data.sh', 'service.sh'):
            text = (MODULE / f).read_text()
            self.assertNotIn('system/bin/cameraserver', text, f)
            self.assertNotIn('rom_updated', text, f)


class LibraryFixes(unittest.TestCase):
    def test_fixes_are_made_from_the_roms_own_files(self):
        """A module install must never copy the previous version's fixed copy (stale after an OTA)."""
        text = (MODULE / 'customize.sh').read_text()
        self.assertNotIn('OFFSRC="$INSTALLED', text)
        self.assertIn('src=$(rom_src "$rom")', text)
        self.assertIn('odm_fp > "$MODPATH/.rom_fp"', text)

    def test_copies_are_remade_at_boot_without_asking_the_user(self):
        """After a LineageOS update the fixes are remade silently: no reinstall, no notification."""
        pfd = (MODULE / 'post-fs-data.sh').read_text()
        self.assertLess(pfd.index('refresh_fixes "$MODDIR"'), pfd.index('prune_mirror "$MODDIR"'))
        self.assertLess(pfd.index('adapt_to_rom "$MODDIR"'), pfd.index('refresh_fixes "$MODDIR"'))
        self.assertIn(
            'sync_mirror "$MODDIR" || { mount_metamodule_image && sync_mirror "$MODDIR"; } || touch "$MODDIR/.sync_mirror"',
            pfd,
        )
        service = (MODULE / 'service.sh').read_text()
        self.assertIn('sync_mirror "$MODDIR" && rm -f "$MODDIR/.sync_mirror"', service)
        notes = [line for line in service.splitlines() if 'cmd notification post' in line]
        self.assertEqual(len(notes), 1, 'only the layer crash watchdog notifies')
        for f in ('post-fs-data.sh', 'service.sh', 'common.sh'):
            self.assertNotIn('install the module', (MODULE / f).read_text().lower(), f)


class ColorOSBlobs(unittest.TestCase):
    """LineageOS's ColorOS-blob builds: the module wraps the ROM's layer and ships the app's files."""

    def test_installer_no_longer_needs_libalgoprocess_on_the_rom(self):
        text = (MODULE / 'customize.sh').read_text()
        self.assertNotIn('[ -e /odm/lib64/libAlgoProcess.so ]', text)
        self.assertNotIn('fixlib /odm/lib64/libAlgoProcess.so', text)
        self.assertIn('chcon u:object_r:ksu_file:s0 "$MODPATH/$BLOB_IMAGE"', text)

    def test_wrapper_over_the_roms_layer_is_the_only_allowed_overlay(self):
        text = (MODULE / 'customize.sh').read_text()
        self.assertIn('[ $ROM_LAYER = 1 ] && [ "$f" = odm/lib64/hw/camera.oemlayer.v2.so ] && continue', text)

    def test_installer_refuses_when_the_metamodule_image_is_too_small(self):
        """meta-overlayfs only warns when its copy fails; a half-copied module must never be mounted."""
        text = (MODULE / 'customize.sh').read_text()
        check = text.index('mountpoint -q "$MM_MNT"')
        self.assertGreater(check, text.index('prune_mirror "$MODPATH" || true'), 'after stale files are gone')
        self.assertIn('abort "! The metamodule\'s image has', text[check:])

    def test_app_files_stay_out_of_the_metamodule_image(self):
        """blobs.img (about 2 GB) isn't a partition folder, so meta-overlayfs doesn't copy it into its
        2 GB image; the size check counts only what it copies, and post-mount.sh mounts the image."""
        text = (MODULE / 'customize.sh').read_text()
        self.assertIn('NEED=$(du -sk "$MODPATH/system"', text)
        self.assertNotIn('label_blobs', text)
        post = (MODULE / 'post-mount.sh').read_text()
        self.assertIn('. "$MODDIR/common.sh"', post)
        self.assertIn('mount_blobs "$MODDIR"', post)
        common = (MODULE / 'common.sh').read_text()
        self.assertIn('BLOB_MOUNTS="odm/lib64 odm/etc/camera"', common)
        self.assertIn('BLOB_IMAGE=blobs.img', common)
        self.assertIn('mount -t erofs -o loop,ro', common)
        sys.path.insert(0, str(MODULE.parent / 'tools'))
        import app_blobs

        self.assertEqual(' '.join(app_blobs.MOUNTS), 'odm/lib64 odm/etc/camera')
        self.assertEqual(app_blobs.IMAGE, 'blobs.img')

    def test_watchdogs_skip_boots_on_outdated_files(self):
        service = (MODULE / 'service.sh').read_text()
        self.assertIn('if [ -f "$L" ] && [ $STALE = 0 ]; then', service)
        self.assertLess(service.index('STALE=1'), service.index('if [ -f "$L" ] && [ $STALE = 0 ]'))

    def test_installer_requires_lineageos_own_layer(self):
        """The ColorOS app and libraries need LineageOS's ColorOS-blob HAL and layer."""
        text = (MODULE / 'customize.sh').read_text()
        self.assertIn('[ -f /odm/lib64/hw/camera.oemlayer.v2.so ] || abort', text)
        self.assertNotIn('check_own_layer', text)
        self.assertNotIn('libcamxofehwl', text)


class DataDirs(unittest.TestCase):
    def test_tighten_dirs_runs_at_both_boot_stages(self):
        self.assertIn('tighten_dirs "$MODDIR"', (MODULE / 'post-fs-data.sh').read_text())
        service = (MODULE / 'service.sh').read_text()
        self.assertIn('. "$MODDIR/common.sh"', service)
        wait = service.index('sys.boot_completed')
        self.assertGreater(service.index('tighten_dirs "$MODDIR"'), wait, 'needs the app installed')

    def test_privapp_list_is_set_before_the_boot_wait(self):
        service = (MODULE / 'service.sh').read_text()
        self.assertLess(
            service.index('resetprop -n persist.vendor.camera.privapp.list'),
            service.index('until [ "$(getprop sys.boot_completed)" = 1 ]'),
        )


class Precompile(unittest.TestCase):
    def test_runs_in_the_background_after_boot_and_only_once(self):
        service = (MODULE / 'service.sh').read_text()
        self.assertIn('precompile &', service)
        self.assertGreater(service.index('precompile &'), service.index('sys.boot_completed'))
        body = service[service.index('precompile() {') : service.index('precompile &')]
        self.assertIn('status=verify', body, 'leave an already compiled app alone')
        self.assertIn('.precompiled', body, 'one attempt per ROM build and APK')
        self.assertIn('-m speed-profile', body)


class Telemetry(unittest.TestCase):
    def test_patch_runs_before_props_and_lib_drop(self):
        sys.path.insert(0, str(MODULE.parent / 'tools'))
        import build_module as B

        names = [f.__name__ for f in B.APP_PATCHES]
        self.assertLess(names.index('camera_no_telemetry'), names.index('camera_scoped_props'))
        self.assertLess(names.index('camera_scoped_props'), names.index('camera_drop_embedded_libs'))


if __name__ == '__main__':
    unittest.main()
