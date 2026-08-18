---
title: 路由器优化分析
tags: [network/router, network/optimization, network]
aliases: [路由器优化]
created: 2026-07-28
updated: 2026-07-28
---

# 路由器优化深度分析 — Xiaomi R4CM 2.14.87

See also: [[Network-KB-Home]] | [[GUIDE]] | [[ROUTER-FULL-CAPABILITY]] | [[ROUTER-DEEP-EXPLORATION]]

## 硬件规格

| 参数 | 规格 | 备注 |
|------|------|------|
| 型号 | R4CM | SoC: MT7628 (MIPS 24Kc) |
| CPU | 单核 575MHz | 当前负载 5.4%，充裕 |
| RAM | 64MB DDR2 @ 800MHz | 当前使用 46%，正常 |
| WiFi | 2.4GHz only (MT7628 内置) | **硬伤** — 无法 5GHz |
| 固件 | 2.14.87 (OpenWrt 修改版) | 较新，API 有限 |
| WAN | eth0.2 DHCP → [IP已脱敏] | 双 NAT |
| LAN | [IP已脱敏]/24 | 设备 IP 池 |

## API 探测结果

```
可用:
  /api/xqnetwork/set_wifi       WiFi 参数修改
  /api/xqnetwork/wan_info       WAN 口信息
  /api/xqnetwork/lan_info       LAN 口信息
  /api/misystem/status          系统状态 (CPU/RAM/WAN吞吐)
  /api/misystem/devicelist      设备列表
  /api/xqsystem/login           登录
  /api/xqsystem/bdata           硬件信息 (免认证)

不可用:
  /api/xqnetwork/dns_info       404
  /api/xqnetwork/firewall_info  404
  /api/xqnetwork/qos_info       500 (无 QoS 模块)
  /api/xqnetwork/wifi_advanced  404
  /api/xqnetwork/nat_info       404
  /api/xqsystem/upgrade_info    404
```

**结论**: R4CM API 非常有限，高级设置（DNS/QoS/防火墙/WiFi高级参数）都需要 SSH 访问 UCI 或直接编辑 `/etc/config/*`。

## 可优化点 (需 SSH)

### 1. MTU 优化

当前: 1500 (标准以太网)
建议: 若上游是 PPPoE，MTU 应为 1492。当前双 NAT 环境可测试 1492 或 1480。

```bash
# SSH 进入后
uci set network.wan.mtu='1492'
uci commit network
ifup wan
```

### 2. DNS 优化

当前: WAN DNS → `[IP已脱敏]` (上游路由器)
问题: 上游路由器再转发 DNS，多一跳延迟。
建议: 直接设置公共 DNS。

```bash
uci set network.wan.peerdns='0'
uci add_list network.wan.dns='[IP已脱敏]'
uci add_list network.wan.dns='[IP已脱敏]'
uci commit network
```

### 3. WiFi 高级参数

| 参数 | 默认值 | 建议值 | 原因 |
|------|--------|--------|------|
| beacon_interval | 100ms | 200ms | 8个IoT设备时减少beacon开销 |
| dtim_period | 2 | 3 | IoT设备省电，减少唤醒频率 |
| rts_threshold | 2347 | 1500 | 8个IoT设备时减少冲突 |
| frag_threshold | 2346 | 2346 | 保持默认（分片降低吞吐） |
| short_preamble | 1 | 1 | 保持（提高效率） |
| wmm | 1 | 1 | 保持（QoS必需） |
| isolate | 1 | **0** | 已通过API设置，需永久写入 |

```bash
# /etc/config/wireless 中修改
config wifi-iface
    option device 'radio0'
    option network 'lan'
    option mode 'ap'
    option ssid '302-1'
    option encryption 'psk2+ccmp'
    option key '19890520'
    option isolate '0'
    option beacon_int '200'
    option dtim_period '3'
    option rts '1500'
    option wmm '1'
```

### 4. 连接跟踪优化

当前: 默认 conntrack 参数 (max 根据 RAM 自动计算)
13 设备下可能有连接数压力。

```bash
# /etc/sysctl.conf
net.netfilter.nf_conntrack_max=16384
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=120
```

### 5. 内核网络参数

```bash
# 减少缓冲区膨胀
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.ipv4.tcp_rmem='4096 87380 4194304'
net.ipv4.tcp_wmem='4096 65536 4194304'
# 启用 TCP 窗口缩放
net.ipv4.tcp_window_scaling=1
# 减少 TIME_WAIT
net.ipv4.tcp_fin_timeout=15
```

### 6. 双 NAT 消除

> [!info] 双 NAT 消除方案
> 
> 当前: R4CM ([IP已脱敏]) → 上游 ([IP已脱敏]) → WAN
> 
> **方案 A**: 上游改桥接模式 → R4CM 直接拨号 (消除一层 NAT)
> **方案 B**: R4CM 改 AP 模式 → 由上游统一 NAT (消除一层 NAT)
> 
> 方案 B 最简单，但会失去 R4CM 的路由功能（DHCP/端口转发等）。

### 7. WiFi 信道固定

当前: 路由器自动选信道 (当前信道 8)
建议: 手动扫描后固定到最干净的信道 (1/6/11 之一)。

```bash
# 通过 API 设置
curl "http://[IP已脱敏]/cgi-bin/luci/;stok=TOKEN/api/xqnetwork/set_wifi" \
  --data "channel=11"
```

## 无需 SSH 的优化 (已执行)

| 优化 | 方法 | 状态 |
|------|------|------|
| AP 隔离关闭 | API `set_wifi` → `isolate=0` | 已执行 (临时) |
| 信道调整 | API `set_wifi` → `channel=1` | 路由器自动选了 8 |
| 40MHz 带宽 | API `set_wifi` → `bandwidth=40` | API 返回成功但未生效 |

## 路由器优化优先级

> [!info] 优化优先级
> 
> ```
> P0: 获取 SSH 访问 (如需，重新运行 CVE-2019-18370)
> P1: 永久 AP 隔离 + WiFi 高级参数 (beacon_int, rts)
> P2: DNS 直连 [IP已脱敏] + MTU 调整
> P3: 双 NAT 消除
> ```

## 硬件升级建议

> [!warning] R4CM 核心限制与升级建议
> 
> 当前 R4CM 核心限制:
> - 仅 2.4GHz (协商速率上限 72.2Mbps 单流)
> - 64MB RAM (连接数容量有限)
> - 单核 575MHz MIPS (无硬件 NAT 加速)
> 
> 推荐升级:
> - **小米 AX3000** (~¥200): WiFi 6, 256MB, 双核, 硬件 NAT
> - **小米 AX6S** (~¥300): WiFi 6, 256MB, 双核, 160MHz
> - 升级后收益: 5GHz 协商速率 600+ Mbps, 延迟稳定 <5ms

## Related

- [[Network-KB-Home]] — 网络知识库主页
- [[GUIDE]] — 使用指南
- [[ROUTER-FULL-CAPABILITY]] — 路由器完全能力手册
- [[ROUTER-DEEP-EXPLORATION]] — 路由器深度探索报告
