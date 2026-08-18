---
title: 优化审计报告
aliases: [Optimization Audit, 优化审计, 设计漏洞]
tags: [network/optimization, network/proxy, network/analysis, network]
created: 2026-07-28
updated: 2026-07-28
---

# 优化审计 — Telegram 视频卡顿根因与修复

See also: [[Network-KB-Home]] | [[FINAL-SUMMARY]] | [[ARCHITECTURE]] | [[ROUTER-OPTIMIZATION]]

## 当前性能基线

| 指标 | 数值 | 目标 |
|------|------|------|
| 代理出口 IP | [IP已脱敏] (p1d2) | — |
| 下载速度 | ~375 KB/s (3.0 Mbps) | >1 MB/s |
| WiFi 网关延迟 | 2-31ms (avg **7ms**) ✅ | <10ms 稳定 (已达标) |
| WiFi 速率 | 72.2 Mbps (2.4GHz 802.11n) | >150 Mbps |

## 四层优化清单

### L1 — WiFi 物理层 (影响最大)

| # | 优化点 | 当前 | 收益 | 难度 |
|---|--------|------|------|------|
| 1 | 更新 QCA9377 驱动 | v12.0.0.1118 (2021) | 延迟 -50~80% | 低 |
| 2 | 换双频路由器 | R4CM 仅 2.4GHz | 速率 72→300+ | 硬件 |
| 3 | 减少 IoT 争用 | 8 ESP32 | 小幅降延迟 | 中 |
| 4 | HT40 40MHz | API 返回成功未生效 | 速率翻倍 | SSH |

> [!warning] WiFi 是最大瓶颈
> 2-182ms 延迟抖动使视频每几秒 TCP 重传，直接导致缓冲循环。

### L2 — 路由器层

| # | 优化点 | 收益 | 难度 |
|---|--------|------|------|
| 5 | 消除双 NAT ([[ROUTER-OPTIMIZATION]]) | -5~10ms | 中 |
| 6 | SSH 永久 AP 隔离 | 避免复发 | 低 ✅ |
| 7 | conntrack 调优 | 减丢包 | SSH |

### L3 — 代理策略层 (详见 [[ARCHITECTURE]])

| # | 优化 | 状态 |
|---|------|------|
| 8 | catch-all 缺失 | ✅ 已修复 |
| 9 | 评分单维度 (仅 Ping) | ⬜ 待复合评分 |
| 10 | Balancer 节点质量 | ✅ proxy-only |
| 11 | 节点消失无感知 | ✅ 每次重测 |
| 12 | Observatory 频率 | ✅ 3min→10min |

### L4 — 协议层

| # | 优化点 | 难度 |
|---|--------|------|
| 13 | Telegram IP 段路由 | 中 |
| 14 | TCP 握手开销 | 客户端控制 |
| 15 | Reality 开销 | 无优化 |

## 设计漏洞 (6 个)

| # | 漏洞 | 方案 | 参考 |
|---|------|------|------|
| 1 | 评分仅用 Ping | guiNDB.db 复合评分 | [[ARCHITECTURE#决策 6]] |
| 2 | 非自动触发 | FileSystemWatcher hook | [[ARCHITECTURE#Phase 3]] |
| 3 | Balancer 频繁切换 | tolerance 容差 | [[ARCHITECTURE#决策 4]] |
| 4 | 无 Telegram 路由 | 加 IP 段规则 | — |
| 5 | SSH 可能失效 | CVE-2019-18370 | [[ROUTER-DEEP-EXPLORATION]] |
| 6 | 高延迟 US 节点 | proxy-only selector | ✅ 已修复 |

## 优先级 (ROI)

```
P0 ✅ catch-all, balancer proxy-only, observatory 10min
P1 ⬜ 驱动更新, Telegram IP 段
P2 ⬜ 复合评分, 消除双 NAT
P3 ⬜ WiFi 6 路由器, Hook 自动化
```

## Related

- [[FINAL-SUMMARY]] — 完整总结
- [[ARCHITECTURE]] — 架构与决策
- [[ROUTER-OPTIMIZATION]] — 路由器优化
- [[Network-KB-Home]] — 知识库首页
