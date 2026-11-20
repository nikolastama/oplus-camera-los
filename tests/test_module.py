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
        self.assertIn('camera_no_telemetry', names)


if __name__ == '__main__':
    unittest.main()
