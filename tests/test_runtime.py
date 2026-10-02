"""Test del controller incorporato nell'updater, senza accedere a dischi reali."""
import ast
from contextlib import nullcontext
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
if (ROOT / '.test-deps').exists():
    sys.path.insert(0, str(ROOT / '.test-deps'))
if sys.platform == 'win32':
    sys.modules['fcntl'] = types.SimpleNamespace(LOCK_EX=1, LOCK_NB=2, LOCK_UN=8, flock=lambda *args: None)

SCRIPT = (ROOT / 'update-veraprox.sh').read_text(encoding='utf-8')
SOURCE = SCRIPT.split("<<'RUNTIMEPY'\n", 1)[1].split('\nRUNTIMEPY\n', 1)[0]
runtime = types.ModuleType('veraprox_runtime_test')
exec(compile(SOURCE, 'runtime.py', 'exec'), runtime.__dict__)


def completed(stdout='', returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout, '')


class DeviceTests(unittest.TestCase):
    def test_excludes_system_disk_siblings_plain_filesystems_and_parent_disks(self):
        entries = [
            {'name': '/dev/sda', 'type': 'disk', 'pkname': None},
            {'name': '/dev/sda1', 'type': 'part', 'pkname': '/dev/sda', 'mountpoints': ['/']},
            {'name': '/dev/sda2', 'type': 'part', 'pkname': '/dev/sda'},
            {'name': '/dev/sdb', 'type': 'disk', 'pkname': None, 'model': 'USB drive', 'serial': '123'},
            {'name': '/dev/sdb1', 'type': 'part', 'pkname': '/dev/sdb', 'size': 1024**3},
            {'name': '/dev/sdb2', 'type': 'part', 'pkname': '/dev/sdb', 'fstype': 'ext4'},
            {'name': '/dev/sdc', 'type': 'disk', 'pkname': None, 'mountpoints': ['[SWAP]']},
        ]
        with patch.object(runtime, 'block_devices', return_value=entries), \
             patch.object(runtime, 'stable_path', side_effect=lambda entry, _: '/dev/disk/by-id/' + Path(entry['name']).name):
            result = runtime.candidates()
        self.assertEqual([entry['name'] for entry in result], ['/dev/sdb1'])
        self.assertEqual(result[0]['serial'], '123')

    def test_duplicate_partuuid_is_rejected(self):
        entries = [{'name': '/dev/sdb1', 'partuuid': 'duplicate'}, {'name': '/dev/sdc1', 'partuuid': 'duplicate'}]
        with self.assertRaises(runtime.VolumeError):
            runtime.stable_path(entries[0], entries)

    def test_missing_selected_device_never_falls_back(self):
        with patch.object(runtime.os.path, 'exists', return_value=False), self.assertRaises(runtime.VolumeError):
            runtime.resolve_device('/dev/disk/by-partuuid/missing')

    def test_raw_path_in_config_is_rejected(self):
        with patch.object(runtime, 'protected_read', return_value='[volume]\ndevice=/dev/sdb1\nmountpoint=/mnt/secure\n'), \
             patch.object(runtime.Path, 'exists', return_value=True), self.assertRaises(runtime.VolumeError):
            runtime.load_device()

    def test_changing_device_while_mounted_is_rejected(self):
        with patch.object(runtime, 'operation_lock', return_value=nullcontext()), \
             patch.object(runtime.os.path, 'ismount', return_value=True), \
             patch.object(runtime, 'atomic_write') as save, self.assertRaises(runtime.VolumeError):
            runtime.set_device('/dev/disk/by-id/another')
        save.assert_not_called()

    def test_stale_or_forged_device_selection_is_rejected(self):
        with patch.object(runtime, 'operation_lock', return_value=nullcontext()), \
             patch.object(runtime.os.path, 'ismount', return_value=False), \
             patch.object(runtime, 'candidates', return_value=[]), self.assertRaises(runtime.VolumeError):
            runtime.set_device('/dev/disk/by-id/forged')

    def test_mounted_volume_must_match_selected_device(self):
        with patch.object(runtime, 'load_device', return_value='/dev/disk/by-id/selected'), \
             patch.object(runtime, 'resolve_device', return_value='/dev/sdb1'), \
             patch.object(runtime, 'mounted_device', return_value='/dev/sdc1'), self.assertRaises(runtime.VolumeError):
            runtime.check_mounted()

    def test_parses_veracrypt_table(self):
        with patch.object(runtime.os.path, 'ismount', return_value=True), \
             patch.object(runtime.os.path, 'realpath', side_effect=lambda value: value), \
             patch.object(runtime, 'command', return_value=completed('1: /dev/sdb1 /dev/mapper/veracrypt1 /mnt/secure\n')):
            self.assertEqual(runtime.mounted_device(), '/dev/sdb1')


class LifecycleTests(unittest.TestCase):
    def test_slow_filebrowser_reports_pending_instead_of_failure(self):
        with patch.object(runtime, 'filebrowser_installed', return_value=True), \
             patch.object(runtime.Path, 'exists', return_value=True), \
             patch.object(runtime, 'prepare_quantum'), \
             patch.object(runtime, 'filebrowser_status', return_value='starting'), \
             patch.object(runtime, 'command') as run:
            self.assertFalse(runtime.start_filebrowser())
        run.assert_called_once_with(['systemctl', 'start', runtime.FILEBROWSER_SERVICE])
        with patch.object(runtime, 'operation_lock', return_value=nullcontext()), \
             patch.object(runtime, 'load_device'), patch.object(runtime.os.path, 'ismount', return_value=True), \
             patch.object(runtime, 'check_mounted'), patch.object(runtime, 'command', return_value=completed('rw')), \
             patch.object(runtime, 'start_filebrowser', return_value=False), patch.object(runtime, 'start_immich'):
            self.assertIn('FileBrowser in avvio', runtime.mount_volume('password'))

    def test_filebrowser_status_checks_http_and_detects_real_failure(self):
        with patch.object(runtime, 'filebrowser_installed', return_value=True), \
             patch.object(runtime.os.path, 'ismount', return_value=True), \
             patch.object(runtime.Path, 'exists', return_value=True), \
             patch.object(runtime, 'command', return_value=completed('active\n')) as run, \
             patch('urllib.request.build_opener') as opener:
            opener.return_value.open.side_effect = OSError('Still starting')
            self.assertEqual(runtime.filebrowser_status(), 'starting')
            opener.return_value.open.side_effect = None
            opener.return_value.open.return_value.__enter__.return_value.status = 200
            self.assertEqual(runtime.filebrowser_status(), 'ready')
            run.return_value = completed('failed\n')
            self.assertEqual(runtime.filebrowser_status(), 'failed')

    def test_password_sent_on_stdin_without_shell_or_argument(self):
        password = "p'ass; $(touch /tmp/never) & spaces"
        calls = []
        def fake_command(args, **kwargs):
            calls.append((args, kwargs))
            return completed('rw,relatime' if args[0] == 'findmnt' else '')
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(runtime, 'MOUNTPOINT', directory), \
             patch.object(runtime, 'operation_lock', return_value=nullcontext()), \
             patch.object(runtime, 'load_device', return_value='/dev/disk/by-id/selected'), \
             patch.object(runtime.os.path, 'ismount', return_value=False), \
             patch.object(runtime, 'assert_available'), patch.object(runtime, 'check_mounted'), \
             patch.object(runtime, 'start_filebrowser'), patch.object(runtime, 'start_immich'), \
             patch.object(runtime, 'command', side_effect=fake_command):
            runtime.mount_volume(password)
        args, kwargs = calls[0]
        self.assertIn('--stdin', args)
        self.assertNotIn(password, args)
        self.assertFalse(any(arg.startswith('--password') for arg in args))
        self.assertEqual(kwargs['input_text'], password + '\n')
        tree = ast.parse(SOURCE)
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                self.assertFalse(any(keyword.arg == 'shell' and isinstance(keyword.value, ast.Constant)
                                     and keyword.value.value is True for keyword in node.keywords))

    def test_nonempty_unmounted_mountpoint_is_not_hidden(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'existing.txt').write_text('existing data')
            with patch.object(runtime, 'MOUNTPOINT', directory), \
                 patch.object(runtime, 'operation_lock', return_value=nullcontext()), \
                 patch.object(runtime, 'load_device', return_value='/dev/disk/by-id/selected'), \
                 patch.object(runtime.os.path, 'ismount', return_value=False), \
                 patch.object(runtime, 'assert_available'), \
                 patch.object(runtime, 'command') as run, self.assertRaises(runtime.VolumeError):
                runtime.mount_volume('password')
            run.assert_not_called()

    def test_readonly_mount_does_not_start_services(self):
        with patch.object(runtime, 'operation_lock', return_value=nullcontext()), \
             patch.object(runtime, 'load_device'), patch.object(runtime.os.path, 'ismount', return_value=True), \
             patch.object(runtime, 'check_mounted'), patch.object(runtime, 'command', return_value=completed('ro,relatime')), \
             patch.object(runtime, 'start_filebrowser') as fb, patch.object(runtime, 'start_immich') as immich:
            self.assertIn('sola lettura', runtime.mount_volume('password'))
        fb.assert_not_called()
        immich.assert_not_called()

    def test_readonly_request_cannot_adopt_an_existing_writable_mount(self):
        with patch.object(runtime, 'operation_lock', return_value=nullcontext()), \
             patch.object(runtime, 'load_device'), patch.object(runtime.os.path, 'ismount', return_value=True), \
             patch.object(runtime, 'check_mounted'), patch.object(runtime, 'command', return_value=completed('rw,relatime')), \
             patch.object(runtime, 'start_filebrowser') as fb, \
             patch.object(runtime, 'start_immich') as immich, self.assertRaises(runtime.VolumeError):
            runtime.mount_volume('password', readonly=True)
        fb.assert_not_called()
        immich.assert_not_called()

    def test_mount_failure_never_starts_services(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(runtime, 'MOUNTPOINT', directory), \
             patch.object(runtime, 'operation_lock', return_value=nullcontext()), \
             patch.object(runtime, 'load_device', return_value='/dev/disk/by-id/selected'), \
             patch.object(runtime.os.path, 'ismount', return_value=False), \
             patch.object(runtime, 'assert_available'), \
             patch.object(runtime, 'command', side_effect=runtime.VolumeError('VeraCrypt fallito')), \
             patch.object(runtime, 'start_filebrowser') as fb, \
             patch.object(runtime, 'start_immich') as immich, self.assertRaises(runtime.VolumeError):
            runtime.mount_volume('password')
        fb.assert_not_called()
        immich.assert_not_called()

    def test_unmount_refuses_other_running_docker_users(self):
        with patch.object(runtime, 'operation_lock', return_value=nullcontext()), \
             patch.object(runtime.os.path, 'ismount', return_value=True), patch.object(runtime, 'check_mounted'), \
             patch.object(runtime, 'immich_settings', return_value=None), \
             patch.object(runtime, 'active_docker_users', return_value=['other-app']), \
             patch.object(runtime, 'command') as run, self.assertRaises(runtime.VolumeError):
            runtime.unmount_volume()
        run.assert_not_called()

    def test_immich_and_filebrowser_stop_before_veracrypt(self):
        calls = []
        with patch.object(runtime, 'operation_lock', return_value=nullcontext()), \
             patch.object(runtime.os.path, 'ismount', side_effect=[True, False]), patch.object(runtime, 'check_mounted'), \
             patch.object(runtime, 'immich_settings', return_value={'directory': '/mnt/secure/immich'}), \
             patch.object(runtime, 'compose_base', return_value=['docker', 'compose']), \
             patch.object(runtime, 'active_docker_users', return_value=[]), \
             patch.object(runtime, 'filebrowser_installed', return_value=True), \
             patch.object(runtime, 'command', side_effect=lambda args, **kwargs: calls.append(args) or completed()):
            runtime.unmount_volume()
        self.assertEqual(calls[0], ['docker', 'compose', 'stop', '--timeout', '60'])
        self.assertEqual(calls[1], ['systemctl', 'stop', runtime.FILEBROWSER_SERVICE])
        self.assertEqual(calls[-1], ['veracrypt', '--text', '--non-interactive', '--dismount', '/mnt/secure'])


class WebTests(unittest.TestCase):
    def setUp(self):
        from werkzeug.security import generate_password_hash
        self.patches = [patch.object(runtime, 'protected_read', return_value=json.dumps({'password_hash': generate_password_hash('admin-secret')})),
                        patch.object(runtime.os.path, 'ismount', return_value=False),
                        patch.object(runtime, 'load_device', return_value='/dev/disk/by-id/selected'),
                        patch.object(runtime, 'candidates', return_value=[]),
                        patch.object(runtime, 'filebrowser_installed', return_value=False)]
        for p in self.patches:
            p.start()
        self.app = runtime.create_web_app()
        self.app.testing = True
        self.client = self.app.test_client()

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()

    def csrf(self):
        self.client.get('/')
        with self.client.session_transaction() as session:
            return session['csrf']

    def login(self):
        response = self.client.post('/login', data={'csrf': self.csrf(), 'admin_password': 'admin-secret'})
        self.assertEqual(response.status_code, 302)
        return self.csrf()

    def test_login_and_authenticated_device_display(self):
        self.assertNotIn(b'/dev/disk/by-id/selected', self.client.get('/').data)
        self.login()
        self.assertIn(b'/dev/disk/by-id/selected', self.client.get('/').data)

    def test_status_updates_when_filebrowser_becomes_ready_without_new_logs(self):
        self.assertEqual(self.client.get('/get-log').status_code, 302)
        self.login()
        with patch.object(runtime.os.path, 'ismount', return_value=True), \
             patch.object(runtime, 'filebrowser_status', return_value='starting') as state:
            first = self.client.get('/get-log').json
            self.assertEqual(first['status']['filebrowser'], 'starting')
            self.assertIn('FileBrowser in avvio', first['status']['text'])
            state.return_value = 'ready'
            second = self.client.get('/get-log').json
        self.assertEqual(second['status']['filebrowser'], 'ready')
        self.assertIn('FileBrowser pronto', second['status']['text'])
        self.assertEqual(first['logs'], second['logs'])
        # Status must refresh even when the operation log has not changed.
        self.assertLess(runtime.HTML.index('refreshStatus(data.status)'),
                        runtime.HTML.index('if(snapshot===previousLog)return'))
        self.assertIn("form.addEventListener('submit'", runtime.HTML)
        self.assertIn("spinner.className='spinner'", runtime.HTML)
        self.assertNotIn('input.disabled=true', runtime.HTML)

    def test_original_logo_is_public_and_used_for_header_and_favicon(self):
        logo = ROOT / 'assets' / 'veraprox-logo.png'
        with patch.object(runtime, 'WEB_LOGO', logo):
            response = self.client.get('/veraprox-logo.png')
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.mimetype, 'image/png')
            self.assertEqual(response.data, logo.read_bytes())
            response.close()
        for authenticated in (False, True):
            if authenticated:
                self.login()
            html = self.client.get('/').get_data(as_text=True)
            self.assertIn('<title>VeraProx</title>', html)
            self.assertIn('rel="icon" type="image/png" href="/veraprox-logo.png"', html)
            self.assertIn('class="brand-logo" src="/veraprox-logo.png" width="36" height="36"', html)

    def test_missing_csrf_prevents_mount_even_when_logged_in(self):
        self.login()
        with patch.object(runtime, 'mount_volume') as mount:
            self.assertEqual(self.client.post('/mount', data={'password': 'secret'}).status_code, 400)
        mount.assert_not_called()

    def test_unauthenticated_valid_csrf_cannot_mount(self):
        with patch.object(runtime, 'mount_volume') as mount:
            response = self.client.post('/mount', data={'csrf': self.csrf(), 'password': 'secret'})
            self.assertEqual(response.status_code, 302)
        mount.assert_not_called()

    def test_mount_password_never_appears_in_html_or_logs(self):
        token = self.login()
        password = "secret'; touch /tmp/never; '"
        with patch.object(runtime, 'mount_volume', return_value='Volume montato.') as mount:
            response = self.client.post('/mount', data={'csrf': token, 'password': password, 'pim': '12'})
        mount.assert_called_once_with(password, '12', readonly=False)
        self.assertNotIn(password.encode(), response.data)
        self.assertNotIn(password, str(self.client.get('/get-log').json))

    def test_clear_log_returns_without_deadlock(self):
        token = self.login()
        self.assertEqual(self.client.post('/clear-log', data={'csrf': token}).status_code, 302)

    def test_repeated_failed_logins_are_limited(self):
        token = self.csrf()
        for _ in range(10):
            self.assertEqual(self.client.post('/login', data={'csrf': token, 'admin_password': 'wrong'}).status_code, 401)
        self.assertEqual(self.client.post('/login', data={'csrf': token, 'admin_password': 'wrong'}).status_code, 429)


class ImmichTests(unittest.TestCase):
    def test_guard_prevents_restart_and_automatic_bind_directory_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'library'
            source.mkdir()
            config = {'services': {'server': {'volumes': [{'type': 'bind', 'source': str(source), 'target': '/data'}]},
                                   'database': {'volumes': [{'type': 'volume', 'source': 'pgdata', 'target': '/var/lib/postgresql/data'}]}}}
            with patch.object(runtime, 'check_mounted'), \
                 patch.object(runtime, 'compose_base', return_value=['docker', 'compose', '-f', 'compose.yml']), \
                 patch.object(runtime, 'RUN_DIR', Path(directory) / 'run'), \
                 patch.object(runtime, 'command', return_value=completed(json.dumps(config))):
                runtime.guarded_compose({})
            guard = json.loads((Path(directory) / 'run' / 'immich-guard.json').read_text())
            self.assertEqual(guard['services']['server']['restart'], 'no')
            self.assertEqual(guard['services']['database']['restart'], 'no')
            self.assertFalse(guard['services']['server']['volumes'][0]['bind']['create_host_path'])
            self.assertNotIn('environment', guard['services']['database'])

    def test_postgres_on_ntfs_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            config = {'services': {'database': {'volumes': [{'type': 'bind', 'source': directory,
                                                            'target': '/var/lib/postgresql/data'}]}}}
            with patch.object(runtime, 'check_mounted'), patch.object(runtime, 'compose_base', return_value=['docker', 'compose']), \
                 patch.object(runtime, 'command', side_effect=[completed(json.dumps(config)), completed('fuseblk\n')]), \
                 self.assertRaises(runtime.VolumeError):
                runtime.guarded_compose({})

    def test_start_does_not_pull_or_build_new_images(self):
        with patch.object(runtime, 'immich_settings', return_value={"directory": '/mnt/secure/docker/immich'}), \
             patch.object(runtime, 'guarded_compose', return_value=['docker', 'compose']), \
             patch.object(runtime, 'command') as run:
            runtime.start_immich()
        self.assertEqual(run.call_args.args[0], ['docker', 'compose', 'up', '-d', '--no-build', '--pull', 'never'])


class InstallerTests(unittest.TestCase):
    def test_failure_cleanup_restores_previously_running_web_and_preserves_exit_code(self):
        body = SCRIPT.split('cleanup_runtime() {\n', 1)[1].split('\n}\n', 1)[0]
        bash = 'C:/Program Files/Git/bin/bash.exe' if sys.platform == 'win32' else 'bash'
        for restart_needed in (0, 1):
            script = '''
systemctl() { printf 'service:%s %s\\n' "$1" "$2"; }
rm() { printf 'cleanup\\n'; }
RUNTIME_WORK=/unused/mock
WEB_RESTART_NEEDED=''' + str(restart_needed) + '\ncleanup_runtime() {\n' + body + '''
}
trap cleanup_runtime EXIT
exit 1
'''
            result = subprocess.run([bash, '-c', script], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('cleanup', result.stdout)
            self.assertEqual('service:start secure-webapp.service' in result.stdout, bool(restart_needed))

    def test_embedded_python_blocks_compile(self):
        for delimiter in ('MIGRATEPY', 'RUNTIMEPY', 'STOPLEGACYPY', 'HEALTHPY'):
            source = SCRIPT.split("<<'" + delimiter + "'\n", 1)[1].split('\n' + delimiter + '\n', 1)[0]
            compile(source, delimiter, 'exec')

    def test_legacy_password_is_hashed_without_executing_legacy_code(self):
        from werkzeug.security import check_password_hash
        source = SCRIPT.split("<<'MIGRATEPY'\n", 1)[1].split('\nMIGRATEPY\n', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            old = Path(directory) / 'old.py'
            old.write_text("ADMIN_PASSWORD = 'old-secret'\nraise RuntimeError('must not execute')")
            destination = Path(directory) / 'web.json'
            with patch.object(sys, 'argv', ['migration', str(destination), str(old)]):
                exec(compile(source, 'migration', 'exec'), {})
            result = json.loads(destination.read_text())
            self.assertNotIn('old-secret', destination.read_text())
            self.assertTrue(check_password_hash(result['password_hash'], 'old-secret'))


if __name__ == '__main__':
    unittest.main()
