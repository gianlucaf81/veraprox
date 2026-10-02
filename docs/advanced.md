# Dettagli avanzati

## File e backup

- Controller condiviso: `/usr/local/lib/veraprox/runtime.py`.
- Dispositivo: `/etc/veraprox/device.conf`, identificativo stabile `by-partuuid` o `by-id`.
- Password web: hash in `/etc/veraprox/web.json`, root `600`.
- Quantum: `/usr/local/bin/filebrowser-quantum`; configurazione generata in `/etc/veraprox/filebrowser-quantum/config.yaml` (JSON valido come YAML).
- Account Quantum: `/etc/veraprox/filebrowser-quantum/quantum.db`, root `600`. La password scelta viene impostata via API locale e memorizzata come hash, non nel file di configurazione.
- Cache, miniature, indice SQLite e temporanei: `/mnt/secure/.veraprox-quantum`. SQLite resta una cache ricostruibile: su NTFS/FUSE possono esserci limitazioni di prestazioni/locking da verificare sulla macchina reale. Non è il database PostgreSQL di Immich.

L'installer Quantum usa il binario ufficiale v1.5.6-stable con checksum fissato. Per una nuova release occorre verificare configurazione, API e digest prima di aggiornare la versione nel codice. Il bootstrap gira brevemente su localhost con una password casuale, invalidata prima dell'installazione; non serve un servizio esposto in rete per creare l'account. L'installer Quantum supporta amd64 e arm64; l'installazione completa VeraCrypt resta per Debian 12 amd64.

Il backup Quantum contiene configurazione e database precedenti, binari e unit systemd. Il vecchio binario FileBrowser e `/etc/filebrowser` non vengono eliminati. Per tornare al precedente servizio, a volume smontato, ripristina `veraprox-filebrowser.service` dal backup Quantum indicato dall'installer e poi esegui `systemctl daemon-reload`. Non avviare due file manager sulla stessa porta. Una successiva esecuzione dell'updater privilegia nuovamente Quantum se la sua configurazione è presente.

I backup possono contenere credenziali vecchie e metadati; il database account e i log di sistema sono sul disco Debian, fuori da VeraCrypt. Cifrare il volume non cifra automaticamente tutto il sistema o la memoria. Quantum gira ancora come root per accedere al volume: usa account fidati. Il servizio usa `RootDirectory` e bind espliciti: vede il volume, il proprio database e i binari/librerie/file di sistema necessari, non l'intero filesystem Debian; le capability vengono rimosse e i dispositivi fisici e `/proc` non sono esposti. È una protezione aggiuntiva, non una garanzia contro vulnerabilità del programma o del kernel. Il controllo VeraCrypt pre-avvio rimane fuori dall'isolamento.

Non aggiungere `folderPath: /` alle regole Quantum v1.5.6: anche con `ignoreSymlinks` interferisce con gli attributi delle sottocartelle e produce `hasPreview: false`. I collegamenti interni al volume possono restare visibili; quelli verso file Debian non resi disponibili nella root isolata non possono accedere ai corrispondenti file host. Non disabilitare l'isolamento per risolvere un errore di avvio: controlla il journal. Configurazioni o override systemd personalizzati richiedono una verifica separata.

## Montaggio

Il controller rifiuta dispositivi mancanti, PARTUUID duplicati e mount non corrispondenti alla selezione. Non ripiega sul primo `/dev/sdX` disponibile. Gli identificativi stabili evitano errori, ma non autenticano crittograficamente il supporto.

La password web VeraCrypt passa su stdin, non negli argomenti dei processi. La web app include CSRF, cookie HttpOnly/SameSite e limite ai tentativi di login. Il volume occupato non viene smontato forzatamente. Lo smontaggio e lo svuotamento delle cache non garantiscono una cancellazione sicura della RAM.

## Integrazione facoltativa Immich

Rimane disabilitata salvo configurazione esplicita. Gestisce uno stack **già funzionante**: non installa Docker, non converte i percorsi Windows e non migra il database.

```bash
veraprox-immich.sh /mnt/secure/docker/immich
python3 /usr/local/lib/veraprox/runtime.py disable-immich  # solo a volume smontato
```

PostgreSQL su NTFS/FUSE, exFAT o condivisione NFS/SMB viene rifiutato. Prima di migrare un database esistente servono backup e ripristino compatibili con la versione. L'avvio non scarica nuove immagini; il controller arresta lo stack prima dello smontaggio e rifiuta altri container attivi sul volume.

## Test

Se APT si interrompe con `No space left on device`, controlla `df -h / /usr /var /tmp` e `df -i / /usr /var /tmp`. `apt-get clean` elimina soltanto i pacchetti scaricati dalla cache, non i file personali. Dopo aver liberato spazio, completa i pacchetti con `dpkg --configure -a` e, se necessario, `apt-get --no-install-recommends --fix-broken install` (controlla il piano prima di confermare). Non eseguire rimozioni automatiche per recuperare spazio senza verificarne l'elenco. L'installer Quantum ora esclude i pacchetti raccomandati e richiede almeno 512 MiB liberi nei filesystem di sistema; questa è una soglia minima, non una garanzia sullo spazio necessario.

Con Python, Flask e Werkzeug:

```bash
python3 -m unittest discover -s tests -v
bash -n update-veraprox.sh
bash -n post-install-veracrypt.sh
bash -n install-filebrowser-quantum.sh
```

Il test opzionale del binario Quantum si attiva con `VERAPROX_QUANTUM_TEST_BINARY=/percorso/binario`. Avvia solo un server localhost con media sintetici: verifica password/login dopo riavvio, vista `gallery`, disponibilità e risposta dell'anteprima in una sottocartella ed esclusione delle directory private. Gli altri test simulano dispositivi e comandi: mount VeraCrypt e cache NTFS vanno provati sulla macchina Debian.

L'updater verifica il nuovo isolamento **sulla macchina Debian prima di sostituire il servizio**: avvia un'unità systemd temporanea su localhost con DB separato, PNG e MP4 sintetici, controlla entrambe le anteprime e il rifiuto di un collegamento verso un'immagine esterna. La prova non monta né legge il volume reale e non usa credenziali esistenti. Il servizio di prova viene fermato e i file temporanei rimossi. Se fallisce, l'updater si interrompe senza applicare la riparazione del servizio; il journal della prova resta consultabile. Questo controllo non equivale a un audit di tutte le API.
