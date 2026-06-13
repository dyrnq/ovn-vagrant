#!/usr/bin/env bash
# ============================================================
# Install ovn-node-agent as a systemd service.
#
# Usage:
#   sudo bash ovn-node-agent-install.sh
# ============================================================
set -euo pipefail

HOSTNAME=$(hostname -s)
GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[${HOSTNAME}]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_PATH="/usr/local/bin/ovn-node-agent"
UNIT_PATH="/etc/systemd/system/ovn-node-agent.service"

# 1. Install binary
cp "$SCRIPT_DIR/ovn-node-agent.py" "$BIN_PATH"
chmod 755 "$BIN_PATH"
info "Installed $BIN_PATH"

# 2. Generate systemd unit
cat > "$UNIT_PATH" << UNIT
[Unit]
Description=OVN node agent — auto-discovery overlay daemon (like flanneld)
After=network-online.target ovs-vswitchd.service ovn-controller.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/uv run $BIN_PATH
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ovn-node-agent

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable ovn-node-agent.service
info "Installed + enabled $UNIT_PATH"
info ""
info "=== Start:"
info "   sudo systemctl start ovn-node-agent"
info "   sudo journalctl -u ovn-node-agent -f"
