#!/usr/bin/env bash

# ============================================
# post-install-veracrypt.sh
# Da eseguire DENTRO la VM Debian 12 dopo l'installazione.
# Installa VeraCrypt + FileBrowser + web app di mount/unmount.
#
# Lo script richiede le password e l'eventuale installazione di FileBrowser.
# Il dispositivo si seleziona nel runtime condiviso, dalla web app o dal terminale.
# ============================================

set -Eeuo pipefail

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"
WT_TITLE="VeraProx - Configurazione VM"

print_success() { echo -e "${GREEN}[✔]${RESET} $1"; }
print_error()   { echo -e "${RED}[✘]${RESET} $1" >&2; }
print_info()    { echo -e "${CYAN}[i]${RESET} $1"; }
print_warn()    { echo -e "${YELLOW}[!]${RESET} $1"; }

msg_info() { print_info "$1"; }
msg_ok() { print_success "$1"; }
msg_error() {
  print_error "$1"
  command -v whiptail >/dev/null 2>&1 && whiptail --title "$WT_TITLE" --msgbox "$1" 9 72
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

if mountpoint -q /mnt/secure; then
  msg_error "Arresta le applicazioni e smonta /mnt/secure prima dell'installazione. Per aggiornare solo gli script usa update-veraprox.sh."
  exit 1
fi

if ! command -v whiptail >/dev/null 2>&1; then
  msg_info "Installazione strumenti di configurazione"
  apt update -qq >/dev/null
  apt install -y -qq whiptail >/dev/null
fi

if ! whiptail --title "$WT_TITLE" --yesno "VeraProx configurerà VeraCrypt, l'interfaccia web e FileBrowser opzionale.\n\nIl dispositivo verrà selezionato dalla nuova interfaccia o con veraprox-device.sh.\n\nContinuare?" 13 78; then
  exit 0
fi

RUNTIME_LOCAL_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  RUNTIME_LOCAL_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fi

if [ -z "${WEB_PASSWORD:-}" ]; then
  WEB_PASSWORD=$(whiptail --backtitle "$WT_TITLE" --passwordbox "Password interfaccia web admin" 8 58 --title "Credenziali" 3>&1 1>&2 2>&3) || exit 1
  [ -n "$WEB_PASSWORD" ] || { msg_error "La password web non può essere vuota."; exit 1; }
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
  [ -n "$FB_PASSWORD" ] || { msg_error "La password FileBrowser non può essere vuota."; exit 1; }
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
apt update -qq >/dev/null && apt upgrade -y -qq >/dev/null
msg_ok "Sistema aggiornato"

msg_info "Installazione dipendenze"
apt install -y -qq curl wget usbutils secure-delete ntfs-3g fuse3 python3-flask >/dev/null
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
# Controller condiviso, script CLI e web app
# ------------------------------------------------
msg_info "Installazione runtime VeraProx"
RUNTIME_INSTALLER=$(mktemp)
if [ -n "$RUNTIME_LOCAL_DIR" ] && [ -f "$RUNTIME_LOCAL_DIR/update-veraprox.sh" ]; then
  cp -- "$RUNTIME_LOCAL_DIR/update-veraprox.sh" "$RUNTIME_INSTALLER"
else
  curl -fsSL --retry 3 https://raw.githubusercontent.com/gianlucaf81/veraprox/main/update-veraprox.sh -o "$RUNTIME_INSTALLER"
fi
bash -n "$RUNTIME_INSTALLER"
if ! printf '%s' "$WEB_PASSWORD" | bash "$RUNTIME_INSTALLER" --web-password-stdin; then
  rm -f -- "$RUNTIME_INSTALLER"
  msg_error "Installazione del runtime non riuscita."
  exit 1
fi
rm -f -- "$RUNTIME_INSTALLER"
msg_ok "Runtime condiviso installato"

WEBAPP_READY=false
for _ in {1..10}; do
  if systemctl is-active --quiet secure-webapp && curl -fsS --max-time 2 http://127.0.0.1:5000/ >/dev/null; then
    WEBAPP_READY=true
    break
  fi
  sleep 1
done

if [ "$WEBAPP_READY" != "true" ]; then
  SERVICE_LOG=$(journalctl -u secure-webapp --no-pager -n 12 2>&1 || true)
  msg_error "Il servizio web non risponde sulla porta 5000.\n\nUltimi messaggi del servizio:\n$SERVICE_LOG"
  exit 1
fi
msg_ok "Servizio secure-webapp attivo e raggiungibile"

VM_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')
VM_IP=${VM_IP:-$(hostname -I | awk '{print $1}')}
VM_IP=${VM_IP:-"IP non rilevato"}

# ------------------------------------------------
# Riepilogo
# ------------------------------------------------
FINAL_MESSAGE="Installazione completata.\n\nInterfaccia VeraProx: http://$VM_IP:5000\nPassword web: $WEB_PASSWORD\n\nMount manuale: /usr/local/bin/mount-secure.sh\nSmontaggio manuale: /usr/local/bin/umount-secure.sh\n\nPrima del mount scegli il disco nella pagina web\no con veraprox-device.sh."

if [ "$INSTALL_FB" = "s" ]; then
  FINAL_MESSAGE+="\n\nFileBrowser: http://$VM_IP:8080\nAccesso FileBrowser: admin / $FB_PASSWORD"
fi

whiptail --title "$WT_TITLE" --msgbox "$FINAL_MESSAGE" 18 78
