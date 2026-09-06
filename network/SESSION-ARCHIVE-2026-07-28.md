---
title: 会话复盘归档 (2026-07-28)
aliases: [Session Archive, 会话归档, 2026-07-28 全记录]
tags: [meta, incident, network/optimization]
created: 2026-07-28
updated: 2026-08-25
status: stable
---

# 会话复盘归档 — 2026-07-27~28 网络全栈优化

> [!abstract] 会话概要
> 起因: 网络速率慢、Telegram 视频卡顿。历时 ~6 小时，覆盖 4 层诊断、代理 6 个 Bug 修复、路由器 SSH 恢复、7 项路由器优化、Obsidian 知识库重构、视频 QoS/远程/监测三大能力实施。

See also: [[Network-KB-Home]] | [[FINAL-SUMMARY]] | [[ARCHITECTURE]]

---

## Phase 1: 初始诊断 (2026-07-27 23:00)

### 发现问题

| 指标 | 发现 | 严重度 |
|------|------|--------|
| WiFi 网关延迟 | 2ms~541ms, avg 154ms（原记 7~457ms/avg 134ms，与 Phase 4 原始测量统一） | 🔴 极差 |
| 代理吞吐 | ~6 Mbps (761 KB/s)（2026-07-27 实测） | 🟡 偏低 |
| 代理服务器 | 仅 `[域名已脱敏]` 单节点 | 🔴 无冗余 |
| 代理协议 | VLESS+Reality, Mux 未开 | 🟡 |
| 系统代理 | v2rayN 10808, 开启 | ✅ |
| VPN | v2rayN + xray 26.3.27 | ✅ |

### 发现的关键信息

- v2rayN 有 **17 个可用节点**（4 供应商），但只用了 1 个
- 路由器确认: Xiaomi R4CM, fw 2.14.87, SSH 不通
- 系统代理开启, 出口 IP [IP已脱敏]
- WiFi: 2.4GHz, 802.11n, 72.2Mbps, 13 设备在线(含 8 ESP32 IoT)

---

## Phase 2: 代理多层 Bug 修复

### Bug 1: Mux + VLESS Vision 冲突
- **根因**: Mux 交错数据包 → Vision 流顺序被破坏 → 队头阻塞
- **修复**: 所有 VLESS 出站 `mux: false`
- **参考**: [[ARCHITECTURE#决策 2]]

### Bug 2: 无 catch-all 规则
- **根因**: 未匹配流量走到 `outbounds[0]`（韩国节点），绕过 balancer
- **修复**: 添加 `network: tcp,udp → balancerTag: balancer`
- **参考**: [[ARCHITECTURE#决策 4]]

### Bug 3: `outboundTag` 引用 balancer
- **根因**: xray 路由规则中引用 balancer 需用 `balancerTag` 字段
- **修复**: `outboundTag: "balancer"` → `balancerTag: "balancer"`
- **参考**: [[ARCHITECTURE#决策 5]]

### Bug 4: DNS 路径分裂
- **根因**: DNS 走 balancer(可能选韩国), 数据走另一个节点 → CDN 不匹配
- **修复**: DNS 模块走原始 `proxy` (p1d2)
- **参考**: [[ARCHITECTURE#决策 3]]

### Bug 5: catch-all 检测误判
- **根因**: `udp:443→block` 规则匹配了 catch-all 检测条件 → catch-all 未被添加
- **修复**: 增加 `network -eq "tcp,udp"` 精确判断

### Bug 6: Balancer 含 US 高延迟节点
- **根因**: 39 个订阅节点中选了 3 个 US 节点 (225ms+)
- **修复**: balancer selector 改为 `["proxy"]` only, 其他节点降为 fallback

### 最终指标

| 指标 | 优化前 | 优化后 |
|------|--------|--------|
| httpbin 响应 | 4.3s | 1.4s |
| Balancer | 无 | proxy-only + fallback |
| Mux | 开启 | 关闭 |
| Observatory | 无 | 10min |
| Catch-all | 缺失 | 已添加 |

---

## Phase 3: 路由器 SSH 恢复

### 尝试历程

| 尝试 | 方法 | 结果 |
|------|------|------|
| 1 | `ssh root@[IP已脱敏]` (Windows OpenSSH) | 超时 |
| 2 | 防火墙可能拦截 MSYS2 ssh | 确认 |
| 3 | 端口探测 | Port 22 OPEN (dropbear 0.52) |
| 4 | sshpass + MobaXterm ssh | ✅ 成功 |
| 5 | 密钥免密登录 | ❌ dropbear 0.52 不兼容现代密钥 |
| 6 | sshpass wrapper 脚本 | ✅ 稳定方案 |

### 最终连接方式

```bash
bash scripts/router_ssh.sh "command"
# 或直接:
/d/Users/28064/AppData/Roaming/MobaXterm/slash/bin/sshpass -p [已脱敏] \
  /d/Users/28064/AppData/Roaming/MobaXterm/slash/bin/ssh \
  -o KexAlgorithms=+diffie-hellman-group1-sha1 \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o MACs=+hmac-sha1-96,hmac-sha1,hmac-md5 \
  root@[IP已脱敏]
```

---

## Phase 4: 路由器优化 (7 项)

| # | 优化 | 方法 | 状态 |
|---|------|------|------|
| 1 | AP 隔离永久关闭 | `/etc/config/wireless` → `option isolate 0` | ✅ 已持久化 |
| 2 | 加密 psk2+ccmp | `/etc/config/wireless` 直接修改 | ✅ |
| 3 | 固定信道+40MHz | sed 写配置 + wifi reload | ⚠️ 固件覆盖 |
| 4 | OTA 自动更新禁用 | `/data/etc/config/otapred` → `auto 0` | ✅ |
| 5 | 遥测禁用 | rc.local kill datacenter+rmonitor | ✅ 永久 |
| 6 | DNS 缓存翻倍 | `cache-size=2000`, HUP dnsmasq | ✅ |
| 7 | WiFi 省电模式(客户端) | 注册表 PnPCapabilities=24 | ⚠️ 需管理员 |

### 延迟改善

| 阶段 | Min | Max | Avg |
|------|-----|-----|-----|
| 原始 | 2ms | 541ms | 154ms |
| 优化后 | 2ms | 113ms | 31ms |
| **改善** | — | **-79%** | **-80%** |

---

## Phase 5: 路由器深度探索

### 关键发现

- **431 个命令**可用（口径: 431=系统可用命令总数, 其中 busybox applet 146 个，见 [[ROUTER-FULL-CAPABILITY]]）, 但 **iptables/tcpdump/tc 不可用**
- **insmod 存在** (busybox), 内核模块已全加载
- **debugfs 不可用** → MT7628 帧缓冲 Bug 无法修复
- **Factory 分区** mtd3 可解锁 TX power (14→30 dBm, 勘误: iwinfo 实测当前已 18 dBm，见 [[ROUTER-DEEP-EXPLORATION]]), 但风险 >> 收益, 不建议
- **无固件签名** → 可刷 OpenWrt
- **iweventd 钩子**可用来在 WiFi 事件时自动执行脚本

文档: [[ROUTER-DEEP-EXPLORATION]], [[ROUTER-FULL-CAPABILITY]]

---

## Phase 6: 知识库 Obsidian 重构

### 改造内容

- 9 个 Markdown 文档全部添加 YAML frontmatter
- 嵌套标签体系: `#network/router`, `#network/proxy`, `#network/optimization`, `#network/architecture`, `#network/guide`, `#network/analysis`
- **90+ 个内部 Wikilinks**（持续增长）— Graph 视图高度连通
- Excalidraw 关系图 ![[Network-DocGraph.excalidraw]] 在 MOC 首页
- Obsidian callouts (info/warning/danger/bug/success)
- [[AGENTS]] 定义 AI 协作规范
- 笔记模板 `scripts/new-note.md`
- 脚本/配置文件归入 `scripts/` 子目录

文件: [[Network-KB-Home]], [[GUIDE]], [[ARCHITECTURE]], [[FINAL-SUMMARY]], [[OPTIMIZATION-AUDIT]], [[ROUTER-OPTIMIZATION]], [[ROUTER-DEEP-EXPLORATION]], [[ROUTER-FULL-CAPABILITY]], [[network-analysis-2026-07-28]]

---

## Phase 7: 三大能力实施

### 视频优化
- WMM QoS: ✅ 已启用 (WiFi 驱动级)
- miqos: ❌ 不可用 (依赖 uci, R4CM 缺失)
- sysctl TCP 调优: ✅ 已有

### 远程访问
- frp 穿透 (tmpfs): 推荐方案, 需外部 frps
- SSH -R 反弹: 需外部 VPS
- DDNS + 转发: 需上游路由器配合
- smartvpn: ❌ 服务器 [IP已脱敏] 已不可达

### 流量监测
- `traffic_monitor.sh`: ✅ 已部署 (/userdisk, ~800B)
- cron 每分钟采样: ✅ 已激活
- 日志自动轮转: ✅ ≤14KB, 保留 200 行
- 设备级速率: ✅ 通过 API 可用

文档: [[ROUTER-VIDEO-REMOTE-MONITOR]]

---

## 未解决项

| 项目 | 状态 | 原因 |
|------|------|------|
| QCA9377 驱动更新 | ⚠️ | Dell G3 3590 官方 [IP已脱敏](2019) 比当前 12.0.0.1118(2021) 更旧 |
| MT7628 帧缓冲 Bug | ❌ | 需 debugfs (原厂内核不支持) → 需刷 OpenWrt |
| SSH 密钥免密 | ❌ | dropbear 0.52 与现代 OpenSSH 密钥格式不兼容 |
| telnetd 启动 | ❌ | busybox telnetd 无法正常监听 |
| 双 NAT 消除 | ⬜ | 需上游路由器改桥接或 R4CM 改 AP 模式 |
| 复合评分(速度+延迟) | ⬜ | 临时 xray 实例不稳定, 暂缓 |
| FileSystemWatcher Hook | ⬜ | 备选方案, 当前按需增强足够 |

## 产出清单

```
D:\Document\local\knowledge\
├── AGENTS.md                                    ← AI 协作规范
├── scripts/new-note.md                          ← 笔记模板
└── network/
    ├── Network-KB-Home.md                       ← MOC 首页 + Excalidraw 关系图
    ├── GUIDE.md                                 ← 使用指南
    ├── ARCHITECTURE.md                          ← 架构设计 (4 阶段 + 7 决策)
    ├── FINAL-SUMMARY.md                         ← 优化总结
    ├── OPTIMIZATION-AUDIT.md                    ← 优化审计 (15 项 + 6 漏洞)
    ├── ROUTER-FULL-CAPABILITY.md                ← 路由器完全能力手册
    ├── ROUTER-DEEP-EXPLORATION.md               ← 路由器深度探索
    ├── ROUTER-OPTIMIZATION.md                   ← 路由器优化分析
    ├── ROUTER-VIDEO-REMOTE-MONITOR.md           ← 视频/远程/监测方案
    ├── network-analysis-2026-07-28.md           ← 初始网络分析
    ├── SESSION-ARCHIVE-2026-07-28.md            ← 本归档
    └── scripts/                                 ← 脚本与配置 (15 个文件)
```
