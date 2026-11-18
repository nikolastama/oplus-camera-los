"""Build-script checks that need no firmware dump."""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / 'tools'))
import build_module as B  # noqa: E402


class Zip(unittest.TestCase):
    def test_same_files_give_the_same_zip(self):
        with tempfile.TemporaryDirectory() as td:
            mod, a, b = Path(td) / 'module', Path(td) / 'a.zip', Path(td) / 'b.zip'
            shutil.copytree(REPO / 'module', mod)
            B.write_zip(mod, a)
            time.sleep(1.1)
            os.utime(mod / 'module.prop')
            B.write_zip(mod, b)
            self.assertEqual(hashlib.sha256(a.read_bytes()).digest(), hashlib.sha256(b.read_bytes()).digest())


class Cli(unittest.TestCase):
    def run_build(self, *args, env=None):
        return subprocess.run(
            [sys.executable, str(REPO / 'tools/build_module.py'), *args],
            capture_output=True,
            text=True,
            env={**os.environ, **(env or {})},
        )

    def test_list_patches_names_every_patch(self):
        out = self.run_build('--list-patches').stdout
        for fn in B.APP_PATCHES + B.SDK_PATCHES + B.STUBS_PATCHES:
            self.assertIn(fn.__name__, out)

    def test_password_comes_from_the_environment(self):
        args = ('--dump', 'x', '--apktool', 'a', '--signer', 's', '--keystore', 'k')
        r = self.run_build(*args, env={'OPLUS_CAMERA_KS_PASS': ''})
        self.assertIn('OPLUS_CAMERA_KS_PASS', r.stderr)
        r = self.run_build(*args, '--skip', 'no_such_patch', env={'OPLUS_CAMERA_KS_PASS': 'x'})
        self.assertIn('unknown --skip', r.stderr)


class Wrapper(unittest.TestCase):
    @unittest.skipUnless(
        subprocess.run(['sh', '-c', 'command -v clang && command -v ld.lld'], capture_output=True).returncode
        == 0,
        'clang and lld are needed',
    )
    def test_prebuilt_wrapper_matches_its_source(self):
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / 'oemwrap'
            subprocess.run(['cp', '-r', str(REPO / 'tools/oemwrap'), str(src)], check=True)
            subprocess.run(['sh', str(src / 'build.sh')], check=True, capture_output=True)
            built = (src / 'out/camera.oemlayer.wrap.so').read_bytes()
        self.assertEqual(built, (REPO / 'prebuilt/camera.oemlayer.wrap.so').read_bytes())


if __name__ == '__main__':
    unittest.main()
