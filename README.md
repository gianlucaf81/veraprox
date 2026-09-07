# VeraProx

Script per creare una VM Debian 12 su Proxmox VE destinata all'uso di VeraCrypt, con passthrough USB, una piccola interfaccia web per montare/smontare il volume e FileBrowser opzionale.

## Cosa fa

`create-veracrypt-vm.sh`, da eseguire sull'host Proxmox, guida nella scelta delle risorse della VM, del bridge di rete e del dispositivo USB. Al termine mostra il comando da eseguire nella VM.

`post-install-veracrypt.sh`, da eseguire **all'interno della VM Debian 12**, installa:

- VeraCrypt console per Debian 12 amd64;
- le dipendenze necessarie e una regola udev per il dispositivo USB selezionato;
- una web app su porta `5000` per montare e smontare il volume;
- FileBrowser sulla porta `8080`, se scelto durante la configurazione.

Ad ogni esecuzione il secondo script interroga la release stabile più recente nel repository ufficiale VeraCrypt, scarica l'asset Debian 12 amd64 corrispondente e controlla il checksum SHA-256 prima dell'installazione.

## Requisiti

- un host Proxmox VE con accesso come `root`;
- un dispositivo USB da assegnare alla VM;
- connettività Internet sia sull'host Proxmox sia nella VM;
- una VM Debian 12 amd64 installata dallo script.

## Installazione

### 1. Crea la VM su Proxmox

Accedi alla shell dell'host Proxmox come `root`, scarica ed esegui lo script:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/gianlucaf81/veraprox/main/create-veracrypt-vm.sh)"
```

Completa le richieste a schermo, avvia la VM e installa Debian 12 dalla console Proxmox. Nella schermata **Selezione del software**, deseleziona **Ambiente desktop Debian** e lascia selezionati solo **server SSH** e **utility di sistema standard**. In questo modo la VM resta senza interfaccia grafica.

Dopo aver concluso l'installazione di Debian, spegni la VM, rimuovi l'ISO e imposta il disco come avvio predefinito:

```bash
qm set ID_DELLA_VM --delete ide2
qm set ID_DELLA_VM --boot order=scsi0
```

### 2. Completa l'installazione nella VM

Accedi alla VM come `root` dopo l'installazione di Debian. Nella schermata finale dello script Proxmox troverai il comando già composto con l'identificativo USB e le opzioni scelte. Eseguilo nella VM.

In alternativa, scarica lo script e passagli manualmente le variabili richieste:

```bash
USB_VENDOR=0781 USB_PRODUCT=5583 WEB_PASSWORD='scegli-una-password-forte' INSTALL_FB=s FB_PASSWORD='scegli-un-altra-password-forte' bash -c "$(curl -fsSL https://raw.githubusercontent.com/gianlucaf81/veraprox/main/post-install-veracrypt.sh)"
```

Sostituisci `0781` e `5583` con il vendor/product ID del tuo dispositivo USB. Lo script di creazione della VM li rileva automaticamente.

Se `curl` non è presente nella VM Debian, installalo prima con `apt update && apt install -y curl`.

## Accesso e uso

Al termine dell'installazione:

- interfaccia di gestione: `http://IP-DELLA-VM:5000`;
- FileBrowser, se installato: `http://IP-DELLA-VM:8080`;
- montaggio manuale: `/usr/local/bin/mount-secure.sh`;
- smontaggio manuale: `/usr/local/bin/umount-secure.sh`.

L'interfaccia web e FileBrowser non includono TLS. Usali solo in una rete fidata oppure dietro un reverse proxy configurato con HTTPS. Non esporre le porte 5000 e 8080 direttamente a Internet.

## Password

Le password vengono richieste durante la procedura. Se un campo viene lasciato vuoto, gli script mantengono i valori predefiniti `password_web` e `filebrowser`: cambiali sempre con valori robusti.

## Avvertenze

Questo progetto modifica la configurazione della VM e abilita servizi di rete. Verifica con attenzione il dispositivo USB selezionato e conserva in modo sicuro le password di VeraCrypt: non possono essere recuperate se smarrite.
