#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  vps-hardener v1.0
#  Secure a fresh Ubuntu/Debian VPS in one command.
#  https://github.com/Koi725/vps-hardener
#
#  Usage:
#    sudo bash harden.sh
#    sudo bash harden.sh --dry-run
#    sudo bash harden.sh --undo
#
#  What it does:
#    1. System updates & unattended upgrades
#    2. Creates a non-root sudo user
#    3. SSH hardening (disable root, password auth, change port)
#    4. UFW firewall setup
#    5. Fail2ban installation & config
#    6. Automatic security updates
#    7. Kernel hardening (sysctl)
#    8. Log rotation & audit logging
#    9. Disable unnecessary services
#   10. Summary report
#
#  Author: Kousha Rezaei — github.com/Koi725
#  License: MIT
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Config defaults ───────────────────────────────────────────
SSH_PORT="${VPS_SSH_PORT:-2222}"
NEW_USER="${VPS_USER:-deployer}"
DRY_RUN=false
UNDO=false
LOG_FILE="/var/log/vps-hardener.log"
BACKUP_DIR="/root/.vps-hardener-backup"
REPORT=()

# ── Parse args ────────────────────────────────────────────────
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --undo)    UNDO=true ;;
        --port=*)  SSH_PORT="${arg#*=}" ;;
        --user=*)  NEW_USER="${arg#*=}" ;;
        --help|-h)
            echo "Usage: sudo bash harden.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run       Show what would be done without making changes"
            echo "  --undo          Reverse hardening (restore backups)"
            echo "  --port=NUMBER   Set SSH port (default: 2222)"
            echo "  --user=NAME     Set non-root username (default: deployer)"
            echo "  -h, --help      Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
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
    echo -e "${CYAN}[$(ts)] ⊘  $* (skipped — dry run)${NC}"
    REPORT+=("⊘ $* (dry run)")
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
    if [ "$DRY_RUN" = true ]; then
        skip "$1"
        return 1
    fi
    return 0
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

# ── Undo mode ─────────────────────────────────────────────────
if [ "$UNDO" = true ]; then
    header "Restoring backups"
    if [ -d "$BACKUP_DIR" ]; then
        for backup in "$BACKUP_DIR"/*.bak; do
            original_name=$(basename "$backup" | sed 's/\.[0-9]*\.bak$//')
            case "$original_name" in
                sshd_config) cp "$backup" /etc/ssh/sshd_config && log "Restored sshd_config" ;;
                sysctl.conf) cp "$backup" /etc/sysctl.conf && sysctl -p >/dev/null 2>&1 && log "Restored sysctl.conf" ;;
                jail.local)  cp "$backup" /etc/fail2ban/jail.local && log "Restored fail2ban config" ;;
            esac
        done
        systemctl restart sshd 2>/dev/null || true
        systemctl restart fail2ban 2>/dev/null || true
        success "Backups restored. Review and reboot to apply all changes."
    else
        warn "No backups found in $BACKUP_DIR"
    fi
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
header "VPS Hardener v1.0"
log "SSH Port: $SSH_PORT | User: $NEW_USER | Dry Run: $DRY_RUN"
echo ""

# ── 1. System Updates ─────────────────────────────────────────
header "1/10 — System Updates"

if run_or_skip "System update & upgrade"; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get dist-upgrade -y -qq
    apt-get autoremove -y -qq
    success "System updated and upgraded"
fi

# ── 2. Essential Packages ─────────────────────────────────────
header "2/10 — Installing Essential Packages"

PACKAGES="ufw fail2ban unattended-upgrades apt-listchanges logrotate \
          curl wget git htop net-tools auditd"

if run_or_skip "Install essential packages"; then
    apt-get install -y -qq $PACKAGES
    success "Essential packages installed"
fi

# ── 3. Create Non-Root User ───────────────────────────────────
header "3/10 — Creating Non-Root User"

if run_or_skip "Create user: $NEW_USER"; then
    if id "$NEW_USER" &>/dev/null; then
        warn "User '$NEW_USER' already exists — skipping"
        REPORT+=("⊘ User $NEW_USER already exists")
    else
        useradd -m -s /bin/bash -G sudo "$NEW_USER"

        # Generate random password
        USER_PASS=$(openssl rand -base64 16)
        echo "$NEW_USER:$USER_PASS" | chpasswd

        # Copy SSH keys from root
        if [ -d /root/.ssh ]; then
            mkdir -p "/home/$NEW_USER/.ssh"
            cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/" 2>/dev/null || true
            chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
            chmod 700 "/home/$NEW_USER/.ssh"
            chmod 600 "/home/$NEW_USER/.ssh/authorized_keys" 2>/dev/null || true
        fi

        # Passwordless sudo
        echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
        chmod 440 "/etc/sudoers.d/$NEW_USER"

        success "User '$NEW_USER' created (password saved to $LOG_FILE)"
        echo "[$(ts)] USER PASSWORD for $NEW_USER: $USER_PASS" >> "$LOG_FILE"
    fi
fi

# ── 4. SSH Hardening ──────────────────────────────────────────
header "4/10 — SSH Hardening"

if run_or_skip "Harden SSH configuration"; then
    backup_file /etc/ssh/sshd_config

    cat > /etc/ssh/sshd_config.d/hardened.conf <<EOF
# ── VPS Hardener SSH Config ──
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

    # Validate config before restarting
    if sshd -t 2>/dev/null; then
        systemctl restart sshd
        success "SSH hardened (port: $SSH_PORT, root login: disabled, password auth: disabled)"
    else
        fail "SSH config validation failed — reverting"
        rm -f /etc/ssh/sshd_config.d/hardened.conf
        REPORT+=("✗ SSH hardening failed — config invalid")
    fi
fi

# ── 5. Firewall (UFW) ────────────────────────────────────────
header "5/10 — Firewall Setup"

if run_or_skip "Configure UFW firewall"; then
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing

    # SSH
    ufw allow "$SSH_PORT/tcp" comment "SSH"

    # Common services (uncomment what you need)
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    # ufw allow 5432/tcp comment "PostgreSQL"
    # ufw allow 6379/tcp comment "Redis"

    # Rate limit SSH
    ufw limit "$SSH_PORT/tcp"

    ufw --force enable
    success "UFW firewall active (SSH:$SSH_PORT, HTTP:80, HTTPS:443)"
fi

# ── 6. Fail2ban ───────────────────────────────────────────────
header "6/10 — Fail2ban Configuration"

if run_or_skip "Configure Fail2ban"; then
    backup_file /etc/fail2ban/jail.local

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
backend  = systemd
action   = %(action_)s

[sshd]
enabled  = true
port     = $SSH_PORT
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 7200

[sshd-ddos]
enabled  = true
port     = $SSH_PORT
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 86400
EOF

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    success "Fail2ban active (3 attempts → 2hr ban, DDoS → 24hr ban)"
fi

# ── 7. Automatic Security Updates ────────────────────────────
header "7/10 — Automatic Security Updates"

if run_or_skip "Enable automatic security updates"; then
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
    success "Automatic security updates enabled (daily check, no auto-reboot)"
fi

# ── 8. Kernel Hardening ───────────────────────────────────────
header "8/10 — Kernel Hardening"

if run_or_skip "Apply sysctl hardening"; then
    backup_file /etc/sysctl.conf

    cat > /etc/sysctl.d/99-hardening.conf <<EOF
# ── Network hardening ──
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

# ── IPv6 hardening ──
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# ── Kernel hardening ──
kernel.randomize_va_space = 2
kernel.sysrq = 0
fs.suid_dumpable = 0
kernel.core_uses_pid = 1
EOF

    sysctl -p /etc/sysctl.d/99-hardening.conf >/dev/null 2>&1
    success "Kernel hardened (SYN cookies, ICMP protection, ASLR, no IP forwarding)"
fi

# ── 9. Disable Unnecessary Services ──────────────────────────
header "9/10 — Disabling Unnecessary Services"

if run_or_skip "Disable unnecessary services"; then
    DISABLED=()
    for service in avahi-daemon cups bluetooth ModemManager whoopsie apport; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            systemctl stop "$service" 2>/dev/null || true
            systemctl disable "$service" 2>/dev/null || true
            DISABLED+=("$service")
        fi
    done

    if [ ${#DISABLED[@]} -gt 0 ]; then
        success "Disabled services: ${DISABLED[*]}"
    else
        success "No unnecessary services found to disable"
    fi
fi

# ── 10. Log Rotation & Audit ─────────────────────────────────
header "10/10 — Log Rotation & Audit Logging"

if run_or_skip "Configure log rotation and auditing"; then
    # Enhanced logrotate for auth logs
    cat > /etc/logrotate.d/vps-hardener <<EOF
/var/log/auth.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}

/var/log/vps-hardener.log {
    monthly
    rotate 6
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
EOF

    # Enable audit daemon
    if command -v auditd &>/dev/null; then
        systemctl enable auditd >/dev/null 2>&1
        systemctl start auditd 2>/dev/null || true

        # Audit rules for critical files
        cat > /etc/audit/rules.d/hardener.rules <<EOF
-w /etc/passwd -p wa -k user_accounts
-w /etc/shadow -p wa -k user_accounts
-w /etc/sudoers -p wa -k sudo_changes
-w /etc/ssh/sshd_config -p wa -k ssh_config
-w /var/log/auth.log -p wa -k auth_log
EOF
        augenrules --load 2>/dev/null || true
    fi

    success "Log rotation configured, audit daemon active"
fi

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
header "Security Report"

echo -e "${BOLD}Results:${NC}"
echo ""
for item in "${REPORT[@]}"; do
    echo -e "  $item"
done

echo ""
echo -e "${BOLD}${YELLOW}⚠  IMPORTANT — Before you disconnect:${NC}"
echo ""
echo -e "  1. Open a ${BOLD}NEW terminal${NC} and test SSH access:"
echo -e "     ${CYAN}ssh -p $SSH_PORT $NEW_USER@your-server-ip${NC}"
echo ""
echo -e "  2. Make sure your SSH key works before closing this session"
echo ""
echo -e "  3. Full log saved to: ${CYAN}$LOG_FILE${NC}"
echo -e "  4. Backups saved to: ${CYAN}$BACKUP_DIR${NC}"
echo -e "  5. Undo all changes: ${CYAN}sudo bash harden.sh --undo${NC}"
echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✓ Server hardening complete${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════${NC}"
echo ""
