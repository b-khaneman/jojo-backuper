# JOJO BACKUP — Quick Install (English)

```bash
cd /opt
sudo git clone https://github.com/b-khaneman/jojo-backup.git
cd jojo-backup/server-migration-manager
sudo ./install.sh
sudo ./migrate.sh
```

### Fast migration path

1. Menu **3** — Create Full Server Backup (on OLD server)  
2. Menu **1** — Deploy to New Server (asks details, uploads backups, installs toolkit with sudo)  
3. Menu **2** — Restore Backup (sudo) on NEW server  
4. Menu **12** — Post-Migration Health Check  

CLI:

```bash
sudo ./migrate.sh backup
sudo ./migrate.sh deploy
sudo ./migrate.sh sudo-restore
```

Full Persian guide: see root [README.md](./README.md)
