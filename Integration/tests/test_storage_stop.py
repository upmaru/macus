"""Storage stop exports the pool, releasing only what a dead incusd left behind."""
import os
from pathlib import Path
import tempfile
import unittest

import test_storage_classification as classification

write_stub = classification.write_stub

KILL = '''#!/bin/sh
signal=$1
shift
for pid in "$@"; do
    printf 'kill %s %s\\n' "$signal" "$pid" >> "$FIXTURE/calls"
    if [ "$signal" = -KILL ] || [ ! -e "$FIXTURE/proc/$pid/ignore-term" ]; then
        rm -rf "$FIXTURE/proc/$pid"
    fi
done
'''


class StorageStopTests(unittest.TestCase):
    run_storage = classification.StorageClassificationTests.run_storage
    owned_identity = classification.StorageClassificationTests.owned_identity

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.disk = self.root / 'disk'
        self.disk.write_bytes(b'zfs')
        self.owned_identity(self.root)
        self.metadata = self.root / 'metadata'
        (self.root / 'proc').mkdir()
        (self.root / 'bin').mkdir()
        write_stub(self.root / 'bin', 'sleep', 'exit 0\n')
        self.kill = self.root / 'kill'
        self.kill.write_text(KILL)
        self.kill.chmod(0o755)
        self.mounts = self.root / 'mounts'
        self.mounts.write_text(
            f'tama-data/metadata {self.metadata} zfs rw 0 0\n'
            f'tmpfs {self.metadata}/devices tmpfs rw 0 0\n'
            f'tmpfs {self.metadata}/shmounts tmpfs rw 0 0\n'
            f'tmpfs {self.metadata}/guestapi tmpfs rw 0 0\n'
            f'tmpfs /run tmpfs rw 0 0\n'
            f'tama-data/workloads/containers/c1 {self.metadata}/storage-pools/default/containers/c1 zfs rw 0 0\n')
        self.export_fails = self.root / 'export-fails'

    def tearDown(self):
        self.directory.cleanup()

    def process(self, pid, cmdline, exe='/usr/bin/true', cwd='/', fds=()):
        entry = self.root / 'proc' / str(pid)
        (entry / 'fd').mkdir(parents=True)
        (entry / 'cmdline').write_bytes(cmdline.replace(' ', '\0').encode() + b'\0')
        os.symlink(exe, entry / 'exe')
        os.symlink(cwd, entry / 'cwd')
        os.symlink('/', entry / 'root')
        for number, target in enumerate(fds):
            os.symlink(target, entry / 'fd' / str(number + 3))
        return entry

    def stop(self, export_failures, incusd_status='3'):
        self.export_fails.write_text(f'{export_failures}\n')
        result, calls = self.run_storage(self.root, self.disk, action='stop', extra_env={
            'TAMA_PROC': str(self.root / 'proc'),
            'TAMA_PROC_MOUNTS': str(self.mounts),
            'TAMA_KILL': str(self.kill),
            'TAMA_EXPORT_FAILS_FILE': str(self.export_fails),
            'TAMA_INCUSD_STATUS': incusd_status,
            'FIXTURE': str(self.root),
        })
        log = (self.root / 'storage.log').read_text()
        recorded = calls.read_text() if calls.exists() else ''
        return result, log, recorded

    def test_clean_export_releases_nothing(self):
        self.process(3267, 'dnsmasq --interface=incusbr0',
                     fds=[f'{self.metadata}/networks/incusbr0/dnsmasq.leases'])
        result, log, recorded = self.stop(0)
        self.assertEqual(result.returncode, 0, log)
        self.assertIn('TAMA_ZFS_EXPORT_OK', log)
        self.assertNotIn('rc-service', recorded)
        self.assertNotIn('kill', recorded)
        self.assertNotIn('umount', recorded)
        self.assertTrue((self.root / 'proc/3267').exists())

    def test_dead_incusd_leftovers_are_released_then_exported(self):
        self.process(3267, 'dnsmasq --interface=incusbr0', exe='/usr/sbin/dnsmasq',
                     fds=['/dev/null', f'{self.metadata}/networks/incusbr0/dnsmasq.leases'])
        self.process(4000, 'chronyd', fds=['/var/lib/chrony/drift'])
        self.process(4100, 'sh', cwd=f'{self.metadata}/containers')
        result, log, recorded = self.stop(1)
        self.assertEqual(result.returncode, 0, log)
        self.assertIn('TAMA_STORAGE_RELEASING_DEAD_INCUS', log)
        self.assertIn('TAMA_STORAGE_HOLDER 3267 dnsmasq --interface=incusbr0', log)
        self.assertIn('kill -TERM 3267', recorded)
        self.assertIn('kill -TERM 4100', recorded)
        self.assertNotIn('4000', recorded)
        self.assertTrue((self.root / 'proc/4000').exists())
        self.assertNotIn('-KILL', recorded)
        # Only incusd's tmpfs mounts, deepest first; never datasets or /run.
        umounts = [line for line in recorded.splitlines() if line.startswith('umount')]
        self.assertEqual(umounts, [f'umount {self.metadata}/{name}'
                                   for name in ('shmounts', 'guestapi', 'devices')])
        self.assertLess(recorded.index('kill -TERM'), recorded.index('umount'))
        self.assertEqual(recorded.count('zpool export'), 2)
        self.assertIn('TAMA_ZFS_EXPORT_OK', log)
        self.assertNotIn('zfs destroy', recorded)
        self.assertNotIn('zfs unmount', recorded)

    def test_holder_that_ignores_term_is_killed(self):
        entry = self.process(3267, 'dnsmasq', fds=[f'{self.metadata}/networks/x'])
        (entry / 'ignore-term').write_text('')
        result, log, recorded = self.stop(1)
        self.assertEqual(result.returncode, 0, log)
        self.assertIn('kill -TERM 3267', recorded)
        self.assertIn('kill -KILL 3267', recorded)
        self.assertIn('TAMA_STORAGE_HOLDER_KILL 3267', log)

    def test_live_incusd_is_never_released(self):
        self.process(3267, 'dnsmasq', fds=[f'{self.metadata}/networks/x'])
        result, log, recorded = self.stop(1, incusd_status='0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('TAMA_STORAGE_INCUS_ALIVE', log)
        self.assertIn('TAMA_ZFS_EXPORT_FAILED', log)
        self.assertNotIn('kill', recorded)
        self.assertNotIn('umount', recorded)
        self.assertEqual(recorded.count('zpool export'), 1)

    def test_zapped_service_with_live_daemon_pidfile_is_alive(self):
        self.process(900, 'incusd --group incus', exe='/usr/sbin/incusd')
        (self.root / 'run/incus').mkdir(parents=True)
        (self.root / 'run/incus/incusd.pid').write_text('900\n')
        self.process(3267, 'dnsmasq', fds=[f'{self.metadata}/networks/x'])
        result, log, recorded = self.stop(1, incusd_status='3')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('TAMA_STORAGE_INCUS_ALIVE', log)
        self.assertNotIn('kill', recorded)

    def test_stale_pidfile_does_not_count_as_alive(self):
        (self.root / 'run/incus').mkdir(parents=True)
        (self.root / 'run/incus/incusd.pid').write_text('900\n')
        self.process(900, 'dnsmasq', exe='/usr/sbin/dnsmasq', fds=[f'{self.metadata}/x'])
        result, log, recorded = self.stop(1, incusd_status='32')
        self.assertEqual(result.returncode, 0, log)
        self.assertIn('kill -TERM 900', recorded)

    def test_export_still_busy_reports_holders_and_fails(self):
        self.process(3267, 'dnsmasq', fds=[f'{self.metadata}/networks/x'])
        result, log, recorded = self.stop(2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('TAMA_STORAGE_RELEASING_DEAD_INCUS', log)
        self.assertIn('TAMA_ZFS_EXPORT_FAILED', log)
        self.assertEqual(recorded.count('zpool export'), 2)


if __name__ == '__main__':
    unittest.main()
