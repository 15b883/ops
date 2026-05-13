#!/bin/bash
#============================================================================
# Linux System Initialization Script
# Version: 2.0
# Supported: Ubuntu 22.04/24.04, Debian 11/12, CentOS Stream 8/9, RHEL 8/9
# Usage: bash system_init.sh
#============================================================================

set -euo pipefail

# ========================= Color & Output Helpers ==========================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ========================= Global Variables ================================

OS_FAMILY=""    # debian | rhel
OS_NAME=""      # ubuntu | debian | centos | rhel
OS_VERSION=""   # e.g. 22.04, 12, 9
PKG_MGR=""      # apt | dnf | yum
KERNEL_MAJOR=0
KERNEL_MINOR=0

# ========================= OS Detection ====================================

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect OS: /etc/os-release not found"
        exit 1
    fi

    source /etc/os-release

    case "${ID}" in
        ubuntu)
            OS_FAMILY="debian"
            OS_NAME="ubuntu"
            OS_VERSION="${VERSION_ID}"
            PKG_MGR="apt"
            if [[ "${OS_VERSION}" != "22.04" && "${OS_VERSION}" != "24.04" ]]; then
                warn "Ubuntu ${OS_VERSION} is not officially supported (22.04/24.04)"
            fi
            ;;
        debian)
            OS_FAMILY="debian"
            OS_NAME="debian"
            OS_VERSION="${VERSION_ID}"
            PKG_MGR="apt"
            if [[ "${OS_VERSION}" != "11" && "${OS_VERSION}" != "12" ]]; then
                warn "Debian ${OS_VERSION} is not officially supported (11/12)"
            fi
            ;;
        centos)
            OS_FAMILY="rhel"
            OS_NAME="centos"
            OS_VERSION="${VERSION_ID}"
            PKG_MGR="dnf"
            if [[ "${OS_VERSION}" != "8" && "${OS_VERSION}" != "9" ]]; then
                warn "CentOS ${OS_VERSION} is not officially supported (Stream 8/9)"
            fi
            ;;
        rhel|rocky|almalinux)
            OS_FAMILY="rhel"
            OS_NAME="${ID}"
            OS_VERSION="${VERSION_ID%%.*}"
            PKG_MGR="dnf"
            if [[ "${OS_VERSION}" != "8" && "${OS_VERSION}" != "9" ]]; then
                warn "RHEL ${OS_VERSION} is not officially supported (8/9)"
            fi
            ;;
        *)
            error "Unsupported OS: ${ID}"
            exit 1
            ;;
    esac

    # Detect kernel version
    local kver
    kver=$(uname -r)
    KERNEL_MAJOR=$(echo "$kver" | cut -d. -f1)
    KERNEL_MINOR=$(echo "$kver" | cut -d. -f2)

    info "Detected: ${PRETTY_NAME} (family=${OS_FAMILY}, pkg=${PKG_MGR}, kernel=${KERNEL_MAJOR}.${KERNEL_MINOR})"
}

# ========================= Root Check ======================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# ========================= 1. Install Common Packages ======================

install_packages() {
    info "Installing common packages..."

    if [[ "${OS_FAMILY}" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq > /dev/null 2>&1

        apt-get install -y -qq \
            vim curl wget git zip unzip lsof nmap netcat-openbsd telnet \
            net-tools sysstat strace htop \
            build-essential cmake \
            openssl libssl-dev libxml2-dev libpcre3-dev zlib1g-dev \
            dnsutils lrzsz bzip2 libbz2-dev \
            ca-certificates gnupg software-properties-common \
            > /dev/null 2>&1

    elif [[ "${OS_FAMILY}" == "rhel" ]]; then
        ${PKG_MGR} install -y epel-release > /dev/null 2>&1 || true

        ${PKG_MGR} install -y \
            vim curl wget git zip unzip lsof nmap ncat telnet \
            net-tools sysstat strace htop \
            gcc gcc-c++ cmake make \
            openssl openssl-devel libxml2-devel pcre-devel zlib-devel \
            bind-utils lrzsz bzip2 bzip2-devel \
            > /dev/null 2>&1
    fi

    success "Common packages installed"
}

# ========================= 2. Create Directories & SSH Keys ================

setup_directories() {
    info "Creating directories and SSH keys..."

    [[ ! -d /opt/package ]] && mkdir -p /opt/package
    [[ ! -d /root/scripts ]] && mkdir -p /root/scripts

    if [[ ! -f ~/.ssh/id_rsa ]]; then
        ssh-keygen -t rsa -b 4096 -P '' -f ~/.ssh/id_rsa > /dev/null 2>&1
        success "SSH key pair generated"
    else
        info "SSH key pair already exists, skipping"
    fi

    success "Directories created"
}

# ========================= 3. Configure SSH Security =======================

configure_ssh() {
    info "Configuring SSH security..."

    local sshd_config="/etc/ssh/sshd_config"

    # Backup
    if [[ ! -f "${sshd_config}.bak" ]]; then
        cp "${sshd_config}" "${sshd_config}.bak"
    fi

    # Allow root login
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${sshd_config}"
    # Deny empty passwords
    sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' "${sshd_config}"
    # Enable password authentication
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "${sshd_config}"
    # Disable DNS lookup
    sed -i 's/^#\?UseDNS.*/UseDNS no/' "${sshd_config}"
    # Listen on all interfaces
    sed -i 's/^#\?ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' "${sshd_config}"

    systemctl restart sshd > /dev/null 2>&1

    success "SSH configured and restarted"
}

# ========================= 4. Configure Timezone & Time Sync ===============

configure_timezone() {
    info "Configuring timezone and time sync..."

    # Set timezone
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || \
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

    # Install and enable chronyd
    if [[ "${OS_FAMILY}" == "debian" ]]; then
        apt-get install -y -qq chrony > /dev/null 2>&1
    elif [[ "${OS_FAMILY}" == "rhel" ]]; then
        ${PKG_MGR} install -y chrony > /dev/null 2>&1
    fi

    systemctl enable chronyd > /dev/null 2>&1
    systemctl restart chronyd > /dev/null 2>&1

    # Force sync
    chronyc makestep > /dev/null 2>&1 || true

    success "Timezone set to Asia/Shanghai, chronyd enabled"
}

# ========================= 5. Disable Unnecessary Services =================

disable_services() {
    info "Disabling unnecessary services..."

    # Disable SELinux (RHEL family only)
    if [[ "${OS_FAMILY}" == "rhel" ]]; then
        if [[ -f /etc/selinux/config ]]; then
            sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
            sed -i 's/^SELINUX=permissive/SELINUX=disabled/' /etc/selinux/config
            setenforce 0 2>/dev/null || true
            success "SELinux disabled"
        fi
    fi

    # Common services to disable
    local services_to_disable=(
        postfix acpid mdmonitor rpcbind rpcgssd rpcidmapd
        auditd haldaemon lldpad atd kdump
    )

    # RHEL-specific
    if [[ "${OS_FAMILY}" == "rhel" ]]; then
        services_to_disable+=(firewalld ip6tables mcelogd netfs nfslock openct)
    fi

    for svc in "${services_to_disable[@]}"; do
        systemctl disable "${svc}" > /dev/null 2>&1 || true
        systemctl stop "${svc}" > /dev/null 2>&1 || true
    done

    # Ensure essential services are enabled
    systemctl enable sshd > /dev/null 2>&1 || true
    systemctl enable cron > /dev/null 2>&1 || \
        systemctl enable crond > /dev/null 2>&1 || true

    success "Unnecessary services disabled"
}

# ========================= 6. Set System Limits ============================

configure_limits() {
    info "Configuring system limits..."

    local limits_file="/etc/security/limits.conf"
    local marker="# Added by system_init.sh"

    if grep -q "${marker}" "${limits_file}" 2>/dev/null; then
        info "System limits already configured, skipping"
        return
    fi

    cat >> "${limits_file}" <<EOF

${marker}
* soft nproc  65530
* hard nproc  65530
* soft nofile 65530
* hard nofile 65530
EOF

    success "System limits configured (nproc/nofile = 65530)"
}

# ========================= 7. Set System Locale ============================

configure_locale() {
    info "Configuring system locale..."

    if [[ "${OS_FAMILY}" == "debian" ]]; then
        apt-get install -y -qq locales > /dev/null 2>&1
        sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || true
        locale-gen en_US.UTF-8 > /dev/null 2>&1 || true
        update-locale LANG=en_US.UTF-8 > /dev/null 2>&1 || true
    elif [[ "${OS_FAMILY}" == "rhel" ]]; then
        localectl set-locale LANG=en_US.UTF-8 2>/dev/null || true
    fi

    success "Locale set to en_US.UTF-8"
}

# ========================= 8. Configure Session Timeout ====================

configure_timeout() {
    info "Configuring session timeout and history..."

    local profile_file="/etc/profile.d/system_init.sh"

    cat > "${profile_file}" <<'EOF'
# Session timeout (10 minutes)
export TMOUT=600
# Limit history size
export HISTSIZE=50
export HISTFILESIZE=50
EOF

    chmod 644 "${profile_file}"

    success "Session timeout=600s, history size=50"
}

# ========================= 9. Lock Critical System Files ===================

lock_system_files() {
    info "Locking critical system files..."

    warn "This will make passwd/shadow/group read-only via chattr +ai"
    warn "You will need to unlock them (chattr -ai) before modifying users"

    local files=(/etc/passwd /etc/shadow /etc/group /etc/gshadow)

    for f in "${files[@]}"; do
        if [[ -f "$f" ]]; then
            chattr +ai "$f" 2>/dev/null || true
        fi
    done

    success "Critical system files locked"
}

# ========================= 10. Clean /etc/issue ============================

clean_issue() {
    info "Cleaning /etc/issue..."

    if [[ -f /etc/issue ]]; then
        [[ ! -f /etc/issue.bak ]] && cp /etc/issue /etc/issue.bak
        > /etc/issue
        success "/etc/issue cleared"
    fi
}

# ========================= 11. Optimize Kernel Parameters ==================
# (merged from kernel.sh)

optimize_kernel() {
    info "Optimizing kernel parameters..."

    local sysctl_file="/etc/sysctl.d/99-system-init.conf"

    # Backup existing sysctl.conf
    [[ ! -f /etc/sysctl.conf.bak ]] && cp /etc/sysctl.conf /etc/sysctl.conf.bak

    cat > "${sysctl_file}" <<'SYSCTL'
# ============================================================
# Kernel optimization - generated by system_init.sh
# ============================================================

# Disable ICMP ping response
net.ipv4.icmp_echo_ignore_all = 1

# Enable SYN Cookies to prevent SYN flood attacks
net.ipv4.tcp_syncookies = 1

# Allow reuse of TIME-WAIT sockets for new connections
net.ipv4.tcp_tw_reuse = 1

# Reduce FIN-WAIT-2 timeout
net.ipv4.tcp_fin_timeout = 2

# TCP keepalive interval (20 minutes)
net.ipv4.tcp_keepalive_time = 1200

# Local port range for outgoing connections
net.ipv4.ip_local_port_range = 10000 65000

# SYN backlog queue length
net.ipv4.tcp_max_syn_backlog = 16384

# Max TIME-WAIT sockets
net.ipv4.tcp_max_tw_buckets = 5000

# Route GC timeout
net.ipv4.route.gc_timeout = 100

# SYN retry counts
net.ipv4.tcp_syn_retries = 1
net.ipv4.tcp_synack_retries = 1

# Socket backlog
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384

# Max orphaned sockets
net.ipv4.tcp_max_orphans = 16384

# Connection tracking (nf_conntrack)
net.netfilter.nf_conntrack_max = 25000000
net.netfilter.nf_conntrack_tcp_timeout_established = 180
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
SYSCTL

    # tcp_tw_recycle was removed in kernel 4.12+
    if [[ ${KERNEL_MAJOR} -lt 4 ]] || { [[ ${KERNEL_MAJOR} -eq 4 ]] && [[ ${KERNEL_MINOR} -lt 12 ]]; }; then
        echo "" >> "${sysctl_file}"
        echo "# Fast recycling of TIME-WAIT sockets (kernel < 4.12 only)" >> "${sysctl_file}"
        echo "net.ipv4.tcp_tw_recycle = 1" >> "${sysctl_file}"
    fi

    # Load nf_conntrack module before applying
    modprobe nf_conntrack 2>/dev/null || true

    # Apply sysctl settings
    sysctl -p "${sysctl_file}" > /dev/null 2>&1 || {
        warn "Some sysctl parameters could not be applied (module not loaded?)"
        sysctl -p "${sysctl_file}" 2>&1 | grep -i "error\|cannot" || true
    }

    success "Kernel parameters optimized (${sysctl_file})"
}

# ========================= Menu Functions ==================================

show_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "============================================================"
    echo "       Linux System Initialization Script v2.0"
    echo "============================================================"
    echo -e "${NC}"
    echo -e "  OS: ${GREEN}${OS_NAME} ${OS_VERSION}${NC} (${OS_FAMILY})"
    echo -e "  Kernel: ${GREEN}${KERNEL_MAJOR}.${KERNEL_MINOR}${NC}"
    echo ""
}

show_menu() {
    echo -e "${BOLD}  Select an option:${NC}"
    echo ""
    echo -e "   ${CYAN} 1)${NC} Install common packages"
    echo -e "   ${CYAN} 2)${NC} Create directories & SSH keys"
    echo -e "   ${CYAN} 3)${NC} Configure SSH security"
    echo -e "   ${CYAN} 4)${NC} Configure timezone & time sync (chronyd)"
    echo -e "   ${CYAN} 5)${NC} Disable unnecessary services"
    echo -e "   ${CYAN} 6)${NC} Set system limits (ulimit)"
    echo -e "   ${CYAN} 7)${NC} Set system locale (UTF-8)"
    echo -e "   ${CYAN} 8)${NC} Configure session timeout & history"
    echo -e "   ${CYAN} 9)${NC} Lock critical system files"
    echo -e "   ${CYAN}10)${NC} Clean /etc/issue"
    echo -e "   ${CYAN}11)${NC} Optimize kernel parameters"
    echo ""
    echo -e "   ${GREEN}${BOLD} 0)${NC}${GREEN}${BOLD} Install ALL (1-8, 10-11)${NC}"
    echo -e "   ${RED} q)${NC} Exit"
    echo ""
    echo "============================================================"
}

run_module() {
    case "$1" in
        1)  install_packages ;;
        2)  setup_directories ;;
        3)  configure_ssh ;;
        4)  configure_timezone ;;
        5)  disable_services ;;
        6)  configure_limits ;;
        7)  configure_locale ;;
        8)  configure_timeout ;;
        9)  lock_system_files ;;
        10) clean_issue ;;
        11) optimize_kernel ;;
        *)  error "Invalid option: $1"; return 1 ;;
    esac
}

install_all() {
    echo ""
    info "Starting full system initialization..."
    echo ""

    local modules=(1 2 3 4 5 6 7 8 10 11)
    local total=${#modules[@]}
    local current=0

    for mod in "${modules[@]}"; do
        ((current++))
        echo -e "${BOLD}[${current}/${total}]${NC} =========================="
        run_module "$mod"
        echo ""
    done

    echo "============================================================"
    success "System initialization complete!"
    echo "============================================================"
    warn "Note: Module 9 (Lock system files) was skipped by default."
    warn "Run it manually if needed (requires chattr -ai to unlock)."
    warn "A reboot is recommended to apply all changes."
}

# ========================= Main ============================================

main() {
    check_root
    detect_os

    # Non-interactive mode: --all flag
    if [[ "${1:-}" == "--all" ]]; then
        install_all
        exit 0
    fi

    # Interactive menu
    while true; do
        clear
        show_banner
        show_menu

        echo -ne "  ${BOLD}Enter option [0-11/q]: ${NC}"
        read -r choice

        case "${choice}" in
            [0-9]|1[01])
                echo ""
                if [[ "${choice}" == "0" ]]; then
                    install_all
                else
                    run_module "${choice}"
                fi
                echo ""
                echo -ne "  Press ${BOLD}Enter${NC} to continue..."
                read -r
                ;;
            q|Q)
                echo ""
                info "Exiting. Goodbye!"
                exit 0
                ;;
            *)
                warn "Invalid option: ${choice}"
                sleep 1
                ;;
        esac
    done
}

main "$@"
