#!/bin/bash

# ==================================================
# Project: VPS Initialization & Hardening Script
# Author:  AzurePath749
# Version: 1.2 (Robust & Idempotent)
# Description: One-click setup for new VPS (Update, BBR, Swap, Timezone)
# ==================================================

# --- 颜色配置 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# --- 辅助函数 ---
log_info() { echo -e "${BLUE}[INFO]${PLAIN} $1"; }
log_success() { echo -e "${GREEN}[OK]${PLAIN} $1"; }
log_error() { echo -e "${RED}[ERROR]${PLAIN} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }

check_root() {
    [[ $EUID -ne 0 ]] && { log_error "请使用 root 权限运行"; exit 1; }
}

# 智能等待包管理器锁释放 (防止 apt/yum 被占用报错)
wait_for_lock() {
    local i=0
    if [ -f /etc/debian_version ]; then
        while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
            echo -ne "${YELLOW}检测到 apt 进程被占用，正在等待释放... [$i s]\r${PLAIN}"
            sleep 1
            ((i++))
            [ $i -gt 300 ] && { echo ""; log_error "等待超时(5分钟)，请手动检查 apt 进程"; exit 1; }
        done
        [ $i -gt 0 ] && echo ""
    elif [ -f /etc/redhat-release ]; then
        while [ -f /var/run/yum.pid ]; do
            echo -ne "${YELLOW}检测到 yum 进程被占用，正在等待释放... [$i s]\r${PLAIN}"
            sleep 1
            ((i++))
            [ $i -gt 300 ] && { echo ""; log_error "等待超时(5分钟)，请手动检查 yum 进程"; exit 1; }
        done
        [ $i -gt 0 ] && echo ""
    fi
}

# 1. 系统更新与基础工具安装
update_system() {
    log_info "检查系统状态..."
    wait_for_lock # 等待锁释放

    log_info "正在更新系统软件包..."
    if [ -f /etc/debian_version ]; then
        # 增加 DEBIAN_FRONTEND=noninteractive 防止弹窗卡住脚本
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y && apt-get upgrade -y
        log_info "安装基础工具 (curl, wget, vim, git, unzip, htop, fuser)..."
        apt-get install -y curl wget vim git unzip htop ca-certificates psmisc
    elif [ -f /etc/redhat-release ]; then
        yum update -y
        yum install -y epel-release
        yum install -y curl wget vim git unzip htop ca-certificates psmisc
    else
        log_error "不支持的操作系统，仅支持 Debian/Ubuntu/CentOS"
        return
    fi
    log_success "系统更新完成，基础工具已安装。"
}

# 2. 设置时区 (默认上海)
set_timezone() {
    CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null)
    if [ "$CURRENT_TZ" == "Asia/Shanghai" ]; then
        log_success "时区已是 Asia/Shanghai，跳过。"
    else
        log_info "设置时区为 Asia/Shanghai..."
        timedatectl set-timezone Asia/Shanghai
        log_success "当前时间: $(date)"
    fi
}

# 3. 开启 BBR (原生方式)
enable_bbr() {
    log_info "正在检查/开启 BBR 加速..."
    
    # 检查是否已经在运行 BBR
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        log_success "BBR 已经开启并生效，跳过。"
        return
    fi

    # 备份配置文件
    [ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak

    # 幂等性检查：防止重复写入
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    sysctl -p >/dev/null 2>&1
    log_success "BBR 已开启。"
}

# 4. 增加 Swap 虚拟内存 (防止小内存机器卡死)
add_swap() {
    log_info "检查 Swap 内存..."
    
    # 检查当前 Swap 大小
    SWAP_TOTAL=$(free -m | grep Swap | awk '{print $2}')
    
    # 如果已经有 Swap (大于 0)，则跳过
    if [ "$SWAP_TOTAL" -gt 0 ]; then
        log_success "系统已存在 Swap ($SWAP_TOTAL MB)，跳过创建。"
        return
    fi

    # 检查是否已存在 swapfile 文件 (防止重复创建)
    if [ -f /swapfile ]; then
        log_warn "检测到 /swapfile 文件存在但未挂载，尝试重新挂载..."
        swapon /swapfile 2>/dev/null
        if [ $? -eq 0 ]; then
            log_success "Swap 重新挂载成功。"
            return
        else
            log_warn "挂载失败，将尝试重新创建..."
            rm -f /swapfile
        fi
    fi

    # 检查磁盘空间是否足够 (至少需要 1.5GB 剩余才创建 1GB swap)
    DISK_AVAIL=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$DISK_AVAIL" -lt 1500 ]; then
        log_error "磁盘空间不足 (剩余 ${DISK_AVAIL}MB)，跳过创建 Swap。"
        return
    fi

    log_info "正在创建 1GB 虚拟内存..."
    dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    # 写入 fstab 前先检查是否存在，防止重复写入
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
    log_success "Swap 创建成功 (1GB)。"
}

# 5. 交互菜单
main_menu() {
    clear
    echo -e "################################################"
    echo -e "#     VPS 一键初始化脚本 (System Init)         #"
    echo -e "#     Author: AzurePath749                     #"
    echo -e "#     Version: 1.2 (Stable)                    #"
    echo -e "################################################"
    echo -e "1. 全自动初始化 (推荐，含所有优化)"
    echo -e "2. 单独开启 BBR"
    echo -e "3. 单独增加 Swap (1G)"
    echo -e "4. 单独修改时区 (CN)"
    echo -e "5. 系统更新 (Update & Upgrade)"
    echo -e "0. 退出"
    echo -e "################################################"
    
    read -p "请选择 [0-5]: " choice
    case $choice in
        1)
            update_system
            set_timezone
            enable_bbr
            add_swap
            log_success "所有初始化步骤已完成！建议重启服务器: reboot"
            ;;
        2) enable_bbr ;;
        3) add_swap ;;
        4) set_timezone ;;
        5) update_system ;;
        *) exit 0 ;;
    esac
}

check_root
main_menu
