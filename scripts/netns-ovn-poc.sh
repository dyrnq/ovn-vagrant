#!/usr/bin/env bash
# ============================================================
# OVN as flannel-like L2 overlay — bridge gateway model
#
# Mirrors flannel's cni0 + flannel.1 architecture:
#   cni0 (bridge)   →  gw-$HOSTNAME (OVS internal port, gateway)
#   flannel.1 (VTEP) →  OVN Geneve tunnel (handled by ovn-controller)
#
# Each host gets a gateway (.1) on its /24 subnet.
# Workloads connect via veth pair and use 'default via .1'.
# ovn-node-agent auto-creates OVN lsp from OVS external_ids.
#
#   overlay switch (L2 flat)
#     ├── gw-ovn12 → 172.16.12.1/24   (gateway on ovn12)
#     ├── ns-ovn12 → 172.16.12.100/16  (test netns on ovn12)
#     ├── gw-ovn13 → 172.16.13.1/24   (gateway on ovn13)
#     └── ns-ovn13 → 172.16.13.100/16  (test netns on ovn13)
#
# Usage:
#   ovn11: sudo bash netns-ovn-poc.sh central
#   ovn12: sudo bash netns-ovn-poc.sh host 172.16.12.1/24
#   ovn13: sudo bash netns-ovn-poc.sh host 172.16.13.1/24
#   ovn12: sudo bash netns-ovn-poc.sh test 172.16.12.100/16
#   ovn13: sudo bash netns-ovn-poc.sh test 172.16.13.100/16
#   ovn12: sudo bash netns-ovn-poc.sh verify 172.16.13.100
#   ovn1X: sudo bash netns-ovn-poc.sh clean
# ============================================================
set -euo pipefail

CENTRAL_IP="192.168.200.11"
LS="overlay"
GW_DEV="gw-${HOSTNAME}"

HOSTNAME=$(hostname -s)
GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[${HOSTNAME}]${NC} $*"; }

# ── Central: create switch (one-time, like etcd init) ──
deploy_central() {
    info "=== Creating flannel-like L2 overlay ==="
    ovn-nbctl ls-add "$LS" 2>/dev/null || true
    info "Logical switch '$LS' ready"
    info ""
    info "== Run on each host:"
    info "   ovn12: sudo bash $0 host 172.16.12.1/24"
    info "   ovn13: sudo bash $0 host 172.16.13.1/24"
    info ""
    info "== Then start ovn-node-agent on each host (auto-creates lsp)"
}

# ── Host: create gateway (like flannel's cni0 bridge) ──
deploy_host() {
    local gw_cidr=$1                   # e.g. 172.16.12.1/24
    local gw_ip="${gw_cidr%/*}"        # 172.16.12.1

    info "=== Setting up gateway $GW_DEV ($gw_cidr) ==="

    # 1. veth pair: host-side (gw-$HOSTNAME) ↔ br-int-side (gw-int-$HOSTNAME)
    local gw_int="gw-int-${HOSTNAME}"
    ip link del "$GW_DEV" 2>/dev/null || true
    ip link add "$GW_DEV" type veth peer name "$gw_int"

    # 2. br-int side: attach to OVS, set external_ids for ovn-node-agent
    ovs-vsctl --if-exists del-port br-int "$gw_int" 2>/dev/null || true
    ovs-vsctl add-port br-int "$gw_int" -- set interface "$gw_int" external_ids:iface-id="$GW_DEV"
    ovs-vsctl set interface "$gw_int" external_ids:ovn-ip="$gw_ip"
    ip link set "$gw_int" up

    # 3. Sync MAC: host-side reads br-int-side MAC
    local gw_mac
    gw_mac=$(cat "/sys/class/net/$gw_int/address")
    ip link set "$GW_DEV" address "$gw_mac"

    # 4. Assign gateway IP on host
    ip addr flush dev "$GW_DEV" 2>/dev/null || true
    ip addr add "$gw_cidr" dev "$GW_DEV"
    ip link set "$GW_DEV" up

    info "  Gateway $gw_ip ready (veth: $GW_DEV ↔ $gw_int) — ovn-node-agent will auto-create lsp"
}

# ── Test: add a netns workload behind the gateway ──
add_test_ns() {
    local ns_cidr=$1                   # e.g. 172.16.12.100/16
    local ns_ip="${ns_cidr%/*}"
    local gw_ip
    gw_ip=$(ip -4 -o addr show dev "$GW_DEV" | grep -oP 'inet \K\S+' | cut -d/ -f1)
    [ -n "$gw_ip" ] || { info "ERROR: gateway $GW_DEV not configured — run 'host' first"; exit 1; }

    local ns_name="ns-test"
    local ns_dev="ns-${HOSTNAME}"

    info "=== Adding test netns $ns_name ($ns_cidr via $gw_ip) ==="

    # 1. Create veth pair: host-side → ns-side (eth0)
    ip link del "$ns_dev" 2>/dev/null || true
    ip link add "$ns_dev" type veth peer name eth0

    # 2. Host-side: attach to OVS, set external_ids for ovn-node-agent
    ovs-vsctl --if-exists del-port br-int "$ns_dev" 2>/dev/null || true
    ovs-vsctl add-port br-int "$ns_dev" -- set interface "$ns_dev" external_ids:iface-id="$ns_dev"
    ovs-vsctl set interface "$ns_dev" external_ids:ovn-ip="$ns_ip"
    ip link set "$ns_dev" up

    local ns_mac
    ns_mac=$(cat "/sys/class/net/$ns_dev/address")

    info "  OVS port created — ovn-node-agent will auto-create lsp"

    # 3. ns-side: set MAC to match host-side, move into netns
    ip netns add "$ns_name" 2>/dev/null || true
    ip link set eth0 address "$ns_mac" netns "$ns_name"
    ip netns exec "$ns_name" ip addr add "$ns_cidr" dev eth0
    ip netns exec "$ns_name" ip link set eth0 up
    ip netns exec "$ns_name" ip link set lo up
    ip netns exec "$ns_name" ip route add default via "$gw_ip"
    ip netns exec "$ns_name" ip addr show
    ip netns exec "$ns_name" ip route show

    info "$ns_name ready — default via $gw_ip"
}

# ── Verify: ping a remote workload ──
verify() {
    local peer=$1
    info "=== Testing $HOSTNAME → $peer ==="
    ip netns exec ns-test ip route get "$peer" 2>&1 || true
    ip netns exec ns-test ping -c 3 -W 1 "$peer" 2>&1
}

# ── Clean ──
clean() {
    info "Cleaning up..."
    ip netns del ns-test 2>/dev/null || true
    ovs-vsctl --if-exists del-port br-int "ns-${HOSTNAME}" 2>/dev/null || true
    ovs-vsctl --if-exists del-port br-int "gw-int-${HOSTNAME}" 2>/dev/null || true
    ovs-vsctl --if-exists del-port br-int "$GW_DEV" 2>/dev/null || true
    ip link del "gw-int-${HOSTNAME}" 2>/dev/null || true
    ip link del "ns-${HOSTNAME}" 2>/dev/null || true
    ovs-ofctl --strict del-flows br-int "table=41,priority=200,metadata=0x1" 2>/dev/null || true
    info "Done"
}

# ── Main ──
case "${1:-}" in
    central) deploy_central ;;
    host)
        [ $# -ge 2 ] || { echo "Usage: $0 host <GW_IP/24>"; exit 1; }
        deploy_host "$2"
        ;;
    test)
        [ $# -ge 2 ] || { echo "Usage: $0 test <IP/16>"; exit 1; }
        add_test_ns "$2"
        ;;
    verify)
        [ $# -ge 2 ] || { echo "Usage: $0 verify <peer-IP>"; exit 1; }
        verify "$2"
        ;;
    clean) clean ;;
    *)
        echo "Usage: $0 {central|host <GW/24>|test <IP/16>|verify <IP>|clean}"
        echo ""
        echo "  ovn11: $0 central"
        echo "  ovn12: $0 host 172.16.12.1/24"
        echo "  ovn13: $0 host 172.16.13.1/24"
        echo "  ovn12: $0 test 172.16.12.100/16"
        echo "  ovn13: $0 test 172.16.13.100/16"
        echo "  ovn12: $0 verify 172.16.13.100"
        exit 1 ;;
esac
info "Done"
