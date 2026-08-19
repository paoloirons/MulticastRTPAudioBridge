#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/multicast-rtp-audio-bridge/config.env
exec @LIBRESPOT@ --name "$SPOTIFY_NAME" --backend alsa --device "$ALOOP_PLAYBACK" --bitrate 320
