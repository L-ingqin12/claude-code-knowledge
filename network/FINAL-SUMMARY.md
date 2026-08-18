---
title: 完整优化总结
aliases: [Final Summary, 总结]
tags: [network/optimization, network/proxy, network/router, network]
created: 2026-07-28
updated: 2026-07-28
---

> [!success] 核心结论
> Telegram 视频卡顿由 **WiFi 层 + 路由器硬件 Bug** 双重导致，非代理问题。代理策略 Bug 已全部修复。详见 [[ARCHITECTURE]] 和 [[GUIDE]]。

## 性能基线

| 指标 | 当前值 | 评级 |
|------|--------|------|
| 代理出口 | [IP已脱敏] (p1d2) | ✅ 稳定 |
| 下载速度 | ~375 KB/s (3.0 Mbps) | △ 勉强 720p |
| Telegram API | 1.5s | △ 偏慢 |
| WiFi 网关延迟 | 2-31ms, avg **7ms** | ✅ 已达标 |
| 信号 | 82%, RSSI -58 | ✅ |

> [!info] 瓶颈已转移
> WiFi 延迟从 541ms → 7ms (改善 96%)。当前瓶颈是**代理带宽 3 Mbps** — 刚好 720p 临界点，1080p 不够。换更快的代理节点是下一步关键。

## 根因分析

### 主因 1: WiFi 层周期性断流

**现象**: Ping 网关每 3-8 秒出现一次 100-182ms 尖峰

**公开知识确认**:
1. **QCA9377 网卡驱动过时** — 当前 2021-05-19 v12.0.0.1118，最新版 v3.1.0.1486 (2025-06)。旧驱动有已知延迟问题。[qc-drivers.eu](https://www.qc-drivers.eu)
2. **WiFi 省电模式** — 默认开启，导致网卡间歇性休眠。关闭后延迟稳定性显著提升。
3. **蓝牙共存干扰** — QCA9377 是 WiFi+BT 二合一芯片，蓝牙活动导致 2.4GHz 信道冲突。

### 主因 2: MT7628 Frames Buffering Bug

**现象**: WiFi 在高负载下断流数秒（吞吐降到 0 bps）

**公开知识确认**:
- Linux 内核邮件列表: MT7628 (mt7603 驱动) 的 MCU 中断 `PKT_TYPE_TXS` 处理异常，帧缓冲导致 WiFi 传输完全停止。[lkml.indiana.edu](https://lkml.indiana.edu/hypermail/linux/kernel/2403.3/05496.html)
- OpenWrt 社区: R4CM 特定型号在高流量下频繁出现 WiFi 断流，通过 debugfs 关闭 SKB loopback 可大幅改善。[OpenWrt Forum](https://forum.openwrt.org/t/openwrt-for-xiaomi-mi-router-4c/72175/129)

### 主因 3: MT7628 TX Power 锁死 14 dBm

**现象**: 出厂固件限制 WiFi 发射功率为 14 dBm (25mW)，而硬件支持 30 dBm (1000mW)。

**公开知识确认**:
- anywlan 论坛: R4CM factory 分区偏移 0xA0 处 14 字节控制 TX power，改为 `FF` 解锁 30 dBm。[anywlan.com](https://www.anywlan.com/thread-447807-1-6.html)

### 主因 4: 代理策略 Bug（已全部修复）

| Bug | 修复 | 状态 |
|-----|------|------|
| Mux+Vision 冲突 → 队头阻塞 | 所有 VLESS 出站 mux: false | ✅ |
| 无 catch-all → Telegram 不走 balancer | 添加 `tcp,udp → balancerTag: balancer` | ✅ |
| Balancer 引用错误 (outboundTag) | 改为 balancerTag | ✅ |
| DNS 路径分裂 → CDN 不匹配 | DNS 走固定 proxy，不走 balancer | ✅ |
| Balancer 包含高延迟 US 节点 | selector 改 `["proxy"]` only | ✅ |
| Observatory 频率过高 | 3min → 10min | ✅ |

## 优化优先级

```
P0 (立即 — 代理配置) — 全部已完成 ✅
  ✅ Mux 禁用
  ✅ catch-all 添加
  ✅ balancerTag 修正
  ✅ DNS 一致性
  ✅ balancer proxy-only
  ✅ observatory 10min

P1 (本周 — 客户端侧)
  ⬜ 更新 QCA9377 驱动到最新版
  ⬜ 关闭 WiFi 省电模式 (设备管理器)
  ⬜ 关闭蓝牙 (如不用)
  ⬜ netsh winsock reset + 网络重置

P2 (本月 — 路由器侧, 需SSH)
  ⬜ 禁用 MT7628 frames buffering (debugfs)
  ⬜ 解锁 TX power 14→30 dBm (factory分区)
  ⬜ 永久写入 AP 隔离 (/etc/config/wireless)
  ⬜ Beacon interval 100→200ms
  ⬜ 上游 DNS 改直连 [IP已脱敏]

P3 (长期 — 硬件)
  ⬜ 换双频 WiFi 6 路由器 (AX3000/AX6S)
  ⬜ 消除双 NAT (上游桥接 或 R4CM AP模式)
  ⬜ FileSystemWatcher hook 全自动化
```

## 路由器优化速查（R4CM）

| 优化 | 生效方式 | 需要 |
|------|----------|------|
| AP 隔离=0 | API (临时) / SSH (永久) | 已执行API |
| 信道优化 | API `set_wifi channel=N` | 已执行 |
| 40MHz 带宽 | API (未生效) / SSH uci | SSH |
| Beacon间隔 | SSH `/etc/config/wireless` | SSH |
| RTS阈值 | SSH `/etc/config/wireless` | SSH |
| 帧缓冲禁用 | SSH debugfs | SSH+补丁 |
| TX power解锁 | 改factory分区 | SSH+hex |
| DNS直连 | SSH uci network | SSH |
| MTU调整 | SSH uci network | SSH |
| 双NAT消除 | 网络拓扑变更 | 手动 |

> [!warning] 路由器优化
> R4CM 的多项优化（帧缓冲、TX power、Beacon）通过 SSH 操作，详见 [[ROUTER-OPTIMIZATION]]。

## 当前生效配置

```
Balancer: proxy(p1d2) only, fallback: us1
Observatory: 10分钟, 4节点健康检查
DNS: 直连走 Alibaba, 境外走 Cloudflare via p1d2
路由: CN → direct, Google → balancer, 其他 → balancer
出站: proxy(p1d2) + us1 + usss1 + a2 (全部 mux:false)
```

## 日常操作

订阅更新后运行 (2-3分钟):
```powershell
powershell -File "D:\Document\local\knowledge\network\enhance-config.ps1" -DryRun
powershell -File "D:\Document\local\knowledge\network\enhance-config.ps1" -Apply
```

查看状态:
```powershell
powershell -File "D:\Document\local\knowledge\network\enhance-config.ps1" -Status
```

---

*Home: [[Network-KB-Home]] | Architecture: [[ARCHITECTURE]] | Router: [[ROUTER-OPTIMIZATION]] | Guide: [[GUIDE]]*
