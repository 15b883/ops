#!/bin/bash

# =================================================================
# 功能：开启 TCP BBR 拥塞控制 + 安装 Docker CE
# 适配：Debian / Ubuntu
# 用法：sudo bash setup_bbr_docker.sh
# =================================================================

set -euo pipefail

# ── 颜色输出 ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── 前置检查 ──────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "请以 root 权限运行（sudo bash $0）"

# 验证发行版（仅支持 Debian/Ubuntu）
[[ -f /etc/os-release ]] || error "无法读取 /etc/os-release，不支持的发行版"
# shellcheck source=/dev/null
source /etc/os-release
[[ "${ID}" =~ ^(ubuntu|debian)$ ]] || error "不支持的发行版: ${ID}，仅支持 ubuntu/debian"

# Ubuntu 24.04+ 新增 UBUNTU_CODENAME 字段，优先使用它；Debian 及旧版 Ubuntu 回退到 VERSION_CODENAME
OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
[[ -n "${OS_CODENAME}" ]] || error "无法获取发行版代号（UBUNTU_CODENAME 与 VERSION_CODENAME 均为空）"
info "检测到系统: ${ID} ${VERSION_ID} (${OS_CODENAME})"

# ── 1. 开启 TCP BBR ───────────────────────────────────────────────
info "==> 1. 检查并开启 TCP BBR..."

# 内核版本检查（需 >= 4.9）
kernel_major=$(uname -r | cut -d. -f1)
kernel_minor=$(uname -r | cut -d. -f2)
if (( kernel_major < 4 || ( kernel_major == 4 && kernel_minor < 9 ) )); then
    error "内核版本 $(uname -r) 过低，BBR 需要 >= 4.9"
fi

# 检查 BBR 模块是否可用
if ! modinfo tcp_bbr &>/dev/null; then
    warn "tcp_bbr 模块不存在，尝试加载..."
    modprobe tcp_bbr || error "无法加载 tcp_bbr 模块"
fi

# 幂等写入 sysctl 配置（避免重复追加）
set_sysctl() {
    local key="$1" value="$2" file="/etc/sysctl.d/99-bbr.conf"
    # 优先写入独立配置文件，避免污染 /etc/sysctl.conf
    touch "$file"
    if grep -q "^${key}\s*=" "$file" 2>/dev/null; then
        sed -i "s|^${key}\s*=.*|${key} = ${value}|" "$file"
    else
        echo "${key} = ${value}" >> "$file"
    fi
}

set_sysctl "net.core.default_qdisc"        "fq"
set_sysctl "net.ipv4.tcp_congestion_control" "bbr"

sysctl --system > /dev/null 2>&1   # 加载 /etc/sysctl.d/*.conf

# 验证
current_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
if [[ "$current_cc" == "bbr" ]]; then
    info "BBR 已成功激活（当前拥塞控制: $current_cc）"
else
    error "BBR 未能激活，当前拥塞控制: $current_cc"
fi

# ── 2. 安装 Docker CE ─────────────────────────────────────────────
info "==> 2. 安装 Docker CE..."

# 若 Docker 已安装则跳过（幂等）
if command -v docker &>/dev/null; then
    warn "Docker 已安装（$(docker --version)），跳过安装步骤"
else
    # 安装基础依赖（bc 不再需要）
    apt-get update -qq
    apt-get install -y --no-install-recommends ca-certificates curl gnupg

    # 配置 GPG 密钥
    KEYRING_DIR="/etc/apt/keyrings"
    KEYRING_FILE="${KEYRING_DIR}/docker.gpg"
    install -m 0755 -d "$KEYRING_DIR"

    # 幂等：覆盖已有密钥文件
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        | gpg --dearmor --yes -o "$KEYRING_FILE"
    chmod a+r "$KEYRING_FILE"

    # 配置软件源（OS_CODENAME 兼容 Ubuntu 24.04+ 的 UBUNTU_CODENAME 字段）
    ARCH=$(dpkg --print-architecture)
    echo "deb [arch=${ARCH} signed-by=${KEYRING_FILE}] \
https://download.docker.com/linux/${ID} ${OS_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    # 安装 Docker 组件
    apt-get update -qq
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    # 启用并启动服务
    systemctl enable --now docker
    info "Docker 安装完成：$(docker --version)"
fi

# ── 完成 ──────────────────────────────────────────────────────────
info "==> 所有任务已完成！"
info "BBR:    $(sysctl -n net.ipv4.tcp_congestion_control)"
info "Docker: $(docker --version)"
