#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_TITLE="MulticastRTPAudioBridge"
APP_SLUG="multicast-rtp-audio-bridge"
SERVICE_PREFIX="mrab"
APP_USER="mrab"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/src"
APP_DIR="/opt/${APP_SLUG}"
CFG_DIR="/etc/${APP_SLUG}"
CFG_FILE="${CFG_DIR}/config.env"
WEB_PORT="${WEB_PORT:-8080}"
MCAST_IP="${MCAST_IP:-239.10.10.10}"
MCAST_PORT="${MCAST_PORT:-5004}"
MCAST_TTL="${MCAST_TTL:-1}"
RUN_USER="${SUDO_USER:-root}"

log(){ printf '[+] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Esegui con sudo/root."; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

check_source_tree() {
  [[ -f "${SOURCE_DIR}/web/app.py" ]] || die "File sorgente mancanti. Clona il repository completo e rilancia install.sh."
}

create_service_user() {
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
  fi
  usermod -aG audio "$APP_USER" || true
}

install_deps() {
  log "Installo dipendenze runtime"
  apt_install ca-certificates curl git sudo alsa-utils python3 python3-venv python3-pip \
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly
}

install_librespot() {
  if command_exists librespot; then
    log "librespot già presente: $(command -v librespot)"
    return
  fi

  if apt-cache show librespot >/dev/null 2>&1; then
    apt_install librespot
  fi
  command_exists librespot && return

  warn "librespot non disponibile via apt: compilo con Cargo"
  apt_install cargo pkg-config libasound2-dev
  local build_user="$RUN_USER"
  [[ "$build_user" != root ]] || build_user="$APP_USER"
  sudo -u "$build_user" bash -lc 'cargo install librespot --locked'
  local built_path
  built_path="$(getent passwd "$build_user" | cut -d: -f6)/.cargo/bin/librespot"
  [[ -x "$built_path" ]] || die "Build librespot fallita."
  install -m 0755 "$built_path" /usr/local/bin/librespot
}

enable_aloop() {
  printf 'snd-aloop\n' > /etc/modules-load.d/snd-aloop.conf
  modprobe snd-aloop || warn "snd-aloop non caricato ora; verifica il kernel se il problema persiste."
}

write_config() {
  install -d -m 0750 -o root -g "$APP_USER" "$CFG_DIR"
  if [[ ! -f "$CFG_FILE" ]]; then
    cat > "$CFG_FILE" <<EOF
SPOTIFY_NAME="${SPOTIFY_NAME:-MulticastRTPAudioBridge}"
MCAST_IP="${MCAST_IP}"
MCAST_PORT="${MCAST_PORT}"
MCAST_TTL="${MCAST_TTL}"
OPUS_BITRATE="${OPUS_BITRATE:-128000}"
STREAM_VOLUME="${STREAM_VOLUME:-1.0}"
ALOOP_PLAYBACK="${ALOOP_PLAYBACK:-hw:Loopback,0,0}"
ALOOP_CAPTURE="${ALOOP_CAPTURE:-hw:Loopback,1,0}"
LINEIN_CAPTURE="${LINEIN_CAPTURE:-auto}"
LINEIN_RATE="${LINEIN_RATE:-48000}"
LINEIN_CHANNELS="${LINEIN_CHANNELS:-2}"
LAST_SOURCE="${LAST_SOURCE:-off}"
EOF
  fi
  chown root:"$APP_USER" "$CFG_FILE"
  chmod 0660 "$CFG_FILE"
}

install_app() {
  log "Installo applicazione in ${APP_DIR}"
  install -d -m 0755 "$APP_DIR" "$APP_DIR/web/templates" "$APP_DIR/scripts"
  install -m 0644 "$SOURCE_DIR/web/app.py" "$APP_DIR/web/app.py"
  install -m 0644 "$SOURCE_DIR/web/templates/index.html" "$APP_DIR/web/templates/index.html"
  install -m 0644 "$SOURCE_DIR/web/templates/diagnostics.html" "$APP_DIR/web/templates/diagnostics.html"
  install -m 0755 "$SOURCE_DIR/scripts/"*.sh "$APP_DIR/scripts/"

  rm -rf "$APP_DIR/.venv"
  python3 -m venv "$APP_DIR/.venv"
  "$APP_DIR/.venv/bin/pip" install --disable-pip-version-check --no-cache-dir --upgrade pip
  "$APP_DIR/.venv/bin/pip" install --disable-pip-version-check --no-cache-dir 'flask>=3.1,<4' 'gunicorn>=23,<24'
  chown -R root:root "$APP_DIR"
}

create_units() {
  local librespot_bin
  librespot_bin="$(command -v librespot)"
  [[ -n "$librespot_bin" ]] || die "librespot non trovato."
  sed "s|@LIBRESPOT@|${librespot_bin}|g" "$APP_DIR/scripts/spotify_rx.sh" > "$APP_DIR/scripts/spotify_rx.runtime.sh"
  chmod 0755 "$APP_DIR/scripts/spotify_rx.runtime.sh"

  cat > /etc/systemd/system/${SERVICE_PREFIX}-spotify.service <<EOF
[Unit]
Description=${PROJECT_TITLE} - Spotify Connect receiver
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
SupplementaryGroups=audio
ExecStart=${APP_DIR}/scripts/spotify_rx.runtime.sh
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/${SERVICE_PREFIX}-stream-spotify.service <<EOF
[Unit]
Description=${PROJECT_TITLE} - Spotify RTP multicast stream
After=${SERVICE_PREFIX}-spotify.service sound.target
BindsTo=${SERVICE_PREFIX}-spotify.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
SupplementaryGroups=audio
ExecStart=${APP_DIR}/scripts/stream_spotify.sh
Restart=on-failure
RestartSec=1
EOF

  cat > /etc/systemd/system/${SERVICE_PREFIX}-stream-linein.service <<EOF
[Unit]
Description=${PROJECT_TITLE} - Line-In RTP multicast stream
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
SupplementaryGroups=audio
ExecStart=${APP_DIR}/scripts/stream_linein.sh
Restart=on-failure
RestartSec=1
EOF

  cat > /etc/systemd/system/${SERVICE_PREFIX}-web.service <<EOF
[Unit]
Description=${PROJECT_TITLE} - Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
SupplementaryGroups=audio
WorkingDirectory=${APP_DIR}/web
ExecStart=${APP_DIR}/.venv/bin/gunicorn --workers 1 --bind 0.0.0.0:${WEB_PORT} --access-logfile - app:app
Restart=on-failure
RestartSec=2
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${CFG_DIR}
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/${SERVICE_PREFIX}-autostart.service <<EOF
[Unit]
Description=${PROJECT_TITLE} - Restore last source
After=network-online.target sound.target ${SERVICE_PREFIX}-spotify.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${APP_DIR}/scripts/autostart.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

create_sudoers() {
  local systemctl_bin
  systemctl_bin="$(command -v systemctl)"
  cat > /etc/sudoers.d/${APP_SLUG} <<EOF
${APP_USER} ALL=(root) NOPASSWD: ${systemctl_bin} start ${SERVICE_PREFIX}-stream-spotify.service
${APP_USER} ALL=(root) NOPASSWD: ${systemctl_bin} stop ${SERVICE_PREFIX}-stream-spotify.service
${APP_USER} ALL=(root) NOPASSWD: ${systemctl_bin} restart ${SERVICE_PREFIX}-stream-spotify.service
${APP_USER} ALL=(root) NOPASSWD: ${systemctl_bin} is-active ${SERVICE_PREFIX}-stream-spotify.service
${APP_USER} ALL=(root) NOPASSWD: ${systemctl_bin} start ${SERVICE_PREFIX}-stream-linein.service
${APP_USER} ALL=(root) NOPASSWD: ${systemctl_bin} stop ${SERVICE_PREFIX}-stream-linein.service
${APP_USER} ALL=(root) NOPASSWD: ${systemctl_bin} restart ${SERVICE_PREFIX}-stream-linein.service
${APP_USER} ALL=(root) NOPASSWD: ${systemctl_bin} is-active ${SERVICE_PREFIX}-stream-linein.service
${APP_USER} ALL=(root) NOPASSWD: ${systemctl_bin} restart ${SERVICE_PREFIX}-spotify.service
${APP_USER} ALL=(root) NOPASSWD: ${systemctl_bin} is-active ${SERVICE_PREFIX}-spotify.service
EOF
  chmod 0440 /etc/sudoers.d/${APP_SLUG}
  visudo -cf /etc/sudoers.d/${APP_SLUG} >/dev/null || die "sudoers non valido."
}

enable_services() {
  systemctl enable --now ${SERVICE_PREFIX}-spotify.service ${SERVICE_PREFIX}-web.service ${SERVICE_PREFIX}-autostart.service
}

uninstall_app() {
  for svc in web stream-spotify stream-linein spotify autostart; do
    systemctl disable --now "${SERVICE_PREFIX}-${svc}.service" 2>/dev/null || true
  done
  rm -f /etc/systemd/system/${SERVICE_PREFIX}-{web,stream-spotify,stream-linein,spotify,autostart}.service
  rm -f /etc/sudoers.d/${APP_SLUG}
  systemctl daemon-reload
  rm -rf "$APP_DIR" "$CFG_DIR"
  userdel "$APP_USER" 2>/dev/null || true
  log "Disinstallazione completata (pacchetti apt lasciati installati)."
}

main() {
  need_root
  if [[ "${1:-}" == uninstall ]]; then uninstall_app; return; fi
  check_source_tree
  install_deps
  create_service_user
  enable_aloop
  install_librespot
  write_config
  install_app
  create_units
  create_sudoers
  enable_services
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  log "Installazione completata. Web UI: http://${ip:-127.0.0.1}:${WEB_PORT}"
  log "RTP multicast: ${MCAST_IP}:${MCAST_PORT} TTL ${MCAST_TTL}"
}

main "$@"
