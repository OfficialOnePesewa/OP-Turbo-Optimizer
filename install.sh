#!/usr/bin/env bash
# ==========================================================
#  OP TURBO OPTIMIZER - Bootstrap installer
#  by OfficialOnePesewa
#  Usage:
#  curl -fsSL https://raw.githubusercontent.com/OfficialOnePesewa/OP-Turbo-Optimizer/main/install.sh | sudo bash
# ==========================================================
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/OfficialOnePesewa/OP-Turbo-Optimizer/main"
INSTALL_DIR="/usr/local/op-turbo"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: curl ... | sudo bash"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y curl
fi

mkdir -p "$INSTALL_DIR"

for f in op-turbo.sh badvpn-udpgw.sh; do
  echo "[+] Downloading $f"
  curl -fsSL "$REPO_RAW/$f" -o "$INSTALL_DIR/$f"
  chmod 755 "$INSTALL_DIR/$f"
done

ln -sf "$INSTALL_DIR/op-turbo.sh" /usr/local/bin/opturbo

exec "$INSTALL_DIR/op-turbo.sh" install
