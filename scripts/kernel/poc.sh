#!/usr/bin/env bash
# ============================================================
# Pure Linux kernel Geneve POC — netns + Docker unified.
#
# Workloads connect to br-overlay (Linux bridge).
# Geneve tunnels are managed by geneve-agent.
#
# Usage:
#   ovn12: poc.sh netns 172.16.12.100/16
#   ovn12: poc.sh docker 172.16.12.200/16 c1
#   ovn12: poc.sh verify 172.16.13.100
#   ovn1X: poc.sh clean
# ============================================================
set -euo pipefail

HOSTNAME=$(hostname -s)
BRIDGE="br-overlay"
GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[${HOSTNAME}]${NC} $*"; }

# ── Workload veth helper ────────────────────────────────────
_setup_workload() {
    local dev=$1 ip_addr=$2 ns_type=$3 ns_id=$4

    # Unique MAC
    local mac
    mac="52:54:$(openssl rand -hex 1):$(openssl rand -hex 1):$(openssl rand -hex 1):$(openssl rand -hex 1)"

    # veth pair
    ip link del "$dev" 2>/dev/null || true
    ip link add "$dev" type veth peer name eth0
    ip link set "$dev" address "$mac"
    ip link set eth0 address "$mac"

    # Host-side → bridge
    ip link set "$dev" master "$BRIDGE"
    ip link set "$dev" up

    # Move eth0 into namespace
    if [ "$ns_type" = "netns" ]; then
        ip netns add "$ns_id" 2>/dev/null || true
        ip link set eth0 netns "$ns_id"
        ip netns exec "$ns_id" ip addr add "$ip_addr" dev eth0
        ip netns exec "$ns_id" ip link set eth0 up
        ip netns exec "$ns_id" ip link set lo up
    else
        ip link set eth0 netns "$ns_id"
        nsenter -t "$ns_id" -n ip addr add "$ip_addr" dev eth0
        nsenter -t "$ns_id" -n ip link set eth0 up
        nsenter -t "$ns_id" -n ip link set lo up
    fi
}

# ── Netns workload ──────────────────────────────────────────
do_netns() {
    local cidr=$1
    local dev="veth-${HOSTNAME}"

    info "=== Netns workload ($cidr) ==="
    _setup_workload "$dev" "$cidr" "netns" "ns-test"
    info "ns-test ready"
}

# ── Docker workload ─────────────────────────────────────────
do_docker() {
    local cidr=$1 cn=$2
    local dev="veth-${cn}"

    info "=== Docker workload $cn ($cidr) ==="
    docker rm -f "$cn" 2>/dev/null || true
    docker run -d --name "$cn" --network=none alpine:3.21 sleep infinity
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$cn")

    _setup_workload "$dev" "$cidr" "docker" "$pid"
    info "$cn ready"
}

# ── Verify ──────────────────────────────────────────────────
do_verify() {
    local peer=$1
    info "=== Testing → $peer ==="
    if ip netns list 2>/dev/null | grep -q ns-test; then
        ip netns exec ns-test ping -c 3 -W 1 "$peer" 2>&1
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q '.'; then
        local cn
        cn=$(docker ps --format '{{.Names}}' | head -1)
        docker exec "$cn" ping -c 3 -W 1 "$peer" 2>&1
    else
        info "No workload found"
        exit 1
    fi
}

# ── Clean ───────────────────────────────────────────────────
do_clean() {
    info "Cleaning..."
    ip netns del ns-test 2>/dev/null || true
    ip link del "veth-${HOSTNAME}" 2>/dev/null || true
    ip -d link show type veth 2>/dev/null | grep -oP '^\d+: \Kveth[^:]+' | while read v; do
        ip link del "$v" 2>/dev/null
    done
    info "Done"
}

# ── Main ────────────────────────────────────────────────────
case "${1:-}" in
    netns)   [ $# -ge 2 ] || { echo "Usage: $0 netns <IP/16>"; exit 1; }; do_netns "$2" ;;
    docker)  [ $# -ge 3 ] || { echo "Usage: $0 docker <IP/16> <name>"; exit 1; }; do_docker "$2" "$3" ;;
    verify)  [ $# -ge 2 ] || { echo "Usage: $0 verify <IP>"; exit 1; }; do_verify "$2" ;;
    clean)   do_clean ;;
    *)
        echo "Usage: $0 {netns|docker|verify|clean}"
        echo ""
        echo "  $0 netns 172.16.12.100/16"
        echo "  $0 docker 172.16.12.200/16 c1"
        echo "  $0 verify 172.16.13.100"
        echo "  $0 clean"
        exit 1 ;;
esac
info "Done"
