# OP Turbo Optimizer

Network tuning and BadVPN UDPGW setup for Debian and Ubuntu VPS servers.
By OfficialOnePesewa.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/OfficialOnePesewa/OP-Turbo-Optimizer/main/install.sh | sudo bash
```

## Commands

```bash
sudo opturbo install   # tune network + install BadVPN (default)
sudo opturbo tune      # network tuning only
sudo opturbo badvpn    # install or repair BadVPN only
sudo opturbo status    # show current state
sudo opturbo revert    # remove tuning
```

## Requirements

- Debian 10+ or Ubuntu 18.04+
- Root access
- KVM, Xen, or bare metal work best. OpenVZ and LXC hosts may block some kernel settings.

## Files

- `install.sh`: bootstrap installer
- `op-turbo.sh`: main optimizer
- `badvpn-udpgw.sh`: BadVPN UDPGW builder and service manager
