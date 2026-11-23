"""Bounded incusd boot recovery and crash evidence in tama-incus-guard."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

GUARD = Path(__file__).resolve().parents[1] / 'guest/incus-guard.sh'
OBSERVATION = 'MACUS_OBSERVATION '

# OpenRC status exit codes: 0 started, 32 crashed, 3 stopped.
RC_SERVICE = '''#!/bin/sh
printf 'rc-service %s\\n' "$*" >> "$FIXTURE/calls"
[ "$1" = incusd ] || exit 0
state=$(cat "$FIXTURE/svc")
case $2 in
    status)
        case $state in
            started-*) echo started; exit 0 ;;
            crashed) echo crashed; exit 32 ;;
            *) echo stopped; exit 3 ;;
        esac ;;
    zap) echo stopped > "$FIXTURE/svc" ;;
    start)
        outcome=$(sed -n 1p "$FIXTURE/launches" 2>/dev/null)
        sed -i.bak 1d "$FIXTURE/launches" 2>/dev/null || true
        case ${outcome:-ok} in
            ok) echo started-ready > "$FIXTURE/svc" ;;
            notready) echo started-notready > "$FIXTURE/svc" ;;
            crash) echo crashed > "$FIXTURE/svc" ;;
            fail) echo stopped > "$FIXTURE/svc"; exit 1 ;;
        esac ;;
esac
'''

INCUSD = '''#!/bin/sh
printf 'incusd %s\\n' "$*" >> "$FIXTURE/calls"
[ "$1" = waitready ] && [ "$(cat "$FIXTURE/svc")" = started-ready ]
'''

READY = '''#!/bin/sh
printf 'ready %s\\n' "$*" >> "$FIXTURE/calls"
outcome=$(sed -n 1p "$FIXTURE/ready_results" 2>/dev/null)
sed -i.bak 1d "$FIXTURE/ready_results" 2>/dev/null || true
case ${outcome:-ok} in
    ok) exit 0 ;;
    crash) echo crashed > "$FIXTURE/svc"; exit 1 ;;
    *) exit 3 ;;
esac
'''


def write_exec(path, body):
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


class IncusGuardTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        write_exec(bin_dir / 'rc-service', RC_SERVICE)
        write_exec(bin_dir / 'incusd', INCUSD)
        write_exec(bin_dir / 'sleep', '#!/bin/sh\nexit 0\n')
        write_exec(self.root / 'ready', READY)
        (self.root / 'var/log/incus').mkdir(parents=True)
        (self.root / 'run').mkdir()
        (self.root / 'console').write_text('')
        (self.root / 'calls').write_text('')
        self.env = dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', FIXTURE=str(self.root),
                        TAMA_BOOT_ROOT=str(self.root), TAMA_CONSOLE=str(self.root / 'console'))

    def tearDown(self):
        self.directory.cleanup()

    def given(self, state, launches=(), ready=()):
        (self.root / 'svc').write_text(state + '\n')
        (self.root / 'launches').write_text(''.join(line + '\n' for line in launches))
        (self.root / 'ready_results').write_text(''.join(line + '\n' for line in ready))

    def run_guard(self, *readiness, **env):
        args = ['sh', str(GUARD), 'ensure']
        if readiness:
            args += [str(self.root / 'ready'), *readiness]
        return subprocess.run(args, env=dict(self.env, **env), text=True, capture_output=True,
                              timeout=30)

    def console(self):
        return (self.root / 'console').read_text()

    def calls(self):
        return (self.root / 'calls').read_text().splitlines()

    def observations(self):
        # Parse the way the host does: trimmed lines starting with the marker.
        return [line.strip() for line in self.console().splitlines()
                if line.strip().startswith(OBSERVATION)]

    def starts(self):
        return self.calls().count('rc-service incusd start')

    def test_ready_daemon_passes_without_restart(self):
        self.given('started-ready')
        result = self.run_guard('ready')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.observations(), ['MACUS_OBSERVATION v1 stage=incus'])
        self.assertEqual(self.starts(), 0)
        self.assertIn('ready ready', self.calls())
        self.assertNotIn('TAMA_INCUSD', self.console())

    def test_stopped_daemon_is_started_once_without_counting(self):
        self.given('stopped', ['ok'])
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.starts(), 1)
        self.assertNotIn('TAMA_INCUSD', self.console())
        self.assertFalse((self.root / 'run/tama-incus-guard/restarts').exists())

    def test_single_crash_is_restarted_with_evidence(self):
        self.given('crashed', ['ok'])
        (self.root / 'var/log/incus/incusd.log').write_text(
            'time="x" level=info msg="Starting up"\nMACUS_OBSERVATION v1 stage=ready\n')
        (self.root / 'var/log/incus/incusd.err').write_text(
            'panic: runtime error: invalid memory address\n' + 'x' * 1000 + '\n')
        result = self.run_guard('ready')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertLess(calls.index('rc-service incusd zap'), calls.index('rc-service incusd start'))
        self.assertEqual(self.starts(), 1)
        console = self.console()
        self.assertIn('TAMA_INCUSD_CRASHED state=crashed restart=1/2', console)
        self.assertIn('incusd| panic: runtime error: invalid memory address', console)
        self.assertIn('incusd| time="x" level=info msg="Starting up"', console)
        self.assertIn('TAMA_INCUSD_RECOVERED restarts=1', console)
        self.assertLess(console.index('panic: runtime'), console.index('TAMA_INCUSD_RECOVERED'))
        # Copied log text never parses as an observation, and lines are bounded.
        self.assertEqual(self.observations(), [
            'MACUS_OBSERVATION v1 stage=incus',
            'MACUS_OBSERVATION v1 stage=incus state=restarting',
        ])
        self.assertTrue(all(len(line) <= 410 for line in console.splitlines()))
        self.assertIn('TAMA_INCUSD_CRASHED', (self.root / 'var/log/tama-incus-guard.log').read_text())

    def test_long_crash_dump_keeps_its_header(self):
        self.given('crashed', ['ok'])
        older = 'panic: older crash\n' + 'old frame\n' * 5
        dump = 'SIGABRT: abort\nPC=0x1 m=0 sigcode=0\n\ngoroutine 1 gp=0x1 m=0 [running]:\n'
        dump += ''.join(f'frame {i}\n' for i in range(200)) + 'pc      0x2\n'
        (self.root / 'var/log/incus/incusd.err').write_text(older + dump)
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        console = self.console()
        self.assertIn('(last crash, first 30 lines) ---', console)
        self.assertIn('incusd| SIGABRT: abort', console)
        self.assertIn('incusd| goroutine 1 gp=0x1 m=0 [running]:', console)
        self.assertNotIn('older crash', console)
        # The tail still ends the block.
        self.assertIn('incusd| pc      0x2', console)
        self.assertLess(console.index('SIGABRT: abort'), console.index('incusd| pc      0x2'))
        self.assertTrue(all(not line.strip().startswith(OBSERVATION) or 'stage=incus' in line
                            for line in console.splitlines()))

    def test_persistent_crash_is_bounded_and_reported(self):
        self.given('crashed', ['crash', 'crash', 'crash'])
        result = self.run_guard('ready')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.starts(), 2)
        self.assertNotIn('ready ready', self.calls())
        self.assertEqual(self.observations()[-1], 'MACUS_OBSERVATION v1 stage=failed code=incus_crashed')
        self.assertEqual(self.console().count('TAMA_INCUSD_CRASHED'), 3)
        self.assertIn('restart=exhausted/2', self.console())
        self.assertTrue((self.root / 'run/tama-incus-guard/failed').exists())
        # The dead daemon is left stopped so shutdown can stop and export storage.
        self.assertEqual(self.calls().count('rc-service incusd zap'), 3)
        self.assertEqual([c for c in self.calls() if c.startswith('rc-service')][-1],
                         'rc-service incusd zap')
        self.assertEqual((self.root / 'svc').read_text().strip(), 'stopped')
        # A later step on the same boot does not restart again.
        again = self.run_guard('ready')
        self.assertEqual(again.returncode, 1)
        self.assertEqual(self.starts(), 2)
        self.assertEqual(self.observations()[-1], 'MACUS_OBSERVATION v1 stage=failed code=incus_crashed')

    def test_restart_count_is_shared_across_steps_of_one_boot(self):
        self.given('crashed', ['ok'])
        self.assertEqual(self.run_guard().returncode, 0)
        self.given('crashed', ['crash', 'ok'])
        result = self.run_guard('ready')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.starts(), 2)
        self.assertIn('code=incus_crashed', self.console())

    def test_running_but_unready_daemon_is_not_restarted(self):
        self.given('started-notready')
        result = self.run_guard('ready', TAMA_INCUS_READY_TIMEOUT='0')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.starts(), 0)
        self.assertNotIn('rc-service incusd zap', self.calls())
        self.assertEqual(self.observations()[-1], 'MACUS_OBSERVATION v1 stage=failed code=incus_not_ready')
        self.assertEqual(
            (self.root / 'run/tama-incus-guard/failed').read_text().strip(), 'incus_not_ready')
        # A later step on the same boot replays the original reason, not a crash.
        again = self.run_guard('ready', TAMA_INCUS_READY_TIMEOUT='0')
        self.assertEqual(again.returncode, 1)
        self.assertEqual(self.starts(), 0)
        self.assertEqual(self.observations()[-1], 'MACUS_OBSERVATION v1 stage=failed code=incus_not_ready')
        self.assertNotIn('code=incus_crashed', self.console())

    def test_readiness_failure_while_running_is_returned(self):
        self.given('started-ready', ready=['fail'])
        result = self.run_guard('ready')
        self.assertEqual(result.returncode, 3)
        self.assertEqual(self.starts(), 0)
        self.assertIn('TAMA_INCUSD_READINESS_CHECK_FAILED status=3', self.console())
        self.assertFalse(any('stage=failed' in line for line in self.observations()))

    def test_crash_found_by_readiness_check_is_restarted(self):
        self.given('started-ready', ['ok'], ready=['crash', 'ok'])
        result = self.run_guard('ready')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.starts(), 1)
        self.assertEqual(self.calls().count('ready ready'), 2)
        self.assertIn('TAMA_INCUSD_RECOVERED restarts=1', self.console())

    def test_failed_launch_counts_as_a_crash_after_the_first_start(self):
        self.given('stopped', ['fail', 'ok'])
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.starts(), 2)
        self.assertIn('TAMA_INCUSD_CRASHED state=stopped restart=1/2', self.console())
        self.assertNotIn('rc-service incusd zap', self.calls())

    def test_unwritable_console_falls_back_to_stderr(self):
        self.given('crashed', ['crash', 'crash'])
        result = self.run_guard(TAMA_CONSOLE=str(self.root / 'missing/console'))
        self.assertEqual(result.returncode, 1)
        self.assertIn('MACUS_OBSERVATION v1 stage=failed code=incus_crashed', result.stderr)

    def test_bridge_start_uses_guard_with_storage_readiness(self):
        initd = (GUARD.parent / 'tama-bridge.initd').read_text()
        self.assertIn(
            '/usr/local/libexec/tama-incus-guard.sh ensure /usr/local/libexec/tama-storage.sh ready',
            initd)
        self.assertNotIn('waitready', initd)


if __name__ == '__main__':
    unittest.main()
