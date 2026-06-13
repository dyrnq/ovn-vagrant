#!/usr/bin/env bash
# ============================================================
# Docker + OVN L2 overlay — bridge gateway model
#
# ovn-node-agent auto-creates OVN lsp from OVS external_ids.
# No manual lsp-add needed — just set iface-id + ovn-ip.
#
#   overlay switch (L2 flat)
#     ├── gw-ovn12    → 172.16.12.1/24  (gateway on ovn12)
#     ├── port-ovn12-c1 → 172.16.12.12/16 (container on ovn12)
#     ├── gw-ovn13    → 172.16.13.1/24  (gateway on ovn13)
#     └── port-ovn13-c1 → 172.16.13.13/16 (container on ovn13)
#
# Usage:
#   ovn11: sudo bash docker-ovn-poc.sh finish
#   ovn12: sudo bash docker-ovn-poc.sh deploy
#   ovn13: sudo bash docker-ovn-poc.sh deploy
#   ovn1X: sudo bash docker-ovn-poc.sh clean
# ============================================================
set -euo pipefail

CENTRAL_IP="192.168.200.11"
LS="overlay"
GW_DEV="gw-${HOSTNAME}"

HOSTNAME=$(hostname -s)
GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[${HOSTNAME}]${NC} $*"; }

# ── Docker install ──
install_docker() {
    if command -v docker &>/dev/null; then info "Docker ready"; return; fi
    info "Installing Docker..."
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://mirrors.ustc.edu.cn/docker-ce/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.ustc.edu.cn/docker-ce/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io
    mkdir -p /etc/docker
    tee /etc/docker/daemon.json <<< '{"registry-mirrors":["https://docker.m.daocloud.io","https://docker.1ms.run"]}' >/dev/null
    systemctl restart docker
    info "Docker $(docker --version)"
}

# ── Central: create switch + ACLs (no lsp-add — agent handles it) ──
create_switch_and_acl() {
    info "=== Creating L2 overlay ==="
    ovn-nbctl ls-add "$LS" 2>/dev/null || true
    ovn-nbctl acl-del "$LS" 2>/dev/null || true
    ovn-nbctl acl-add "$LS" from-lport 1 'ip4' allow
    ovn-nbctl acl-add "$LS" to-lport   1 'ip4' allow
    info "Switch '$LS' ready — ovn-node-agent will auto-create lsp"
}

# ── Host: create gateway (like flannel's cni0 bridge) ──
setup_gateway() {
    local gw_cidr=$1                   # e.g. 172.16.12.1/24
    local gw_ip="${gw_cidr%/*}"

    info "=== Setting up gateway $GW_DEV ($gw_cidr) ==="

    # veth pair: host-side (gw-$HOSTNAME) ↔ br-int-side (gw-int-$HOSTNAME)
    local gw_int="gw-int-${HOSTNAME}"
    ip link del "$GW_DEV" 2>/dev/null || true
    ip link add "$GW_DEV" type veth peer name "$gw_int"

    # br-int side: attach to OVS, set external_ids for ovn-node-agent
    ovs-vsctl --if-exists del-port br-int "$gw_int" 2>/dev/null || true
    ovs-vsctl add-port br-int "$gw_int" -- set interface "$gw_int" external_ids:iface-id="$GW_DEV"
    ovs-vsctl set interface "$gw_int" external_ids:ovn-ip="$gw_ip"
    ip link set "$gw_int" up

    # Sync MAC: host-side reads br-int-side MAC
    local gw_mac
    gw_mac=$(cat "/sys/class/net/$gw_int/address")
    ip link set "$GW_DEV" address "$gw_mac"

    # Assign gateway IP on host
    ip addr flush dev "$GW_DEV" 2>/dev/null || true
    ip addr add "$gw_cidr" dev "$GW_DEV"
    ip link set "$GW_DEV" up

    info "  Gateway $gw_ip ready (veth: $GW_DEV ↔ $gw_int)"  
}

# ── Host: setup container behind gateway ──
setup_container() {
    local cidr=$1 pn=$2 cn=$3          # e.g. 172.16.12.12/16, port-ovn12-c1, ovn12-c1
    local container_ip="${cidr%/*}"
    local gw_ip
    gw_ip=$(ip -4 -o addr show dev "$GW_DEV" | grep -oP 'inet \K\S+' | cut -d/ -f1)
    [ -n "$gw_ip" ] || { info "ERROR: gateway $GW_DEV not set up — run setup_gateway first"; exit 1; }

    info "=== Setting up $cn ($cidr via gw $gw_ip) ==="

    # 1. Docker container (network=none — we provide our own networking)
    docker rm -f "$cn" 2>/dev/null || true
    docker run -d --name "$cn" --network=none alpine:3.21 sleep infinity

    # 2. veth pair: host-side → container-side (eth0)
    ip link del "$pn" 2>/dev/null || true
    ip link add "$pn" type veth peer name eth0

    # 3. Host-side: attach to OVS, set external_ids for ovn-node-agent
    ovs-vsctl --if-exists del-port br-int "$pn" 2>/dev/null || true
    ovs-vsctl add-port br-int "$pn" -- set interface "$pn" external_ids:iface-id="$pn"
    ovs-vsctl set interface "$pn" external_ids:ovn-ip="$container_ip"
    ip link set "$pn" up

    local real_mac
    real_mac=$(cat "/sys/class/net/$pn/address" 2>/dev/null \
               || ip link show "$pn" | grep -oP 'link/ether \K\S+')
    info "  MAC: $real_mac — ovn-node-agent will auto-create lsp"

    # 4. Set eth0 MAC to match host-side veth, move into container
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$cn")
    ip link set eth0 address "$real_mac" netns "$pid"
    nsenter -t "$pid" -n ip addr add "$cidr" dev eth0
    nsenter -t "$pid" -n ip link set eth0 up
    nsenter -t "$pid" -n ip link set lo up
    nsenter -t "$pid" -n ip route add default via "$gw_ip"

    info "  Container routes:"
    nsenter -t "$pid" -n ip route show

    info "$cn ready — all traffic via gateway $gw_ip"
}

# ── Clean ──
clean() {
    info "Cleaning..."
    case "$HOSTNAME" in
        ovn12) docker rm -f ovn12-c1 2>/dev/null || true
               ovs-vsctl --if-exists del-port br-int port-ovn12-c1 2>/dev/null || true
               ip link del port-ovn12-c1 2>/dev/null || true ;;
        ovn13) docker rm -f ovn13-c1 2>/dev/null || true
               ovs-vsctl --if-exists del-port br-int port-ovn13-c1 2>/dev/null || true
               ip link del port-ovn13-c1 2>/dev/null || true ;;
    esac
    ovs-vsctl --if-exists del-port br-int "gw-int-${HOSTNAME}" 2>/dev/null || true
    ovs-vsctl --if-exists del-port br-int "$GW_DEV" 2>/dev/null || true
    ip link del "gw-int-${HOSTNAME}" 2>/dev/null || true
    ovs-ofctl --strict del-flows br-int "table=41,priority=200,metadata=0x1" 2>/dev/null || true
    info "Cleaned"
}

# ── Main ──
case "${1:-deploy}" in
    clean)  install_docker; clean; exit 0 ;;
    finish)
        install_docker
        create_switch_and_acl
        info ""
        info "=== Verify (after starting ovn-node-agent on ovn12 & ovn13):"
        info "  vagrant ssh ovn12 -- sudo docker exec ovn12-c1 ping 172.16.13.13"
        info "  vagrant ssh ovn13 -- sudo docker exec ovn13-c1 ping 172.16.12.12"
        ;;
    deploy)
        install_docker
        case "$HOSTNAME" in
            ovn12)
                setup_gateway "172.16.12.1/24"
                setup_container "172.16.12.12/16" "port-ovn12-c1" "ovn12-c1"
                ;;
            ovn13)
                setup_gateway "172.16.13.1/24"
                setup_container "172.16.13.13/16" "port-ovn13-c1" "ovn13-c1"
                ;;
            *) info "Run deploy on ovn12 or ovn13 only"; exit 1 ;;
        esac
        ;;
    *)
        echo "Usage: $0 {deploy|finish|clean}"
        echo ""
        echo "  deploy  - setup gateway + container (run on ovn12 & ovn13)"
        echo "  finish  - create switch + ACLs (run on ovn11)"
        echo "  clean   - tear down"
        exit 1 ;;
esac
info "POC complete"
