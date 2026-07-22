# **JOJO BACKUPER**
## Server Migration Manager v1.1

> Full guide: [README.md](../README.md) · Author: **[@B_KHANEMAN](https://github.com/b-khaneman)**

**GitHub:** https://github.com/b-khaneman/jojo-backuper

```bash
cd /opt
sudo git clone https://github.com/b-khaneman/jojo-backuper.git
cd jojo-backuper/server-migration-manager
sudo ./install.sh
sudo ./migrate.sh
```

### Fast path

| Step | Menu |
|------|------|
| 1. Backup | **3) Create Full Server Backup** |
| 2. Deploy | **1) Deploy to New Server** |
| 3. Restore | **2) Restore Backup (sudo)** |
| 4. Check | **12) Post-Migration Health Check** |

---

### What’s new in v1.1

| Feature | Description |
|---------|-------------|
| Pre-flight | Ubuntu check, deps, disk, DNS, remote arch match |
| Lock + traps | Prevents concurrent runs; cleans up on Ctrl+C |
| Security | SSH keys, fail2ban, AppArmor, sudoers, PAM |
| Web | nginx / apache / php / caddy configs |
| Mail | postfix / dovecot / opendkim |
| Packages | APT sources + dpkg selections restore |
| Encryption | GPG or OpenSSL AES-256 |
| Split archives | Optional chunking for huge backups |
| Bandwidth limit | `BANDWIDTH_LIMIT_KB` for rsync |
| Notifications | Telegram + Discord/Slack webhook |
| Restore-point | Snapshot of new server configs before overwrite |
| cloud-init clean | Stops provider from rewriting network/hostname |
| Post-check | Ports, HTTP URLs, systemd, services |
| Scheduler | systemd timer or cron |
| Dry-run | `DRY_RUN=yes` estimates only |
| `/boot` | Included in filesystem backup |
| Wizard | One-shot full migration |

---

### Backup coverage

Filesystem: `/etc` `/home` `/root` `/opt` `/usr` `/var` `/srv` `/boot`  
(+ metadata, network, firewall, DBs, Docker, SSL, tunnels, security, web, mail, packages)

Archive: `server-backup-TIMESTAMP.tar.zst` + `.sha256` + `.manifest`

---

### Important `config.conf` knobs

```bash
ENCRYPT_BACKUP="no"          # yes + ENCRYPT_PASSPHRASE or ENCRYPT_GPG_RECIPIENT
BANDWIDTH_LIMIT_KB="0"       # e.g. 8192
SPLIT_SIZE_MB="0"            # e.g. 2048
NOTIFY_ENABLED="no"
NOTIFY_TELEGRAM_BOT_TOKEN=""
NOTIFY_TELEGRAM_CHAT_ID=""
NOTIFY_WEBHOOK_URL=""
PRESERVE_NEW_SSH_HOST_KEYS="yes"
CLEAN_CLOUD_INIT="yes"
POSTCHECK_HTTP_URLS=""       # e.g. https://example.com
DRY_RUN="no"
KEEP_BACKUPS="3"
```

---

### CLI

```bash
sudo ./migrate.sh backup
sudo ./migrate.sh preflight
sudo ./migrate.sh wizard
sudo ./migrate.sh postcheck
sudo ./migrate.sh schedule
sudo ./migrate.sh notify-test
```

---

### New server agent

```bash
sudo ./restore-agent.sh --archive /backup/server-backup-XXXX.tar.zst --yes --reboot=yes
```

---

### After migration

1. Point DNS / floating IP to the new VPS  
2. Review `/etc/netplan` if NIC names differ  
3. Check `/root/smm-tunnel-hints/` for GRE/VXLAN  
4. Compose files under `/opt/smm-compose/`  
5. Confirm `/etc/smm-restore-complete` and run post-check  

---

**JOJO BACKUP** · SERVER MIGRATION MANAGER v1.1
