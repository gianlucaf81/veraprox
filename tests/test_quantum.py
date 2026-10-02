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


class QuantumTests(unittest.TestCase):
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

    @unittest.skipUnless(os.environ.get('VERAPROX_QUANTUM_TEST_BINARY'), 'Binario Quantum ufficiale non specificato')
    def test_real_quantum_bootstrap_login_and_password_not_stored_plaintext(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'media'
            source.mkdir()
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
                            break
                        except OSError:
                            time.sleep(0.25)
                    else:
                        self.fail('Login dopo riavvio non riuscito')
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == '__main__':
    unittest.main()
