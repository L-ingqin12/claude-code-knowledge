---
title: 路由器完全能力手册
tags: [network/router, network]
aliases: [路由器能力手册]
created: 2026-07-28
updated: 2026-07-28
---

# 路由器完全能力手册 — Xiaomi R4CM 2.14.87

See also: [[Network-KB-Home]] | [[GUIDE]] | [[ROUTER-DEEP-EXPLORATION]] | [[ROUTER-OPTIMIZATION]]

## 一、硬件规格

| 参数 | 值 |
|------|-----|
| 型号 | R4CM (小米路由器 4C) |
| SoC | MT7628AN (MIPS 24KEc V5.5, 575MHz 单核) |
| RAM | 64MB DDR2 @ 800MHz (空闲 ~15MB) |
| Flash | 16MB SPI NOR |
| WiFi | 2.4GHz only, 802.11bgn, 2x2 MIMO |
| 内核 | Linux 3.10.14 (2019-11-26) |
| SSH | dropbear 0.52, 仅 LAN ([IP已脱敏]:22) |
| TX Power | 18 dBm (可解锁到 30 dBm，不推荐) |

## 二、Flash 分区

| 分区 | 大小 | 名称 | 用途 |
|------|------|------|------|
| mtd0 | 16MB | ALL | 全镜像 |
| mtd1 | 128KB | Bootloader | U-Boot |
| mtd2 | 64KB | Config | 配置 |
| mtd3 | 64KB | Factory | 校准数据(SN/MAC/TX power) |
| mtd4 | 64KB | crash | 崩溃日志 |
| mtd5 | 64KB | cfg_bak | 配置备份 |
| mtd6 | 1MB | overlay | 持久化 (/data, /etc) |
| mtd7 | 12.4MB | OS1 | 固件 |
| mtd8 | 10.9MB | rootfs | 根文件系统 |
| mtd9 | 2MB | disk | 用户数据 (/userdisk) |

## 三、存储使用

| 挂载点 | 大小 | 已用 | 可用 | 备注 |
|--------|------|------|------|------|
| / (rootfs) | 8.5M | 8.5M | **0** | 只读, 100% 满 |
| /tmp | 29.6M | 784K | 28.8M | RAM tmpfs, 重启丢失 |
| /userdisk | 2.0M | 564K | **1.4M** | 用户数据存储 |
| /data | 1.0M | 752K | **272K** | 配置持久化, 空间紧张 |

> [!warning] 存储空间告急
> - `/ (rootfs)` 100% 已满且为只读，无法写入任何文件
> - `/data` 仅剩 **272KB**，持久化空间极度有限
> - `/userdisk` 仅剩 **1.4MB**，可用于少量脚本和数据存储

## 四、运行服务与端口

| 端口 | 绑定 | 进程 | 用途 |
|------|------|------|------|
| 22 | [IP已脱敏] | dropbear | SSH 管理 ✅ |
| 53 | [IP已脱敏] | dnsmasq | DNS + DHCP |
| 67 | [IP已脱敏] | dnsmasq | DHCP |
| 80 | [IP已脱敏] | sysapihttpd | Web 管理 |
| 784 | [IP已脱敏] | tbusd | 小米消息总线 |
| 8080 | [IP已脱敏] | himan | 小米 IoT |
| 8899,8999 | [IP已脱敏] | sysapihttpd | 管理 API |
| 8387 | [IP已脱敏] | hiapk2 | 应用分发 |
| 8443 | [IP已脱敏] | sysapihttpd | HTTPS API |
| 8920 | [IP已脱敏] | fcgi-cgi | FastCGI 后端 |
| 9090 | [IP已脱敏] | datacenter | 遥测 |
| 9091 | [IP已脱敏] | plugincenter | 插件中心 |
| 6010 | [IP已脱敏] | dropbear | SSH (loopback) |

## 五、Busybox 工具清单 (146 个)

### 网络工具
`arp`, `arping`, `brctl`, `dnsd`, `dnsdomainname`, `ifconfig`, `nc`, `netstat`, `nslookup`, `ping`, `ping6`, `route`, `traceroute`, `udhcpc`, `wget`

### 系统管理
`crond`, `crontab`, `dd`, `df`, `free`, `kill`, `killall`, `logger`, `lsmod`, `insmod`, `rmmod`, `mount`, `nohup`, `ntpd`, `ps`, `reboot`, `sync`, `sysctl`, `telnet`, `telnetd`, `top`, `watch`, `watchdog`

### 文件操作
`cat`, `cp`, `dd`, `du`, `find`, `grep`, `gzip`, `head`, `hexdump`, `less`, `ln`, `ls`, `mkdir`, `mv`, `rm`, `rmdir`, `sed`, `strings`, `tail`, `tar`, `touch`, `vi`, `zcat`

### 脚本
`awk`, `basename`, `dirname`, `echo`, `expr`, `printf`, `sleep`, `test`, `timeout`, `usleep`, `wc`, `xargs`, `yes`

### 内核模块 (已加载)
`compat_xtables`, `crc-itu-t`, `br_http` 系列, `http_*` 系列, `ip6_*` 系列

## 六、可用但需 busybox 前缀的命令

```bash
busybox insmod <module>    # 加载内核模块 (已全加载)
busybox brctl show          # 显示网桥
busybox nc -l -p <port>     # TCP 监听
busybox telnetd -p <port> -l /bin/ash  # 启动 telnet (实际不工作)
busybox wget <url>          # 下载文件
busybox nslookup <domain>   # DNS 查询
```

## 七、不可用的工具

> [!warning] 缺失的关键工具
> 
> | 工具 | 原因 | 替代 |
> |------|------|------|
> | `iptables` | 未编译进 busybox | `fw3` 配置或放弃 |
> | `tcpdump` | 未编译 | `nc` 转发到外部抓包 |
> | `tc` | 未编译 | `miqos` |
> | `iperf` | 独立二进制不可用 | `speedtest` |
> | `curl` | 独立二进制不可用 | `wget` + `nc` |
> | `modprobe` | 未编译 | `busybox insmod` |

## 八、可用功能清单

### ✅ 已启用
- SSH 远程管理 (LAN-only)
- DNS/DHCP (dnsmasq)
- Web 管理界面
- 小米 IoT 平台 (himan)
- WiFi 事件监控 (iweventd)
- 流量统计 (trafficd)
- 定时任务 (crond)
- NTP 时间同步
- MAC 过滤
- 网桥 (br-lan: eth0.1 + wl1)

### ⬜ 可启用 (已配置, 已禁用)
- **访客网络** — `guest_2G` 接口, disabled=1
- **QoS 流量整形** — `miqos`, 4 级优先级 (p1 VoIP/p2 Web/p3 Email/p4 FTP)
- **UPnP** — `miniupnpd`, rc.local 中已 kill
- **小米 VPN 中继** — `smartvpn`, 出口 [IP已脱敏]:10080
- **DDNS** — `ddnsd` 二进制存在, 无配置
- **磁盘服务** — JFFS2 /userdisk, 可存储脚本数据
- **自定义 DNS** — `custom_hosts`, dnsmasq.d 目录

### 🔧 可开发
- **广告屏蔽 DNS** — 写 custom_hosts 拦截广告域名
- **定时测速记录** — crond + speedtest
- **自动化脚本** — /data/ 持久化 shell 脚本
- **nc 端口转发** — TCP 隧道/内网穿透
- **wget 远程加载** — 从外网拉取配置/脚本
- **syslog 日志分析** — syslog-ng 可配置远程日志

### ❌ 不可用
- USB 外设 (R4CM 无 USB 接口)
- Samba/FTP 文件共享
- 打印机共享
- WPA3 (MT7628 不支持)
- 5GHz WiFi (MT7628 硬件限制)
- debugfs (原厂内核不支持)
- Lua Web API 修改 (源码已编译)

## 九、SSH 连接

```bash
# 唯一有效方式 (MobaXterm sshpass + old crypto)
/d/Users/28064/AppData/Roaming/MobaXterm/slash/bin/sshpass -p [已脱敏] \
  /d/Users/28064/AppData/Roaming/MobaXterm/slash/bin/ssh \
  -o KexAlgorithms=+diffie-hellman-group1-sha1 \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o MACs=+hmac-sha1-96,hmac-sha1,hmac-md5 \
  -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
  root@[IP已脱敏] "<command>"

# Wrapper
bash ~/.ssh/router_ssh.sh "command"
```

密钥免密不可用: dropbear 0.52 与现代 OpenSSH 密钥格式不兼容。

## 十、nvram/Bootloader 标志

```
uart_en=0      # 串口禁用
ssh_en=0       # SSH 禁用 (bootloader 级, 不同于 OS 中的 dropbear)
telnet_en=0    # Telnet 禁用
flag_boot_success=1  # 启动成功
```

## 十一、API 端点 (需 stok 认证)

| 端点 | 方法 | 用途 |
|------|------|------|
| `/api/xqsystem/login` | POST | 登录获取 token |
| `/api/xqsystem/bdata` | GET | 硬件信息(免认证) |
| `/api/misystem/status` | GET | CPU/RAM/WAN 吞吐 |
| `/api/misystem/devicelist` | GET | 在线设备 |
| `/api/xqnetwork/set_wifi` | POST | WiFi 参数修改 |
| `/api/xqnetwork/wan_info` | GET | WAN 状态 |
| `/api/xqnetwork/lan_info` | GET | LAN 状态 |

## 十二、已执行的优化

> [!info] 已完成优化项目
> 
> | 优化 | 状态 |
> |------|------|
> | SSH 访问 | ✅ dropbear 持久化 |
> | AP 隔离 = 0 | ✅ /etc/config/wireless 永久 |
> | 加密 psk2+ccmp | ✅ /etc/config/wireless |
> | OTA 自动更新 | ✅ 已禁用 |
> | 遥测禁用 | ✅ datacenter + rmonitor |
> | DNS 缓存 2000 | ✅ 已持久化 |
> | DNS rebind 保护 | ✅ 已启用 |
> | 流量监测 | ✅ cron 每分钟 |
> | 固定信道 11 | ⚠️ 固件覆盖(自动选频) |
> | 40MHz 带宽 | ⚠️ 固件忽略 |
> | WiFi 事件钩子 | ✅ iweventd |
> | rc.local 持久化 | ✅ dropbear + 遥测kill |

## 十三、Factory 分区风险警告

> [!danger] Factory 分区 — 修改可能导致永久性硬件损坏
> 
> - 修改 mtd3 Factory 分区可解锁 TX power (18→30 dBm)
> - **风险**: 校准数据损坏 → WiFi 永久失效, 且 R4CM 无引出 UART 难恢复
> - **收益**: 信号增强, 但你的信号已 86%, 不解决 MT7628 帧缓冲 Bug
> - **结论**: 风险 >> 收益, 不建议

## Related

- [[Network-KB-Home]] — 网络知识库主页
- [[GUIDE]] — 使用指南
- [[ROUTER-DEEP-EXPLORATION]] — 路由器深度探索报告
- [[ROUTER-OPTIMIZATION]] — 路由器优化分析
