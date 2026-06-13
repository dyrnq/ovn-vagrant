#!/usr/bin/env bash
# ============================================================
# OVN POC 部署脚本 — Vagrant 3 节点 (ovn11/12/13)
# 用 uv 管理 Python 依赖，无需 pip install
# ============================================================
set -euo pipefail

CENTRAL_IP="192.168.200.11"
CENTRAL_HOST="ovn11"
API_PORT=18081
API_KEY="ovn-api-key-2024"
OVN_ENCAP_TYPE="geneve"

HOSTNAME=$(hostname -s)
LOCAL_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep '192.168.200' | head -1)

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[${HOSTNAME}]${NC} $*"; }
err()   { echo -e "${RED}[${HOSTNAME}]${NC} $*"; }

# ============================================================
# 通用: 安装 OVS + OVN 包 (系统级)
# ============================================================
install_packages() {
    info "安装 OVS + OVN 软件包..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq openvswitch-switch ovn-central ovn-host
    info "软件包安装完成"
}

# ============================================================
# Central 节点 (ovn11): NB DB + SB DB + northd + REST API
# ============================================================
deploy_central() {
    info "=== 部署 OVN Central ==="

    # 启动 northd
    systemctl enable ovn-central
    systemctl restart ovn-central
    sleep 2

    # 开启 NB/SB DB TCP 监听 (Ubuntu 24.04 默认只开 unix socket)
    ovs-appctl -t /var/run/ovn/ovnnb_db.ctl ovsdb-server/add-remote ptcp:6641:0.0.0.0 2>/dev/null || true
    ovs-appctl -t /var/run/ovn/ovnsb_db.ctl ovsdb-server/add-remote ptcp:6642:0.0.0.0 2>/dev/null || true

    info "ovn-northd 状态: $(systemctl is-active ovn-northd)"
    info "OVN Central 就绪"

    deploy_api
}

# ============================================================
# REST API (ovn11) — 安装 ovn-api.py
# ============================================================
deploy_api() {
    info "=== 部署 OVN REST API (uv) ==="

    local api_dir="/opt/ovn-api"
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"

    mkdir -p "$api_dir"
    cp "$script_dir/ovn-api.py" "$api_dir/main.py"
    chmod 644 "$api_dir/main.py"

    cat > /etc/systemd/system/ovn-api.service << SVCEOF
[Unit]
Description=OVN REST API (uv)
After=network.target ovn-central.service

[Service]
Type=simple
User=root
WorkingDirectory=${api_dir}
ExecStart=/usr/local/bin/uv run --no-cache ${api_dir}/main.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable ovn-api
    systemctl restart ovn-api
    sleep 3

    info "REST API 状态: $(systemctl is-active ovn-api)"
    curl -sf http://127.0.0.1:${API_PORT}/api/health && info "API 健康检查 OK"
}

# ============================================================
# Host 节点: ovn-controller + ovs-vswitchd
# ============================================================
deploy_host() {
    info "=== 部署 OVN Host ==="

    ovs-vsctl set open . external_ids:ovn-remote="tcp:${CENTRAL_IP}:6642"
    ovs-vsctl set open . external_ids:ovn-encap-type="${OVN_ENCAP_TYPE}"
    ovs-vsctl set open . external_ids:ovn-encap-ip="${LOCAL_IP}"

    systemctl enable ovn-controller 2>/dev/null || true
    systemctl restart ovn-controller
    sleep 2

    info "ovn-controller 状态: $(systemctl is-active ovn-controller)"
    info "OVN Host 就绪 (encap: ${OVN_ENCAP_TYPE}, ip: ${LOCAL_IP})"
}

# ============================================================
# 验证
# ============================================================
verify() {
    info "=== 验证 OVN 集群 ==="
    if [ "${HOSTNAME}" = "${CENTRAL_HOST}" ]; then
        echo "--- Chassis 列表 ---"
        ovn-sbctl show 2>&1 || true
        echo "--- REST API 测试 ---"
        curl -sf -X POST "http://127.0.0.1:${API_PORT}/api/bridge/" \
            -H "X-API-Key: ${API_KEY}" \
            -H "Content-Type: application/json" \
            -d '{"name":"poc-test","cidr":"10.200.0.0/24","gateway":"10.200.0.1"}' 2>&1
        curl -sf -X DELETE "http://127.0.0.1:${API_PORT}/api/bridge/poc-test" \
            -H "X-API-Key: ${API_KEY}" 2>&1
        echo ""
        info "验证完成"
    fi
}

# ============================================================
# Main
# ============================================================
install_packages

if [ "${HOSTNAME}" = "${CENTRAL_HOST}" ]; then
    deploy_central
    deploy_host
    verify
else
    deploy_host
fi

info "===== OVN 部署完成 (${HOSTNAME}) ====="
