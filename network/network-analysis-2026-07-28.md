---
title: 初始网络全栈分析
aliases: [网络分析, 初始诊断]
tags: [network/analysis, network]
created: 2026-07-28
updated: 2026-08-25
status: review
---

# 家庭网络全栈分析与优化 (2026-07-28)

See also: [[Network-KB-Home]] | [[FINAL-SUMMARY]] | [[ARCHITECTURE]] | [[ROUTER-OPTIMIZATION]]

## 一、拓扑架构

```
Internet → [光猫/上游路由 [IP已脱敏]]
                ↓ (eth0.2, DHCP)
          [Xiaomi R4CM [IP已脱敏]] — 2.4GHz 802.11n WiFi
                ↓ (WiFi 信号 -58dBm, 72.2Mbps 协商速率)
          [Windows 11 Laptop [IP已脱敏]]
                ↓ (系统代理 [IP已脱敏]:10808)
          [xray 26.3.27 — VLESS+Reality]
                ↓ (直连/代理分流)
          [Target Services]
```

### 硬件清单

| 设备 | 型号/信息 | 角色 |
|------|-----------|------|
| 上游路由器 | [IP已脱敏] | 光猫/一级 NAT |
| 小米路由器 | R4CM, MT7628 单核 575MHz, 64MB DDR2, fw 2.14.87 | 二级 NAT, WiFi AP |
| 笔记本网卡 | Qualcomm QCA9377 802.11ac | WiFi 客户端 |
| 代理客户端 | v2rayN + xray 26.3.27 | 流量分流 |

## 二、四层瓶颈诊断

### L1 — WiFi 物理层

| 指标 | 当前值 | 评级 |
|------|--------|------|
| 频段/协议 | 2.4GHz / 802.11n | 差 — 无法用 5GHz |
| 协商速率 | 72.2 Mbps (20MHz 单流) | 实际吞吐 ~35 Mbps |
| 信号强度 | 88% (2026-07-27 初测), RSSI -58 dBm | 良好 |
| 网关延迟 | 2ms ~ 541ms, 平均 154ms | 极差 — 严重抖动 |
| 信道 | 6 (2.4GHz), 利用率 13% | 中等 |
| 接入设备数 | 13 (含 8 个 ESP32 IoT) | 偏高 |
| 网卡驱动 | 2021-05-19 v12.0.0.1118 | 过时 — 已知延迟问题 |

**根因**: R4CM 是单频路由器 (仅 2.4GHz)，无法利用 QCA9377 的 5GHz/AC 能力。8 个 ESP32 设备 + 过时驱动 → 信道争用 → 延迟抖动。

**优化方案 (按优先级)**:
1. 更新 QCA9377 驱动 (Dell/高通 2022+) → 延迟抖动降低 50-80%
2. 更换双频路由器 (如 AX3000/AX6S) → 彻底解决, 5GHz 可达 300+ Mbps
3. 尝试 HT40 (40MHz 带宽) → 协商速率翻倍至 150 Mbps
4. 如不用蓝牙则禁用 → 减少 2.4GHz 共存干扰

### L2 — 路由器层

| 指标 | 当前值 | 评级 |
|------|--------|------|
| CPU 负载 | 0.30 (30%) | 正常 |
| 内存使用 | 50% (32/64MB) | 偏高但未饱和 |
| 在线时长 | ~6 天 | 正常 |
| NAT 层数 | 双 NAT (192.168.31.x → 192.168.1.x) | 差 — 增加延迟 |
| WAN 吞吐 | 下行峰值 9.3 MB/s (~74 Mbps) | 受 WiFi 限制 |

**根因**: 64MB RAM + 13 设备连接跟踪表压力。双 NAT 每包多一跳。

**优化方案**:
1. 将上游路由改为桥接模式 → 消除双 NAT
2. 或 R4CM 改为 AP 模式 → 由上游路由统一 NAT
3. SSH 进入后可调整 conntrack 参数

> 路由器 API: `[IP已脱敏]` — stok 登录机制, 密码 = WiFi 密码
> SSH: root@[IP已脱敏]:22 (旧加密套件), 密码 root

### L3 — 代理策略层 (v2rayN/xray)

| 指标 | 当前值 | 评级 |
|------|--------|------|
| 代理节点数 | 1 (fuck.p1d2.com) | 差 — 无冗余 |
| Mux 多路复用 | 关闭 | 初始误判「差」— 复盘确认 Vision 下必须关闭（见下方勘误） |
| 负载均衡 | 无 | 差 |
| 健康检查 | 无 | 差 |
| 直连策略 | CN 直连 + Google 代理 | 合理 |

**可用代理节点 (节选 6 个, 全部 17 个来自 4 个供应商)**:

| 节点 | 延迟 | 状态 |
|------|------|------|
| dtwo1.kt.ddns.koreais.best (韩国 KT) | 70ms | **最佳** |
| fuck.p1d2.com (主服务器) | 90ms | 当前 |
| sg1.718node.com (新加坡) | 334ms | 备用 |
| a1.718node.com (亚洲) | 436ms | 备用 |
| us1.dengta.lat (美国) | 255ms | 可用 |
| z3.dengta.lat (日本) | 370ms | 可用 |

**优化后的配置**: 见 `scripts/xray-config-optimized.json`
- 4 节点出站 (KR 主力 + P1D2 + SG + A1)
- Mux 开启 (concurrency=8)
- Observatory 健康检查 (每 2 分钟)
- Balancer 负载均衡 (leastPing 策略, 自动故障转移)

> [!warning] 勘误：Mux 开启为致障配置
> 后续复盘确认「Mux 开启 (concurrency=8)」与 VLESS Vision 冲突（队头阻塞 → Telegram 视频卡死），已回退为 `mux: false`。本节「优化后的配置」对应 Phase 1 存档 `scripts/xray-config-optimized.json`，已被废弃。详见 [[v2rayn-balancer-复盘-2026-08-09]] 与 [[ARCHITECTURE#决策 2]]。

### L4 — 代理服务器层

| 指标 | 当前值 | 评级 |
|------|--------|------|
| 代理延迟 | 78-89ms, 20% 丢包 | 差 |
| 代理吞吐 | ~5 Mbps (587 KB/s) | 差 |
| 直连外网 | <20 KB/s (基本被封) | 极差 |

**根因**: `fuck.p1d2.com` 服务器性能/带宽受限。直连外网被 QoS/GFW 限速。

## 三、速度基准测试 (2026-07-27)

| 测试路径 | 延迟 | 下载速度 | 备注 |
|----------|------|----------|------|
| Ping 网关 (WiFi) | 2-541ms (avg 154ms) | — | 极不稳定 |
| Ping [IP已脱敏] (阿里 DNS) | 16-274ms (avg 92ms) | — | 经 WiFi+双 NAT |
| Ping [IP已脱敏] | 212-248ms (avg 224ms) | — | 正常 (中国到美国) |
| 直连 speedtest.tele2.net | — | ~16 KB/s | 基本被封 |
| 代理 (fuck.p1d2.com) | 90ms | ~5 Mbps | 当前主力 |
| 代理 (dtwo1, 理论上) | 70ms | 待实测 | 理论更快 |

## 四、路由器设备清单 (13 在线)

| 设备 | IP | 类型 | 在线时长 |
|------|-----|------|----------|
| Laptop (本机) | [IP已脱敏] | Windows 11 | ~1.5h |
| Redmi-K60 | [IP已脱敏] | 手机 | ~15.5h |
| REDMI-K90 | [IP已脱敏] | 手机 | ~1h |
| BNE-AL00 | [IP已脱敏] | 手机 | ~1.8h |
| OnePlus-Ace-2V | [IP已脱敏] | 手机 | ~4.2h |
| ESP_24A3E8 | [IP已脱敏] | IoT | ~4d |
| ESP_098195 | [IP已脱敏] | IoT | ~4d |
| ESP_09610B | [IP已脱敏] | IoT | ~4d |
| ESP_4F95CF | [IP已脱敏] | IoT | ~4d |
| ESP_25B21B | [IP已脱敏] | IoT | ~4d |
| ESP_4F8F46 | [IP已脱敏] | IoT | ~4d |
| ESP-AA48A5 | [IP已脱敏] | IoT | ~4d |
| Unknown | [IP已脱敏] | ? | ~2min |

## 五、v2rayN 优化操作步骤

### 方案 A: 直接替换 config.json (立即生效)

```bash
# 1. 关闭 v2rayN 的系统代理
# 2. 备份当前配置
cp binConfigs/config.json binConfigs/config.json.bak
# 3. 替换为优化配置
cp D:/Document/local/knowledge/network/scripts/xray-config-optimized.json binConfigs/config.json
# 4. 重启 v2rayN 代理
```

### 方案 B: v2rayN GUI 手动配置

在 v2rayN 界面中:
1. 添加多个服务器配置 (dtwo1, p1d2, sg1, a1)
2. 右键 → "测试服务器真连接延迟"
3. 选择延迟最低的服务器
4. ~~设置 → 参数设置 → 启用 Mux 多路复用 (并发 8)~~（⚠️ 勘误: 勿启用 — Vision 下 Mux 致障，见 L3 勘误）

### 代理节点配置模板 (VLESS+Reality)

所有节点共享同一用户凭证:
- UUID: `[已脱敏]`
- Flow: `xtls-rprx-vision`
- Security: `reality`
- Transport: `tcp`

## 六、路由器管理速查

### API 登录
```bash
KEY="a2ffa5c9be07488bbb04a3a47d3c5f6a"
DEV_ID="42:23:e1:18:d7:e2"
PW="19890520"
NONCE="0_${DEV_ID}_$(date +%s)_${RANDOM}"
INNER=$(echo -n "${PW}${KEY}" | openssl sha1 | cut -d' ' -f2)
OUTER=$(echo -n "${NONCE}${INNER}" | openssl sha1 | cut -d' ' -f2)
STOK=$(curl -s "http://[IP已脱敏]/cgi-bin/luci/api/xqsystem/login" \
  --data "username=admin&password=${OUTER}&logtype=2&nonce=${NONCE}" \
  | grep -oP '"token":"[^"]+"' | cut -d'"' -f4)
```

### 常用 API
```bash
B="http://[IP已脱敏]/cgi-bin/luci/;stok=$STOK"

# 设备列表
curl -s "$B/api/misystem/devicelist"

# 系统状态 (CPU/RAM/WAN 吞吐)
curl -s "$B/api/misystem/status"

# 关闭 AP 隔离 (临时, hostapd 重载后失效)
curl -s "$B/api/xqnetwork/set_wifi" --data "isolate=0"

# 路由器信息 (免认证)
curl -s http://[IP已脱敏]/cgi-bin/luci/api/xqsystem/bdata
```

### SSH 连接 (MobaXterm sshpass + 旧加密套件)
```bash
# 原生 Windows OpenSSH 已证实超时不可用，需 MobaXterm sshpass + 旧加密套件
/d/Users/28064/AppData/Roaming/MobaXterm/slash/bin/sshpass -p [已脱敏] \
  /d/Users/28064/AppData/Roaming/MobaXterm/slash/bin/ssh \
  -o KexAlgorithms=+diffie-hellman-group1-sha1 \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o MACs=+hmac-sha1-96,hmac-sha1,hmac-md5 \
  -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
  root@[IP已脱敏] "<command>"

# Wrapper
bash scripts/router_ssh.sh "<command>"
```

### 永久关闭 AP 隔离 (需 SSH)
```bash
sed -i '/option ssid.*302-1/a\toption isolate 0' /etc/config/wireless
/sbin/wifi reload
```

## 七、路由器优化操作

### 已执行 (2026-07-28)

| 操作 | API | 结果 |
|------|-----|------|
| 关闭 AP 隔离 | `set_wifi` → `isolate=0` | `code:0` — 生效 (临时, hostapd 重载后需重设) |
| 优化信道 | `set_wifi` → `channel=1` | 路由器自动选到信道 8 (可能比信道 6 干扰更少) |
| 启用 40MHz | `set_wifi` → `bandwidth=40` | `code:0` — 需重启 WiFi 验证协商速率变化 |
| 登录凭证 | stok=`24a3e1912f09247c73e9056fe3cc20e4` | 有效期有限, 超时后重新获取 |

### 后续可执行优化

| 优先级 | 操作 | 方法 | 预期收益 |
|--------|------|------|----------|
| P1 | 永久锁定 AP 隔离 | SSH `/etc/config/wireless` + `option isolate 0` | 一劳永逸 |
| P1 | 换 5GHz 路由器 | 硬件升级 (AX3000/AX6S) | 速率 72→300+ Mbps |
| P2 | 消除双 NAT | 上游改桥接 或 R4CM 改 AP 模式 | 减少一跳延迟 |
| P2 | 锁定 WiFi 信道 | `set_wifi` → `channel=11` (若周围少) | 减少同频干扰 |
| P3 | 更新网卡驱动 | Dell/高通 QCA9377 2022+ 版 | 延迟抖动降低 |

## 八、动态订阅策略 (应对节点变动)

### 问题

v2rayN 的订阅链接会定期更新节点列表。手动维护的 `config.json` 在 v2rayN 切换节点或更新订阅时会被**自动覆盖**。

### 解决方案

**方案 A: 自动生成脚本**

使用 `scripts/generate-xray-config.sh` 在每次订阅更新后自动重建多节点配置:

```bash
# 订阅更新后执行
bash D:/Document/local/knowledge/network/scripts/generate-xray-config.sh
cp D:/Document/Download/v2rayN-windows-64-desktop/v2rayN-windows-64/binConfigs/config-optimized.json \
   D:/Document/Download/v2rayN-windows-64-desktop/v2rayN-windows-64/binConfigs/config.json
# 重启代理
```

脚本逻辑:
1. 扫描 `configTest*.json` 发现所有可用节点
2. Ping 测速筛选最佳 4 个 (2 主力 + 2 备用)
3. 生成带 balancer + observatory 的完整配置
4. 自动适配每个节点的 SNI/公钥参数

**方案 B: v2rayN 自定义配置**

在 v2rayN → 服务器 → 添加自定义配置服务器 → 粘贴完整 xray JSON。
优点: v2rayN 不会覆盖；缺点: 节点列表需手动更新。

**方案 C: Cron 自动化 (树莓派恢复后)**

```bash
# crontab: 每小时检查并更新
0 * * * * cd "D:\Document\local\knowledge\network" && bash scripts/generate-xray-config.sh && cp scripts/xray-config-optimized.json <v2rayN-dir>/binConfigs/config.json
```

## 九、相关文件路径

| 文件 | 路径 |
|------|------|
| v2rayN 主程序 | `D:\Document\Download\v2rayN-windows-64-desktop\v2rayN-windows-64\` |
| xray 核心配置 (当前) | `.../binConfigs/config.json` |
| xray 优化配置 (静态) | `D:\Document\local\knowledge\network\scripts\xray-config-optimized.json` |
| 动态配置生成脚本 | `D:\Document\local\knowledge\network\scripts\generate-xray-config.sh` |
| 代理节点数据库 | `D:\Document\local\knowledge\network\scripts\proxy-nodes.json` |
| v2rayN GUI 配置 | `.../guiConfigs/guiNConfig.json` |
| v2rayN 节点数据库 | `.../guiConfigs/guiNDB.db` |
| 本分析文档 | `D:\Document\local\knowledge\network\network-analysis-2026-07-28.md` |
| 小米路由器 skill | `.claude/skills/xiaomi-router/SKILL.md` |
| 历史事故报告 | [[2026-07-21-树莓派网络故障与路由器破解完整复盘]] |
