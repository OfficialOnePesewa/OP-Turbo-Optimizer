#!/usr/bin/env bash
# ==========================================================
#  BADVPN-UDPGW INSTALLER - OP Turbo
#  by OfficialOnePesewa
#  Builds ambrop72/badvpn from source (works on Debian & Ubuntu),
#  runs it as a systemd service on 127.0.0.1:7300.
# ==========================================================
set -euo pipefail

SRC_URL="https://github.com/ambrop72/badvpn.git"
BUILD_DIR="/tmp/op-badvpn-build"
BIN="/usr/local/bin/badvpn-udpgw"
UNIT="/etc/systemd/system/badvpn-udpgw.service"
LISTEN="127.0.0.1:7300"

C_CY=$'\033[1;36m'; C_GR=$'\033[1;32m'; C_RD=$'\033[1;31m'; C_NC=$'\033[0m'
info() { echo -e "${C_CY}[+]${C_NC} $*"; }
ok()   { echo -e "${C_GR}[✓]${C_NC} $*"; }
die()  { echo -e "${C_RD}[x]${C_NC} $*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."; }

check_os() {
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ok "Detected: ${PRETTY_NAME}" ;;
    *) die "Unsupported OS '${ID:-unknown}'." ;;
  esac
}

install_deps() {
  info "Installing build dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y build-essential cmake git ca-certificates
}

build_badvpn() {
  info "Building badvpn-udpgw from source..."
  rm -rf "$BUILD_DIR"
  git clone --depth 1 "$SRC_URL" "$BUILD_DIR"
  mkdir -p "$BUILD_DIR/build"
  cd "$BUILD_DIR/build"
  cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local \
           -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null
  make -j"$(nproc)" >/dev/null

  local built
  built=$(find "$BUILD_DIR/build" -type f -name badvpn-udpgw | head -n1)
  [[ -n $built ]] || die "Build finished but badvpn-udpgw binary was not found."

  install -m 755 "$built" "$BIN"
  cd /
  rm -rf "$BUILD_DIR"
  ok "Installed $BIN"
}

write_unit() {
  cat > "$UNIT" <<EOF
[Unit]
Description=BadVPN UDPGW (OP Turbo)
After=network.target

[Service]
ExecStart=${BIN} --listen-addr ${LISTEN} --max-clients 1000 --max-connections-for-client 16 --client-socket-sndbuf 65536
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

start_service() {
  systemctl enable badvpn-udpgw >/dev/null 2>&1
  systemctl restart badvpn-udpgw
  sleep 2
  if systemctl is-active --quiet badvpn-udpgw && ss -ltn | grep -q ":7300"; then
    ok "BadVPN UDPGW running on ${LISTEN}"
  else
    journalctl -u badvpn-udpgw -n 30 --no-pager || true
    die "BadVPN UDPGW failed to start. Logs are shown above."
  fi
}

install_badvpn() {
  require_root; check_os; install_deps; build_badvpn; write_unit; start_service
}

remove_badvpn() {
  require_root
  systemctl disable --now badvpn-udpgw >/dev/null 2>&1 || true
  rm -f "$UNIT" "$BIN"
  systemctl daemon-reload
  ok "BadVPN UDPGW removed."
}

case "${1:-install}" in
  install) install_badvpn ;;
  remove)  remove_badvpn ;;
  status)  systemctl status badvpn-udpgw --no-pager || true ;;
  *) echo "Usage: $0 {install|remove|status}"; exit 1 ;;
esac
