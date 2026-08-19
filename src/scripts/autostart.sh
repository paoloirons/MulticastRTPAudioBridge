#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/multicast-rtp-audio-bridge/config.env
systemctl stop mrab-stream-spotify.service mrab-stream-linein.service 2>/dev/null || true
case "${LAST_SOURCE:-off}" in
  spotify) systemctl start mrab-stream-spotify.service ;;
  linein) systemctl start mrab-stream-linein.service ;;
  off) : ;;
  *) echo "LAST_SOURCE non valido: ${LAST_SOURCE}" >&2; exit 1 ;;
esac
