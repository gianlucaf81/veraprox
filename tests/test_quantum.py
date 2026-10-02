import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import types
import unittest
from unittest.mock import patch

from test_runtime import runtime

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / 'install-filebrowser-quantum.sh').read_text(encoding='utf-8')
SOURCE = INSTALLER.split("<<'QUANTUMPY'\n", 1)[1].split('\nQUANTUMPY\n', 1)[0]
quantum = types.ModuleType('quantum_test')
exec(compile(SOURCE, 'configure_quantum.py', 'exec'), quantum.__dict__)
UPDATER = (ROOT / 'update-veraprox.sh').read_text(encoding='utf-8')
REPAIR_SOURCE = UPDATER.split("<<'QUANTUMFIXPY'\n", 1)[1].split('\nQUANTUMFIXPY\n', 1)[0]
repair = types.ModuleType('quantum_repair_test')
exec(compile(REPAIR_SOURCE, 'repair_quantum.py', 'exec'), repair.__dict__)


class QuantumTests(unittest.TestCase):
    def test_apt_does_not_install_recommendations_or_remove_packages(self):
        self.assertIn('--no-install-recommends --no-remove ca-certificates curl ffmpeg python3', INSTALLER)

    def test_low_disk_space_aborts_before_package_installation(self):
        source = INSTALLER.split("<<'SPACEPY'\n", 1)[1].split('\nSPACEPY\n', 1)[0]
        self.assertLess(INSTALLER.index("<<'SPACEPY'"), INSTALLER.index('apt-get update'))
        with patch('shutil.disk_usage', return_value=types.SimpleNamespace(free=0)), \
             patch('sys.stderr'), self.assertRaises(SystemExit) as stopped:
            exec(compile(source, 'space_check.py', 'exec'), {})
        self.assertEqual(stopped.exception.code, 1)

    def test_space_check_accepts_enough_space(self):
        source = INSTALLER.split("<<'SPACEPY'\n", 1)[1].split('\nSPACEPY\n', 1)[0]
        with patch('shutil.disk_usage', return_value=types.SimpleNamespace(free=1024**3)) as usage:
            exec(compile(source, 'space_check.py', 'exec'), {})
        self.assertEqual([call.args[0] for call in usage.call_args_list], ['/', '/usr', '/var', '/tmp'])

    def test_config_uses_stable_schema_and_encrypted_cache(self):
        config = quantum.configuration('/etc/veraprox/filebrowser-quantum/quantum.db',
                                       '/mnt/secure/.veraprox-quantum/cache')
        self.assertEqual(config['server']['port'], 8080)
        self.assertEqual(config['server']['sources'][0]['path'], '/mnt/secure')
        self.assertTrue(config['server']['sources'][0]['config']['private'])
        self.assertNotIn('adminPassword', config['auth'])
        self.assertTrue(config['auth']['methods']['password']['enabled'])
        self.assertFalse(config['auth']['methods']['noauth'])
        self.assertEqual(config['integrations']['media']['ffmpegPath'], '/usr/bin')
        self.assertTrue(config['userDefaults']['preview']['video'])
        self.assertTrue(config['userDefaults']['preview']['motionVideoPreview'])
        self.assertFalse(config['server']['cacheDirCleanup'])
        self.assertEqual(config['userDefaults']['listing']['viewMode'], 'gallery')
        self.assertEqual(config['server']['sources'][0]['config']['rules'],
                         [{'folderName': '.veraprox-quantum'}, {'folderName': '@eaDir'}])

    def test_repair_only_changes_bad_rule_and_unsupported_default_view(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.yaml'
            config = quantum.configuration('/etc/quantum.db', '/mnt/secure/.veraprox-quantum/cache')
            config['server']['sources'][0]['config']['rules'].extend([
                {'folderPath': '/', 'ignoreSymlinks': True}, {'folderName': 'user-exclusion'}])
            config['userDefaults']['listing']['viewMode'] = 'grid'
            path.write_text(json.dumps(config), encoding='utf-8')
            os.chmod(path, 0o600)
            # Windows does not implement POSIX group/other modes.
            safe = types.SimpleNamespace(st_mode=0o100600, st_uid=0)
            with patch.object(repair.Path, 'lstat', return_value=safe):
                self.assertTrue(repair.repair_config(path))
                self.assertFalse(repair.repair_config(path))
            config['server']['sources'][0]['config']['rules'].remove({'folderPath': '/', 'ignoreSymlinks': True})
            config['userDefaults']['listing']['viewMode'] = 'gallery'
            self.assertEqual(json.loads(path.read_text()), config)
            self.assertEqual(sorted(item.name for item in path.parent.iterdir()), ['config.yaml'])

    def test_repair_refuses_symlink_or_public_configuration(self):
        for mode, owner in ((0o120600, 0), (0o100644, 0), (0o100600, 1000)):
            with patch.object(repair.Path, 'lstat', return_value=types.SimpleNamespace(st_mode=mode, st_uid=owner)), \
                 self.assertRaises(ValueError):
                repair.repair_config('/unused/config.yaml')

    def test_service_root_refuses_symlink(self):
        with patch.object(repair.Path, 'is_symlink', return_value=True), \
             patch.object(repair.Path, 'mkdir') as mkdir, self.assertRaises(ValueError):
            repair.prepare_service_root('/var/lib/veraprox/quantum-root')
        mkdir.assert_not_called()

    def test_service_root_refuses_writable_or_foreign_directory(self):
        for mode, owner in ((0o040777, 0), (0o040700, 1000)):
            with patch.object(repair.Path, 'is_symlink', return_value=False), \
                 patch.object(repair.Path, 'mkdir'), \
                 patch.object(repair.Path, 'stat', return_value=types.SimpleNamespace(st_mode=mode, st_uid=owner)), \
                 self.assertRaises(ValueError):
                repair.prepare_service_root('/var/lib/veraprox/quantum-root')

    def test_isolation_preflight_precedes_configuration_and_unit_replacement(self):
        self.assertLess(REPAIR_SOURCE.index('verify_isolated_previews(sys.argv'),
                        REPAIR_SOURCE.index('if repair_config(sys.argv'))
        self.assertLess(UPDATER.index('python3 "$RUNTIME_WORK/quantum-repair.py"'),
                        UPDATER.index('install -m 644 "$RUNTIME_WORK/veraprox-filebrowser.service"'))
        self.assertIn("'/api/resources/preview?source=Volume&path=%2Foutside-link%2Fsample.png'", REPAIR_SOURCE)
        self.assertIn("for filename in ('sample.png', 'sample.mp4')", REPAIR_SOURCE)

    def test_isolation_preflight_reuses_the_final_unit_restrictions(self):
        with tempfile.TemporaryDirectory() as directory:
            unit = Path(directory) / 'test.service'
            unit.write_text(UPDATER.split("<<'QUANTUMSERVICE'\n", 1)[1].split('\nQUANTUMSERVICE\n', 1)[0])
            properties = repair.isolation_properties(unit)
        self.assertEqual(properties['RootDirectory'], '/var/lib/veraprox/quantum-root')
        self.assertEqual(properties['CapabilityBoundingSet'], '')
        self.assertEqual(properties['PrivateDevices'], 'true')
        self.assertEqual(properties['InaccessiblePaths'], '-/proc -/sys')
        self.assertIn('/usr/bin/ffmpeg', properties['BindReadOnlyPaths'])
        self.assertIn('-/etc/alternatives', properties['BindReadOnlyPaths'])
        self.assertIn('-/etc/ssl/certs', properties['BindReadOnlyPaths'])
        self.assertNotIn('ExecStartPre', properties)
        self.assertNotIn('BindPaths', properties)

    def test_invalid_password_rejected_before_starting_process(self):
        for password in ('', 'short', 'x' * 73, 'valid123\n', 'valid123\0'):
            with patch.object(quantum.subprocess, 'Popen') as start, self.assertRaises(ValueError):
                quantum.bootstrap('binary', '/tmp/unused', password)
            start.assert_not_called()

    def test_unmounted_volume_cannot_create_cache(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(runtime, 'MOUNTPOINT', directory), \
             patch.object(runtime, 'check_mounted', side_effect=runtime.VolumeError('smontato')):
            with self.assertRaises(runtime.VolumeError):
                runtime.prepare_quantum()
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_prepare_creates_only_private_cache_after_mount_check(self):
        with tempfile.TemporaryDirectory() as directory:
            config = quantum.configuration('/etc/quantum.db', str(Path(directory) / '.veraprox-quantum/cache'), directory)
            with patch.object(runtime, 'MOUNTPOINT', directory), patch.object(runtime, 'check_mounted') as check, \
                 patch.object(runtime, 'protected_read', return_value=json.dumps(config)):
                runtime.prepare_quantum()
            check.assert_called_once()
            self.assertTrue((Path(directory) / '.veraprox-quantum/cache').is_dir())
            self.assertTrue((Path(directory) / '.veraprox-quantum/tmp').is_dir())

    def test_cache_outside_volume_is_refused(self):
        config = quantum.configuration('/etc/quantum.db', '/tmp/unsafe')
        with patch.object(runtime, 'check_mounted'), \
             patch.object(runtime, 'protected_read', return_value=json.dumps(config)), \
             self.assertRaises(runtime.VolumeError):
            runtime.prepare_quantum()

    def test_another_source_is_refused(self):
        config = quantum.configuration('/etc/quantum.db', '/mnt/secure/.veraprox-quantum/cache', '/')
        with patch.object(runtime, 'check_mounted'), \
             patch.object(runtime, 'protected_read', return_value=json.dumps(config)), \
             self.assertRaises(runtime.VolumeError):
            runtime.prepare_quantum()

    def test_symlink_private_directory_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            config = quantum.configuration('/etc/quantum.db', str(Path(directory) / '.veraprox-quantum/cache'), directory)
            with patch.object(runtime, 'MOUNTPOINT', directory), patch.object(runtime, 'check_mounted'), \
                 patch.object(runtime, 'protected_read', return_value=json.dumps(config)), \
                 patch.object(runtime.Path, 'is_symlink', return_value=True), \
                 self.assertRaises(runtime.VolumeError):
                runtime.prepare_quantum()
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_service_cannot_start_at_boot_without_mount(self):
        unit = (ROOT / 'update-veraprox.sh').read_text(encoding='utf-8').split("<<'QUANTUMSERVICE'\n", 1)[1].split('\nQUANTUMSERVICE\n', 1)[0]
        self.assertIn('ConditionPathIsMountPoint=/mnt/secure', unit)
        self.assertIn('runtime.py prepare-quantum', unit)
        self.assertNotIn('[Install]', unit)
        self.assertIn('TMPDIR=/mnt/secure/.veraprox-quantum/tmp', unit)
        self.assertIn('ProtectSystem=strict', unit)
        self.assertIn('RootDirectory=/var/lib/veraprox/quantum-root', unit)
        self.assertIn('RootDirectoryStartOnly=true', unit)
        self.assertIn('ExecStartPre=+/usr/bin/python3', unit)
        self.assertIn('BindPaths=/mnt/secure /etc/veraprox/filebrowser-quantum', unit)
        self.assertIn('CapabilityBoundingSet=\n', unit)
        self.assertIn('PrivateDevices=true', unit)
        self.assertIn('InaccessiblePaths=-/proc -/sys', unit)
        self.assertNotIn('BindReadOnlyPaths=/usr\n', unit)

    @unittest.skipUnless(os.environ.get('VERAPROX_QUANTUM_TEST_BINARY'), 'Binario Quantum ufficiale non specificato')
    def test_real_quantum_bootstrap_login_and_password_not_stored_plaintext(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'media'
            source.mkdir()
            nested = source / 'sample'
            nested.mkdir()
            # Real PNG fixture in a subdirectory: this reproduces the root-rule bug.
            png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2XcAAAAASUVORK5CYII=')
            (nested / 'sample.png').write_bytes(png)
            (source / '.veraprox-quantum').mkdir()
            (source / '@eaDir').mkdir()
            password = "test, quote' € & %123"
            quantum.bootstrap(Path(os.environ['VERAPROX_QUANTUM_TEST_BINARY']).resolve(), directory, password, source)
            self.assertNotIn(password.encode(), (Path(directory) / 'quantum.db').read_bytes())
            self.assertNotIn(password.encode(), (Path(directory) / 'bootstrap.log').read_bytes())
            self.assertFalse((Path(directory) / 'bootstrap.yaml').exists())
            # Secondo avvio senza adminPassword: non deve tornare alla password di default.
            with quantum.socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            config = quantum.configuration(Path(directory) / 'quantum.db', Path(directory) / 'cache', source, port, '127.0.0.1')
            config['integrations']['media']['ffmpegPath'] = ''
            config_path = Path(directory) / 'final.yaml'
            config_path.write_text(json.dumps(config), encoding='utf-8')
            with (Path(directory) / 'restart.log').open('wb') as log:
                process = subprocess.Popen([os.environ['VERAPROX_QUANTUM_TEST_BINARY'], '-c', str(config_path)],
                                           cwd=directory, stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                                           creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                try:
                    opener = quantum.build_opener(quantum.ProxyHandler({}))
                    request = quantum.Request(f'http://127.0.0.1:{port}/api/auth/login?username=admin', method='POST',
                                              headers={'X-Password': quantum.quote(password, safe='')})
                    for _ in range(80):
                        if process.poll() is not None:
                            self.fail('Quantum non si riavvia con la configurazione definitiva')
                        try:
                            with opener.open(request, timeout=2) as response:
                                self.assertEqual(response.status, 200)
                                token = response.read().decode().strip('"\n')
                            break
                        except OSError:
                            time.sleep(0.25)
                    else:
                        self.fail('Login dopo riavvio non riuscito')
                    headers = {'Authorization': 'Bearer ' + token}
                    base = f'http://127.0.0.1:{port}'
                    with opener.open(quantum.Request(base + '/api/users?id=self', headers=headers), timeout=5) as response:
                        user = json.load(response)
                    self.assertEqual(user['viewMode'], 'gallery')
                    with opener.open(quantum.Request(base + '/api/resources?source=Volume&path=%2Fsample%2F', headers=headers), timeout=5) as response:
                        listing = json.load(response)
                    self.assertEqual(listing['files'][0]['type'], 'image/png')
                    self.assertTrue(listing['files'][0]['hasPreview'])
                    with opener.open(quantum.Request(base + '/api/resources/preview?source=Volume&path=%2Fsample%2Fsample.png', headers=headers), timeout=5) as response:
                        self.assertEqual(response.status, 200)
                        self.assertEqual(response.read(), png)
                    with opener.open(quantum.Request(base + '/api/resources?source=Volume&path=%2F', headers=headers), timeout=5) as response:
                        folders = {item['name'] for item in json.load(response).get('folders', [])}
                    self.assertIn('sample', folders)
                    self.assertNotIn('.veraprox-quantum', folders)
                    self.assertNotIn('@eaDir', folders)
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == '__main__':
    unittest.main()
