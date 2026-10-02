#!/usr/bin/env bash
# Aggiorna il runtime; --install-quantum sostituisce esplicitamente FileBrowser.
set -Eeuo pipefail
umask 077

if [ "$(id -u)" -ne 0 ]; then
  echo "Eseguire come root." >&2
  exit 1
fi
if mountpoint -q /mnt/secure; then
  echo "Prima dell'aggiornamento arresta le applicazioni che usano /mnt/secure e smonta il volume." >&2
  exit 1
fi
for runtime_tool in python3 veracrypt lsblk findmnt systemctl; do
  command -v "$runtime_tool" >/dev/null || { echo "Strumento mancante: $runtime_tool" >&2; exit 1; }
done
python3 -c 'import flask' || { echo "Installa python3-flask prima dell'aggiornamento." >&2; exit 1; }
case "${1:-}" in
  ''|--web-password-stdin|--install-quantum) ;;
  *) echo "Uso: bash update-veraprox.sh [--install-quantum|--web-password-stdin]" >&2; exit 1 ;;
esac

RUNTIME_WORK=$(mktemp -d)
trap 'rm -rf -- "$RUNTIME_WORK"' EXIT
# Usa il logo originale, verificato prima di modificare il servizio web.
WEB_LOGO_SHA256=05d74bbb74d8690b0a90184240e211cf5f732b98b443fc9a6f6bf3f9f2ce26ec
WEB_LOCAL_DIR=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  WEB_LOCAL_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fi
if [ -n "$WEB_LOCAL_DIR" ] && [ -f "$WEB_LOCAL_DIR/assets/veraprox-logo.png" ]; then
  cp -- "$WEB_LOCAL_DIR/assets/veraprox-logo.png" "$RUNTIME_WORK/veraprox-logo.png"
else
  curl -fsSL --retry 3 https://raw.githubusercontent.com/gianlucaf81/veraprox/main/assets/veraprox-logo.png -o "$RUNTIME_WORK/veraprox-logo.png"
fi
python3 -c 'import hashlib,pathlib,sys; actual=hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest(); sys.exit(0 if actual == sys.argv[2] else "Checksum del logo non valido: aggiornamento annullato.")' "$RUNTIME_WORK/veraprox-logo.png" "$WEB_LOGO_SHA256"
BACKUP_DIR=$(mktemp -d /var/backups/veraprox-XXXXXXXX)
for runtime_file in /usr/local/bin/mount-secure.sh /usr/local/bin/umount-secure.sh /usr/local/bin/secure-webapp.py /usr/local/bin/veraprox-device.sh /usr/local/bin/veraprox-immich.sh /usr/local/lib/veraprox/runtime.py /etc/systemd/system/secure-webapp.service /etc/systemd/system/veraprox-filebrowser.service; do
  if [ -f "$runtime_file" ]; then
    cp -p -- "$runtime_file" "$BACKUP_DIR/"
  fi
done
if [ -d /etc/veraprox ]; then cp -a /etc/veraprox "$BACKUP_DIR/"; fi
echo "Backup della configurazione e dei vecchi script: $BACKUP_DIR"
install -d -m 700 /etc/veraprox
install -d -m 755 /usr/local/lib/veraprox

if [ "${1:-}" = "--install-quantum" ]; then
  QUANTUM_LOCAL_DIR=""
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    QUANTUM_LOCAL_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  fi
  if [ -n "$QUANTUM_LOCAL_DIR" ] && [ -f "$QUANTUM_LOCAL_DIR/install-filebrowser-quantum.sh" ]; then
    cp -- "$QUANTUM_LOCAL_DIR/install-filebrowser-quantum.sh" "$RUNTIME_WORK/install-quantum.sh"
  else
    curl -fsSL --retry 3 https://raw.githubusercontent.com/gianlucaf81/veraprox/main/install-filebrowser-quantum.sh -o "$RUNTIME_WORK/install-quantum.sh"
  fi
  bash -n "$RUNTIME_WORK/install-quantum.sh"
  bash "$RUNTIME_WORK/install-quantum.sh"
fi

# Legge la vecchia password come dato, senza importare/eseguire la vecchia web app.
# L'installer può fornire una nuova password su stdin; un aggiornamento la conserva.
if [ "${1:-}" = "--web-password-stdin" ]; then
  python3 -c 'import json,sys; from werkzeug.security import generate_password_hash; p=sys.stdin.read(); assert p, "Password vuota"; json.dump({"password_hash":generate_password_hash(p)},open(sys.argv[1],"w"))' "$RUNTIME_WORK/web.json"
elif [ -f /etc/veraprox/web.json ]; then
  cp /etc/veraprox/web.json "$RUNTIME_WORK/web.json"
else
  python3 - "$RUNTIME_WORK/web.json" /usr/local/bin/secure-webapp.py <<'MIGRATEPY'
import ast
import json
import sys
from pathlib import Path
from werkzeug.security import generate_password_hash

source = Path(sys.argv[2])
password = None
if source.exists():
    try:
        tree = ast.parse(source.read_text())
    except SyntaxError:
        raise SystemExit('Vecchia web app non valida. Fornisci la password con --web-password-stdin.') from None
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'ADMIN_PASSWORD' for t in node.targets):
            try:
                password = ast.literal_eval(node.value)
            except (ValueError, TypeError):
                raise SystemExit('Password non letterale. Forniscila con --web-password-stdin.') from None
if not isinstance(password, str) or not password:
    raise SystemExit('Password web non recuperabile. Usa --web-password-stdin con la password su stdin.')
Path(sys.argv[1]).write_text(json.dumps({'password_hash': generate_password_hash(password)}))
MIGRATEPY
fi

cat > "$RUNTIME_WORK/runtime.py" <<'RUNTIMEPY'
#!/usr/bin/env python3
"""Unico controller per CLI e web. Nessun rilevamento automatico di ripiego."""
import argparse
import configparser
from contextlib import contextmanager
from datetime import datetime
import fcntl
import glob
import io
import json
import os
from pathlib import Path
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time

CONFIG_DIR = Path('/etc/veraprox')
DEVICE_CONFIG = CONFIG_DIR / 'device.conf'
IMMICH_CONFIG = CONFIG_DIR / 'immich.json'
MOUNTPOINT = '/mnt/secure'
FILEBROWSER_SERVICE = 'veraprox-filebrowser.service'
QUANTUM_CONFIG = CONFIG_DIR / 'filebrowser-quantum' / 'config.yaml'
LOCK_PATH = '/run/lock/veraprox.lock'
RUN_DIR = Path('/run/veraprox')
WEB_LOGO = Path('/usr/local/share/veraprox/veraprox-logo.png')


class VolumeError(Exception):
    pass


def command(args, *, input_text=None, check=True, timeout=120):
    try:
        result = subprocess.run(args, input=input_text, capture_output=True, text=True,
                                timeout=timeout, env={**os.environ, 'LC_ALL': 'C'})
    except subprocess.TimeoutExpired as exc:
        raise VolumeError('Operazione troppo lunga: verifica lo stato prima di riprovare.') from exc
    except OSError as exc:
        raise VolumeError(f'Strumento non disponibile: {args[0]}') from exc
    if check and result.returncode:
        # Non includere stdin (password) e non mostrare output di comandi con segreti.
        raise VolumeError(f'Operazione non riuscita: {args[0]} (codice {result.returncode}).')
    return result


@contextmanager
def operation_lock():
    with open(LOCK_PATH, 'a') as handle:
        os.chmod(LOCK_PATH, 0o600)
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise VolumeError('Un’altra operazione sul volume è già in corso.') from exc
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def protected_read(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
        raise VolumeError(f'Configurazione non protetta: {path}. Richiesti root e permessi 600.')
    return path.read_text(encoding='utf-8')


def atomic_write(path, text):
    CONFIG_DIR.mkdir(mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.veraprox-')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_device():
    if not DEVICE_CONFIG.exists():
        raise VolumeError('Dispositivo non configurato. Esegui veraprox-device.sh.')
    parser = configparser.ConfigParser(interpolation=None)
    parser.read_string(protected_read(DEVICE_CONFIG))
    device = parser.get('volume', 'device', fallback='')
    if parser.get('volume', 'mountpoint', fallback='') != MOUNTPOINT:
        raise VolumeError('Punto di montaggio non valido nella configurazione.')
    if not device.startswith(('/dev/disk/by-partuuid/', '/dev/disk/by-id/')):
        raise VolumeError('Serve un percorso stabile by-partuuid o by-id.')
    return device


def block_devices():
    data = command(['lsblk', '--json', '--list', '--paths', '--bytes', '--output',
                    'NAME,TYPE,SIZE,MODEL,SERIAL,PARTUUID,FSTYPE,MOUNTPOINTS,PKNAME'])
    return json.loads(data.stdout)['blockdevices']


def stable_path(entry, devices):
    name = os.path.realpath(entry['name'])
    partuuid = entry.get('partuuid')
    if partuuid:
        if sum(d.get('partuuid') == partuuid for d in devices) != 1:
            raise VolumeError('PARTUUID duplicato: scollega il disco clonato prima di configurare.')
        path = '/dev/disk/by-partuuid/' + partuuid
        if os.path.realpath(path) == name and os.path.exists(path):
            return path
    for path in sorted(glob.glob('/dev/disk/by-id/*')):
        if os.path.realpath(path) == name and os.path.exists(path):
            return path
    raise VolumeError('Il dispositivo non ha un identificativo stabile disponibile.')


def candidates():
    devices = block_devices()
    by_name = {d['name']: d for d in devices}
    blocked = set()
    # Esclude anche il disco padre di filesystem montati, swap e dispositivi attivi.
    for entry in devices:
        holders = Path('/sys/class/block') / Path(entry['name']).name / 'holders'
        if any(entry.get('mountpoints') or []) or (holders.exists() and any(holders.iterdir())):
            name = entry['name']
            while name and name not in blocked:
                blocked.add(name)
                name = by_name.get(name, {}).get('pkname')
    parents = {d.get('pkname') for d in devices}
    available = []
    for entry in devices:
        parent = entry.get('pkname')
        if entry['type'] not in ('disk', 'part') or entry['name'] in blocked or parent in blocked:
            continue
        if entry['type'] == 'disk' and entry['name'] in parents:
            continue  # Disco con partizioni: si sceglie la singola partizione.
        if entry.get('fstype'):
            continue  # Non proporre filesystem in chiaro, LUKS, RAID o swap.
        try:
            path = stable_path(entry, devices)
        except VolumeError:
            continue
        disk = by_name.get(parent, entry)
        available.append({'device': path, 'name': entry['name'],
                          'size': round(int(entry.get('size') or 0) / 1024**3, 2),
                          'model': (disk.get('model') or '').strip(),
                          'serial': (disk.get('serial') or '').strip()})
    return available


def resolve_device(device):
    if not os.path.exists(device) or not stat.S_ISBLK(os.stat(device).st_mode):
        raise VolumeError('Il dispositivo configurato è assente o non è un dispositivo a blocchi.')
    resolved = os.path.realpath(device)
    if device.startswith('/dev/disk/by-partuuid/'):
        identifier = Path(device).name
        if sum(d.get('partuuid') == identifier for d in block_devices()) != 1:
            raise VolumeError('PARTUUID assente o duplicato: montaggio rifiutato.')
    return resolved


def assert_available(device):
    resolved = resolve_device(device)
    if not any(os.path.realpath(d['name']) == resolved for d in candidates()):
        raise VolumeError('Dispositivo occupato, filesystem in chiaro o disco di sistema: operazione rifiutata.')
    return resolved


def set_device(device):
    with operation_lock():
        if os.path.ismount(MOUNTPOINT):
            raise VolumeError('Smonta il volume prima di cambiare dispositivo.')
        choices = {d['device'] for d in candidates()}
        if device not in choices:
            raise VolumeError('Selezione non più disponibile. Aggiorna l’elenco e riprova.')
        assert_available(device)
        parser = configparser.ConfigParser(interpolation=None)
        parser['volume'] = {'device': device, 'mountpoint': MOUNTPOINT}
        output = io.StringIO()
        parser.write(output)
        atomic_write(DEVICE_CONFIG, output.getvalue())


def mounted_device():
    if not os.path.ismount(MOUNTPOINT):
        return None
    result = command(['veracrypt', '--text', '--list', MOUNTPOINT], check=False)
    if result.returncode:
        raise VolumeError('/mnt/secure è occupato da un montaggio non riconosciuto da VeraCrypt.')
    # La lista testuale contiene slot, percorso volume, device virtuale e mountpoint.
    for line in result.stdout.splitlines():
        fields = line.split()
        if MOUNTPOINT in fields:
            paths = [field for field in fields if field.startswith('/dev/')]
            if paths:
                return os.path.realpath(paths[0])
    raise VolumeError('Impossibile verificare il dispositivo montato. Nessun servizio verrà avviato.')


def check_mounted():
    device = resolve_device(load_device())
    if mounted_device() != device:
        raise VolumeError('Il volume configurato non è montato in /mnt/secure.')


def filebrowser_installed():
    return Path('/etc/systemd/system/' + FILEBROWSER_SERVICE).exists()


def prepare_quantum():
    # Utilizzato anche da ExecStartPre: mai creare cache sotto un mountpoint vuoto.
    check_mounted()
    config = json.loads(protected_read(QUANTUM_CONFIG))
    private = Path(MOUNTPOINT) / '.veraprox-quantum'
    if config['server']['cacheDir'] != str(private / 'cache'):
        raise VolumeError('Percorso cache Quantum non valido.')
    sources = config['server']['sources']
    if len(sources) != 1 or sources[0]['path'] != MOUNTPOINT:
        raise VolumeError('Quantum deve esporre soltanto il volume configurato.')
    for path in (private, private / 'cache', private / 'tmp'):
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            raise VolumeError('Directory Quantum non sicura: collegamenti simbolici non consentiti.')
        path.mkdir(mode=0o700, exist_ok=True)
        if path.resolve().parent not in (Path(MOUNTPOINT).resolve(), private.resolve()):
            raise VolumeError('Directory Quantum fuori dal volume.')


def start_filebrowser():
    if filebrowser_installed():
        quantum = QUANTUM_CONFIG.exists()
        if quantum:
            prepare_quantum()
        command(['systemctl', 'start', FILEBROWSER_SERVICE])
        for _ in range(60):
            if command(['systemctl', 'is-active', '--quiet', FILEBROWSER_SERVICE], check=False).returncode == 0:
                # Verifica che il processo HTTP risponda, non soltanto lo stato systemd.
                from urllib.request import urlopen
                try:
                    with urlopen('http://127.0.0.1:8080/' + ('health' if quantum else ''), timeout=1) as response:
                        if response.status == 200:
                            return
                except OSError:
                    pass
            time.sleep(0.25)
        raise VolumeError('Volume montato, ma FileBrowser non risponde. Controlla journalctl -u veraprox-filebrowser.')


def immich_settings():
    if not IMMICH_CONFIG.exists():
        return None
    return json.loads(protected_read(IMMICH_CONFIG))


def compose_base(settings):
    directory = Path(settings['directory']).resolve()
    if not directory.is_relative_to(Path(MOUNTPOINT)):
        raise VolumeError('Il progetto Immich deve essere all’interno di /mnt/secure.')
    compose = directory / settings['file']
    if not compose.is_file() or not (directory / '.env').is_file():
        raise VolumeError('Compose o .env di Immich non disponibili sul volume montato.')
    return ['docker', 'compose', '--project-directory', str(directory), '-f', str(compose)]


def guarded_compose(settings):
    check_mounted()
    base = compose_base(settings)
    # Non scrive la configurazione completa: potrebbe contenere password del DB.
    result = command(base + ['config', '--format', 'json'])
    config = json.loads(result.stdout)
    guard = {'services': {}}
    for name, service in config['services'].items():
        update = {'restart': 'no'}
        volumes = []
        for volume in service.get('volumes', []):
            if volume.get('type') == 'bind':
                source = Path(volume['source'])
                if not source.exists():
                    raise VolumeError(f'Percorso Immich assente: {source}. Correggi il Compose prima dell’avvio.')
                if volume['target'] == '/var/lib/postgresql/data':
                    fs = command(['findmnt', '--noheadings', '--output', 'FSTYPE', '--target', str(source)]).stdout.strip()
                    if fs in ('fuseblk', 'ntfs', 'ntfs3', 'exfat', 'vfat', 'cifs', 'nfs', 'nfs4'):
                        raise VolumeError('PostgreSQL richiede storage locale con permessi Unix: il percorso attuale non è adatto.')
                safe_volume = dict(volume)
                safe_volume['bind'] = {**volume.get('bind', {}), 'create_host_path': False}
                volumes.append(safe_volume)
        if volumes:
            update['volumes'] = volumes
        guard['services'][name] = update
    directory = RUN_DIR
    directory.mkdir(mode=0o700, exist_ok=True)
    path = directory / 'immich-guard.json'
    path.write_text(json.dumps(guard))
    os.chmod(path, 0o600)
    return base + ['-f', str(path)]


def start_immich():
    settings = immich_settings()
    if settings:
        # Non aggiorna immagini né migra intenzionalmente la versione configurata.
        command(guarded_compose(settings) + ['up', '-d', '--no-build', '--pull', 'never'], timeout=300)


def active_docker_users():
    if not shutil.which('docker'):
        return []
    ids = command(['docker', 'ps', '--quiet'], check=False)
    if ids.returncode:
        if command(['systemctl', 'is-active', '--quiet', 'docker'], check=False).returncode == 0:
            raise VolumeError('Docker è attivo ma non interrogabile: impossibile verificare lo smontaggio.')
        return []
    if not ids.stdout.strip():
        return []
    containers = json.loads(command(['docker', 'inspect', *ids.stdout.split()]).stdout)
    users = []
    for container in containers:
        for mount in container.get('Mounts', []):
            source = Path(mount.get('Source') or '/').resolve()
            if source == Path(MOUNTPOINT) or source.is_relative_to(Path(MOUNTPOINT)):
                users.append(container['Name'].lstrip('/'))
                break
    return users


def mount_volume(password=None, pim='0', readonly=False):
    with operation_lock():
        device = load_device()
        if os.path.ismount(MOUNTPOINT):
            check_mounted()
        else:
            assert_available(device)
            target = Path(MOUNTPOINT)
            if target.is_symlink():
                raise VolumeError('/mnt/secure non può essere un collegamento simbolico.')
            target.mkdir(mode=0o700, exist_ok=True)
            if any(target.iterdir()):
                raise VolumeError('/mnt/secure contiene file a volume smontato. Verifica prima di coprirli con il montaggio.')
            args = ['veracrypt', '--text', '--mount', device, MOUNTPOINT]
            if password is None:
                result = subprocess.run(args)  # VeraCrypt richiede password/PIM/keyfile al terminale.
                if result.returncode:
                    raise VolumeError(f'Montaggio VeraCrypt fallito (codice {result.returncode}).')
            else:
                if not password or '\n' in password or '\r' in password or '\x00' in password:
                    raise VolumeError('Password vuota o con caratteri di controllo non supportati dal prompt stdin.')
                if not pim.isdecimal() or len(pim) > 7:
                    raise VolumeError('PIM non valido.')
                # La web app supporta volumi normali o nascosti, senza keyfile.
                # La sola lettura impedisce di danneggiare un eventuale volume nascosto nell’outer.
                args += ['--non-interactive', '--stdin', '--keyfiles=', '--pim=' + pim,
                         '--protect-hidden=no']
                if readonly:
                    args += ['--mount-options=readonly']
                command(args, input_text=password + '\n', timeout=300)
            check_mounted()
        options = command(['findmnt', '--noheadings', '--output', 'OPTIONS', '--mountpoint', MOUNTPOINT]).stdout.strip().split(',')
        if readonly and 'ro' not in options:
            raise VolumeError('Il volume è montato in scrittura. Smontalo prima di richiedere la sola lettura.')
        if 'ro' in options:
            # Non avviare applicazioni che scrivono sul volume in sola lettura.
            return 'Volume montato in sola lettura; servizi non avviati.'
        start_filebrowser()
        start_immich()
        return 'Volume montato e servizi configurati avviati.'


def unmount_volume():
    with operation_lock():
        if not os.path.ismount(MOUNTPOINT):
            return 'Volume già smontato.'
        check_mounted()
        settings = immich_settings()
        if settings:
            command(compose_base(settings) + ['stop', '--timeout', '60'], timeout=180)
        users = active_docker_users()
        if users:
            raise VolumeError('Smontaggio bloccato: arresta prima i container ' + ', '.join(users))
        if filebrowser_installed():
            command(['systemctl', 'stop', FILEBROWSER_SERVICE])
        command(['sync'])
        command(['veracrypt', '--text', '--non-interactive', '--dismount', MOUNTPOINT], timeout=180)
        if os.path.ismount(MOUNTPOINT):
            raise VolumeError('Il volume è ancora montato. Verifica i processi che lo utilizzano.')
        return 'Volume smontato.'


def configure_immich(directory):
    with operation_lock():
        check_mounted()
        path = Path(directory).resolve()
        names = ('compose.yaml', 'compose.yml', 'docker-compose.yml', 'docker-compose.yaml')
        name = next((name for name in names if (path / name).is_file()), None)
        if not name:
            raise VolumeError('File Compose non trovato.')
        settings = {'directory': str(path), 'file': name}
        args = guarded_compose(settings)
        # Se esistono già container, elimina il riavvio automatico senza ricrearli.
        ids = command(args + ['ps', '--all', '--quiet']).stdout.split()
        if ids:
            command(['docker', 'update', '--restart=no', *ids])
        atomic_write(IMMICH_CONFIG, json.dumps(settings))


def configure_cli(device=None):
    if os.path.ismount(MOUNTPOINT):
        raise VolumeError('Smonta il volume prima di configurare il dispositivo.')
    items = candidates()
    if not items:
        raise VolumeError('Nessun dispositivo non occupato con identificativo stabile. Verifica passthrough e lsblk.')
    if device:
        resolved = os.path.realpath(device)
        choice = next((d for d in items if os.path.realpath(d['name']) == resolved), None)
        if not choice:
            raise VolumeError('Il dispositivo indicato non è selezionabile.')
    else:
        descriptions = [f"{d['name']} — {d['size']} GiB — {d['model']} — seriale {d['serial']}" for d in items]
        if shutil.which('whiptail') and sys.stdin.isatty():
            args = ['whiptail', '--title', 'VeraProx - Dispositivo', '--menu',
                    'Scegli la partizione cifrata. L’elenco non certifica che contenga VeraCrypt.', '22', '100', '12']
            for index, description in enumerate(descriptions, 1):
                args += [str(index), description]
            with tempfile.TemporaryFile(mode='w+') as selected:
                result = subprocess.run(args, stderr=selected)
                if result.returncode:
                    raise VolumeError('Selezione annullata.')
                selected.seek(0)
                answer = selected.read().strip()
        else:
            for index, description in enumerate(descriptions, 1):
                print(f'{index}. {description}')
            answer = input('Numero del dispositivo (invio per annullare): ').strip()
        if not answer.isdecimal() or not 1 <= int(answer) <= len(items):
            raise VolumeError('Selezione annullata o non valida.')
        choice = items[int(answer) - 1]
        confirmation = input(f"Salvare {choice['device']} ({choice['name']})? Scrivi SI: ")
        if confirmation != 'SI':
            raise VolumeError('Configurazione annullata.')
    set_device(choice['device'])
    print('Dispositivo salvato: ' + choice['device'])


def create_web_app():
    from flask import Flask, jsonify, redirect, render_template_string, request, send_file, session, url_for
    from werkzeug.security import check_password_hash
    app = Flask(__name__)
    app.secret_key = secrets.token_bytes(32)
    app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE='Strict', MAX_CONTENT_LENGTH=8192)
    password_hash = json.loads(protected_read(CONFIG_DIR / 'web.json'))['password_hash']
    logs = []
    log_lock = threading.Lock()
    failures = {}
    failure_lock = threading.Lock()

    def add_log(message):
        with log_lock:
            logs.append({'timestamp': datetime.now().strftime('%H:%M:%S'), 'message': str(message)})
            del logs[:-100]

    @app.before_request
    def protect():
        if request.method == 'POST':
            token = session.get('csrf', '')
            if not token or not secrets.compare_digest(token, request.form.get('csrf', '')):
                return 'Richiesta non valida. Ricarica la pagina.', 400
        if request.path not in ('/', '/login', '/veraprox-logo.png') and not session.get('authenticated'):
            return redirect(url_for('home'))

    def page(error=None):
        session.setdefault('csrf', secrets.token_urlsafe(32))
        device = ''
        items = []
        authenticated = session.get('authenticated', False)
        if authenticated:
            try:
                device = load_device()
            except VolumeError as exc:
                error = error or str(exc)
            if not os.path.ismount(MOUNTPOINT):
                try:
                    items = candidates()
                except VolumeError as exc:
                    error = error or str(exc)
        with log_lock:
            entries = list(reversed(logs[-20:])) if authenticated else []
        return render_template_string(HTML, error=error, device=device,
                                      mounted=os.path.ismount(MOUNTPOINT), candidates=items,
                                      filebrowser=filebrowser_installed(), logs=entries)

    @app.get('/')
    def home():
        return page()

    @app.get('/veraprox-logo.png')
    def web_logo():
        # Un solo asset pubblico, non una directory di file navigabile.
        return send_file(WEB_LOGO, mimetype='image/png', max_age=86400)

    @app.post('/login')
    def login():
        address = request.remote_addr or ''
        now = time.monotonic()
        with failure_lock:
            attempts = [t for t in failures.get(address, []) if now - t < 300]
            failures[address] = attempts
            if len(attempts) >= 10:
                return page(error='Troppi tentativi. Attendi cinque minuti.'), 429
            attempts.append(now)
        if check_password_hash(password_hash, request.form.get('admin_password', '')):
            with failure_lock:
                failures.pop(address, None)
            session.clear()
            session['authenticated'] = True
            session['csrf'] = secrets.token_urlsafe(32)
            return redirect(url_for('home'))
        return page(error='Password errata.'), 401

    @app.post('/logout')
    def logout():
        session.clear()
        return redirect(url_for('home'))

    def action(function):
        try:
            message = function()
            add_log(message)
            return page()
        except (VolumeError, OSError, ValueError, configparser.Error) as exc:
            # Non riporta exception subprocess contenenti stdin o credenziali.
            message = str(exc) if isinstance(exc, VolumeError) else 'Configurazione non valida o operazione non disponibile.'
            add_log(message)
            return page(error=message), 409

    @app.post('/device')
    def device():
        def select():
            set_device(request.form.get('device', ''))
            return 'Dispositivo configurato.'
        return action(select)

    @app.post('/mount')
    def mount():
        return action(lambda: mount_volume(request.form.get('password', ''),
                                           request.form.get('pim', '0'),
                                           readonly=request.form.get('readonly') == 'yes'))

    @app.post('/unmount')
    def unmount():
        return action(unmount_volume)

    @app.get('/get-log')
    def get_log():
        with log_lock:
            return jsonify(logs=list(reversed(logs[-20:])))

    @app.post('/clear-log')
    def clear_log():
        with log_lock:
            logs.clear()
        return redirect(url_for('home'))

    return app


HTML = '''<!DOCTYPE html>
<html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>VeraProx</title><link rel="icon" type="image/png" href="{{ url_for('web_logo') }}"><style>
*{box-sizing:border-box}body{font-family:system-ui,sans-serif;background:linear-gradient(135deg,#667eea,#764ba2);margin:0;min-height:100vh;padding:12px;display:grid;place-items:center}
main{background:white;border-radius:16px;padding:20px;width:100%;max-width:450px}h1{text-align:center;font-size:1.5rem;margin:0 0 14px}input,select,button{font:inherit;width:100%;padding:10px;border-radius:8px;margin:5px 0;border:1px solid #ccc}button{cursor:pointer;background:#2863ba;color:white;border:0}.danger{background:#b52c3a}.mount{background:#218838}.muted{color:#555;font-size:.85rem}.message{padding:10px;border-radius:8px;background:#eef1f5;margin:10px 0}.error{background:#f8d7da}.success{background:#d4edda}.device{overflow-wrap:anywhere;font-family:monospace;font-size:.8rem;margin:6px 0}details{margin:10px 0}summary{cursor:pointer;font-size:.9rem}label{display:block;margin-top:6px}.check input{width:auto}li{overflow-wrap:anywhere}a{color:#2455a5}
.logs{background:#f8f9fa;border-radius:8px;padding:10px;margin:14px 0 8px}.log-header{display:flex;align-items:center;justify-content:space-between;gap:8px;font-size:.85rem}.clear-log{width:auto;padding:5px 8px;margin:0;font-size:.75rem;background:#6c757d}.log-list{list-style:none;padding:0;margin:8px 0 0;min-height:48px;max-height:160px;overflow-y:auto;font:12px/1.5 monospace}.log-list li{padding:4px 0;border-bottom:1px solid #e7e7e7}
h1{display:flex;align-items:center;justify-content:center;gap:10px}.brand-logo{display:block;width:36px;height:36px;border-radius:8px;flex-shrink:0}
</style></head><body><main><h1><img class="brand-logo" src="{{ url_for('web_logo') }}" width="36" height="36" alt="">VeraProx</h1>
{% if error %}<p class="message error">{{ error }}</p>{% endif %}
{% if session.authenticated %}
<p class="message {{ 'success' if mounted else '' }}">Volume {{ 'montato' if mounted else 'smontato' }}</p>
<p class="device" title="Dispositivo configurato">{{ device or 'Dispositivo non configurato' }}</p>
{% if mounted %}
{% if filebrowser %}<p><a id="filebrowser-link" target="_blank" rel="noopener">Apri FileBrowser</a></p>{% endif %}
<form method="post" action="/unmount"><input type="hidden" name="csrf" value="{{ session.csrf }}"><button class="danger">Smonta volume</button></form>
{% else %}
<details {{ 'open' if not device else '' }}><summary>Scegli o cambia dispositivo</summary>
<p class="muted">Sono esclusi i dischi occupati e i filesystem riconoscibili. Verifica modello, seriale e partizione: l’elenco non certifica che contengano VeraCrypt.</p>
<form method="post" action="/device"><input type="hidden" name="csrf" value="{{ session.csrf }}">
<select name="device" required><option value="">Seleziona una partizione</option>{% for item in candidates %}
<option value="{{ item.device }}">{{ item.name }} | {{ item.size }} GiB | {{ item.model }} | {{ item.serial }}</option>{% endfor %}</select>
<button>Salva dispositivo</button></form></details>
{% if device %}<form method="post" action="/mount"><input type="hidden" name="csrf" value="{{ session.csrf }}">
<label>Password VeraCrypt<input type="password" name="password" required autocomplete="off"></label>
<details><summary>Opzioni avanzate</summary>
<label>PIM<input type="number" name="pim" min="0" max="9999999" value="0" required></label>
<p class="muted">Lascia 0 se non hai impostato un PIM personalizzato quando hai creato il volume.</p>
<label class="check"><input type="checkbox" name="readonly" value="yes"> Sola lettura (senza avviare i servizi)</label></details>
<p class="muted">Keyfile o volume nascosto da proteggere? Usa il terminale.</p>
<button class="mount">Monta volume</button></form>{% endif %}
{% endif %}
<section class="logs" aria-label="Log operazioni"><div class="log-header"><span>Log operazioni</span>
<form method="post" action="/clear-log"><input type="hidden" name="csrf" value="{{ session.csrf }}"><button class="clear-log">Pulisci</button></form></div>
<ul id="log-list" class="log-list" aria-live="polite">{% for log in logs %}<li>{{ log.timestamp }} — {{ log.message }}</li>{% else %}<li class="muted">Nessuna operazione registrata.</li>{% endfor %}</ul></section>
<form method="post" action="/logout"><input type="hidden" name="csrf" value="{{ session.csrf }}"><button>Esci</button></form>
{% else %}<form method="post" action="/login"><input type="hidden" name="csrf" value="{{ session.csrf }}">
<label>Password amministratore<input type="password" name="admin_password" required autocomplete="current-password"></label><button>Accedi</button></form>{% endif %}
</main><script>
const link=document.getElementById('filebrowser-link');if(link){link.href='http://'+window.location.hostname+':8080';}
const logList=document.getElementById('log-list');
if(logList){
  let previousLog='';
  let refreshing=false;
  async function refreshLog(){
    if(refreshing||document.hidden)return;
    refreshing=true;
    try{
      const response=await fetch('/get-log',{cache:'no-store'});
      if(!response.ok||!response.headers.get('content-type')?.includes('application/json'))return;
      const data=await response.json();
      const snapshot=JSON.stringify(data.logs);
      if(snapshot===previousLog)return;
      previousLog=snapshot;
      const fragment=document.createDocumentFragment();
      for(const log of data.logs){const row=document.createElement('li');row.textContent=log.timestamp+' — '+log.message;fragment.append(row);}
      if(!data.logs.length){const row=document.createElement('li');row.className='muted';row.textContent='Nessuna operazione registrata.';fragment.append(row);}
      logList.replaceChildren(fragment);
    }catch(error){/* Mantieni visibili le ultime operazioni se la rete non risponde. */}
    finally{refreshing=false;}
  }
  setInterval(refreshLog,3000);
}
</script></body></html>'''


def main():
    if os.geteuid() != 0:
        raise VolumeError('Eseguire come root.')
    parser = argparse.ArgumentParser(description='VeraProx: gestione del volume configurato')
    parser.add_argument('action', choices=['configure', 'mount', 'unmount', 'check-mounted', 'prepare-quantum', 'status',
                                          'web', 'configure-immich', 'disable-immich'])
    parser.add_argument('path', nargs='?')
    args = parser.parse_args()
    if args.action == 'configure':
        configure_cli(args.path)
    elif args.action == 'mount':
        if not DEVICE_CONFIG.exists():
            configure_cli()
        print(mount_volume())
    elif args.action == 'unmount':
        print(unmount_volume())
    elif args.action == 'check-mounted':
        check_mounted()
    elif args.action == 'prepare-quantum':
        prepare_quantum()
    elif args.action == 'status':
        print('Dispositivo: ' + load_device())
        print('Volume: ' + ('montato' if os.path.ismount(MOUNTPOINT) else 'smontato'))
        if os.path.ismount(MOUNTPOINT):
            check_mounted()
        settings = immich_settings()
        print('Immich: ' + (settings['directory'] if settings else 'integrazione disabilitata'))
    elif args.action == 'configure-immich':
        if not args.path:
            raise VolumeError('Specifica la directory del progetto Immich.')
        configure_immich(args.path)
        print('Integrazione Immich configurata. Nessun container avviato.')
    elif args.action == 'disable-immich':
        with operation_lock():
            if os.path.ismount(MOUNTPOINT):
                raise VolumeError('Smonta il volume prima di disabilitare l’integrazione.')
            IMMICH_CONFIG.unlink(missing_ok=True)
        print('Integrazione Immich disabilitata.')
    elif args.action == 'web':
        create_web_app().run(host='0.0.0.0', port=5000, debug=False, threaded=True)


if __name__ == '__main__':
    try:
        main()
    except (VolumeError, OSError, ValueError, configparser.Error) as exc:
        print(f'Errore: {exc}', file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        print('Operazione annullata.', file=sys.stderr)
        sys.exit(130)
RUNTIMEPY

python3 -m py_compile "$RUNTIME_WORK/runtime.py"
systemctl stop secure-webapp.service 2>/dev/null || true
# Ferma soltanto i vecchi FileBrowser avviati sul mountpoint di VeraProx.
python3 - <<'STOPLEGACYPY'
import os
from pathlib import Path
import signal
for proc in Path('/proc').iterdir():
    if not proc.name.isdecimal():
        continue
    try:
        args = (proc / 'cmdline').read_bytes().split(b'\0')
        if args and Path(os.fsdecode(args[0])).name == 'filebrowser' and b'/mnt/secure' in args:
            os.kill(int(proc.name), signal.SIGTERM)
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        pass
STOPLEGACYPY
install -m 600 "$RUNTIME_WORK/web.json" /etc/veraprox/web.json
install -m 644 "$RUNTIME_WORK/runtime.py" /usr/local/lib/veraprox/runtime.py
install -d -m 755 /usr/local/share/veraprox
install -m 644 "$RUNTIME_WORK/veraprox-logo.png" /usr/local/share/veraprox/veraprox-logo.png

cat > /usr/local/bin/mount-secure.sh <<'MOUNTCLI'
#!/usr/bin/env bash
exec /usr/bin/python3 /usr/local/lib/veraprox/runtime.py mount "$@"
MOUNTCLI
cat > /usr/local/bin/umount-secure.sh <<'UNMOUNTCLI'
#!/usr/bin/env bash
exec /usr/bin/python3 /usr/local/lib/veraprox/runtime.py unmount "$@"
UNMOUNTCLI
cat > /usr/local/bin/veraprox-device.sh <<'DEVICECLI'
#!/usr/bin/env bash
exec /usr/bin/python3 /usr/local/lib/veraprox/runtime.py configure "$@"
DEVICECLI
cat > /usr/local/bin/veraprox-immich.sh <<'IMMICHCLI'
#!/usr/bin/env bash
exec /usr/bin/python3 /usr/local/lib/veraprox/runtime.py configure-immich "$@"
IMMICHCLI
cat > /usr/local/bin/secure-webapp.py <<'WEBCLI'
#!/usr/bin/env python3
import os
os.execv('/usr/bin/python3', ['/usr/bin/python3', '/usr/local/lib/veraprox/runtime.py', 'web'])
WEBCLI
chmod 755 /usr/local/bin/mount-secure.sh /usr/local/bin/umount-secure.sh /usr/local/bin/veraprox-device.sh /usr/local/bin/veraprox-immich.sh /usr/local/bin/secure-webapp.py

if [ -x /usr/local/bin/filebrowser-quantum ] && [ -f /etc/veraprox/filebrowser-quantum/config.yaml ]; then
  # Riparazione mirata: niente APT, download o reset account.
  # v1.5.6 tratta la regola root come esclusione degli attributi delle sottocartelle.
  # L'accesso al filesystem host viene limitato dal servizio, non da quella regola.
  command -v systemd-run >/dev/null || { echo 'systemd-run necessario per verificare il servizio Quantum.' >&2; exit 1; }
  cat > "$RUNTIME_WORK/quantum-repair.py" <<'QUANTUMFIXPY'
import base64
import json
import os
from pathlib import Path
import secrets
import socket
import stat
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, build_opener, ProxyHandler


def correct_settings(config):
    changed = False
    bad_rule = {'folderPath': '/', 'ignoreSymlinks': True}
    for source in config['server']['sources']:
        rules = source.get('config', {}).get('rules', [])
        corrected = [rule for rule in rules if rule != bad_rule]
        if corrected != rules:
            source['config']['rules'] = corrected
            changed = True
    listing = config.get('userDefaults', {}).get('listing', {})
    if listing.get('viewMode') == 'grid':
        listing['viewMode'] = 'gallery'
        changed = True
    return changed


def repair_config(path):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
        raise ValueError('Configurazione Quantum non sicura: richiesto file regolare root 600.')
    config = json.loads(path.read_text(encoding='utf-8'))
    changed = correct_settings(config)
    if changed:
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                    prefix='.config-repair-', delete=False) as output:
                temporary = Path(output.name)
                os.chmod(temporary, 0o600)
                json.dump(config, output, indent=2)
                output.write('\n')
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()
    return changed


def prepare_service_root(path):
    path = Path(path)
    for directory in (path.parent, path):
        if directory.is_symlink():
            raise ValueError('Root servizio Quantum: collegamenti simbolici non consentiti.')
        directory.mkdir(mode=0o700, exist_ok=True)
        info = directory.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError('Root servizio Quantum: directory non sicura.')


def isolation_properties(unit):
    permitted = {'RootDirectory', 'BindReadOnlyPaths', 'NoNewPrivileges',
                 'CapabilityBoundingSet', 'PrivateDevices', 'ProtectHome',
                 'ProtectSystem', 'InaccessiblePaths', 'UMask'}
    properties = {}
    for line in Path(unit).read_text().splitlines():
        key, separator, value = line.partition('=')
        if separator and key in permitted:
            properties[key] = (properties[key] + ' ' + value).strip() if key in properties else value
    return properties


def verify_isolated_previews(config_path, unit_path):
    # Nessun file/account reale: media sintetici, DB separato e porta solo localhost.
    with tempfile.TemporaryDirectory(prefix='veraprox-quantum-check-', dir='/var/tmp') as directory:
        work = Path(directory)
        media = work / 'media'
        nested = media / 'sample'
        nested.mkdir(parents=True)
        settings = work / 'settings'
        settings.mkdir()
        private = media / '.veraprox-quantum'
        (private / 'cache').mkdir(parents=True)
        (private / 'tmp').mkdir()
        png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2XcAAAAASUVORK5CYII=')
        (nested / 'sample.png').write_bytes(png)
        outside = work / 'outside'
        outside.mkdir()
        (outside / 'sample.png').write_bytes(png)
        (media / 'outside-link').symlink_to(outside, target_is_directory=True)
        subprocess.run(['/usr/bin/ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
            '-f', 'lavfi', '-i', 'color=c=red:s=64x64:r=5', '-t', '1', '-c:v', 'mpeg4',
            str(nested / 'sample.mp4')], check=True, timeout=20, capture_output=True)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        config = json.loads(Path(config_path).read_text())
        correct_settings(config)
        config['server'].update(listen='127.0.0.1', port=port,
            database='/etc/veraprox/filebrowser-quantum/quantum.db',
            cacheDir='/mnt/secure/.veraprox-quantum/cache', disableUpdateCheck=True)
        config['server']['sources'] = [{'path': '/mnt/secure', 'name': 'Volume',
            'config': {'defaultEnabled': True, 'private': True, 'defaultUserScope': '/',
                       'rules': [{'folderName': '.veraprox-quantum'}, {'folderName': '@eaDir'}]}}]
        seed = secrets.token_urlsafe(32)
        config['auth'] = {'adminUsername': 'admin', 'adminPassword': seed,
            'methods': {'password': {'enabled': True, 'signup': False}}}
        config['integrations']['media']['ffmpegPath'] = '/usr/bin'
        (settings / 'config.yaml').write_text(json.dumps(config), encoding='utf-8')
        os.chmod(settings / 'config.yaml', 0o600)
        name = 'veraprox-quantum-check-' + secrets.token_hex(6) + '.service'
        properties = isolation_properties(unit_path)
        properties.update(BindPaths=f'{media}:/mnt/secure {settings}:/etc/veraprox/filebrowser-quantum',
            ReadWritePaths='/mnt/secure /etc/veraprox/filebrowser-quantum',
            WorkingDirectory='/etc/veraprox/filebrowser-quantum', RuntimeMaxSec='120')
        args = ['systemd-run', '--quiet', '--collect', '--service-type=exec', '--unit=' + name]
        for key, value in properties.items():
            args.append('--property=' + key + '=' + value)
        for key in ('TMPDIR', 'TMP', 'TEMP'):
            args.append('--setenv=' + key + '=/mnt/secure/.veraprox-quantum/tmp')
        args += ['/usr/local/bin/filebrowser-quantum', '-c', '/etc/veraprox/filebrowser-quantum/config.yaml']
        opener = build_opener(ProxyHandler({}))
        base = f'http://127.0.0.1:{port}'

        def get(path, token):
            return opener.open(Request(base + path, headers={'Authorization': 'Bearer ' + token}), timeout=10)

        try:
            subprocess.run(args, check=True, timeout=20, capture_output=True)
            for _ in range(80):
                try:
                    request = Request(base + '/api/auth/login?username=admin', method='POST',
                                      headers={'X-Password': quote(seed, safe='')})
                    with opener.open(request, timeout=1) as response:
                        token = response.read().decode().strip('"\n')
                    break
                except OSError:
                    time.sleep(0.25)
            else:
                raise RuntimeError('Quantum isolato non risponde.')
            with get('/api/resources?source=Volume&path=%2Fsample%2F', token) as response:
                listing = json.load(response)
            available = {item['name']: item['hasPreview'] for item in listing['files']}
            for filename in ('sample.png', 'sample.mp4'):
                if not available.get(filename):
                    raise RuntimeError('Anteprima di prova non disponibile.')
                with get('/api/resources/preview?source=Volume&path=%2Fsample%2F' + filename, token) as response:
                    if response.status != 200 or len(response.read()) < 50:
                        raise RuntimeError('Anteprima di prova non generata.')
            try:
                with get('/api/resources/preview?source=Volume&path=%2Foutside-link%2Fsample.png', token) as response:
                    if response.status == 200 and response.read():
                        raise RuntimeError('Il collegamento esterno non è isolato.')
            except HTTPError as error:
                if error.code not in (400, 403, 404, 415, 500):
                    raise
        finally:
            subprocess.run(['systemctl', 'stop', name], timeout=20, capture_output=True)
    print('Test locale VM riuscito: anteprime immagine/video e isolamento del collegamento esterno.')


if __name__ == '__main__':
    try:
        prepare_service_root(sys.argv[2])
        verify_isolated_previews(sys.argv[1], sys.argv[3])
        if repair_config(sys.argv[1]):
            print('Configurazione anteprime Quantum corretta; account conservati.')
    except Exception:
        print('Verifica Quantum fallita: riparazione del servizio non applicata. '
              'Controlla journalctl -u "veraprox-quantum-check-*" --no-pager -n 80.', file=sys.stderr)
        sys.exit(1)
QUANTUMFIXPY
  cat > "$RUNTIME_WORK/veraprox-filebrowser.service" <<'QUANTUMSERVICE'
[Unit]
Description=VeraProx FileBrowser Quantum (solo dopo il montaggio verificato)
After=network.target
ConditionPathIsMountPoint=/mnt/secure

[Service]
Type=simple
User=root
WorkingDirectory=/etc/veraprox/filebrowser-quantum
# Il controllo del vero mount deve vedere i dispositivi host, fuori dalla jail.
ExecStartPre=+/usr/bin/python3 /usr/local/lib/veraprox/runtime.py prepare-quantum
ExecStart=/usr/local/bin/filebrowser-quantum -c /etc/veraprox/filebrowser-quantum/config.yaml
RootDirectory=/var/lib/veraprox/quantum-root
RootDirectoryStartOnly=true
BindPaths=/mnt/secure /etc/veraprox/filebrowser-quantum
BindReadOnlyPaths=/usr/local/bin/filebrowser-quantum /usr/bin/ffmpeg /usr/bin/ffprobe /usr/lib /lib -/lib64
BindReadOnlyPaths=-/etc/ld.so.cache -/etc/localtime -/etc/passwd -/etc/group -/etc/nsswitch.conf -/etc/hosts -/etc/resolv.conf -/etc/ssl/certs
BindReadOnlyPaths=-/etc/fonts -/usr/share/fonts -/usr/share/fontconfig
Environment=TMPDIR=/mnt/secure/.veraprox-quantum/tmp
Environment=TMP=/mnt/secure/.veraprox-quantum/tmp
Environment=TEMP=/mnt/secure/.veraprox-quantum/tmp
Restart=on-failure
RestartSec=3
TimeoutStopSec=60
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/mnt/secure /etc/veraprox/filebrowser-quantum
# Non esporre processi e descrittori host tramite collegamenti sul volume.
InaccessiblePaths=-/proc -/sys
QUANTUMSERVICE
  python3 "$RUNTIME_WORK/quantum-repair.py" /etc/veraprox/filebrowser-quantum/config.yaml /var/lib/veraprox/quantum-root "$RUNTIME_WORK/veraprox-filebrowser.service"
  install -m 644 "$RUNTIME_WORK/veraprox-filebrowser.service" /etc/systemd/system/veraprox-filebrowser.service
elif command -v filebrowser >/dev/null && [ -f /etc/filebrowser/filebrowser.db ]; then
  # Compatibilità per chi aggiorna il solo runtime senza chiedere la migrazione.
  FILEBROWSER_BINARY=$(command -v filebrowser)
  cat > /etc/systemd/system/veraprox-filebrowser.service <<FBSERVICE
[Unit]
Description=VeraProx FileBrowser (solo dopo il montaggio verificato)
After=network.target
ConditionPathIsMountPoint=/mnt/secure

[Service]
Type=simple
User=root
WorkingDirectory=/etc/filebrowser
ExecStartPre=/usr/bin/python3 /usr/local/lib/veraprox/runtime.py check-mounted
ExecStart=$FILEBROWSER_BINARY -d /etc/filebrowser/filebrowser.db -r /mnt/secure -a 0.0.0.0 -p 8080
Restart=on-failure
RestartSec=3
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=true
FBSERVICE
fi

cat > /etc/systemd/system/secure-webapp.service <<'WEBSERVICE'
[Unit]
Description=VeraProx - gestione volume cifrato
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/veraprox/runtime.py web
Restart=on-failure
RestartSec=3
User=root
UMask=0077

[Install]
WantedBy=multi-user.target
WEBSERVICE

systemctl daemon-reload
systemctl disable veraprox-filebrowser.service >/dev/null 2>&1 || true
systemctl enable secure-webapp.service >/dev/null
systemctl restart secure-webapp.service
python3 - <<'HEALTHPY'
import time
from urllib.request import urlopen
for _ in range(20):
    try:
        with urlopen('http://127.0.0.1:5000/', timeout=2) as response:
            if response.status == 200:
                break
    except OSError:
        time.sleep(0.5)
else:
    raise SystemExit('La web app non risponde: controlla journalctl -u secure-webapp.')
HEALTHPY
echo "Runtime aggiornato. Credenziali web conservate; volume non montato."
echo "Configura il disco dalla pagina web oppure con: veraprox-device.sh"
echo "Montaggio: mount-secure.sh | Smontaggio: umount-secure.sh"
