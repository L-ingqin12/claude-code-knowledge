---
title: Claude Code 网络韧性参考
aliases: [claude网络韧性, socket消除]
tags: [network/proxy, reference, ai/ops]
created: 2026-08-17
updated: 2026-08-17
status: review
---

# Claude Code 网络韧性参考 — 摘要页

> [!abstract] 概述
> 本页是 [[Claude-Ops-KB-Home]] 子库中**网络链路类知识**的摘要索引，聚焦 Agent 无人值守场景下的三类核心问题：
> socket 断连（keepalive/NAT 超时）、代理门控（网络不稳时的请求挂起）、连接表饱和（conntrack 打爆导致的全链路瘫痪）。
> 与 network/ 子库的 [[ARCHITECTURE]]、[[FINAL-SUMMARY]] 交叉参考，构成从家庭网络到 Agent 链路的完整韧性视图。

## 一、Socket 断连与 NAT 超时 — 四层消除

核心文档：[[claude-socket-error-elimination-guide]]

**根因**：Node.js 默认不启用 HTTP KeepAlive + 移动网络 NAT 30-120s 空闲超时 = 必然断连。空闲期连接被 NAT 静默 RST，Claude 复用死连接时崩溃 (`The socket connection was closed unexpectedly`)。

**四层消除方案**（从网络栈底层到应用层逐层防御）：

| 层 | 机制 | 要点 |
|----|------|------|
| Layer 0 内核加固 | TCP keepalive 调优 | `tcp_keepalive_time=60 / intvl=10 / probes=3`，60s 探测刷新 NAT 映射，从源头消除空闲超时 |
| Layer 1 透明重试代理 | 连接池 + 心跳 + 自动重试 | 每 socket 60s keepalive、连接池心跳 45s、socket 错误重试 3 次 (backoff 1/3/8s)，让错误发生时也无感 |
| Layer 2 应用启动层 | 环境注入 + 中断恢复协议 | `ANTHROPIC_BASE_URL` 指向本地代理，注入 resume-prompt 恢复上下文 |
| 兜底守护 | guardian 脚本 | 代理 3 次重试失败返回 502 + 保存 context-dump/task-state → 守护脚本检测并自动恢复 |

**效果**：NAT 空闲超时、基站切换、Wi-Fi→蜂窝切换、瞬时抖动均从 "Crash" 变为自动恢复（最长 11s）；代理开销 < 1ms 本地回环延迟。

## 二、代理门控 — 网络不稳时延迟发送

核心文档：[[Claude-Ops-KB-Home]] 子库内 `claude-network-stability-gate`（网络稳定性门控）

**思想**：不只是"通不通"，而是"稳不稳"。用滑动窗口评估网络质量（延迟/成功率波动），网络不稳定时**挂起请求而非立即失败**，稳定后再放行发送，避免请求在链路抖动窗口内无谓消耗重试预算。

- 稳定性度量：滑动窗口评估网络质量，区分"可达"与"稳定"
- 挂起机制：代理挂起请求且不让 Claude 超时（时间预算内等待）
- 与 Layer 1 重试代理集成：门控在前、重试在后，共同组成发送质量闸门

## 三、conntrack 饱和 — 飞书 P0 事故案例

核心文档：[[2026-06-24-hermes-feishu-outage-postmortem]]

**五层级联故障**（2026-06-24，P0，~80 分钟）：

1. **触发器**：代理节点（韩国 VLESS reality）TLS 瞬断，`SSLError: EOF`
2. **放大器**：`api_max_retries=3` × 每个工具调用 → 数百个死连接堆积
3. **临界点**：路由器 conntrack/NAT 表耗尽 → 新连接（含 DNS）全部被丢弃
4. **飞书断连**：DNS 解析失败（`Temporary failure in name resolution`），WebSocket 每 2 分钟重连失败 9+ 次
5. **瘫痪**：Pi 网络栈完全阻塞，SSH 不可达，只能物理重启

**教训**：代理死链时**重试本身就是 DDoS 放大器**；连接表是隐形的单点资源，必须限制重试次数并监控 conntrack 水位。

## 四、与本库的交叉参考

- [[ARCHITECTURE]] — 家庭网络代理架构（v2rayN/xray 链路，与 Agent 代理链同源问题：节点瞬断、重试放大）
- [[FINAL-SUMMARY]] — 网络优化总结（含公开知识支撑与延迟改善数据）
- [[Claude-Ops-KB-Home]] — claude-ops 子库 MOC（运维方案/事故复盘/架构模式全集）

## Related

- [[Network-KB-Home]] — 本子库 MOC
- [[Claude-Ops-KB-Home]] — 运维子库 MOC
- [[claude-socket-error-elimination-guide]] — socket 错误四层消除方案
- [[2026-06-24-hermes-feishu-outage-postmortem]] — conntrack 饱和 P0 复盘
- [[FINAL-SUMMARY]] — 网络优化总结
- [[ARCHITECTURE]] — 代理架构设计
