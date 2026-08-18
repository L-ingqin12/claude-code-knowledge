---
title: 架构设计文档
aliases: [Architecture, 架构]
tags: [network/architecture, network/proxy, network]
created: 2026-07-28
updated: 2026-08-09
---
# 网络优化架构设计文档

> [!info] 文档定位
> 本文档是 [[Network-KB-Home]] 的核心参考，详细记录了网络代理优化架构的设计目标、演进历程和关键技术决策。完整分析见 [[FINAL-SUMMARY]]，优化审计见 [[OPTIMIZATION-AUDIT]]，路由器能力分析见 [[ROUTER-FULL-CAPABILITY]]。
## 一、设计目标

| 目标 | 含义 |
|------|------|
| 用户无感 | 不需要手动维护配置、不需要重启切换 |
| 自适应 | 订阅更新后自动发现新节点，路由器变化后自动适配 |
| 安全 | 保留 Reality 伪装/SNI 指纹，CN IP 直连不泄露，无额外开放端口 |
| 灵活 | 不硬编码节点，不覆盖 v2rayN 原生设置 |
| 容错 | 任何变更先验证后应用，失败自动回滚 |

## 二、架构演进

### Phase 1: 固定多节点配置 (xray-config-optimized.json) — **废弃**

> [!bug] Phase 1 关键问题
> 1. Mux 开启 → VLESS Vision 流被打乱 → Telegram 视频卡住
> 2. 无 catch-all 规则 → 非 Google 境外流量走到第一个出站（韩国节点），不走 balancer
> 3. `outboundTag` 引用 balancer → xray 报 `non existing outTag`
> 4. DNS 走 balancer、数据走第一个出站 → CDN 边缘节点不匹配
> 5. 节点硬编码 → 订阅更新后被 v2rayN 覆盖

**结论**: 固定配置不可行，必须"增强"而非"替换"。

### Phase 2: 定时任务方案 (auto-optimizer.ps1) — **废弃**

> [!warning] 定时轮询的问题
> - 定时轮询浪费资源
> - 节点变动和脚本执行之间存在窗口期
> - 不是事件驱动

### Phase 3: FileSystemWatcher Hook (v2rayn-config-hook.ps1) — **备选**

> [!info] 设计思路
> 监听 v2rayN 的 config.json 写入事件，在 v2rayN 生成新配置后、xray 启动前拦截并增强。

**流程**:
```
v2rayN 写入 config.json
    ↓ FileSystemWatcher 检测变化
    ↓ 延迟 3s（等待写入完成）
    ↓ 检查冷却期（5 分钟，防止死循环）
    ↓ 检查是否已是多节点配置
    ↓ 从 configTest 文件发现节点 + Ping 测速
    ↓ 增强配置（添加出站 + balancer）
    ↓ 写入 config.json
    ↓ v2rayN/xray 读取增强后的配置
```

**优点**: 事件驱动，资源占用极低，完全透明
**缺点**: 依赖 PowerShell 进程常驻；v2rayN 重写配置时会再次触发

**状态**: 代码已完成，作为备选方案保留。当前使用 Phase 4。

### Phase 4: 按需增强脚本 (enhance-config.ps1) — **当前方案**

> [!info] 当前方案
> 订阅更新后手动触发一次，脚本完成测速、评分、配置生成、验证、应用的完整流程。日常无需运行。

**流程**:
```
1. 读取 v2rayN 当前 config.json
2. 从 configTest*.json 发现所有可用节点
3. Ping 所有节点 → 过滤 < 500ms
4. 排除与当前主代理相同地址的节点
5. 去重（每个地址只保留最佳端口）
6. 选 Top 3 不同地理位置的节点
7. 在 v2rayN 原始配置基础上增量添加出站
8. 保留所有原生路由（CN直连/DNS/Reality伪装）
9. 添加 balancer + observatory
10. xray -test 语法验证
11. 原子写入（失败自动回滚原配置）
12. 重启 xray
```

## 三、核心设计决策

### 决策 1: 增强而非替换

**选择**: 读取 v2rayN 的原生配置，只增量修改出站和路由。
**原因**: v2rayN 管理着路由策略（CN 绕过/DNS 分流），直接替换会丢失这些设置。

### 决策 2: Mux 永久禁用

> [!warning] Mux 与 Vision 不兼容
> **选择**: 所有 VLESS+Vision 出站 `mux: false`。
> **原因**: VLESS XTLS-Vision 依赖精确的包时序进行 TLS 伪装。Mux 多路复用会交错不同流的数据包，破坏 Vision 的流顺序，导致队头阻塞。实测：开启 Mux → Telegram 视频卡住。

### 决策 3: DNS 走固定代理

**选择**: DNS 模块路由到原始代理 (`proxy` tag)，不使用 balancer。
**原因**: DNS 解析时，CDN 根据 DNS 出口 IP 返回最优边缘节点。如果 DNS 走 balancer（可能选韩国节点），数据走另一个节点，CDN 边缘节点不匹配 → 视频加载失败。

### 决策 4: catch-all → balancer

**选择**: 末尾添加 `network: tcp,udp → balancerTag: balancer`。
**原因**: 没有 catch-all 时，未匹配流量走到 `outbounds[0]`（第一个出站），绕过了 balancer。

### 决策 5: balancerTag 而非 outboundTag

**选择**: 路由规则中引用 balancer 时用 `balancerTag` 字段。
**原因**: xray 的路由分发器对 `outboundTag` 只在出站列表中查找，对 `balancerTag` 在 balancers 列表中查找。用错字段 → `non existing outTag` 错误。

> [!bug] 2026-08-09 实测：v2rayN 7.19.5 GUI 均衡组自己也生成 `outboundTag`
> 在 GUI 配置均衡组后，v2rayN 生成 `{"domain":["geosite:google"],"outboundTag":"balancer"}` 的无效规则 → Google 全挂、其余网站正常。已用 watcher（`fix_balancer_watcher.ps1`）自动改写为 `balancerTag` 并重启 xray。完整事故复盘见 [[v2rayn-balancer-复盘-2026-08-09]]。**注意：本决策此前只防住了外部脚本，没防住 v2rayN 原生生成。**

### 决策 6: 排除原始代理地址

**选择**: 候选节点中排除与主代理相同 IP 的节点。
**原因**: 同一服务器不同端口没有地理多样性价值。不排除的话，39 个订阅节点中 ~25 个是 p1d2 不同端口，选出来的全是同一台机器。

### 决策 7: 安全约束

> [!info] 安全约束一览
> | 约束 | 实现 |
> |------|------|
> | Reality 指纹伪装 | 保留 v2rayN 为每个节点配置的独立 SNI/公钥/fingerprint |
> | DNS 防泄露 | CN 域名 → Alibaba DNS（直连）；境外 → Cloudflare DNS（通过代理） |
> | CN IP 直连 | 保留 `geoip:cn → direct` 和 `geosite:cn → direct` |
> | UDP 443 阻断 | 保留 `port:443, network:udp → block` 防 QUIC 绕过代理 |
> | 无开放端口 | 代理仅监听 [IP已脱敏]:10808，不对局域网开放 |

## 四、文件说明

| 文件 | 状态 | 说明 |
|------|------|------|
| `enhance-config.ps1` | **当前** | 按需增强脚本，订阅更新后运行 |
| `v2rayn-config-hook.ps1` | 备选 | FileSystemWatcher 事件驱动 hook |
| `auto-optimizer.ps1` | 废弃 | 定时任务方案 |
| `generate-xray-config.sh` | 废弃 | Bash 版配置生成器 |
| `score-nodes.ps1` | 废弃 | 复合评分原型（速度测试不稳定） |
| `xray-config-v2-working.json` | 当前生效 | 最终增强配置 |
| `xray-config-optimized.json` | 存档(有Bug) | v1 固定配置 |
| `xray-config-fixed.json` | 存档(有Bug) | v2 修复尝试 |
| `config.json.bak-20260728` | 备份 | v2rayN 原始配置 |
| `proxy-nodes.json` | 参考 | 代理节点速查表 |
| `network-analysis-2026-07-28.md` | 参考 | 完整网络分析 |

## 五、未来可能的增强
1. **下载速度综合评分**: 在 Ping 排序后对 Top 节点做 1MB 下载测试，延迟+速度加权评分（30/70）。当前因临时 xray 实例启动不稳定暂缓。
2. **Hook 常驻模式**: 将 FileSystemWatcher 方案作为 v2rayN 的透明 hook 启用，订阅更新后全自动处理。当前用户可以按需运行 enhance-config。
3. **v2rayN 原生多选**: v2rayN 本身支持多选服务器后自动生成 balancer 配置（`GenerateClientMultipleLoadConfig`），如 v2rayN 后续版本在 GUI 中暴露此功能，则可完全替代外部脚本。
