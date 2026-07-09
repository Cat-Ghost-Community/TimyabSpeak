# 🎮 TimyabSpeak — TeamSpeak 6 One-Command Server Manager

**TimyabSpeak** (formerly TeamTP) is a complete, professional TeamSpeak 6 server deployment system with a one-command installer, three integrated bots (level-up, temp channels, support ticketing), a modern web panel, and a powerful CLI — all packaged as a single setup wizard.

```
curl -fsSL https://raw.githubusercontent.com/Cat-Ghost-Community/TimyabSpeak/main/install.sh | sudo bash
```

---

## Features

| Category | Details |
|----------|---------|
| **Server** | Auto-installs TS6 server, configures YAML, systemd service, port scanning with fallback |
| **SSL** | Let's Encrypt (domain) or self-signed (IP) — auto-configured with nginx reverse proxy |
| **Roles** | 9 server groups with full permission matrix — Owner, Admin, Mod, Support, Elite, Veteran, Member, Guest, Bot |
| **Channels** | 23 channels in 6 themed categories — Welcome, Game Zone (with Time Window), Social, Support, Statistics, Staff |
| **Level Bot** | XP tracking via voice activity, role promotion, daily streaks, leaderboard, 9 achievements |
| **Temp Channel Bot** | 19 commands — create, rename, lock, password, private, invite, kick, bitrate, timeout, claim, hide, permanent, delete |
| **Support Bot** | Full ticketing system — create/claim/transfer/close tickets, staff notes, auto-transcripts, FAQ, blocklist |
| **Web Panel** | Dashboard, ticket management, user leaderboard, channel viewer, role viewer, bot controls, backup manager, SSL renew, live logs |
| **CLI** | `teamtp` — status, restart, panel, bot control, SSL renew, backup, update, health, logs, wipe |
| **Security** | Query interfaces bound to 127.0.0.1, UFW firewall, fail2ban, dedicated system users, .env chmod 600, JWT auth, rate limiting |

---

## Quick Start

### System Requirements

| Requirement | Minimum |
|------------|---------|
| OS | Ubuntu 22.04+ / Debian 12+ |
| Architecture | x86_64 (ARM64 with libatomic1) |
| RAM | 512 MB |
| Disk | 2 GB free in /opt |
| glibc | >= 2.32 |
| Node.js | >= 20.x (auto-installed) |

### One-Command Install

```bash
# Basic install (prompts for config)
curl -fsSL https://raw.githubusercontent.com/Cat-Ghost-Community/TimyabSpeak/main/install.sh | sudo bash
```

### With Custom TS6 Download URL

```bash
TS6_URL=https://your-mirror/tsserver.tar.gz sudo bash install.sh
```

### Dry-Run Preview

```bash
curl -fsSL https://raw.githubusercontent.com/Cat-Ghost-Community/TimyabSpeak/main/install.sh | sudo bash -s -- --dry-run
```

---

## Installation — Private Repo via SSH

For private repositories or when you have your own fork:

### 1. Generate a GitHub Fine-Grained PAT

1. Go to **GitHub Settings → Developer settings → Personal access tokens → Fine-grained tokens**
2. Click **Generate new token**
3. Set:
   - **Token name**: `TimyabSpeak-deploy`
   - **Repository access**: Only select repositories → Tick your private repo
   - **Permissions**:
     - `Contents` → `Read and write`
     - `Metadata` → `Read-only`
4. Click **Generate token** and copy the token

### 2. Install Using the Token

```bash
# Via HTTPS with token
sudo TEAMTP_REPO=https://<YOUR_TOKEN>@github.com/yourname/TimyabSpeak.git bash install.sh

# Or set the env var separately
export TEAMTP_REPO=https://<YOUR_TOKEN>@github.com/yourname/TimyabSpeak.git
sudo bash install.sh
```

### 3. Install Using SSH Key

```bash
# Deploy your SSH key on the server first
ssh-copy-id user@your-server

# Then run with SSH repo URL
sudo TEAMTP_REPO=git@github.com:yourname/TimyabSpeak.git bash install.sh
```

### 4. Install from a Local Clone

```bash
git clone git@github.com:yourname/TimyabSpeak.git /opt/TimyabSpeak
cd /opt/TimyabSpeak
sudo bash install.sh
```

The installer auto-detects the cloned repo and pulls updates automatically.

---

## Installer Flow

The wizard goes through these phases:

```
Phase  0: Pre-flight — root check, OS check (glibc ≥ 2.32), disk space, port scanning
Phase  1: Wizard — domain/IP, SSL choice, server name, admin credentials, community name, slots
Phase  2: Dependencies — apt packages, Node.js 20.x, python3-bcrypt
Phase  3: System users — tsserver + teamtp (no login, no home)
Phase  4: Deploy files — git clone or local copy → /opt/teamtp/
Phase  5: Generate secrets — bcrypt password hash, API key, JWT secrets, query password
Phase  6: TS6 server — download, extract, write tsserver.yaml, systemd service, health check
Phase  7: Capture privilege key — auto-grep from logs
Phase  8: Install bots — npm install, systemd services for level/temp/support bots
Phase  9: Web panel — Express + Socket.IO + Helmet, systemd service
Phase 10: CLI — /usr/local/bin/teamtp
Phase 11: nginx + SSL — reverse proxy, certbot or self-signed
Phase 12: Firewall — UFW (voice, HTTP, HTTPS, SSH), fail2ban
Phase 13: Logrotate — /var/log/teamtp/
Phase 14: Summary — credential sheet
```

### Port Auto-Detection

| Service | Default | Fallback Range |
|---------|---------|----------------|
| Voice (UDP) | 9987 | +1 to +20 |
| File Transfer (TCP) | 30033 | +1 to +10 |
| SSH Query (TCP) | 10022 | +1 to +10 |
| HTTP Query / REST (TCP) | 10080 | +1 to +10 |
| Web Panel (TCP) | 3000 | +1 to +10 |
| HTTP (TCP) | 80 | +1 to +5 |
| HTTPS (TCP) | 443 | +1 to +5 |

---

## Channel Tree

```
📢 ═══ WELCOME ═══════════════════════════════
  📋 Info & Rules           [text, read-only]
  📢 Announcements          [text, read-only]
  🆕 Changelog              [text, read-only]
  💬 General Chat           [text]
  🤖 Bot Commands           [text]

🎮 ═══ GAME ZONE ══════════════════════════════
  🗣️ Game Lobby             [voice]
  ──────────────────────     [spacer]
  🔫 FPS Arena              [category]
    CS2 / Valorant / Apex    [voice]
  ⚔️ RPG Realm              [category]
    WoW / D4 / Elden Ring    [voice]
  🏎️ Racing Circuit         [category]
    Forza / AC / NFS         [voice]
  ♟️ Strategy Command       [category]
    LoL / Dota / SC2         [voice]
  🎲 Party Hub              [category]
    Among Us / Jackbox       [voice]
  ──────────────────────     [spacer]
  ⏳ Time Window             [category]    ← All temp channels created here
    🎫 ➕ Create Channel     [voice, trigger]
    🎮 PlayerOne's Room     [auto-created, auto-deleted]
    🎮 PlayerTwo's Room     [auto-created, auto-deleted]

🎵 ═══ SOCIAL ═════════════════════════════════
  🎤 Main Lounge            [voice]
  🎧 Music & Chill          [voice]
  🤫 Study & Focus          [voice, quiet zone]
  💤 AFK Zone               [voice, auto-move]

🆘 ═══ SUPPORT ════════════════════════════════
  📖 FAQ & Knowledge Base   [text, read-only]
  🎫 Create Ticket          [text, /new here]
  📋 Active Tickets         [category, join_power=50]
    🎫 username             [text, per-ticket, private]
  🔒 Archived Tickets       [category, join_power=100]

📊 ═══ STATISTICS ═════════════════════════════
  🏆 Leaderboard            [text, auto-updated]
  📈 My Stats               [text, /stats]
  🎯 Weekly Challenge       [text, auto-announce]
  📊 Server Status          [text, auto-updated]

🔒 ═══ STAFF ═════════════════════════════════ [join_power=100]
  👑 Admin Office           [voice, join_power=150]
  🛡️ Mod Room               [voice]
  💼 Staff Chat             [text]
  ⚙️ Server Control         [text]
  📝 Staff Logs             [text, audit]
```

---

## Role System

| Role | Color | Hex | XP Required | Permissions |
|------|-------|-----|-------------|-------------|
| 👑 Owner | Deep Red | `#E74C3C` | — | Absolute — snapshots, all permissions |
| 🔶 Admin | Orange | `#FF7F00` | — | Full control except snapshots |
| 🟡 Moderator | Gold | `#FFD700` | — | Kick, ban, manage channels, no server settings |
| 🟢 Support | Green | `#2ECC71` | — | Read all channels, handle tickets, no modify |
| 💎 Elite | Cyan | `#00BFFF` | 1000 XP | Priority speaker, 500MB upload |
| 🟣 Veteran | Purple | `#9B59B6` | 500 XP | 250MB upload |
| 🔵 Member | Sky Blue | `#3498DB` | 100 XP | Standard registered |
| ⚪ Guest | Grey | `#95A5A6` | 0 XP | Restricted — no file upload, no private channels |
| 🔘 Bot | Slate | `#607D8B` | — | ServerQuery only, no voice |

---

## XP System

| Action | XP | Rate Limit |
|--------|----|-----------|
| 10 minutes in voice | 10 | Every 10 min |
| Hourly voice bonus | 20 | Once per hour |
| First login of day | 15 | Daily |
| 3-day streak bonus | 25 | Daily |
| 7-day streak bonus | 50 | Daily |
| Create temp channel | 10 | Once per hour |
| Invite friend (joined) | 50 | Once per invite |
| Win weekly challenge | 100 | Weekly |

### Progression

| Level | Role | XP | Estimated Voice Time |
|-------|------|----|---------------------|
| 0 | ⚪ Guest | 0 | — |
| 1 | 🔵 Member | 100 | ~3 hours |
| 2 | 🔵 Member | 200 | ~6 hours |
| 3 | 🔵 Member | 350 | ~10 hours |
| 4 | 🟣 Veteran | 500 | ~15 hours |
| 5 | 🟣 Veteran | 650 | ~20 hours |
| 6 | 🟣 Veteran | 800 | ~25 hours |
| 7 | 💎 Elite | 1000 | ~30 hours |

### Achievements

| Achievement | Requirement | XP Bonus |
|-------------|-------------|----------|
| 🎤 First Words | Join any voice channel | 10 |
| 🦋 Social Butterfly | Visit 5 different channels | 25 |
| 🏠 Home Owner | Create your first temp channel | 30 |
| 🦉 Night Owl | Stay in voice 2+ hours | 50 |
| 🔄 Comeback Kid | 7-day login streak | 100 |
| 🏅 Veteran | Reach Veteran role | 200 |
| 🎉 Party Starter | Your temp channel had 5+ users | 50 |
| 🤝 Helper | Create 5 support tickets | 30 |
| 🏆 Voice Champion | 100 hours in voice | 150 |

---

## Temp Channel Bot — Commands

All commands are typed in your temporary voice channel's text chat.

| Command | Description | Required |
|---------|-------------|----------|
| `/name <text>` | Rename your channel | Owner |
| `/limit <N>` | Set max users (0=unlimited) | Owner |
| `/password <pw>` | Lock with password | Owner |
| `/password ""` | Remove password | Owner |
| `/public` | Anyone can join | Owner |
| `/private` | Invite-only mode | Owner |
| `/invite @user` | Invite someone to private channel | Owner |
| `/lock` | Only you can join (generates random password) | Owner |
| `/unlock` | Revert lock | Owner |
| `/kick @user` | Kick user from your channel | Owner |
| `/bitrate <N>` | Audio quality (8-512 kbps) | Owner |
| `/desc <text>` | Channel description | Owner |
| `/give @user` | Transfer ownership | Owner |
| `/claim` | Claim abandoned channel (60s after owner leaves) | Anyone |
| `/hide` | Move channel to hidden position | Owner |
| `/show` | Restore channel visibility | Owner |
| `/timeout <N>` | Auto-delete after N min idle | Owner |
| `/permanent` | Toggle permanent (never auto-delete) | Owner |
| `/delete` | Delete channel immediately | Owner |
| `/settings` | Show channel configuration | Owner |
| `/help` | Show all commands | Anyone |

### Auto-Delete Rules

| Condition | Permanent? | Action |
|-----------|-----------|--------|
| Channel empty for 30s | No | Delete |
| Channel empty for 30s | Yes | Keep |
| Owner disconnected > 60s | — | Anyone can `/claim` |
| Unclaimed for 5 min | — | Delete |
| Idle > timeout set by owner | — | Delete |

---

## Support Bot — Ticketing

### User Commands

| Command | Description |
|---------|-------------|
| `/new [subject]` | Create a new support ticket |
| `/close` | Close your own ticket |
| `/faq` | Show FAQ |
| `/faq <query>` | Search FAQ |
| `/mytickets` | List your open tickets |

### Staff Commands (in ticket channel)

| Command | Description |
|---------|-------------|
| `/claim` | Assign ticket to yourself |
| `/transfer @staff` | Reassign to another staff member |
| `/close [reason]` | Close ticket |
| `/resolve` | Mark as resolved + close |
| `/note <text>` | Private staff note (invisible to user) |
| `/alert` | Notify user if idle > 5 min |
| `/block @user [reason]` | Block user from creating tickets |
| `/idle` | Show idle time |
| `/log` | Show ticket transcript |

### Ticketing Flow

```
1. User types /new → bot DMs for description
2. Bot creates private text channel in Support → Active Tickets
3. Only ticket creator + Support+ roles can see/access it
4. Staff /claim → status changes to "claimed"
5. Conversation happens → all messages logged
6. /close → transcript saved to /opt/teamtp/tickets/{id}.log
7. Channel moved to 🔒 Archived Tickets, read-only
8. Auto-close: 48h inactivity, 72h max open
```

---

## Web Panel

Access via `http://localhost:3000` or `https://panel.your.domain`.

| Page | Route | Description |
|------|-------|-------------|
| Dashboard | `/dashboard` | Live server status, online count, XP leaderboard, ticket stats, temp channel count |
| Tickets | `/tickets` | Full ticket management — view, filter, reply, claim, close, resolve, add notes |
| Users | `/users` | Online user search, XP leaderboard (top 50), edit XP |
| Channels | `/channels` | Read-only channel tree with descriptions |
| Roles | `/roles` | Role list with colors, XP thresholds, current server groups |
| Bots | `/bots` | Status and controls for level, temp, support bots (start/stop/restart) |
| Settings | `/settings` | Server info display, SSL renew button |
| Backup | `/backup` | One-click backup creation, existing backups list |
| Logs | `/logs` | Last 100 lines of install and panel logs |

---

## CLI — `teamtp`

```bash
teamtp status              # Show all services status
teamtp restart             # Restart all services
teamtp panel [port]        # Show panel info
teamtp bot <name> <act>    # Control bots (level|temp|support, on|off|restart|status)
teamtp ssl                 # Renew Let's Encrypt certificates
teamtp backup              # Create backup (30-day retention)
teamtp update              # Pre-backup → git pull → npm ci → restart all
teamtp health              # Health check (exit 0 = OK, exit 1 = DOWN)
teamtp wipe                # DELETE everything — destructive, ask for confirmation
teamtp logs [svc] [lines]  # View journald logs (default: teamspeak6, 50 lines)
teamtp help                # Show usage
```

---

## Security

| Layer | Measure |
|-------|---------|
| Network | TS6 query interfaces bound to `127.0.0.1` only. UFW: allow only 9987/udp, 80/tcp, 443/tcp, SSH. |
| Firewall | `ufw default deny incoming`, fail2ban for SSH and nginx auth. |
| Credentials | `.env` chmod 600. Query password: 32-char random. API key: 64-char random. JWT: 15-min access + 7-day refresh tokens. |
| Authentication | Panel login rate-limited (5 attempts/min/IP). bcrypt password hashing. JWT with refresh rotation. |
| OS Users | `tsserver` runs TS6. `teamtp` runs bots + panel. Neither can log in. No service runs as root. |
| Permissions | Guest role: file upload/download/browse all denied (value=-1). Private channels denied. |
| Audit | All ticket actions logged. All permission changes logged by TS6. Weekly permission audit recommended. |
| Updates | `unattended-upgrades` for security patches. `teamtp update` for platform updates. Pre-update backup always. |
| SSL | TLS 1.2/1.3 only, strong ciphers, HSTS headers via nginx. |
| Bot | Private message rate limit: 50/user/10min. Command cooldown: 2s. Channel ownership verified server-side. |

---

## Backup & Restore

### Create Backup

```bash
# Via CLI
teamtp backup

# Creates: /opt/teamtp/backups/teamtp-{date}.tar.gz
# Includes: .env, config/, all SQLite databases
# Retention: 30 days auto-prune
```

### Via Web Panel

Dashboard → Backup → **Create Backup Now**

### Manual Backup

```bash
sudo /opt/teamtp/scripts/backup.sh
```

### Restore from Backup

```bash
sudo systemctl stop teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot
sudo tar -xzf /opt/teamtp/backups/teamtp-{date}.tar.gz -C /opt/teamtp/
sudo systemctl start teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot
```

---

## Update

```bash
# Full update (backup + pull + npm ci + restart)
teamtp update
```

This runs:
1. Pre-update backup
2. `git pull` (if git repo, otherwise skips)
3. `npm ci` (or `npm install` fallback) in all subdirectories
4. `systemctl daemon-reload`
5. Restart all bot + panel services

---

## Uninstall / Wipe

```bash
# Via CLI
teamtp wipe

# Or via install.sh
sudo bash /opt/teamtp/install.sh --wipe
```

Both methods:
1. Ask for confirmation (type **DELETE**)
2. Stop and disable all services
3. Remove systemd unit files
4. Remove nginx config
5. Delete `/opt/teamtp/`
6. Remove `/usr/local/bin/teamtp`
7. Remove log files and logrotate config
8. Leave all system packages and Node.js installation intact

---

## File Structure

```
/opt/teamtp/
├── .env                          # Secrets (chmod 600)
├── .installed                    # Marker file
├── config/
│   ├── roles.json                # 9 roles with colors, XP thresholds
│   ├── channels.json             # Channel tree template (23 channels)
│   ├── permissions.json          # Full permission matrix (9 groups × ~100 perms)
│   ├── xp-thresholds.json        # 7 levels, 8 XP sources, 9 achievements
│   ├── faq.json                  # 10 initial FAQ entries
│   └── welcome.txt               # Welcome message
├── shared/
│   ├── ts6-rest.js               # TS6 REST API client (40+ methods)
│   └── ticket-db.js              # Shared SQLite ticket store
├── bots/
│   ├── level-bot/
│   │   ├── index.js              # XP tracking, role assignment, streaks, leaderboard
│   │   └── data.sqlite           # User XP data
│   ├── temp-channel-bot/
│   │   ├── index.js              # 19 commands, full lifecycle management
│   │   └── temp-channels.sqlite  # Active temp channel records
│   └── support-bot/
│       ├── index.js              # Ticketing, FAQ, blocklist, transcripts
│       └── tickets.sqlite        # Ticket and message data
├── panel/
│   ├── server.js                 # Express + Socket.IO + JWT auth
│   ├── package.json
│   └── public/
│       ├── index.html            # Login + SPA shell
│       ├── style.css             # Dark theme, responsive
│       └── app.js                # Dashboard, tickets, users, bots, settings, backup, logs
├── scripts/
│   ├── ssl.sh                    # Certificate renewal
│   ├── security.sh               # Audit script
│   ├── backup.sh                 # Backup with 30-day retention
│   └── update.sh                 # Pre-backup → npm ci → restart
├── systemd/
│   ├── teamspeak6.service        # TS6 server
│   ├── teamtp-panel.service      # Web panel
│   ├── teamtp-level-bot.service  # Level-up bot
│   ├── teamtp-temp-bot.service   # Temp channel bot
│   └── teamtp-support-bot.service# Support bot
├── tickets/                      # Ticket transcripts
├── backups/                      # Backup archives
└── install.sh                    # One-command wizard
```

---

## Architecture

```
┌──────────────┐     ┌──────────────────────────────────────────┐
│  TS6 Clients │────▶│  TeamSpeak 6 Server                      │
│  (Players)   │     │  Ports: 9987/udp, 10022, 10080, 30033   │
└──────────────┘     └────────┬─────────────────────────────────┘
                              │ REST API (127.0.0.1:10080)
                              │
          ┌───────────────────┼────────────────────┐
          ▼                   ▼                    ▼
   ┌─────────────┐   ┌──────────────┐   ┌──────────────────┐
   │ Level Bot   │   │ Temp Channel │   │ Support Bot      │
   │ (XP/roles)  │   │ Bot (VC mgmt)│   │ (ticketing)      │
   └──────┬──────┘   └──────┬───────┘   └────────┬─────────┘
          │                 │                     │
          ▼                 ▼                     ▼
   ┌────────────────────────────────────────────────────────┐
   │  SQLite DBs                                             │
   │  (data.sqlite, temp-channels.sqlite, tickets.sqlite)    │
   └────────────────────────────────────────────────────────┘
          │
          ▼
   ┌────────────────────────────────────────────────────────┐
   │  Web Panel (Express + Socket.IO)                       │
   │  Port 3000 (← nginx proxy on port 80/443 if domain)    │
   │  JWT auth, Helmet security headers                     │
   └────────────────────────────────────────────────────────┘
          │
          ▼
   ┌────────────────────────────────────────────────────────┐
   │  teamtp CLI (/usr/local/bin/teamtp)                    │
   │  status, restart, bot, backup, update, wipe, health    │
   └────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

### TS6 Server Won't Start

```bash
journalctl -u teamspeak6 -n 50 --no-pager
```

Common causes:
- **glibc too old**: Need glibc ≥ 2.32 (Ubuntu 22.04+ / Debian 12+)
- **License expired**: TS6 beta license renews every 2 months. Update TS6 binary.
- **Port conflict**: Check `ss -tlnp | grep <port>`

### Bot Won't Connect to TS6

```bash
journalctl -u teamtp-level-bot -n 50 --no-pager
journalctl -u teamtp-temp-bot -n 50 --no-pager
journalctl -u teamtp-support-bot -n 50 --no-pager
```

Common causes:
- **API key mismatch**: Check `/opt/teamtp/.env` `TS6_API_KEY` is correct
- **TS6 not running**: Check `teamtp status`
- **HTTP query disabled**: Verify `tsserver.yaml` has `query.http.enable: 1`

### Web Panel Shows 502 Bad Gateway

```bash
systemctl status teamtp-panel --no-pager
journalctl -u nginx -n 20 --no-pager
```

Common causes:
- Panel not running: `systemctl restart teamtp-panel`
- nginx config: `nginx -t` to test
- Port mismatch: Check nginx proxy_pass matches `PANEL_PORT` in .env

### Lost Admin Access

If you lose the privilege key or admin access:

```bash
# Check logs for the key
journalctl -u teamspeak6 | grep token

# Or regenerate via SSH query:
# Connect to SSH query port with the admin password from .env
ssh serveradmin@127.0.0.1 -p 10022
# Then run: tokenadd tokentype=0 tokenid1=6 tokenid2=0
```

---

## FAQ

**Q: Can I use my own domain?**  
A: Yes. The wizard asks for a domain. If provided, Let's Encrypt SSL is auto-configured with nginx reverse proxy for the web panel.

**Q: What if I don't have a domain?**  
A: The wizard works with IP addresses. Self-signed SSL or no SSL options are available.

**Q: How do I change the server name after installation?**  
A: Via the web panel (Settings page) or by editing `tsserver.yaml` and restarting.

**Q: Can I add more game categories?**  
A: Yes. Edit `/opt/teamtp/config/channels.json` and apply via the TS6 REST API or manually through the TS6 client.

**Q: How do I add custom roles/permissions?**  
A: Edit `/opt/teamtp/config/permissions.json` and apply via the panel or ServerQuery. The permission matrix supports all TS6 permission types.

**Q: Is there a Docker version?**  
A: Not yet. The installer runs on bare metal Ubuntu/Debian. Docker support is planned.

**Q: How often should I update?**  
A: Run `teamtp update` every 2 months or when TS6 releases a new beta (the beta license expires every 2 months).

---

## License

MIT License. See [LICENSE](LICENSE) for details.

TeamSpeak is a trademark of TeamSpeak Systems GmbH. This project is not affiliated with or endorsed by TeamSpeak Systems.
