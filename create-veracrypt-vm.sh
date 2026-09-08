#!/usr/bin/env bash

# ============================================
# create-veracrypt-vm.sh
# Creazione VM VeraCrypt + FileBrowser su Proxmox VE
# USB passthrough (Vendor/Device ID)
# Interfaccia in stile Ausilio/helper script
# ============================================

set -Eeuo pipefail

# ------------------------------------------------
# Stile messaggi Ausilio
# ------------------------------------------------
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"
WT_TITLE="VeraProx - Crea VM"

GITHUB_USER="gianlucaf81"
GITHUB_REPO="veraprox"
RAW_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/post-install-veracrypt.sh"

# ------------------------------------------------
# Messaggi e finestre
# ------------------------------------------------
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
  print_info "Installazione di whiptail..."
  apt update -qq >/dev/null && apt install -y whiptail -qq >/dev/null
fi

# ------------------------------------------------
# Benvenuto
# ------------------------------------------------
if ! whiptail --title "$WT_TITLE" --yesno "VeraProx creerà una VM Debian 12 minimale con passthrough di un dispositivo USB per VeraCrypt.\n\nContinuare?" 11 72; then
  exit 0
fi

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
whiptail --title "$WT_TITLE" --msgbox "VM '$VMNAME' (ID: $VMID) creata con successo.\n\n1. Avviala con: qm start $VMID\n2. Installa Debian 12 senza ambiente desktop. In 'Selezione del software', lascia solo 'server SSH' e 'utility di sistema standard'.\n3. Nella VM esegui:\n   bash -c \"\$(curl -fsSL $RAW_URL)\"\n   Se curl non è presente: apt update && apt install -y curl\n4. Al termine, rimuovi l'ISO:\n   qm set $VMID --delete ide2\n   qm set $VMID --boot order=scsi0" 22 78
