# VeraProx

Script per creare una VM Debian 12 su Proxmox VE destinata all'uso di VeraCrypt, con passthrough USB, una piccola interfaccia web per montare/smontare il volume e FileBrowser opzionale.

## Cosa fa

`create-veracrypt-vm.sh`, da eseguire sull'host Proxmox, guida nella scelta delle risorse della VM, del bridge e del dispositivo USB da passare alla VM. Non raccoglie né conserva password.

Il campo dell'ID VM viene precompilato con il primo valore libero del cluster Proxmox, ma può essere modificato prima della creazione.

`post-install-veracrypt.sh`, da eseguire **all'interno della VM Debian 12**, installa:

- VeraCrypt console per Debian 12 amd64;
- le dipendenze necessarie e il controller condiviso per scegliere il dispositivo;
- una web app su porta `5000` per montare e smontare il volume;
- FileBrowser sulla porta `8080`, se scelto durante la configurazione nella VM.

Il secondo script è indipendente dal primo: chiede direttamente nella VM la password dell'interfaccia web e se installare FileBrowser. Il disco si seleziona poi dalla pagina web oppure con `veraprox-device.sh`; la scelta viene conservata in `/etc/veraprox/device.conf`.

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

Accedi alla VM come `root` dopo l'installazione di Debian ed esegui:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/gianlucaf81/veraprox/main/post-install-veracrypt.sh)"
```

Il programma chiederà la password dell'interfaccia web e domanderà se installare FileBrowser. Alla fine apri la pagina web, accedi e usa **Scegli o cambia dispositivo**. Seleziona la partizione cifrata verificando modello, dimensione e seriale. Non devi copiare valori o password dall'host Proxmox.

Se `curl` non è presente nella VM Debian, installalo prima con `apt update && apt install -y curl`.

## Accesso e uso

Al termine dell'installazione:

- interfaccia di gestione: `http://IP-DELLA-VM:5000`;
- FileBrowser, se installato: `http://IP-DELLA-VM:8080`;
- montaggio manuale: `/usr/local/bin/mount-secure.sh`;
- smontaggio manuale: `/usr/local/bin/umount-secure.sh`.

## Aggiornare un'installazione esistente

Per provare le nuove funzioni senza reinstallare VeraCrypt, aggiornare pacchetti o reimpostare FileBrowser, usa `update-veraprox.sh` **dentro la VM o il container Debian esistente**.

Prima arresta le applicazioni che utilizzano il volume, inclusi eventuali container Docker, e smonta `/mnt/secure`. L'aggiornamento viene rifiutato se il volume è ancora montato. Verifica con:

```bash
findmnt --mountpoint /mnt/secure
```

Poi esegui:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/gianlucaf81/veraprox/main/update-veraprox.sh)"
```

L'aggiornamento conserva la password web e il database FileBrowser. La vecchia password web viene letta come dato dal vecchio script e sostituita da un hash; il vecchio codice non viene eseguito. Un backup degli script e della configurazione viene conservato in una directory privata `/var/backups/veraprox-…`, il cui percorso viene mostrato. Anche questo backup può contenere le vecchie credenziali: rimane accessibile a root.

Apri nuovamente `http://IP-DELLA-MACCHINA:5000` e accedi con la password di prima. Seleziona il disco, salva la scelta, quindi prova il montaggio e lo smontaggio. La configurazione non include un PARTUUID predefinito e non importa automaticamente le vecchie regole USB: la prima scelta è esplicita.

Se trasferisci manualmente il file anziché scaricarlo, salvalo fuori dal volume cifrato, ad esempio `/root/update-veraprox.sh`, ed esegui `bash /root/update-veraprox.sh`.

## Scelta del dispositivo e montaggio

Pagina web e terminale usano lo stesso controller, `/usr/local/lib/veraprox/runtime.py`. La configurazione locale contiene solo un percorso stabile `by-partuuid` o `by-id` e il punto di montaggio, con proprietario root e permessi `600`.

```bash
# Menu interattivo per la prima configurazione o per cambiare disco
veraprox-device.sh

# Configurazione esplicita, solo se la partizione è disponibile e sicura da selezionare
veraprox-device.sh /dev/disk/by-partuuid/IL-TUO-PARTUUID

# Montaggio: la password e le altre opzioni vengono chieste direttamente da VeraCrypt
mount-secure.sh

# Smontaggio con verifica dell'esito, senza forzare un volume occupato
umount-secure.sh

# Stato e integrazione Immich
python3 /usr/local/lib/veraprox/runtime.py status
```

Il menu esclude filesystem riconoscibili, dispositivi occupati e il disco che ospita filesystem montati o swap. Se un disco contiene partizioni, si propone la singola partizione. È un elenco di candidati, non un rilevamento certo di volumi VeraCrypt: scegli consapevolmente la partizione cifrata. Nei container LXC servono la visibilità del device e dei suoi identificativi stabili; questo aggiornamento non configura il passthrough sul nodo Proxmox.

Se il dispositivo configurato manca o il suo PARTUUID è duplicato, il montaggio viene rifiutato. Non vengono mai usati come ripiego `/dev/sdb`, `/dev/sdb2` o la prima partizione disponibile. Gli identificativi stabili evitano errori di selezione, ma non autenticano crittograficamente il supporto. La selezione di un altro disco è permessa soltanto a volume smontato.

La password VeraCrypt non viene salvata. Nel terminale la richiede VeraCrypt; nella pagina web viene passata al processo tramite stdin, senza shell e senza `--password` negli argomenti. La web app include un token contro richieste involontarie da altri siti, cookie di sessione `HttpOnly`/`SameSite=Strict` e un limite ai tentativi di login. Il PIM specificato nella pagina web viene passato come opzione del processo: se lo consideri segreto, usa il prompt da terminale.

La pagina web supporta password e PIM, e offre il montaggio in sola lettura. Per keyfile o protezione di un volume nascosto all'interno del volume esterno, usa il terminale. Non montare in scrittura dalla web app un volume esterno che contiene un volume nascosto da proteggere.

FileBrowser viene gestito da `veraprox-filebrowser.service`, avviato solo dopo che il controller ha verificato il volume configurato. Non è abilitato automaticamente al boot. In sola lettura il controller non avvia FileBrowser o Immich. Prima dello smontaggio ferma FileBrowser; se il volume è occupato, restituisce un errore senza dichiararlo smontato.

Per controllare eventuali errori:

```bash
systemctl status secure-webapp veraprox-filebrowser --no-pager -l
journalctl -u secure-webapp -u veraprox-filebrowser --no-pager -n 60
lsblk -p -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL,PARTUUID
```

## Integrazione facoltativa con Immich

Questa funzione gestisce uno stack già funzionante: non installa Docker, non modifica il Compose o `.env`, non sposta il database e non risolve una migrazione Windows/Linux.

Se lo stack arriva da Windows, i percorsi `U:\…` devono essere adattati a Linux. L'integrazione rifiuta bind mount PostgreSQL su NTFS/FUSE, exFAT o share NFS/SMB; per i volumi Docker nominati verifica anche il loro storage sottostante. Prima di spostare un database esistente servono un backup e una procedura di migrazione coerente con la sua versione. Se il database viene collocato su ext4 fuori da VeraCrypt, non è protetto dalla cifratura di quel volume: proteggi anche il suo storage se questo è un requisito.

Dopo aver corretto e verificato lo stack, con il volume montato:

```bash
veraprox-immich.sh /mnt/secure/docker/immich
```

Il comando verifica il Compose e salva la scelta, senza avviare lo stack. Dal successivo `mount-secure.sh` o montaggio web, Immich viene avviato; prima dello smontaggio viene arrestato. Il controller usa un override temporaneo per disabilitare il riavvio automatico dei container e la creazione implicita delle cartelle di bind mount. Se ci sono container già creati per quel progetto, il comando ne disabilita il riavvio automatico immediatamente.

L'avvio usa le immagini già scaricate (`--pull never --no-build`). Se mancano, il volume resta montato e viene segnalato l'errore: scarica esplicitamente le immagini della versione desiderata dopo aver verificato backup e compatibilità. Gli avvii effettuati direttamente con il Compose originale possono ripristinare `restart: always` e bypassare queste protezioni; usa il controller per lo stack integrato.

Altri container attivi con file sotto `/mnt/secure` bloccano lo smontaggio e vengono indicati nel messaggio di errore. Per disabilitare l'integrazione, prima smonta il volume, poi esegui:

```bash
python3 /usr/local/lib/veraprox/runtime.py disable-immich
```

L'interfaccia web e FileBrowser non includono TLS. Usali solo in una rete fidata oppure dietro un reverse proxy configurato con HTTPS. Non esporre le porte 5000 e 8080 direttamente a Internet.

## Password

Le password vengono richieste soltanto dal secondo script, dentro la VM, e non possono essere lasciate vuote. Il riepilogo dell'installazione le mostra come richiesto; non condividerne screenshot non censurati. L'aggiornamento del runtime conserva le credenziali esistenti.

## Avvertenze

Questo progetto modifica la configurazione della VM e abilita servizi di rete. Verifica con attenzione il dispositivo USB selezionato e conserva in modo sicuro le password di VeraCrypt: non possono essere recuperate se smarrite.

La web app gira ancora come root e usa il server di sviluppo Flask; l'aggiornamento non introduce HTTPS né trasforma il progetto in un servizio adatto a essere esposto direttamente a Internet. Non considera lo svuotamento delle cache una cancellazione sicura della memoria.

## Verifica per lo sviluppo

Con Python, Flask e Werkzeug disponibili:

```bash
python3 -m unittest discover -s tests -v
bash -n update-veraprox.sh
bash -n post-install-veracrypt.sh
```

I test verificano il controller incorporato nell'updater usando dispositivi e comandi simulati: non montano dischi reali. Il montaggio effettivo e l'integrazione con systemd, VeraCrypt e Docker devono essere verificati sulla macchina destinazione.
