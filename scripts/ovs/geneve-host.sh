#!/usr/bin/env bash
# ============================================================
# Pure OVS Geneve host setup — installs everything needed.
#
# Run on each host node (ovn12, ovn13, ...) after central etcd is up.
# Mirrors flannel: install agent → register → create gateway → watch.
#
# What it does:
#   1. Install openvswitch-switch
#   2. Install geneve-agent.py + systemd service
#   3. Start geneve-agent (auto-creates gateway + tunnels)
#   4. Verify connectivity
#
# Usage:
#   ovn11: sudo bash geneve-host.sh central     (install etcd)
#   ovn12: sudo bash geneve-host.sh host        (install OVS + agent)
#   ovn1X: sudo bash geneve-host.sh clean       (tear down)
# ============================================================
set -euo pipefail

CENTRAL_IP="192.168.200.11"
HOSTNAME=$(hostname -s)
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[${HOSTNAME}]${NC} $*"; }
err()   { echo -e "${RED}[${HOSTNAME}]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Central: install etcd ──────────────────────────────────
deploy_central() {
    info "=== Installing etcd ==="

    if ! command -v etcd &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq etcd-server etcd-client
    fi

    # Configure etcd to listen on management network
    local listen_ip
    listen_ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep '192.168.200' | head -1)
    if [ -z "$listen_ip" ]; then
        listen_ip="0.0.0.0"
    fi

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

    if etcdctl endpoint health 2>&1 | grep -q "healthy"; then
        info "etcd healthy at http://${listen_ip}:2379"
    else
        err "etcd health check failed"
        exit 1
    fi
}

# ── Host: install OVS + geneve-agent ──────────────────────
deploy_host() {
    info "=== Installing Open vSwitch ==="
    if ! command -v ovs-vsctl &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq openvswitch-switch
    fi
    systemctl enable openvswitch-switch
    systemctl start openvswitch-switch 2>/dev/null || true
    info "OVS: $(ovs-vswitchd --version 2>&1 | head -1)"

    info "=== Installing geneve-agent ==="
    local bin="/usr/local/bin/geneve-agent"
    cp "$SCRIPT_DIR/geneve-agent.py" "$bin"
    chmod 755 "$bin"

    # Ensure OVS bridge
    if ! ovs-vsctl br-exists br-int 2>/dev/null; then
        ovs-vsctl add-br br-int
        info "Created br-int"
    fi

    # Generate systemd unit
    cat > /etc/systemd/system/geneve-agent.service << UNIT
[Unit]
Description=Pure OVS Geneve overlay agent (like flanneld)
After=network-online.target openvswitch-switch.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/uv run $bin
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

    info "=== Starting geneve-agent ==="
    systemctl restart geneve-agent
    sleep 5

    local status
    status=$(systemctl is-active geneve-agent 2>&1)
    if [ "$status" = "active" ]; then
        info "geneve-agent: $status"
    else
        err "geneve-agent: $status — check: journalctl -u geneve-agent"
    fi

    info ""
    info "=== Network state ==="
    info "  OVS ports: $(ovs-vsctl list-ports br-int 2>/dev/null | tr '\n' ' ')"
    info "  Routes:    $(ip route | grep 172.16 | tr '\n' ' ')"
    info ""
    info "=== Next steps:"
    info "  journalctl -u geneve-agent -f     # watch agent logs"
    info "  etcdctl get /geneve/ --prefix     # check etcd state"
    info "  ovs-vsctl show                    # check OVS bridge"
}

# ── Clean ──────────────────────────────────────────────────
clean() {
    info "=== Cleaning up ==="

    # Stop agent
    systemctl stop geneve-agent 2>/dev/null || true
    systemctl disable geneve-agent 2>/dev/null || true
    rm -f /etc/systemd/system/geneve-agent.service
    rm -f /usr/local/bin/geneve-agent

    # Remove OVS bridge
    ovs-vsctl del-br br-int 2>/dev/null || true

    # Remove gateway veth
    ip link del "gw-${HOSTNAME}" 2>/dev/null || true
    ip link del "gw-int-${HOSTNAME}" 2>/dev/null || true

    # Remove overlay routes
    ip route del 172.16.0.0/16 2>/dev/null || true

    # Remove etcd (central only)
    if [ "$HOSTNAME" = "ovn11" ]; then
        systemctl stop etcd 2>/dev/null || true
        systemctl disable etcd 2>/dev/null || true
        rm -rf /var/lib/etcd/*
        info "etcd stopped and data cleared"
    fi

    systemctl daemon-reload
    info "Cleaned"
}

# ── Main ───────────────────────────────────────────────────
case "${1:-}" in
    central) deploy_central ;;
    host)    deploy_host ;;
    clean)   clean ;;
    *)
        echo "Usage: $0 {central|host|clean}"
        echo ""
        echo "  ovn11: $0 central    # Install etcd"
        echo "  ovn12: $0 host       # Install OVS + geneve-agent"
        echo "  ovn13: $0 host       # Install OVS + geneve-agent"
        echo "  ovn1X: $0 clean      # Teardown"
        exit 1 ;;
esac
info "Done"
