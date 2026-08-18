# Claude Code 韧性代理 — 架构总览

> 当前运行版本: Node.js 代理 + Permafrost 缓存层, 部署于 2026-06-12
> 缓存优化方案详见: [claude-cache-optimization.md](claude-cache-optimization.md)

---

## 一、文件清单（按职能）

```
缓存优化层 (Permafrost)
├── ~/.claude/plugins/cache/permafrost/ ← permafrost v0.3.0 插件
└── ~/.permafrost/proxy.log             ← permafrost 运行日志

双层管理 (3 个)
├── /root/claude-permafrost-deploy.sh   ← 方案 B↔C 切换 (start/rollback/stop/status)
├── /root/claude-permafrost-rollback.sh ← 独立 C→B 逃生通道
└── /root/claude-cache-optimization.md  ← 缓存优化方案文档

底层代理 (3 个)
├── /root/claude-resilience-proxy.js    ← Node.js 韧性代理 (:8787)
├── /root/claude-resilience-deploy.sh   ← proxy 启停脚本 (历史兼容)
└── /root/claude-rollback.sh            ← 完全回滚到直连 DeepSeek

配置文件 (2 个)
├── /root/.zshrc (line 107)             ← ANTHROPIC_BASE_URL
└── /root/.bashrc (line 150)            ← ANTHROPIC_BASE_URL

运行时文件 (3 个，自动生成)
├── /root/.claude/proxy.pid             ← 代理进程 PID
├── /root/.claude/proxy.log             ← 代理运行日志
└── /root/.claude/resume-prompt-header.txt ← 中断恢复协议模板

文档 (GitHub, ~15 个)
└── /root/workspace/claude-code-knowledge/ → L-ingqin12/claude-code-knowledge
```

## 二、数据链路图

### 当前架构 (方案 B — 应急)

```
Claude Code
  │  ANTHROPIC_BASE_URL = http://[IP已脱敏]:8788
  │  (从 settings.local.json 读取)
  ▼
Permafrost :8788 (Python)
  │  upstream = https://api.deepseek.com/anthropic
  │  ├─ 去 cache_control
  │  ├─ 工具排序
  │  ├─ env 冻结 + 增量
  │  └─ 规范 JSON 序列化
  ▼
api.deepseek.com/anthropic
```

### 目标架构 (方案 C — 双层生产)

```
Claude Code
  │  ANTHROPIC_BASE_URL = http://[IP已脱敏]:8788
  ▼
┌─────────────────────────────────────────┐
│  Permafrost :8788 (缓存对齐层)           │
│  upstream = http://[IP已脱敏]:8787       │
│                                         │
│  aggressive mode:                        │
│  ├─ 去 cache_control                    │
│  ├─ 工具按 name 排序                     │
│  ├─ env 块冻结 + 仅传增量               │
│  ├─ 规范 JSON 序列化                     │
│  ├─ 冷锚点合并 (并行子 agent 共享预热)    │
│  └─ 空闲保活 (opt-in)                    │
└────────────┬────────────────────────────┘
             │ http://[IP已脱敏]:8787
             ▼
┌─────────────────────────────────────────┐
│  claude-resilience-proxy.js (韧性层)     │
│  upstream = https://api.deepseek.com    │
│                                         │
│  ├─ 透明转发                             │
│  ├─ socket 错误自动重试 (3次, 1s/3s/8s)  │
│  └─ TCP keepalive (60s)                 │
└────────────┬────────────────────────────┘
             │ https://api.deepseek.com:443/anthropic/v1/messages
             ▼
┌─────────────────────────────────────────┐
│  api.deepseek.com (Anthropic 兼容层)     │
└─────────────────────────────────────────┘
```

### 逃生路径

```
方案 C ──(proxy故障)──▶ 方案 B ──(permafrost故障)──▶ 直连 DeepSeek
  ↑                        ↑                          ↑
  deploy.sh start     deploy.sh rollback        claude-rollback.sh
```

## 三、部署运维

```bash
# 查看完整链路状态
bash /root/claude-permafrost-deploy.sh status

# 方案 C 部署 (permafrost → proxy → DeepSeek)
bash /root/claude-permafrost-deploy.sh start

# 方案 C→B 逃生 (绕过 proxy)
bash /root/claude-permafrost-deploy.sh rollback

# 完全回滚 (绕过所有代理)
bash /root/claude-rollback.sh

# 查看 permafrost 实时缓存命中率
curl -s http://[IP已脱敏]:8788/permafrost/stats | python3 -m json.tool
```

### 启停状态机

```
                        deploy.sh start
   ┌──────────┐ ──────────────────────────→ ┌──────────────┐
   │ 方案 B    │                              │ 方案 C        │
   │ pf → DS  │ ←────────────────────────── │ pf → px → DS │
   └──────────┘      deploy.sh rollback      └──────────────┘
        │                                           │
        └──────────── claude-rollback.sh ──────────▶ 直连 DS
```

## 四、错误处理路径

```
请求到达代理
     │
     ▼
  https.request → 成功? → pipe 响应 → Claude 收到 HTTP 200
     │
     ├─ socket 错误 → retry #1 (1s 后)
     │     ├─ 成功 → Claude HTTP 200
     │     └─ 失败 → retry #2 (3s 后)
     │           ├─ 成功 → Claude HTTP 200
     │           └─ 失败 → retry #3 (8s 后)
     │                 ├─ 成功 → Claude HTTP 200
     │                 └─ 失败 → Claude HTTP 502
     │                           │
     │                           ▼
     │                      Claude 显示错误
     │                      等待用户输入
     │                      (会话历史完整保留)
     │
     └─ 非socket错误 (4xx/5xx) → 直接转发给 Claude
```

## 五、逃生通道

```
正常状态:         Claude → proxy → DeepSeek
                      
逃生触发:         bash /root/claude-rollback.sh
                     │
                     ├─ 杀掉代理进程
                     ├─ .zshrc → https://api.deepseek.com/anthropic
                     └─ .bashrc → https://api.deepseek.com/anthropic

逃生后:           Claude → DeepSeek (直连, 绕过代理)
                      
重新启用:         bash /root/claude-resilience-deploy.sh start
```

## 六、当前环境约束

| 约束 | 影响 | 缓解 |
|------|------|------|
| PRoot 无 sysctl | 内核 TCP keepalive 不可调 | 应用层 socket.setKeepAlive(60s) |
| 无 systemd | 代理不能自启/自恢复 | 手动 deploy.sh start |
| 移动网络 NAT 30-120s | 空闲连接易断 | 代理 keepalive + 重试 |
| Android 进程管理 | Termux 可能被杀 | 需 wake-lock + 电池白名单 (未部署) |
