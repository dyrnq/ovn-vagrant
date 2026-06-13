#!/usr/bin/env bash
# ============================================================
# OVN overlay POC — unified script (netns + Docker)
#
# Combines netns-ovn-poc.sh and docker-ovn-poc.sh.
# Gateway code is shared; workload type is a flag.
#
# Usage:
#   ovn11: ovn-poc.sh central
#   ovn12: ovn-poc.sh host 172.16.12.1/24
#   ovn12: ovn-poc.sh netns 172.16.12.100/16
#   ovn12: ovn-poc.sh docker 172.16.12.12/16 ovn12-c1
#   ovn12: ovn-poc.sh verify 172.16.13.100
#   ovn1X: ovn-poc.sh clean
# ============================================================
set -euo pipefail

CENTRAL_IP="192.168.200.11"
LS="overlay"
HOSTNAME=$(hostname -s)
GW_DEV="gw-${HOSTNAME}"
GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[${HOSTNAME}]${NC} $*"; }

# ── Central ─────────────────────────────────────────────────
do_central() {
    info "=== Creating overlay logical switch ==="
    ovn-nbctl ls-add "$LS" 2>/dev/null || true
    info "Switch '$LS' ready"
    info "== Run on each host: ovn-poc.sh host <GW/24>"
}

# ── Gateway (shared by netns and docker) ────────────────────
do_host() {
    local gw_cidr=$1
    local gw_ip="${gw_cidr%/*}"
    local gw_int="gw-int-${HOSTNAME}"

    info "=== Setting up gateway $GW_DEV ($gw_cidr) ==="

    # veth pair
    ip link del "$GW_DEV" 2>/dev/null || true
    ip link add "$GW_DEV" type veth peer name "$gw_int"

    # OVS side
    ovs-vsctl --if-exists del-port br-int "$gw_int" 2>/dev/null || true
    ovs-vsctl add-port br-int "$gw_int" -- set interface "$gw_int" external_ids:iface-id="$GW_DEV"
    ovs-vsctl set interface "$gw_int" external_ids:ovn-ip="$gw_ip"
    ip link set "$gw_int" up

    # MAC sync
    local gw_mac
    gw_mac=$(cat "/sys/class/net/$gw_int/address")
    ip link set "$GW_DEV" address "$gw_mac"

    # Assign IP
    ip addr flush dev "$GW_DEV" 2>/dev/null || true
    ip addr add "$gw_cidr" dev "$GW_DEV"
    ip link set "$GW_DEV" up

    # Table 41 bypass (OVS internal port workaround)
    ovs-ofctl --strict add-flow br-int \
        "table=41,priority=200,metadata=0x1,actions=load:0->NXM_NX_REG0[],load:0->NXM_NX_REG1[],load:0->NXM_NX_REG2[],load:0->NXM_NX_REG3[],load:0->NXM_NX_REG4[],load:0->NXM_NX_REG5[],load:0->NXM_NX_REG6[],load:0->NXM_NX_REG7[],load:0->NXM_NX_REG8[],load:0->NXM_NX_REG9[],resubmit(,42)" \
        2>/dev/null || true

    info "  Gateway $gw_ip ready"
}

# ── Workload helper (common veth logic) ─────────────────────
_setup_veth() {
    local dev=$1 ip_addr=$2 ns_type=$3 ns_id=$4
    # ns_type: "netns" or "docker"
    # ns_id: netns name or container PID

    # Unique MAC
    local mac
    mac="52:54:$(openssl rand -hex 1):$(openssl rand -hex 1):$(openssl rand -hex 1):$(openssl rand -hex 1)"

    # veth pair
    ip link del "$dev" 2>/dev/null || true
    ip link add "$dev" type veth peer name eth0
    ip link set "$dev" address "$mac"
    ip link set eth0 address "$mac"

    # OVS side
    ovs-vsctl --if-exists del-port br-int "$dev" 2>/dev/null || true
    ovs-vsctl add-port br-int "$dev" -- set interface "$dev" external_ids:iface-id="$dev"
    ovs-vsctl set interface "$dev" external_ids:ovn-ip="${ip_addr%/*}"
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
    local gw_ip
    gw_ip=$(ip -4 -o addr show dev "$GW_DEV" | grep -oP 'inet \K\S+' | cut -d/ -f1)
    [ -n "$gw_ip" ] || { info "ERROR: gateway $GW_DEV not found — run 'host' first"; exit 1; }

    local ns_dev="ns-${HOSTNAME}"
    info "=== Netns workload ($cidr via $gw_ip) ==="

    _setup_veth "$ns_dev" "$cidr" "netns" "ns-test"
    ip netns exec ns-test ip route add default via "$gw_ip"

    info "ns-test ready"
}

# ── Docker workload ─────────────────────────────────────────
do_docker() {
    local cidr=$1 cn=$2
    local gw_ip
    gw_ip=$(ip -4 -o addr show dev "$GW_DEV" | grep -oP 'inet \K\S+' | cut -d/ -f1)
    [ -n "$gw_ip" ] || { info "ERROR: gateway $GW_DEV not found — run 'host' first"; exit 1; }

    local pn="port-${cn}"
    info "=== Docker workload $cn ($cidr via $gw_ip) ==="

    docker rm -f "$cn" 2>/dev/null || true
    docker run -d --name "$cn" --network=none alpine:3.21 sleep infinity
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$cn")

    _setup_veth "$pn" "$cidr" "docker" "$pid"
    nsenter -t "$pid" -n ip route add default via "$gw_ip"

    info "$cn ready"
}

# ── Verify ──────────────────────────────────────────────────
do_verify() {
    local peer=$1
    info "=== Testing → $peer ==="
    # Try netns first, then docker
    if ip netns list 2>/dev/null | grep -q ns-test; then
        ip netns exec ns-test ping -c 3 -W 1 "$peer" 2>&1
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'ovn.*-c1\|geneve-c1'; then
        local cn
        cn=$(docker ps --format '{{.Names}}' | grep -E 'ovn.*-c1|geneve-c1' | head -1)
        docker exec "$cn" ping -c 3 -W 1 "$peer" 2>&1
    else
        info "No workload found (run 'netns' or 'docker' first)"
        exit 1
    fi
}

# ── Clean ───────────────────────────────────────────────────
do_clean() {
    info "Cleaning..."
    ip netns del ns-test 2>/dev/null || true
    ip link del "ns-${HOSTNAME}" 2>/dev/null || true
    docker rm -f "ovn${HOSTNAME#ovn}-c1" 2>/dev/null || true
    docker rm -f "geneve-c1" 2>/dev/null || true
    ip link del "port-ovn${HOSTNAME#ovn}-c1" 2>/dev/null || true
    ip link del "port-geneve-c1" 2>/dev/null || true
    ovs-vsctl --if-exists del-port br-int "gw-int-${HOSTNAME}" 2>/dev/null || true
    ovs-vsctl --if-exists del-port br-int "$GW_DEV" 2>/dev/null || true
    ip link del "$GW_DEV" 2>/dev/null || true
    ip link del "gw-int-${HOSTNAME}" 2>/dev/null || true
    ovs-ofctl --strict del-flows br-int "table=41,priority=200,metadata=0x1" 2>/dev/null || true
    info "Done"
}

# ── Main ────────────────────────────────────────────────────
case "${1:-}" in
    central)  do_central ;;
    host)     [ $# -ge 2 ] || { echo "Usage: $0 host <GW/24>"; exit 1; }
              do_host "$2" ;;
    netns)    [ $# -ge 2 ] || { echo "Usage: $0 netns <IP/16>"; exit 1; }
              do_netns "$2" ;;
    docker)   [ $# -ge 3 ] || { echo "Usage: $0 docker <IP/16> <name>"; exit 1; }
              do_docker "$2" "$3" ;;
    verify)   [ $# -ge 2 ] || { echo "Usage: $0 verify <IP>"; exit 1; }
              do_verify "$2" ;;
    clean)    do_clean ;;
    *)
        echo "Usage: $0 {central|host|netns|docker|verify|clean}"
        echo ""
        echo "  ovn11: $0 central"
        echo "  ovn12: $0 host 172.16.12.1/24"
        echo "  ovn12: $0 netns 172.16.12.100/16"
        echo "  ovn12: $0 docker 172.16.12.12/16 ovn12-c1"
        echo "  ovn12: $0 verify 172.16.13.100"
        echo "  ovn1X: $0 clean"
        exit 1 ;;
esac
info "Done"
