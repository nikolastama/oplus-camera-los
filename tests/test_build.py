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

    def test_compressed_files_are_stored(self):
        """The installer only copies the erofs image instead of inflating it; scripts stay deflated.
        No data descriptors, which some unzip implementations don't read."""
        import zipfile

        with tempfile.TemporaryDirectory() as td:
            mod, z = Path(td) / 'module', Path(td) / 'm.zip'
            mod.mkdir()
            (mod / 'blobs.img').write_bytes(os.urandom(4096))
            (mod / 'common.sh').write_text('echo hi\n' * 100)
            B.write_zip(mod, z)
            info = {i.filename: i for i in zipfile.ZipFile(z).infolist()}
            self.assertEqual(info['blobs.img'].compress_type, zipfile.ZIP_STORED)
            self.assertEqual(info['common.sh'].compress_type, zipfile.ZIP_DEFLATED)
            self.assertFalse(any(i.flag_bits & 0x08 for i in info.values()))
            self.assertEqual(zipfile.ZipFile(z).testzip(), None)


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


class Secrets(unittest.TestCase):
    def test_password_is_masked_in_printed_commands(self):
        cmd = ('java', '-jar', 's.jar', '--ks', 'k.jks', '--ksPass', 'hunter2', '--ksKeyPass', 'hunter2')
        self.assertNotIn('hunter2', B.shown(cmd))
        self.assertIn('--ksPass ***', B.shown(cmd))
        self.assertEqual(B.shown(('sh', '-n', 'x.sh')), 'sh -n x.sh')


def loaded(elf):
    """The program headers and every PT_LOAD segment's file bytes of a 64-bit ELF file."""
    import struct

    phoff = struct.unpack_from('<Q', elf, 0x20)[0]
    phsize, phnum = struct.unpack_from('<HH', elf, 0x36)
    out = [elf[phoff : phoff + phsize * phnum]]
    for i in range(phnum):
        typ, _, off, _, _, filesz = struct.unpack_from('<IIQQQQ', elf, phoff + i * phsize)
        if typ == 1:
            out.append(elf[off : off + filesz])
    return out


class Wrapper(unittest.TestCase):
    @unittest.skipUnless(
        subprocess.run(['sh', '-c', 'command -v clang && command -v ld.lld'], capture_output=True).returncode
        == 0,
        'clang and lld are needed',
    )
    def test_prebuilt_wrapper_matches_its_source(self):
        """Everything the loader maps is identical (code, data, dynamic tables). Only the unmapped
        .comment section, where each LLVM distribution writes its own version string, may differ."""
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / 'oemwrap'
            subprocess.run(['cp', '-r', str(REPO / 'tools/oemwrap'), str(src)], check=True)
            subprocess.run(['sh', str(src / 'build.sh')], check=True, capture_output=True)
            built = (src / 'out/camera.oemlayer.wrap.so').read_bytes()
        self.assertEqual(loaded(built), loaded((REPO / 'prebuilt/camera.oemlayer.wrap.so').read_bytes()))

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
