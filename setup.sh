#!/bin/bash
# =============================================================
# ZeroTrust IoT Gateway — Setup Script
# Ubuntu 22.04/24.04 | Run as root or sudo user
# Usage: sudo bash setup.sh
# =============================================================

set -e
SK_HOME="${SK_HOME:-/home/sk}"
USER="${SUDO_USER:-sk}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()  { echo -e "${GREEN}✅ $1${NC}"; }
info(){ echo -e "${CYAN}ℹ  $1${NC}"; }
warn(){ echo -e "${YELLOW}⚠  $1${NC}"; }
die() { echo -e "${RED}✗  $1${NC}"; exit 1; }

echo ""
echo "=============================================="
echo " ZeroTrust IoT Gateway — Setup"
echo "=============================================="
echo ""

# ── 0. Root check ─────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root: sudo bash setup.sh"

# ── 1. System packages ────────────────────────────────────────
info "Installing system packages..."
apt-get update -qq
apt-get install -y -qq \
    python3 python3-pip python3-venv \
    docker.io docker-compose \
    tcpdump nmap \
    iptables iptables-persistent \
    nftables \
    net-tools iproute2 \
    openssl curl jq \
    bridge-utils
ok "System packages installed"

# ── 2. Python dependencies ────────────────────────────────────
info "Installing Python packages..."
pip3 install --break-system-packages --quiet \
    fastapi uvicorn aiofiles \
    bcrypt python-jose \
    requests urllib3
ok "Python packages installed"

# ── 3. Docker setup ───────────────────────────────────────────
info "Configuring Docker..."
systemctl enable docker --quiet
systemctl start docker
usermod -aG docker "$USER" 2>/dev/null || true
ok "Docker configured"

# ── 4. Docker networks ────────────────────────────────────────
info "Creating Docker networks..."

# IoT LAN
docker network inspect iot-lan >/dev/null 2>&1 || \
    docker network create \
        --driver bridge \
        --subnet 192.168.20.0/24 \
        --gateway 192.168.20.1 \
        --opt com.docker.network.bridge.name=docker-iot \
        iot-lan
ok "iot-lan: 192.168.20.0/24 (bridge: docker-iot)"

# Quarantine LAN
docker network inspect quarantine-lan >/dev/null 2>&1 || \
    docker network create \
        --driver bridge \
        --subnet 192.168.30.0/24 \
        --gateway 192.168.30.1 \
        --opt com.docker.network.bridge.name=docker-quar \
        quarantine-lan
ok "quarantine-lan: 192.168.30.0/24 (bridge: docker-quar)"

# ── 5. iptables rules ─────────────────────────────────────────
info "Applying iptables rules..."

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 -q
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-zerotrust.conf

# Block IoT-to-IoT by default (east-west isolation)
iptables-nft -C FORWARD -s 192.168.20.0/24 -d 192.168.20.0/24 -j DROP 2>/dev/null || \
    iptables-nft -I FORWARD 1 -s 192.168.20.0/24 -d 192.168.20.0/24 -j DROP

# Block quarantine → IoT
iptables-nft -C FORWARD -i docker-quar -o docker-iot -j DROP 2>/dev/null || \
    iptables-nft -A FORWARD -i docker-quar -o docker-iot -j DROP

# Block quarantine → external
iptables-nft -C FORWARD -i docker-quar -o ens37 -j DROP 2>/dev/null || \
    iptables-nft -A FORWARD -i docker-quar -o ens37 -j DROP

# Save rules
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
ok "iptables rules applied"

# ── 6. Log files ──────────────────────────────────────────────
info "Creating log files..."
for f in /var/log/zt-alerts.log /var/log/zt-controller.log \
          /var/log/zt-ratelimit.log /var/log/zt-behavior.log; do
    touch "$f"
    chmod 666 "$f"
done
touch /var/run/zt-monitor-events.jsonl
chmod 666 /var/run/zt-monitor-events.jsonl
ok "Log files created"

# ── 7. TLS certificates ───────────────────────────────────────
info "Generating self-signed TLS certificate..."
CERT_DIR="$SK_HOME/certs"
mkdir -p "$CERT_DIR"
if [[ ! -f "$CERT_DIR/gateway.crt" ]]; then
    GW_IP=$(hostname -I | awk '{print $1}')
    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout "$CERT_DIR/gateway.key" \
        -out    "$CERT_DIR/gateway.crt" \
        -days   3650 \
        -subj   "/CN=ZeroTrust-Gateway/O=HomeNetwork" \
        -addext "subjectAltName=IP:${GW_IP},IP:127.0.0.1" \
        2>/dev/null
    chown "$USER:$USER" "$CERT_DIR"/*
    ok "TLS certificate generated (CN=${GW_IP})"
else
    ok "TLS certificate already exists"
fi

# ── 8. auth_config.json ───────────────────────────────────────
AUTH_FILE="$SK_HOME/auth_config.json"
if [[ ! -f "$AUTH_FILE" ]]; then
    info "Creating default auth config..."
    python3 -c "
import json, secrets, bcrypt
pw = bcrypt.hashpw(b'Admin1234', bcrypt.gensalt(rounds=12)).decode()
cfg = {
    'mode': 'jwt',
    'username': 'admin',
    'password': pw,
    'api_key': secrets.token_urlsafe(32),
    'jwt_secret': secrets.token_urlsafe(64),
    'users': []
}
with open('$AUTH_FILE', 'w') as f:
    json.dump(cfg, f, indent=2)
print('Default login: admin / Admin1234')
"
    chmod 600 "$AUTH_FILE"
    chown "$USER:$USER" "$AUTH_FILE"
    warn "Default password is Admin1234 — change it after first login!"
else
    ok "auth_config.json already exists"
fi

# ── 9. .env file ──────────────────────────────────────────────
ENV_FILE="$SK_HOME/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    info "Creating .env file..."
    cat > "$ENV_FILE" << 'ENVEOF'
IOT_NET=192.168.20
TRUSTED_NET=192.168.10
QUARANTINE_NET=192.168.30
SCAN_THRESHOLD=3
MONITOR_INTERVAL=2
DISCOVERY_INTERVAL=3
SLEEP_BETWEEN=1
BEHAVIOR_MONITOR=/home/sk/behavior_monitor.sh
DEVICE_HISTORY=/home/sk/device_history.json
HEARTBEAT_FILE=/var/run/zt-heartbeat
EVENTS_FILE=/var/run/zt-monitor-events.jsonl
WHITELIST_FILE=/home/sk/iot_whitelist.json
DASHBOARD_HTML=/home/sk/dashboard.html
STATIC_DIR=/home/sk/static_web
ALERT_LOG=/var/log/zt-alerts.log
RATELIMIT_LOG=/var/log/zt-ratelimit.log
TELEGRAM_TOKEN=
TELEGRAM_CHAT_ID=
TELEGRAM_TIMEOUT=5
APP_PATH=/home/sk
SK_HOME=/home/sk
ENVEOF
    chown "$USER:$USER" "$ENV_FILE"
    warn "Edit $ENV_FILE to add your TELEGRAM_TOKEN and TELEGRAM_CHAT_ID"
else
    ok ".env already exists"
fi

# ── 10. Init files ────────────────────────────────────────────
info "Initialising empty data files..."
for f in "$SK_HOME/iot_whitelist.json" "$SK_HOME/device_history.json"; do
    if [[ ! -f "$f" ]]; then
        echo '{}' > "$f"
        chown "$USER:$USER" "$f"
        ok "Created $f"
    fi
done

# Whitelist should be array
python3 -c "
import json
p='$SK_HOME/iot_whitelist.json'
d=json.load(open(p))
if isinstance(d,dict):
    json.dump([],open(p,'w'),indent=2)
"

# ── 11. Demo IoT containers ───────────────────────────────────
echo ""
read -rp "Deploy 15 demo IoT containers? [y/N] " DEMO
if [[ "$DEMO" =~ ^[Yy]$ ]]; then
    info "Deploying demo containers..."

    declare -A CONTAINERS=(
        ["badge"]="nginx:alpine"
        ["sensorhub"]="nginx:alpine"
        ["lock1"]="nginx:alpine"
        ["envsensor"]="eclipse-mosquitto"
        ["lighting"]="eclipse-mosquitto"
        ["thermo1"]="eclipse-mosquitto"
        ["printer"]="olbat/cupsd"
        ["tv1"]="nginx:alpine"
        ["chromecast"]="nginx:alpine"
        ["bulb1"]="eclipse-mosquitto"
        ["nvr"]="nginx:alpine"
        ["nas"]="httpd:alpine"
        ["plug1"]="httpd:alpine"
        ["cam1"]="nginx:alpine"
        ["energymeter"]="nginx:alpine"
    )

    for name in "${!CONTAINERS[@]}"; do
        image="${CONTAINERS[$name]}"
        if docker inspect "$name" >/dev/null 2>&1; then
            info "$name already exists, skipping"
        else
            docker run -d --name "$name" --network iot-lan \
                --restart unless-stopped "$image" >/dev/null 2>&1 \
                && ok "Started $name ($image)" \
                || warn "Failed to start $name"
        fi
    done
    ok "Demo containers deployed"
fi

# ── 12. systemd services ──────────────────────────────────────
echo ""
read -rp "Install systemd services (auto-start on boot)? [y/N] " SYSTEMD
if [[ "$SYSTEMD" =~ ^[Yy]$ ]]; then
    # Controller service
    cat > /etc/systemd/system/zt-controller.service << SVCEOF
[Unit]
Description=ZeroTrust IoT Gateway Controller
After=network.target docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=$SK_HOME
ExecStart=/usr/bin/python3 $SK_HOME/zt_controller.py
Restart=always
RestartSec=5
StandardOutput=append:/var/log/zt-controller.log
StandardError=append:/var/log/zt-controller.log
Environment=APP_PATH=$SK_HOME

[Install]
WantedBy=multi-user.target
SVCEOF

    # Dashboard service
    cat > /etc/systemd/system/zt-dashboard.service << SVCEOF
[Unit]
Description=ZeroTrust IoT Gateway Dashboard
After=network.target

[Service]
User=$USER
WorkingDirectory=$SK_HOME
ExecStart=/usr/bin/python3 -m uvicorn dashboard_api:app \
    --host 0.0.0.0 --port 8443 \
    --ssl-certfile $SK_HOME/certs/gateway.crt \
    --ssl-keyfile  $SK_HOME/certs/gateway.key
Restart=always
RestartSec=5
Environment=APP_PATH=$SK_HOME
Environment=SK_HOME=$SK_HOME

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable zt-controller zt-dashboard
    ok "systemd services installed and enabled"
    info "Start with: sudo systemctl start zt-controller zt-dashboard"
fi

# ── 13. Static web assets ─────────────────────────────────────
STATIC="$SK_HOME/static_web"
mkdir -p "$STATIC"
if [[ ! -f "$STATIC/manifest.json" ]]; then
    cat > "$STATIC/manifest.json" << 'MANEOF'
{
  "name": "ZeroTrust Gateway",
  "short_name": "ZeroTrust",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#f5f4ed",
  "theme_color": "#c96442",
  "icons": []
}
MANEOF
    echo 'self.addEventListener("fetch",()=>{})' > "$STATIC/sw.js"
    chown -R "$USER:$USER" "$STATIC"
    ok "Static web assets created"
fi

# ── 14. Summary ───────────────────────────────────────────────
GW_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "=============================================="
echo -e "${GREEN} Setup complete!${NC}"
echo "=============================================="
echo ""
echo "  Dashboard:  https://${GW_IP}:8443"
echo "  Default login: admin / Admin1234"
echo "  (Change password after first login)"
echo ""
echo "  Start manually:"
echo "    sudo python3 $SK_HOME/zt_controller.py >> /var/log/zt-controller.log 2>&1 &"
echo "    cd $SK_HOME && python3 -m uvicorn dashboard_api:app \\"
echo "        --host 0.0.0.0 --port 8443 \\"
echo "        --ssl-certfile $SK_HOME/certs/gateway.crt \\"
echo "        --ssl-keyfile  $SK_HOME/certs/gateway.key &"
echo ""
echo "  Edit $SK_HOME/.env to configure Telegram alerts."
echo ""
echo "  Next step — add devices:"
echo "    docker run -d --name <name> --network iot-lan nginx:alpine"
echo ""
