from array import array
import math
import subprocess
import sys
import threading
import time

from flask import Flask, jsonify, render_template, request

CFG = "/etc/multicast-rtp-audio-bridge/config.env"
SERVICE_PREFIX = "mrab"
SYSTEMCTL = "/usr/bin/systemctl"


def run(cmd):
    return subprocess.run(cmd, text=True, capture_output=True)


def sudo_systemctl(*args):
    return run(["sudo", SYSTEMCTL, *args])


def svc_active(name: str) -> bool:
    result = sudo_systemctl("is-active", name)
    return result.returncode == 0 and result.stdout.strip() == "active"


def read_cfg() -> dict[str, str]:
    data: dict[str, str] = {}
    with open(CFG, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip().strip('"')
    return data


def write_cfg(updates: dict[str, str]) -> None:
    with open(CFG, "r", encoding="utf-8") as handle:
        lines = handle.readlines()

    pending = dict(updates)
    output: list[str] = []
    for raw in lines:
        stripped = raw.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key in pending:
                value = str(pending.pop(key)).replace('"', "'").replace("\n", "").replace("\r", "")
                output.append(f'{key}="{value}"\n')
                continue
        output.append(raw)

    for key, value in pending.items():
        clean = str(value).replace('"', "'").replace("\n", "").replace("\r", "")
        output.append(f'{key}="{clean}"\n')

    with open(CFG, "w", encoding="utf-8") as handle:
        handle.writelines(output)


def pick_linein_device(cfg: dict[str, str]) -> str:
    configured = (cfg.get("LINEIN_CAPTURE") or "auto").strip()
    if configured != "auto":
        return configured
    result = run(["arecord", "-l"])
    if result.returncode == 0:
        for line in result.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) > 1 and parts[0] == "card":
                return f"hw:{parts[1].rstrip(':')},0"
    return "default"


def pcm_rms_s16le(data: bytes) -> float:
    if len(data) < 2:
        return 0.0
    usable = data[: len(data) - (len(data) % 2)]
    samples = array("h")
    samples.frombytes(usable)
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples:
        return 0.0
    return math.sqrt(sum(sample * sample for sample in samples) / len(samples))


class Meter:
    def __init__(self):
        self._lock = threading.Lock()
        self._proc: subprocess.Popen | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)
        self.source = "off"
        self.device = ""
        self.level = 0
        self.error = ""
        self._thread.start()

    def set_source(self, source: str, device: str) -> None:
        with self._lock:
            if self.source == source and self.device == device:
                return
            self.source = source
            self.device = device
        self._restart_capture()

    def _restart_capture(self) -> None:
        proc = self._proc
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
        self._proc = None

        with self._lock:
            source, device = self.source, self.device
            self.level = 0
            self.error = ""

        if source == "off" or not device:
            return

        try:
            self._proc = subprocess.Popen(
                ["arecord", "-D", device, "-f", "S16_LE", "-r", "48000", "-c", "2", "-t", "raw"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=0,
            )
        except OSError as exc:
            with self._lock:
                self.error = f"arecord start failed: {exc}"

    def _run(self) -> None:
        while True:
            proc = self._proc
            if not proc or proc.stdout is None:
                time.sleep(0.2)
                continue
            try:
                data = proc.stdout.read(4096)
                if not data:
                    if proc.poll() is not None:
                        error = "arecord stopped"
                        if proc.stderr is not None:
                            error = proc.stderr.read().decode("utf-8", errors="ignore").strip() or error
                        with self._lock:
                            self.error = error
                            self.level = 0
                    time.sleep(0.2)
                    continue
                rms = pcm_rms_s16le(data)
                level = int(min(100, (rms / 16000.0) * 100))
                with self._lock:
                    self.level = max(level, int(self.level * 0.8))
            except (OSError, ValueError) as exc:
                with self._lock:
                    self.error = f"meter read error: {exc}"
                    self.level = 0
                time.sleep(0.2)

    def snapshot(self) -> dict[str, object]:
        with self._lock:
            return {"level": self.level, "source": self.source, "device": self.device, "error": self.error}


meter = Meter()
app = Flask(__name__)


def selected_source() -> str:
    if svc_active(f"{SERVICE_PREFIX}-stream-spotify.service"):
        return "spotify"
    if svc_active(f"{SERVICE_PREFIX}-stream-linein.service"):
        return "linein"
    return "off"


def sync_meter() -> None:
    cfg = read_cfg()
    source = selected_source()
    if source == "spotify":
        meter.set_source(source, cfg.get("ALOOP_CAPTURE", "hw:Loopback,1,0"))
    elif source == "linein":
        meter.set_source(source, pick_linein_device(cfg))
    else:
        meter.set_source("off", "")


@app.get("/")
def index():
    return render_template("index.html", cfg=read_cfg())


@app.get("/diagnostics")
def diagnostics():
    cfg = read_cfg()
    return render_template(
        "diagnostics.html",
        cfg=cfg,
        arecord=run(["arecord", "-l"]).stdout,
        aplay=run(["aplay", "-l"]).stdout,
    )


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/api/status")
def status():
    cfg = read_cfg()
    return jsonify(
        spotify_on=svc_active(f"{SERVICE_PREFIX}-stream-spotify.service"),
        linein_on=svc_active(f"{SERVICE_PREFIX}-stream-linein.service"),
        spotify_rx=svc_active(f"{SERVICE_PREFIX}-spotify.service"),
        volume=float(cfg.get("STREAM_VOLUME", "1.0")),
        multicast=f"{cfg.get('MCAST_IP')}:{cfg.get('MCAST_PORT')}",
        spotify_name=cfg.get("SPOTIFY_NAME", "MulticastRTPAudioBridge"),
        linein_capture=cfg.get("LINEIN_CAPTURE", "auto"),
        last_source=cfg.get("LAST_SOURCE", "off"),
    )


@app.get("/api/meter")
def meter_api():
    sync_meter()
    return jsonify(meter.snapshot())


@app.post("/api/source")
def set_source():
    payload = request.get_json(silent=True) or {}
    source = payload.get("source")
    if source not in {"spotify", "linein", "off"}:
        return jsonify(ok=False, error="invalid source"), 400

    sudo_systemctl("stop", f"{SERVICE_PREFIX}-stream-spotify.service")
    sudo_systemctl("stop", f"{SERVICE_PREFIX}-stream-linein.service")
    if source != "off":
        result = sudo_systemctl("start", f"{SERVICE_PREFIX}-stream-{source}.service")
        if result.returncode != 0:
            return jsonify(ok=False, error=result.stderr.strip() or "service start failed"), 500
    write_cfg({"LAST_SOURCE": source})
    sync_meter()
    return jsonify(ok=True)


@app.post("/api/volume")
def set_volume():
    payload = request.get_json(silent=True) or {}
    try:
        volume = float(payload.get("volume"))
    except (TypeError, ValueError):
        return jsonify(ok=False, error="invalid volume"), 400
    if not 0.0 <= volume <= 1.5:
        return jsonify(ok=False, error="volume out of range"), 400
    write_cfg({"STREAM_VOLUME": str(volume)})
    for name in ("spotify", "linein"):
        service = f"{SERVICE_PREFIX}-stream-{name}.service"
        if svc_active(service):
            sudo_systemctl("restart", service)
    return jsonify(ok=True)


@app.post("/api/linein")
def set_linein():
    payload = request.get_json(silent=True) or {}
    device = str(payload.get("device") or "").strip()
    if not device or not (device in {"auto", "default"} or device.startswith(("hw:", "plughw:"))):
        return jsonify(ok=False, error="device not allowed"), 400
    if len(device) > 80 or any(ch in device for ch in "\n\r\"'"):
        return jsonify(ok=False, error="invalid device"), 400
    write_cfg({"LINEIN_CAPTURE": device})
    if svc_active(f"{SERVICE_PREFIX}-stream-linein.service"):
        sudo_systemctl("restart", f"{SERVICE_PREFIX}-stream-linein.service")
    sync_meter()
    return jsonify(ok=True, device=device)


@app.post("/api/spotify-name")
def set_spotify_name():
    payload = request.get_json(silent=True) or {}
    name = str(payload.get("name") or "").strip()
    if not 1 <= len(name) <= 64 or any(ch in name for ch in "\n\r\""):
        return jsonify(ok=False, error="invalid name"), 400
    write_cfg({"SPOTIFY_NAME": name})
    result = sudo_systemctl("restart", f"{SERVICE_PREFIX}-spotify.service")
    if result.returncode != 0:
        return jsonify(ok=False, error=result.stderr.strip() or "restart failed"), 500
    return jsonify(ok=True, name=name)
