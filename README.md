<div align="center">

# **JOJO BACKUPER**
### **Server Migration Manager · v1.1**

**Enterprise Ubuntu VPS Cloning & Migration Toolkit**

<br/>

[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20%7C%2022.04%20%7C%2024.04-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/License-MIT-0B3D91?style=for-the-badge)](./LICENSE)
[![Version](https://img.shields.io/badge/Version-1.1.1-111111?style=for-the-badge)](./server-migration-manager/VERSION)

<br/>

**Author**

### **[@B_KHANEMAN](https://github.com/b-khaneman)**

`GitHub · b-khaneman` &nbsp;·&nbsp; `Telegram / ID · @B_KHANEMAN`

<br/>

> **از سرور قدیم بکاپ کامل بگیر · به سرور جدید بفرست · با یک دستور `sudo` ریستور کن**

<br/>

```text
┌──────────────────────────────────────────────┐
│   JOJO BACKUPER  ·  ONE-CLICK VPS MIGRATE   │
│                                              │
│   OLD SERVER  ──►  BACKUP  ──►  NEW SERVER   │
│         tar + zstd   ·   rsync   ·   sudo    │
└──────────────────────────────────────────────┘
```

</div>

---

<div align="center">

## **فهرست مطالب**

</div>

<br/>

| # | بخش | توضیح |
|--:|:----|:------|
| **01** | [معرفی](#intro) | JOJO BACKUPER چیست؟ |
| **02** | [ویژگی‌ها](#features) | قابلیت‌های اصلی |
| **03** | [پیش‌نیازها](#requirements) | سرور قدیم و جدید |
| **04** | [نصب سریع](#install) | ۳ دستور تا اجرا |
| **05** | [مراحل مهاجرت](#migrate) | مسیر پیشنهادی |
| **06** | [منوی برنامه](#menu) | همه گزینه‌ها |
| **07** | [دستورات CLI](#cli) | اجرای بدون منو |
| **08** | [تنظیمات](#config) | `config.conf` |
| **09** | [ریستور دستی](#manual-restore) | روی سرور جدید |
| **10** | [بعد از مهاجرت](#after) | چک‌لیست نهایی |
| **11** | [عیب‌یابی](#troubleshoot) | مشکلات رایج |
| **12** | [ساختار پروژه](#structure) | فایل‌ها و ماژول‌ها |
| **13** | [امنیت](#security) | هشدارهای مهم |
| **14** | [سازنده](#author) | **@B_KHANEMAN** |

---

<a id="intro"></a>

## **معرفی**

**JOJO BACKUPER** یک ابزار **حرفه‌ای Bash** برای **کلون و مهاجرت کامل VPS** است.

روی **سرور قدیم** اجرا می‌شود، بکاپ فشرده می‌سازد، به **سرور جدید** منتقل می‌کند،
اسکریپت‌ها را نصب می‌کند و در نهایت با **`sudo`** ریستور را انجام می‌دهد.

| | |
|:--|:--|
| **نام پروژه** | **JOJO BACKUPER** |
| **موتور** | Server Migration Manager **v1.1** |
| **پلتفرم** | **Ubuntu 20.04 / 22.04 / 24.04** |
| **سازنده** | **[@B_KHANEMAN](https://github.com/b-khaneman)** |

---

<a id="features"></a>

## **ویژگی‌ها**

| قابلیت | جزئیات |
|:-------|:-------|
| **Full Backup** | `/etc` `/home` `/root` `/opt` `/usr` `/var` `/srv` `/boot` |
| **Compression** | `tar` + **zstd** + progress (`pv`) |
| **Quick Deploy** | گرفتن مشخصات سرور جدید + آپلود + نصب خودکار |
| **Sudo Restore** | ریستور امن با دسترسی کامل root |
| **Databases** | MySQL / MariaDB / PostgreSQL / Redis / MongoDB |
| **Docker** | Images · Volumes · Networks · Compose |
| **Security** | SSH keys · fail2ban · AppArmor · sudoers |
| **Network** | Netplan · iptables · nftables · WireGuard |
| **Integrity** | **SHA256** checksum قبل از ریستور |
| **Notify** | Telegram / Webhook (اختیاری) |

---

<a id="requirements"></a>

## **پیش‌نیازها**

### **سرور قدیم (منبع)**

- **Ubuntu** 20.04 / 22.04 / 24.04  
- دسترسی **root** (`sudo`)  
- فضای دیسک کافی برای بکاپ فشرده  
- امکان **SSH** به سرور جدید  

### **سرور جدید (مقصد)**

- Ubuntu هم‌نسخه یا نزدیک (پیشنهادی)  
- دسترسی **SSH** (ترجیحاً `root`)  
- فضای دیسک **≥** سرور قدیم  

---

<a id="install"></a>

## **نصب سریع**

<div align="center">

### **۳ دستور · آماده‌ی کار**

</div>

```bash
cd /opt
sudo git clone https://github.com/b-khaneman/jojo-backuper.git
cd jojo-backuper/server-migration-manager
sudo ./install.sh && sudo ./migrate.sh
```

> بعد از نصب می‌توانید با دستور **`sudo smm`** هم وارد منو شوید.

<details>
<summary><b>روش‌های دیگر نصب</b></summary>

<br/>

**دانلود ZIP**

1. از صفحه GitHub گزینه **Code → Download ZIP**  
2. به سرور قدیم منتقل کنید و از حالت فشرده خارج کنید  
3. سپس:

```bash
cd server-migration-manager
sudo chmod +x install.sh migrate.sh restore-agent.sh
sudo ./install.sh
sudo ./migrate.sh
```

</details>

---

<a id="migrate"></a>

## **مراحل مهاجرت**

<div align="center">

### **مسیر طلایی JOJO BACKUPER**

</div>

| مرحله | کار | گزینه منو |
|:----:|:----|:----------|
| **۱** | ساخت بکاپ کامل از سرور قدیم | **`3` Create Full Server Backup** |
| **۲** | ارسال بکاپ + نصب ابزار روی سرور جدید | **`1` Deploy to New Server** |
| **۳** | ریستور با sudo روی سرور جدید | **`2` Restore Backup (sudo)** |
| **۴** | بررسی سلامت بعد از مهاجرت | **`12` Post-Migration Health Check** |

```text
  [ OLD ] --backup--> [ ARCHIVE.tar.zst ]
                          |
                       deploy
                          |
                          v
  [ NEW ] <--sudo restore-- [ /opt/jojo-backup ]
```

---

<a id="menu"></a>

## **منوی برنامه**

```text
════════════════════════════════════════
   JOJO BACKUPER  ·  SMM v1.1
   by @B_KHANEMAN
════════════════════════════════════════

─── Quick Migration ───
 1) Deploy to New Server
 2) Restore Backup (sudo)

─── Backup & Tools ───
 3) Create Full Server Backup
 4) Connect To New Server
 5) Upload Backup Only
 6) Verify Backup
 7) Show Backup Information
 8) Cleanup Backup Files
 9) Pre-flight Check
10) Estimate Backup Size
11) Full Migration Wizard
12) Post-Migration Health Check
13) Generate Migration Report
14) Schedule Weekly Backup
15) Test Notifications
16) Exit
```

---

<a id="cli"></a>

## **دستورات CLI**

```bash
sudo ./migrate.sh backup          # بکاپ کامل
sudo ./migrate.sh deploy          # مشخصات + آپلود + نصب
sudo ./migrate.sh sudo-restore    # ریستور با sudo
sudo ./migrate.sh preflight       # چک قبل از کار
sudo ./migrate.sh estimate        # تخمین حجم
sudo ./migrate.sh wizard          # ویزارد کامل
sudo ./migrate.sh postcheck       # بررسی بعد از مهاجرت
```

---

<a id="config"></a>

## **تنظیمات**

فایل: `server-migration-manager/config.conf`

| متغیر | معنی | نمونه |
|:------|:-----|:------|
| **`BACKUP_DIR`** | مسیر بکاپ محلی | `./backups` |
| **`REMOTE_PATH`** | مسیر روی سرور جدید | `/backup` |
| **`KEEP_BACKUPS`** | تعداد بکاپ‌های نگه‌داشته | `3` |
| **`BANDWIDTH_LIMIT_KB`** | محدودیت سرعت آپلود | `8192` |
| **`ENCRYPT_BACKUP`** | رمزنگاری بکاپ | `yes` / `no` |
| **`NOTIFY_ENABLED`** | نوتیفیکیشن | `yes` / `no` |
| **`REBOOT_AFTER_RESTORE`** | ریبوت بعد از ریستور | `yes` |

---

<a id="manual-restore"></a>

## **ریستور دستی**

اگر Deploy انجام شده باشد، روی سرور جدید:

```bash
sudo /opt/jojo-backup/restore-agent.sh \
  --archive /backup/server-backup-TIMESTAMP.tar.zst \
  --yes \
  --reboot=yes
```

---

<a id="after"></a>

## **بعد از مهاجرت**

1. **DNS** یا Floating IP را به سرور جدید بدهید  
2. اگر نام NIC فرق دارد، **`/etc/netplan`** را بررسی کنید  
3. تانل‌ها: `/root/smm-tunnel-hints/`  
4. Compose: `/opt/smm-compose/`  
5. وجود **`/etc/smm-restore-complete`** یعنی ریستور تمام شده  

---

<a id="troubleshoot"></a>

## **عیب‌یابی**

| مشکل | راه‌حل |
|:-----|:------|
| **Permission denied** | همه دستورات را با **`sudo`** اجرا کنید |
| **SSH fail** | پورت، فایروال، کلید/پسورد را چک کنید |
| **آپلود قطع شد** | دوباره گزینه **`1` Deploy** — rsync ادامه می‌دهد |
| **کمبود فضا** | گزینه **`10` Estimate** + پاکسازی دیسک |
| **ریستور fail** | لاگ: `/var/log/server-migration/restore.log` |

---

<a id="structure"></a>

## **ساختار پروژه**

```text
jojo-backuper/
├── README.md                          ← شما اینجا هستید
├── INSTALL.md
├── LICENSE
└── server-migration-manager/
    ├── migrate.sh                     ← منوی اصلی
    ├── restore-agent.sh               ← عامل ریستور
    ├── install.sh                     ← نصب وابستگی‌ها
    ├── config.conf
    ├── modules/                       ← backup · restore · docker · …
    ├── backups/
    └── logs/
```

---

<a id="security"></a>

## **امنیت**

> **هشدار:** ریستور، فایل‌سیستم سرور جدید را بازنویسی می‌کند.

- قبل از ریستور از سرور جدید **Snapshot** بگیرید  
- بکاپ شامل **secret**هاست — امن نگه دارید  
- پسورد و کلید را در چت عمومی نفرستید  

---

<a id="author"></a>

<div align="center">

## **سازنده**

# **[@B_KHANEMAN](https://github.com/b-khaneman)**

**JOJO BACKUPER** ساخته شده توسط **@B_KHANEMAN**  
برای مهاجرت **سریع · امن · حرفه‌ای** سرورهای Ubuntu

<br/>

[![GitHub](https://img.shields.io/badge/GitHub-b--khaneman-181717?style=for-the-badge&logo=github)](https://github.com/b-khaneman)
[![Repo](https://img.shields.io/badge/Repo-jojo--backuper-0B3D91?style=for-the-badge&logo=github)](https://github.com/b-khaneman/jojo-backuper)

<br/>

### **Version**

**JOJO BACKUPER v1.1.1** · by **[@B_KHANEMAN](https://github.com/b-khaneman)**

**© 2026 JOJO BACKUPER · MIT License · @B_KHANEMAN**

</div>
