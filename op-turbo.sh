#!/usr/bin/env bash
# ==========================================================
#  OP TURBO OPTIMIZER v2.0 - UDP-first tuning
#  by OfficialOnePesewa · github.com/OfficialOnePesewa
#  Targets: UDP throughput, buffering/lag, packet drops,
#  NAT session drops and reconnects.
#  Debian & Ubuntu · any VPS provider
# ==========================================================
set -euo pipefail

OP_TURBO_VERSION="2.0.0"
INSTALL_DIR="/usr/local/op-turbo"
SYSCTL_FILE="/etc/sysctl.d/99-op-turbo.conf"
LIMITS_FILE="/etc/security/limits.d/99-op-turbo.conf"
MODULES_FILE="/etc/modules-load.d/op-turbo.conf"
NIC_UNIT="/etc/systemd/system/op-turbo-nic.service"
SYSCTL_MAIN="/etc/sysctl.conf"
BACKUP_DIR="/var/backups/op-turbo"

# Keys we own. Any copies in /etc/sysctl.conf are disabled so they can't override us.
TUNED_KEYS=(
  net.core.default_qdisc net.ipv4.tcp_congestion_control
  net.core.rmem_default net.core.rmem_max net.core.wmem_default net.core.wmem_max
  net.core.optmem_max net.core.netdev_max_backlog net.core.netdev_budget net.core.netdev_budget_usecs
  net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min
  net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.somaxconn net.ipv4.tcp_max_syn_backlog
  net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing
  net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
  net.ipv4.tcp_slow_start_after_idle
  net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter
  net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_udp_timeout
  net.netfilter.nf_conntrack_udp_timeout_stream
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
      warn "Container virtualization ($virt). The host may block some kernel settings; the rest will still apply." ;;
    *) ok "Virtualization: $virt" ;;
  esac
}

install_pkgs() {
  info "Installing helper packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y ethtool iproute2 procps >/dev/null
  ok "Helper packages ready"
}

mem_mb() { awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }

tune_network() {
  info "Applying UDP-first kernel tuning..."
  mkdir -p "$BACKUP_DIR"

  if [[ -f $SYSCTL_MAIN && ! -f $BACKUP_DIR/sysctl.conf.orig ]]; then
    cp -a "$SYSCTL_MAIN" "$BACKUP_DIR/sysctl.conf.orig"
    ok "Backed up $SYSCTL_MAIN"
  fi

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
  modprobe sch_fq_codel 2>/dev/null || true
  local qdisc="fq_codel"

  local ram buf conn_max
  ram=$(mem_mb)
  if (( ram < 1024 )); then buf=8388608; else buf=16777216; fi

  conn_max=$(( ram * 256 ))
  if (( conn_max > 1048576 )); then conn_max=1048576; fi
  if (( conn_max < 65536 )); then conn_max=65536; fi

  local ct_block=""
  if modprobe nf_conntrack 2>/dev/null && [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    echo nf_conntrack > "$MODULES_FILE"
    ct_block="net.netfilter.nf_conntrack_max=${conn_max}
net.netfilter.nf_conntrack_udp_timeout=60
net.netfilter.nf_conntrack_udp_timeout_stream=180"
    ok "NAT table: ${conn_max} entries, UDP session timeout 180s"
  else
    warn "nf_conntrack unavailable; skipping NAT session tuning."
  fi

  ok "RAM: ${ram} MB · socket buffer cap: $((buf / 1048576)) MB · congestion: ${cc}"

  cat > "$SYSCTL_FILE" <<EOF
# OP Turbo Optimizer v${OP_TURBO_VERSION} (UDP-first) - generated $(date -u +%F)

# Queueing: fq_codel keeps latency low under load
net.core.default_qdisc=${qdisc}
net.ipv4.tcp_congestion_control=${cc}

# UDP socket buffers: fewer drops during bursts
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.rmem_max=${buf}
net.core.wmem_max=${buf}
net.core.optmem_max=65536
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384

# Packet processing: larger RX queue and per-poll budget
net.core.netdev_max_backlog=32768
net.core.netdev_budget=600
net.core.netdev_budget_usecs=8000

# TCP (SSH, panel, control channels)
net.ipv4.tcp_rmem=4096 131072 ${buf}
net.ipv4.tcp_wmem=4096 65536 ${buf}
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=262144
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_slow_start_after_idle=0

# Loose reverse-path filter so VPN return traffic isn't dropped
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2

# Forwarding (required for VPN routing)
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# File descriptors
fs.file-max=1048576
${ct_block}
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

default_iface() {
  ip -o -4 route show default 2>/dev/null \
    | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

nic_tune() {
  local iface
  iface=$(default_iface)
  if [[ -z $iface ]]; then
    warn "No default interface found; skipping NIC tuning."
    return 0
  fi
  info "NIC tuning on ${iface}..."

  # Larger hardware rings absorb UDP bursts
  local rx_max tx_max
  rx_max=$(ethtool -g "$iface" 2>/dev/null | awk '/Pre-set/{p=1} /Current/{p=0} p && /^RX:/{print $2; exit}')
  tx_max=$(ethtool -g "$iface" 2>/dev/null | awk '/Pre-set/{p=1} /Current/{p=0} p && /^TX:/{print $2; exit}')
  if [[ -n $rx_max && -n $tx_max ]]; then
    if ethtool -G "$iface" rx "$rx_max" tx "$tx_max" >/dev/null 2>&1; then
      ok "Ring buffers: RX ${rx_max} / TX ${tx_max}"
    fi
  fi

  # Longer transmit queue for bursts
  ip link set dev "$iface" txqueuelen 10000 2>/dev/null || true

  # Low-latency fair queueing on egress
  if command -v tc >/dev/null 2>&1; then
    if tc qdisc replace dev "$iface" root fq_codel 2>/dev/null; then
      ok "Egress qdisc: fq_codel"
    fi
  fi

  # UDP GRO forwarding: faster forwarding of UDP tunnels (skipped if unsupported)
  if ethtool -K "$iface" rx-udp-gro-forwarding on >/dev/null 2>&1; then
    ok "UDP GRO forwarding enabled"
  fi

  # Spread receive work across all CPUs
  local ncpu mask q
  ncpu=$(nproc)
  if (( ncpu > 1 )); then
    mask=$(printf '%x' $(( (1 << ncpu) - 1 )))
    for q in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
      [[ -e $q ]] && echo "$mask" > "$q" 2>/dev/null || true
    done
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
    for q in /sys/class/net/"$iface"/queues/rx-*/rps_flow_cnt; do
      [[ -e $q ]] && echo 4096 > "$q" 2>/dev/null || true
    done
    ok "Receive work spread across ${ncpu} CPUs"
  fi
}

install_nic_service() {
  cat > "$NIC_UNIT" <<EOF
[Unit]
Description=OP Turbo NIC and UDP tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_DIR}/op-turbo.sh nic-apply

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable op-turbo-nic >/dev/null 2>&1
  ok "NIC tuning service enabled (re-applies on every boot)"
}

run_badvpn() {
  local b="$INSTALL_DIR/badvpn-udpgw.sh"
  [[ -f $b ]] || die "Missing $b. Reinstall with install.sh."
  bash "$b" install
}

udp_drops() {
  awk '
    /^Udp:/ {
      if (!h) { for (i=1;i<=NF;i++) k[i]=$i; h=1 }
      else    { for (i=1;i<=NF;i++) { if (k[i]=="RcvbufErrors") r=$i; if (k[i]=="InErrors") e=$i } }
    }
    END { print r+0, e+0 }' /proc/net/snmp
}

status() {
  local rcv err iface ct
  read -r rcv err < <(udp_drops)
  iface=$(default_iface)
  ct=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo n/a)
  echo -e "\n${C_CY}OP Turbo v${OP_TURBO_VERSION} status${C_NC}"
  echo "Kernel:          $(uname -r)"
  echo "Interface:       ${iface:-n/a}"
  echo "Queue (qdisc):   $(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)"
  echo "TCP congestion:  $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
  echo "UDP buffer max:  $(sysctl -n net.core.rmem_max 2>/dev/null || echo n/a) bytes"
  echo "UDP drops:       ${rcv} buffer overflows, ${err} input errors (since boot)"
  echo "NAT sessions:    ${ct}"
  echo "BadVPN UDPGW:    $(systemctl is-active badvpn-udpgw 2>/dev/null || echo not-installed)"
}

revert() {
  require_root
  systemctl disable --now op-turbo-nic >/dev/null 2>&1 || true
  rm -f "$NIC_UNIT" "$SYSCTL_FILE" "$LIMITS_FILE" "$MODULES_FILE"
  systemctl daemon-reload
  if [[ -f $BACKUP_DIR/sysctl.conf.orig ]]; then
    cp -a "$BACKUP_DIR/sysctl.conf.orig" "$SYSCTL_MAIN"
  fi
  ok "OP Turbo tuning removed. Reboot to return kernel values to stock."
}

usage() {
  cat <<EOF
OP Turbo Optimizer v${OP_TURBO_VERSION}

Usage: opturbo <command>

  install   Full setup: kernel + NIC tuning, boot service, BadVPN (default)
  tune      Kernel and NAT tuning only
  nic       Re-apply NIC/UDP tuning now
  badvpn    Install or repair BadVPN UDPGW
  status    Show tuning, UDP drop counters and service state
  revert    Remove OP Turbo tuning
EOF
}

main() {
  case "${1:-install}" in
    install)
      require_root; detect_os; check_virt; install_pkgs
      tune_network; nic_tune; install_nic_service; run_badvpn; status ;;
    tune)
      require_root; detect_os; check_virt; tune_network; status ;;
    nic|nic-apply)
      require_root; nic_tune ;;
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
