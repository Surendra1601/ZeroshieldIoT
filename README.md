# 🛡 ZeroTrust IoT Gateway

> A self-hosted, zero-trust security gateway for home IoT networks — automatic threat detection, device isolation, real-time dashboard, and Telegram alerts. No cloud. No subscription. Runs on a Raspberry Pi.

![Dashboard](https://img.shields.io/badge/Dashboard-React_SPA-c96442?style=flat-square)
![Backend](https://img.shields.io/badge/Backend-FastAPI_+_Python-1e4976?style=flat-square)
![Network](https://img.shields.io/badge/Network-Docker_+_iptables-2d6a27?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-gray?style=flat-square)

---

## What it does

Every IoT device is treated as **untrusted by default**. The gateway continuously monitors all 15+ devices across three isolated network zones, scores each device 0–100 every 7 seconds, and automatically quarantines anything that misbehaves.

```
192.168.10.0/24  →  Trusted (Kali, Host)       — score 100, no restrictions
192.168.20.0/24  →  IoT LAN (all devices)      — monitored, rate-limited, scored
192.168.30.0/24  →  Quarantine (isolated)       — no IoT access, monitored only
```

---

## Features

| Feature | Detail |
|---|---|
| **Auto-quarantine** | Score < 40 → device moved to quarantine LAN in < 7s |
| **East-west blocking** | All IoT↔IoT traffic blocked by default (iptables DROP) |
| **Whitelist exceptions** | Per-pair allow rules (e.g. badge → nas) with no false positives |
| **Rate limiting** | Zero-data-loss iptables MARK rules — SOFT warning / HARD quarantine |
| **External attack detection** | Trusted LAN scanning IoT LAN detected via tcpdump in 1 cycle |
| **Trust scoring** | 8-factor algorithm, computed every cycle, stored as sparkline history |
| **Real-time dashboard** | React SPA over HTTPS — devices, alerts, charts, network topology |
| **Telegram alerts** | Instant push — single combined message per attack event |
| **Multi-user auth** | JWT + bcrypt, admin/viewer roles, change-password endpoint |
| **Zero cloud** | Everything runs on-prem — no external services required |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     GATEWAY  192.168.35.136                 │
│                                                             │
│  zt_controller.py      →  monitoring loop (7s cycle)       │
│  dashboard_api.py      →  FastAPI REST + WebSocket :8443   │
│  behavior_monitor.sh   →  background tcpdump               │
│  rate_limit_manager.py →  iptables MARK rules              │
│  scoring.py            →  trust score algorithm            │
│  quarantine_manager.py →  docker network isolation         │
└────────────┬──────────────────┬──────────────┬─────────────┘
             │                  │              │
     ┌───────▼──────┐  ┌────────▼───────┐  ┌──▼──────────────┐
     │   IoT LAN    │  │  Quarantine    │  │  Trusted (ens37) │
     │ 20.0/24      │  │  LAN 30.0/24   │  │  10.0/24        │
     │ docker-iot   │  │  docker-quar   │  │  physical iface │
     │ 15 devices   │  │  isolated devs │  │  Kali, Host     │
     └──────────────┘  └────────────────┘  └─────────────────┘
```

---

## Quick Start

```bash
# Clone
git clone https://github.com/youruser/zerotrust-iot-gateway
cd zerotrust-iot-gateway

# Install everything (packages, Docker networks, TLS certs, iptables rules)
sudo bash setup.sh

# Start
sudo python3 zt_controller.py >> /var/log/zt-controller.log 2>&1 &
python3 -m uvicorn dashboard_api:app \
    --host 0.0.0.0 --port 8443 \
    --ssl-certfile certs/gateway.crt \
    --ssl-keyfile  certs/gateway.key &

# Dashboard
open https://<gateway-ip>:8443
# Default: admin / Admin1234  ← change after first login
```

---

## Detection

### How fast?

| Threat | Detection Time |
|---|---|
| External nmap scan (Kali → IoT) | ~4–7 seconds |
| East-west lateral movement | ~2–4 seconds |
| Rate limit HARD violation | 1 monitoring cycle (~7s) |
| New device on network | Next discovery cycle (~24s) |

### What gets detected?

- **External attacker** — trusted-LAN device scanning IoT LAN (`nmap`, etc.)
- **East-west movement** — any IoT device talking to another IoT device (unless whitelisted)
- **Port scanning** — device contacting >3 unique IoT targets per cycle
- **Rate limit SOFT** — connection rate above base threshold → score penalty
- **Rate limit HARD** — connection rate above ceiling → immediate quarantine
- **Active connection flood** — too many simultaneous open connections
- **New device joined** — unknown IP appears on any monitored LAN
- **Device left** — known device disappears

---

## Trust Score

Every device starts at **100**. Deductions applied each cycle:

```
-20   IoT device (always)
-10   Unknown vendor (MAC OUI)
-50   Port scanning detected
-40   Under active attack
-50   East-west lateral movement
-10   Previously quarantined
-30   Manually isolated (dashboard)
-10   Rate limit SOFT
-35   Rate limit HARD
```

**Threshold: score < 40 → quarantine**

---

## File Structure

```
zerotrust-iot-gateway/
├── zt_controller.py          # Master monitoring loop
├── dashboard_api.py          # FastAPI backend
├── auth.py                   # JWT + bcrypt auth
├── alert_manager.py          # Telegram + log alerts
├── quarantine_manager.py     # Docker network isolation
├── rate_limit_manager.py     # iptables MARK rate limiting
├── behavior_monitor.sh       # Background tcpdump monitor
├── traffic_monitor.py        # East-west + connection tracking
├── event_reader.py           # JSONL event reader
├── scoring.py                # Trust score algorithm
├── discovery.py              # ARP device discovery + fingerprinting
├── logger.py                 # Structured logging
├── env_loader.py             # .env config loader
├── quarantine_device.sh      # Docker network quarantine script
├── restore_device.sh         # Restore device to IoT LAN
├── dashboard.html            # React SPA (~1160 lines)
├── setup.sh                  # Full setup script
├── .env.example              # Environment config template
├── iot_whitelist.json        # IoT-to-IoT allow rules
└── static_web/               # PWA assets
```

---

## Device Management

### Add a device to IoT LAN
```bash
docker run -d --name <name> --network iot-lan nginx:alpine
```

### Manual quarantine / restore
```bash
sudo bash quarantine_device.sh <container> <ip>
sudo bash restore_device.sh <container>
```

### Add a whitelist rule (badge → nas)
Go to **Network tab → IoT Communication Whitelist → Add Rule** (admin only).

### Clear all flags and inactive devices
```bash
python3 - << 'EOF'
import json, subprocess
path = '/home/sk/device_history.json'
dh   = json.load(open(path))
running = subprocess.run(['docker','ps','--format','{{.Names}}'],
    capture_output=True, text=True).stdout.splitlines()
for name in list(dh.keys()):
    if name not in running and not name.startswith('trusted_') and not dh[name].get('quarantined'):
        del dh[name]; continue
    dh[name].update({'east_west':False,'under_attack':False,'scanning':False,
        'rl_penalty':0,'quarantine_reason':'','quarantine_cause':''})
json.dump(dh, open(path,'w'), indent=2)
EOF
```

---

## Environment Config

Copy `.env.example` to `.env` and fill in:

```bash
TELEGRAM_TOKEN=your_bot_token
TELEGRAM_CHAT_ID=your_chat_id
IOT_NET=192.168.20
TRUSTED_NET=192.168.10
QUARANTINE_NET=192.168.30
SCAN_THRESHOLD=3
MONITOR_INTERVAL=2
DISCOVERY_INTERVAL=3
```

---

## Dashboard Tabs

| Tab | Content |
|---|---|
| 📱 Devices | Zone sections · score badges · sparklines · device sheet |
| 🔔 Alerts | Unified time-sorted stream · attack dropdowns · unread badge |
| 📊 Charts | Trust distribution · score bars · avg trend · rate violations |
| 🌐 Network | SVG topology · device history · whitelist panel · zone cards |

---

## Logs

```
/var/log/zt-alerts.log         ← all alerts (dashboard + Telegram source)
/var/log/zt-controller.log     ← cycle-by-cycle controller output
/var/log/zt-ratelimit.log      ← rate limit events
/var/log/zt-behavior.log       ← behavior_monitor.sh output
/var/run/zt-monitor-events.jsonl  ← live inter-process event queue
/var/run/zt-heartbeat          ← last controller cycle timestamp
```

---

## Requirements

- Ubuntu 22.04 / 24.04 (or Raspberry Pi OS 64-bit)
- Python 3.10+
- Docker 24+
- `tcpdump`, `nmap`, `iptables-nft`
- 512 MB RAM minimum (Raspberry Pi 4 recommended)

---

## Roadmap

- [ ] SQLite migration (structured query over device history)
- [ ] NAS persistent storage via NFS mount
- [ ] Per-device connection log (who talked to whom, when)
- [ ] InfluxDB time-series for 30-day score trends
- [ ] ML anomaly detection baseline

---

## License

MIT — see [LICENSE](LICENSE)
