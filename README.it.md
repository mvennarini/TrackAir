# TrackAir

**Trasforma iPhone o iPad in un trackpad e una tastiera per il Mac.**
A tutto schermo, con tutti i gesti di macOS, cifrato da capo a capo, senza
account, senza server: niente esce dalla tua rete Wi-Fi.

English: [README.md](README.md)

- Tocca per fare clic, clic secondario a due dita, scorrimento a due dita con
  la vera inerzia del trackpad (in Safari funzionano lo swipe indietro e
  l'effetto elastico), pizzico per lo zoom, trascinamento a tre dita, clic
  tenuto con un dito fermo, quattro dita per Spazi e Mission Control, pizzico
  a quattro dita per la vista App.
- Tastiera: scrivi qualsiasi testo sul Mac, con una barra Cmd / Ctrl / Alt /
  Shift / Esc / Tab / frecce per le scorciatoie. Funzionano anche le tastiere
  fisiche.
- iPad: tutto schermo oppure un trackpad ridimensionabile.
- Abbinamento inquadrando con la fotocamera un codice luminoso mostrato dal
  Mac (oppure un PIN di 6 cifre). Da lì in poi ogni pacchetto è cifrato e
  autenticato (X25519, HKDF, ChaCha20-Poly1305, protezione dal replay). Vedi
  `SECURITY.md`.
- App Mac nella barra dei menu: dispositivi abbinati, avvio al login, aiuto
  per il permesso Accessibilità.
- **Versione web**: l'app Mac serve il trackpad anche come pagina web, per
  qualsiasi telefono o tablet, senza App Store e senza scadenza.
- Italiano e inglese.

## Cosa serve

- Un Mac con macOS 13 o successivo.
- Un iPhone o iPad con iOS/iPadOS 17 o successivo, sulla stessa Wi-Fi del Mac.
- Per compilare e installare l'app iOS nativa: **Xcode 15 o successivo** e un
  Apple ID aggiunto in Xcode → Impostazioni → Account. Basta un account
  gratuito, con due limiti: l'app sul dispositivo **scade dopo 7 giorni** e va
  reinstallata, e si possono avere al massimo 3 app così. Vedi
  [AutoSign](https://github.com/mvennarini/AutoSign) per automatizzare il
  rinnovo, oppure usa la versione web, che non scade mai.
- [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

## Installazione sul Mac

1. Clona il repository e compila l'app Mac:
   ```
   git clone https://github.com/mvennarini/TrackAir.git
   cd TrackAir
   ./build.sh mac
   open build/TrackAir.app
   ```
   Lo script firma l'app con il tuo certificato Apple Development (lo crea
   Xcode quando aggiungi l'Apple ID), così il permesso Accessibilità resta
   valido anche dopo una ricompilazione.
2. Nella barra dei menu compare l'icona di una mano. macOS chiede il permesso
   **Accessibilità**: Impostazioni di Sistema → Privacy e sicurezza →
   Accessibilità, attiva TrackAir. È l'unico modo in cui un'app può muovere il
   puntatore.
3. Facoltativo: menu → **Avvia al login**.

## Installazione su iPhone o iPad (app nativa)

1. Collega il dispositivo con il cavo, sbloccalo e, se chiesto, autorizza il
   computer. Sul dispositivo attiva la **Modalità Sviluppatore** (Impostazioni
   → Privacy e sicurezza → Modalità Sviluppatore; iOS chiede un riavvio).
2. Compila e installa:
   ```
   ./build.sh ios
   ```
   La prima volta Xcode registra il dispositivo e crea un profilo con il tuo
   Apple ID: può volerci un minuto.
3. Se all'apertura iOS dice "Sviluppatore non attendibile": Impostazioni →
   Generali → VPN e gestione dispositivi → il tuo Apple ID → Autorizza.
4. Apri TrackAir. Consenti l'accesso alla **Rete locale** (serve per trovare
   il Mac) e, quando lo chiede, alla **fotocamera** (solo per leggere il codice
   di abbinamento).
5. Il Mac mostra un codice luminoso dentro una sfera fluttuante. Inquadralo.
   Fatto: il dispositivo resta abbinato per sempre. In alternativa digita il
   PIN scritto sotto al codice.
6. Lo schermo diventa il trackpad. In alto: un pallino verde (collegato), il
   bottone della tastiera e l'ingranaggio delle impostazioni.

Per rinnovare dopo 7 giorni: collega il dispositivo (o rendilo raggiungibile
via Wi-Fi con "Connetti tramite rete" attivo in Xcode → Dispositivi) e lancia
di nuovo `./build.sh ios`. Oppure lascia fare ad
[AutoSign](https://github.com/mvennarini/AutoSign).

## Installazione con la versione web (qualsiasi telefono, nessuna scadenza)

1. Con l'app Mac in esecuzione, apri il menu e scegli **Copia indirizzo web**
   (qualcosa come `http://mio-mac.local:7788`).
2. Sul telefono o sul tablet, sulla stessa Wi-Fi, apri quell'indirizzo in
   Safari (o in qualsiasi browser).
3. Condividi → **Aggiungi alla schermata Home**. Aprila dalla Home: va a tutto
   schermo.
4. Inserisci il PIN mostrato dal Mac. Stessi gesti, tastiera e cifratura
   dell'app nativa. Differenze: niente vibrazione ai clic, e l'abbinamento è
   solo con il PIN (i browser permettono la fotocamera solo in HTTPS).

## Gesti

| Gesto | Effetto |
|---|---|
| un dito | muove il puntatore (accelerazione come su macOS) |
| tap / doppio tap | clic / doppio clic |
| un dito fermo | clic tenuto, poi trascini con qualsiasi dito |
| due dita | scorrimento con inerzia |
| tap a due dita | clic secondario |
| pizzico | zoom (Cmd + / Cmd −) |
| tre dita | trascina |
| quattro dita a sinistra / destra | Spazio precedente / successivo |
| quattro dita in alto / in basso | Mission Control / lo chiude |
| pizzico a quattro dita | vista App (stringi per aprire, allarga per chiudere) |
| bottone tastiera | scrivi sul Mac; barra con modificatori, Esc, Tab, frecce |

I valori iniziali replicano le impostazioni Trackpad del Mac su cui l'app è
nata; ogni gesto è un interruttore nelle impostazioni.

## Dettagli di build

`project.yml` è la fonte di verità; `TrackAir.xcodeproj` viene generato da
xcodegen. `build.sh` rileva team e certificato dal portachiavi; si possono
forzare con le variabili d'ambiente `TEAM`, `MAC_SIGN_ID` e `BUNDLE_IOS`.
Cambia `BUNDLE_IOS` (e gli identificativi in `project.yml`) se pubblichi una
tua build.

```
./build.sh test     # test automatici del livello sicuro
./build.sh mac      # build/TrackAir.app
./build.sh ios      # compila e installa sull'iPhone/iPad collegato
./build.sh release  # build Mac firmata Developer ID e notarizzata (account a pagamento)
```

La sfera di abbinamento è disegnata con Metal; lo shader viene compilato
all'avvio da `Mac/SphereShaders.metal.txt`, quindi non serve il Metal
Toolchain per compilare.

## Struttura del progetto

```
Shared/Protocol.swift        messaggi (payload UDP da 9 byte)
Shared/Secure.swift          frame, abbinamento, cifratura, anti-replay, archivio dei dispositivi
Shared/Localizable.xcstrings inglese + italiano
Mac/                         app menu bar: Server (UDP), WebServer (HTTP + WebSocket),
                             MouseController (CGEvent), PairingController, SphereMetalView
Mac/trackpad.html            il client web
iOS/                         ciclo di vita UIKit + SwiftUI: Client, TrackpadView (motore dei gesti),
                             KeyboardBridge, ScannerView, ContentView
Tests/                       XCTest per il livello sicuro
Tools/makeicon.swift         l'icona, disegnata con CoreGraphics
```

## Privacy e sicurezza

Nessuna raccolta di dati; vedi `PRIVACY.md`. Modello di minaccia e protocollo
in `SECURITY.md`. Le segnalazioni di sicurezza vanno fatte in privato.

## Crediti

Progettato e scritto da Michele Vennarini con il supporto di strumenti di IA.

## Licenza

MIT. Componenti di terze parti in `THIRD_PARTY.md`.
