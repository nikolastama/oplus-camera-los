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


class Binpatch(unittest.TestCase):
    """binpatch() finds an edit that moved in a newer build by its stored context window."""

    def spec(self, data, off, orig, new):
        ctx = B.edit_context(data, off, len(orig))
        self.assertIsNotNone(ctx)
        e = {'id': 'e', 'offset': off, 'orig': orig.hex(), 'new': new.hex(), 'why': 'test'}
        e['find'], e['at'] = ctx
        return {'src': 's', 'dst': 'd', 'src_sha256': '', 'dst_sha256': '', 'edits': [e]}

    def run_patch(self, data, spec):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / 'f'
            p.write_bytes(data)
            B.binpatch(p, spec)
            return p.read_bytes()

    def test_moved_one_byte_edit_is_found(self):
        stock = (
            bytes(range(256)) * 4 + b'libsensorbridge.so\x00vendor.x.so\x00' + bytes(range(255, -1, -1)) * 4
        )
        off = stock.index(b'libsensorbridge.so') + 14  # the 'e' of 'bridge'
        spec = self.spec(stock, off, b'e', b'2')
        self.assertEqual(self.run_patch(stock, spec), stock[:off] + b'2' + stock[off + 1 :])
        moved = b'\xaa' * 777 + stock
        out = self.run_patch(moved, spec)
        self.assertEqual(out[777:], stock[:off] + b'2' + stock[off + 1 :])

    def test_edits_are_located_before_any_is_applied(self):
        stock = bytes(range(256)) * 2 + b'a-V8-ndk.so\x00b-V8-ndk.so\x00' + bytes(range(256)) * 2
        o1, o2 = stock.index(b'a-V8') + 3, stock.index(b'b-V8') + 3
        s1, s2 = self.spec(stock, o1, b'8', b'9'), self.spec(stock, o2, b'8', b'9')
        spec = dict(s1, edits=s1['edits'] + [dict(s2['edits'][0], id='e2')])
        out = self.run_patch(b'\x00' * 99 + stock, spec)
        self.assertEqual(out[99:].count(b'-V9-ndk.so'), 2)

    def test_edit_that_no_longer_fits_stops_the_build(self):
        stock = b''.join(hashlib.sha256(bytes([i])).digest() for i in range(64))
        spec = self.spec(stock, 300, stock[300:301], b'\x00')
        with self.assertRaises(SystemExit):
            self.run_patch(bytes(reversed(stock)) + b'\x01', spec)

    def test_every_recorded_edit_has_a_context_window(self):
        import json

        for spec in json.loads((REPO / 'tools/binpatches.json').read_text()):
            for e in spec['edits']:
                self.assertIn('find', e, e['id'])
                w = bytes.fromhex(e['find'])
                self.assertEqual(
                    w[e['at'] : e['at'] + len(bytes.fromhex(e['orig']))], bytes.fromhex(e['orig'])
                )


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

    @unittest.skipUnless(shutil.which('cc'), 'a C compiler is needed')
    def test_timestamp_fix_logic(self):
        """tests/oemwrap_host_test.c: the frame-timestamp fix driven like the provider and layer do."""
        with tempfile.TemporaryDirectory() as td:
            exe = Path(td) / 'oemwrap_host_test'
            src = REPO / 'tests/oemwrap_host_test.c'
            subprocess.run(['cc', '-O1', '-Wall', '-Werror', '-o', str(exe), str(src)], check=True)
            r = subprocess.run([str(exe)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == '__main__':
    unittest.main()
