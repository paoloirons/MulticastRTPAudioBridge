# MulticastRTPAudioBridge

Appliance Linux per trasformare Spotify Connect o un ingresso Line-In in uno stream RTP multicast Opus, con Web UI, volume, VU meter, diagnostica e ripristino dell'ultima sorgente al boot.

Default RTP: `239.10.10.10:5004`, TTL 1.

## Installazione

Clona/scarica **l'intero repository**, poi:

```bash
chmod +x install.sh
sudo ./install.sh
```

Il vecchio `multicast-rtp-audio-bridge-installer.sh` resta come wrapper compatibile e inoltra a `install.sh`.

## Sicurezza e runtime

- La Web UI gira come utente di servizio dedicato `mrab`, non come root.
- `sudoers` consente a `mrab` solo le azioni `systemctl` necessarie agli stream/receiver.
- Il servizio web usa Gunicorn con hardening systemd.
- Il VU meter usa un calcolo PCM interno compatibile con Python 3.13+ e non dipende da `audioop`.
- Il processo `arecord` del meter viene riavviato solo quando cambia sorgente/device, non a ogni polling del browser.

## Configurazione

File: `/etc/multicast-rtp-audio-bridge/config.env`.

Variabili principali: `SPOTIFY_NAME`, `MCAST_IP`, `MCAST_PORT`, `MCAST_TTL`, `STREAM_VOLUME`, `LINEIN_CAPTURE`, `LAST_SOURCE`.

## Disinstallazione

```bash
sudo ./install.sh uninstall
```
