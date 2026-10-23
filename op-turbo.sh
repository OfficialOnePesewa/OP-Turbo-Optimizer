#!/usr/bin/env bash
# ==========================================================
#  OP TURBO OPTIMIZER
#  by OfficialOnePesewa · github.com/OfficialOnePesewa
#  Debian & Ubuntu · any VPS provider · KVM / Xen / bare metal
# ==========================================================
set -euo pipefail

OP_TURBO_VERSION="1.0.0"
INSTALL_DIR="/usr/local/op-turbo"
SYSCTL_FILE="/etc/sysctl.d/99-op-turbo.conf"
LIMITS_FILE="/etc/security/limits.d/99-op-turbo.conf"
SYSCTL_MAIN="/etc/sysctl.conf"
BACKUP_DIR="/var/backups/op-turbo"

TUNED_KEYS=(
  net.core.default_qdisc net.ipv4.tcp_congestion_control
  net.core.rmem_default net.core.rmem_max net.core.wmem_default net.core.wmem_max
  net.core.optmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem
  net.core.netdev_max_backlog net.core.somaxconn net.ipv4.tcp_max_syn_backlog
  net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_fastopen
  net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
  net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing
)

C_CY=$'\033[1;36m'; C_GR=$'\033[1;32m'; C_YE=$'\033[1;33m'; C_RD=$'\033[1;31m'; C_NC=$'\033[0m'
info() { echo -e "${C_CY}[+]${C_NC} $*"; }
ok()   { echo -e "${C_GR}[✓]${C_NC} $*"; }
warn() { echo -e "${C_YE}[!]${C_NC} $*"; }
die()  { echo -e "${C_RD}[x]${C_NC} $*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."; }

detect_os() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ok "Detected: ${PRETTY_NAME}" ;;
    *) die "Unsupported OS '${ID:-unknown}'. Debian and Ubuntu only." ;;
  esac
}

check_virt() {
  local virt
  virt=$(systemd-detect-virt 2>/dev/null) || virt="none"
  : "${virt:=none}"
  case "$virt" in
    openvz|lxc|lxc-libvirt)
      warn "Container virtualization ($virt). The host may block some sysctl values; the rest will still apply." ;;
    *) ok "Virtualization: $virt" ;;
  esac
}

tune_network() {
  info "Applying network stack tuning..."
  mkdir -p "$BACKUP_DIR"

  if [[ -f $SYSCTL_MAIN && ! -f $BACKUP_DIR/sysctl.conf.orig ]]; then
    cp -a "$SYSCTL_MAIN" "$BACKUP_DIR/sysctl.conf.orig"
    ok "Backed up $SYSCTL_MAIN to $BACKUP_DIR"
  fi

  # Older installers appended to sysctl.conf, which overrides sysctl.d at boot.
  # Comment those keys out so they cannot override this tuning.
  local key key_re
  for key in "${TUNED_KEYS[@]}"; do
    key_re=$(printf '%s' "$key" | sed 's/\./\\./g')
    sed -i -E "s|^[[:space:]]*${key_re}[[:space:]]*=|# disabled by op-turbo: &|" "$SYSCTL_MAIN" 2>/dev/null || true
  done

  modprobe tcp_bbr 2>/dev/null || true
  local cc="cubic"
  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    cc="bbr"
  fi
  ok "Congestion control: $cc"

  local mem_mb buf=16777216
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  if (( mem_mb < 1024 )); then
    buf=8388608
  fi
  ok "RAM: ${mem_mb} MB · socket buffer cap: $((buf / 1048576)) MB"

  cat > "$SYSCTL_FILE" <<EOF
# OP Turbo Optimizer v${OP_TURBO_VERSION} - generated $(date -u +%F)

# Congestion control and queueing
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=${cc}

# Socket buffers (sized for RAM)
net.core.rmem_default=262144
net.core.wmem_default=262144
net.core.rmem_max=${buf}
net.core.wmem_max=${buf}
net.core.optmem_max=65536
net.ipv4.tcp_rmem=4096 131072 ${buf}
net.ipv4.tcp_wmem=4096 65536 ${buf}

# Connection handling
net.core.netdev_max_backlog=16384
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=262144
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1

# Keep-alive and idle behaviour
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_slow_start_after_idle=0

# Forwarding (needed for VPN routing)
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# File descriptors
fs.file-max=1048576
EOF

  cat > "$LIMITS_FILE" <<EOF
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  if sysctl -p "$SYSCTL_FILE" >/dev/null 2>/tmp/op-turbo-sysctl.err; then
    ok "Kernel parameters applied"
  else
    warn "Some keys were rejected by this kernel (see /tmp/op-turbo-sysctl.err). Supported keys were applied."
  fi
}

run_badvpn() {
  local b="$INSTALL_DIR/badvpn-udpgw.sh"
  [[ -f $b ]] || die "Missing $b. Reinstall with install.sh."
  bash "$b" install
}

status() {
  echo -e "\n${C_CY}OP Turbo v${OP_TURBO_VERSION} status${C_NC}"
  echo "Kernel:       $(uname -r)"
  echo "Congestion:   $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
  echo "Qdisc:        $(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)"
  echo "rmem_max:     $(sysctl -n net.core.rmem_max 2>/dev/null || echo n/a)"
  echo "wmem_max:     $(sysctl -n net.core.wmem_max 2>/dev/null || echo n/a)"
  echo "BadVPN UDPGW: $(systemctl is-active badvpn-udpgw 2>/dev/null || echo not-installed)"
}

revert() {
  require_root
  rm -f "$SYSCTL_FILE" "$LIMITS_FILE"
  if [[ -f $BACKUP_DIR/sysctl.conf.orig ]]; then
    cp -a "$BACKUP_DIR/sysctl.conf.orig" "$SYSCTL_MAIN"
  fi
  ok "OP Turbo tuning removed. Reboot to return kernel values to stock."
}

usage() {
  cat <<EOF
OP Turbo Optimizer v${OP_TURBO_VERSION}

Usage: opturbo <command>

  install   Tune the network stack and install BadVPN UDPGW (default)
  tune      Apply network tuning only
  badvpn    Install or repair BadVPN UDPGW only
  status    Show current tuning and service state
  revert    Remove OP Turbo tuning
EOF
}

main() {
  case "${1:-install}" in
    install)
      require_root; detect_os; check_virt; tune_network; run_badvpn; status ;;
    tune)
      require_root; detect_os; check_virt; tune_network; status ;;
    badvpn)
      require_root; run_badvpn ;;
    status)
      status ;;
    revert)
      revert ;;
    -h|--help|help)
      usage ;;
    *)
      usage; exit 1 ;;
  esac
}

main "$@"
