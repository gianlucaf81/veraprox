#!/usr/bin/env bash
# Installazione/migrazione esplicita: non monta il volume e non avvia il servizio definitivo.
set -Eeuo pipefail
umask 077

[ "$(id -u)" -eq 0 ] || { echo "Eseguire come root." >&2; exit 1; }
if mountpoint -q /mnt/secure; then
  echo "Smonta /mnt/secure prima di installare Quantum." >&2
  exit 1
fi
case "${1:-}" in
  ''|--password-stdin) ;;
  *) echo "Uso: bash install-filebrowser-quantum.sh [--password-stdin]" >&2; exit 1 ;;
esac

# Versione stabile collaudata: la beta 2.x usa un formato di configurazione diverso.
QUANTUM_VERSION=v1.5.6-stable
case "$(uname -m)" in
  x86_64) QUANTUM_ARCH=amd64; QUANTUM_SHA=febf1ded3368eac1f13481f413db272c57678b70f09e74f5513d5e25e0bfb0e5 ;;
  aarch64) QUANTUM_ARCH=arm64; QUANTUM_SHA=0ad12910ffe51bc3ad06096af9559147f1126d074ed5c8a1afdf81ae5d7ebf24 ;;
  *) echo "Architettura non supportata." >&2; exit 1 ;;
esac
QUANTUM_DIR=/etc/veraprox/filebrowser-quantum
command -v python3 >/dev/null || { echo "Installa python3 prima di eseguire questo helper." >&2; exit 1; }
# Soglia minima prudenziale, non una stima esatta del piano APT. Controlla anche
# filesystem separati: spazio sul disco VeraCrypt non libera spazio in Debian.
python3 - <<'SPACEPY'
import shutil
import sys

minimum = 512 * 1024 * 1024
for path in ('/', '/usr', '/var', '/tmp'):
    free = shutil.disk_usage(path).free
    if free < minimum:
        print(f'Spazio insufficiente sul filesystem di {path}: {free // (1024 * 1024)} MiB liberi. '
              'Libera spazio o amplia il disco Debian; servono almeno 512 MiB liberi prima di procedere. '
              'Verifica anche gli inode con df -i.', file=sys.stderr)
        sys.exit(1)
SPACEPY
QUANTUM_WORK=$(mktemp -d /var/tmp/veraprox-quantum-XXXXXXXX)
trap 'rm -rf -- "$QUANTUM_WORK"' EXIT

echo "Installazione dipendenze Quantum e FFmpeg..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends --no-remove ca-certificates curl ffmpeg python3
command -v ffprobe >/dev/null

echo "Download FileBrowser Quantum $QUANTUM_VERSION..."
curl -fL --retry 3 "https://github.com/gtsteffaniak/filebrowser/releases/download/$QUANTUM_VERSION/linux-$QUANTUM_ARCH-filebrowser" -o "$QUANTUM_WORK/filebrowser-quantum"
printf '%s  %s\n' "$QUANTUM_SHA" "$QUANTUM_WORK/filebrowser-quantum" | sha256sum --check --status
chmod 700 "$QUANTUM_WORK/filebrowser-quantum"
"$QUANTUM_WORK/filebrowser-quantum" version

cat > "$QUANTUM_WORK/configure.py" <<'QUANTUMPY'
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time
from urllib.parse import quote
from urllib.request import Request, build_opener, ProxyHandler


def configuration(database, cache, source='/mnt/secure', port=8080, listen='0.0.0.0'):
    # JSON è YAML valido; nessuna dipendenza PyYAML o interpolazione della password.
    return {
        'server': {
            'port': port, 'listen': listen, 'database': str(database), 'cacheDir': str(cache),
            'cacheDirCleanup': False, 'numImageProcessors': 2, 'disableUpdateCheck': True,
            'disablePreviews': False, 'disableWebDAV': True,
            'logging': [{'levels': 'warning|error', 'output': 'stdout'}],
            'sources': [{'path': str(source), 'name': 'Volume', 'config': {
                'defaultEnabled': True, 'defaultUserScope': '/', 'private': True,
                'rules': [{'folderName': '.veraprox-quantum'},
                          {'folderName': '@eaDir'}]
            }}]
        },
        'auth': {'adminUsername': 'admin', 'methods': {
            'password': {'enabled': True, 'signup': False, 'minLength': 8}, 'noauth': False}},
        'userDefaults': {
            'listing': {'viewMode': 'gallery'}, 'ui': {'locale': 'it'},
            'preview': {'image': True, 'video': True, 'motionVideoPreview': True}
        },
        'integrations': {'media': {'ffmpegPath': '/usr/bin', 'debug': False}}
    }


def bootstrap(binary, work, password, source='/mnt/secure'):
    # Il vero segreto non finisce in argv, config o log. La password casuale di bootstrap
    # è invalidata prima dell'installazione del DB. Solo filesystem vuoti in questa fase.
    if not 8 <= len(password.encode('utf-8')) <= 72 or any(c in password for c in '\r\n\0'):
        raise ValueError('Password Quantum: da 8 a 72 byte UTF-8, senza caratteri di controllo.')
    work = Path(work)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    seed = secrets.token_urlsafe(32)
    config = configuration(work / 'quantum.db', work / 'cache', source, port, '127.0.0.1')
    # Non servono anteprime durante il bootstrap, né accesso a Internet.
    config['integrations']['media']['ffmpegPath'] = ''
    config['auth']['adminPassword'] = seed
    config_path = work / 'bootstrap.yaml'
    config_path.write_text(json.dumps(config), encoding='utf-8')
    os.chmod(config_path, 0o600)
    opener = build_opener(ProxyHandler({}))
    base = f'http://127.0.0.1:{port}'

    def request(path, method='GET', data=None, headers=None):
        headers = dict(headers or {})
        if data is not None:
            data = json.dumps(data).encode('utf-8')
            headers['Content-Type'] = 'application/json'
        with opener.open(Request(base + path, data=data, headers=headers, method=method), timeout=3) as response:
            return response.read()

    # Stesso controller API della release stabile, provato anche con password speciali.
    with (work / 'bootstrap.log').open('wb') as log:
        env = {key: value for key, value in os.environ.items() if not key.startswith('FILEBROWSER_')}
        env.update(TMPDIR=str(work), TMP=str(work), TEMP=str(work))
        process = subprocess.Popen([str(binary), '-c', str(config_path)], cwd=work,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=env,
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        try:
            for _ in range(80):
                if process.poll() is not None:
                    raise RuntimeError('Quantum non si avvia durante il collaudo della configurazione.')
                try:
                    request('/health')
                    break
                except OSError:
                    time.sleep(0.25)
            else:
                raise RuntimeError('Quantum non risponde durante il bootstrap.')
            token = request('/api/auth/login?username=admin', 'POST',
                            headers={'X-Password': quote(seed, safe='')}).decode().strip('"\n')
            headers = {'Authorization': 'Bearer ' + token, 'X-Password': quote(seed, safe='')}
            user = json.loads(request('/api/users?id=self', headers=headers))
            request('/api/users?id=' + str(user['id']), 'PUT',
                    {'which': ['Password'], 'data': {'password': password}}, headers)
            # Verifica il nuovo login, non soltanto la risposta alla modifica.
            request('/api/auth/login?username=admin', 'POST', headers={'X-Password': quote(password, safe='')})
        finally:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    config_path.unlink()
    # Controllo difensivo: l'account password viene conservato solo come hash bcrypt.
    if password.encode('utf-8') in (work / 'quantum.db').read_bytes():
        raise RuntimeError('Password in chiaro rilevata nel database: installazione annullata.')


def main():
    binary, work, destination, mode = sys.argv[1:]
    destination = Path(destination)
    work = Path(work)
    existing = destination / 'quantum.db'
    if not existing.is_file() or existing.stat().st_size == 0:
        if mode == '--password-stdin':
            password = sys.stdin.read()
        else:
            import getpass
            password = getpass.getpass('Nuova password FileBrowser Quantum (admin): ')
            if password != getpass.getpass('Ripeti password Quantum: '):
                raise ValueError('Le password non coincidono.')
        bootstrap(binary, work, password)
    config = configuration(destination / 'quantum.db', '/mnt/secure/.veraprox-quantum/cache')
    (work / 'config.yaml').write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Non stampare risposte API o dettagli che potrebbero includere credenziali.
        print('Configurazione Quantum fallita. Verifica password (8–72 byte), dipendenze e spazio libero.', file=sys.stderr)
        sys.exit(1)
QUANTUMPY

python3 "$QUANTUM_WORK/configure.py" "$QUANTUM_WORK/filebrowser-quantum" "$QUANTUM_WORK" "$QUANTUM_DIR" "${1:-}"

# Nessuna sostituzione definitiva prima del download, checksum e bootstrap riusciti.
systemctl stop veraprox-filebrowser.service 2>/dev/null || true
QUANTUM_BACKUP=$(mktemp -d /var/backups/veraprox-quantum-XXXXXXXX)
if [ -d /etc/filebrowser ]; then cp -a /etc/filebrowser "$QUANTUM_BACKUP/"; fi
if [ -d "$QUANTUM_DIR" ]; then cp -a "$QUANTUM_DIR" "$QUANTUM_BACKUP/"; fi
if [ -f /usr/local/bin/filebrowser-quantum ]; then cp -p /usr/local/bin/filebrowser-quantum "$QUANTUM_BACKUP/"; fi
if command -v filebrowser >/dev/null; then cp -p -- "$(command -v filebrowser)" "$QUANTUM_BACKUP/filebrowser-classic"; fi
if [ -f /etc/systemd/system/veraprox-filebrowser.service ]; then
  cp -p /etc/systemd/system/veraprox-filebrowser.service "$QUANTUM_BACKUP/"
fi
install -d -m 700 "$QUANTUM_DIR"
install -m 755 "$QUANTUM_WORK/filebrowser-quantum" /usr/local/bin/filebrowser-quantum
install -m 600 "$QUANTUM_WORK/config.yaml" "$QUANTUM_DIR/config.yaml"
if [ -f "$QUANTUM_WORK/quantum.db" ]; then install -m 600 "$QUANTUM_WORK/quantum.db" "$QUANTUM_DIR/quantum.db"; fi
printf '%s\n' "$QUANTUM_VERSION" > "$QUANTUM_DIR/version"
echo "Quantum pronto. Backup: $QUANTUM_BACKUP"
echo "Account: admin / password scelta per Quantum. Vecchi utenti e condivisioni non importati."
echo "Il runtime VeraProx configurerà il servizio; il volume resta smontato."
