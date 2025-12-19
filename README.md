# 🛠️ VPS 一键初始化脚本 (VPS Init Script)

买到新服务器不知道该干什么？这个脚本帮你一键完成所有“装修”工作。
特别适合 **512MB/1GB 小内存** VPS 的优化。

## ✨ 功能特点
1. **📦 系统更新**: 自动 `apt update` / `yum update` 并安装常用工具 (`vim`, `curl`, `git`, `htop` 等)。
2. **🚀 开启 BBR**: 自动修改内核参数开启 BBR 拥塞控制，提升网络速度。
3. **💾 自动 Swap**: 智能检测，如果没 Swap 自动创建 1GB 虚拟内存，**防止 Gost/SOCKS5 进程因内存不足被杀**。
4. **⏰ 修正时区**: 自动修改为 `Asia/Shanghai`，看日志不再头大。

## 📦 使用方法

```bash
bash <(curl -sL https://raw.githubusercontent.com/AzurePath749/socks5-installer/main/vps_init.sh)

## 💡 最佳实践
建议新机器拿到手后：
 先运行本脚本 (`vps_init.sh`) 进行初始化。

