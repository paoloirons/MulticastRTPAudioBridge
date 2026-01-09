#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# MulticastRTPAudioBridge - Single-file Installer (Debian/Ubuntu/Raspberry Pi OS)
#
# Features:
# - Spotify Connect receiver (librespot) -> ALSA loopback
# - Line-In capture (USB sound card) -> RTP multicast
# - Fixed RTP multicast destination: 239.10.10.10:5004 (TTL 1)
# - Web UI (Flask):
#     * select source (Spotify / Line-In / Stop)
#     * output volume (software gain)
#     * VU meter (RMS level) for the currently selected source
#     * diagnostics page: arecord/aplay output + set LINEIN_CAPTURE + set SPOTIFY_NAME
# - Remembers last selected source and restores it on boot (mrab-autostart.service)
#
# Usage:
#   sudo bash multicast-rtp-audio-bridge-installer.sh
#   sudo bash multicast-rtp-audio-bridge-installer.sh uninstall
# ------------------------------------------------------------------------------

set -euo pipefail

# ---- Project naming ----
PROJECT_TITLE="MulticastRTPAudioBridge"
APP_SLUG="multicast-rtp-audio-bridge"
SERVICE_PREFIX="mrab"

APP_DIR="/opt/${APP_SLUG}"
CFG_DIR="/etc/${APP_SLUG}"
CFG_FILE="${CFG_DIR}/config.env"

WEB_PORT="8080"

# Fixed multicast destination (as requested)
MCAST_IP="239.10.10.10"
MCAST_PORT="5004"
MCAST_TTL="1"

# Defaults
DEFAULT_SPOTIFY_NAME="${PROJECT_TITLE}"
DEFAULT_OPUS_BITRATE="128000"      # bps
DEFAULT_STREAM_VOLUME="1.0"        # 0.0 - 1.5
DEFAULT_LINEIN_RATE="48000"
DEFAULT_LINEIN_CHANNELS="2"
DEFAULT_LAST_SOURCE="off"          # spotify|linein|off

# ALSA loopback devices
ALOOP_PLAYBACK="hw:Loopback,0,0"
ALOOP_CAPTURE="hw:Loopback,1,0"

RUN_USER="${SUDO_USER:-$USER}"

# ---- Pretty output ----
if command -v tput >/dev/null 2>&1; then
  C_BOLD="$(tput bold || true)"; C_RED="$(tput setaf 1 || true)"
  C_GRN="$(tput setaf 2 || true)"; C_YLW="$(tput setaf 3 || true)"
  C_BLU="$(tput setaf 4 || true)"; C_RST="$(tput sgr0 || true)"
else
  C_BOLD=""; C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi

log()   { echo "${C_BLU}ℹ${C_RST} $*"; }
ok()    { echo "${C_GRN}✅${C_RST} $*"; }
warn()  { echo "${C_YLW}⚠️${C_RST} $*"; }
die()   { echo "${C_RED}✖${C_RST} $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Esegui con sudo: sudo bash $0"
  fi
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
    OS_NAME="${NAME:-unknown}"
  else
    OS_ID="unknown"; OS_VER="unknown"; OS_NAME="unknown"
  fi
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ---- Prompt for system name (Spotify device name) ----
prompt_system_name() {
  local name=""
  echo
  echo "${C_BOLD}Nome del dispositivo Spotify Connect${C_RST}"
  echo "Questo nome apparirà come dispositivo Spotify Connect sul telefono."
  echo "Esempi: \"Palestra\", \"Gym Audio\", \"Sala Corsi\""
  echo
  read -r -p "Inserisci nome (invio = \"${DEFAULT_SPOTIFY_NAME}\"): " name
  name="$(echo "${name}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [[ -z "${name}" ]]; then
    name="${DEFAULT_SPOTIFY_NAME}"
  fi
  # Basic sanitization for env files
  name="$(echo "${name}" | tr -d '\r\n' | sed 's/"/'\''/g')"
  echo "${name}"
}

# ---- librespot ----
install_librespot() {
  log "Installo Spotify Connect receiver (librespot)..."

  if command_exists librespot; then
    ok "librespot già presente: $(command -v librespot)"
    return
  fi

  # Try apt first
  if apt-cache show librespot >/dev/null 2>&1; then
    apt_install librespot
  fi

  if command_exists librespot; then
    ok "librespot installato via apt: $(command -v librespot)"
    return
  fi

  # Fallback build via cargo
  warn "librespot non disponibile via apt. Fallback: build via cargo (Rust)."
  apt_install cargo pkg-config libasound2-dev

  sudo -u "${RUN_USER}" bash -lc 'set -euo pipefail; cargo install librespot --locked'
  local built_path
  built_path="$(sudo -u "${RUN_USER}" bash -lc 'echo "$HOME/.cargo/bin/librespot"')"
  [[ -x "$built_path" ]] || die "Build librespot fallita: binario non trovato."
  install -m 0755 "$built_path" /usr/local/bin/librespot
  ok "librespot installato in /usr/local/bin/librespot"
}

# ---- ALSA loopback ----
enable_aloop() {
  log "Abilito ALSA loopback (snd-aloop)..."
  echo "snd-aloop" > /etc/modules-load.d/snd-aloop.conf
  modprobe snd-aloop || true
  ok "snd-aloop configurato (persistente) e caricato (se supportato)."
}

# ---- Create app files ----
create_app_files() {
  local spotify_name="$1"
  log "Creo file applicazione in ${APP_DIR}..."
  install -d "${APP_DIR}/webui/templates" "${APP_DIR}/scripts" "${CFG_DIR}"

  # Config (only if missing)
  if [[ ! -f "${CFG_FILE}" ]]; then
    cat > "${CFG_FILE}" <<EOF
# ${PROJECT_TITLE} configuration
SPOTIFY_NAME="${spotify_name}"

# Fixed multicast destination
MCAST_IP="${MCAST_IP}"
MCAST_PORT="${MCAST_PORT}"
MCAST_TTL="${MCAST_TTL}"

# Audio settings
OPUS_BITRATE="${DEFAULT_OPUS_BITRATE}"     # bps
STREAM_VOLUME="${DEFAULT_STREAM_VOLUME}"   # 0.0 - 1.5 (software gain)

# ALSA loopback devices
ALOOP_PLAYBACK="${ALOOP_PLAYBACK}"
ALOOP_CAPTURE="${ALOOP_CAPTURE}"

# Line-in capture:
# - "auto" (default): pick first card from arecord -l
# - or explicit "hw:1,0" / "plughw:1,0" / "default"
LINEIN_CAPTURE="auto"
LINEIN_RATE="${DEFAULT_LINEIN_RATE}"
LINEIN_CHANNELS="${DEFAULT_LINEIN_CHANNELS}"

# Persisted last selected source: spotify|linein|off
LAST_SOURCE="${DEFAULT_LAST_SOURCE}"
EOF
    ok "Creato ${CFG_FILE}"
  else
    ok "Config esistente: ${CFG_FILE} (non modificata)"
  fi

  # scripts/stream_linein.sh
  cat > "${APP_DIR}/scripts/stream_linein.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/multicast-rtp-audio-bridge/config.env

pick_linein() {
  if [[ "${LINEIN_CAPTURE}" != "auto" ]]; then
    echo "${LINEIN_CAPTURE}"
    return
  fi
  local card
  card="$(arecord -l 2>/dev/null | awk '/card [0-9]+:/ {gsub(":","",$2); print $2; exit}')"
  if [[ -z "${card:-}" ]]; then
    echo "default"
  else
    echo "hw:${card},0"
  fi
}

DEV="$(pick_linein)"

exec /usr/bin/gst-launch-1.0 -q \
  alsasrc device="${DEV}" ! audioconvert ! audioresample ! \
  audio/x-raw,rate=${LINEIN_RATE},channels=${LINEIN_CHANNELS} ! \
  volume volume=${STREAM_VOLUME} ! \
  opusenc bitrate=${OPUS_BITRATE} ! rtpopuspay ! \
  udpsink host=${MCAST_IP} port=${MCAST_PORT} auto-multicast=true ttl=${MCAST_TTL}
EOF
  chmod +x "${APP_DIR}/scripts/stream_linein.sh"

  # scripts/autostart.sh
  cat > "${APP_DIR}/scripts/autostart.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CFG="/etc/multicast-rtp-audio-bridge/config.env"
source "${CFG}"

stop_all() {
  systemctl stop mrab-stream-spotify.service 2>/dev/null || true
  systemctl stop mrab-stream-linein.service 2>/dev/null || true
}

case "${LAST_SOURCE:-off}" in
  spotify)
    stop_all
    systemctl start mrab-stream-spotify.service
    ;;
  linein)
    stop_all
    systemctl start mrab-stream-linein.service
    ;;
  off|*)
    stop_all
    ;;
esac
EOF
  chmod +x "${APP_DIR}/scripts/autostart.sh"

  # webui/app.py (VU meter + last source persistence + spotify name change)
  cat > "${APP_DIR}/webui/app.py" <<'EOF'
from flask import Flask, render_template, request, jsonify
import subprocess
import threading
import time
import audioop

CFG = "/etc/multicast-rtp-audio-bridge/config.env"
SERVICE_PREFIX = "mrab"

def sh(cmd):
    return subprocess.check_output(cmd, text=True).strip()

def run(cmd):
    return subprocess.run(cmd, text=True, capture_output=True)

def svc_active(name: str) -> bool:
    try:
        out = sh(["sudo", "/bin/systemctl", "is-active", name])
        return out == "active"
    except Exception:
        return False

def read_cfg() -> dict:
    data = {}
    with open(CFG, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            data[k.strip()] = v.strip().strip('"')
    return data

def write_cfg(updates: dict):
    with open(CFG, "r", encoding="utf-8") as f:
        lines = f.readlines()
    new_lines = []
    for line in lines:
        raw = line
        s = line.strip()
        if s and not s.startswith("#") and "=" in s:
            k = s.split("=", 1)[0].strip()
            if k in updates:
                val = str(updates[k]).replace('"', "'").replace("\n","").replace("\r","")
                raw = f'{k}="{val}"\n'
        new_lines.append(raw)
    with open(CFG, "w", encoding="utf-8") as f:
        f.writelines(new_lines)

def safe_system_info():
    info = {}

    def cmd_out(cmd_list):
        try:
            r = run(cmd_list)
            out = (r.stdout or "").strip()
            err = (r.stderr or "").strip()
            if r.returncode != 0 and not out:
                return f"(exit {r.returncode}) {err}"
            return out if out else err
        except Exception as e:
            return str(e)

    info["hostname"] = cmd_out(["hostname"])
    info["ip"] = cmd_out(["bash", "-lc", "hostname -I | awk '{print $1}'"])
    info["uname"] = cmd_out(["uname", "-a"])
    info["arecord_l"] = cmd_out(["arecord", "-l"])
    info["aplay_l"] = cmd_out(["aplay", "-l"])
    info["lsmod_aloop"] = cmd_out(["bash", "-lc", "lsmod | grep -E '^snd_aloop\\b' || true"])
    info["services"] = {
        "spotify_rx": svc_active(f"{SERVICE_PREFIX}-spotify.service"),
        "spotify_stream": svc_active(f"{SERVICE_PREFIX}-stream-spotify.service"),
        "linein_stream": svc_active(f"{SERVICE_PREFIX}-stream-linein.service"),
        "web": True,
    }
    return info

def pick_linein_device(cfg: dict) -> str:
    dev = (cfg.get("LINEIN_CAPTURE") or "auto").strip()
    if dev != "auto":
        return dev

    # auto: pick first card from `arecord -l`
    try:
        out = sh(["arecord", "-l"])
        for line in out.splitlines():
            line = line.strip()
            # Example: "card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]"
            if line.startswith("card "):
                parts = line.split()
                # parts[1] is like "1:"
                card = parts[1].replace(":", "")
                return f"hw:{card},0"
    except Exception:
        pass

    return "default"

class Meter:
    """
    Simple VU meter based on arecord capturing raw PCM and computing RMS.
    - 16-bit little endian, 48kHz, 2ch (reasonable defaults)
    - If capture fails, meter shows 0 and error string is stored.
    """
    def __init__(self):
        self._lock = threading.Lock()
        self._proc = None
        self._thread = None
        self._stop = False
        self.level = 0          # 0..100
        self.source = "off"
        self.error = ""
        self.device = ""

    def start(self):
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def set_source(self, source: str, device: str):
        with self._lock:
            self.source = source
            self.device = device
        self._restart_proc()

    def _restart_proc(self):
        # terminate existing process
        try:
            if self._proc and self._proc.poll() is None:
                self._proc.terminate()
                try:
                    self._proc.wait(timeout=1.0)
                except Exception:
                    self._proc.kill()
        except Exception:
            pass
        self._proc = None

        with self._lock:
            src = self.source
            dev = self.device

        if src == "off" or not dev:
            with self._lock:
                self.level = 0
                self.error = ""
            return

        # Start arecord: raw S16_LE stereo 48k
        # We keep it lightweight: -t raw outputs raw bytes.
        try:
            self._proc = subprocess.Popen(
                ["arecord", "-D", dev, "-f", "S16_LE", "-r", "48000", "-c", "2", "-t", "raw"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=0,
            )
            with self._lock:
                self.error = ""
        except Exception as e:
            with self._lock:
                self.level = 0
                self.error = f"arecord start failed: {e}"

    def _run(self):
        # Main loop: every ~100ms compute RMS on chunk
        while not self._stop:
            proc = self._proc
            if not proc or proc.stdout is None:
                time.sleep(0.2)
                continue

            try:
                data = proc.stdout.read(4096)
                if not data:
                    # maybe arecord exited; capture stderr for diagnostics
                    if proc.poll() is not None and proc.stderr is not None:
                        err = proc.stderr.read().decode("utf-8", errors="ignore").strip()
                        with self._lock:
                            self.error = err or "arecord stopped"
                            self.level = 0
                    time.sleep(0.2)
                    continue

                # RMS for 16-bit samples. audioop.rms returns 0..32767
                rms = audioop.rms(data, 2)  # width=2 bytes
                # Map to 0..100 with a soft curve. Adjust if you want.
                #  - 0..2000 quiet
                #  - 8000 moderate
                #  - 16000 loud
                lvl = int(min(100, (rms / 16000.0) * 100))
                with self._lock:
                    # simple smoothing: decay
                    self.level = max(lvl, int(self.level * 0.8))
            except Exception as e:
                with self._lock:
                    self.error = f"meter read error: {e}"
                    self.level = 0
                time.sleep(0.2)

    def snapshot(self):
        with self._lock:
            return {
                "level": int(self.level),
                "source": self.source,
                "device": self.device,
                "error": self.error,
            }

meter = Meter()

def current_selected_source(cfg: dict) -> str:
    # Determine active stream service
    if svc_active(f"{SERVICE_PREFIX}-stream-spotify.service"):
        return "spotify"
    if svc_active(f"{SERVICE_PREFIX}-stream-linein.service"):
        return "linein"
    return "off"

def update_meter_from_services():
    cfg = read_cfg()
    src = current_selected_source(cfg)
    if src == "spotify":
        dev = (cfg.get("ALOOP_CAPTURE") or "hw:Loopback,1,0").strip()
        meter.set_source("spotify", dev)
    elif src == "linein":
        dev = pick_linein_device(cfg)
        meter.set_source("linein", dev)
    else:
        meter.set_source("off", "")

app = Flask(__name__)

@app.get("/")
def index():
    cfg = read_cfg()
    return render_template(
        "index.html",
        cfg=cfg,
        spotify_on=svc_active(f"{SERVICE_PREFIX}-stream-spotify.service"),
        linein_on=svc_active(f"{SERVICE_PREFIX}-stream-linein.service"),
    )

@app.get("/diagnostics")
def diagnostics():
    cfg = read_cfg()
    info = safe_system_info()
    return render_template("diagnostics.html", cfg=cfg, info=info)

@app.post("/api/source")
def set_source():
    src = request.json.get("source")
    if src not in ("spotify", "linein", "off"):
        return jsonify({"ok": False, "error": "invalid source"}), 400

    # stop all first
    subprocess.call(["sudo", "/bin/systemctl", "stop", f"{SERVICE_PREFIX}-stream-spotify.service"])
    subprocess.call(["sudo", "/bin/systemctl", "stop", f"{SERVICE_PREFIX}-stream-linein.service"])

    if src == "spotify":
        subprocess.check_call(["sudo", "/bin/systemctl", "start", f"{SERVICE_PREFIX}-stream-spotify.service"])
    elif src == "linein":
        subprocess.check_call(["sudo", "/bin/systemctl", "start", f"{SERVICE_PREFIX}-stream-linein.service"])

    # persist
    write_cfg({"LAST_SOURCE": src})

    # update meter
    update_meter_from_services()

    return jsonify({"ok": True})

@app.post("/api/volume")
def set_volume():
    vol = float(request.json.get("volume"))
    if not (0.0 <= vol <= 1.5):
        return jsonify({"ok": False, "error": "volume out of range"}), 400

    write_cfg({"STREAM_VOLUME": str(vol)})

    # restart active streams to apply
    if svc_active(f"{SERVICE_PREFIX}-stream-spotify.service"):
        subprocess.call(["sudo", "/bin/systemctl", "restart", f"{SERVICE_PREFIX}-stream-spotify.service"])
    if svc_active(f"{SERVICE_PREFIX}-stream-linein.service"):
        subprocess.call(["sudo", "/bin/systemctl", "restart", f"{SERVICE_PREFIX}-stream-linein.service"])

    return jsonify({"ok": True})

@app.post("/api/linein")
def set_linein_capture():
    dev = (request.json.get("device") or "").strip()
    if not dev:
        return jsonify({"ok": False, "error": "missing device"}), 400

    allowed_prefixes = ("auto", "default", "hw:", "plughw:")
    if not dev.startswith(allowed_prefixes):
        return jsonify({"ok": False, "error": "device not allowed"}), 400

    write_cfg({"LINEIN_CAPTURE": dev})

    if svc_active(f"{SERVICE_PREFIX}-stream-linein.service"):
        subprocess.call(["sudo", "/bin/systemctl", "restart", f"{SERVICE_PREFIX}-stream-linein.service"])

    # meter might depend on capture device
    update_meter_from_services()

    return jsonify({"ok": True, "device": dev})

@app.post("/api/spotify_name")
def set_spotify_name():
    name = (request.json.get("name") or "").strip()
    if not name:
        return jsonify({"ok": False, "error": "missing name"}), 400
    if len(name) > 64:
        return jsonify({"ok": False, "error": "name too long (max 64)"}), 400

    write_cfg({"SPOTIFY_NAME": name})
    subprocess.call(["sudo", "/bin/systemctl", "restart", f"{SERVICE_PREFIX}-spotify.service"])

    return jsonify({"ok": True, "name": name})

@app.get("/api/status")
def status():
    cfg = read_cfg()
    return jsonify({
        "spotify_on": svc_active(f"{SERVICE_PREFIX}-stream-spotify.service"),
        "linein_on": svc_active(f"{SERVICE_PREFIX}-stream-linein.service"),
        "volume": float(cfg.get("STREAM_VOLUME", "1.0")),
        "mcast": f'{cfg.get("MCAST_IP")}:{cfg.get("MCAST_PORT")}',
        "spotify_name": cfg.get("SPOTIFY_NAME", "Spotify"),
        "linein_capture": cfg.get("LINEIN_CAPTURE", "auto"),
        "last_source": cfg.get("LAST_SOURCE", "off"),
    })

@app.get("/api/meter")
def meter_api():
    # Ensure meter follows current state
    update_meter_from_services()
    return jsonify(meter.snapshot())

def boot_init():
    # Start meter thread and sync once
    meter.start()
    update_meter_from_services()

boot_init()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
EOF

  # webui/templates/index.html (VU meter + last source indicator)
  cat > "${APP_DIR}/webui/templates/index.html" <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>MulticastRTPAudioBridge</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <style>
    .vu-wrap { height: 14px; background: rgba(0,0,0,.08); border-radius: 999px; overflow:hidden; }
    .vu-bar  { height: 14px; width: 0%; transition: width .12s linear; }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; }
  </style>
</head>
<body class="bg-light">
<div class="container py-4" style="max-width: 980px;">
  <div class="d-flex align-items-center justify-content-between mb-3">
    <div>
      <h2 class="m-0">MulticastRTPAudioBridge</h2>
      <div class="text-muted small">Spotify + Line-In → RTP Multicast</div>
    </div>
    <div class="d-flex align-items-center gap-2">
      <a class="btn btn-outline-secondary btn-sm" href="/diagnostics">Diagnostics</a>
      <span class="badge bg-secondary">RTP {{ cfg["MCAST_IP"] }}:{{ cfg["MCAST_PORT"] }}</span>
    </div>
  </div>

  <div class="row g-3">
    <div class="col-12 col-lg-7">
      <div class="card shadow-sm h-100">
        <div class="card-body">
          <h5 class="card-title">Sorgente</h5>
          <p class="text-muted mb-3">
            Spotify apparirà sul telefono come <b>{{ cfg["SPOTIFY_NAME"] }}</b>.
          </p>

          <div class="d-flex gap-2 flex-wrap">
            <button class="btn btn-primary" onclick="setSource('spotify')">
              Spotify Connect
              <span id="spotifyBadge" class="badge bg-light text-dark ms-2">{{ "ON" if spotify_on else "OFF" }}</span>
            </button>

            <button class="btn btn-primary" onclick="setSource('linein')">
              Line-In
              <span id="lineinBadge" class="badge bg-light text-dark ms-2">{{ "ON" if linein_on else "OFF" }}</span>
            </button>

            <button class="btn btn-outline-danger" onclick="setSource('off')">Stop</button>
          </div>

          <div class="mt-3 small text-muted">
            Ultima sorgente salvata: <span class="badge bg-secondary" id="lastSrc">...</span>
          </div>

          <hr class="my-4"/>

          <h6 class="mb-2">VU meter (sorgente attiva)</h6>
          <div class="vu-wrap mb-2">
            <div id="vu" class="vu-bar bg-success"></div>
          </div>
          <div class="d-flex justify-content-between small text-muted">
            <span>0</span>
            <span class="mono" id="vuTxt">0%</span>
            <span>100</span>
          </div>
          <div class="small text-muted mt-2">
            <span>Device: </span><span class="mono" id="vuDev">-</span>
            <span class="ms-3">Errore: </span><span class="mono" id="vuErr">-</span>
          </div>

          <hr class="my-4"/>

          <h6 class="mb-2">Test rapido</h6>
          <div class="text-muted small">
            Su un PC con VLC: Media → Open Network Stream:
            <div class="mt-1"><code>rtp://@{{ cfg["MCAST_IP"] }}:{{ cfg["MCAST_PORT"] }}</code></div>
          </div>

          <div class="alert alert-secondary mt-4 mb-0 small">
            <b>Tip:</b> per Line-In, se non senti niente, vai su <b>Diagnostics</b> e imposta <code>LINEIN_CAPTURE</code>.
          </div>
        </div>
      </div>
    </div>

    <div class="col-12 col-lg-5">
      <div class="card shadow-sm h-100">
        <div class="card-body">
          <h5 class="card-title">Volume uscita</h5>
          <div class="text-muted small mb-2">Range 0.0 – 1.5 (software gain)</div>
          <input id="vol" type="range" class="form-range" min="0" max="1.5" step="0.01" value="{{ cfg['STREAM_VOLUME'] }}">
          <div class="d-flex justify-content-between">
            <small class="text-muted">0.0</small>
            <small class="text-muted">1.5</small>
          </div>
          <div class="mt-3 d-flex align-items-center gap-2">
            <button class="btn btn-success" onclick="applyVolume()">Applica</button>
            <span id="volLabel" class="text-muted">attuale: {{ cfg['STREAM_VOLUME'] }}</span>
          </div>

          <hr class="my-4"/>

          <h6 class="mb-2">Stato</h6>
          <div class="small">
            <div>Spotify stream: <span id="s1" class="badge bg-secondary">?</span></div>
            <div class="mt-1">Line-In stream: <span id="s2" class="badge bg-secondary">?</span></div>
            <div class="mt-3 text-muted small">Line-In capture: <code id="cap">...</code></div>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<script>
async function setSource(source){
  await fetch('/api/source', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({source})});
  await refresh();
}
async function applyVolume(){
  const v = parseFloat(document.getElementById('vol').value);
  await fetch('/api/volume', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({volume:v})});
  await refresh();
}
function badge(el, on){
  el.className = "badge " + (on ? "bg-success" : "bg-secondary");
  el.textContent = on ? "ON" : "OFF";
}
async function refresh(){
  const r = await fetch('/api/status');
  const s = await r.json();
  document.getElementById('spotifyBadge').textContent = s.spotify_on ? 'ON' : 'OFF';
  document.getElementById('lineinBadge').textContent = s.linein_on ? 'ON' : 'OFF';
  document.getElementById('volLabel').textContent = 'attuale: ' + s.volume.toFixed(2);
  badge(document.getElementById('s1'), s.spotify_on);
  badge(document.getElementById('s2'), s.linein_on);
  document.getElementById('cap').textContent = s.linein_capture || "auto";
  document.getElementById('lastSrc').textContent = (s.last_source || "off").toUpperCase();
}

async function pollMeter(){
  const r = await fetch('/api/meter');
  const m = await r.json();
  const lvl = Math.max(0, Math.min(100, m.level || 0));
  const bar = document.getElementById('vu');
  bar.style.width = lvl + "%";
  document.getElementById('vuTxt').textContent = lvl + "%";

  // color logic
  bar.className = "vu-bar " + (lvl < 60 ? "bg-success" : (lvl < 85 ? "bg-warning" : "bg-danger"));

  document.getElementById('vuDev').textContent = m.device || "-";
  document.getElementById('vuErr').textContent = (m.error && m.error.length) ? m.error : "-";
}

refresh();
setInterval(refresh, 2500);
pollMeter();
setInterval(pollMeter, 200);
</script>
</body>
</html>
EOF

  # webui/templates/diagnostics.html (set LINEIN_CAPTURE + set SPOTIFY_NAME)
  cat > "${APP_DIR}/webui/templates/diagnostics.html" <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Diagnostics - MulticastRTPAudioBridge</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <style> pre { white-space: pre-wrap; word-break: break-word; } </style>
</head>
<body class="bg-light">
<div class="container py-4" style="max-width: 1000px;">
  <div class="d-flex align-items-center justify-content-between mb-3">
    <div>
      <h2 class="m-0">Diagnostics</h2>
      <div class="text-muted small">Setup & troubleshooting</div>
    </div>
    <div class="d-flex gap-2">
      <a class="btn btn-outline-secondary btn-sm" href="/">← Back</a>
      <span class="badge bg-secondary">RTP {{ cfg["MCAST_IP"] }}:{{ cfg["MCAST_PORT"] }}</span>
    </div>
  </div>

  <div class="row g-3">
    <div class="col-12 col-lg-5">
      <div class="card shadow-sm">
        <div class="card-body">
          <h5 class="card-title">Impostazioni</h5>

          <div class="mb-3">
            <label class="form-label">Spotify device name</label>
            <div class="input-group">
              <input id="sname" class="form-control" value="{{ cfg.get('SPOTIFY_NAME','MulticastRTPAudioBridge') }}">
              <button class="btn btn-primary" onclick="applySpotifyName()">Apply</button>
            </div>
            <div class="form-text">
              Aggiorna il nome visibile in Spotify Connect (riavvia il receiver automaticamente).
            </div>
          </div>

          <hr/>

          <h5 class="card-title">Line-In capture</h5>
          <p class="text-muted small mb-2">
            Imposta <code>LINEIN_CAPTURE</code>. Usa <code>auto</code> oppure ALSA tipo <code>hw:1,0</code>.
          </p>

          <div class="input-group">
            <input id="linein" class="form-control" placeholder="auto / default / hw:1,0 / plughw:1,0" value="{{ cfg.get('LINEIN_CAPTURE','auto') }}">
            <button class="btn btn-primary" onclick="applyLinein()">Apply</button>
          </div>

          <div class="form-text">
            Suggerimento: guarda <b>arecord -l</b> e usa il numero di <i>card</i> (es. <code>hw:1,0</code>).
          </div>

          <hr class="my-4"/>

          <h6 class="mb-2">Services</h6>
          <div class="small">
            <div>Spotify receiver: <span id="svc_rx" class="badge bg-secondary">?</span></div>
            <div class="mt-1">Spotify stream: <span id="svc_sp" class="badge bg-secondary">?</span></div>
            <div class="mt-1">Line-In stream: <span id="svc_li" class="badge bg-secondary">?</span></div>
            <div class="mt-1">snd_aloop: <span id="aloop" class="badge bg-secondary">?</span></div>
          </div>

          <hr class="my-4"/>

          <h6 class="mb-2">System</h6>
          <div class="small text-muted">
            <div><b>Host:</b> {{ info["hostname"] }}</div>
            <div><b>IP:</b> {{ info["ip"] }}</div>
          </div>
        </div>
      </div>
    </div>

    <div class="col-12 col-lg-7">
      <div class="card shadow-sm mb-3">
        <div class="card-body">
          <h5 class="card-title">arecord -l</h5>
          <pre class="bg-dark text-light p-3 rounded-3 mb-0">{{ info["arecord_l"] }}</pre>
        </div>
      </div>

      <div class="card shadow-sm mb-3">
        <div class="card-body">
          <h5 class="card-title">aplay -l</h5>
          <pre class="bg-dark text-light p-3 rounded-3 mb-0">{{ info["aplay_l"] }}</pre>
        </div>
      </div>

      <div class="card shadow-sm">
        <div class="card-body">
          <h5 class="card-title">Kernel module</h5>
          <div class="text-muted small mb-2">lsmod | grep snd_aloop</div>
          <pre class="bg-dark text-light p-3 rounded-3 mb-0">{{ info["lsmod_aloop"] }}</pre>
        </div>
      </div>
    </div>
  </div>
</div>

<script>
function badge(el, on){
  el.className = "badge " + (on ? "bg-success" : "bg-secondary");
  el.textContent = on ? "OK" : "OFF";
}

async function refresh(){
  const r = await fetch('/api/status');
  const s = await r.json();

  const rx = {{ "true" if info["services"]["spotify_rx"] else "false" }};
  badge(document.getElementById('svc_rx'), rx);
  badge(document.getElementById('svc_sp'), s.spotify_on);
  badge(document.getElementById('svc_li'), s.linein_on);

  const aloop_present = {{ "true" if info["lsmod_aloop"] else "false" }};
  badge(document.getElementById('aloop'), aloop_present);

  document.getElementById('linein').value = s.linein_capture || "auto";
  document.getElementById('sname').value = s.spotify_name || "MulticastRTPAudioBridge";
}

async function applyLinein(){
  const dev = document.getElementById('linein').value.trim();
  const res = await fetch('/api/linein', {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body: JSON.stringify({device: dev})
  });

  if(!res.ok){
    const e = await res.json();
    alert("Errore: " + (e.error || "unknown"));
    return;
  }
  await refresh();
  alert("LINEIN_CAPTURE impostato a: " + dev);
}

async function applySpotifyName(){
  const name = document.getElementById('sname').value.trim();
  const res = await fetch('/api/spotify_name', {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body: JSON.stringify({name})
  });

  if(!res.ok){
    const e = await res.json();
    alert("Errore: " + (e.error || "unknown"));
    return;
  }
  await refresh();
  alert("SPOTIFY_NAME impostato a: " + name);
}

refresh();
</script>
</body>
</html>
EOF

  chown -R "${RUN_USER}:${RUN_USER}" "${APP_DIR}" || true
  ok "File applicazione creati."
}

# ---- Python venv ----
setup_python() {
  log "Creo Python venv e installo Flask..."
  apt_install python3 python3-venv python3-pip
  sudo -u "${RUN_USER}" python3 -m venv "${APP_DIR}/.venv"
  sudo -u "${RUN_USER}" "${APP_DIR}/.venv/bin/pip" install --upgrade pip
  sudo -u "${RUN_USER}" "${APP_DIR}/.venv/bin/pip" install flask
  ok "Web UI runtime pronto."
}

# ---- systemd ----
create_systemd_units() {
  log "Creo unit systemd..."

  # Spotify receiver -> ALSA loopback playback
  cat > /etc/systemd/system/${SERVICE_PREFIX}-spotify.service <<EOF
[Unit]
Description=${PROJECT_TITLE} - Spotify Connect Receiver (librespot)
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CFG_FILE}
ExecStart=/usr/local/bin/librespot --name "%E{SPOTIFY_NAME}" --backend alsa --device "%E{ALOOP_PLAYBACK}" --bitrate 320
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  # In case librespot is in /usr/bin
  if [[ ! -x /usr/local/bin/librespot ]] && command_exists librespot; then
    local p
    p="$(command -v librespot)"
    sed -i "s|ExecStart=/usr/local/bin/librespot|ExecStart=${p}|g" /etc/systemd/system/${SERVICE_PREFIX}-spotify.service
  fi

  # Stream Spotify -> multicast (read from loopback capture)
  cat > /etc/systemd/system/${SERVICE_PREFIX}-stream-spotify.service <<EOF
[Unit]
Description=${PROJECT_TITLE} - Stream Spotify to RTP Multicast
After=${SERVICE_PREFIX}-spotify.service sound.target
BindsTo=${SERVICE_PREFIX}-spotify.service

[Service]
Type=simple
EnvironmentFile=${CFG_FILE}
ExecStart=/usr/bin/gst-launch-1.0 -q \\
  alsasrc device="%E{ALOOP_CAPTURE}" ! audioconvert ! audioresample ! \\
  volume volume=%E{STREAM_VOLUME} ! \\
  opusenc bitrate=%E{OPUS_BITRATE} ! rtpopuspay ! \\
  udpsink host=%E{MCAST_IP} port=%E{MCAST_PORT} auto-multicast=true ttl=%E{MCAST_TTL}
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

  # Stream Line-In -> multicast
  cat > /etc/systemd/system/${SERVICE_PREFIX}-stream-linein.service <<EOF
[Unit]
Description=${PROJECT_TITLE} - Stream Line-In to RTP Multicast
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CFG_FILE}
ExecStart=${APP_DIR}/scripts/stream_linein.sh
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

  # Web UI
  cat > /etc/systemd/system/${SERVICE_PREFIX}-web.service <<EOF
[Unit]
Description=${PROJECT_TITLE} - Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}/webui
ExecStart=${APP_DIR}/.venv/bin/python ${APP_DIR}/webui/app.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  # Autostart last source on boot
  cat > /etc/systemd/system/${SERVICE_PREFIX}-autostart.service <<EOF
[Unit]
Description=${PROJECT_TITLE} - Restore last selected source
After=network-online.target sound.target ${SERVICE_PREFIX}-web.service ${SERVICE_PREFIX}-spotify.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${APP_DIR}/scripts/autostart.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  ok "Unit systemd create."
}

# ---- sudoers ----
create_sudoers() {
  log "Configuro sudoers allow-list per Web UI..."
  cat > /etc/sudoers.d/${APP_SLUG} <<EOF
# ${PROJECT_TITLE} - minimal allow-list for web UI
ALL ALL=(root) NOPASSWD: /bin/systemctl start ${SERVICE_PREFIX}-stream-spotify.service
ALL ALL=(root) NOPASSWD: /bin/systemctl stop ${SERVICE_PREFIX}-stream-spotify.service
ALL ALL=(root) NOPASSWD: /bin/systemctl restart ${SERVICE_PREFIX}-stream-spotify.service
ALL ALL=(root) NOPASSWD: /bin/systemctl is-active ${SERVICE_PREFIX}-stream-spotify.service

ALL ALL=(root) NOPASSWD: /bin/systemctl start ${SERVICE_PREFIX}-stream-linein.service
ALL ALL=(root) NOPASSWD: /bin/systemctl stop ${SERVICE_PREFIX}-stream-linein.service
ALL ALL=(root) NOPASSWD: /bin/systemctl restart ${SERVICE_PREFIX}-stream-linein.service
ALL ALL=(root) NOPASSWD: /bin/systemctl is-active ${SERVICE_PREFIX}-stream-linein.service

ALL ALL=(root) NOPASSWD: /bin/systemctl restart ${SERVICE_PREFIX}-spotify.service
ALL ALL=(root) NOPASSWD: /bin/systemctl is-active ${SERVICE_PREFIX}-spotify.service
EOF
  chmod 0440 /etc/sudoers.d/${APP_SLUG}
  ok "sudoers ok."
}

# ---- deps ----
install_deps() {
  log "Installo dipendenze (GStreamer, ALSA, ecc.)..."
  apt_install \
    ca-certificates curl git \
    alsa-utils \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly
  ok "Dipendenze installate."
}

# ---- start services ----
enable_and_start() {
  log "Abilito servizi e avvio Web UI + Spotify receiver + autostart..."
  systemctl enable --now ${SERVICE_PREFIX}-web.service ${SERVICE_PREFIX}-spotify.service ${SERVICE_PREFIX}-autostart.service
  ok "Servizi avviati: ${SERVICE_PREFIX}-web + ${SERVICE_PREFIX}-spotify + ${SERVICE_PREFIX}-autostart"

  warn "Lo stream (Spotify/Line-In) si avvia dalla Web UI (e viene ricordato al reboot)."
}

# ---- uninstall ----
uninstall() {
  warn "Disinstallazione ${PROJECT_TITLE}..."

  systemctl stop \
    ${SERVICE_PREFIX}-web.service \
    ${SERVICE_PREFIX}-stream-spotify.service \
    ${SERVICE_PREFIX}-stream-linein.service \
    ${SERVICE_PREFIX}-spotify.service \
    ${SERVICE_PREFIX}-autostart.service 2>/dev/null || true

  systemctl disable \
    ${SERVICE_PREFIX}-web.service \
    ${SERVICE_PREFIX}-stream-spotify.service \
    ${SERVICE_PREFIX}-stream-linein.service \
    ${SERVICE_PREFIX}-spotify.service \
    ${SERVICE_PREFIX}-autostart.service 2>/dev/null || true

  rm -f /etc/systemd/system/${SERVICE_PREFIX}-web.service \
        /etc/systemd/system/${SERVICE_PREFIX}-stream-spotify.service \
        /etc/systemd/system/${SERVICE_PREFIX}-stream-linein.service \
        /etc/systemd/system/${SERVICE_PREFIX}-spotify.service \
        /etc/systemd/system/${SERVICE_PREFIX}-autostart.service

  systemctl daemon-reload || true

  rm -f /etc/sudoers.d/${APP_SLUG}
  rm -rf "${APP_DIR}"
  rm -rf "${CFG_DIR}"

  ok "Rimosso tutto (pacchetti apt non rimossi)."
  exit 0
}

# ---- main ----
need_root
detect_os

if [[ "${1:-}" == "uninstall" ]]; then
  uninstall
fi

log "${C_BOLD}${PROJECT_TITLE}${C_RST} installer — OS: ${OS_NAME} (${OS_ID} ${OS_VER})"
log "Runtime user: ${RUN_USER}"
log "Multicast fisso: ${MCAST_IP}:${MCAST_PORT} (TTL ${MCAST_TTL})"

SYSTEM_NAME="$(prompt_system_name)"
log "Nome scelto (Spotify Connect): ${C_BOLD}${SYSTEM_NAME}${C_RST}"

install_deps
enable_aloop
install_librespot
create_app_files "${SYSTEM_NAME}"
setup_python
create_systemd_units
create_sudoers
enable_and_start

IP_ADDR="$(hostname -I | awk '{print $1}')"
ok "Installazione completata."
echo
echo "${C_BOLD}Web UI:${C_RST}  http://${IP_ADDR}:${WEB_PORT}"
echo "${C_BOLD}Diagnostics:${C_RST} http://${IP_ADDR}:${WEB_PORT}/diagnostics"
echo "${C_BOLD}Config:${C_RST}   ${CFG_FILE}"
echo "${C_BOLD}Spotify Name:${C_RST} ${SYSTEM_NAME}"
echo "${C_BOLD}Test VLC:${C_RST} rtp://@${MCAST_IP}:${MCAST_PORT}"
echo
echo "Per disinstallare: sudo bash $0 uninstall"
