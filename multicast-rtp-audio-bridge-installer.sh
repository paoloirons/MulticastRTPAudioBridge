#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -x "${SCRIPT_DIR}/install.sh" ]]; then
  echo "install.sh non trovato: clona/scarica il repository completo." >&2
  exit 1
fi
echo "[i] Installer legacy: inoltro a install.sh" >&2
exec "${SCRIPT_DIR}/install.sh" "$@"
