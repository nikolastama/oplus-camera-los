"""tools/app_blobs.py: the camera app's own files LineageOS no longer ships, and their fixups."""

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / 'tools'))
import app_blobs as A  # noqa: E402

HAVE_TOOLS = shutil.which('cc') and shutil.which('readelf')


def build_so(td, code, *libs):
    src, out = Path(td) / 'x.c', Path(td) / 'libx.so'
    src.write_text(code)
    subprocess.run(['cc', '-shared', '-fPIC', '-o', str(out), str(src), *libs], check=True)
    return out


def dynsyms(path):
    return subprocess.run(['readelf', '--dyn-syms', '-W', str(path)], capture_output=True, text=True).stdout


class List(unittest.TestCase):
    def test_list_is_the_camera_app_part_of_lineageos_drop(self):
        p = A.paths()
        self.assertEqual(len(p), len(set(p)), 'duplicates')
        self.assertTrue(all(r.startswith(('odm/etc/camera/', 'odm/lib64/')) for r in p))
        self.assertFalse([r for r in p if 'AIMotion' in r or ';' in r or ':' in r])
        for must in (
            'odm/lib64/libAlgoProcess.so',
            'odm/lib64/libalog.so',
            'odm/lib64/com.oplus.node.defer.so',
        ):
            self.assertIn(must, p)

    def test_offline_camera_client_is_lineageos_version(self):
        """LineageOS ships offlinecamera-V3-ndk only; both libraries that link V2 must be pointed at it."""
        for rel in ('odm/lib64/libAlgoProcess.so', 'odm/lib64/libAlgoInterface.so'):
            self.assertIn(A.OFFLINE_CAMERA_V3, A.REPLACE_NEEDED[rel])
        old, new = A.OFFLINE_CAMERA_V3
        self.assertEqual(len(old), len(new))

    def test_every_fixup_target_is_shipped(self):
        self.assertTrue(set(A.fixups()) <= set(A.paths()))


class Labels(unittest.TestCase):
    CONTEXTS = (
        '/etc/camera u:object_r:vendor_configs_file:s0\n'
        '/etc/camera/m/x\\.bin u:object_r:vendor_configs_file:s0\n'
        '/lib64 u:object_r:vendor_file:s0\n'
        '/lib64/libA\\.so u:object_r:same_process_hal_file:s0\n'
    )

    def test_files_and_folders_take_the_odm_images_labels(self):
        c = A.read_contexts(self.CONTEXTS)
        got = A.labels(c, ['odm/lib64/libA.so', 'odm/etc/camera/m/x.bin'])
        self.assertEqual(
            got,
            [
                ('u:object_r:vendor_configs_file:s0', 'odm/etc/camera'),
                ('u:object_r:vendor_configs_file:s0', 'odm/etc/camera/m'),  # no entry: its parent's
                ('u:object_r:vendor_file:s0', 'odm/lib64'),
                ('u:object_r:vendor_configs_file:s0', 'odm/etc/camera/m/x.bin'),
                ('u:object_r:same_process_hal_file:s0', 'odm/lib64/libA.so'),
            ],
        )

    def test_file_without_label_stops_the_build(self):
        with self.assertRaises(ValueError):
            A.labels(A.read_contexts(self.CONTEXTS), ['odm/lib64/libB.so'])

    def test_image_labels_cover_every_path(self):
        """mkfs.erofs labels by file_contexts: every file, its folders and the image root get one,
        with names escaped (a '.' must not match any character)."""
        got = A.image_file_contexts(
            [
                ('u:object_r:vendor_file:s0', 'odm/lib64'),
                ('u:object_r:same_process_hal_file:s0', 'odm/lib64/libA+b.so'),
            ]
        )
        self.assertEqual(
            got,
            '/ u:object_r:vendor_file:s0\n'
            '/odm u:object_r:vendor_file:s0\n'
            '/odm/lib64 u:object_r:vendor_file:s0\n'
            '/odm/lib64/libA\\+b\\.so u:object_r:same_process_hal_file:s0\n',
        )

    def test_image_modes(self):
        self.assertEqual(
            A.image_fs_config(['odm/lib64/libA.so']),
            ' 0 0 0755\nodm 0 0 0755\nodm/lib64 0 0 0755\nodm/lib64/libA.so 0 0 0644\n',
        )

    def test_image_is_reproducible(self):
        cmd = A.mkfs_command('mkfs.erofs', Path('w'), Path('w/blobs'), Path('m/blobs.img'))
        self.assertIn('-T0', cmd)
        self.assertIn(f'-U{A.IMAGE_UUID}', cmd)
        self.assertIn('--all-root', cmd)
        self.assertEqual(cmd[-2:], ('m/blobs.img', 'w/blobs'))

    def test_release_image_is_deduplicated(self):
        def cmd(**kw):
            return A.mkfs_command('mkfs.erofs', Path('w'), Path('w/blobs'), Path('m/blobs.img'), **kw)

        self.assertIn('-Eztailpacking,fragments,dedupe', cmd())
        self.assertIn('-Eztailpacking,fragments', cmd(dedupe=False))

    def test_image_key_follows_its_inputs(self):
        with tempfile.TemporaryDirectory() as td:
            f, mkfs = Path(td) / 'a.so', Path(td) / 'mkfs'
            f.write_bytes(b'x')
            mkfs.write_bytes(b'm')
            k = A.image_key([('odm/lib64/a.so', f)], mkfs)
            self.assertEqual(k, A.image_key([('odm/lib64/a.so', f)], mkfs))
            self.assertNotEqual(k, A.image_key([('odm/lib64/b.so', f)], mkfs))
            self.assertNotEqual(k, A.image_key([('odm/lib64/a.so', f)], mkfs, dedupe=False))
            f.write_bytes(b'xy')
            self.assertNotEqual(k, A.image_key([('odm/lib64/a.so', f)], mkfs))

    def test_every_file_is_in_a_mounted_folder(self):
        A.check_mounts(A.paths())
        with self.assertRaises(ValueError):
            A.check_mounts(['odm/bin/x'])


@unittest.skipUnless(HAVE_TOOLS, 'cc and readelf are needed')
class ElfFixups(unittest.TestCase):
    def test_clear_symbol_version(self):
        with tempfile.TemporaryDirectory() as td:
            so = build_so(
                td,
                '#include <string.h>\nvoid *f(void *d, const void *s, size_t n) { return memcpy(d, s, n); }\n',
            )
            if '@GLIBC' not in [line for line in dynsyms(so).splitlines() if ' memcpy' in line][0]:
                self.skipTest('the host libc does not version memcpy')
            d = bytearray(so.read_bytes())
            self.assertEqual(A.clear_symbol_version(d, {'memcpy'}), 1)
            so.write_bytes(bytes(d))
            line = [line for line in dynsyms(so).splitlines() if ' memcpy' in line][0]
            self.assertNotIn('@', line)
            self.assertEqual(A.clear_symbol_version(d, {'memcpy'}), 0, 'already cleared')

    def test_replace_needed(self):
        with tempfile.TemporaryDirectory() as td:
            so = build_so(td, '#include <math.h>\ndouble f(double x) { return cos(x); }\n', '-lm')
            dyn = subprocess.run(['readelf', '-dW', str(so)], capture_output=True, text=True).stdout
            old = [
                line.split('[')[1].rstrip(']')
                for line in dyn.splitlines()
                if 'NEEDED' in line and 'libm' in line
            ]
            if not old:
                self.skipTest('the host links libm statically')
            new = old[0].replace('libm', 'libq')
            d = bytearray(so.read_bytes())
            self.assertTrue(A.replace_needed(d, old[0], new))
            self.assertFalse(A.replace_needed(d, 'libnothere.so', 'x'))
            with self.assertRaises(ValueError):
                A.replace_needed(d, new, new + 'longer')
            so.write_bytes(bytes(d))
            dyn = subprocess.run(['readelf', '-dW', str(so)], capture_output=True, text=True).stdout
            self.assertIn(f'[{new}]', dyn)

    def test_not_an_elf_file_fails_loudly(self):
        with self.assertRaises(ValueError):
            A.clear_symbol_version(bytearray(b'MZ' + bytes(100)), {'x'})


class ByteEdit(unittest.TestCase):
    def test_moved_edit_found_once_and_reapplied_harmlessly(self):
        off, orig, new = A.BYTE_EDITS['odm/lib64/libAlgoProcess.so'][0]
        stock = bytearray(b'\x11' * 3000 + bytes.fromhex(orig) + b'\x22' * 99)
        self.assertEqual(A.byte_edit(stock, off, orig, new), 3000)
        self.assertEqual(bytes(stock[3000 : 3000 + len(new) // 2]), bytes.fromhex(new))
        self.assertEqual(A.byte_edit(stock, off, orig, new), 3000, 'an already fixed file stays as it is')
        with self.assertRaises(ValueError):
            A.byte_edit(bytearray(b'\x00' * 4000), off, orig, new)


if __name__ == '__main__':
    unittest.main()
