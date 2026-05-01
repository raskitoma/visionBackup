# visionBackup — Automated Database Backup Suite

A robust, automated MySQL/MariaDB backup system for Debian-based Linux servers. Manages multiple database sources, compresses backups, schedules cron jobs, and provides centralized logging — all through an interactive terminal UI.

---

## 📋 Requirements

### System
- **OS:** Debian-based Linux (Ubuntu, Debian, etc.)
- **Shell:** Bash 4.0+

### Dependencies

| Package | Purpose | Install |
|---------|---------|---------|
| `mysql-client` / `mariadb-client` | `mysqldump` for database exports | `sudo apt install mariadb-client` |
| `tar` | Compression of `.sql` dumps | Pre-installed on most systems |
| `cron` | Scheduling automated backups | `sudo apt install cron` |
| `grep`, `sed`, `awk` | Text processing | Pre-installed on most systems |

#### Install all dependencies at once:
```bash
sudo apt update && sudo apt install -y mariadb-client cron
```

> **Note:** The `pv` package is **not required** but could be installed for enhanced piped progress visualization in future versions:
> ```bash
> sudo apt install -y pv
> ```

---

## 🚀 Quick Start

### 1. Clone / Copy files
```bash
# Place all files in your preferred directory
mkdir -p /opt/visionBackup
cp deploy.sh visionBackup.sh .env.sample /opt/visionBackup/
cd /opt/visionBackup
```

### 2. Make scripts executable
```bash
chmod +x deploy.sh visionBackup.sh
```

### 3. Launch the manager
```bash
./deploy.sh
```

This opens the interactive management console where you can:
- Add/remove database sources
- Set the backup target directory
- Schedule daily cron jobs
- View error logs

### 4. Run a manual backup
```bash
./visionBackup.sh          # Interactive mode (choose sources)
./visionBackup.sh --auto   # Silent mode (all sources, for cron)
```

---

## 📁 File Structure

```
/opt/visionBackup/            ← Script home directory
├── deploy.sh                 ← Management & setup script
├── visionBackup.sh           ← Backup execution engine
├── .env                      ← Configuration (auto-generated)
├── .env.sample               ← Configuration reference
├── logs/
│   └── visionBackup.log      ← Centralized event log
└── README.md

/your/target/path/            ← User-defined TARGET_PATH
└── visionBackup/
    ├── production/
    │   ├── production_20260501_manual.tar.gz
    │   └── production_20260502.tar.gz
    └── staging/
        └── staging_20260501_manual.tar.gz
```

---

## ⚙️ Configuration

### `.env` Format

```bash
SOURCE_DBS="user:pass@host:port/db|description,user:pass@host:port/db|description"
TARGET_PATH="/backups"
```

### Source Block Structure

```
user:password@host:port/database|description
│     │        │    │    │         │
│     │        │    │    │         └─ Human-readable label (used for folders/filenames)
│     │        │    │    └─────────── Database name
│     │        │    └──────────────── MySQL port
│     │        └───────────────────── Hostname or IP
│     └────────────────────────────── Password
└──────────────────────────────────── Username
```

**Example:**
```bash
SOURCE_DBS="root:s3cret@localhost:3306/app_prod|production,admin:pw@10.0.0.5:3306/staging_db|staging"
```

> ⚠️ **Limitation:** Passwords must **not** contain the `@` character, as it is used as a delimiter in the connection string.

---

## 📝 Backup Naming Convention

| Mode | Filename Pattern |
|------|-----------------|
| **Interactive (manual)** | `<description>_YYYYMMDD_manual.tar.gz` |
| **Auto (cron)** | `<description>_YYYYMMDD.tar.gz` |

Each `.tar.gz` contains a single `.sql` file from `mysqldump`.

---

## ⏰ Cron Integration

The `deploy.sh` script manages cron entries tagged with `# visionBackup-auto`.

- **Only visionBackup entries are modified** — existing cron jobs are never touched.
- You specify just the hour (e.g., `03` for 3:00 AM daily).
- Remove the schedule by entering `r` at the hour prompt.

### Manual cron entry (if preferred):
```bash
# Run at 2 AM daily
0 2 * * * /usr/bin/env bash /opt/visionBackup/visionBackup.sh --auto # visionBackup-auto
```

---

## 📊 Logging

All events are logged to `logs/visionBackup.log` in the script directory.

### Log Format
```
[2026-05-01 03:00:05] [INFO] [system] Auto backup started
[2026-05-01 03:00:12] [SUCCESS] [production] Backup completed: /backups/visionBackup/production/production_20260501.tar.gz (45M)
[2026-05-01 03:00:15] [FAIL] [staging] mysqldump failed (exit 2): Access denied for user 'admin'@'10.0.0.5'
[2026-05-01 03:00:15] [INFO] [system] Auto backup finished: 1 succeeded, 1 failed
```

### View last error from deploy.sh:
Select option `6` from the main menu to see the most recent `[FAIL]` entry.

---

## 🔧 deploy.sh Menu Reference

```
╔══════════════════════════════════════════════╗
║         visionBackup · Deploy Manager        ║
╚══════════════════════════════════════════════╝

  Sources: 2   Target: /backups

  Source Management
    1) Add source
    2) Remove source
    3) List sources

  Configuration
    4) Set target path
    5) Schedule cron job

  Diagnostics
    6) Show last error
    7) Run backup now

    8) Factory reset
    0) Exit
```

| Option | Description |
|--------|-------------|
| **1** | Interactively add a new database source |
| **2** | Select and remove a configured source |
| **3** | List all sources with last successful backup timestamp |
| **4** | Browse directories or type a path to set `TARGET_PATH` |
| **5** | Set the daily backup hour or remove the cron schedule |
| **6** | Display the latest `[FAIL]` log entry |
| **7** | Launch `visionBackup.sh` in interactive mode |
| **8** | Wipe all config, logs, and cron entries (keeps backup files) |

---

## 🏭 Factory Reset

Option `8` in `deploy.sh` will:
- ✅ Delete `.env` configuration
- ✅ Delete all log files
- ✅ Remove visionBackup cron entries
- ❌ Does **not** delete existing backup archives

Requires typing `RESET` to confirm.

---

## 🛡️ Security Notes

- The `.env` file contains database credentials in plaintext. Restrict access:
  ```bash
  chmod 600 .env
  ```
- Consider running the scripts under a dedicated service user.
- Backup files should be stored on a volume with appropriate access controls.

---

## 🐞 Troubleshooting

| Problem | Solution |
|---------|----------|
| `mysqldump: command not found` | Install: `sudo apt install mariadb-client` |
| `Access denied for user` | Verify credentials in `.env` or via `deploy.sh` |
| Cron job not running | Check `sudo systemctl status cron` and verify with `crontab -l` |
| Empty backup file | Check disk space and MySQL server availability |
| Permission denied on target | Ensure the running user has write access to `TARGET_PATH` |

---

## 📜 License

Internal use. Modify and distribute as needed.
