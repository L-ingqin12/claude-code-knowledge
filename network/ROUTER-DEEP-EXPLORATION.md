---
title: 路由器深度探索报告
tags: [network/router, network]
aliases: [路由器深度探索]
created: 2026-07-28
updated: 2026-08-25
status: stable
---

# 路由器深度探索报告 — Xiaomi R4CM 2.14.87

See also: [[Network-KB-Home]] | [[GUIDE]] | [[ROUTER-FULL-CAPABILITY]] | [[ROUTER-OPTIMIZATION]]

## 硬件规格

| 参数 | 值 |
|------|-----|
| 型号 | R4CM (小米路由器 4C) |
| SoC | MT7628AN (MIPS 24KEc V5.5, 575MHz) |
| RAM | 64MB DDR2 @ 800MHz |
| Flash | 16MB (SPI NOR) |
| WiFi | 2.4GHz only (MT7628 内置), 802.11bgn |
| 内核 | Linux 3.10.14 (2019-11-26) |
| 固件 | MiWiFi-R4CM-2.14.87 |

## Flash 分区布局

| 分区 | 大小 | 名称 | 用途 |
|------|------|------|------|
| mtd0 | 16MB | ALL | 全镜像 |
| mtd1 | 128KB | Bootloader | U-Boot |
| mtd2 | 64KB | Config | 配置 |
| mtd3 | 64KB | **Factory** | TX power校准/SN/MAC |
| mtd4 | 64KB | crash | 崩溃日志 |
| mtd5 | 64KB | cfg_bak | 配置备份 |
| mtd6 | 1MB | overlay | 持久化存储(/data) |
| mtd7 | 12.4MB | OS1 | 系统固件 |
| mtd8 | 10.9MB | rootfs | 根文件系统 |
| mtd9 | 2MB | disk | 用户数据(/data) |

## 运行进程

| 进程 | 用途 | 端口 |
|------|------|------|
| dropbear | SSH (LAN-only) | [IP已脱敏]:22 |
| dnsmasq | DNS/DHCP | 53 |
| sysapihttpd | Web API (nginx-based) | 80, 8899, 8999 + 15个后端端口 |
| himan | 小米 IoT 管理器 | 8080 |
| tbusd | 小米内部消息总线 | 784 |
| fcgi-cgi | FastCGI 后端 | 127.0.0.1:8920 |
| taskmonitor | 任务监控 | — |
| trafficd | 流量统计 | — |
| datacenter | 数据中心(遥测) | — |
| smartcontroller | 智能家居控制 | — |
| plugincenter | 插件中心 | — |
| messagingagent | 消息代理 | — |
| rmonitor | 远程监控 | — |
| crond | 定时任务 | — |
| iweventd | WiFi 事件监控 | — |
| mald | 恶意攻击检测 | — |
| btnd | 按钮守护进程 | — |
| netapi | 网络 API | — |

## Web API 端点 (Lua 控制器)

| 文件 | 功能 |
|------|------|
| xqsystem.lua | 系统(登录/信息/固件) |
| xqnetwork.lua | 网络设置(WiFi/WAN/LAN) |
| misystem.lua | 设备管理(设备列表/状态) |
| xqsmarthome.lua | 智能家居 |
| xqtunnel.lua | 隧道/代理 |
| xqdatacenter.lua | 数据遥测 |
| xqnetdetect.lua | 网络检测 |
| xqpassport.lua | 账户 |
| miats.lua | 防盗安全 |
| misns.lua | 社交网络服务 |
| cportal.lua | 强制门户 |

注意: Lua 源码已预编译为字节码，无法直接阅读。

## sysctl 关键内核参数

```
conntrack_max = 16384
tcp_keepalive_time = 60s
tcp_fin_timeout = 10s
tcp_tw_reuse = 1
tcp_mtu_probing = 1
tcp_ecn = 0
conntrack_tcp_timeout_established = 3600
```

## 可利用的机制

### 1. rc.local 持久化 (已验证)
```bash
# /etc/rc.local 在启动时执行，已配置:
/data/dropbear/dropbear -p [IP已脱敏]:22 &  # SSH
busybox telnetd -p 23 -l /bin/ash &            # Telnet (实际未生效)
```

### 2. iweventd WiFi 事件钩子
WiFi 状态变化时触发 `/data/etc/iwevent.d/*.sh`。可用于:
- WiFi reload 时自动重设 AP 隔离
- 设备连接/断开时执行自定义脚本

### 3. Factory 分区 (mtd3)

> [!warning] Factory 分区操作风险
> 
> 偏移 0xA0 处 14 字节为 TX power 校准值。修改为 FF 可解锁到 30dBm。
> 但当前 iwinfo 显示 Tx-Power: 18 dBm，可能已部分解锁。
> 
> **警告**: 修改 Factory 分区有砖机风险。务必先备份:
> 
> ```bash
> dd if=/dev/mtdblock3 of=/tmp/factory.bak bs=64k
> ```

### 4. Xiaomi smartvpn (已不可用)

> [!warning] SmartVPN 服务器已死
> 内置 VPN 代理功能，type=vpn, 出口 IP [IP已脱敏]:10080。
> **2026-07-28 测试**: 服务器 100% 丢包，代理域名列表为空，已不可用。
> 替代方案见 [[ROUTER-VIDEO-REMOTE-MONITOR]]。

### 5. miqos (已禁用)
内置 QoS 流量整形，4 级优先级(p1 VoIP/p2 Web/p3 Email/p4 FTP)。

### 6. 无固件签名验证

> [!info] 可刷写自定义固件
> 
> 可刷写自定义 OpenWrt 固件获得:
> - 新版内核 + debugfs (修复 MT7628 帧缓冲)
> - iptables + QoS
> - 现代 dropbear (支持密钥认证)
> - 5GHz USB 网卡支持

## 限制

> [!warning] 已知限制
> 
> | 限制 | 说明 |
> |------|------|
> | `iptables` 用户空间缺失 | 未编译进 busybox; 内核模块 (compat_xtables 等) 已全加载, 但无 iptables 二进制 |
> | iptables 缺失 | 无防火墙/NAT 管理能力 |
> | debugfs 缺失 | 无法禁用 MT7628 frames buffering |
> | uci 不可用 | 必须直接编辑 /etc/config/* |
> | dropbear 0.52 | 不支持现代 SSH 密钥格式 |
> | Lua 字节码 | 无法修改 Web API 逻辑 |
> | telnetd 无法启动 | busybox telnetd 启动失败(原因不明) |
> | MT7628 帧缓冲 Bug | 无 debugfs 修复，需刷 OpenWrt |

## SSH 连接方法

```bash
# 唯一可用的连接方式
/d/Users/28064/AppData/Roaming/MobaXterm/slash/bin/sshpass -p [已脱敏] \
  /d/Users/28064/AppData/Roaming/MobaXterm/slash/bin/ssh \
  -o KexAlgorithms=+diffie-hellman-group1-sha1 \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o MACs=+hmac-sha1-96,hmac-sha1,hmac-md5 \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=8 \
  root@[IP已脱敏]

# Wrapper 脚本
bash scripts/router_ssh.sh "command"
```

密钥认证不可用(dropbear 0.52 与 OpenSSH 密钥格式不兼容)。

## Related

- [[Network-KB-Home]] — 网络知识库主页
- [[GUIDE]] — 使用指南
- [[ROUTER-FULL-CAPABILITY]] — 路由器完全能力手册
- [[ROUTER-OPTIMIZATION]] — 路由器优化分析
