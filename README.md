# VeraProx

VeraCrypt su Debian, con una piccola pagina web per montare/smontare un disco USB e **FileBrowser Quantum** per sfogliare i file con anteprime video.

Il disco può restare **NTFS**, leggibile anche da Windows dopo lo sblocco con VeraCrypt. Quantum usa FFmpeg: non serve Docker. Le anteprime sono quelle native di Quantum, non il trittico del progetto Synology.

## Installazione

Serve Debian 12 amd64, accesso root e Internet.

### 1. VM su Proxmox (facoltativo)

Nella shell dell'host Proxmox:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/gianlucaf81/veraprox/main/create-veracrypt-vm.sh)"
```

Scegli risorse e USB; l'ID VM proposto automaticamente è modificabile. Avvia la VM e **installa Debian dalla console**, senza ambiente desktop: lascia SSH e utility standard. Poi, sull'host, sostituisci `ID_VM`:

```bash
qm set ID_VM --delete ide2
qm set ID_VM --boot order=scsi0
```

Se hai già Debian, salta questo passaggio. Per LXC, il passthrough del dispositivo va configurato separatamente.

### 2. Installazione dentro Debian

Come root, a volume smontato:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/gianlucaf81/veraprox/main/post-install-veracrypt.sh)"
```

Se manca curl: `apt update && apt install -y curl`.

Scegli la password web e se installare Quantum. La password Quantum deve avere 8–72 byte UTF-8. L'installer scarica l'ultima release stabile VeraCrypt per Debian 12 amd64 e controlla SHA-256. Quantum è fissato alla release stabile collaudata **v1.5.6-stable**, con SHA-256 verificato; non viene installata la beta 2.x.

## Uso

1. Apri `http://IP-DEBIAN:5000` e accedi con la password web.
2. In **Scegli o cambia dispositivo**, verifica modello, dimensione e seriale della partizione cifrata, quindi salva.
3. Inserisci la password VeraCrypt e premi **Monta volume**.
4. Apri Quantum su `http://IP-DEBIAN:8080`: utente `admin`, password scelta per Quantum.
5. Per rimuovere il disco usa **Smonta volume**: Quantum viene fermato prima dello smontaggio.

Quantum mostra le miniature in modalità griglia e anteprime animate al passaggio del mouse. La prima generazione può richiedere tempo; le miniature non garantiscono che ogni codec video sia riproducibile dal browser. Cache, indice e temporanei sono in `/mnt/secure/.veraprox-quantum`, esclusa dalla navigazione. Non cancellarla mentre Quantum è in esecuzione.

In alternativa, dal terminale:

```bash
veraprox-device.sh  # scelta del disco
mount-secure.sh    # password richiesta da VeraCrypt
umount-secure.sh
```

## Passare dal vecchio FileBrowser a Quantum

Ferma le applicazioni che usano il disco e smonta il volume dalla pagina VeraProx. Dentro Debian esegui:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/gianlucaf81/veraprox/main/update-veraprox.sh)" -- --install-quantum
```

La password web e il dispositivo restano invariati. Viene chiesta una **nuova password per Quantum**; utenti e condivisioni del vecchio FileBrowser non vengono importati. I file del volume non vengono spostati o convertiti.

Script/configurazione precedenti e FileBrowser sono conservati in backup privati sotto `/var/backups/veraprox-*`, con percorso mostrato a schermo. Se Quantum è già configurato, l'account viene conservato; la configurazione gestita da VeraProx viene rigenerata. Dopo l'aggiornamento monta il disco e apri la porta 8080.

Per aggiornare **solo il runtime**, senza installare Quantum, usa lo stesso comando senza `-- --install-quantum`.

## Sicurezza e problemi

- Usa il progetto in LAN fidata o tramite VPN: **HTTP non protegge password e dati durante il transito**. HTTPS non è configurato automaticamente.
- La password VeraCrypt non viene salvata. Configurazione e account locali sono accessibili a root; proteggi anche i backup.
- Quantum parte soltanto dopo la verifica del volume e non è abilitato al boot. Con montaggio in sola lettura non parte.
- PIM `0` usa i valori predefiniti. Per keyfile o protezione del volume nascosto usa il terminale; il PIM web è visibile negli argomenti del processo.
- Il servizio web usa ancora Flask come root: non esporlo direttamente a Internet.

Per controllare gli errori:

```bash
systemctl status secure-webapp veraprox-filebrowser --no-pager -l
journalctl -u secure-webapp -u veraprox-filebrowser --no-pager -n 40
```

[Dettagli avanzati, backup e test](docs/advanced.md). [FileBrowser Quantum](https://github.com/gtsteffaniak/filebrowser).
