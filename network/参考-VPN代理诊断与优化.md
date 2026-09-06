---
title: VPN 代理诊断与优化参考
aliases: [VPN诊断, 代理优化]
tags: [reference/vpn, reference, network/proxy]
created: 2026-07-22
updated: 2026-08-25
status: stable
source_urls: [https://github.com/gfpcom/free-proxy-list, https://github.com/nikita29a/FreeProxyList, https://github.com/rtwo2/FastNodes]
---

# VPN 代理诊断与优化 — 知识参考

See also: [[Network-KB-Home]] | [[ROUTER-VIDEO-REMOTE-MONITOR]] | [[ARCHITECTURE]]

> 配合《树莓派网络故障与路由器破解完整复盘》阅读。
> 分析树莓派 VPN 代理不稳定的根因及优化方案。

---

## 一、当前代理架构

```
应用 (git/curl/Claude Code)
  ↓ socks5h://127.0.0.1:10808
Xray SOCKS5 Inbound (port 10808)
  ↓ VLESS + REALITY 协议
远程服务器 ([IP已脱敏]:10000)
  ↓
目标网站 (github.com, google.com)
```

### Xray 配置

| 组件 | 配置 |
|------|------|
| Inbound | SOCKS5, 127.0.0.1:10808 |
| Outbound | VLESS + REALITY → [IP已脱敏]:10000 |
| 传输 | TCP, REALITY 指纹伪装 ([域名已脱敏], chrome) |
| 路由 | geosite:cn → direct, 其余 → proxy |
| 健康检查 | burstObservatory, 5min 间隔, 3 次采样 |

### Git 代理配置

```bash
git config --global http.proxy socks5h://127.0.0.1:10808
git config --global https.proxy socks5h://127.0.0.1:10808
```

注意：`socks5h`（h = hostname）让 DNS 也通过代理解析，避免 DNS 泄漏。

---

## 二、诊断结果

### 连通性测试

| 目标 | 单次请求 | 连续请求（3次） | 大文件 |
|------|:------:|:-------------:|:-----:|
| google.com | 302, 1.0s ✓ | — | — |
| github.com | 200, 2.8s ✓ | 200/200/**000** | — |
| github.com 大文件 | 200, 2.3s ✓ | — | — |
| git clone (HTTPS) | — | **失败** | **断连** |

### 根因分析

**VPN 隧道不稳定，约 1/3 连接超时（连通性测试 3 次中 1 次 `000`；连续 10 次中 3 次失败）。**

```
连续 10 次测试：
  ✓ ✓ ✗ ✓ ✓ ✗ ✓ ✓ ✗ ✓
```

Git clone 需要多次连续 HTTP 请求（ref 发现 → pack 下载 → index 解包）。任何一次超时都会导致整个 clone 失败。

### 为什么 HTTPS clone 失败

```
git clone 流程:
  GET /info/refs?service=git-upload-pack  ← 可能成功
  POST /git-upload-pack                    ← 可能成功
  ← 接收 pack 数据（大文件）               ← 高概率超时！
  
一次超时 → "unexpected disconnect while reading sideband packet"
```

### TLS 层错误

```
GnuTLS recv error (-9): Error decoding the received TLS packet
```

REALITY 协议的 TLS 隧道在某些网络条件下会丢包或 TLS 记录损坏，导致 GnuTLS 解码失败。这是 VLESS+REALITY 协议的已知问题——当中间网络（ISP/GFW）对 TLS 流量进行干扰时，REALITY 无法完全隐藏流量特征。

---

## 三、优化措施

### 已部署

| 措施 | 说明 |
|------|------|
| **git-retry** | 指数退避（3s→6s→12s→24s→48s）+ 随机抖动，最多 5 次 |
| **熔断器** | 连续 2 次失败后检测代理是否存活，代理不可达时冷却 5 分钟 |
| **Xray burstObservatory** | 5 分钟间隔健康检查，3 次采样，追踪出站延迟 |
| **leastPing 策略** | 多出站时自动选延迟最低的（当前仅 1 个出站，准备扩展） |

### 关键设计原则（避免"排序陷阱"）

1. **不要频繁切换**：健康检查间隔 ≥ 5 分钟，避免短时间内的反复切换
2. **显著改善才切换**：新代理需要比当前代理好 20%（评分 ×1.2）以上才触发切换（与切换策略表一致）
3. **故障冷却**：失败的代理至少冷却 15 分钟才重新尝试
4. **最少切换间隔**：10 分钟内最多切换 1 次

## 四、综合评分系统（已部署）

### 评分公式

```
综合分 = 延迟分×30% + 吞吐分×40% + 稳定性分×30%
```

| 维度 | 权重 | 满分条件 | 零分条件 |
|------|:--:|------|------|
| **延迟** | 30% | 0s | ≥5s |
| **吞吐** | 40% | ≥2MB/s | 0 |
| **稳定性** | 30% | 100% 成功率 | 0% |

**吞吐权重最高（40%）**——对 git clone、大文件下载等场景，吞吐比延迟更重要。

### 当前代理评分

```
primary (socks5h://127.0.0.1:10808)
  综合分: 35/100
  延迟:   2.8s (44/100)   ← github.com 实测（google 1.0s、大文件 2.3s）
  吞吐:   0.03MB/s (1/100)  ← 主要瓶颈
  稳定性: 70% (70/100)   ← 连续 10 次成功 7 次
```

> [!warning] 勘误（2026-08-25）
> 原评分卡记「延迟 4.0s / 稳定性 100% / 综合 36」，与 §二 实验数据表（延迟 1.0~2.8s、约 1/3 超时）矛盾，已按实验数据表统一：延迟取 2.8s，线性分 (5−延迟)/5×100 = 44；稳定性按 10 次实测成功 7 次取 70%；综合分 = 44×30% + 1×40% + 70×30% ≈ 35。速率口径：吞吐 0.03MB/s 为评分周期均值；实验表「大文件 200 @2.3s」为单次响应时间（文件体积未记录），二者口径不同，吞吐分仍按 0.03MB/s 计。

### 切换策略

| 条件 | 行为 |
|------|------|
| 候选分 > 当前分 × 1.2 | **切换** |
| 候选分 ≤ 当前分 × 1.2 | **保持**（避免 ping-pong） |
| 距上次切换 < 15 分钟 | **保持**（冷却期） |
| 所有代理不可用 | **报警**（保持当前） |

### Cron 调度

```
*/30 * * * * /usr/bin/python3 /usr/local/bin/proxy-selector
```

每 30 分钟评估一次——不是每次请求。避免"排序陷阱"。

```json
// Xray config 添加更多 outbounds
"outbounds": [
  {"tag": "proxy-1", ...},  // 当前服务器
  {"tag": "proxy-2", ...},  // 备用服务器 1
  {"tag": "proxy-3", ...},  // 备用服务器 2
]

// burstObservatory 自动监控所有 proxy-* 前缀的出站
"burstObservatory": {
  "subjectSelector": ["proxy-"],
  "pingConfig": {"interval": "5m", "sampling": 3, "timeout": "10s"}
}

// leastPing 策略自动选择延迟最低的存活出站
"balancers": [{
  "tag": "proxy-pool",
  "selector": ["proxy-"],
  "strategy": {"type": "leastPing"},
  "fallbackTag": "direct"  // 全部不可用时直连
}]
```

### 获取免费 VLESS 服务器

| 来源 | 更新频率 | 说明 |
|------|---------|------|
| [gfpcom/free-proxy-list](https://github.com/gfpcom/free-proxy-list) | 每 30 分钟 | ~95,000 VLESS |
| [nikita29a/FreeProxyList](https://github.com/nikita29a/FreeProxyList) | 每 10 分钟 | 多协议 |
| [rtwo2/FastNodes](https://github.com/rtwo2/FastNodes) | 定期 | 按地区/协议分类 |

注意：免费代理速度波动大，需要定期测试筛选。

---

## 五、git-retry 使用说明

```bash
# 替代 git 命令，自动重试
git-retry clone https://github.com/user/repo.git

# 等同于
git clone https://github.com/user/repo.git

# 任何 git 子命令都可以
git-retry pull
git-retry fetch --all
```

**熔断器状态**：
- 正常：重试最多 5 次，指数退避
- 代理不可达：自动熔断 5 分钟，避免重试风暴
- 手动清除熔断：`rm /tmp/git-retry-circuit-breaker`

---

## 六、代理选择策略对比

| 策略 | 切换频率 | 稳定性 | 适用场景 |
|------|:------:|:-----:|------|
| **leastPing（每次）** | 极高 | 差 | 不适合——"排序陷阱" |
| **leastPing（定期）** | 低 | 好 | 当前方案——30 分钟评估一次（cron；burstObservatory 5 分钟采样） |
| **显著改善才切换** | 极低 | 最好 | 推荐——20%（×1.2）改善阈值 |
| **手动固定** | 无 | 最好 | 仅 1 个服务器时 |

---

> **关联文档**
> - 完整复盘: `2026-07-21-树莓派网络故障与路由器破解完整复盘.md`
> - 网络路由: `参考-网络路由与代理排障.md`
> - 小米 API: `参考-小米路由器API认证与利用.md`

## Related

- [[AGENTS]] — AI 协作规范
- [[Network-KB-Home]] — 网络知识库
- [[参考-网络路由与代理排障]] — 路由排障
