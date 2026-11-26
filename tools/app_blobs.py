"""The OnePlus camera app's own libraries, models and data on /odm (tools/app_blobs.txt).

LineageOS stopped shipping them with its ColorOS-blob builds (they serve only the OnePlus camera), so
the module ships them from the ColorOS firmware the camera app comes from, with the fixups
LineageOS applied to them (from its extract-files.py before the drop) and the module's own fix of
libAlgoProcess (formerly made at install time from LineageOS's copy):

  clear_symbol_version  AHardwareBuffer_* are imported with a symbol version LineageOS's
                        libnativewindow doesn't define for these libraries; unversioned they load
  replace_needed        libAlgoProcess links graphics.common-V5, LineageOS ships V7. It and
                        libAlgoInterface link the offline camera service's client library at V2,
                        LineageOS ships V3 only and runs ColorOS's service (built against V2) on it
                        the same way; the symbols they use are all in V3. Without it libAlgoProcess
                        doesn't load and the camera crashes when it connects to its algorithms.
  libAlgoProcess P010   for Qualcomm's 10-bit format (YCbCr_420_P010_VENUS) it takes the chroma
                        plane from AHardwareBuffer_lockPlanes(), which on stock Android (LineageOS)
                        returns only the luma plane: garbage chroma pointer, HDR / 10-bit
                        processing crashed. Compute it like the allocator lays it out (luma rows
                        padded to 32, chroma stride = luma stride).

Every fixup checks what it changes and fails loudly when the file isn't as expected.
"""

import hashlib
import re
import struct
from pathlib import Path

LIST = Path(__file__).resolve().with_name('app_blobs.txt')

AHB_SYMBOLS = (
    'AHardwareBuffer_acquire',
    'AHardwareBuffer_allocate',
    'AHardwareBuffer_describe',
    'AHardwareBuffer_lock',
    'AHardwareBuffer_lockPlanes',
    'AHardwareBuffer_release',
    'AHardwareBuffer_unlock',
)
CLEAR_AHB_VERSIONS = (
    'odm/lib64/libAlgoProcess.so',
    'odm/lib64/libEISLive.so',
    'odm/lib64/libFaceBeautyJni.so',
    'odm/lib64/libFaceDistortionCorrection.so',
    'odm/lib64/libOPAlgoCamAiBeautyFaceRetouchCn.so',
    'odm/lib64/libOPAlgoCamAiUnifySkin.so',
    'odm/lib64/libOPAlgoCamFaceBeautyCap.so',
    'odm/lib64/libaiboost_te.so',
)
OFFLINE_CAMERA_V3 = (
    'vendor.qti.hardware.camera.offlinecamera-V2-ndk.so',
    'vendor.qti.hardware.camera.offlinecamera-V3-ndk.so',
)
REPLACE_NEEDED = {
    'odm/lib64/libAlgoInterface.so': (OFFLINE_CAMERA_V3,),
    'odm/lib64/libAlgoProcess.so': (
        ('android.hardware.graphics.common-V5-ndk.so', 'android.hardware.graphics.common-V7-ndk.so'),
        OFFLINE_CAMERA_V3,
    ),
}
# (expected offset, original hex, fixed hex); found by its bytes if it moved
BYTE_EDITS = {
    'odm/lib64/libAlgoProcess.so': (
        (
            # ColorOS 11.C.80, P010 case (format 0x7fa30c0a) after AHardwareBuffer_lockPlanes():
            #   ldr x9,[sp,#0xf8] (planes[1].data) -> ldr w9,[sp,#0x138] (camApsBufferDesc height)
            #   ldr w12/w13,[sp,#0x104/0x114] (chroma row strides) -> mov w12/w13,w10 (luma stride)
            #   sub x9,x9,x8; sdiv x9,x9,x10 (luma rows from the plane gap) -> (height + 31) & ~31
            2216696,
            'e87740f9e97f40f94b008052eaf740b9ec0741b9ed1741b9290108cb880e00f9290dca9a8b2a0429',
            'e87740f9e93b41b94b008052eaf740b9ec030a2aed030a2a297d0011880e00f929691b128b2a0429',
        ),
    ),
}

# The files stay in the module folder (blobs/), outside the metamodule's image, which they don't
# fit in; post-mount.sh mounts each of these directories as an overlay over the ROM's.
MOUNTS = ('odm/lib64', 'odm/etc/camera')
# SELinux labels of every file in the odm image, as extract.erofs writes them next to the files
CONTEXTS = 'odm/config/odm_file_contexts'

SHT_DYNSYM, SHT_DYNAMIC, SHT_GNU_VERSYM = 11, 6, 0x6FFFFFFF
DT_NEEDED = 1


def paths():
    return [
        line.strip() for line in LIST.read_text().splitlines() if line.strip() and not line.startswith('#')
    ]


def check_mounts(rels):
    """Every file must sit in one of the mounted directories (only those are overlaid)."""
    bad = [r for r in rels if not any(r.startswith(m + '/') for m in MOUNTS)]
    if bad:
        raise ValueError(f'not under {" or ".join(MOUNTS)}: {bad[:3]}')


def read_contexts(text):
    """{path inside the partition: label} from a per-file contexts list ("/etc/a\\.b u:object_r:x:s0")."""
    out = {}
    for line in text.splitlines():
        f = line.split()
        if len(f) >= 2 and f[0].startswith('/'):
            out[re.sub(r'\\(.)', r'\1', f[0])] = f[-1]
    return out


def labels(contexts, rels):
    """[(label, path)] for every file in <rels> and every directory from each mount point down,
    directories first. Files take their own label from the odm image; a directory without an
    entry takes its parent's."""

    def lookup(rel):
        return contexts.get('/' + rel.split('/', 1)[1])

    dirs = set()
    for r in rels:
        mount = next(m for m in MOUNTS if r.startswith(m + '/'))
        parts = r.split('/')
        for k in range(len(mount.split('/')), len(parts)):
            dirs.add('/'.join(parts[:k]))
    dir_label = {}
    for d in sorted(dirs):  # parents sort before their children
        dir_label[d] = lookup(d) or dir_label.get(d.rsplit('/', 1)[0])
        if not dir_label[d]:
            raise ValueError(f'no label for directory {d}')
    out = [(lb, d) for d, lb in dir_label.items()]
    missing = [r for r in rels if not lookup(r)]
    if missing:
        raise ValueError(f'{len(missing)} files have no label in {CONTEXTS}, e.g. {missing[:3]}')
    return out + [(lookup(r), r) for r in sorted(rels)]


def _sections(d):
    if d[:6] != b'\x7fELF\x02\x01':
        raise ValueError('not a 64-bit little-endian ELF file')
    shoff = struct.unpack_from('<Q', d, 0x28)[0]
    shentsize, shnum = struct.unpack_from('<HH', d, 0x3A)
    if not shoff or not shnum:
        raise ValueError('no section headers')
    out = []
    for i in range(shnum):
        name, kind, _flags, _addr, off, size, link, _info, _align, entsize = struct.unpack_from(
            '<IIQQQQIIQQ', d, shoff + i * shentsize
        )
        out.append({'type': kind, 'off': off, 'size': size, 'link': link, 'entsize': entsize})
    return out


def _cstr(d, off):
    return bytes(d[off : d.index(b'\0', off)]).decode('latin-1')


def clear_symbol_version(d, names):
    """Make the given dynamic symbols unversioned (version index 1, global), as patchelf
    --clear-symbol-version does. Returns how many symbols were changed."""
    secs = _sections(d)
    dynsym = [s for s in secs if s['type'] == SHT_DYNSYM]
    versym = [s for s in secs if s['type'] == SHT_GNU_VERSYM]
    if len(dynsym) != 1 or len(versym) != 1:
        raise ValueError('expected one .dynsym and one .gnu.version section')
    sym, ver = dynsym[0], versym[0]
    strtab = secs[sym['link']]['off']
    count = sym['size'] // 24
    if ver['size'] // 2 != count:
        raise ValueError('.gnu.version does not match .dynsym')
    changed = 0
    for i in range(count):
        st_name = struct.unpack_from('<I', d, sym['off'] + i * 24)[0]
        if _cstr(d, strtab + st_name) in names:
            at = ver['off'] + i * 2
            if struct.unpack_from('<H', d, at)[0] > 1:
                struct.pack_into('<H', d, at, 1)
                changed += 1
    return changed


def replace_needed(d, old, new):
    """Rename a DT_NEEDED entry in place (the new name may not be longer). Returns True if done."""
    if len(new) > len(old):
        raise ValueError(f'{new} is longer than {old}')
    secs = _sections(d)
    dyn = [s for s in secs if s['type'] == SHT_DYNAMIC]
    if len(dyn) != 1:
        raise ValueError('expected one .dynamic section')
    strtab = secs[dyn[0]['link']]['off']
    for i in range(dyn[0]['size'] // 16):
        tag, val = struct.unpack_from('<qQ', d, dyn[0]['off'] + i * 16)
        if tag == DT_NEEDED and _cstr(d, strtab + val) == old:
            at = strtab + val
            d[at : at + len(old)] = new.encode().ljust(len(old), b'\0')
            return True
    return False


def byte_edit(d, off, orig, new):
    """Apply one edit at <off> or at the one place its original bytes occur. Returns the offset."""
    o, n = bytes.fromhex(orig), bytes.fromhex(new)
    if bytes(d[off : off + len(o)]) not in (o, n):
        hits = [i for i in (d.find(o), d.find(n)) if i >= 0]
        if len(hits) != 1 or d.find(o, hits[0] + 1) >= 0 or d.find(n, hits[0] + 1) >= 0:
            raise ValueError('expected code not found exactly once')
        off = hits[0]
    d[off : off + len(n)] = n
    return off


def fix(rel, path):
    """Apply every fixup listed for module path <rel> to the file <path>. Returns what was done."""
    done = []
    d = bytearray(path.read_bytes())
    if rel in CLEAR_AHB_VERSIONS:
        done.append(f'{clear_symbol_version(d, AHB_SYMBOLS)} symbol versions cleared')
    for old, new in REPLACE_NEEDED.get(rel, ()):
        if not replace_needed(d, old, new):
            raise ValueError(f'{rel}: DT_NEEDED {old} not found')
        done.append(f'needs {new}')
    for off, orig, new in BYTE_EDITS.get(rel, ()):
        done.append(f'code fixed at {byte_edit(d, off, orig, new):#x}')
    if done:
        path.write_bytes(bytes(d))
    return done


def fixups():
    return sorted(set(CLEAR_AHB_VERSIONS) | set(REPLACE_NEEDED) | set(BYTE_EDITS))


# The files go into a read-only erofs image (blobs.img): Android's kernels refuse overlayfs layers
# on a filesystem that supports case-insensitive names, which /data (f2fs) does. The image carries
# the labels and modes itself.
IMAGE = 'blobs.img'
# fixed, so the same files always give the same image ("oplus-cam-los-blobs" in hex)
IMAGE_UUID = '6f706c75-7363-616d-6c6f-73626c6f6273'


def image_key(sources, mkfs, dedupe=True):
    """Fingerprint of everything blobs.img is made from: each source file (path, size, mtime), the
    file list and fixups (this module and app_blobs.txt), the mkfs.erofs binary and the dedupe
    choice. The image is reproducible, so equal keys give the same image and the build reuses the
    cached one."""
    h = hashlib.sha256(b'dedupe' if dedupe else b'no-dedupe')
    for f in (Path(__file__), LIST, Path(mkfs)):
        h.update(f.read_bytes())
    for rel, path in sources:
        st = Path(path).stat()
        h.update(f'{rel}\0{st.st_size}\0{st.st_mtime_ns}\n'.encode())
    return h.hexdigest()


def mkfs_command(mkfs, work, source, image, dedupe=True):
    """mkfs.erofs call for <image> from <source> with the labels and modes that build_module.py
    wrote to <work>: lz4hc like the ROM's own odm image (the fastest to decompress, so loading the
    models doesn't slow down), with file tails packed together (erofs in Linux 6.1+), identical
    data stored once, fixed time and UUID. Dedupe keeps the zip about 0.2 GB smaller (1.94 instead
    of 2.14 GB, close to GitHub's 2 GiB limit for a release file), but mkfs.erofs can only dedupe
    on one thread: build_module.py --no-dedupe makes the image on all cores in about half the time,
    for test builds. mkfs.erofs keeps the packed data in a temporary file: build_module.py points
    TMPDIR at <work>."""
    return (
        mkfs,
        '-zlz4hc,12',
        '-Eztailpacking,fragments' + (',dedupe' if dedupe else ''),
        '-T0',
        f'-U{IMAGE_UUID}',
        '--all-root',
        f'--file-contexts={(work / "blobs.file_contexts").as_posix()}',
        f'--fs-config-file={(work / "blobs.fs_config").as_posix()}',
        '--mount-point=/',
        image.as_posix(),
        source.as_posix(),
    )


def _fc_escape(path):
    return re.sub(r'([.^$*+?()\[\]{}|\\])', r'\\\1', path)


def image_file_contexts(labelled):
    """file_contexts for mkfs.erofs: every path of the image (root and parents too) with its label."""
    out = {'': 'u:object_r:vendor_file:s0'}
    for label, rel in labelled:
        parts = rel.split('/')
        for k in range(1, len(parts)):
            out.setdefault('/'.join(parts[:k]), 'u:object_r:vendor_file:s0')
        out[rel] = label
    return ''.join(f'/{_fc_escape(p)} {lb}\n' if p else f'/ {lb}\n' for p, lb in sorted(out.items()))


def image_fs_config(rels):
    """fs_config for mkfs.erofs: root-owned, folders 0755, files 0644."""
    dirs = {''}
    for r in rels:
        parts = r.split('/')
        dirs.update('/'.join(parts[:k]) for k in range(1, len(parts)))
    lines = [f'{d} 0 0 0755' for d in sorted(dirs)] + [f'{r} 0 0 0644' for r in sorted(rels)]
    return ''.join(line + '\n' for line in lines)
