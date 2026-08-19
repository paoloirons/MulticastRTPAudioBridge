#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/multicast-rtp-audio-bridge/config.env
pick_linein() {
  if [[ "$LINEIN_CAPTURE" != auto ]]; then printf '%s\n' "$LINEIN_CAPTURE"; return; fi
  local card
  card="$(arecord -l 2>/dev/null | awk '/card [0-9]+:/ {gsub(":","",$2); print $2; exit}')"
  [[ -n "${card:-}" ]] && printf 'hw:%s,0\n' "$card" || printf 'default\n'
}
DEV="$(pick_linein)"
exec /usr/bin/gst-launch-1.0 -q \
  alsasrc device="$DEV" ! audioconvert ! audioresample ! \
  audio/x-raw,rate="$LINEIN_RATE",channels="$LINEIN_CHANNELS" ! \
  volume volume="$STREAM_VOLUME" ! opusenc bitrate="$OPUS_BITRATE" ! rtpopuspay ! \
  udpsink host="$MCAST_IP" port="$MCAST_PORT" auto-multicast=true ttl="$MCAST_TTL"
