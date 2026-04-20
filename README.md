# 🛡️ VPS Hardener

**Secure a fresh Ubuntu/Debian VPS in one command.**

Most developers buy a VPS, deploy their app, and forget about security. This script fixes that in under 2 minutes.

```bash
curl -sL https://raw.githubusercontent.com/Koi725/vps-hardener/main/harden.sh | sudo bash
```

---

## What It Does

| Step | Action                | Why It Matters                             |
| ---- | --------------------- | ------------------------------------------ |
| 1    | System updates        | Patches known vulnerabilities              |
| 2    | Essential packages    | Installs security tools                    |
| 3    | Non-root user         | Eliminates root login attack surface       |
| 4    | SSH hardening         | Custom port, key-only auth, rate limits    |
| 5    | UFW firewall          | Blocks everything except what you need     |
| 6    | Fail2ban              | Auto-bans brute force attempts             |
| 7    | Auto security updates | Daily checks, no manual patching           |
| 8    | Kernel hardening      | SYN flood protection, ASLR, ICMP hardening |
| 9    | Disable junk services | Removes avahi, cups, bluetooth, etc.       |
| 10   | Audit logging         | Tracks changes to critical system files    |

---

## Quick Start

**Option 1: One-liner (for the brave)**

```bash
curl -sL https://raw.githubusercontent.com/Koi725/vps-hardener/main/harden.sh | sudo bash
```

**Option 2: Clone and customize**

```bash
git clone https://github.com/Koi725/vps-hardener.git
cd vps-hardener
sudo bash harden.sh --port=2222 --user=deployer
```

**Option 3: Dry run first (recommended)**

```bash
sudo bash harden.sh --dry-run
```

---

## Options

```
Usage: sudo bash harden.sh [OPTIONS]

Options:
  --dry-run       Show what would be done without making changes
  --undo          Reverse hardening (restore backups)
  --port=NUMBER   Set SSH port (default: 2222)
  --user=NAME     Set non-root username (default: deployer)
  -h, --help      Show help
```

You can also set defaults via environment variables:

```bash
export VPS_SSH_PORT=2200
export VPS_USER=myuser
sudo -E bash harden.sh
```

---

## After Running

**⚠️ CRITICAL: Before closing your current session, open a NEW terminal and verify SSH access:**

```bash
ssh -p 2222 deployer@your-server-ip
```

If it works, you're good. If not, use your current session to fix the config.

**What changed:**

- SSH now runs on port `2222` (configurable)
- Root login is disabled
- Password auth is disabled (key-only)
- Firewall allows only SSH, HTTP (80), HTTPS (443)
- Fail2ban bans IPs after 3 failed SSH attempts
- Security updates install automatically

---

## Undo Everything

Made a mistake? Restore all original configs:

```bash
sudo bash harden.sh --undo
```

Backups are stored in `/root/.vps-hardener-backup/`.

---

## What It Does NOT Do

- ❌ Set up Nginx/Apache
- ❌ Install Docker
- ❌ Configure SSL certificates
- ❌ Manage application deployments
- ❌ Replace a proper security audit

This tool handles **OS-level hardening**. Your application security is your responsibility.

---

## Compatibility

| OS               | Status          |
| ---------------- | --------------- |
| Ubuntu 22.04 LTS | ✅ Tested        |
| Ubuntu 24.04 LTS | ✅ Tested        |
| Debian 11        | ✅ Tested        |
| Debian 12        | ✅ Tested        |
| CentOS/RHEL      | ❌ Not supported |

---

## Security Checklist

After running this script, your server has:

- [x] All packages updated to latest versions
- [x] Non-root sudo user with SSH key access
- [x] SSH on non-standard port with key-only auth
- [x] Firewall blocking all unused ports
- [x] Brute-force protection via fail2ban
- [x] Automatic daily security updates
- [x] Kernel-level network hardening
- [x] SYN flood protection enabled
- [x] ICMP broadcast protection
- [x] Address Space Layout Randomization (ASLR)
- [x] Unnecessary services disabled
- [x] Audit logging on critical system files
- [x] Log rotation configured

---

## Contributing

Found a bug or want to add a feature? PRs are welcome.

1. Fork the repo
2. Create your branch (`git checkout -b feature/awesome`)
3. Commit changes (`git commit -m 'Add awesome feature'`)
4. Push (`git push origin feature/awesome`)
5. Open a Pull Request

---

## License

MIT — do whatever you want with it.

---

**Built by [Kousha Rezaei](https://kousharezaei.dev)** — Full-Stack Developer & Security Enthusiast

If this saved you time, give it a ⭐
