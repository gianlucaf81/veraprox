#!/usr/bin/env bash

# ============================================
# post-install-veracrypt.sh
# Da eseguire DENTRO la VM Debian 12 dopo l'installazione.
# Installa VeraCrypt + FileBrowser + web app di mount/unmount.
#
# Lo script richiede direttamente nella VM il dispositivo USB, le password
# e l'eventuale installazione di FileBrowser.
# ============================================

set -Eeuo pipefail

YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
RD=$(echo "\033[01;31m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

SPINNER_PID=""

spinner() {
  local frames="/-\\|"
  local i=0
  while true; do
    i=$(( (i + 1) % 4 ))
    printf "\r %s %b" "${frames:$i:1}" "${YW}${SPINNER_MSG}...${CL}"
    sleep 0.1
  done
}

msg_info() {
  SPINNER_MSG="$1"
  spinner &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
}

msg_ok() {
  if [ -n "$SPINNER_PID" ]; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi
  printf "${BFR} ${CM} ${GN}%s${CL}\n" "$1"
}

msg_error() {
  if [ -n "$SPINNER_PID" ]; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi
  printf "${BFR} ${CROSS} ${RD}%s${CL}\n" "$1"
}

on_error() {
  local exit_code=$1
  local line_number=$2
  local failed_command=$3
  msg_error "Errore alla riga ${line_number} (codice ${exit_code}): ${failed_command}"
  exit "$exit_code"
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

if [ "$(id -u)" -ne 0 ]; then
  msg_error "Questo script deve essere eseguito come root."
  exit 1
fi

if ! command -v whiptail >/dev/null 2>&1 || ! command -v lsusb >/dev/null 2>&1; then
  msg_info "Installazione strumenti di configurazione"
  apt update -qq
  apt install -y -qq whiptail usbutils
  msg_ok "Strumenti di configurazione installati"
fi

WT_TITLE="VeraCrypt Post-Install"

USB_MENU_ITEMS=()
while IFS= read -r line; do
  ID=$(echo "$line" | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{4}')
  DESC=$(echo "$line" | sed -E 's/^.*ID [0-9a-fA-F]{4}:[0-9a-fA-F]{4} //')
  [ -n "$ID" ] && USB_MENU_ITEMS+=("$ID" "$DESC")
done < <(lsusb)

if [ "${#USB_MENU_ITEMS[@]}" -eq 0 ]; then
  msg_error "Nessun dispositivo USB rilevato nella VM. Verifica il passthrough in Proxmox."
  exit 1
fi

USB_ID=$(whiptail --backtitle "$WT_TITLE" --title "Dispositivo USB" --menu "Seleziona il dispositivo VeraCrypt passato alla VM" 20 70 10 "${USB_MENU_ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 1
USB_VENDOR="${USB_ID%%:*}"
USB_PRODUCT="${USB_ID##*:}"

if [ -z "${WEB_PASSWORD:-}" ]; then
  WEB_PASSWORD=$(whiptail --backtitle "$WT_TITLE" --passwordbox "Password interfaccia web admin" 8 58 --title "Credenziali" 3>&1 1>&2 2>&3) || exit 1
  WEB_PASSWORD=${WEB_PASSWORD:-password_web}
fi

if [ -z "${INSTALL_FB:-}" ]; then
  if whiptail --backtitle "$WT_TITLE" --title "FileBrowser" --yesno "Installare FileBrowser?" 8 58; then
    INSTALL_FB="s"
  else
    INSTALL_FB="n"
  fi
fi

if [ "$INSTALL_FB" = "s" ] && [ -z "${FB_PASSWORD:-}" ]; then
  FB_PASSWORD=$(whiptail --backtitle "$WT_TITLE" --passwordbox "Password FileBrowser admin" 8 58 --title "Credenziali" 3>&1 1>&2 2>&3) || exit 1
  FB_PASSWORD=${FB_PASSWORD:-filebrowser}
fi

if [ "$INSTALL_FB" != "s" ] && [ "$INSTALL_FB" != "n" ]; then
  msg_error "INSTALL_FB deve essere 's' oppure 'n'."
  exit 1
fi

FILEBROWSER_DB="/etc/filebrowser/filebrowser.db"
VERACRYPT_RELEASE_API="https://api.github.com/repos/veracrypt/VeraCrypt/releases/latest"
VERACRYPT_DEB_NAME=""

# ------------------------------------------------
# Aggiornamento sistema
# ------------------------------------------------
msg_info "Aggiornamento pacchetti di sistema"
apt update -qq && apt upgrade -y -qq
msg_ok "Sistema aggiornato"

msg_info "Installazione dipendenze"
apt install -y -qq curl wget usbutils secure-delete ntfs-3g fuse3 python3-flask
msg_ok "Dipendenze installate"

# ------------------------------------------------
# VeraCrypt
# ------------------------------------------------
msg_info "Ricerca dell'ultima versione stabile di VeraCrypt"
VERACRYPT_RELEASE_JSON=$(mktemp)
curl -fsSL --retry 3 "$VERACRYPT_RELEASE_API" -o "$VERACRYPT_RELEASE_JSON"

mapfile -t VERACRYPT_RELEASE < <(python3 - "$VERACRYPT_RELEASE_JSON" << 'PY'
import json
import sys

release = json.load(open(sys.argv[1], encoding="utf-8"))
version = release["tag_name"].removeprefix("VeraCrypt_")
deb_name = f"veracrypt-console-{version}-Debian-12-amd64.deb"
checksum_name = f"veracrypt-{version}-sha256sum.txt"
assets = {asset["name"]: asset["browser_download_url"] for asset in release["assets"]}

for name in (deb_name, checksum_name):
    if name not in assets:
        raise SystemExit(f"Asset mancante nella release {version}: {name}")

print(version)
print(assets[deb_name])
print(assets[checksum_name])
PY
)
rm -f "$VERACRYPT_RELEASE_JSON"
[ "${#VERACRYPT_RELEASE[@]}" -eq 3 ] || { msg_error "Impossibile leggere i dati dell'ultima release VeraCrypt"; exit 1; }

VERACRYPT_VERSION="${VERACRYPT_RELEASE[0]}"
VERACRYPT_DEB_URL="${VERACRYPT_RELEASE[1]}"
VERACRYPT_CHECKSUM_URL="${VERACRYPT_RELEASE[2]}"
VERACRYPT_DEB_NAME="veracrypt-console-${VERACRYPT_VERSION}-Debian-12-amd64.deb"
VERACRYPT_CHECKSUM_NAME="veracrypt-${VERACRYPT_VERSION}-sha256sum.txt"
msg_ok "Ultima versione stabile rilevata: $VERACRYPT_VERSION"

msg_info "Download VeraCrypt $VERACRYPT_VERSION"
cd /tmp
curl -fL --retry 3 "$VERACRYPT_DEB_URL" -o "$VERACRYPT_DEB_NAME"
curl -fsSL --retry 3 "$VERACRYPT_CHECKSUM_URL" -o "$VERACRYPT_CHECKSUM_NAME"
CHECKSUM_LINE=$(grep -F " $VERACRYPT_DEB_NAME" "$VERACRYPT_CHECKSUM_NAME" || true)
[ -n "$CHECKSUM_LINE" ] || { msg_error "Checksum VeraCrypt non trovato"; exit 1; }
printf '%s\n' "$CHECKSUM_LINE" | sha256sum --check --status -
msg_ok "VeraCrypt scaricato e checksum SHA-256 verificato"

msg_info "Installazione VeraCrypt"
dpkg -i "$VERACRYPT_DEB_NAME" >/dev/null 2>&1 || true
apt install -f -y -qq
msg_ok "VeraCrypt installato"

msg_info "Creazione directory sicura /mnt/secure"
mkdir -p /mnt/secure
chmod 700 /mnt/secure
msg_ok "Directory /mnt/secure pronta"

# ------------------------------------------------
# Regola udev per identificazione stabile USB
# ------------------------------------------------
msg_info "Configurazione regola udev per $USB_VENDOR:$USB_PRODUCT"
cat > /etc/udev/rules.d/99-veracrypt-usb.rules << UDEVEOF
ACTION=="add", SUBSYSTEM=="block", ATTRS{idVendor}=="${USB_VENDOR}", ATTRS{idProduct}=="${USB_PRODUCT}", SYMLINK+="veracrypt-disk%n"
UDEVEOF
udevadm control --reload-rules
udevadm trigger
msg_ok "Regola udev applicata"

# ------------------------------------------------
# FileBrowser (opzionale)
# ------------------------------------------------
if [ "$INSTALL_FB" = "s" ]; then
  FILEBROWSER_INSTALLER=$(mktemp)

  msg_info "Download installer FileBrowser"
  if ! curl -fsSL --retry 3 https://raw.githubusercontent.com/filebrowser/get/master/get.sh -o "$FILEBROWSER_INSTALLER"; then
    rm -f "$FILEBROWSER_INSTALLER"
    msg_error "Download dell'installer FileBrowser non riuscito"
    exit 1
  fi
  msg_ok "Installer FileBrowser scaricato"

  echo "Installazione FileBrowser in corso..."
  if ! bash "$FILEBROWSER_INSTALLER"; then
    rm -f "$FILEBROWSER_INSTALLER"
    msg_error "Installazione FileBrowser non riuscita: controlla il messaggio precedente"
    exit 1
  fi
  rm -f "$FILEBROWSER_INSTALLER"

  if ! command -v filebrowser >/dev/null 2>&1; then
    msg_error "FileBrowser non è disponibile nel PATH dopo l'installazione"
    exit 1
  fi

  msg_info "Configurazione FileBrowser"
  mkdir -p /etc/filebrowser
  chmod 700 /etc/filebrowser

  if [ ! -f "$FILEBROWSER_DB" ] && ! filebrowser config init -d "$FILEBROWSER_DB"; then
    msg_error "Inizializzazione FileBrowser non riuscita"
    exit 1
  fi

  if filebrowser users find admin -d "$FILEBROWSER_DB" >/dev/null 2>&1; then
    if ! filebrowser users update admin --password "$FB_PASSWORD" --perm.admin -d "$FILEBROWSER_DB"; then
      msg_error "Aggiornamento dell'utente amministratore FileBrowser non riuscito"
      exit 1
    fi
  elif ! filebrowser users add admin "$FB_PASSWORD" --perm.admin -d "$FILEBROWSER_DB"; then
    msg_error "Creazione dell'utente amministratore FileBrowser non riuscita"
    exit 1
  fi
  msg_ok "FileBrowser installato e configurato"
fi

# ------------------------------------------------
# Script CLI mount/umount
# ------------------------------------------------
msg_info "Creazione script mount-secure.sh / umount-secure.sh"

cat > /usr/local/bin/mount-secure.sh << 'MOUNTEOF'
#!/bin/bash
if [ -e /dev/veracrypt-disk1 ]; then
    DEVICE="/dev/veracrypt-disk1"
elif [ -e /dev/veracrypt-disk ]; then
    DEVICE="/dev/veracrypt-disk"
else
    DEVICE=$(lsblk -o NAME,TYPE | grep part | grep -v sda | head -1 | awk '{print "/dev/"$1}')
    DEVICE=${DEVICE:-/dev/sdb2}
fi

echo "Device rilevato: $DEVICE"
echo -n "Password VeraCrypt: "
read -s PASSWORD
echo ""

veracrypt --mount "$DEVICE" /mnt/secure --password="$PASSWORD" --non-interactive
unset PASSWORD

if mountpoint -q /mnt/secure; then
    echo "Volume montato."
    if command -v filebrowser >/dev/null 2>&1; then
        filebrowser -d /etc/filebrowser/filebrowser.db -r /mnt/secure -a 0.0.0.0 -p 8080 &
        echo "FileBrowser su http://localhost:8080"
    fi
else
    echo "Montaggio fallito."
fi
MOUNTEOF
chmod +x /usr/local/bin/mount-secure.sh

cat > /usr/local/bin/umount-secure.sh << 'UMOUNTEOF'
#!/bin/bash
pkill filebrowser 2>/dev/null || true
if mountpoint -q /mnt/secure; then
    veracrypt --dismount /mnt/secure
fi
sync
echo 3 > /proc/sys/vm/drop_caches
echo "Volume smontato e pulito."
UMOUNTEOF
chmod +x /usr/local/bin/umount-secure.sh

msg_ok "Script CLI creati"

# ------------------------------------------------
# Web app Flask
# ------------------------------------------------
msg_info "Creazione web app secure-webapp.py"

cat > /usr/local/bin/secure-webapp.py << WEBAPPEOF
#!/usr/bin/env python3
from flask import Flask, request, render_template_string, redirect, url_for, session, jsonify
import subprocess
import os
import time
import glob
import re
from functools import wraps
from datetime import datetime
import threading

app = Flask(__name__)
app.secret_key = os.urandom(24)

MOUNT_POINT = "/mnt/secure"
FILEBROWSER_PORT = 8080
FILEBROWSER_DB = "/etc/filebrowser/filebrowser.db"
ADMIN_PASSWORD = "${WEB_PASSWORD}"

def get_device():
    devices = sorted(glob.glob('/dev/veracrypt-disk*'))
    if devices:
        return devices[0]
    if os.path.exists('/dev/sdb2'):
        return '/dev/sdb2'
    return '/dev/sdb'

log_messages = []
log_lock = threading.Lock()

def add_log(message, level="INFO"):
    with log_lock:
        timestamp = datetime.now().strftime("%H:%M:%S")
        message = re.sub(r"--password='[^']*'", "--password='********'", str(message))
        log_messages.append({'timestamp': timestamp, 'message': message, 'level': level})
        if len(log_messages) > 100:
            log_messages.pop(0)

def log_subprocess(cmd):
    safe_cmd = re.sub(r"--password='[^']*'", "--password='********'", cmd)
    add_log(f"Esecuzione: {safe_cmd}", "COMMAND")
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    for stream, level in ((result.stdout, "OUTPUT"), (result.stderr, "ERROR")):
        for line in stream.split('\\n'):
            if line.strip():
                safe_line = re.sub(r"--password='[^']*'", "--password='********'", line)
                add_log(safe_line, level)
    add_log("Comando completato" if result.returncode == 0 else "Comando fallito",
             "SUCCESS" if result.returncode == 0 else "ERROR")
    return result

HTML = '''
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Secure File Access</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, sans-serif; background: linear-gradient(135deg,#667eea,#764ba2); min-height: 100vh; padding: 10px; display: flex; align-items: center; justify-content: center; }
.container { background: #fff; border-radius: 15px; padding: 20px; max-width: 450px; width: 100%; box-shadow: 0 20px 60px rgba(0,0,0,.3); }
h1 { text-align: center; margin-bottom: 20px; }
.status { text-align: center; padding: 15px; margin: 15px 0; border-radius: 10px; font-weight: 500; }
.mounted { background: #d4edda; color: #155724; }
.unmounted { background: #f8d7da; color: #721c24; }
input[type=password] { width: 100%; padding: 12px; margin: 5px 0; border: 2px solid #ddd; border-radius: 8px; font-size: 16px; }
button { width: 100%; padding: 12px; margin: 8px 0; border: none; border-radius: 8px; font-size: 16px; font-weight: bold; cursor: pointer; }
.mount-btn { background: #28a745; color: #fff; }
.unmount-btn { background: #dc3545; color: #fff; }
.browse-btn { background: #007bff; color: #fff; }
.logout-btn { background: #6c757d; color: #fff; font-size: 14px; }
.message { padding: 10px; border-radius: 5px; margin: 10px 0; font-size: 14px; }
.error { background: #f8d7da; color: #721c24; }
.success { background: #d4edda; color: #155724; }
.log-container { margin-top: 20px; background: #f8f9fa; border-radius: 8px; padding: 10px; max-height: 300px; overflow-y: auto; font-family: monospace; font-size: 12px; }
.log-header { display: flex; justify-content: space-between; margin-bottom: 10px; }
.clear-log-btn { background: #6c757d; color: #fff; border: none; padding: 5px 10px; border-radius: 4px; width: auto; }
.log-entry { padding: 3px 0; border-bottom: 1px solid #eee; }
.log-COMMAND { color: #007bff; font-weight: bold; }
.log-ERROR { color: #dc3545; }
.log-SUCCESS { color: #28a745; font-weight: bold; }
a { text-decoration: none; }
</style>
</head>
<body>
<div class="container">
<h1>Secure File Access</h1>
{% if error %}<div class="message error">{{ error }}</div>{% endif %}
{% if success %}<div class="message success">{{ success }}</div>{% endif %}
{% if session.authenticated %}
  {% if mounted %}
    <div class="status mounted">Volume montato</div>
    <a href="http://{{ request.host.split(':')[0] }}:{{ filebrowser_port }}" target="_blank">
      <button class="browse-btn">Apri File Browser</button>
    </a>
    <form method="POST" action="/unmount"><button class="unmount-btn">Smonta volume</button></form>
  {% else %}
    <div class="status unmounted">Volume smontato</div>
    <form method="POST" action="/mount">
      <input type="password" name="password" placeholder="Password VeraCrypt" required autocomplete="off">
      <button class="mount-btn">Monta volume</button>
    </form>
  {% endif %}
  <div class="log-container">
    <div class="log-header"><span>Log operazioni</span><button class="clear-log-btn" onclick="clearLog()">Pulisci</button></div>
    <div id="log-content">
      {% for log in logs|reverse %}
      <div class="log-entry log-{{ log.level }}"><span>{{ log.timestamp }}</span> {{ log.message }}</div>
      {% endfor %}
    </div>
  </div>
  <form method="POST" action="/logout"><button class="logout-btn">Logout</button></form>
{% else %}
  <form method="POST" action="/login">
    <input type="password" name="admin_password" placeholder="Password Admin" required autocomplete="off">
    <button class="mount-btn">Accedi</button>
  </form>
{% endif %}
</div>
<script>
function clearLog(){ fetch('/clear-log',{method:'POST'}).then(()=>location.reload()); }
{% if session.authenticated %}
setInterval(()=>{
  fetch('/get-log').then(r=>r.json()).then(data=>{
    document.getElementById('log-content').innerHTML = data.logs.reverse().map(l=>
      '<div class="log-entry log-'+l.level+'"><span>'+l.timestamp+'</span> '+l.message+'</div>').join('');
  });
}, 3000);
{% endif %}
</script>
</body>
</html>
'''

def check_auth(f):
    @wraps(f)
    def decorated(*a, **kw):
        if not session.get('authenticated'):
            return redirect(url_for('home'))
        return f(*a, **kw)
    return decorated

@app.route('/')
def home():
    return render_template_string(HTML, mounted=os.path.ismount(MOUNT_POINT),
                                   filebrowser_port=FILEBROWSER_PORT, logs=log_messages)

@app.route('/get-log')
@check_auth
def get_log():
    return jsonify({'logs': list(reversed(log_messages[-20:]))})

@app.route('/clear-log', methods=['POST'])
@check_auth
def clear_log():
    with log_lock:
        log_messages.clear()
        add_log("Log pulito", "INFO")
    return jsonify({'status': 'ok'})

@app.route('/login', methods=['POST'])
def login():
    if request.form['admin_password'] == ADMIN_PASSWORD:
        session['authenticated'] = True
        add_log("Login effettuato", "SUCCESS")
        return redirect(url_for('home'))
    add_log("Tentativo di login fallito", "ERROR")
    return render_template_string(HTML, error="Password errata!", mounted=False,
                                   filebrowser_port=FILEBROWSER_PORT, logs=log_messages)

@app.route('/logout', methods=['POST'])
def logout():
    add_log("Logout effettuato", "INFO")
    session.pop('authenticated', None)
    return redirect(url_for('home'))

@app.route('/mount', methods=['POST'])
@check_auth
def mount_volume():
    password = request.form['password']
    add_log("Tentativo di montaggio volume", "INFO")
    if os.path.ismount(MOUNT_POINT):
        return render_template_string(HTML, error="Volume già montato!", mounted=True,
                                       filebrowser_port=FILEBROWSER_PORT, logs=log_messages)
    device = get_device()
    add_log(f"Device rilevato: {device}", "INFO")
    result = log_subprocess(f"veracrypt --mount {device} {MOUNT_POINT} --password='{password}' --non-interactive")
    if result.returncode == 0:
        if subprocess.run("command -v filebrowser", shell=True, capture_output=True).returncode == 0:
            subprocess.Popen(['filebrowser', '-d', FILEBROWSER_DB, '-r', MOUNT_POINT,
                              '-a', '0.0.0.0', '-p', str(FILEBROWSER_PORT)])
        time.sleep(2)
        add_log("FileBrowser avviato", "SUCCESS")
        return render_template_string(HTML, success="Volume montato con successo!", mounted=True,
                                       filebrowser_port=FILEBROWSER_PORT, logs=log_messages)
    add_log("Password errata o volume non accessibile", "ERROR")
    return render_template_string(HTML, error="Errore nel montaggio. Password errata?", mounted=False,
                                   filebrowser_port=FILEBROWSER_PORT, logs=log_messages)

@app.route('/unmount', methods=['POST'])
@check_auth
def unmount_volume():
    log_subprocess("pkill filebrowser")
    if os.path.ismount(MOUNT_POINT):
        log_subprocess(f"veracrypt --dismount {MOUNT_POINT}")
        time.sleep(1)
    log_subprocess("sync")
    log_subprocess("sh -c 'echo 3 > /proc/sys/vm/drop_caches'")
    add_log("Smontaggio completato", "SUCCESS")
    return render_template_string(HTML, success="Volume smontato e pulito!", mounted=False,
                                   filebrowser_port=FILEBROWSER_PORT, logs=log_messages)

if __name__ == '__main__':
    add_log("Servizio avviato", "INFO")
    app.run(host='0.0.0.0', port=5000, debug=False, threaded=True)
WEBAPPEOF

chmod +x /usr/local/bin/secure-webapp.py
msg_ok "Web app creata"

# ------------------------------------------------
# Servizio systemd
# ------------------------------------------------
msg_info "Registrazione servizio systemd secure-webapp"
cat > /etc/systemd/system/secure-webapp.service << 'SVCEOF'
[Unit]
Description=Secure File Access Web Interface
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/secure-webapp.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now secure-webapp >/dev/null 2>&1
msg_ok "Servizio secure-webapp attivo"

# ------------------------------------------------
# Riepilogo
# ------------------------------------------------
echo
echo -e "${GN}=== INSTALLAZIONE COMPLETATA ===${CL}"
echo "Accesso web:       http://IP-VM:5000"
[ "$INSTALL_FB" = "s" ] && echo "FileBrowser:       http://IP-VM:8080"
echo "Password Web:      $WEB_PASSWORD"
[ "$INSTALL_FB" = "s" ] && echo "FileBrowser login: admin / $FB_PASSWORD"
echo
echo "Mount manuale:     /usr/local/bin/mount-secure.sh"
echo "Umount manuale:    /usr/local/bin/umount-secure.sh"
