#!/bin/bash
set -euo pipefail

# ==================================================
# Project: VPS Initialization & Optimization Script
# Author:  AzurePath749
# Version: 2.0 (Stable)
# Description: 一键优化 VPS 小主机 (512MB~2GB RAM / 低核 CPU)
#              为 OpenVPN / OpenClash 安装做准备
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
SYSCTL_CONF="/etc/sysctl.d/99-vps-optimize.conf"

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
    if [[ -f /swapfile ]] && ! grep -q '/swapfile' /proc/swaps 2>/dev/null; then
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
    if [[ -f /etc/debian_version ]]; then
        while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
            echo -ne "${YELLOW}检测到 apt 进程被占用，正在等待释放... [$i s]\r${PLAIN}"
            sleep 1
            i=$((i + 1))
            [[ $i -gt 300 ]] && { echo ""; log_error "等待超时(5分钟)，请手动检查 apt 进程"; exit 1; }
        done
        [[ $i -gt 0 ]] && echo ""
    elif [[ -f /etc/redhat-release ]]; then
        while [[ -f /var/run/yum.pid ]] || [[ -f /var/run/dnf.pid ]]; do
            echo -ne "${YELLOW}检测到 yum 进程被占用，正在等待释放... [$i s]\r${PLAIN}"
            sleep 1
            i=$((i + 1))
            [[ $i -gt 300 ]] && { echo ""; log_error "等待超时(5分钟)，请手动检查 yum 进程"; exit 1; }
        done
        [[ $i -gt 0 ]] && echo ""
    fi
}

# =====================================================
# 1. 系统更新与基础工具安装 (含 VPN 依赖)
# =====================================================

# 逐个安装包，单个失败不阻塞其他包
install_packages() {
    local pkg_manager="$1"
    shift
    for pkg in "$@"; do
        case "$pkg_manager" in
            apt)  apt-get install -y "$pkg" 2>/dev/null || log_warn "包 $pkg 安装失败，跳过" ;;
            dnf)  dnf install -y "$pkg" 2>/dev/null || log_warn "包 $pkg 安装失败，跳过" ;;
            yum)  yum install -y "$pkg" 2>/dev/null || log_warn "包 $pkg 安装失败，跳过" ;;
            apk)  apk add "$pkg" 2>/dev/null || log_warn "包 $pkg 安装失败，跳过" ;;
        esac
    done
}

update_system() {
    log_info "检查系统状态..."
    wait_for_lock

    log_info "正在更新系统软件包..."
    if [ -f /etc/debian_version ]; then
        export DEBIAN_FRONTEND=noninteractive
        # 预置 iptables-persistent 的 debconf 答案，防止交互提示
        echo "iptables-persistent iptables-persistent/autosave boolean true" | debconf-set-selections 2>/dev/null || true
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null || true
        apt-get update -y && apt-get upgrade -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold"

        log_info "安装基础工具..."
        install_packages apt curl wget vim git unzip htop ca-certificates psmisc
        log_info "安装 VPN 可选依赖..."
        install_packages apt iptables-persistent net-tools socat qrencode

    elif [ -f /etc/redhat-release ]; then
        if command -v dnf &>/dev/null; then
            dnf update -y
            log_info "安装基础工具..."
            install_packages dnf curl wget vim git unzip htop ca-certificates psmisc
            log_info "安装 VPN 可选依赖..."
            install_packages dnf iptables-services net-tools socat qrencode
        elif command -v yum &>/dev/null; then
            yum install -y epel-release 2>/dev/null || true
            yum update -y
            log_info "安装基础工具..."
            install_packages yum curl wget vim git unzip htop ca-certificates psmisc
            log_info "安装 VPN 可选依赖..."
            install_packages yum iptables-services net-tools socat qrencode
        else
            log_error "未找到包管理器 (dnf/yum)"
            return 1
        fi

    elif [ -f /etc/alpine-release ] || grep -q '^ID=alpine' /etc/os-release 2>/dev/null; then
        apk update && apk upgrade
        log_info "安装基础工具..."
        install_packages apk curl wget vim git unzip htop ca-certificates psmisc
        log_info "安装 VPN 可选依赖..."
        install_packages apk iptables net-tools socat qrencode
    else
        log_error "不支持的操作系统，仅支持 Debian/Ubuntu/CentOS/RHEL/Fedora/Alpine"
        return 1
    fi
    log_success "系统更新完成，基础工具和 VPN 依赖已安装。"
}

# =====================================================
# 2. 设置时区 (支持参数)
# =====================================================
set_timezone() {
    local tz="${1:-$TIMEZONE}"

    # 校验：时区名不能为空，且对应文件必须存在
    if [[ -z "$tz" ]]; then
        log_error "时区不能为空"
        return 1
    fi
    if [[ ! -f "/usr/share/zoneinfo/$tz" ]]; then
        log_error "无效时区: $tz (找不到 /usr/share/zoneinfo/$tz)"
        return 1
    fi

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

# =====================================================
# 3. 增加 Swap 虚拟内存 (自适应大小，针对小内存优化)
# =====================================================
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
    if [[ -n "$swap_size" && ! "$swap_size" =~ ^[0-9]+$ ]]; then
        log_error "SWAP_SIZE 环境变量非法: '$swap_size'，必须是正整数"
        return 1
    fi
    if [[ -z "$swap_size" ]]; then
        if [ "$mem_total" -le 512 ]; then
            swap_size=2048
        elif [ "$mem_total" -le 1024 ]; then
            swap_size=$((mem_total * 2))
        elif [ "$mem_total" -le 2048 ]; then
            swap_size=$mem_total
        elif [ "$mem_total" -lt 4096 ]; then
            swap_size=1024
        else
            swap_size=512
        fi
    fi
    if [[ "$swap_size" -lt 1 ]]; then
        swap_size=1024
    fi
    # 512MB~2GB 小机器: swap 上限 4096MB，防止小磁盘被撑满
    if [[ "$swap_size" -gt 4096 ]]; then
        swap_size=4096
    fi

    local required=$((swap_size + 300))
    if [ "$disk_avail" -lt "$required" ]; then
        log_error "磁盘空间不足 (剩余 ${disk_avail}MB，需要 ${required}MB)，跳过创建 Swap。"
        return 1
    fi

    log_info "正在创建 ${swap_size}MB 虚拟内存..."
    # 安全: 使用 install 直接以 600 权限创建，避免 touch+chmod 之间的权限窗口
    # 同时确保 /swapfile 不是符号链接 (防止 symlink 攻击)
    if [[ -L /swapfile ]]; then
        log_error "/swapfile 是符号链接，疑似安全风险，拒绝操作。"
        return 1
    fi
    install -m 600 /dev/null /swapfile

    if dd --help 2>&1 | grep -q 'status=progress'; then
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_size" status=progress
    else
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_size"
    fi

    mkswap /swapfile || { log_error "mkswap 失败"; rm -f /swapfile; return 1; }
    swapon /swapfile || { log_error "swapon 失败"; rm -f /swapfile; return 1; }

    if ! grep -q '^/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    log_success "Swap 创建成功 (${swap_size}MB)。"
}

# =====================================================
# 4. 内核参数全面调优 (内存/网络/连接/VPN)
# =====================================================
optimize_kernel() {
    log_info "正在配置内核优化参数 (512MB~2GB RAM / VPN)..."

    # 检查内核版本，BBR 需要 >= 4.9
    local kv_major=0 kv_minor=0
    kv_major=$(uname -r | cut -d. -f1)
    kv_minor=$(uname -r | cut -d. -f2)
    if [[ $kv_major -lt 4 ]] || { [[ $kv_major -eq 4 ]] && [[ $kv_minor -lt 9 ]]; }; then
        log_warn "内核版本 $(uname -r) 低于 4.9，BBR 不可用，其余参数仍会优化。"
    fi

    # 清理旧的独立 BBR 配置 (已合并到统一文件)
    if [[ -f /etc/sysctl.d/99-bbr.conf ]]; then
        rm -f /etc/sysctl.d/99-bbr.conf
        log_info "已清理旧的 BBR 配置文件。"
    fi

    # 加载 BBR 内核模块 (需在写入 sysctl 配置前完成)
    if modprobe tcp_bbr 2>/dev/null; then
        log_info "tcp_bbr 模块已加载。"
    else
        log_warn "tcp_bbr 模块加载失败 (可能已内置或内核不支持)，继续..."
    fi

    # 备份
    [ ! -f /etc/sysctl.conf.bak ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak 2>/dev/null || true

    mkdir -p /etc/sysctl.d
    cat > "$SYSCTL_CONF" << 'EOF'
# ==================================================
# VPS 小主机优化 (512MB~2GB RAM / VPN 预配置)
# ==================================================

# --- 内存优化 (针对 512MB~2GB) ---
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.min_free_kbytes=16384

# --- 文件描述符 ---
fs.file-max=65535

# --- 网络 Socket 缓冲 (VPN 吞吐量) ---
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=5000
net.core.somaxconn=32768

# --- TCP 连接优化 ---
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_fastopen=3

# --- BBR 拥塞控制 ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# --- IP 转发 (OpenVPN / OpenClash 必须) ---
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# --- 连接跟踪 (NAT / VPN) ---
net.netfilter.nf_conntrack_max=65535
net.netfilter.nf_conntrack_tcp_timeout_established=7200

# --- 安全加固 ---
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.rp_filter=1
EOF

    # 应用配置
    if sysctl --system 2>/dev/null; then
        log_success "内核参数已优化并生效。"
    elif sysctl -p "$SYSCTL_CONF" 2>/dev/null; then
        log_success "内核参数已优化 (直接加载)。"
    else
        log_warn "部分内核参数应用失败 (可能在容器中)，但不影响使用。"
    fi
}

# =====================================================
# 5. 系统限制优化 (ulimit / journald)
# =====================================================
optimize_limits() {
    log_info "正在优化系统资源限制 (ulimit)..."

    mkdir -p /etc/security/limits.d
    cat > /etc/security/limits.d/99-vps.conf << 'EOF'
# VPS 优化 - 文件描述符上限
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

    log_success "ulimit 已优化 (nofile=65535)，新会话生效。"
}

optimize_journald() {
    log_info "正在限制 systemd-journald 内存占用..."

    if ! command -v systemctl &>/dev/null; then
        log_warn "systemctl 不可用 (可能在容器中)，跳过 journald 优化。"
        return 0
    fi

    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-vps.conf << 'EOF'
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=30M
EOF

    systemctl restart systemd-journald 2>/dev/null || true
    log_success "journald 已限制 (最大 50MB)。"
}

# =====================================================
# 6. CPU 性能模式
# =====================================================
optimize_cpu() {
    log_info "正在设置 CPU 性能模式..."

    local governor_dir="/sys/devices/system/cpu/cpu0/cpufreq"
    if [[ -f "$governor_dir/scaling_available_governors" ]]; then
        if grep -q 'performance' "$governor_dir/scaling_available_governors"; then
            for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                echo performance > "$cpu" 2>/dev/null || true
            done
            log_success "CPU governor 已设置为 performance。"
        else
            log_warn "当前内核不支持 performance 模式，跳过。"
        fi
    else
        log_warn "无法访问 CPU 调度信息 (可能在虚拟化/容器中)，跳过。"
    fi
}

# =====================================================
# 7. 全部执行 (容错模式)
# =====================================================
run_all() {
    local failed=0

    echo ""
    show_system_info
    echo ""
    echo -e "${GREEN}=========================================="
    echo -e "  开始一键优化..."
    echo -e "==========================================${PLAIN}"
    echo ""

    update_system     || { log_error "系统更新失败"; failed=1; }
    set_timezone      || { log_error "时区设置失败"; failed=1; }
    add_swap          || { log_error "Swap 创建失败"; failed=1; }
    optimize_kernel   || { log_error "内核参数优化失败"; failed=1; }
    optimize_limits   || { log_error "ulimit 优化失败"; failed=1; }
    optimize_journald || { log_error "journald 优化失败"; failed=1; }
    optimize_cpu      || { log_error "CPU 优化失败"; failed=1; }

    echo ""
    echo -e "${GREEN}=========================================="
    echo -e "  优化完成!"
    echo -e "==========================================${PLAIN}"
    echo ""

    if [ $failed -eq 0 ]; then
        log_success "所有优化步骤已完成！建议重启服务器: reboot"
    else
        log_warn "部分步骤执行失败，请检查上方日志。"
    fi

    echo ""
    log_info "优化概要:"
    echo "  - IP 转发: $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"
    echo "  - BBR:     $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    echo "  - Swap:    $(free -m | awk '/Swap:/{print $2}') MB"
    echo "  - 文件描述符上限: $(cat /proc/sys/fs/file-max 2>/dev/null || echo '?')"
    echo ""

    return $failed
}

# =====================================================
# 8. 系统检测与主机信息
# =====================================================

# 获取操作系统名称
detect_os() {
    if [ -f /etc/os-release ]; then
        # 优先 PRETTY_NAME，覆盖绝大部分发行版
        grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 && return
    fi
    if [ -f /etc/debian_version ]; then
        echo "Debian $(cat /etc/debian_version)" && return
    fi
    if [ -f /etc/redhat-release ]; then
        cat /etc/redhat-release && return
    fi
    if [ -f /etc/alpine-release ]; then
        echo "Alpine $(cat /etc/alpine-release)" && return
    fi
    # 最后回退到 uname
    uname -s -r
}

# 获取公网 IP (IPv4)
get_public_ip() {
    local ip=""
    # 依次尝试多个 API，适配全球不同网络环境
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipv4.icanhazip.com" "https://checkip.amazonaws.com"; do
        ip=$(curl -s4 --connect-timeout 3 --max-time 5 "$url" 2>/dev/null) && break
    done
    # 校验：必须是合法 IPv4 格式
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
    else
        echo "N/A"
    fi
}

# 获取虚拟化类型
detect_virt() {
    local virt=""
    if command -v systemd-detect-virt &>/dev/null; then
        virt=$(systemd-detect-virt 2>/dev/null)
    fi
    if [[ -z "$virt" || "$virt" == "none" ]]; then
        # 尝试从 /proc/cpuinfo 或 DMI 获取
        if [[ -f /sys/class/dmi/id/product_name ]]; then
            virt=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
        fi
    fi
    echo "${virt:-Unknown}"
}

# 显示完整系统信息
show_system_info() {
    local os_name kernel cpu_model cpu_cores mem_total mem_used mem_free
    local disk_total disk_used swap_total swap_used pub_ip hostname_val arch virt load uptime_str

    os_name=$(detect_os)
    kernel=$(uname -r)
    hostname_val=$(hostname 2>/dev/null || echo "N/A")
    arch=$(uname -m)

    # CPU
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | xargs || echo "N/A")
    [[ "$cpu_model" == "N/A" ]] && cpu_model=$(grep -m1 'Hardware' /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | xargs || echo "N/A")
    cpu_cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "?")

    # 内存 (MB)
    mem_total=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%.0f", $2}') || mem_total=0
    mem_used=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%.0f", $3}') || mem_used=0
    mem_total=${mem_total:-0}
    mem_used=${mem_used:-0}
    mem_free=$((mem_total - mem_used))

    # 磁盘 (GB)
    disk_total=$(df -h / 2>/dev/null | awk 'NR==2{print $2}') || disk_total="N/A"
    disk_used=$(df -h / 2>/dev/null | awk 'NR==2{print $3}') || disk_used="N/A"

    # Swap
    swap_total=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}') || swap_total=0
    swap_used=$(free -m 2>/dev/null | awk '/^Swap:/{print $3}') || swap_used=0
    swap_total=${swap_total:-0}
    swap_used=${swap_used:-0}

    # 虚拟化
    virt=$(detect_virt)

    # 公网 IP
    pub_ip=$(get_public_ip)

    # 负载
    load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}') || load="N/A"

    # 运行时间
    uptime_str=$(uptime -p 2>/dev/null || echo "N/A")

    echo -e "${GREEN}============================================"
    echo -e "    VPS 主机信息"
    echo -e "============================================${PLAIN}"
    echo -e "  主机名:   ${BLUE}$hostname_val${PLAIN}"
    echo -e "  系统:     ${BLUE}$os_name${PLAIN}"
    echo -e "  内核:     ${BLUE}$kernel${PLAIN}"
    echo -e "  架构:     ${BLUE}$arch${PLAIN}"
    echo -e "  虚拟化:   ${BLUE}$virt${PLAIN}"
    echo -e "  公网 IP:  ${BLUE}$pub_ip${PLAIN}"
    echo -e "  CPU:      ${BLUE}$cpu_model ($cpu_cores 核)${PLAIN}"
    echo -e "  内存:     ${BLUE}${mem_used}MB / ${mem_total}MB${PLAIN}  (可用 ${mem_free}MB)"
    echo -e "  Swap:     ${BLUE}${swap_used}MB / ${swap_total}MB${PLAIN}"
    echo -e "  磁盘(/):  ${BLUE}$disk_used / $disk_total${PLAIN}"
    echo -e "  负载:     ${BLUE}$load${PLAIN}"
    echo -e "  运行时间: ${BLUE}$uptime_str${PLAIN}"
    echo -e "${GREEN}============================================${PLAIN}"
}

# =====================================================
# 9. 交互菜单
# =====================================================
main_menu() {
    while true; do
        clear
        show_system_info
        echo ""
        echo -e "################################################"
        echo -e "#   VPS 小主机一键优化脚本 (512MB~2GB)          #"
        echo -e "#   Author:  AzurePath749                      #"
        echo -e "#   Version: 2.0 (Stable)                      #"
        echo -e "#   Target: OpenVPN / OpenClash 准备           #"
        echo -e "################################################"
        echo -e " 1. 一键全部优化 (推荐)"
        echo -e " 2. 仅系统更新 + VPN 依赖安装"
        echo -e " 3. 仅开启 BBR + 内核/网络/VPN调优"
        echo -e " 4. 仅配置 Swap (自适应)"
        echo -e " 5. 仅修改时区 ($TIMEZONE)"
        echo -e " 6. 仅优化系统限制 (ulimit/journald)"
        echo -e " 0. 退出"
        echo -e "################################################"

        read -rp "请选择 [0-6]: " choice || true
        choice="${choice// /}"
        case "$choice" in
            1) run_all || true ;;
            2) update_system || true ;;
            3) optimize_kernel || true ;;
            4) add_swap || true ;;
            5) set_timezone || true ;;
            6) optimize_limits || true; optimize_journald || true ;;
            0) exit 0 ;;
            *) log_error "无效选择，请重新输入" ;;
        esac
        echo ""
        read -rp "按回车键继续..." || true
    done
}

usage() {
    cat << 'USAGE'
Usage: vps_init.sh [OPTIONS]

Options:
  无参数            进入交互菜单
  --all            一键全部优化（跳过菜单，直接执行）
  --swap [SIZE_MB] 仅配置 Swap (默认: 自适应内存大小)
  --timezone [TZ]  设置时区 (默认: Asia/Shanghai)
  -h, --help       显示帮助信息

环境变量:
  TIMEZONE             设置默认时区 (默认: Asia/Shanghai)
  SWAP_SIZE            设置 Swap 大小 MB (默认: 自适应)

示例:
  ./vps_init.sh            # 进入交互菜单
  ./vps_init.sh --all      # 一键全部优化
  ./vps_init.sh --swap 2048
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
        --swap)
            shift
            if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
                SWAP_SIZE="$1"
                shift
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
