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

I backup possono contenere credenziali vecchie e metadati; il database account e i log di sistema sono sul disco Debian, fuori da VeraCrypt. Cifrare il volume non cifra automaticamente tutto il sistema o la memoria. Quantum gira ancora come root per accedere al volume: usa account fidati. Il servizio limita le scritture al volume e alla propria configurazione, ma non è un isolamento completo del filesystem.

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

Il test opzionale del binario Quantum si attiva con `VERAPROX_QUANTUM_TEST_BINARY=/percorso/binario`. Avvia solo un server localhost con cartella vuota, verifica impostazione password/login e assenza della password scelta in chiaro nel DB e nei log. Gli altri test simulano dispositivi e comandi: systemd, mount VeraCrypt e cache NTFS vanno provati sulla macchina Debian.
