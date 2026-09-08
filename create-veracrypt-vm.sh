#!/usr/bin/env bash

# ============================================
# create-veracrypt-vm.sh
# Creazione VM VeraCrypt + FileBrowser su Proxmox VE
# USB passthrough (Vendor/Device ID)
# Stile UI ispirato a community-scripts.org (build.func)
# ============================================

set -Eeuo pipefail

# ------------------------------------------------
# Colori e simboli (community-scripts style)
# ------------------------------------------------
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
RD=$(echo "\033[01;31m")
BL=$(echo "\033[36m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD=" "
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

GITHUB_USER="gianlucaf81"
GITHUB_REPO="veraprox"
RAW_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/post-install-veracrypt.sh"

# ------------------------------------------------
# Spinner
# ------------------------------------------------
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
  msg_error "Esegui lo script come root sull'host Proxmox."
  exit 1
fi

if ! command -v qm >/dev/null 2>&1; then
  msg_error "Il comando qm non è disponibile: esegui lo script sull'host Proxmox, non dentro una VM."
  exit 1
fi

if ! command -v pvesh >/dev/null 2>&1; then
  msg_error "Il comando pvesh non è disponibile: impossibile assegnare automaticamente l'ID della VM."
  exit 1
fi

if [ ! -t 0 ] || [ ! -t 1 ]; then
  msg_error "Serve una shell interattiva con terminale per mostrare le schermate di configurazione."
  exit 1
fi

# ------------------------------------------------
# Verifica whiptail
# ------------------------------------------------
if ! command -v whiptail >/dev/null 2>&1; then
  echo "whiptail non trovato, installazione..."
  apt update -qq && apt install -y whiptail -qq
fi

WT_TITLE="VeraCrypt VM Builder"

# ------------------------------------------------
# Header
# ------------------------------------------------
clear
echo -e "${BL}"
cat << "HEADER"
 __     __            _____                _
 \ \   / /__ _ __ __ _/ ____|_ __ _   _ _ __ | |_
  \ \ / / _ \ '__/ _` | |    | '__| | | | '_ \| __|
   \ V /  __/ | | (_| | |____| |  | |_| | |_) | |_
    \_/ \___|_|  \__,_|\_____|_|   \__, | .__/ \__|
                                    |___/|_|
HEADER
echo -e "${CL}"

# ------------------------------------------------
# Prompt parametri VM
# ------------------------------------------------
NEXT_VMID=$(pvesh get /cluster/nextid)
VMID=$(whiptail --backtitle "$WT_TITLE" --inputbox "ID VM" 8 58 "$NEXT_VMID" --title "Configurazione VM" 3>&1 1>&2 2>&3) || exit 1
VMNAME=$(whiptail --backtitle "$WT_TITLE" --inputbox "Nome VM" 8 58 "veracrypt-secure" --title "Configurazione VM" 3>&1 1>&2 2>&3) || exit 1
VMRAM=$(whiptail --backtitle "$WT_TITLE" --inputbox "RAM in MB" 8 58 "2048" --title "Configurazione VM" 3>&1 1>&2 2>&3) || exit 1
VMCORES=$(whiptail --backtitle "$WT_TITLE" --inputbox "Cores CPU" 8 58 "2" --title "Configurazione VM" 3>&1 1>&2 2>&3) || exit 1
VMDISK=$(whiptail --backtitle "$WT_TITLE" --inputbox "Dimensione disco VM (GB)" 8 58 "32" --title "Configurazione VM" 3>&1 1>&2 2>&3) || exit 1
VMBRIDGE=$(whiptail --backtitle "$WT_TITLE" --inputbox "Bridge di rete" 8 58 "vmbr0" --title "Configurazione VM" 3>&1 1>&2 2>&3) || exit 1

# ------------------------------------------------
# Selezione dispositivo USB da lsusb
# ------------------------------------------------
USB_MENU_ITEMS=()
while IFS= read -r line; do
  ID=$(echo "$line" | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{4}')
  DESC=$(echo "$line" | sed -E 's/^.*ID [0-9a-fA-F]{4}:[0-9a-fA-F]{4} //')
  [ -n "$ID" ] && USB_MENU_ITEMS+=("$ID" "$DESC")
done < <(lsusb)

if [ "${#USB_MENU_ITEMS[@]}" -eq 0 ]; then
  msg_error "Nessun dispositivo USB rilevato."
  exit 1
fi

USB_ID=$(whiptail --backtitle "$WT_TITLE" --title "Dispositivo USB" --menu "Seleziona il device da passare in passthrough" 20 70 10 "${USB_MENU_ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 1

# ------------------------------------------------
# Riepilogo di conferma
# ------------------------------------------------
SUMMARY="VMID: $VMID
ID proposto automaticamente dal cluster: $NEXT_VMID
Nome: $VMNAME
RAM: ${VMRAM}MB  |  Cores: $VMCORES  |  Disco: ${VMDISK}GB
Bridge: $VMBRIDGE
USB: $USB_ID"

whiptail --backtitle "$WT_TITLE" --title "Conferma" --yesno "$SUMMARY

Procedere con la creazione della VM?" 18 60 || exit 1

# ------------------------------------------------
# Download ISO Debian 12
# ------------------------------------------------
DEBIAN_VERSION="12.13.0"
ISO_PATH="/var/lib/vz/template/iso"
ISO_NAME="debian-${DEBIAN_VERSION}-amd64-netinst.iso"
ISO_FILE="$ISO_PATH/$ISO_NAME"
ISO_URL="https://cdimage.debian.org/cdimage/archive/${DEBIAN_VERSION}/amd64/iso-cd/${ISO_NAME}"
ISO_CHECKSUM_URL="https://cdimage.debian.org/cdimage/archive/${DEBIAN_VERSION}/amd64/iso-cd/SHA256SUMS"

if [ ! -f "$ISO_FILE" ]; then
  msg_info "Download ISO Debian ${DEBIAN_VERSION} netinst"
  wget -q -P "$ISO_PATH" "$ISO_URL"
  msg_ok "ISO Debian scaricata"
else
  msg_ok "ISO Debian 12 già presente"
fi

msg_info "Verifica checksum ISO Debian"
ISO_CHECKSUM_FILE=$(mktemp)
wget -q -O "$ISO_CHECKSUM_FILE" "$ISO_CHECKSUM_URL"
ISO_CHECKSUM_LINE=$(grep -F " $ISO_NAME" "$ISO_CHECKSUM_FILE" || true)
rm -f "$ISO_CHECKSUM_FILE"
[ -n "$ISO_CHECKSUM_LINE" ] || { msg_error "Checksum ISO Debian non trovato"; exit 1; }
printf '%s\n' "$ISO_CHECKSUM_LINE" | (cd "$ISO_PATH" && sha256sum --check --status -)
msg_ok "Checksum ISO Debian verificato"

# ------------------------------------------------
# Creazione VM
# ------------------------------------------------
msg_info "Creazione VM $VMID ($VMNAME)"
qm create "$VMID" --name "$VMNAME" --memory "$VMRAM" --cores "$VMCORES" --net0 virtio,bridge="$VMBRIDGE"
msg_ok "VM $VMID creata"

msg_info "Configurazione disco scsi0 (${VMDISK}GB)"
qm set "$VMID" --scsi0 local-lvm:"$VMDISK" >/dev/null
msg_ok "Disco configurato"

msg_info "Montaggio CDROM installazione"
qm set "$VMID" --cdrom "$ISO_FILE" >/dev/null
msg_ok "CDROM montato"

msg_info "Passthrough USB $USB_ID"
qm set "$VMID" --usb0 host="$USB_ID" >/dev/null
msg_ok "USB passthrough configurato"

msg_info "Configurazione boot da ISO e guest agent"
qm set "$VMID" --boot order="ide2;scsi0" >/dev/null
qm set "$VMID" --agent enabled=1 >/dev/null
msg_ok "Boot da ISO e guest agent configurati"

# ------------------------------------------------
# Riepilogo finale
# ------------------------------------------------
echo
echo -e "${GN}=== VM CREATA CON SUCCESSO ===${CL}"
echo -e "${BL}VMID:${CL}          $VMID"
echo -e "${BL}Nome:${CL}          $VMNAME"
echo -e "${BL}USB Device:${CL}    $USB_ID"
echo
echo -e "${YW}PROSSIMI PASSI:${CL}"
echo "1. Avvia la VM:            qm start $VMID"
echo "2. Installa Debian 12 senza desktop dalla console Proxmox"
echo "   In 'Selezione del software', deseleziona 'Ambiente desktop Debian'."
echo "   Lascia selezionati solo 'server SSH' e 'utility di sistema standard'."
echo "3. Nella VM, esegui il post-install con curl:"
printf '   bash -c "$(curl -fsSL %q)"\n' "$RAW_URL"
echo "   Se curl non è installato: apt update && apt install -y curl"
echo "4. Dopo l'installazione, rimuovi l'ISO e avvia dal disco:"
echo "   qm set $VMID --delete ide2"
echo "   qm set $VMID --boot order=scsi0"
echo
