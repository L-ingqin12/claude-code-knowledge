---
title: 路由器视频/远程/监测方案
aliases: [QoS, 远程访问, 流量监测]
tags: [network/router, network/optimization]
created: 2026-07-28
updated: 2026-07-28
status: stable
---

# 路由器视频优化、远程访问与流量监测

See also: [[Network-KB-Home]] | [[ROUTER-FULL-CAPABILITY]] | [[ROUTER-OPTIMIZATION]]

> [!abstract] 硬件约束
> - RAM: 64MB (空闲 ~15MB), CPU: 575MHz 单核
> - /data: 272KB 剩余, /userdisk: 1.4MB 剩余
> - 无 iptables (无法端口转发/NAT 规则)
> - 无 uci (miqos 无法启动)

## 一、视频优化

### WMM (WiFi Multimedia) — 已生效

MT7628 驱动级 QoS，4 个优先级队列：

| 优先级 | 队列 | 典型流量 |
|--------|------|----------|
| Voice (最高) | AC_VO | VoIP, 游戏 |
| **Video** | **AC_VI** | **视频流, Telegram** |
| Best Effort | AC_BE | Web, 普通 TCP |
| Background | AC_BG | 下载, P2P |

WMM 在 `/etc/config/wireless` 中 `option wmm '1'` 已启用。WiFi 驱动自动根据 IP TOS/DSCP 标记将包分配到对应队列。

> [!warning] miqos 不可用
> miqos 依赖 uci 命令（R4CM 2.14.87 中缺失），启动时崩溃: `uci: not found`。配置已写入但无法运行。

### 客户端侧优化 (Windows)

```powershell
# 启用 TCP 窗口自动调优
netsh int tcp set global autotuninglevel=normal
# 启用 CTCP 拥塞控制
netsh int tcp set global congestionprovider=ctcp
```

### 效果

WMM 无法主动标记包（需要 iptables），但尊重已有的 DSCP 标记。xray/VLESS 流量不携带特定 DSCP，因此 WMM 对代理流量的视频优化效果**有限**。主要收益在于：非代理直连流量（如国内视频网站）可被正确分类。

## 二、远程访问

### 方案 A: SSH 隧道 (推荐, 零存储, 即时可用)

从 Windows 本机 (已有 SSH 到路由器) 建立到 VPS 的远程隧道：

```bash
# 方案 A1: 反向隧道 (从 Windows → VPS, 暴露路由器端口)
ssh -R 2222:[IP已脱敏]:22 -o ServerAliveInterval=60 user@your-vps

# 方案 A2: SOCKS 动态转发 (路由器作为代理出口)
ssh -D 2080 -N user@your-vps
# 然后浏览器配置 SOCKS5: [IP已脱敏]:2080

# 方案 A3: 本地转发 (访问远程服务)
ssh -L 8080:remote-service:80 user@your-vps
```

优点: 安全加密, 无需端口转发, 无需路由器存储
缺点: 需要一台有公网 IP 的 VPS; 连接断开需重连

### 方案 B: xl2tpd L2TP VPN (替代 SmartVPN, 路由器原生)

xl2tpd 二进制已存在 (/usr/sbin/xl2tpd, 97KB):

```bash
# 配置 L2TP 客户端连接远程 VPN 服务器
# 编辑 /data/etc/xl2tpd/xl2tpd.conf
# 编辑 /data/etc/xl2tpd/xl2tp-secrets (已存在模板)
# 启动: /etc/init.d/xl2tpd start
```

优点: 路由器原生支持, 2 层隧道, 可路由整个子网
缺点: 需要远程 L2TP 服务器; 配置复杂

### 方案 C: nc TCP 中继 (最轻量, 0 存储)

```bash
# 从路由器转发端口到外部服务器
while true; do
  busybox nc <remote_server> <remote_port> < /tmp/fifo | busybox nc localhost 80 > /tmp/fifo
done &
```

优点: 零存储, busybox 内置
缺点: 不稳定, 无加密, 单向

### 方案 D: frp/nps 内网穿透 (最灵活)

```bash
# 下载 frp MIPS 客户端到 /userdisk (1.4MB 可用)
cd /userdisk && wget <frp-mips-url>
# 配置指向有公网 IP 的 frp 服务端
# 开机自启 via rc.local
```

优点: 功能完整, 支持多端口映射, 可穿透多层 NAT
限制: 需要外部 frp 服务端; frp 二进制 ~5MB (/userdisk 只有 1.4MB, 需用 tmpfs 运行)

> [!tip] 推荐方案
> 当前最优: **frp/tmpfs + 外部 frp 服务端**。frp 客户端下载到 /tmp (RAM), 每次启动时 wget 拉取, 不占用 flash。配置存 /userdisk。

## 三、流量监测

### 实时监测脚本 (已部署)

`/userdisk/traffic_monitor.sh` — 每分钟采集:

```
格式: timestamp WAN_RX_bps WAN_TX_bps WiFi_bps conntrack_count
输出: /userdisk/traffic.log (自动轮转, 保留 200 行)
```

**存储占用**: 脚本 ~800B, 日志 ~14KB, 总计 <15KB

```bash
# 查看最近 10 条记录
tail -10 /userdisk/traffic.log

# 实时连接数
cat /proc/sys/net/netfilter/nf_conntrack_count

# 接口累计流量
cat /proc/net/dev | grep eth0.2
```

### 数据解读

| 指标 | 来源 | 含义 |
|------|------|------|
| WAN_RX_bps | /proc/net/dev eth0.2 | WAN 下载速率 (bps) |
| WAN_TX_bps | /proc/net/dev eth0.2 | WAN 上传速率 (bps) |
| WiFi_bps | /proc/net/dev wl1 | WiFi 接口速率 |
| conntrack | nf_conntrack_count | 活跃连接数 |

### 扩展: 设备级流量

```bash
# 通过 API 获取每个设备的实时速率
curl "http://[IP已脱敏]/cgi-bin/luci/;stok=TOKEN/api/misystem/devicelist"
# 返回每个设备的 upspeed/downspeed (单位: B/s?)
```

### 扩展: 远程日志

```bash
# 通过 nc 发送到外部日志服务器
tail -f /userdisk/traffic.log | busybox nc <log-server> 514 &
```

## 四、存储使用

| 文件 | 大小 | 位置 |
|------|------|------|
| traffic_monitor.sh | ~800B | /userdisk |
| traffic.log | ≤14KB | /userdisk |
| miqos 配置 | ~1KB | /data/etc/config |
| rc.local 修改 | +100B | /data/etc |
| **总计** | **<16KB** | — |

剩余: /data 272KB, /userdisk 1.4MB

## Related

- [[ROUTER-FULL-CAPABILITY]] — 路由器能力手册
- [[ROUTER-OPTIMIZATION]] — 路由器优化分析
- [[Network-KB-Home]] — 知识库首页
