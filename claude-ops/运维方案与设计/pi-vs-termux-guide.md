---
title: Pi (systemd) vs Termux (proot) — Agent 运维部署差异指南
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-06-29
updated: 2026-08-17
status: review
---

# Pi (systemd) vs Termux (proot) — Agent 运维部署差异指南

See also: [[Claude-Ops-KB-Home]] · [[claude-unattended-cross-platform-guide]] · [[claude-deployment-record]]

> 更新: 2026-06-29 | 适用: Claude Code + Hermes 的 permafrost/proxy/监控部署

---

## 一、环境差异总览

| 维度 | Raspberry Pi 4B | Termux (Android) |
|------|:-----------:|:----------------:|
| **OS** | Debian (aarch64) | Android + Termux + PRoot Ubuntu |
| **进程管理** | systemd (user) | 手动 nohup / tmux |
| **Python** | 系统 python3 (3.11) | pkg install python |
| **Node.js** | 系统 node | pkg install nodejs |
| **包管理** | apt | pkg (Termux) + apt (PRoot) |
| **代理** | xray (:10808) | 无（或 clash / v2rayNG） |
| **网络** | 路由器 NAT + WiFi | 蜂窝/WiFi 直连 |
| **自启动** | systemd service | termux-boot |
| **文件路径** | /home/pi/ | /data/data/com.termux/files/home/ |
| **内核** | Linux (完整) | Android (受限) |
| **sysctl** | 可用 | 不可用（需 root） |
| **端口** | 全部可用 | 1024+ (非 root) |

---

## 二、Permafrost 部署差异

### 2.1 Pi 部署

```bash
# 通过 npm 安装（CC 插件机制自动处理）
# 或手动启动
nohup python3 ~/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/permafrost_proxy.py &

# systemd 自动拉起
systemctl --user status claude-permafrost.service
```

### 2.2 Termux 部署

```bash
# 1. 确保 Python 可用
pkg install python

# 2. 同 Pi 一样通过 CC 插件安装 permafrost
claude plugin install cache@permafrost

# 3. 手动启动（Termux 无 systemd）
nohup python3 ~/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/permafrost_proxy.py \
  > ~/.permafrost/permafrost.log 2>&1 &

# 4. 写入 .bashrc 实现"伪自启动"
echo 'pgrep -f permafrost_proxy.py >/dev/null || nohup python3 ~/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/permafrost_proxy.py > ~/.permafrost/permafrost.log 2>&1 &' >> ~/.bashrc
```

**注意**: Termux 在后台被 Android 杀死后，permafrost 也会退出。需要配合 termux-wake-lock 或 termux-boot。

---

## 三、Resilience Proxy 部署差异

### 3.1 Pi 部署

```bash
# Node.js 代理，systemd 管理
systemctl --user status claude-proxy.service

# 或手动
nohup node /home/pi/claude-resilience-proxy.js &
```

### 3.2 Termux 部署

```bash
# 1. 安装 Node.js
pkg install nodejs

# 2. 复制 proxy 脚本
cp /path/to/claude-resilience-proxy.js ~/

# 3. 手动启动
nohup node ~/claude-resilience-proxy.js > ~/.claude/proxy.log 2>&1 &

# ⚠️ Termux 注意事项:
#   - proxy 端口 8787 可能被占用 → 改为 8789
#   - Node.js 版本可能较旧 → 检查 async/await 语法支持
#   - 无 sysctl → 跳过 TCP keepalive 内核参数优化
```

---

## 四、缓存监控部署差异

### 4.1 Pi 部署

```bash
# systemd timer 或 cron
bash /home/pi/claude-cache-monitor.sh daemon
bash /home/pi/hermes-cache-monitor.sh daemon  # Hermes 专用
```

### 4.2 Termux 部署

```bash
# 1. 安装 termux-services (替代 systemd)
pkg install termux-services

# 2. 或使用 cron (termux 内置)
crontab -e
# 添加: */5 * * * * bash ~/claude-cache-monitor.sh once

# 3. 或最简单的 nohup 循环
nohup bash -c 'while true; do bash ~/claude-cache-monitor.sh once; sleep 60; done' &
```

**注意**: 
- Termux 的 cron 需要 termux-services 保持后台运行
- 最简单的方案是 tmux session 中运行监控脚本

---

## 五、CC 配置差异

### 5.1 Pi 配置 (~/.claude/settings.local.json)

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://[IP已脱敏]:8788",
    "ANTHROPIC_AUTH_TOKEN": "[已脱敏]",
    "ANTHROPIC_MODEL": "deepseek-v4-pro"
  }
}
```

### 5.2 Termux 配置

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://[IP已脱敏]:8788",
    "ANTHROPIC_AUTH_TOKEN": "[已脱敏]",
    "ANTHROPIC_MODEL": "deepseek-v4-pro"
  }
}
```

**相同！** CC 配置不区分平台。关键是 permafrost 要在同一台机器上运行。

---

## 六、网络代理差异

### 6.1 Pi 网络

```
CC → permafrost :8788 → proxy :8787 → xray :10808 → 代理节点 → DeepSeek
                                         ↑
                                    GFW 隧道
```

### 6.2 Termux 网络

```
CC → permafrost :8788 → DeepSeek API (直连)
```

**Termux 通常不需要 xray**，因为：
- Android 网络不走 GFW（蜂窝/WiFi 直连）
- DeepSeek/ARK API 在国内可直接访问
- 如果确实需要代理，用 v2rayNG (Android app) 或 clash

---

## 七、端口规划

### 7.1 Pi 端口分配

| 端口 | 服务 | 进程 |
|:----:|------|------|
| 8787 | Resilience Proxy | node |
| 8788 | Permafrost (CC) | python3 |
| 10808 | Xray SOCKS5 | xray |
| 18888 | Model-Router (Hermes) | python3 |

### 7.2 Termux 端口分配

| 端口 | 服务 | 备注 |
|:----:|------|------|
| 8788 | Permafrost (CC) | 同 Pi |
| 8787 | Proxy (可选) | 国内直连不需要 |
| — | Xray | 不需要（国内直连） |
| — | Model-Router | 不需要（Termux 不跑 Hermes） |

---

## 八、补丁部署差异

### 8.1 Pi

```bash
# 从仓库权威补丁部署
cp /home/pi/claude-code-knowledge/patches/permafrost_align.py \
   ~/.claude/plugins/cache/permafrost/.../permafrost_align.py
rm -rf ~/.claude/plugins/cache/permafrost/.../__pycache__/
kill $(pgrep -f permafrost_proxy.py)
# ...重启...
```

### 8.2 Termux

```bash
# 同样的操作，但:
# 1. 仓库路径不同 (/data/data/com.termux/files/home/ 而非 /home/pi/)
# 2. 无 pgrep → 用 ps | grep 替代
# 3. 无 kill → 同样可用但 Android 可能限制信号

# Termux 适配版:
cp ~/claude-code-knowledge/patches/permafrost_align.py \
   ~/.claude/plugins/cache/permafrost/.../permafrost_align.py
rm -rf ~/.claude/plugins/cache/permafrost/.../__pycache__/
PID=$(ps aux | grep permafrost_proxy.py | grep -v grep | awk '{print $2}')
[ -n "$PID" ] && kill $PID && sleep 2
nohup python3 ~/.claude/plugins/cache/permafrost/.../permafrost_proxy.py &
```

---

## 九、常见问题

### 9.1 Pi 特有

| 问题 | 原因 | 解决 |
|------|------|------|
| 端口占用 | 上次 permafrost 未完全退出 | `sleep 2` 等待释放 |
| systemd 冲突 | 手动启动与 service 冲突 | 统一用 systemd 或统一切到手动 |
| xray 瞬断 | 代理节点不稳定 | proxy-guardian.sh + update-proxy-sub.sh |
| conntrack 饱和 | 大量失败连接堆积 | TCP keepalive + 降低重试次数 |

### 9.2 Termux 特有

| 问题 | 原因 | 解决 |
|------|------|------|
| 进程被杀死 | Android 后台限制 | termux-wake-lock |
| 端口 <1024 | 非 root 用户 | 使用高端口 |
| Python .pyc 不一致 | Python 版本可能不同 | 每次部署清除 __pycache__ |
| pip 安装失败 | 缺少编译工具 | pkg install python build-essential |
| 无 crontab | 未安装 termux-services | pkg install termux-services |

---

## 十、决策速查

| 场景 | Pi | Termux |
|------|:--:|:------:|
| 需要 xray 代理? | ✅ GFW 隧道 | ❌ 国内直连 |
| 需要 systemd? | ✅ | ❌ 用 nohup/tmux |
| 需要 TCP 内核优化? | ✅ sysctl | ❌ 无权限 |
| 需要 permafrost? | ✅ | ✅ (相同) |
| 需要 proxy :8787? | ✅ 韧性 | ⚠️ 可选 |
| 需要 model-router? | ✅ Hermes | ❌ 不跑 Hermes |
| 需要缓存监控? | ✅ 两个脚本 | ✅ 仅 CC 监控 |
