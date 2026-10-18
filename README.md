# ⚡ WinOptima Portable 3.1 — Ottimizzatore per Windows 10 e 11

**WinOptima Portable** è una suite portatile per ottimizzare le prestazioni, proteggere la privacy e pulire a fondo Windows 10 e 11, con un'interfaccia in **stile Windows 11** (Fluent: materiale Mica, tema chiaro/scuro automatico, colore di accento di sistema).

**[⬇ Scarica WinOptima.exe](https://github.com/brn78/WinOptima/releases/latest/download/WinOptima.exe)** · **[Pagina del progetto](https://brn78.github.io/WinOptima/)**

> Windows potrebbe mostrare «Windows ha protetto il PC»: l'exe non è firmato digitalmente. Clicca **Ulteriori informazioni → Esegui comunque**.

Non richiede installazione né dipendenze: **`WinOptima.exe` è un unico file portatile** da copiare dove vuoi (anche su chiavetta USB).

---

## 🚀 Come avviarla

Fai doppio clic su **`WinOptima.exe`**: chiede l'elevazione UAC, estrae il programma in **`%LOCALAPPDATA%\WinOptima`** (aggiornandolo solo se la versione è cambiata) e lo avvia da lì. Nella stessa cartella trovi preferenze, copie di sicurezza (`Backup\`) e l'eventuale log degli errori. Per rimuovere tutto basta cancellare l'exe e quella cartella.

Per lo sviluppo si può anche avviare lo script direttamente (`WinOptima.bat` oppure `WinOptima.ps1`). Per provare l'app senza rischi: `powershell -ExecutionPolicy Bypass -File .\WinOptima.ps1 -Simulate` (non servono i privilegi di amministratore e **non viene modificato nulla**).

## 🆕 Novità della versione 3.7.2
* **Aggiornamento senza residui**: dopo l'aggiornamento la versione precedente (`WinOptima.old.exe`) viene eliminata da sola, appena possibile o al primo avvio della nuova versione. Accanto resta solo `WinOptima.exe`.
* **Tutto schermo**: il contenuto occupa tutta la larghezza della finestra, allineato al titolo; nelle finestre strette i testi della barra dei comandi si accorciano senza sovrapporsi.

## 🆕 Novità della versione 3.7.1
* **Rete → Nascondi l'avviso sui file .rdp non firmati**: niente più finestra «Attenzione: connessione remota sconosciuta» introdotta dall'aggiornamento di aprile 2026. Usa l'impostazione documentata `RedirectionWarningDialogVersion = 1`, più `RdpLaunchConsentAccepted = 1` per l'avviso del primo avvio. Da usare solo verso PC che conosci: l'avviso protegge dai file .rdp di phishing, e Microsoft potrebbe rimuovere questa opzione in futuro. In alternativa, firmando i file .rdp l'avviso sparisce senza disattivare la protezione.

## 🆕 Novità della versione 3.7
* Nuova pagina **Driver**:
  * **Dispositivi con problemi** (driver mancante, non avviato, firma non valida…) presi da Gestione dispositivi, con l'**ID hardware** già ridotto alla forma che i siti riconoscono (es. `PCI\VEN_10EC&DEV_8168`). Per ognuno puoi aprire la pagina di **DriverPack** con versione e data del driver, cercare nel **Catalogo Microsoft Update** o copiare l'ID.
  * **Cerca driver online**: Windows Update, la fonte ufficiale, verifica quali driver mancanti o più recenti esistono per il tuo hardware. Quelli che risolvono un problema sono già spuntati; *Installa selezionati* li scarica e li installa, con punto di ripristino facoltativo.
  * Nota: DriverPack si apre nel browser per consultare i driver. Il programma DriverPack Solution non è necessario ed è noto per proporre software aggiuntivo durante l'installazione.

## 🆕 Novità della versione 3.6
* Logo **GitHub** in fondo al menu (e in *Impostazioni → Informazioni*): un clic apre il profilo [github.com/brn78](https://github.com/brn78). Accanto c'è anche il link al sito del progetto.

## 🆕 Novità della versione 3.5
* Nuova pagina **App preinstallate**:
  * **App dello Store** rimovibili, con *Rimozione consigliata* già indicata per quelle superflue (Microsoft 365/Office Hub, Notizie, Meteo, Solitaire, Clipchamp, Teams personale, Candy Crush, TikTok…). Con *Seleziona consigliate* ne spunti tante in un clic; su richiesta impedisce che tornino per i nuovi utenti. Componenti di sistema, Store, driver, utilità hardware ed Edge non vengono mai mostrati. Si reinstalla tutto dal Microsoft Store.
  * **Programmi desktop preinstallati** (Office/Microsoft 365 Click-to-Run in più lingue, OneNote, antivirus in prova come McAfee e Norton): *Disinstalla* avvia il disinstallatore ufficiale.

## 🆕 Novità della versione 3.4
* **Nascondi «Riprendi» dalla barra** (Windows 11), insieme a Cerca, Visualizzazione attività e Widget: tutti gli elementi della barra delle applicazioni si gestiscono da WinOptima.

## 🆕 Novità della versione 3.3
* **Nascondi «Cerca» dalla barra** (Personalizzazione → Barra delle applicazioni).
* **«Seleziona tutto» agisce solo sulla pagina visibile**: prima selezionava le voci di tutte le pagine (per esempio, dalla Pulizia attivava anche «Allinea la barra a sinistra»).

## 🆕 Novità della versione 3.2
* **Aggiornamenti automatici**: all'avvio WinOptima controlla le release su GitHub. Se c'è una versione nuova la scarica, ne verifica integrità (dimensione e SHA-256) e la installa alla chiusura, oppure subito con *Riavvia e aggiorna*. La versione precedente viene poi eliminata automaticamente. Si può disattivare da *Impostazioni → Aggiornamenti*.
* **Si vede sempre cosa sta succedendo**: barra «in corso» con il passo attuale (es. *Passo 5 di 17: Attivo: Menu più reattivi*), percentuale nel titolo e avanzamento sull'icona della barra delle applicazioni.
* **Registro attività ridimensionabile**: trascina la maniglia sul bordo superiore; l'altezza viene ricordata.
* **Widget**: ora si nascondono tramite la policy ufficiale di Windows (la vecchia chiave è protetta dal driver UCPD e dava «operazione non autorizzata»).

## 🆕 Novità della versione 3.1
* **Exe unico e portatile** che si estrae in AppData.
* Nuova pagina **Avvio e notifiche**:
  * **App di avvio** (registro utente, registro di sistema, cartelle Esecuzione automatica): interruttore attiva/disattiva compatibile con Gestione attività e pulsante **Elimina**, che prima salva una copia ripristinabile (file `.reg` da aprire con doppio clic, oppure il collegamento) in `Backup\Avvio`.
  * **Icone dell'area di notifica** (Windows 11): per ogni app scegli se l'icona resta visibile sulla barra o va nel menu «^»; più *Mostra tutte* / *Nascondi tutte*. Su Windows 10: «Mostra sempre tutte le icone».
* **Icone del desktop** in Personalizzazione: Questo PC, cartella utente, Rete, Pannello di controllo.
* **Strumenti** ampliati con collegamenti rapidi divisi per argomento: Gestione computer, Gestione dispositivi, Utilità di pianificazione, Connessioni di rete, Firewall, Visualizzatore eventi, Monitoraggio risorse e affidabilità, Informazioni di sistema e altro.

---

## ✨ Novità della versione 3.0

* **Interfaccia Windows 11**: navigazione laterale, card stile Impostazioni, interruttori (toggle), dialoghi di conferma, avvisi, scrollbar sottili, Mica sulle build che lo supportano. Si adatta da sola al tema e al colore di accento di Windows (o scegli *Chiaro/Scuro* da Impostazioni).
* **Nuova icona** e finestra con la propria identità nella barra delle applicazioni.
* **Ogni ottimizzazione mostra lo stato reale** del sistema e si può **ripristinare** (basta spegnere l'interruttore e applicare).
* **Conferma prima di applicare**: elenco preciso di ciò che verrà fatto, con l'opzione *«Crea prima un punto di ripristino»*.
* **Modalità simulazione**: il registro mostra cosa farebbe l'app senza toccare nulla.
* **Home** con CPU, RAM e disco in tempo reale, contatore delle ottimizzazioni attive e azioni rapide.
* **Analisi dello spazio recuperabile** prima di pulire, con risultato per ogni voce.
* **38 voci** (erano 24): nuove ottimizzazioni, nuove pulizie, DNS AdGuard, collegamenti rapidi agli strumenti di Windows.
* **Registro attività** colorato, con salvataggio su file.

### 🛠️ Correzioni rispetto alla 2.0
* **Il pulsante *Applica* e tutte le azioni in background non funzionavano**: usavano `ThreadPool.QueueUserWorkItem` con script block PowerShell, che nei thread del pool non hanno un runspace e fanno terminare il processo. Ora il lavoro gira in un runspace dedicato che comunica con la finestra tramite una coda di messaggi.
* **Accenti ed emoji corrotti**: lo script era salvato senza BOM UTF-8 e Windows PowerShell 5.1 lo leggeva come ANSI.
* **Pulizia dei dump**: tentava di eliminare la cartella `Minidump` come se fosse un file; ora ne svuota il contenuto.
* **Esito sincero**: TRIM e pulizie non dichiarano più «successo» quando falliscono; viene indicato quanti file erano in uso e quanto spazio è stato liberato davvero.
* **Riavvio di Explorer** più affidabile (non avvia una shell con privilegi elevati se Windows l'ha già riavviata).
* **DNS**: modificati solo gli adattatori fisici attivi (VPN e schede virtuali non vengono toccate).
* **RDP**: regole firewall indipendenti dalla lingua di Windows e avviso su Windows Home (che non include l'host).
* **Piano energetico**: se «Prestazioni elevate» è nascosto (tipico dei portatili) viene ricreato invece di non fare nulla.
* **Avviso se l'app non parte**: l'exe segnala l'errore e salva `WinOptima-error.log` invece di sparire in silenzio.

---

## 📋 Cosa puoi fare

### ⚡ Prestazioni
Menu contestuale classico · Menu più reattivi (50 ms) · Avvio programmi senza ritardo · Arresto più veloce (timeout a 2 s) · Piano energetico *Prestazioni elevate* · Disattiva registrazione Xbox (Game DVR) · *Avanzate:* Disattiva Avvio rapido · Disattiva ibernazione.

### 🛡️ Privacy
Telemetria al minimo · Cronologia attività off · ID pubblicitario off · Esperienze personalizzate off · Feedback su «Mai» · Ricerca Start solo locale (niente Bing) · Aggiornamenti senza condivisione P2P · *Avanzate:* Segnalazione errori di Windows off · Istantanee AI (Recall) off.

### 🎨 Personalizzazione
Estensioni sempre visibili · File nascosti · Apri Esplora file su «Questo PC» · Visualizzazione compatta · Barra a sinistra · Nascondi Widget · Nascondi «Visualizzazione attività» · Secondi nell'orologio · Blocca suggerimenti e app sponsorizzate (anche le installazioni automatiche) · Disattiva la scorciatoia Tasti permanenti · Icone del desktop (Questo PC, cartella utente, Rete, Pannello di controllo).

### 🧹 Pulizia
File temporanei utente e di sistema · Cache di Windows Update · Cestino · Crash dump · Report di errore · Cache Ottimizzazione recapito · Cache dei browser (Edge, Chrome, Brave, Firefox: cookie e password restano) · Cache DNS · TRIM dell'SSD · *Lenta:* pulizia dell'archivio componenti (WinSxS).

### ▶️ Avvio e notifiche
App di avvio (attiva/disattiva/elimina con copia di sicurezza) · Icone dell'area di notifica per singola app · Mostra/Nascondi tutte. Queste modifiche sono immediate, come in Gestione attività.

### 🌐 Rete
Desktop remoto (abilita/disabilita, con stato) · DNS Cloudflare, Google, Quad9, AdGuard o automatico (con indicazione di quello attivo) · Ripristino di Winsock e TCP/IP.

### 🔧 Strumenti
Punto di ripristino · SFC · DISM · Ripristino di Windows Update · Riavvio di Esplora risorse · Collegamenti rapidi:
* **Gestione del sistema**: Gestione computer, Gestione dispositivi, Gestione disco, Servizi, Utilità di pianificazione, App installate, Pannello di controllo, Proprietà del sistema, Protezione del sistema, Risparmio energia, Windows Update, Pulizia disco.
* **Rete**: Connessioni di rete, Stato della rete, Wi‑Fi, Windows Defender Firewall, Centro connessioni di rete e condivisione.
* **Diagnostica**: Gestione attività, Monitoraggio risorse, Visualizzatore eventi, Informazioni di sistema, Monitoraggio affidabilità, Prompt dei comandi (amministratore), Editor del Registro.

---

## 🔒 Sicurezza e reversibilità

* Nessuna modifica parte da sola: serve sempre **Applica** e una **conferma** con l'elenco delle operazioni.
* Passa il mouse su una voce per vedere **quali chiavi di registro** modifica.
* **Ripristina** = spegni l'interruttore e applica: vengono rimessi i valori predefiniti di Windows.
* La pulizia **rifiuta** radici di unità, `C:\Windows`, il profilo utente e le cartelle di programma; i file in uso vengono saltati.
* Un errore in una voce non blocca le altre: viene segnalato nel registro e si prosegue.
* Alcune chiavi (es. Widget) possono essere protette da Windows sulle build più recenti: in quel caso l'app lo segnala.

---

## 🗂️ Contenuto della cartella

| File | Scopo |
|---|---|
| `WinOptima.exe` | **L'unico file da distribuire** (contiene script e icona): si genera con `Build.ps1` e si pubblica solo nelle [release](https://github.com/brn78/WinOptima/releases) |
| `Publish.ps1` | Crea la release su GitHub con l'exe e tiene solo le ultime 2 |
| `WinOptima.ps1` | Sorgente dell'applicazione (motore + interfaccia), incorporato nell'exe |
| `WinOptima.bat` | Avvio diretto dello script (sviluppo) |
| `WinOptima.ico` | Icona (incorporata nell'exe) |
| `Launcher.cs`, `app.manifest`, `Build.ps1` | Sorgenti del launcher e script per ricostruire icona ed exe |
| `_backup-originale/` | Copia dei file della versione 2.0 (puoi eliminarla) |

In `%LOCALAPPDATA%\WinOptima` l'app crea `WinOptima.settings.json` (preferenze), `Backup\` (voci di avvio eliminate) e, in caso di problemi, `WinOptima-error.log`.

### Pubblicare una nuova versione
1. Aumenta `$script:AppVersion` in `WinOptima.ps1` (es. `'3.3'`): è l'unica fonte della versione, `Build.ps1` la copia nell'exe.
2. Fai commit e push.
3. `powershell -ExecutionPolicy Bypass -File .\Publish.ps1 -Notes "Cosa cambia"`: compila, crea la release `v3.3` con l'exe ed elimina quelle più vecchie, tenendo le ultime 2. Le copie installate si aggiornano da sole al prossimo avvio.

### Ricostruire icona ed exe
Non servono SDK: basta il compilatore incluso in Windows. Dopo ogni modifica a `WinOptima.ps1` rilancia la build, così l'exe incorpora la nuova versione.

```powershell
powershell -ExecutionPolicy Bypass -File .\Build.ps1
```

---

## ℹ️ Note tecniche

* **Requisiti**: Windows 10 o 11 con Windows PowerShell 5.1 (già incluso). Mica richiede Windows 11 22H2 o successivo; sulle versioni precedenti l'app usa uno sfondo a tinta unita.
* Le voci valide solo per Windows 11 (menu classico, barra a sinistra, Widget, Recall) non compaiono su Windows 10.
* I valori predefiniti di ripristino sono quelli di un'installazione standard di Windows.
