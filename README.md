# MulticastRTPAudioBridge

**Spotify Connect + Line-In → RTP Multicast (239.10.10.10:5004)**  
con **Web UI** (sorgente / volume / VU meter / diagnostica) e installer **single-file**.

---

## TL;DR (Cos’è e cosa fa)

**MulticastRTPAudioBridge** trasforma un Raspberry Pi (o qualunque macchina Linux Debian/Ubuntu ARM/x86_64) in una piccola “appliance” audio di rete:

- crea un **dispositivo Spotify Connect** (lo selezioni dall’app Spotify sul telefono)
- cattura una sorgente **analogica Line-In** (es. lettore CD, mixer, radio, PC) tramite scheda audio USB
- invia l’audio in rete come **RTP multicast** (un solo stream per tutti i receiver) verso destinazione fissa:

> **239.10.10.10:5004** (TTL 1)

- espone una **Web UI** semplice e carina:
  - selezione sorgente: **Spotify / Line-In / Stop**
  - controllo **volume** (software gain)
  - **VU meter** (livello RMS) sulla sorgente attiva
  - pagina **Diagnostics** con:
    - output di `arecord -l`, `aplay -l`
    - stato del modulo `snd_aloop`
    - impostazione da browser di:
      - `LINEIN_CAPTURE`
      - `SPOTIFY_NAME` (nome visibile in Spotify Connect, con restart automatico)

- salva l’**ultima sorgente selezionata** e la ripristina automaticamente al reboot.

---

## Perché questo progetto esiste (motivazione)

Molti sistemi audio “consumer” (Sonos/Chromecast/AirPlay) sono comodissimi ma:
- non parlano RTP multicast in modo “pro”
- non si integrano facilmente in architetture SIP/multicast/IP speakers
- spesso richiedono ecosistemi proprietari

I sistemi “pro” (IP speaker PoE, paging, multicast) invece:
- scalano benissimo
- funzionano su subnet/VLAN dedicate
- sono robusti e prevedibili
- ma non hanno una sorgente “Spotify/Line-In” pronta e plug-and-play open-source

**MulticastRTPAudioBridge** è quel “pezzo mancante”: una sorgente audio di rete semplice.

---

## Casi d’uso tipici

- palestra: musica di sottofondo su speaker IP multicast
- negozio / ufficio: streaming unico multicast verso più punti
- laboratorio: creare una sorgente multicast e testare speaker / network
- impianti PA: musica a bassa priorità + annunci su altri canali (non incluso qui, ma il multicast è la base)

---

## Come funziona (architettura)

### 1) Spotify
- `librespot` crea un dispositivo **Spotify Connect**
- l’audio viene inviato a **ALSA loopback** (`snd-aloop`) → “cavo virtuale”
- GStreamer prende l’audio dal loopback e lo manda in:
  - **Opus → RTP → UDP multicast**

### 2) Line-In
- cattura da un dispositivo ALSA (USB sound card)
- GStreamer manda lo stesso formato:
  - **Opus → RTP → UDP multicast**

### 3) Web UI
- gira su Flask (`:8080`)
- chiama solo una lista di azioni molto limitate via `sudoers`:
  - start/stop/restart dei servizi systemd stream
  - restart del receiver Spotify quando cambi nome

### 4) Persistenza “ultima sorgente”
- quando selezioni una sorgente dalla UI, viene scritto in config:
  - `LAST_SOURCE=spotify|linein|off`
- al boot un servizio `mrab-autostart.service` legge `LAST_SOURCE` e riattiva lo stream.

---

## Requisiti

### Hardware minimo
- Raspberry Pi (Pi 3/4/5 consigliato) **oppure** mini PC x86_64
- rete LAN con supporto multicast (meglio ancora subnet/VLAN dedicata)
- (opzionale ma consigliato) scheda audio USB con ingresso **Line-In**

### OS supportati
- Raspberry Pi OS (Debian)
- Debian
- Ubuntu Server

### Receiver (per ascoltare lo stream)
- IP speaker / endpoint che supporti RTP multicast  
  **oppure**  
- un PC con VLC (perfetto per test immediato)

---

## Installazione (single-file)

1) Salva lo script in un file, ad esempio:
`multicast-rtp-audio-bridge-installer.sh`

2) Esegui:

```bash
chmod +x multicast-rtp-audio-bridge-installer.sh
sudo ./multicast-rtp-audio-bridge-installer.sh
