"""Patch functions checked against the recorded diffs in diffs/.

Each diff holds, for every file it touches, the lines before and after its patch (plus a few lines
of context). The "before" fragments are written to a temporary tree, the patch function runs on
it, and the result must equal the "after" fragments. Patches whose anchors lie outside a diff's
context lines can't be checked this way and are listed in NEEDS_FULL_SOURCE.

    python3 -m unittest discover -s tests
"""

import re
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / 'tools'))
import patches as P  # noqa: E402

# Checked by tools/make_diffs.py instead, which runs every patch on a full decode of the stock file.
NEEDS_FULL_SOURCE = {
    'camera_blur_seginit_guard',
    'camera_defer_ufs_probe',
    'camera_gallery_fallback',
    'sdk_session_package_tag',
    'camera_no_telemetry',  # anchors on method headers far above the changed lines
    'camera_hide_dead_settings',  # checks the namespace declared at the top of the file
    'camera_scoped_props',  # counts both reflective reads in their whole files
    'stubs_scoped_props',  # adds a new class file
}


def parse_diff(path):
    """{file: (before, after)} from a unified diff; hunks are separated by a blank line."""
    files, cur = {}, None
    for line in path.read_text(encoding='utf-8', errors='surrogateescape').split('\n'):
        if line.startswith('diff --git'):
            cur = None
        elif line.startswith('+++ b/'):
            cur = line[6:]
            files[cur] = ([], [])
        elif cur and line.startswith('@@'):
            for side in files[cur]:
                side.append('\n')
        elif cur and line[:1] in (' ', '-', '+') and not line.startswith(('---', '+++')):
            if line[0] in ' -':
                files[cur][0].append(line[1:] + '\n')
            if line[0] in ' +':
                files[cur][1].append(line[1:] + '\n')
    return {f: (''.join(a), ''.join(b)) for f, (a, b) in files.items()}


def apply(fn, before):
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        for f, text in before.items():
            (root / f).parent.mkdir(parents=True, exist_ok=True)
            (root / f).write_text(text, encoding='utf-8', errors='surrogateescape')
        fn(root)
        return {f: (root / f).read_text(encoding='utf-8', errors='surrogateescape') for f in before}


class RecordedDiffs(unittest.TestCase):
    def test_patches_reproduce_their_diffs(self):
        diffs = sorted((REPO / 'diffs').glob('*/*.diff'))
        self.assertTrue(diffs)
        checked = 0
        for diff in diffs:
            name = re.sub(r'^\d+-', '', diff.stem)
            if name in NEEDS_FULL_SOURCE:
                continue
            with self.subTest(diff=f'{diff.parent.name}/{diff.name}'):
                files = parse_diff(diff)
                result = apply(getattr(P, name), {f: b for f, (b, _) in files.items()})
                for f, (_, after) in files.items():
                    self.assertEqual(result[f], after, f)
                checked += 1
        self.assertGreaterEqual(checked, 10)


class RestrictExportedComponents(unittest.TestCase):
    def manifest(self):
        files = parse_diff(REPO / 'diffs/app/04-strip_oem_component_permissions.diff')
        return files['AndroidManifest.xml'][1]

    def test_only_the_listed_components_change(self):
        before = self.manifest()
        after = apply(P.restrict_exported_components, {'AndroidManifest.xml': before})['AndroidManifest.xml']
        changed = [(a, b) for a, b in zip(before.splitlines(), after.splitlines()) if a != b]
        self.assertEqual(len(changed), len(P.INTERNAL_COMPONENTS))
        for a, b in changed:
            self.assertEqual(a.replace('android:exported="true"', 'android:exported="false"'), b)
        for name in P.INTERNAL_COMPONENTS:
            self.assertIn(f'android:name="{name}"', ''.join(b for _, b in changed))

    def test_running_twice_changes_nothing_more(self):
        once = apply(P.restrict_exported_components, {'AndroidManifest.xml': self.manifest()})
        twice = apply(P.restrict_exported_components, once)
        self.assertEqual(once, twice)

    def test_missing_component_fails_loudly(self):
        with self.assertRaises(ValueError):
            apply(P.restrict_exported_components, {'AndroidManifest.xml': '<manifest/>'})


class ByteSafeIO(unittest.TestCase):
    def test_undecodable_bytes_survive_a_patch(self):
        with tempfile.TemporaryDirectory() as td:
            f = Path(td) / 'a.smali'
            raw = b'const-string v0, "com.oplus.burst.capture.single"\n# \xff\xfe\n'
            f.write_bytes(raw)
            P._write(f, P._read(f).replace('.single', ''))
            self.assertEqual(f.read_bytes(), raw.replace(b'.single', b''))


if __name__ == '__main__':
    unittest.main()
