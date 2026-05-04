#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  vps-hardener v2.0
#  Secure a fresh Ubuntu/Debian VPS in one command.
#  Now with: Audit mode, Security scoring, Kernel checks,
#            Interactive mode, and structured reporting.
#
#  https://github.com/Koi725/vps-hardener
#
#  Usage:
#    sudo bash harden.sh                   Full hardening
#    sudo bash harden.sh --audit-only      Scan & score without changes
#    sudo bash harden.sh --interactive     Ask before each change
#    sudo bash harden.sh --dry-run         Show what would happen
#    sudo bash harden.sh --undo            Restore backups
#
#  Author: Kousha Rezaei — github.com/Koi725
#  License: MIT
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

VERSION="2.0.0"

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Config defaults ───────────────────────────────────────────
SSH_PORT="${VPS_SSH_PORT:-2222}"
NEW_USER="${VPS_USER:-deployer}"
DRY_RUN=false
UNDO=false
AUDIT_ONLY=false
INTERACTIVE=false
LOG_FILE="/var/log/vps-hardener.log"
BACKUP_DIR="/root/.vps-hardener-backup"
REPORT=()

# ── Security Score ────────────────────────────────────────────
SCORE=0
MAX_SCORE=0
FINDINGS_CRITICAL=()
FINDINGS_HIGH=()
FINDINGS_MEDIUM=()
FINDINGS_LOW=()

# ── Parse args ────────────────────────────────────────────────
for arg in "$@"; do
    case $arg in
        --dry-run)      DRY_RUN=true ;;
        --undo)         UNDO=true ;;
        --audit-only)   AUDIT_ONLY=true ;;
        --interactive)  INTERACTIVE=true ;;
        --port=*)       SSH_PORT="${arg#*=}" ;;
        --user=*)       NEW_USER="${arg#*=}" ;;
        --version|-v)   echo "vps-hardener v$VERSION"; exit 0 ;;
        --help|-h)
            echo -e "${BOLD}vps-hardener${NC} v$VERSION — Harden & audit Ubuntu/Debian servers"
            echo ""
            echo "Usage: sudo bash harden.sh [OPTIONS]"
            echo ""
            echo "Modes:"
            echo "  (default)         Full hardening — applies all security fixes"
            echo "  --audit-only      Scan system and report issues without fixing"
            echo "  --interactive     Ask before applying each change"
            echo "  --dry-run         Show what would be done without changes"
            echo "  --undo            Reverse hardening (restore backups)"
            echo ""
            echo "Options:"
            echo "  --port=NUMBER     Set SSH port (default: 2222)"
            echo "  --user=NAME       Set non-root username (default: deployer)"
            echo "  -v, --version     Show version"
            echo "  -h, --help        Show this help"
            echo ""
            echo "https://github.com/Koi725/vps-hardener"
            exit 0
            ;;
        *) echo "Unknown option: $arg (use --help)"; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────
ts() { date +"%Y-%m-%d %H:%M:%S"; }

log() {
    echo -e "${GREEN}[$(ts)]${NC} $*"
    echo "[$(ts)] $*" >> "$LOG_FILE" 2>/dev/null || true
}

warn() {
    echo -e "${YELLOW}[$(ts)] ⚠  $*${NC}"
    echo "[$(ts)] WARNING: $*" >> "$LOG_FILE" 2>/dev/null || true
}

fail() {
    echo -e "${RED}[$(ts)] ✗  $*${NC}"
    echo "[$(ts)] ERROR: $*" >> "$LOG_FILE" 2>/dev/null || true
}

success() {
    echo -e "${GREEN}[$(ts)] ✓  $*${NC}"
    REPORT+=("✓ $*")
}

skip() {
    echo -e "${CYAN}[$(ts)] ⊘  $* (skipped)${NC}"
    REPORT+=("⊘ $*")
}

header() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $*${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════${NC}"
    echo ""
}

backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        mkdir -p "$BACKUP_DIR"
        cp "$file" "$BACKUP_DIR/$(basename "$file").$(date +%s).bak"
    fi
}

run_or_skip() {
    if [ "$AUDIT_ONLY" = true ]; then return 1; fi
    if [ "$DRY_RUN" = true ]; then skip "$1"; return 1; fi
    if [ "$INTERACTIVE" = true ]; then
        echo -ne "${YELLOW}  Apply: $1? (y/N): ${NC}"
        read -r answer
        if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
            skip "$1 (declined)"; return 1
        fi
    fi
    return 0
}

add_score() { SCORE=$((SCORE + $1)); MAX_SCORE=$((MAX_SCORE + $2)); }

finding() {
    local sev=$1; local msg=$2
    case $sev in
        critical) FINDINGS_CRITICAL+=("$msg") ;;
        high)     FINDINGS_HIGH+=("$msg") ;;
        medium)   FINDINGS_MEDIUM+=("$msg") ;;
        low)      FINDINGS_LOW+=("$msg") ;;
    esac
}

# ── Pre-checks ────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    fail "This script must be run as root"
    echo "  Run: sudo bash harden.sh"
    exit 1
fi

if [ ! -f /etc/debian_version ] && [ ! -f /etc/lsb-release ]; then
    fail "This script supports Ubuntu/Debian only"
    exit 1
fi

# ── Piped execution warning ───────────────────────────────────
if [ ! -t 0 ] && [ "$AUDIT_ONLY" = false ]; then
    echo ""
    echo -e "${RED}${BOLD}  WARNING: Piped execution detected${NC}"
    echo ""
    echo -e "  You are running this via ${BOLD}curl | bash${NC}."
    echo -e "  This will make ${BOLD}permanent changes${NC} to your system."
    echo ""
    echo -e "  Recommended: Download first, review, then run:"
    echo -e "  ${CYAN}curl -sLO https://raw.githubusercontent.com/Koi725/vps-hardener/main/harden.sh${NC}"
    echo -e "  ${CYAN}less harden.sh && sudo bash harden.sh${NC}"
    echo ""
    echo -e "  Proceeding in 10 seconds... (Ctrl+C to cancel)"
    sleep 10
fi

# ── Undo mode ─────────────────────────────────────────────────
if [ "$UNDO" = true ]; then
    header "Restoring backups"
    if [ -d "$BACKUP_DIR" ]; then
        for backup in "$BACKUP_DIR"/*.bak; do
            [ -f "$backup" ] || continue
            original_name=$(basename "$backup" | sed 's/\.[0-9]*\.bak$//')
            case "$original_name" in
                sshd_config) cp "$backup" /etc/ssh/sshd_config && log "Restored sshd_config" ;;
                sysctl.conf) cp "$backup" /etc/sysctl.conf && sysctl -p >/dev/null 2>&1 && log "Restored sysctl.conf" ;;
                jail.local)  cp "$backup" /etc/fail2ban/jail.local && log "Restored fail2ban config" ;;
            esac
        done
        rm -f /etc/ssh/sshd_config.d/hardened.conf 2>/dev/null
        systemctl restart sshd 2>/dev/null || true
        systemctl restart fail2ban 2>/dev/null || true
        success "Backups restored. Reboot recommended."
    else
        warn "No backups found in $BACKUP_DIR"
    fi
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# AUDIT ENGINE
# ═══════════════════════════════════════════════════════════════

audit_system() {
    header "Security Audit"

    # ── SSH ────────────────────────────────────────────────────
    echo -e "  ${BOLD}[SSH]${NC}"

    # Root login
    if grep -qiE "^PermitRootLogin\s+(yes|without-password|prohibit-password)" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
        finding "critical" "SSH root login enabled — attackers target root directly"
        add_score 0 15
        fail "Root login enabled"
    elif ! grep -qi "PermitRootLogin no" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
        finding "high" "SSH PermitRootLogin not explicitly set to 'no'"
        add_score 5 15
        warn "Root login not explicitly disabled"
    else
        add_score 15 15
        success "Root login disabled"
    fi

    # Password auth
    if grep -qi "^PasswordAuthentication yes" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
        finding "critical" "SSH password auth enabled — vulnerable to brute force"
        add_score 0 15
        fail "Password auth enabled"
    elif ! grep -qi "PasswordAuthentication no" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
        finding "high" "SSH PasswordAuthentication not explicitly disabled"
        add_score 5 15
        warn "Password auth not explicitly disabled"
    else
        add_score 15 15
        success "Password auth disabled (key-only)"
    fi

    # SSH port
    local ssh_port=$(grep -i "^Port " /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | head -1)
    ssh_port="${ssh_port:-22}"
    if [ "$ssh_port" = "22" ]; then
        finding "medium" "SSH on default port 22 — targeted by automated scanners"
        add_score 2 5
        warn "SSH on default port 22"
    else
        add_score 5 5
        success "SSH on non-default port $ssh_port"
    fi

    # MaxAuthTries
    local max_tries=$(grep -i "^MaxAuthTries" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | head -1)
    if [ -z "$max_tries" ] || [ "${max_tries:-99}" -gt 5 ] 2>/dev/null; then
        finding "low" "SSH MaxAuthTries not restricted"
        add_score 1 3
        warn "MaxAuthTries not hardened"
    else
        add_score 3 3
        success "MaxAuthTries set to $max_tries"
    fi

    echo ""

    # ── Firewall ──────────────────────────────────────────────
    echo -e "  ${BOLD}[Firewall]${NC}"

    if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -qi "active"; then
            add_score 10 10
            success "UFW firewall active"
            local open_ports=$(ufw status | grep -c "ALLOW")
            if [ "$open_ports" -gt 5 ]; then
                finding "medium" "$open_ports ports open — review if all necessary"
                warn "$open_ports ports open"
            fi
        else
            finding "critical" "Firewall installed but NOT active"
            add_score 0 10
            fail "UFW inactive"
        fi
    else
        finding "critical" "No firewall installed"
        add_score 0 10
        fail "No firewall found"
    fi

    echo ""

    # ── Fail2ban ──────────────────────────────────────────────
    echo -e "  ${BOLD}[Intrusion Prevention]${NC}"

    if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban 2>/dev/null; then
        add_score 8 8
        success "Fail2ban active"
    elif command -v fail2ban-client &>/dev/null; then
        finding "high" "Fail2ban installed but not running"
        add_score 0 8
        fail "Fail2ban inactive"
    else
        finding "high" "Fail2ban not installed — no brute force protection"
        add_score 0 8
        fail "No fail2ban"
    fi

    echo ""

    # ── SUID/SGID Binaries ────────────────────────────────────
    echo -e "  ${BOLD}[SUID/SGID Binaries]${NC}"

    local safe_suid="/usr/bin/passwd /usr/bin/sudo /usr/bin/su /usr/bin/newgrp /usr/bin/chsh /usr/bin/chfn /usr/bin/gpasswd /usr/bin/mount /usr/bin/umount /usr/lib/openssh/ssh-keysign /usr/lib/dbus-1.0/dbus-daemon-launch-helper /usr/bin/pkexec /usr/bin/crontab /usr/bin/at /usr/sbin/unix_chkpwd"
    local suspicious_count=0
    local suspicious_list=""

    while IFS= read -r binary; do
        [ -z "$binary" ] && continue
        local is_safe=false
        for safe in $safe_suid; do
            [ "$binary" = "$safe" ] && is_safe=true && break
        done
        if [ "$is_safe" = false ]; then
            suspicious_count=$((suspicious_count + 1))
            suspicious_list="$suspicious_list\n    ${DIM}$binary${NC}"
        fi
    done < <(find / -perm /4000 -type f 2>/dev/null | head -30)

    if [ "$suspicious_count" -gt 0 ]; then
        finding "high" "$suspicious_count unusual SUID binaries — potential privilege escalation"
        add_score 3 8
        warn "$suspicious_count unusual SUID binaries:"
        echo -e "$suspicious_list" | head -10
    else
        add_score 8 8
        success "No unusual SUID binaries"
    fi

    echo ""

    # ── World-Writable Files ──────────────────────────────────
    echo -e "  ${BOLD}[World-Writable Files]${NC}"

    local ww_count=$(find /etc /usr /var/www -perm -0002 -type f 2>/dev/null | wc -l)
    if [ "$ww_count" -gt 0 ]; then
        finding "high" "$ww_count world-writable files in critical directories"
        add_score 2 7
        warn "$ww_count world-writable files found"
    else
        add_score 7 7
        success "No world-writable files in critical directories"
    fi

    echo ""

    # ── Cron Jobs ─────────────────────────────────────────────
    echo -e "  ${BOLD}[Cron Jobs]${NC}"

    local suspicious_cron=0
    for cron_file in /var/spool/cron/crontabs/* /etc/cron.d/* /etc/cron.daily/* /etc/cron.hourly/*; do
        [ -f "$cron_file" ] || continue
        if grep -lqiE "curl|wget|nc |ncat|/dev/tcp|python.*http" "$cron_file" 2>/dev/null; then
            suspicious_cron=$((suspicious_cron + 1))
        fi
    done

    if [ "$suspicious_cron" -gt 0 ]; then
        finding "high" "$suspicious_cron cron entries with network download commands"
        add_score 2 5
        warn "$suspicious_cron suspicious cron entries"
    else
        add_score 5 5
        success "No suspicious cron jobs"
    fi

    echo ""

    # ── Kernel ────────────────────────────────────────────────
    echo -e "  ${BOLD}[Kernel & Updates]${NC}"

    local kernel_version=$(uname -r)
    local kernel_major=$(echo "$kernel_version" | cut -d. -f1)
    local kernel_minor=$(echo "$kernel_version" | cut -d. -f2)

    log "Kernel: $kernel_version"

    # Dirty Pipe: 5.8 — 5.16
    if [ "$kernel_major" -eq 5 ] && [ "$kernel_minor" -ge 8 ] && [ "$kernel_minor" -le 16 ]; then
        finding "critical" "Kernel $kernel_version may be vulnerable to Dirty Pipe (CVE-2022-0847)"
        add_score 0 10
        fail "Kernel $kernel_version — Dirty Pipe risk"
    # OverlayFS LPE: 5.11 — 6.2 on Ubuntu
    elif { [ "$kernel_major" -eq 5 ] && [ "$kernel_minor" -ge 11 ]; } || \
         { [ "$kernel_major" -eq 6 ] && [ "$kernel_minor" -le 2 ]; }; then
        if [ -f /etc/lsb-release ]; then
            finding "high" "Kernel $kernel_version may be affected by OverlayFS LPE (CVE-2023-2640)"
            add_score 3 10
            warn "Kernel $kernel_version — OverlayFS risk (check if patched)"
        else
            add_score 8 10
            success "Kernel $kernel_version"
        fi
    # Old kernels
    elif [ "$kernel_major" -lt 5 ]; then
        finding "high" "Kernel $kernel_version is significantly outdated"
        add_score 2 10
        fail "Kernel $kernel_version — outdated"
    elif [ "$kernel_major" -lt 6 ]; then
        finding "medium" "Kernel $kernel_version — consider upgrading for latest patches"
        add_score 6 10
        warn "Kernel $kernel_version — older series"
    else
        add_score 10 10
        success "Kernel $kernel_version — no known critical issues"
    fi

    # Pending security updates
    local pending=0
    if command -v apt-get &>/dev/null; then
        pending=$(apt-get -s dist-upgrade 2>/dev/null | grep -c "^Inst.*security" || echo "0")
    fi
    if [ "$pending" -gt 0 ]; then
        finding "high" "$pending pending security updates"
        add_score 0 5
        fail "$pending security updates pending"
    else
        add_score 5 5
        success "No pending security updates"
    fi

    # Auto updates
    if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
        add_score 4 4
        success "Automatic security updates configured"
    else
        finding "medium" "No automatic security updates"
        add_score 0 4
        warn "No automatic updates"
    fi

    echo ""

    # ── Users ─────────────────────────────────────────────────
    echo -e "  ${BOLD}[Users & Auth]${NC}"

    local empty_pass=$(awk -F: '($2 == "" || $2 == "!") && $1 != "root" {print $1}' /etc/shadow 2>/dev/null | head -5)
    if [ -n "$empty_pass" ]; then
        finding "critical" "Users with empty passwords: $empty_pass"
        add_score 0 5
        fail "Users without passwords"
    else
        add_score 5 5
        success "All users have passwords"
    fi

    local sudo_users=$(grep -Po '^sudo.+:\K.*$' /etc/group 2>/dev/null)
    if [ -z "$sudo_users" ]; then
        finding "medium" "No sudo users — only root can administer"
        add_score 2 5
        warn "No sudo users"
    else
        add_score 5 5
        success "Sudo users: $sudo_users"
    fi

    echo ""

    # ── Sysctl ────────────────────────────────────────────────
    echo -e "  ${BOLD}[Kernel Parameters]${NC}"

    local sysctl_ok=0
    local sysctl_total=0

    check_sysctl() {
        sysctl_total=$((sysctl_total + $4))
        local val=$(sysctl -n "$1" 2>/dev/null)
        if [ "$val" = "$2" ]; then
            sysctl_ok=$((sysctl_ok + $4))
        else
            finding "medium" "sysctl $1 = $val (expected $2) — $3"
        fi
    }

    check_sysctl "net.ipv4.tcp_syncookies" "1" "SYN flood protection off" 2
    check_sysctl "net.ipv4.conf.all.rp_filter" "1" "IP spoofing protection off" 2
    check_sysctl "net.ipv4.conf.all.accept_redirects" "0" "ICMP redirects accepted" 1
    check_sysctl "net.ipv4.conf.all.send_redirects" "0" "ICMP redirects sent" 1
    check_sysctl "net.ipv4.ip_forward" "0" "IP forwarding enabled" 2
    check_sysctl "kernel.randomize_va_space" "2" "ASLR not fully enabled" 2

    add_score "$sysctl_ok" "$sysctl_total"
    if [ "$sysctl_ok" -eq "$sysctl_total" ]; then
        success "All kernel parameters hardened ($sysctl_ok/$sysctl_total)"
    else
        warn "Kernel hardening: $sysctl_ok/$sysctl_total"
    fi

    echo ""
}

# ═══════════════════════════════════════════════════════════════
# SECURITY SCORE
# ═══════════════════════════════════════════════════════════════

print_score() {
    header "Security Score"

    local pct=0
    [ "$MAX_SCORE" -gt 0 ] && pct=$((SCORE * 100 / MAX_SCORE))

    # Score bar
    local bar_len=30
    local filled=$((pct * bar_len / 100))
    local empty=$((bar_len - filled))
    local color=$RED
    [ "$pct" -ge 80 ] && color=$GREEN
    [ "$pct" -ge 60 ] && [ "$pct" -lt 80 ] && color=$YELLOW

    echo -ne "  ${BOLD}Score: ${color}"
    for ((i=0; i<filled; i++)); do echo -ne "█"; done
    echo -ne "${DIM}"
    for ((i=0; i<empty; i++)); do echo -ne "░"; done
    echo -e "${NC} ${BOLD}${color}${pct}/100${NC}"
    echo ""

    # Grade
    local grade=""
    [ "$pct" -ge 90 ] && grade="A — Excellent"
    [ "$pct" -ge 80 ] && [ "$pct" -lt 90 ] && grade="B — Good"
    [ "$pct" -ge 60 ] && [ "$pct" -lt 80 ] && grade="C — Fair"
    [ "$pct" -ge 40 ] && [ "$pct" -lt 60 ] && grade="D — Needs Work"
    [ "$pct" -lt 40 ] && grade="F — Critical Risk"

    echo -e "  ${BOLD}Grade: ${color}${grade}${NC}"
    echo ""

    # Findings
    if [ ${#FINDINGS_CRITICAL[@]} -gt 0 ]; then
        echo -e "  ${RED}${BOLD}CRITICAL (${#FINDINGS_CRITICAL[@]}):${NC}"
        for f in "${FINDINGS_CRITICAL[@]}"; do echo -e "  ${RED}  ✗ $f${NC}"; done
        echo ""
    fi
    if [ ${#FINDINGS_HIGH[@]} -gt 0 ]; then
        echo -e "  ${YELLOW}${BOLD}HIGH (${#FINDINGS_HIGH[@]}):${NC}"
        for f in "${FINDINGS_HIGH[@]}"; do echo -e "  ${YELLOW}  ⚠ $f${NC}"; done
        echo ""
    fi
    if [ ${#FINDINGS_MEDIUM[@]} -gt 0 ]; then
        echo -e "  ${CYAN}${BOLD}MEDIUM (${#FINDINGS_MEDIUM[@]}):${NC}"
        for f in "${FINDINGS_MEDIUM[@]}"; do echo -e "  ${CYAN}  ℹ $f${NC}"; done
        echo ""
    fi
    if [ ${#FINDINGS_LOW[@]} -gt 0 ]; then
        echo -e "  ${DIM}LOW (${#FINDINGS_LOW[@]}):${NC}"
        for f in "${FINDINGS_LOW[@]}"; do echo -e "  ${DIM}  · $f${NC}"; done
        echo ""
    fi

    local total=$(( ${#FINDINGS_CRITICAL[@]} + ${#FINDINGS_HIGH[@]} + ${#FINDINGS_MEDIUM[@]} + ${#FINDINGS_LOW[@]} ))
    [ "$total" -eq 0 ] && echo -e "  ${GREEN}${BOLD}No security issues found.${NC}\n"
}

# ═══════════════════════════════════════════════════════════════
# HARDENING ENGINE
# ═══════════════════════════════════════════════════════════════

harden_system() {
    header "1/10 — System Updates"
    if run_or_skip "System update & upgrade"; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get upgrade -y -qq && apt-get dist-upgrade -y -qq && apt-get autoremove -y -qq
        success "System updated"
    fi

    header "2/10 — Essential Packages"
    if run_or_skip "Install essential packages"; then
        apt-get install -y -qq ufw fail2ban unattended-upgrades apt-listchanges logrotate curl wget git htop net-tools auditd
        success "Essential packages installed"
    fi

    header "3/10 — Non-Root User"
    if run_or_skip "Create user: $NEW_USER"; then
        if id "$NEW_USER" &>/dev/null; then
            warn "User '$NEW_USER' already exists"
        else
            useradd -m -s /bin/bash -G sudo "$NEW_USER"
            USER_PASS=$(openssl rand -base64 16)
            echo "$NEW_USER:$USER_PASS" | chpasswd
            if [ -d /root/.ssh ]; then
                mkdir -p "/home/$NEW_USER/.ssh"
                cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/" 2>/dev/null || true
                chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
                chmod 700 "/home/$NEW_USER/.ssh"
                chmod 600 "/home/$NEW_USER/.ssh/authorized_keys" 2>/dev/null || true
            fi
            echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
            chmod 440 "/etc/sudoers.d/$NEW_USER"
            success "User '$NEW_USER' created"
            echo "[$(ts)] PASSWORD for $NEW_USER: $USER_PASS" >> "$LOG_FILE"
        fi
    fi

    header "4/10 — SSH Hardening"
    if run_or_skip "Harden SSH configuration"; then
        backup_file /etc/ssh/sshd_config
        cat > /etc/ssh/sshd_config.d/hardened.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
MaxSessions 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
AllowUsers $NEW_USER
Protocol 2
EOF
        if sshd -t 2>/dev/null; then
            systemctl restart sshd
            success "SSH hardened (port:$SSH_PORT, root:off, password:off)"
        else
            fail "SSH config invalid — reverting"
            rm -f /etc/ssh/sshd_config.d/hardened.conf
        fi
    fi

    header "5/10 — Firewall"
    if run_or_skip "Configure UFW firewall"; then
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming && ufw default allow outgoing
        ufw allow "$SSH_PORT/tcp" comment "SSH"
        ufw allow 80/tcp comment "HTTP"
        ufw allow 443/tcp comment "HTTPS"
        ufw limit "$SSH_PORT/tcp"
        ufw --force enable
        success "UFW active (SSH:$SSH_PORT, HTTP:80, HTTPS:443)"
    fi

    header "6/10 — Fail2ban"
    if run_or_skip "Configure Fail2ban"; then
        backup_file /etc/fail2ban/jail.local
        cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200

[sshd-ddos]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log
maxretry = 5
bantime = 86400
EOF
        systemctl enable fail2ban >/dev/null 2>&1
        systemctl restart fail2ban
        success "Fail2ban active"
    fi

    header "7/10 — Auto Security Updates"
    if run_or_skip "Enable automatic updates"; then
        cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
        cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
        systemctl enable unattended-upgrades >/dev/null 2>&1
        success "Auto security updates enabled"
    fi

    header "8/10 — Kernel Hardening"
    if run_or_skip "Apply sysctl hardening"; then
        backup_file /etc/sysctl.conf
        cat > /etc/sysctl.d/99-hardening.conf <<EOF
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
kernel.randomize_va_space = 2
kernel.sysrq = 0
fs.suid_dumpable = 0
kernel.core_uses_pid = 1
EOF
        sysctl -p /etc/sysctl.d/99-hardening.conf >/dev/null 2>&1
        success "Kernel hardened"
    fi

    header "9/10 — Disable Unnecessary Services"
    if run_or_skip "Disable unnecessary services"; then
        local disabled=()
        for svc in avahi-daemon cups bluetooth ModemManager whoopsie apport; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
                disabled+=("$svc")
            fi
        done
        [ ${#disabled[@]} -gt 0 ] && success "Disabled: ${disabled[*]}" || success "No unnecessary services found"
    fi

    header "10/10 — Audit Logging"
    if run_or_skip "Configure logging and auditing"; then
        cat > /etc/logrotate.d/vps-hardener <<EOF
/var/log/auth.log { weekly; rotate 12; compress; missingok; notifempty; create 640 root adm; }
/var/log/vps-hardener.log { monthly; rotate 6; compress; missingok; notifempty; create 640 root root; }
EOF
        if command -v auditd &>/dev/null; then
            systemctl enable auditd >/dev/null 2>&1
            systemctl start auditd 2>/dev/null || true
            cat > /etc/audit/rules.d/hardener.rules <<EOF
-w /etc/passwd -p wa -k user_accounts
-w /etc/shadow -p wa -k user_accounts
-w /etc/sudoers -p wa -k sudo_changes
-w /etc/ssh/sshd_config -p wa -k ssh_config
-w /var/log/auth.log -p wa -k auth_log
EOF
            augenrules --load 2>/dev/null || true
        fi
        success "Logging and auditing configured"
    fi
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════

if [ "$AUDIT_ONLY" = true ]; then
    header "VPS Hardener v$VERSION — Audit Mode"
    log "Mode: Audit Only (no changes)"
else
    header "VPS Hardener v$VERSION"
    log "SSH:$SSH_PORT | User:$NEW_USER | DryRun:$DRY_RUN | Interactive:$INTERACTIVE"
fi

# Always audit first
audit_system
print_score

# Harden if not audit-only
if [ "$AUDIT_ONLY" = false ]; then
    harden_system

    header "Hardening Report"
    echo -e "${BOLD}Results:${NC}\n"
    for item in "${REPORT[@]}"; do echo -e "  $item"; done

    echo ""
    echo -e "${BOLD}${YELLOW}⚠  Before you disconnect:${NC}"
    echo -e "  1. Test SSH: ${CYAN}ssh -p $SSH_PORT $NEW_USER@your-server-ip${NC}"
    echo -e "  2. Log: ${CYAN}$LOG_FILE${NC}"
    echo -e "  3. Undo: ${CYAN}sudo bash harden.sh --undo${NC}"
    echo -e "  4. Audit: ${CYAN}sudo bash harden.sh --audit-only${NC}"
fi

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════${NC}"
[ "$AUDIT_ONLY" = true ] && echo -e "${BOLD}${GREEN}  ✓ Security audit complete${NC}" || echo -e "${BOLD}${GREEN}  ✓ Server hardening complete${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════${NC}"
echo ""
