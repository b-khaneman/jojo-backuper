# JOJO BACKUP
### SERVER MIGRATION MANAGER v1.1

ابزار حرفه‌ای **کلون و مهاجرت کامل سرور (VPS)** برای Ubuntu  
پشتیبانی: **20.04 / 22.04 / 24.04**

با این ابزار می‌توانید از سرور قدیم بکاپ کامل بگیرید، به سرور جدید منتقل کنید و با یک دستور `sudo` ریستور کنید.

---

## فهرست

1. [پیش‌نیازها](#پیش‌نیازها)
2. [نصب روی سرور قدیم](#نصب-روی-سرور-قدیم)
3. [مراحل مهاجرت (پیشنهادی)](#مراحل-مهاجرت-پیشنهادی)
4. [توضیح منو](#توضیح-منو)
5. [دستورات CLI](#دستورات-cli)
6. [تنظیمات](#تنظیمات-configconf)
7. [ریستور دستی روی سرور جدید](#ریستور-دستی-روی-سرور-جدید)
8. [بعد از مهاجرت](#بعد-از-مهاجرت)
9. [عیب‌یابی](#عیب‌یابی)
10. [ساختار پروژه](#ساختار-پروژه)

---

## پیش‌نیازها

### سرور قدیم (منبع)
- Ubuntu 20.04 / 22.04 / 24.04
- دسترسی **root** (`sudo`)
- فضای دیسک کافی برای بکاپ فشرده
- امکان اتصال SSH به سرور جدید

### سرور جدید (مقصد)
- Ubuntu هم‌نسخه یا نزدیک به سرور قدیم (پیشنهادی)
- دسترسی SSH (ترجیحاً کاربر `root`)
- فضای دیسک بیشتر یا مساوی سرور قدیم

---

## نصب روی سرور قدیم

### روش ۱ — کلون از GitHub (پیشنهادی)

```bash
# روی سرور قدیم
cd /opt
sudo git clone https://github.com/b-khaneman/jojo-backup.git
cd jojo-backup/server-migration-manager
sudo chmod +x install.sh migrate.sh restore-agent.sh
sudo ./install.sh
```

پس از نصب:

```bash
sudo ./migrate.sh
# یا
sudo smm
```

### روش ۲ — دانلود ZIP

1. از صفحه ریپو روی GitHub گزینه **Code → Download ZIP** را بزنید  
2. فایل را به سرور قدیم منتقل کنید  
3. از حالت فشرده خارج کنید و مثل بالا `install.sh` را اجرا کنید:

```bash
cd server-migration-manager
sudo chmod +x install.sh migrate.sh restore-agent.sh
sudo ./install.sh
sudo ./migrate.sh
```

### روش ۳ — کپی مستقیم

اگر پوشه پروژه را دارید:

```bash
scp -r "JOJO BACKUP" root@OLD_SERVER_IP:/opt/jojo-backup-src
ssh root@OLD_SERVER_IP
cd /opt/jojo-backup-src/server-migration-manager
sudo ./install.sh
sudo ./migrate.sh
```

`install.sh` این‌ها را نصب می‌کند: `zstd`, `rsync`, `pv`, `sshpass`, `curl`, و سایر وابستگی‌ها. همچنین لینک `smm` را در `/usr/local/bin` می‌سازد.

---

## مراحل مهاجرت (پیشنهادی)

جریان سریع و امن:

| مرحله | کار | گزینه منو |
|------:|----|----------|
| ۱ | بکاپ کامل از سرور قدیم | **3) Create Full Server Backup** |
| ۲ | ارسال بکاپ + نصب ابزار روی سرور جدید | **1) Deploy to New Server** |
| ۳ | ریستور با sudo روی سرور جدید | **2) Restore Backup (sudo)** |
| ۴ | بررسی سلامت بعد از مهاجرت | **12) Post-Migration Health Check** |

### جزئیات هر مرحله

#### مرحله ۱ — بکاپ
روی سرور قدیم:

```bash
sudo ./migrate.sh
# گزینه 3 را بزنید
```

خروجی در مسیر:

```text
./backups/server-backup-TIMESTAMP.tar.zst
./backups/server-backup-TIMESTAMP.tar.zst.sha256
./backups/server-backup-TIMESTAMP.tar.zst.manifest
```

#### مرحله ۲ — Deploy به سرور جدید
گزینه **1** را بزنید. از شما می‌پرسد:

- IP / hostname سرور جدید  
- پورت SSH (پیش‌فرض `22`)  
- Username (معمولاً `root`)  
- احراز هویت: کلید خصوصی یا پسورد  

سپس به‌صورت خودکار:

1. همه بکاپ‌ها را با `rsync` آپلود می‌کند  
2. کل اسکریپت‌های JOJO BACKUP را می‌فرستد  
3. در مسیر `/opt/jojo-backup` روی سرور جدید با **sudo** نصب می‌کند  

#### مرحله ۳ — Restore با sudo
گزینه **2** را بزنید:

- هشدار overwrite نشان داده می‌شود  
- باید دقیقاً `YES` تایپ کنید  
- ریستور با `sudo` روی سرور جدید اجرا می‌شود  
- در پایان می‌تواند سرور جدید را ریبوت کند  

#### مرحله ۴ — تأیید
بعد از بالا آمدن سرور جدید، گزینه **12** یا:

```bash
sudo ./migrate.sh postcheck
```

---

## توضیح منو

```text
─── Quick Migration ───
 1) Deploy to New Server     ← مشخصات + آپلود بکاپ + نصب اسکریپت
 2) Restore Backup (sudo)    ← ریستور امن با sudo

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

## دستورات CLI

```bash
# بکاپ
sudo ./migrate.sh backup

# ارسال و نصب روی سرور جدید
sudo ./migrate.sh deploy

# ریستور با sudo
sudo ./migrate.sh sudo-restore

# بررسی قبل از کار
sudo ./migrate.sh preflight

# تخمین حجم
sudo ./migrate.sh estimate

# ویزارد کامل (همه‌چیز پشت سر هم)
sudo ./migrate.sh wizard

# بررسی بعد از مهاجرت
sudo ./migrate.sh postcheck
```

---

## تنظیمات (`config.conf`)

فایل مهم: `server-migration-manager/config.conf`

| متغیر | معنی | مثال |
|--------|------|------|
| `BACKUP_DIR` | مسیر ذخیره بکاپ | `./backups` |
| `REMOTE_PATH` | مسیر روی سرور جدید | `/backup` |
| `KEEP_BACKUPS` | تعداد بکاپ‌های نگه‌داشته‌شده | `3` |
| `BANDWIDTH_LIMIT_KB` | محدودیت سرعت آپلود | `8192` |
| `ENCRYPT_BACKUP` | رمزنگاری بکاپ | `yes` / `no` |
| `ENCRYPT_PASSPHRASE` | پسورد رمزنگاری | `...` |
| `NOTIFY_ENABLED` | نوتیفیکیشن | `yes` / `no` |
| `NOTIFY_TELEGRAM_BOT_TOKEN` | توکن ربات تلگرام | |
| `NOTIFY_TELEGRAM_CHAT_ID` | چت آیدی | |
| `REBOOT_AFTER_RESTORE` | ریبوت بعد از ریستور | `yes` |
| `PRESERVE_NEW_SSH_HOST_KEYS` | نگه داشتن SSH host key سرور جدید | `yes` |

---

## ریستور دستی روی سرور جدید

اگر Deploy انجام شده باشد، روی خود سرور جدید هم می‌توانید:

```bash
sudo /opt/jojo-backup/restore-agent.sh \
  --archive /backup/server-backup-TIMESTAMP.tar.zst \
  --yes \
  --reboot=yes
```

---

## چه چیزهایی بکاپ می‌شود؟

- فایل‌سیستم: `/etc` `/home` `/root` `/opt` `/usr` `/var` `/srv` `/boot`
- شبکه، فایروال (iptables/nftables)، SSL، WireGuard و تانل‌ها
- دیتابیس: MySQL/MariaDB، PostgreSQL، Redis، MongoDB
- Docker: image / volume / network / compose
- امنیت: SSH keys، fail2ban، AppArmor، sudoers
- وب: nginx / apache / php
- میل: postfix / dovecot

**حذف‌شده از بکاپ:** `/proc` `/sys` `/dev` `/run` `/tmp` `/mnt` `/media` و مشابه

---

## بعد از مهاجرت

1. DNS یا Floating IP را به سرور جدید بدهید  
2. اگر نام کارت شبکه فرق دارد، `/etc/netplan` را بررسی کنید  
3. تانل‌های GRE/VXLAN را در `/root/smm-tunnel-hints/` چک کنید  
4. فایل‌های compose در `/opt/smm-compose/` قرار می‌گیرند  
5. وجود فایل `/etc/smm-restore-complete` یعنی ریستور تمام شده  

---

## عیب‌یابی

| مشکل | راه‌حل |
|------|--------|
| خطای permission | همه دستورات را با `sudo` اجرا کنید |
| SSH وصل نمی‌شود | پورت، فایروال، و کلید/پسورد را چک کنید |
| آپلود قطع شد | دوباره گزینه **1 (Deploy)** را بزنید — `rsync` ادامه می‌دهد |
| کمبود فضا | گزینه **10 (Estimate)** و پاکسازی دیسک |
| ریستور fail شد | لاگ: `/var/log/server-migration/restore.log` روی سرور جدید |
| بعد از ریبوت SSH نمی‌آید | کنسول VPS را چک کنید؛ netplan/NIC را اصلاح کنید |

لاگ‌های محلی:

```text
./logs/
/var/log/server-migration/
```

---

## ساختار پروژه

```text
JOJO BACKUP/
└── server-migration-manager/
    ├── migrate.sh              # منوی اصلی (روی سرور قدیم)
    ├── restore-agent.sh        # عامل ریستور (روی سرور جدید)
    ├── install.sh              # نصب وابستگی‌ها
    ├── config.conf
    ├── modules/                # backup, restore, network, ...
    ├── backups/
    └── logs/
```

---

## هشدار امنیتی

- ریستور فایل‌سیستم سرور جدید را **بازنویسی** می‌کند  
- قبل از ریستور حتماً از سرور جدید snapshot بگیرید (اگر ارائه‌دهنده دارد)  
- پسوردها و کلیدها را در چت عمومی نفرستید  
- بکاپ شامل secretها (کلید SSL، `.env`، shadow و ...) است — امن نگه دارید  

---

## لایسنس

استفاده آزاد برای مهاجرت سرورهای خودتان. قبل از محیط production روی یک VPS تست امتحان کنید.

---

**JOJO BACKUP** · ساخته‌شده برای مهاجرت سریع، امن و قابل اعتماد سرور  
GitHub: https://github.com/b-khaneman/jojo-backup
