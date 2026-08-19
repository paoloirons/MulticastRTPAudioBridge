#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/multicast-rtp-audio-bridge/config.env
exec /usr/bin/gst-launch-1.0 -q \
  alsasrc device="$ALOOP_CAPTURE" ! audioconvert ! audioresample ! \
  volume volume="$STREAM_VOLUME" ! opusenc bitrate="$OPUS_BITRATE" ! rtpopuspay ! \
  udpsink host="$MCAST_IP" port="$MCAST_PORT" auto-multicast=true ttl="$MCAST_TTL"
