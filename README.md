# VPS 小主机一键优化脚本

专门为 **512MB~2GB** 内存小型 VPS 优化的初始化脚本。
为后续安装 **OpenVPN** / **OpenClash** 做系统级准备。

## 功能

### 系统检测 (首页展示)
- 自动检测并显示：操作系统、内核、CPU、内存、Swap、磁盘、公网 IP、虚拟化类型、负载
- 兼容 Debian / Ubuntu / CentOS / RHEL / Fedora / Alpine 等主流发行版

### 一键优化 (7 大模块)

| 模块 | 说明 |
|------|------|
| **系统更新** | 更新软件包 + 安装基础工具和 VPN 依赖 (`iptables`, `socat`, `qrencode` 等) |
| **时区设置** | 默认 `Asia/Shanghai` |
| **Swap 虚拟内存** | 自适应大小（512MB → 2GB / 1GB → 2GB / 2GB → 2GB），最大 4GB，防止 OOM |
| **内核参数调优** | vm.swappiness / vfs_cache_pressure / TCP 缓冲 / BBR / IP 转发 / 连接跟踪 |
| **ulimit 优化** | 文件描述符上限提升至 65535 |
| **journald 限制** | 日志最大 50MB，节省磁盘 |
| **CPU 性能模式** | 设置 governor 为 performance |

### 为 OpenVPN / OpenClash 的准备项
- `net.ipv4.ip_forward=1` / `net.ipv6.conf.all.forwarding=1` — IP 转发
- `net.netfilter.nf_conntrack_max=65535` — NAT 连接跟踪
- Socket 缓冲区 16MB — 提升 VPN 吞吐量
- TCP Fast Open / BBR — 加速网络
- 端口范围扩展 `1024-65535`
- 预装 `iptables-persistent`, `socat`, `qrencode` 等 VPN 工具

## 使用方法

```bash
bash <(curl -sL https://raw.githubusercontent.com/AzurePath749/vps_init/main/vps_init.sh)
```

进入后选择 `1` 一键全部优化，或按需选择单项操作。

## CLI 参数

```
无参数            进入交互菜单
--all            一键全部优化（跳过菜单，直接执行）
--swap [SIZE_MB] 仅配置 Swap
--timezone [TZ]  设置时区 (默认 Asia/Shanghai)
-h, --help       显示帮助
```

## 环境变量

```
TIMEZONE=Asia/Shanghai    默认时区
SWAP_SIZE=2048            指定 Swap 大小 (MB)
```

## 兼容系统

- Debian 9+
- Ubuntu 16.04+
- CentOS 7/8/9
- RHEL / Fedora
- Alpine Linux
- 其他使用 apt / dnf / yum / apk 的发行版

## 优化效果参考 (512MB~2GB VPS)

```
512MB:  分配 2GB Swap，min_free_kbytes=16MB (防止极低内存崩溃)
1GB:    分配 2GB Swap，swappiness=10 (优先用 RAM)
2GB:    分配 2GB Swap，65535 连接跟踪，IP 转发就绪
```
