"""Guest storage classification must preserve every nonblank disk."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'guest/storage.sh'
STORAGE_TEXT = SCRIPT.read_text()


def write_stub(directory, name, body):
    path = directory / name
    path.write_text('#!/bin/sh\n' + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


class StorageClassificationTests(unittest.TestCase):
    def run_storage(self, root, disk, action='start', kind='', label='', memory='4008360', extra_env=None):
        bin_dir = root / 'bin'
        bin_dir.mkdir(exist_ok=True)
        calls = root / 'calls'
        write_stub(bin_dir, 'blkid', f'''
if [ "$2" = TYPE ]; then printf '%s\\n' '{kind}'; else printf '%s\\n' '{label}'; fi
''')
        write_stub(bin_dir, 'modprobe', f'''
printf "%s\\n" "$*" >> "{calls}"
if [ "${{TAMA_MODPROBE_FAIL:-}}" = zfs ] && [ "$1" = zfs ]; then exit 1; fi
''')
        write_stub(bin_dir, 'zpool', f'''
printf "zpool %s\\n" "$*" >> "{calls}"
if [ "$1" = get ]; then
  case "$*" in
    *expandsize*) printf '%s\\n' "${{TAMA_ZPOOL_EXPANDSIZE:--}}" ;;
    *size*) printf '4294967296\\n' ;;
    *) printf '120\\n' ;;
  esac
  exit 0
fi
if [ "$1" = status ]; then printf '%s\\n' "${{TAMA_ZPOOL_STATUS_DISK:-{disk}}}"; exit 0; fi
if [ "$1" = online ] && [ "${{TAMA_ZPOOL_ONLINE_FAIL:-}}" = 1 ]; then exit 1; fi
# With TAMA_ZPOOL_IMPORTED set, the pool is listed only after an import and until an export.
if [ "$1" = list ] && [ -n "${{TAMA_ZPOOL_IMPORTED:-}}" ]; then
  [ -f "$TAMA_ZPOOL_IMPORTED" ] || exit 1
  exit 0
fi
if [ "$1" = import ]; then
  if [ "${{TAMA_ZPOOL_IMPORT_OK:-}}" = 1 ]; then
    if [ -n "${{TAMA_ZPOOL_IMPORTED:-}}" ]; then : > "$TAMA_ZPOOL_IMPORTED"; fi
    exit 0
  fi
  exit 1
fi
if [ "$1" = export ] && [ -n "${{TAMA_ZPOOL_IMPORTED:-}}" ]; then rm -f "$TAMA_ZPOOL_IMPORTED"; fi
if [ "$1" = export ] && [ -n "${{TAMA_EXPORT_FAILS_FILE:-}}" ]; then
  left=$(cat "$TAMA_EXPORT_FAILS_FILE")
  if [ "$left" -gt 0 ]; then
    echo $((left - 1)) > "$TAMA_EXPORT_FAILS_FILE"
    echo "cannot unmount '/var/lib/incus': pool or dataset is busy" >&2
    exit 1
  fi
fi
exit 0
''')
        write_stub(bin_dir, 'rc-service', f'printf "rc-service %s\\n" "$*" >> "{calls}"\nexit "${{TAMA_INCUSD_STATUS:-3}}"\n')
        write_stub(bin_dir, 'zfs', f'''
printf "zfs %s\\n" "$*" >> "{calls}"
if [ "$1" = list ] && [ "${{TAMA_ZFS_NO_METADATA:-}}" = 1 ]; then exit 1; fi
if [ "$1" = get ]; then
  case "$*" in
    *available*) printf '1073741824\\n' ;;
    *refreservation*) printf '1073741824\\n' ;;
    *mounted*) printf 'yes\\n' ;;
    *name*) printf 'tama-data/metadata\\n' ;;
    *) printf '%s\\n' "$TAMA_METADATA_MOUNT" ;;
  esac
  exit 0
fi
exit 0
''')
        for command in ('mount', 'umount', 'e2fsck', 'resize2fs', 'blockdev', 'mkfs.ext4'):
            write_stub(bin_dir, command, f'printf "%s %s\\n" "{command}" "$*" >> "{calls}"\n')
        write_stub(bin_dir, 'mountpoint', 'if [ "${TAMA_MOUNTPOINT_PRESENT:-}" = 1 ]; then exit 0; fi\nexit 1\n')
        write_stub(bin_dir, 'findmnt', 'printf "%s\\n" "${TAMA_FINDMOUNT_SOURCE:-tama-data/metadata}"\n')
        write_stub(bin_dir, 'sync', 'exit 0\n')
        write_stub(bin_dir, 'incus', f'''
printf "incus %s\\n" "$*" >> "{calls}"
if [ "$2" = /1.0/profiles/default ]; then
  printf '%s\\n' '{{"devices":{{"root":{{"pool":"default","size":"2GiB"}}}}}}'
else
  printf '%s\\n' '{{"driver":"zfs","config":{{"source":"tama-data/workloads","volume.zfs.reserve_space":"true","volume.zfs.use_refquota":"true"}}}}'
fi
''')
        env = dict(os.environ)
        env.update({
            'PATH': f'{bin_dir}:/usr/bin:/bin',
            'TAMA_STORAGE_ROOT': str(root),
            'TAMA_DISK': str(disk),
            'TAMA_METADATA_MOUNT': str(root / 'metadata'),
            'TAMA_MEMINFO': str(root / 'meminfo'),
            'TAMA_STORAGE_LOG': str(root / 'storage.log'),
        })
        if extra_env:
            env.update(extra_env)
        (root / 'meminfo').write_text(f'MemTotal:       {memory} kB\n')
        (root / 'metadata').mkdir(exist_ok=True)
        (root / 'run').mkdir(exist_ok=True)
        return subprocess.run(['sh', str(SCRIPT), action], env=env, text=True, capture_output=True), calls

    def owned_identity(self, root, phase='ready'):
        identity = root / 'etc/tama-storage'
        identity.mkdir(parents=True)
        (root / 'metadata').mkdir(parents=True, exist_ok=True)
        (root / 'run').mkdir(parents=True, exist_ok=True)
        (identity / 'layout').write_text('zfs-v1\n')
        (identity / 'phase').write_text(phase + '\n')
        (identity / 'pool-guid').write_text('120\n')
        (root / 'metadata' / '.tama-storage-layout').write_text('zfs-v1\n')
        (root / 'run/tama-storage-backend').write_text('zfs\n')

    def test_appliance_does_not_mutate_incus_workloads(self):
        self.assertNotIn('apply_headroom', STORAGE_TEXT)
        self.assertNotIn('workloads/containers', STORAGE_TEXT)
        self.assertNotIn('workloads/virtual-machines', STORAGE_TEXT)

    def test_blank_disk_creates_owned_pool_without_ext4(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 64)
            os.truncate(disk, 4 * 1024 ** 3)
            result, calls = self.run_storage(root, disk)
            log = (root / 'storage.log').read_text()
            self.assertEqual(result.returncode, 0, log)
            self.assertIn('TAMA_STORAGE_ZFS_CREATED', log)
            recorded = calls.read_text()
            self.assertIn('zpool create', recorded)
            self.assertNotIn('mkfs.ext4', recorded)
            self.assertNotIn('zfs set refreservation=33554432', recorded)
            self.assertEqual((root / 'etc/tama-storage/phase').read_text().strip(), 'preseed-pending')
            self.assertEqual((root / 'etc/tama-storage/layout').read_text().strip(), 'zfs-v1')

    def test_nonzero_tail_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 64)
            os.truncate(disk, 4 * 1024 ** 3)
            with disk.open('r+b') as handle:
                handle.seek(4 * 1024 ** 3 - 1)
                handle.write(b'\x01')
            result, calls = self.run_storage(root, disk)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('nonblank', (root / 'storage.log').read_text())
            self.assertNotIn('zpool create', calls.read_text() if calls.exists() else '')

    def test_small_disk_and_low_memory_are_rejected_before_format(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 1024)
            result, _calls = self.run_storage(root, disk)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('at least 4 GiB', (root / 'storage.log').read_text())
            self.assertFalse((root / 'etc/tama-storage/phase').exists())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 64)
            os.truncate(disk, 4 * 1024 ** 3)
            result, _calls = self.run_storage(root, disk, memory='2015380')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('below 3670016 KiB', (root / 'storage.log').read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 64)
            os.truncate(disk, 4 * 1024 ** 3)
            result, calls = self.run_storage(root, disk, memory='3670016', extra_env={'TAMA_MODPROBE_FAIL': 'zfs'})
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertNotIn('below 3670016 KiB', log)
            self.assertIn('module is unavailable', log)
            self.assertNotIn('zpool create', calls.read_text() if calls.exists() else '')

    def test_missing_module_leaves_blank_disk_unformatted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 64)
            os.truncate(disk, 4 * 1024 ** 3)
            result, calls = self.run_storage(root, disk, extra_env={'TAMA_MODPROBE_FAIL': 'zfs'})
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / 'etc/tama-storage/phase').exists())
            self.assertNotIn('zpool create', calls.read_text() if calls.exists() else '')

    def test_interrupted_intent_on_nonblank_disk_is_not_reformatted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 64)
            os.truncate(disk, 4 * 1024 ** 3)
            with disk.open('r+b') as handle:
                handle.seek(10)
                handle.write(b'\x01')
            identity = root / 'etc/tama-storage'
            identity.mkdir(parents=True)
            (identity / 'phase').write_text('intent-blank\n')
            result, calls = self.run_storage(root, disk)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('no recorded pool GUID', (root / 'storage.log').read_text())
            self.assertNotIn('zpool create', calls.read_text() if calls.exists() else '')
            self.assertNotIn('zpool import', calls.read_text() if calls.exists() else '')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'partial-pool')
            identity = root / 'etc/tama-storage'
            identity.mkdir(parents=True)
            (identity / 'phase').write_text('intent-blank\n')
            (root / 'metadata').mkdir()
            (root / 'metadata' / '.tama-storage-layout').write_text('foreign-layout-v2\n')
            result, calls = self.run_storage(root, disk, extra_env={'TAMA_ZPOOL_IMPORT_OK': '1'})
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text() if calls.exists() else ''
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('no recorded pool GUID', log)
            self.assertNotIn('zpool import', recorded)
            self.assertNotIn('zpool create', recorded)
            self.assertNotIn('TAMA_STORAGE_ZFS_READY', log)
            self.assertFalse((identity / 'pool-guid').exists())
            self.assertEqual((root / 'metadata' / '.tama-storage-layout').read_text().strip(), 'foreign-layout-v2')
            self.assertFalse((root / 'metadata/.tama-preseed-pending').exists())
            self.assertEqual((identity / 'phase').read_text().strip(), 'intent-blank')

    def test_recorded_guid_does_not_adopt_foreign_layout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'partial-pool')
            identity = root / 'etc/tama-storage'
            identity.mkdir(parents=True)
            (identity / 'phase').write_text('intent-blank\n')
            (identity / 'pool-guid').write_text('120\n')
            (root / 'metadata').mkdir()
            (root / 'metadata' / '.tama-storage-layout').write_text('foreign-layout-v2\n')
            result, calls = self.run_storage(root, disk, extra_env={'TAMA_ZPOOL_IMPORT_OK': '1'})
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('foreign metadata layout', log)
            imports = [line for line in recorded.splitlines() if line.startswith('zpool import')]
            self.assertTrue(imports, recorded)
            self.assertTrue(all(line.endswith(' 120') for line in imports), imports)
            self.assertFalse(any(line.endswith(' tama-data') for line in imports), imports)
            self.assertNotIn('zfs set', recorded)
            self.assertEqual((root / 'metadata/.tama-storage-layout').read_text().strip(), 'foreign-layout-v2')
            self.assertFalse((root / 'metadata/.tama-preseed-pending').exists())
            self.assertEqual((identity / 'phase').read_text().strip(), 'intent-blank')

    def test_datasets_ready_resumes_preseed_without_recreate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root, phase='datasets-ready')
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            log = (root / 'storage.log').read_text()
            self.assertEqual(result.returncode, 0, log)
            self.assertEqual((root / 'etc/tama-storage/phase').read_text().strip(), 'preseed-pending')
            self.assertTrue((root / 'metadata/.tama-preseed-pending').is_file())
            self.assertNotIn('zpool create', calls.read_text())

    def test_pool_created_with_existing_database_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root, phase='pool-created')
            metadata = root / 'metadata'
            (metadata / 'database').mkdir()
            (metadata / 'database' / 'db.bin').write_bytes(b'foreign-db')
            (metadata / 'sentinel').write_text('do-not-touch\n')
            before = {
                path.relative_to(metadata).as_posix(): path.read_bytes()
                for path in metadata.rglob('*') if path.is_file()
            }
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text()
            after = {
                path.relative_to(metadata).as_posix(): path.read_bytes()
                for path in metadata.rglob('*') if path.is_file()
            }
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('already has an Incus database', log)
            self.assertNotIn('zpool create', recorded)
            self.assertNotIn('zfs create', recorded)
            self.assertNotIn('zfs set', recorded)
            self.assertNotIn('TAMA_STORAGE_ZFS_READY', log)
            self.assertEqual(before, after)
            self.assertFalse((metadata / '.tama-preseed-pending').exists())
            self.assertEqual((root / 'etc/tama-storage/phase').read_text().strip(), 'pool-created')

    def test_unexpected_mount_is_refused_before_import(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs-pool')
            self.owned_identity(root)
            mounts = root / 'proc-mounts'
            mounts.write_text(f'tmpfs {root / "metadata"} tmpfs rw 0 0\n')
            before = disk.read_bytes()
            result, calls = self.run_storage(
                root, disk, kind='zfs_member',
                extra_env={'TAMA_PROC_MOUNTS': str(mounts), 'TAMA_ZPOOL_IMPORT_OK': '1'})
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text() if calls.exists() else ''
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('unexpected filesystem mounted at metadata target: tmpfs', log)
            self.assertNotIn('zpool import', recorded)
            self.assertNotIn('zpool create', recorded)
            self.assertEqual(disk.read_bytes(), before)

    def test_pool_created_foreign_layout_is_not_rewritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root, phase='pool-created')
            metadata = root / 'metadata'
            (metadata / '.tama-storage-layout').write_text('foreign-layout-v2\n')
            (metadata / 'sentinel').write_text('keep\n')
            before = {path.relative_to(metadata).as_posix(): path.read_bytes()
                      for path in metadata.rglob('*') if path.is_file()}
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text()
            after = {path.relative_to(metadata).as_posix(): path.read_bytes()
                     for path in metadata.rglob('*') if path.is_file()}
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('foreign metadata layout', log)
            self.assertNotIn('zfs set', recorded)
            self.assertNotIn('zfs create', recorded)
            self.assertEqual(before, after)
            self.assertFalse((metadata / '.tama-preseed-pending').exists())

    def test_unknown_phase_is_not_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root, phase='unknown-version-or-interrupted-phase')
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('unknown or interrupted phase', (root / 'storage.log').read_text())
            self.assertNotIn('zpool online', calls.read_text() if calls.exists() else '')
            self.assertNotIn('TAMA_STORAGE_ZFS_READY', (root / 'storage.log').read_text())

    def test_label_alone_does_not_authorize_ext4_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'ext4')
            result, calls = self.run_storage(root, disk, kind='ext4', label='tama-incus-data')
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('ro,noload', recorded)
            self.assertNotIn('e2fsck', recorded)
            self.assertNotIn('resize2fs', recorded)
            self.assertNotIn('TAMA_STORAGE_EXT4_READY', log)

    def test_wrong_mounted_source_is_not_repaired(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'ext4')
            inspect = root / 'mnt/tama-inspect'
            inspect.mkdir(parents=True)
            (inspect / 'server.crt').write_text('cert')
            (root / 'metadata').mkdir()
            (root / 'metadata' / 'server.crt').write_text('cert')
            mounts = root / 'proc-mounts'
            mounts.write_text(f'/dev/wrong {root / "metadata"} ext4 rw 0 0\n')
            result, calls = self.run_storage(
                root, disk, kind='ext4', label='tama-incus-data',
                extra_env={'TAMA_MOUNTPOINT_PRESENT': '1', 'TAMA_PROC_MOUNTS': str(mounts)})
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('/dev/wrong', log)
            self.assertNotIn('e2fsck', calls.read_text())

    def test_recognized_ext4_layout_is_checked_before_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'ext4')
            inspect = root / 'mnt/tama-inspect'
            inspect.mkdir(parents=True)
            (inspect / 'database').mkdir()
            (inspect / 'server.crt').write_text('cert')
            (root / 'metadata' / 'database').mkdir(parents=True)
            (root / 'metadata' / 'server.crt').write_text('cert')
            result, calls = self.run_storage(root, disk, kind='ext4', label='tama-incus-data')
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text()
            self.assertEqual(result.returncode, 0, log)
            self.assertLess(recorded.index('ro,noload'), recorded.index('e2fsck'))
            self.assertIn('TAMA_STORAGE_EXT4_READY', log)
            self.assertNotIn('zpool create', recorded)

    def test_foreign_zfs_and_wrong_guid_are_not_adopted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('foreign ZFS', (root / 'storage.log').read_text())
            self.assertNotIn('zpool import', calls.read_text() if calls.exists() else '')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            (root / 'etc/tama-storage/pool-guid').write_text('999\n')
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('does not match', (root / 'storage.log').read_text())
            self.assertNotIn('zpool create', calls.read_text())
            self.assertNotIn('zpool import -f', calls.read_text())

    def test_expansion_failure_is_not_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            result, calls = self.run_storage(root, disk, kind='zfs_member',
                                             extra_env={'TAMA_ZPOOL_ONLINE_FAIL': '1'})
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('vdev expansion failed', log)
            self.assertNotIn('TAMA_STORAGE_ZFS_READY', log)
            self.assertIn('zpool online', calls.read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            result, _calls = self.run_storage(
                root, disk, kind='zfs_member', extra_env={'TAMA_ZPOOL_EXPANDSIZE': '33554432'})
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('still pending', log)
            self.assertNotIn('TAMA_STORAGE_ZFS_READY', log)

    def test_proc_mounts_source_is_used_when_findmnt_is_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            mounts = root / 'proc-mounts'
            mounts.write_text(f'other-dataset {root / "metadata"} zfs rw 0 0\n')
            result, _calls = self.run_storage(
                root, disk, kind='zfs_member',
                extra_env={'TAMA_MOUNTPOINT_PRESENT': '1', 'TAMA_PROC_MOUNTS': str(mounts)})
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('other-dataset', log)
            self.assertNotIn('TAMA_STORAGE_ZFS_READY', log)

    def test_owned_pool_imports_without_workload_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text()
            self.assertEqual(result.returncode, 0, log)
            self.assertIn('zpool online', recorded)
            self.assertNotIn('zpool create', recorded)
            self.assertNotIn('refreservation=268435456', recorded)
            self.assertIn('TAMA_STORAGE_ZFS_READY', log)

    def test_ready_requires_backend_profile_and_live_headroom(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            result, _calls = self.run_storage(root, disk, action='ready')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('missing or unknown', (root / 'storage.log').read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root, phase='preseed-pending')
            result, calls = self.run_storage(root, disk, action='ready')
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('phase is not ready', log)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            result, calls = self.run_storage(root, disk, action='ready')
            log = (root / 'storage.log').read_text()
            self.assertEqual(result.returncode, 0, log)
            self.assertIn('TAMA_STORAGE_DRIVER_OK', log)
            self.assertIn('incus query /1.0/profiles/default', calls.read_text())

    # Adoption: a replacement root with no identity and a host-delivered record.

    def adoptable(self, root, guid='120', layout='zfs-v1', database=True):
        identity = root / 'etc/tama-storage'
        identity.mkdir(parents=True)
        (identity / 'adopt').write_text(f'pool_guid={guid}\nlayout={layout}\n')
        metadata = root / 'metadata'
        metadata.mkdir(parents=True, exist_ok=True)
        (metadata / '.tama-storage-layout').write_text('zfs-v1\n')
        if database:
            (metadata / 'database').mkdir()
            (metadata / 'database' / 'global').write_bytes(b'db')
        disk = root / 'disk'
        disk.write_bytes(b'zfs')
        return disk

    def adopt(self, root, disk, kind='zfs_member', imported=False, extra_env=None):
        env = {'TAMA_ZPOOL_IMPORT_OK': '1'}
        if not imported:
            env['TAMA_ZPOOL_IMPORTED'] = str(root / 'imported')
        env.update(extra_env or {})
        result, calls = self.run_storage(root, disk, kind=kind, extra_env=env)
        log = (root / 'storage.log').read_text()
        recorded = calls.read_text() if calls.exists() else ''
        return result, log, recorded

    def metadata_files(self, root):
        metadata = root / 'metadata'
        return {path.relative_to(metadata).as_posix(): path.read_bytes()
                for path in metadata.rglob('*') if path.is_file()}

    def assert_adoption_refused(self, root, result, log, recorded, reason):
        identity = root / 'etc/tama-storage'
        self.assertNotEqual(result.returncode, 0, log)
        self.assertIn('TAMA_STORAGE_REFUSED: adoption:', log)
        self.assertIn(reason, log)
        self.assertNotIn('TAMA_STORAGE_ADOPTED', log)
        self.assertNotIn('TAMA_STORAGE_ZFS_READY', log)
        self.assertEqual((root / 'run/tama-storage-failure').read_text().strip(), 'storage_adoption_refused')
        for name in ('pool-guid', 'layout', 'phase'):
            self.assertFalse((identity / name).exists(), name)
        self.assertTrue((identity / 'adopt').is_file())
        self.assertFalse((root / 'run/tama-storage-backend').exists())
        for forbidden in ('zpool create', 'zpool import -f', 'zpool online', 'zfs create', 'zfs set', 'mkfs.ext4'):
            self.assertNotIn(forbidden, recorded)
        self.assertFalse((root / 'metadata/.tama-preseed-pending').exists())

    def test_adoption_records_named_pool_and_runs_owned_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = self.adoptable(root)
            before = self.metadata_files(root)
            result, log, recorded = self.adopt(root, disk)
            identity = root / 'etc/tama-storage'
            self.assertEqual(result.returncode, 0, log)
            imports = [line for line in recorded.splitlines() if line.startswith('zpool import')]
            self.assertEqual(imports, [f'zpool import -N -d {disk} 120'])
            self.assertEqual((identity / 'pool-guid').read_text().strip(), '120')
            self.assertEqual((identity / 'layout').read_text().strip(), 'zfs-v1')
            self.assertEqual((identity / 'phase').read_text().strip(), 'ready')
            self.assertFalse((identity / 'adopt').exists())
            self.assertLess(log.index('TAMA_STORAGE_ADOPTED 120'), log.index('TAMA_STORAGE_ZFS_READY 120'))
            self.assertIn(f'zpool online -e tama-data {disk}', recorded)
            self.assertEqual((root / 'run/tama-storage-backend').read_text().strip(), 'zfs')
            self.assertFalse((root / 'run/tama-storage-failure').exists())
            self.assertNotIn('zpool create', recorded)
            self.assertNotIn('zfs create', recorded)
            self.assertNotIn('zfs set', recorded)
            self.assertNotIn('zpool export', recorded)
            self.assertEqual(self.metadata_files(root), before)
            self.assertFalse((root / 'metadata/.tama-preseed-pending').exists())

    def test_adoption_accepts_named_pool_already_imported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = self.adoptable(root)
            result, log, recorded = self.adopt(root, disk, imported=True)
            self.assertEqual(result.returncode, 0, log)
            self.assertNotIn('zpool import', recorded)
            self.assertIn('TAMA_STORAGE_ZFS_READY 120', log)

    def test_adoption_refuses_guid_mismatch(self):
        # The disk holds no pool with the named GUID: nothing is imported.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = self.adoptable(root, guid='999')
            result, log, recorded = self.adopt(root, disk, extra_env={'TAMA_ZPOOL_IMPORT_OK': '0'})
            self.assert_adoption_refused(root, result, log, recorded, 'named pool 999 cannot be imported')
            self.assertIn(f'zpool import -N -d {disk} 999', recorded)
            self.assertNotIn('zfs mount', recorded)
        # An import that yields another GUID is exported again.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = self.adoptable(root, guid='999')
            result, log, recorded = self.adopt(root, disk)
            self.assert_adoption_refused(root, result, log, recorded, 'pool GUID 120 is not the named 999')
            self.assertIn('zpool export tama-data', recorded)
            self.assertFalse((root / 'imported').exists())
        # Another pool already imported under the name is not ours to export.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = self.adoptable(root, guid='999')
            result, log, recorded = self.adopt(root, disk, imported=True)
            self.assert_adoption_refused(root, result, log, recorded, 'not exporting it')
            self.assertNotIn('zpool import', recorded)
            self.assertNotIn('zpool export', recorded)

    def test_adoption_refuses_pool_on_another_vdev(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = self.adoptable(root)
            result, log, recorded = self.adopt(
                root, disk, extra_env={'TAMA_ZPOOL_STATUS_DISK': '/dev/vdz'})
            self.assert_adoption_refused(root, result, log, recorded, 'not backed by the attached data disk')
            self.assertIn('zpool export tama-data', recorded)

    def test_adoption_refuses_foreign_or_missing_layout(self):
        for marker in ('foreign-layout-v2\n', None):
            with self.subTest(marker=marker), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                disk = self.adoptable(root)
                layout_marker = root / 'metadata/.tama-storage-layout'
                if marker is None:
                    layout_marker.unlink()
                else:
                    layout_marker.write_text(marker)
                before = self.metadata_files(root)
                result, log, recorded = self.adopt(root, disk)
                self.assert_adoption_refused(root, result, log, recorded, 'not zfs-v1')
                self.assertIn('zpool export tama-data', recorded)
                self.assertEqual(self.metadata_files(root), before)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = self.adoptable(root)
            result, log, recorded = self.adopt(root, disk, extra_env={'TAMA_ZFS_NO_METADATA': '1'})
            self.assert_adoption_refused(root, result, log, recorded, 'has no metadata dataset')

    def test_adoption_refuses_uninitialized_pool(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = self.adoptable(root, database=False)
            result, log, recorded = self.adopt(root, disk)
            self.assert_adoption_refused(root, result, log, recorded, 'no Incus database')
            self.assertIn('zpool export tama-data', recorded)
        for marker, reason in (('.tama-preseed-pending', 'still pending'),
                               ('.tama-preseed-started', 'was interrupted')):
            with self.subTest(marker=marker), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                disk = self.adoptable(root)
                (root / 'metadata' / marker).write_text('')
                result, log, recorded = self.adopt(root, disk)
                self.assertNotEqual(result.returncode, 0, log)
                self.assertIn(reason, log)
                self.assertEqual((root / 'run/tama-storage-failure').read_text().strip(), 'storage_adoption_refused')
                self.assertFalse((root / 'etc/tama-storage/phase').exists())
                self.assertTrue((root / 'metadata' / marker).exists())
                self.assertIn('zpool export tama-data', recorded)

    def test_adoption_refuses_invalid_record_before_touching_the_disk(self):
        for guid, layout, reason in (('', 'zfs-v1', 'no valid pool GUID'),
                                     ('12x', 'zfs-v1', 'no valid pool GUID'),
                                     ('120', 'zfs-v2', 'unknown layout zfs-v2'),
                                     ('120', '', 'unknown layout absent')):
            with self.subTest(guid=guid, layout=layout), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                disk = self.adoptable(root, guid=guid, layout=layout)
                result, log, recorded = self.adopt(root, disk)
                self.assert_adoption_refused(root, result, log, recorded, reason)
                self.assertNotIn('zpool', recorded)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = self.adoptable(root)
            result, log, recorded = self.adopt(root, disk, extra_env={'TAMA_MODPROBE_FAIL': 'zfs'})
            self.assert_adoption_refused(root, result, log, recorded, 'ZFS module is unavailable')
            self.assertNotIn('zpool', recorded)

    def test_adoption_never_creates_or_converts_storage(self):
        # A blank disk or an ext4 disk with a record is refused, never formatted or repaired.
        for kind in ('', 'ext4'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                disk = self.adoptable(root)
                disk.write_bytes(b'\0' * 64)
                os.truncate(disk, 4 * 1024 ** 3)
                result, log, recorded = self.adopt(root, disk, kind=kind, extra_env={'TAMA_ZPOOL_IMPORT_OK': '0'})
                self.assert_adoption_refused(root, result, log, recorded, 'cannot be imported')
                for forbidden in ('e2fsck', 'resize2fs', 'mount -o'):
                    self.assertNotIn(forbidden, recorded)

    def test_root_identity_ignores_stale_adoption_record(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            (root / 'etc/tama-storage/adopt').write_text('pool_guid=999\nlayout=zfs-v1\n')
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            log = (root / 'storage.log').read_text()
            self.assertEqual(result.returncode, 0, log)
            self.assertIn('TAMA_STORAGE_ADOPT_IGNORED', log)
            self.assertIn('TAMA_STORAGE_ZFS_READY 120', log)
            self.assertNotIn('TAMA_STORAGE_ADOPTED', log)
            self.assertNotIn(' 999', calls.read_text())
            self.assertEqual((root / 'etc/tama-storage/pool-guid').read_text().strip(), '120')

    def test_failure_observation_is_cleared_on_the_next_start(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            (root / 'run/tama-storage-failure').write_text('storage_adoption_refused\n')
            result, _calls = self.run_storage(root, disk, kind='zfs_member')
            self.assertEqual(result.returncode, 0, (root / 'storage.log').read_text())
            self.assertFalse((root / 'run/tama-storage-failure').exists())

    def test_fresh_root_without_record_still_refuses_zfs_member(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            (root / 'metadata').mkdir()
            (root / 'metadata/database').mkdir()
            result, calls = self.run_storage(root, disk, kind='zfs_member', extra_env={'TAMA_ZPOOL_IMPORT_OK': '1'})
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('foreign ZFS member has no owned identity', log)
            self.assertNotIn('zpool import', calls.read_text() if calls.exists() else '')
            self.assertFalse((root / 'run/tama-storage-failure').exists())
