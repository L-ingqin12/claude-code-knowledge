---
title: Hermes 飞书助手全面瘫痪事故复盘
aliases: []
tags: [ai/ops, incident]
created: 2026-06-24
updated: 2026-08-25
status: stable
---

# Hermes 飞书助手全面瘫痪事故复盘

See also: [[Claude-Ops-KB-Home]] · [[hermes-session-optimization-report]] · [[pi-vs-termux-guide]]

> **日期**: 2026-06-24  
> **影响范围**: default + ranzi 两个飞书机器人完全无响应  
> **持续时长**: 约 108 分钟 (20:06 → 21:54 物理重启)  
> **恢复方式**: 重启树莓派 (唯一恢复手段)  
> **严重级别**: P0 (全面瘫痪, 无法远程恢复)

---

## 一、事故时间线

| 时间 | 事件 |
|------|------|
| 20:06:08 | `urllib3 SSLError: EOF occurred in violation of protocol` — 代理 TLS 握手被对端 RST |
| 20:06 | 代理节点 (韩国 DDNS) 瞬断, 所有通过代理的 API 调用失败 |
| 20:06~21:37 | hermes 重试 API 调用 (之前 `api_max_retries=3` × 每个工具调用) → TCP 连接累积 |
| ~21:00 | 路由器 conntrack/NAT 表开始饱和, DNS 解析出现 `Temporary failure` |
| 21:01:37 | 首次 `Lark: Failed to resolve 'open.feishu.cn'` — DNS 解析失败 |
| 21:01~21:53 | 飞书 WebSocket 每 2 分钟重连一次, 连续失败 9+ 次 |
| ~21:30 | Pi 网络栈完全阻塞, SSH 开始无法连接 |
| ~21:40 | Pi 完全无响应 (ping 不通, SSH 拒绝), 只能物理重启 |
| 21:54 | 用户重启树莓派 |
| 21:55 | 所有服务自动启动, 飞书重连成功, 恢复 |

## 二、故障机制 (5 层级联)

### 第 1 层: 代理 TLS 瞬断 (触发器)

**日志证据**:
```
2026-06-24 20:06:08 urllib3.exceptions.SSLError: EOF occurred in violation of protocol
```

xray 通过韩国 VLESS reality 节点 (`[IP已脱敏]:10000` 等) 转发流量。reality 协议通过伪造 TLS 握手 (SNI=apple.com) 规避 GFW 检测。但韩国节点的 TLS 层不稳定 — 对端会间歇性发送 TCP RST 或直接关闭连接, 导致 `SSLError: EOF`。

**命令复现**:
```bash
# 检查当前代理节点
grep '"address"' /usr/local/etc/xray/config.json
# 测试代理连通性
curl -s -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 10 \
  --socks5-hostname [IP已脱敏]:10808 https://github.com
```

### 第 2 层: 重试放大 (放大器)

当时 `api_max_retries=3`, 每个失败的 API 调用重试 3 次, 每次建立新 TCP 连接。

```
1 个 API 调用失败 → 3 次重试 → 3 个新 TCP 连接 (全部走代理)
代理已死 → 每个连接超时等待 → TIME_WAIT 状态堆积
N 个并发工具调用 × 3 次重试 × 15s 超时 → 数百个死连接
```

### 第 3 层: 连接表饱和 (临界点)

路由器 `[IP已脱敏]` 维护 conntrack/NAT 表, 跟踪所有内网→外网连接。连接堆积导致:

```
conntrack 表项 → 耗尽
    ↓
新连接被丢弃 (包括 DNS 查询)
    ↓
"Temporary failure in name resolution"
```

**日志证据**:
```
2026-06-24 21:01:37 ERROR Lark: connect failed
  Caused by NameResolutionError: Failed to resolve 'open.feishu.cn'
  ([Errno -3] Temporary failure in name resolution)
```

### 第 4 层: DNS 断裂 (飞书断连)

路由器也是 DNS 服务器 (`/etc/resolv.conf` → `nameserver [IP已脱敏]`)。

虽然飞书走 xray `direct` 出站, 不通过代理, 但 DNS 仍需路由器:
```bash
# 来自 xray 访问日志, 确认飞书走 direct 而非 proxy
xray[1158]: accepted tcp:open.feishu.cn:443 [socks-in -> direct]
```

```
代理风暴 → 路由器 conntrack 满 → DNS 不可用
    ↓
open.feishu.cn 无法解析 → WebSocket 断开
    ↓
重连尝试 → 路由器更堵 → 恶性循环
```

### 第 5 层: 全网阻塞 (SSH 死)

```
所有 TCP 流量 → 路由器 → conntrack 满 → 全部丢弃
    ↓
ping 通 (ICMP) 但 TCP 不通 (SSH, HTTP 全死)
    ↓
唯一恢复手段: 物理重启 (路由器断电或 Pi 重启)
```

## 三、排查过程

### 3.1 发现阶段

**现象**: 用户在飞书给两个机器人发消息, 均无响应。

**排查命令**:
```bash
# 1. 检查 gateway 状态
ssh pi@[IP已脱敏] 'systemctl --user status hermes-gateway.service'
# 输出: active (running) — 进程活着但不应答

# 2. 检查 gateway 日志
tail -30 /home/pi/.hermes/logs/gateway.log
# 发现: inbound message 有记录, 但无 response ready

# 3. 检查错误日志
tail -50 /home/pi/.hermes/logs/errors.log
# 发现: 大量 NameResolutionError (open.feishu.cn) + SSLError

# 4. 检查代理
curl --socks5-hostname [IP已脱敏]:10808 https://github.com
# HTTP 000 — 代理不通
```

### 3.2 假活检测

Gateway 进程 `active (running)` 但飞书不响应 → "假活" 状态:

- systemd 看进程活着
- WebSocket 断连未被 systemd 感知
- agent 卡在工具循环中 (Remotion 视频生成 → 180s 超时 × 反复重试)

**检测方法** (后续写成 guardian P4 探针):
```bash
# 方法 A: WebSocket 记录检查
grep "[Feishu] Connected" /home/pi/.hermes/logs/gateway.log | tail -1

# 方法 B: 收/发比率分析
inbound=$(grep "inbound message.*feishu" gateway.log | tail -20 | wc -l)
outbound=$(grep "Sending response.*Feishu" gateway.log | tail -20 | wc -l)
# inbound > 0 且 outbound = 0 → 假活

# 方法 C: API 心跳 ping (通过飞书 Open API 发 /ping)
```

### 3.3 定位瓶颈

**关键发现**: 整个子网 ([IP已脱敏]~254) 的端口 22 全部表现相同 — `Connection closed`, 包括路由器本身。

```bash
# 全网扫描
for i in $(seq 1 254); do
  timeout 1 bash -c "echo >/dev/tcp/192.168.0.$i/22" 2>/dev/null && echo "SSH: $i"
done
# 结果: 几乎所有 IP 都显示 SSH 可达, 但全部立即关闭连接
# 结论: 路由器 conntrack 过载, 不是 Pi 独有问题
```

**验证**: telnet 到路由器 `[IP已脱敏]:22` 同样 `Connection closed`。

### 3.4 DNS 隔离确认

```bash
# open.feishu.cn 解析测试
host open.feishu.cn
# 输出: 多个 CDN IP (111.x, 223.x) — 国内地址, 确认走 direct

# xray 访问日志确认路由
sudo journalctl -u xray-proxy | grep feishu
# [socks-in -> direct] ← 走了直连, 不是 proxy
```

### 3.5 SSH 断连但 ping 通时的诊断

```bash
# ping 通
ping [IP已脱敏]  # 正常

# telnet 通但 SSH 协议握手失败
echo "quit" | telnet [IP已脱敏] 22
# Connected to [IP已脱敏]. → Connection closed by foreign host.
# 没有 SSH 横幅 → TCP 握手成功但应用层被截断
```

## 四、IP 变更事件

重启后 Pi 的 IP 从 `[IP已脱敏]` 变为未知 (路由器 DHCP 可能重新分配), 导致无法 SSH。

**排查方法**:
```bash
# 全网 ping 扫描
for i in $(seq 1 254); do
  (ping -c1 -W1 192.168.0.$i >/dev/null 2>&1 && echo "alive: .$i") &
done; wait

# 发现新 IP
# .193, .194, .195, .196 均响应 ping
# 逐 IP 尝试 SSH → 全部连接拒绝 (路由器 conntrack 问题仍在)

# 重启路由器/等待后恢复, .191 重新可用
```

**后续建议**: 在路由器上为 Pi 设置静态 DHCP 绑定。

## 五、解决方案

### 5.1 已部署 (事故后)

#### 1. API 重试降频

```bash
# 修改前: api_max_retries: 3
# 修改后: api_max_retries: 1
python3 -c "
import yaml
with open('/home/pi/.hermes/config.yaml') as f: cfg = yaml.safe_load(f)
cfg['agent']['api_max_retries'] = 1
with open('/home/pi/.hermes/config.yaml','w') as f: yaml.dump(cfg, f)
"
```

**原理**: 代理瞬断时, 减少重试次数直接降低 TCP 连接数。原 3 次重试 → 3× 连接, 现 1 次 → 连接风暴强度降 67%。

#### 2. TCP keepalive 优化

```bash
sudo tee /etc/sysctl.d/90-hermes-tcp.conf << EOF
net.ipv4.tcp_keepalive_time = 120   # 原 7200s → 120s
net.ipv4.tcp_keepalive_intvl = 15   # 15s 探测间隔
net.ipv4.tcp_keepalive_probes = 3   # 3 次探测后判定死亡
net.ipv4.tcp_fin_timeout = 30       # 原 60s → 30s
EOF
sudo sysctl -p /etc/sysctl.d/90-hermes-tcp.conf
```

**原理**: 
- `tcp_keepalive_time`: 7200s (2 小时) 才能发现死连接 → 120s (2 分钟)。代理 TLS 断后, 120s 后内核发送 keepalive 探测, 发现对端不可达, 关闭连接释放资源。
- `tcp_fin_timeout`: FIN_WAIT2 状态的最大时间从 60s → 30s, 加速连接释放。

#### 3. DNS 静态绑定

```bash
echo "[IP已脱敏] open.feishu.cn" | sudo tee -a /etc/hosts
```

**原理**: 飞书 WebSocket 连接需要解析 `open.feishu.cn`。将此主机名写入 `/etc/hosts` 绕过路由器 DNS, 即使路由器 DNS 挂掉也不影响飞书重连。⚠️ 飞书 IP 可能会变, 需定期 (每周) 更新。

#### 4. Feishu 白名单修复

```bash
sed -i 's/FEISHU_ALLOW_ALL_USERS=false/FEISHU_ALLOW_ALL_USERS=true/' \
  /home/pi/.hermes/.env /home/pi/.hermes/profiles/ranzi/.env
```

#### 5. Gateway 排水时间缩短

```bash
# config.yaml:
#   agent.restart_drain_timeout: 180 → 60
#   agent.gateway_notify_interval: 120 → 20
#   agent.clarify_timeout: 600 → 180
```

#### 6. Hermes 守护进程

```bash
# 部署文件:
#   /home/pi/hermes-guardian.sh
#   /etc/systemd/system/hermes-guardian.service
#   /etc/systemd/system/hermes-guardian.timer (每 5 分钟)
```

**6 项探针**:
| 探针 | 检测 | 方法 |
|------|------|------|
| P1 网关进程 | systemd 单元状态 | `systemctl --user show -p ActiveState` |
| P2 模型路由器 | :18888/health | `curl http://[IP已脱敏]:18888/health` |
| P3 代理连通性 | GitHub 可达性 | socks5://[IP已脱敏]:10808 → GitHub |
| P4 飞书响应 (复合) | WS + 日志 + API ping | grep Connected + inbound/outbound + API |
| P5 工具循环 | tool_call 堆积 | agent.log 中 tool/response 比率 |
| P6 会话数 | 会话泄漏 | `ls /home/pi/.hermes/sessions/*.json | wc -l` |

**5 级恢复**:
| 级别 | 触发条件 | 动作 |
|:----:|------|------|
| L1 | 轻微降级 | 仅日志 |
| L2 | 工具循环/会话过多 | 杀问题会话 |
| L3 | 单个探针 critical | 重启 gateway |
| L4 | 多个 critical 或 L3 失败 | 清会话 + 重启 gateway + router |
| L5 | 3+ 探针 critical | 全栈重启 (xray+router+gateway) + 通知 |

#### 7. 代理守护联动

```bash
# proxy-guardian.sh (cron 每 15 分钟)
# hermes-guardian.sh 检测到代理降级 → 立即触发 proxy-guardian
```

### 5.2 之前已部署 (二次防御)

| 项 | 值 | 部署日期 |
|----|-----|---------|
| `model.context_length` | 131072 → 压缩在 45K tokens 触发 | 06-16 |
| `compression.threshold` | 0.35 | 06-16 |
| `compression.hygiene_hard_message_limit` | 120 | 06-16 |
| `session_reset.mode` | daily | 06-16 |
| `update-proxy-sub.sh` v3 | IPv4 预解析 + 测速择优 | 06-17 |
| xray config | 预解析 IPv4 + 最简模板 | 06-17 |
| `proxy-guardian.sh` | 本地网络预检 + 5 级更新管控 | 06-17 |
| `cleanup_sessions.sh` + cron | 每日 03:30 清理旧会话 | 06-16 |

## 六、架构原理

### 6.1 网络拓扑

```
树莓派 ([IP已脱敏])
├── /etc/hosts: open.feishu.cn → [IP已脱敏] (绕过 DNS)
├── xray-proxy (:10808)
│   ├── outbound proxy: 韩国/台湾 VLESS reality → 外网
│   └── outbound direct: geosite:cn → 直连 (飞书走这里)
├── model-router (:18888) → ARK API (通过 xray proxy)
├── hermes-gateway → model-router (API) + xray proxy (GitHub)
└── hermes-gateway-ranzi (同上)

路由器 ([IP已脱敏])
├── DHCP + DNS + NAT
├── conntrack 表: 所有内网→外网连接的跟踪
└── 瓶颈: conntrack 满 → 全内网断网
```

### 6.2 为什么飞书直连也被拖垮

虽然 xray 将 `open.feishu.cn` 路由到 `direct`, 但:

1. **DNS 查询仍走路由器** → conntrack 满 → DNS 超时
2. **TCP 连接需 NAT** → 新连接需 conntrack 条目 → 满 → 拒绝
3. **现有连接不受影响** → 已建立的 WebSocket 能继续, 但一旦断开就无法重连

### 6.3 为什么 SSH 也断了

SSH 是纯内网 TCP 连接 (同一子网), 理论上不经过路由器 NAT。但实际上:

1. SSH 需要 TCP 握手 → 内核需要分配 socket buffer
2. 代理风暴导致大量 socket 处于 TIME_WAIT → 内核 socket 表压力大
3. Pi 的内存/CPU 被 hermes agent (重试工具调用) 吃掉 → SSH 响应慢/拒绝

**验证**: telnet 能连上 (TCP 握手成功) 但 SSH 协议层立即断开 — 说明 SSH 服务还在, 但 fork 新进程时资源不足。

## 七、使用命令汇总

### 7.1 状态检查

```bash
systemctl --user status hermes-gateway.service hermes-gateway-ranzi.service
systemctl --user status model-router.service
systemctl status xray-proxy.service
```

### 7.2 日志排查

```bash
tail -50 /home/pi/.hermes/logs/gateway.log
tail -50 /home/pi/.hermes/logs/errors.log
tail -50 /home/pi/.hermes/logs/agent.log
sudo journalctl -u xray-proxy --since "2026-06-24 20:00" --no-pager
grep -c "inbound message.*feishu" /home/pi/.hermes/logs/gateway.log
grep -c "Sending response.*Feishu" /home/pi/.hermes/logs/gateway.log
```

### 7.3 代理测试

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 10 \
  --socks5-hostname [IP已脱敏]:10808 https://github.com
curl -s -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 10 \
  https://www.baidu.com
host -t A open.feishu.cn
```

### 7.4 网络诊断

```bash
ping [IP已脱敏]
ping [IP已脱敏]
ip addr show wlan0 | grep inet
arp -a
# 全网端口扫描
for i in $(seq 1 254); do (timeout 1 bash -c "echo >/dev/tcp/192.168.0.$i/22" 2>/dev/null && echo "SSH: $i") & done; wait
```

### 7.5 恢复操作

```bash
# 重启 gateway
systemctl --user restart hermes-gateway.service hermes-gateway-ranzi.service

# 更新代理节点
sudo bash /home/pi/update-proxy-sub.sh

# 重启 xray
sudo systemctl restart xray-proxy.service

# 全部重启
sudo reboot
```

### 7.6 配置修改

```bash
# 读当前值
grep "api_max_retries\|restart_drain\|gateway_notify" /home/pi/.hermes/config.yaml

# Python 批量修改
python3 -c "
import yaml
with open('/home/pi/.hermes/config.yaml') as f: cfg = yaml.safe_load(f)
cfg['agent']['api_max_retries'] = 1
with open('/home/pi/.hermes/config.yaml','w') as f: yaml.dump(cfg, f)
"
```

## 八、残余风险

| 风险 | 可能性 | 缓解 |
|------|:------:|------|
| 代理节点再次瞬断 | 高 (韩国 DDNS 不稳定) | guardian 即时切节点 |
| 路由器 conntrack 再次饱和 | 低 (重试已降 67%) | TCP keepalive 加速释放 |
| open.feishu.cn IP 变化 | 中 (CDN 会轮换) | 每周 cron 更新 `/etc/hosts` |
| hermes 工具循环再次发生 | 中 (Remotion 等重任务) | guardian P5 探针 + L2 杀会话 |
| guardian 自身故障 | 低 | systemd Restart=on-failure |
| 物理重启是唯一恢复手段 | 低 (有了 guardian) | guardian L5 全栈重启 |

## 九、后续优化建议

1. **路由器静态 DHCP**: 为 Pi MAC 地址绑定固定 IP, 防重启后 IP 变化
2. **open.feishu.cn 定时更新**: cron 每周运行 `host open.feishu.cn | awk '/has address/{print $NF, $1}' >> /etc/hosts`
3. **conntrack 监控**: 添加 guardian 探针检测 conntrack 使用率
4. **代理 IPv6**: 如果 ISP 支持 IPv6, 在 Pi 上启用 IPv6 可解锁 23 个 IPv6 节点
5. **双代理冗余**: 配置两个不同供应商的代理节点作为 fallback
6. **飞书 API 心跳恢复**: 填写 `~/.hermes-guardian-secrets.sh` 启用端到端飞书响应检测
