<div align="center">

# **JOJO BACKUPER**
### **Quick Install · by [@B_KHANEMAN](https://github.com/b-khaneman)**

</div>

```bash
cd /opt
sudo git clone https://github.com/b-khaneman/jojo-backuper.git
cd jojo-backuper/server-migration-manager
sudo ./install.sh
sudo ./migrate.sh
```

### Fast path

| Step | Action |
|:----:|:-------|
| **1** | Menu **`3`** — Create Full Server Backup |
| **2** | Menu **`1`** — Deploy to New Server |
| **3** | Menu **`2`** — Restore Backup (**sudo**) |
| **4** | Menu **`12`** — Post-Migration Health Check |

```bash
sudo ./migrate.sh backup
sudo ./migrate.sh deploy
sudo ./migrate.sh sudo-restore
```

Full guide (فارسی): **[README.md](./README.md)**

**Author: [@B_KHANEMAN](https://github.com/b-khaneman)**
