---
title: v2rayN Balancer 生成 Bug 故障复盘
aliases: [v2rayN balancer bug, Google 无法访问 2026-08-09, balancerTag 修复, outboundTag balancer]
tags: [incident, network/proxy, network/analysis]
created: 2026-08-09
updated: 2026-08-25
status: stable
---
# v2rayN Balancer 生成 Bug — Google 无法访问完整复盘

See also: [[Network-KB-Home]] | [[ARCHITECTURE]] | [[GUIDE]] | [[参考-网络路由与代理排障]]

> **日期**: 2026-08-09
> **环境**: Windows 11 + v2rayN 7.19.5 便携版 + xray core 26.3.27（混合入站 10808）
> **核心问题**: 代理对大多数网站正常，但 Google 搜索 / YouTube 无法访问
> **根因**: v2rayN 生成配置时产出**无效路由规则** `{"domain":["geosite:google"],"outboundTag":"balancer"}` —— xray 的 `outboundTag` 只能引用出站，不能引用 balancer；必须用 `balancerTag`。该规则使所有 google 域名流量在**路由阶段被瞬间拒绝**（0.01s TLS 失败），而 catch-all 规则用 `balancerTag` 正常工作，所以"其他网站都正常"。
> **结论**: 已修复 ✅ watcher 自动修复脚本 + 开机自启，端到端验证通过。

---

## 目录

1. [现象与影响](#1. 现象与影响)
2. [诊断过程（排除法）](#2. 诊断过程（排除法）)
3. [根因分析](#3. 根因分析)
4. [关键证据：对照实验](#4. 关键证据：对照实验)
5. [修复方案演进](#5. 修复方案演进)
6. [节点稳定性实测](#6. 节点稳定性实测)
7. [上游信息](#7. 上游信息)
8. [经验教训](#8. 经验教训)
9. [关联文档与脚本](#9. 关联文档与脚本)

---

## 1. 现象与影响

| 目标 | 结果 |
|------|------|
| 代理下访问 Google 搜索 / YouTube | ❌ 打不开（TLS 秒拒，~0.01s） |
| 代理下访问其他境外网站 | ✅ 正常 |
| 代理下访问国内网站 | ✅ 正常 |

> [!bug] 症状特征
> Google 系失败是**瞬间拒绝**（0.01s 级 TLS 失败），而非超时/慢。这是"路由层直接拒绝"而非"节点不通"的典型特征 —— 节点问题表现为超时或 RST 重试，不会如此干脆。

---

## 2. 诊断过程（排除法）

### 2.1 排除节点问题（SNI 过滤测试）

> [!info] 测试方法
> 通过代理访问固定 IP + 不同 SNI：SNI 过滤被墙的节点，google SNI 会被重置；正常节点无论 SNI 都通。

- 固定 IP + baidu SNI → 200（节点本身能通 google IP）
- 固定 IP + google SNI → 连接被重置
- **一度误判为节点被墙** —— 但同一节点用其他配置文件直连 google SNI 却通，矛盾点最终指向配置本身

### 2.2 排除 DNS 问题

- xray DNS 模块 geosite:google → Cloudflare DoH（无污染）
- 本地系统 DNS（[IP已脱敏], 勘误: 原记 [IP已脱敏]，与全库上游路由器口径统一）确实被污染（google → Facebook IP [IP已脱敏]），但只影响直连流量，代理流量走 xray 自己的 DNS，不受影响

### 2.3 定位配置层

用 `C:\Users\28064\AppData\Local\Temp\xraytest\` 的单节点配置逐个排除（`gen_configs.py` 从 v2rayN 数据库生成）：

| 配置变体 | 结果 | 结论 |
|----------|------|------|
| 原样单节点配置 | Google 通 | 节点没问题 |
| variant A（去掉 observatory） | 行为不变 | 与观测器无关 |
| **variant C（规则改 balancerTag）** | **Google 204** ✅ | **规则字段是根因** |

---

## 3. 根因分析

v2rayN 7.19.5 的 GUI 均衡组（多选服务器生成 balancer）产出的路由规则：

```json
// ❌ v2rayN 生成的（无效）
{"domain": ["geosite:google"], "outboundTag": "balancer"}

// ✅ 正确的
{"domain": ["geosite:google"], "balancerTag": "balancer"}
```

> [!warning] 机制
> xray 路由分发器对 `outboundTag` **只在 outbounds 列表查找**，找不到 `balancer` 标签 → 该规则匹配到的所有流量（全部 google 域名）被**直接拒绝**。catch-all 规则用的是 `balancerTag`，所以其余境外流量正常。这与 [[ARCHITECTURE#决策-5-balancertag-而非-outboundtag]] 记录的机制一致 —— 但 v2rayN 自己生成时**也会犯同样的错**。

**为什么之前没发现**：此前 [[ARCHITECTURE]] 的增强脚本（Phase 4）只增量添加出站，不碰 v2rayN 原生路由；而本次在 GUI 里配置了均衡组，v2rayN 生成路由时把 bug 带进来了。

---

## 4. 关键证据：对照实验

同节点、同 google SNI、同 DNS，仅改规则字段：

```
variant C (balancerTag):  https://[域名已脱敏]/generate_204 → 204 ✅
原配置 (outboundTag):     https://[域名已脱敏]/generate_204 → TLS 秒拒 ❌
```

> [!success] 证据链完整
> 节点 ✅ → DNS ✅ → 规则 ❌（唯一变量）→ 修复后 204。根因确凿。

---

## 5. 修复方案演进

### 方案 A：手动改运行配置（即时生效，会复发）

把规则 `outboundTag` 改为 `balancerTag`，重启 xray → 立即恢复。**但 v2rayN 每次重新生成 config.json（切均衡组 / 重启 core）都会重新引入 bug**。

### 方案 B：watcher 自动修复 + 开机自启（用户选定 ✅）

> [!success] 最终方案
> **Watcher**: `scripts/fix_balancer_watcher.ps1`（位于本 Vault `network/scripts/`）
> **开机自启**: `%AppData%\Microsoft\Windows\Start Menu\Programs\Startup\v2rayN-balancer-fix.vbs`
> （schtasks / Register-ScheduledTask 权限被拒，改用 Startup 文件夹 VBS 启动隐藏 PowerShell）

**工作流程**（每 3s 轮询，非事件驱动但足够轻量）：

```
v2rayN 重写 config.json
    ↓ 检测 mtime 变化（>1s）
    ↓ 等 1.5s（写入完成）
    ↓ 解析 JSON，扫描路由规则
    ↓ 发现 domain=geosite:google 且 outboundTag=balancer
    ↓ 改写为 balancerTag
    ↓ 写入（UTF8 无 BOM）
    ↓ 杀掉 v2rayN 的 xray 进程 → 500ms → 隐藏启动 xray run -c config.json
```

> [!success] 端到端验证
> 手动注入 bug 规则 → ~15s 内 watcher 自动修复 + xray 重启 → Google 恢复 204。

### 手动修复配方（应急）

```powershell
# 把 config.json 里该规则的 "outboundTag": "balancer" 改成 "balancerTag": "balancer"，重启 xray
$cfg = "D:\Document\Download\v2rayN-windows-64-desktop\v2rayN-windows-64\binConfigs\config.json"  # <你的v2rayN目录>\binConfigs\config.json
(Get-Content $cfg -Raw) -replace '"outboundTag"\s*:\s*"balancer"', '"balancerTag": "balancer"' | Set-Content $cfg -Encoding utf8NoBOM
taskkill /F /IM xray.exe   # 结束后由 v2rayN 重启核心（或在 v2rayN 中手动重启）
```

---

## 6. 节点稳定性实测

live balancer 实测（2026-08-09），**运行池已换成 4 个稳定节点**：

| 节点 | 别名 | 状态 |
|------|------|------|
| px-sg1 | 新加坡1 | ✅ 稳定（当前池） |
| px-us1 | 美国1 | ✅ 稳定（当前池） |
| px-us3 | 美国3-双ISP | ✅ 稳定（当前池） |
| px-jp1 | 日本-01 | ✅ 稳定（当前池） |
| px-dtwo1-10000 | 韩国1 动态家宽 | ⚠️ 波动大（ipify 5 次挂 2 次），已移出池 |
| px-221-10000 | 韩国2 | ⚠️ 波动，已移出池 |
| [域名已脱敏]:32769 | 新加坡2 | ⚠️ 不稳，已移出池 |
| TW1 | 台湾直连 | ❌ 宕机 |
| SG6 | 新加坡6 | ❌ google 失败 |

> [!warning] 遗留事项
> v2rayN GUI 均衡组仍显示「新加坡2 + 韩国×2」。watcher 只修规则不换节点，若 v2rayN 重新生成配置会把不稳节点加回池 → **建议在 GUI 中把均衡组成员也改为 SG1/US1/US3/JP1**（一次性同步）。
> **状态**: GUI 池同步为待办；未完成前以配置文件（balancer 池 SG1/US1/US3/JP1）为准。

验证结果（新池，10808 live proxy）：Google generate_204 204 ×3（1.1s/1.1s/7.9s）、YouTube 200、出口 [IP已脱敏]。

---

## 7. 上游信息

v2rayN 的 balancer 路由在多个版本间反复回归（[[ARCHITECTURE]] Phase 1 曾记录 `outboundTag` 引用 balancer 报 `non existing outTag`）：

- GitHub v2rayN issue **#8849** — Fix balancer routing
- GitHub v2rayN issue **#9699** — 7.23.2 的 balancer 回归
- GitHub PR **#9727** — Revert "Fix"（修复被回退）
- 最新版 7.24.6（2026-08-08）—— 未验证是否修复

> [!tip] 结论
> 此功能版本间反复横跳，升级 v2rayN 不能依赖，watcher 是当前最稳妥的兜底。

---

## 8. 经验教训

1. **"秒拒" vs "超时" 是路由层 vs 链路层的分水岭** —— 0.01s TLS 失败先查配置/规则，而不是节点。
2. **对照实验要单变量** —— 同节点、同 SNI、同 DNS，只改一个字段，才能把锅甩给配置而不是节点（SNI 测试一度误导诊断为节点被墙）。
3. **GUI 生成 ≠ 正确生成** —— 工具自动生成的配置也可能违反工具自己文档化的规则（[[ARCHITECTURE#决策-5-balancertag-而非-outboundtag]]）。
4. **自动修复要防复发** —— 手动修一次不够，v2rayN 每次重新生成都会复现；事件驱动的 watcher（轮询 mtime）是低成本的兜底方案。
5. **动态家宽节点不可靠** —— 韩国动态家宽在 leastPing 池里 5 次挂 2 次，多节点池应只放实测稳定的机房节点。

---

## 9. 关联文档与脚本

> **文档**
> - [[Network-KB-Home]] — 网络知识库 MOC
> - [[ARCHITECTURE#决策-5-balancertag-而非-outboundtag]] — balancerTag 机制设计决策
> - [[GUIDE]] — 日常使用指南（含本事故排查条目）
> - [[参考-网络路由与代理排障]] — 路由/代理排障参考

> **脚本**
> - `network/scripts/fix_balancer_watcher.ps1` — 当前方案（watcher，2026-08-09 新增）
> - `%AppData%\...\Startup\v2rayN-balancer-fix.vbs` — 开机自启启动器
> - `enhance-config.ps1` — 按需增强脚本（[[ARCHITECTURE]] Phase 4，不修此 bug）
> - 测试基建: `C:\Users\28064\AppData\Local\Temp\xraytest\`（`gen_configs.py`、`run_tests.sh`、`launch_test.ps1`、`batch_test.sh`、各节点单测配置）

> [!note] 测试要点
> Windows schannel 本地 CRL 检查被墙报 `CRYPT_E_REVOCATION_OFFLINE`，curl 测试一律加 `--ssl-no-revoke`。
