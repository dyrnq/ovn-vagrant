#!/usr/bin/env bash
# ============================================================
# Install geneve-agent as a systemd service.
#
# Pure OVS Geneve overlay agent — no OVN required.
#
# Usage:
#   sudo bash geneve-agent-install.sh
# ============================================================
set -euo pipefail

HOSTNAME=$(hostname -s)
GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[${HOSTNAME}]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_PATH="/usr/local/bin/geneve-agent"
UNIT_PATH="/etc/systemd/system/geneve-agent.service"

# 1. Install binary
cp "$SCRIPT_DIR/geneve-agent.py" "$BIN_PATH"
chmod 755 "$BIN_PATH"
info "Installed $BIN_PATH"

# 2. Ensure OVS bridge exists
if ! ovs-vsctl br-exists br-int 2>/dev/null; then
    ovs-vsctl add-br br-int
    info "Created br-int"
fi

# 3. Generate systemd unit
cat > "$UNIT_PATH" << UNIT
[Unit]
Description=Pure OVS Geneve overlay agent (like flanneld)
After=network-online.target openvswitch-switch.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/uv run $BIN_PATH
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
info "Installed + enabled $UNIT_PATH"
info ""
info "=== Start:"
info "   sudo systemctl start geneve-agent"
info "   sudo journalctl -u geneve-agent -f"
