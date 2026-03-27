#!/bin/bash
set -euo pipefail

# ==================================================
# Project: VPS Initialization & Hardening Script
# Author:  AzurePath749
# Version: 1.3 (Robust & Idempotent)
# Description: One-click setup for new VPS (Update, BBR, Swap, Timezone)
# ==================================================

# --- 颜色配置 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# --- 全局变量 ---
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
SWAP_SIZE="${SWAP_SIZE:-}"

# --- 辅助函数 ---
log_info()    { echo -e "${BLUE}[INFO]${PLAIN} ${*:-}"; }
log_success() { echo -e "${GREEN}[OK]${PLAIN} ${*:-}"; }
log_error()   { echo -e "${RED}[ERROR]${PLAIN} ${*:-}"; }
log_warn()    { echo -e "${YELLOW}[WARN]${PLAIN} ${*:-}"; }

# --- 信号处理 ---
cleanup() {
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        return 0
    fi
    if [[ $exit_code -gt 128 ]]; then
        log_warn "检测到中断信号 (code: $exit_code)，正在清理..."
    else
        log_warn "脚本异常退出 (code: $exit_code)，正在清理..."
    fi
    if [[ -f /swapfile ]] && ! swapon --show=NAME 2>/dev/null | grep -q '^/swapfile'; then
        log_warn "清理未完成的 swap 文件..."
        rm -f /swapfile
    fi
}
trap cleanup EXIT INT TERM

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限运行"
        exit 1
    fi
}

# 智能等待包管理器锁释放 (防止 apt/yum 被占用报错)
wait_for_lock() {
    local i=0
    if [ -f /etc/debian_version ]; then
        while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
            echo -ne "${YELLOW}检测到 apt 进程被占用，正在等待释放... [$i s]\r${PLAIN}"
            sleep 1
            i=$((i + 1))
            [ $i -gt 300 ] && { echo ""; log_error "等待超时(5分钟)，请手动检查 apt 进程"; exit 1; }
        done
        [ $i -gt 0 ] && echo ""
    elif [ -f /etc/redhat-release ]; then
        while [ -f /var/run/yum.pid ]; do
            echo -ne "${YELLOW}检测到 yum 进程被占用，正在等待释放... [$i s]\r${PLAIN}"
            sleep 1
            i=$((i + 1))
            [ $i -gt 300 ] && { echo ""; log_error "等待超时(5分钟)，请手动检查 yum 进程"; exit 1; }
        done
        [ $i -gt 0 ] && echo ""
    fi
}

# 1. 系统更新与基础工具安装
update_system() {
    log_info "检查系统状态..."
    wait_for_lock

    log_info "正在更新系统软件包..."
    if [ -f /etc/debian_version ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y && apt-get upgrade -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold"
        log_info "安装基础工具 (curl, wget, vim, git, unzip, htop, fuser)..."
        apt-get install -y curl wget vim git unzip htop ca-certificates psmisc
    elif [ -f /etc/redhat-release ]; then
        if command -v dnf &>/dev/null; then
            dnf update -y
            dnf install -y curl wget vim git unzip htop ca-certificates psmisc
        elif command -v yum &>/dev/null; then
            yum update -y
            yum install -y epel-release
            yum install -y curl wget vim git unzip htop ca-certificates psmisc
        else
            log_error "未找到包管理器 (dnf/yum)"
            return 1
        fi
    elif [ -f /etc/alpine-release ] || grep -q '^ID=alpine' /etc/os-release 2>/dev/null; then
        apk update && apk upgrade
        apk add curl wget vim git unzip htop ca-certificates psmisc
    else
        log_error "不支持的操作系统，仅支持 Debian/Ubuntu/CentOS/RHEL/Fedora/Alpine"
        return 1
    fi
    log_success "系统更新完成，基础工具已安装。"
}

# 2. 设置时区 (支持参数)
set_timezone() {
    local tz="${1:-$TIMEZONE}"
    local current_tz=""
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null) || true

    if [ "$current_tz" = "$tz" ]; then
        log_success "时区已是 $tz，跳过。"
        return 0
    fi

    log_info "设置时区为 $tz..."
    if ! timedatectl set-timezone "$tz" 2>/dev/null; then
        log_warn "timedatectl 不可用 (可能在容器中)，使用 ln -sf 回退..."
        ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
    fi
    log_success "当前时间: $(date)"
}

# 3. 开启 BBR (原生方式, drop-in 文件)
enable_bbr() {
    log_info "正在检查/开启 BBR 加速..."

    local kernel_version=""
    kernel_version=$(uname -r | grep -oE '^[0-9]+\.[0-9]+') || true

    if [[ -n "$kernel_version" ]]; then
        local major minor
        major=$(echo "$kernel_version" | cut -d. -f1)
        minor=$(echo "$kernel_version" | cut -d. -f2)
        if [[ $major -lt 4 ]] || { [[ $major -eq 4 ]] && [[ $minor -lt 9 ]]; }; then
            log_error "内核版本 $(uname -r) 低于 4.9，不支持 BBR"
            return 1
        fi
    fi

    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        log_success "BBR 已经开启并生效，跳过。"
        return 0
    fi

    [ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak 2>/dev/null || true

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    local sysctl_output=""
    if sysctl_output=$(sysctl --system 2>&1); then
        log_success "BBR 已开启。"
    else
        if ! sysctl_output=$(sysctl -p /etc/sysctl.d/99-bbr.conf 2>&1); then
            log_error "sysctl 配置应用失败:"
            echo "$sysctl_output"
            return 1
        fi
        log_success "BBR 已开启 (通过直接加载)。"
    fi
}

# 4. 增加 Swap 虚拟内存 (自适应大小)
add_swap() {
    log_info "检查 Swap 内存..."

    local swap_total=""
    swap_total=$(free -m | grep Swap | awk '{print $2}') || swap_total=0
    swap_total=${swap_total:-0}

    if [ "$swap_total" -gt 0 ]; then
        log_success "系统已存在 Swap ($swap_total MB)，跳过创建。"
        return 0
    fi

    if [ -f /swapfile ]; then
        log_warn "检测到 /swapfile 文件存在但未挂载，尝试重新挂载..."
        if swapon /swapfile 2>/dev/null; then
            log_success "Swap 重新挂载成功。"
            return 0
        else
            log_warn "挂载失败，将尝试重新创建..."
            rm -f /swapfile
        fi
    fi

    local disk_avail=""
    disk_avail=$(df -m / | awk 'NR==2 {print $4}') || disk_avail=0
    disk_avail=${disk_avail:-0}

    local mem_total=""
    mem_total=$(free -m | awk '/^Mem:/{print $2}') || mem_total=0
    mem_total=${mem_total:-0}

    local swap_size="${SWAP_SIZE:-}"
    if [[ -z "$swap_size" ]]; then
        if [ "$mem_total" -lt 1024 ]; then
            swap_size=$((mem_total * 2))
        elif [ "$mem_total" -lt 4096 ]; then
            swap_size=$mem_total
        else
            swap_size=1024
        fi
    fi

    local required=$((swap_size + 500))
    if [ "$disk_avail" -lt "$required" ]; then
        log_error "磁盘空间不足 (剩余 ${disk_avail}MB，需要 ${required}MB)，跳过创建 Swap。"
        return 1
    fi

    log_info "正在创建 ${swap_size}MB 虚拟内存..."
    touch /swapfile && chmod 600 /swapfile

    if dd --help 2>&1 | grep -q 'status=progress'; then
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_size" status=progress
    else
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_size"
    fi

    mkswap /swapfile
    swapon /swapfile

    if ! grep -q '^/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    log_success "Swap 创建成功 (${swap_size}MB)。"
}

# 5. 全部执行 (容错模式，单个步骤失败不中断)
run_all() {
    local failed=0
    update_system || { log_error "系统更新失败"; failed=1; }
    set_timezone || { log_error "时区设置失败"; failed=1; }
    enable_bbr || { log_error "BBR 启用失败"; failed=1; }
    add_swap || { log_error "Swap 创建失败"; failed=1; }
    if [ $failed -eq 0 ]; then
        log_success "所有初始化步骤已完成！建议重启服务器: reboot"
    else
        log_warn "部分步骤执行失败，请检查上方日志。"
    fi
    return $failed
}

# 6. 交互菜单
main_menu() {
    clear
    echo -e "################################################"
    echo -e "#     VPS 一键初始化脚本 (System Init)         #"
    echo -e "#     Author: AzurePath749                     #"
    echo -e "#     Version: 1.3 (Stable)                    #"
    echo -e "################################################"
    echo -e "1. 全自动初始化 (推荐，含所有优化)"
    echo -e "2. 单独开启 BBR"
    echo -e "3. 单独增加 Swap (自适应)"
    echo -e "4. 单独修改时区 ($TIMEZONE)"
    echo -e "5. 系统更新 (Update & Upgrade)"
    echo -e "0. 退出"
    echo -e "################################################"

    read -rp "请选择 [0-5]: " choice || true
    case "$choice" in
        1) run_all ;;
        2) enable_bbr ;;
        3) add_swap ;;
        4) set_timezone ;;
        5) update_system ;;
        0) exit 0 ;;
        *) log_error "无效选择"; exit 1 ;;
    esac
}

usage() {
    cat << 'USAGE'
Usage: vps_init.sh [OPTIONS]

Options:
  --all                全自动初始化 (含所有优化)
  --bbr                单独开启 BBR
  --swap [SIZE_MB]     单独增加 Swap (默认: 自适应内存大小)
  --timezone [TZ]      设置时区 (默认: Asia/Shanghai)
  --update             系统更新
  -h, --help           显示帮助信息

不带参数时进入交互菜单。

环境变量:
  TIMEZONE             设置默认时区 (默认: Asia/Shanghai)
  SWAP_SIZE            设置 Swap 大小 MB (默认: 自适应)

示例:
  ./vps_init.sh --all
  ./vps_init.sh --bbr --swap 2048
  ./vps_init.sh --timezone America/New_York
USAGE
}

# --- 主入口 ---
check_root

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            run_all; exit $?
            ;;
        --bbr)
            enable_bbr; exit $?
            ;;
        --swap)
            shift
            if [[ $# -gt 0 && "${1:-}" != -* ]]; then
                SWAP_SIZE="$1"
            fi
            add_swap; exit $?
            ;;
        --timezone)
            shift
            if [[ $# -gt 0 && "${1:-}" != -* ]]; then
                TIMEZONE="$1"
            fi
            set_timezone "$TIMEZONE"; exit $?
            ;;
        --update)
            update_system; exit $?
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "未知参数: $1"
            usage
            exit 1
            ;;
    esac
done

main_menu
