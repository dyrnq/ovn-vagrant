#!/usr/bin/env bash
# ============================================================
# Pure Linux kernel Geneve host setup.
# No OVS, no OVN — just bridge + Geneve + etcd.
#
# Usage:
#   ovn11: geneve-host.sh central    (install etcd)
#   ovn12: geneve-host.sh host       (install agent + bridge)
#   ovn1X: geneve-host.sh clean
# ============================================================
set -euo pipefail

HOSTNAME=$(hostname -s)
GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[${HOSTNAME}]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="/usr/local/bin/geneve-agent"
BRIDGE="br-overlay"

# ── Central ─────────────────────────────────────────────────
deploy_central() {
    info "=== Installing etcd ==="
    if ! command -v etcd &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq etcd-server etcd-client
    fi

    local listen_ip
    listen_ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep '192.168.200' | head -1)
    [ -z "$listen_ip" ] && listen_ip="0.0.0.0"

    mkdir -p /etc/systemd/system/etcd.service.d/
    cat > /etc/systemd/system/etcd.service.d/override.conf << UNIT
[Service]
ExecStart=
ExecStart=/usr/bin/etcd --listen-client-urls=http://127.0.0.1:2379,http://${listen_ip}:2379 --advertise-client-urls=http://${listen_ip}:2379
UNIT

    systemctl daemon-reload
    systemctl enable etcd
    systemctl restart etcd
    sleep 2

    etcdctl endpoint health 2>&1 && info "etcd healthy at http://${listen_ip}:2379"
}

# ── Host ────────────────────────────────────────────────────
deploy_host() {
    info "=== Loading geneve module ==="
    modprobe geneve 2>/dev/null || true

    info "=== Installing geneve-agent ==="
    cp "$SCRIPT_DIR/geneve-agent.py" "$BIN"
    chmod 755 "$BIN"

    cat > /etc/systemd/system/geneve-agent.service << UNIT
[Unit]
Description=Pure Linux Geneve overlay agent (like flanneld)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/uv run $BIN
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=geneve-agent

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable geneve-agent.service
    systemctl restart geneve-agent
    sleep 5

    info "geneve-agent: $(systemctl is-active geneve-agent)"
    info "bridge: $(ip addr show $BRIDGE 2>/dev/null | grep inet || echo 'not created')"
    info "geneve devices: $(ip link show type geneve 2>/dev/null | grep -c geneve || echo 0)"
    info ""
    info "=== journalctl -u geneve-agent -f"
}

# ── Clean ───────────────────────────────────────────────────
clean() {
    info "Cleaning..."
    systemctl stop geneve-agent 2>/dev/null || true
    systemctl disable geneve-agent 2>/dev/null || true
    rm -f /etc/systemd/system/geneve-agent.service
    rm -f "$BIN"

    # Remove geneve devices
    ip -d link show type geneve 2>/dev/null | grep -oP '^\d+: \K[^:]+' | while read dev; do
        ip link del "$dev" 2>/dev/null
    done

    # Remove bridge
    ip link del "$BRIDGE" 2>/dev/null || true

    # Remove etcd data (central only)
    if [ "$HOSTNAME" = "ovn11" ]; then
        systemctl stop etcd 2>/dev/null || true
        rm -rf /var/lib/etcd/*
        info "etcd cleared"
    fi

    systemctl daemon-reload
    info "Done"
}

# ── Main ────────────────────────────────────────────────────
case "${1:-}" in
    central) deploy_central ;;
    host)    deploy_host ;;
    clean)   clean ;;
    *)
        echo "Usage: $0 {central|host|clean}"
        echo ""
        echo "  ovn11: $0 central    # Install etcd"
        echo "  ovn12: $0 host       # Install agent + bridge"
        echo "  ovn1X: $0 clean      # Teardown"
        exit 1 ;;
esac
info "Done"
