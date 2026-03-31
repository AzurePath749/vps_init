# VPS 小主机一键优化脚本

专门为 **1GB 内存 / 双核 CPU** 小型 VPS 优化的初始化脚本。
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
| **Swap 虚拟内存** | 自适应大小（1GB RAM → 2GB Swap），防止 OOM |
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
# 一键全部优化 (推荐)
bash <(curl -sL https://raw.githubusercontent.com/AzurePath749/vps_init/main/vps_init.sh) --all

# 交互菜单 (查看主机信息 + 选择优化项)
bash <(curl -sL https://raw.githubusercontent.com/AzurePath749/vps_init/main/vps_init.sh)
```

## CLI 参数

```
--all                一键全部优化 (推荐)
--update             仅系统更新 + VPN 依赖安装
--swap [SIZE_MB]     仅配置 Swap (默认自适应)
--optimize           仅内核+内存+网络+限制优化
--timezone [TZ]      设置时区 (默认 Asia/Shanghai)
-h, --help           显示帮助
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

## 优化效果参考 (1GB RAM / 双核 VPS)

```
优化前:  OOM 频发, 网络抖动, VPN 连接数受限
优化后:  2GB Swap 保障, BBR+缓冲优化, 65535 连接跟踪, IP 转发就绪
```
