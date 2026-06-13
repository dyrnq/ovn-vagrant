#!/usr/bin/env bash
# ============================================================
# Docker + Pure OVS Geneve overlay
#
# Prerequisites: geneve-agent running on both hosts.
# Uses OVS br-int + veth pairs + unique MACs.
# No OVN, no ovn-nbctl, no external_ids.
#
#   br-int (OVS)
#     ├── gw-int-ovn12   ← geneve-agent gateway veth
#     ├── geneve-ovn13   ← geneve-agent tunnel
#     └── port-ovn12-c1  ← container veth (this script)
#
# Usage:
#   ovn12: sudo bash docker-geneve-poc.sh deploy 172.16.12.200
#   ovn13: sudo bash docker-geneve-poc.sh deploy 172.16.13.200
#   ovn1X: sudo bash docker-geneve-poc.sh clean
# ============================================================
set -euo pipefail

HOSTNAME=$(hostname -s)
GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[${HOSTNAME}]${NC} $*"; }

CN="geneve-c1"                 # container name
PN="port-${CN}"                # OVS port name (host-side veth)

# ── Deploy ──────────────────────────────────────────────────
deploy() {
    local container_ip=$1       # e.g. 172.16.12.200
    local gw_ip
    gw_ip=$(ip -4 -o addr show dev "gw-${HOSTNAME}" 2>/dev/null \
            | grep -oP 'inet \K[^ ]+' | cut -d/ -f1)
    [ -n "$gw_ip" ] || { info "ERROR: gateway gw-${HOSTNAME} not found — run geneve-agent first"; exit 1; }

    info "=== Deploying $CN ($container_ip/16 via $gw_ip) ==="

    # 1. Docker container (network=none)
    docker rm -f "$CN" 2>/dev/null || true
    docker run -d --name "$CN" --network=none alpine:3.21 sleep infinity

    # 2. veth pair
    ip link del "$PN" 2>/dev/null || true
    ip link add "$PN" type veth peer name eth0

    # 3. Unique MAC (prevents OVS FDB collision across hosts)
    local mac
    mac="52:54:$(openssl rand -hex 1):$(openssl rand -hex 1):$(openssl rand -hex 1):$(openssl rand -hex 1)"
    ip link set "$PN" address "$mac"
    ip link set eth0 address "$mac"

    # 4. Host-side → OVS br-int
    ovs-vsctl --if-exists del-port br-int "$PN" 2>/dev/null || true
    ovs-vsctl add-port br-int "$PN"
    ip link set "$PN" up

    # 5. eth0 → container
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$cn")
    ip link set eth0 netns "$pid"
    nsenter -t "$pid" -n ip addr add "${container_ip}/16" dev eth0
    nsenter -t "$pid" -n ip link set eth0 up
    nsenter -t "$pid" -n ip link set lo up

    info "  MAC=$mac"
    info "  Container routes:"
    nsenter -t "$pid" -n ip route show
    info "$CN ready"
}

# ── Clean ───────────────────────────────────────────────────
clean() {
    info "Cleaning..."
    docker rm -f "$CN" 2>/dev/null || true
    ovs-vsctl --if-exists del-port br-int "$PN" 2>/dev/null || true
    ip link del "$PN" 2>/dev/null || true
    info "Cleaned"
}

# ── Main ────────────────────────────────────────────────────
case "${1:-}" in
    deploy)
        [ $# -ge 2 ] || { echo "Usage: $0 deploy <container-IP>"; echo "  e.g. $0 deploy 172.16.12.200"; exit 1; }
        deploy "$2"
        ;;
    clean) clean ;;
    *)
        echo "Usage: $0 {deploy <IP>|clean}"
        echo ""
        echo "  ovn12: $0 deploy 172.16.12.200"
        echo "  ovn13: $0 deploy 172.16.13.200"
        echo "  ovn1X: $0 clean"
        exit 1 ;;
esac
